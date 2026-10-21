// Installed Pi 1.3.0 offline SDK contract probe. Loaded by the Pi executable,
// not Node's SDK fake; no provider requests may leave this process.
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import {
  createAgentSession, createCodemodeExtension, createToolSearchExtension,
  DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager,
} from "@earendil-works/pi-coding-agent";
import type { AgentSession, ExtensionAPI, ExtensionFactory } from "@earendil-works/pi-coding-agent";

const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const definition = { id: "offline", name: "Offline", api: "parley-environment-offline", reasoning: true,
  input: ["text"] as const, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100_000, maxTokens: 1024 };

async function probe(directory: string): Promise<void> {
  const root = path.join(directory, "work"), agentDir = path.join(directory, "agent");
  await fs.mkdir(path.join(root, ".pi", "extensions"), { recursive: true });
  await fs.mkdir(path.join(agentDir, "skills", "fixture"), { recursive: true });
  await fs.writeFile(path.join(agentDir, "skills", "fixture", "SKILL.md"), "---\nname: fixture\ndescription: Offline inherited skill\n---\nOffline skill instructions.\n");
  await fs.writeFile(path.join(root, "source.ts"), "source\n");
  await fs.writeFile(path.join(root, ".pi", "extensions", "permission.ts"), `export default function(pi) {
    pi.on('tool_call', event => {
      pi.appendEntry('permission-hook', { name: event.toolName });
      if (event.toolName === 'write' && event.input.path.endsWith('denied.ts')) return { block: true, reason: 'DENIED BY NORMAL HOOK' };
    });
    pi.on('tool_result', event => {
      if (event.toolName === 'read') return { content: [{ type: 'text', text: 'REDACTED BY NORMAL HOOK' }] };
    });
    pi.registerTool({ name: 'guarded_model_only', label: 'Guarded', description: 'Normal model-only extension tool', exposure: 'model-only',
      parameters: { type: 'object', properties: {} }, execute: async (_id, _args, _signal, _update, ctx) => {
        pi.appendEntry('model-only-executed', { sessionId: ctx.sessionManager.getSessionId() });
        return { content: [{ type: 'text', text: 'NORMAL MODEL ONLY' }], details: undefined };
      } });
  }`);
  // This permission handler changes no tool metadata or system-prompt inputs.
  // Reloading files cannot reproduce a factory supplied by the embedding host.
  const inlinePermission: ExtensionFactory = pi => {
    pi.on("tool_call", event => {
      if (event.toolName === "write" && event.input.path === path.join(root, "private.ts")) {
        return { block: true, reason: "DENIED BY INLINE HOOK" };
      }
    });
  };
  const settings = SettingsManager.inMemory({ defaultTools: ["read", "write", "codemode", "guarded_model_only"],
    cacheWarming: "off", compaction: { enabled: false }, retry: { enabled: false } });
  const loader = (includeInline: boolean) => new DefaultResourceLoader({ cwd: root, agentDir, settingsManager: settings,
    extensionFactories: [createCodemodeExtension(), createToolSearchExtension(), ...(includeInline ? [inlinePermission] : [])] });
  const runtime = await ModelRuntime.create({ allowModelNetwork: false, authPath: path.join(agentDir, "auth.json"), modelsPath: path.join(agentDir, "models.json") });
  let plan: "normal" | "inline-denied" | "inline-missing" = "normal";
  let stage = 0;
  runtime.registerProvider("parley-environment-offline", {
    baseUrl: "http://127.0.0.1:1", api: definition.api, apiKey: "offline", models: [{ ...definition, input: [...definition.input] }],
    streamSimple: (model, context, options) => {
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const base = { role: "assistant" as const, api: model.api, provider: model.provider, model: model.id, usage, timestamp: Date.now() };
        try {
          assert.equal(options?.reasoning, "high");
          const serialized = JSON.stringify(context.messages);
          assert(serialized.includes("compacted decision"));
          assert(serialized.includes("replacement context"));
          assert(!serialized.includes("REPLACED ORIGINAL"));
          const last = context.messages.at(-1);
          let content: AssistantMessage["content"];
          let stopReason: "toolUse" | "stop";
          if (stage === 0) {
            const code = `text(await tools.write({path:${JSON.stringify(path.join(root, "denied.ts"))},content:'forbidden'}).then(()=>'UNEXPECTED',e=>e.message)); text(await tools.read({path:${JSON.stringify(path.join(root, "source.ts"))}})); text(await tools.write({path:${JSON.stringify(path.join(root, "changed.ts"))},content:'implemented\\n'}));`;
            content = [{ type: "toolCall" as const, id: `${plan}-tool`, name: plan === "normal" ? "codemode" : "write",
              arguments: plan === "normal" ? { code } : { path: path.join(root, "private.ts"), content: "inline protection missing\n" } }];
            stopReason = "toolUse" as const;
          } else if (plan === "normal" && stage === 1) {
            assert.equal(last?.role, "toolResult");
            assert(JSON.stringify(last).includes("DENIED BY NORMAL HOOK"));
            assert(JSON.stringify(last).includes("REDACTED BY NORMAL HOOK"));
            content = [{ type: "toolCall" as const, id: "modelonly", name: "guarded_model_only", arguments: {} }];
            stopReason = "toolUse" as const;
          } else {
            assert.equal(last?.role, "toolResult");
            const expected = plan === "normal" ? "NORMAL MODEL ONLY" : plan === "inline-denied" ? "DENIED BY INLINE HOOK" : "Successfully wrote";
            assert(JSON.stringify(last).includes(expected), JSON.stringify(last));
            content = [{ type: "text" as const, text: `Verified ${plan}` }];
            stopReason = "stop" as const;
          }
          stage++;
          const message = { ...base, content, stopReason };
          stream.push({ type: "start", partial: message });
          stream.push({ type: "done", reason: stopReason, message });
          stream.end();
        } catch (error) {
          const message = { ...base, content: [], stopReason: "error" as const, errorMessage: String(error) };
          stream.push({ type: "error", reason: "error", error: message });
          stream.end();
        }
      });
      return stream;
    },
  });
  const model = runtime.getModel("parley-environment-offline", "offline");
  assert(model);
  const manager = SessionManager.create(root, path.join(directory, "sessions"));
  manager.appendMessage({ role: "user", content: "older task", timestamp: 1 });
  const keep = manager.appendMessage({ role: "user", content: "REPLACED ORIGINAL", timestamp: 2 });
  manager.appendMessage({ role: "assistant", content: [{ type: "text", text: "older answer" }], api: model.api, provider: model.provider,
    model: model.id, usage, stopReason: "stop", timestamp: 3 });
  manager.appendCompaction("compacted decision", keep, 100);
  manager.appendContextEdit(keep, { content: "replacement context" });
  const sessions: AgentSession[] = [];
  try {
    const parentLoader = loader(true);
    await parentLoader.reload();
    assert.deepEqual(parentLoader.getExtensions().errors, []);
    const { session: parent } = await createAgentSession({ cwd: root, agentDir, modelRuntime: runtime, model, thinkingLevel: "high",
      sessionManager: manager, resourceLoader: parentLoader, settingsManager: settings });
    sessions.push(parent);
    await parent.bindExtensions({});
    const filename = manager.getSessionFile()!;
    const bytes = await fs.readFile(filename), boundary = manager.getLeafId()!;
    const branch = () => {
      const fork = SessionManager.open(filename);
      assert.notEqual(fork.createBranchedSession(boundary), filename);
      assert.notEqual(fork.getSessionId(), manager.getSessionId());
      assert.deepEqual(fork.buildSessionContext(), manager.buildSessionContext());
      return fork;
    };
    const childLoader = loader(true);
    await childLoader.reload();
    assert.deepEqual(childLoader.getExtensions().errors, []);
    assert.deepEqual(childLoader.getSkills(), parentLoader.getSkills());
    assert.deepEqual(childLoader.getSkills().skills.map(skill => skill.name), ["fixture"], "Probe must not discover ambient skills");
    const fork = branch();
    const { session: child } = await createAgentSession({ cwd: root, agentDir, modelRuntime: runtime, model, thinkingLevel: "high",
      sessionManager: fork, resourceLoader: childLoader, settingsManager: settings });
    sessions.push(child);
    await child.bindExtensions({});
    assert.deepEqual(child.getActiveToolNames().sort(), parent.getActiveToolNames().sort());
    assert.equal(JSON.stringify(child.getAllTools()), JSON.stringify(parent.getAllTools()));
    assert.equal(child.systemPrompt, parent.systemPrompt);
    assert.equal(child.thinkingLevel, parent.thinkingLevel);
    assert.deepEqual(child.model, parent.model);
    await child.prompt("Run the offline implementation probe.");
    await child.waitForIdle();
    assert.equal(child.getLastAssistantText(), "Verified normal");
    assert.equal(await fs.stat(path.join(root, "denied.ts")).then(() => true, () => false), false);
    assert.equal(await fs.readFile(path.join(root, "changed.ts"), "utf8"), "implemented\n");
    assert(fork.getBranch().some(entry => entry.type === "custom" && entry.customType === "permission-hook"));
    assert(fork.getBranch().some(entry => entry.type === "custom" && entry.customType === "model-only-executed"
      && entry.data !== null && typeof entry.data === "object" && "sessionId" in entry.data && entry.data.sessionId === fork.getSessionId()));
    plan = "inline-denied";
    stage = 0;
    await child.prompt("Check the inherited inline permission.");
    await child.waitForIdle();
    assert.equal(child.getLastAssistantText(), "Verified inline-denied");
    assert.equal(await fs.stat(path.join(root, "private.ts")).then(() => true, () => false), false);

    const reloadedLoader = loader(false);
    await reloadedLoader.reload();
    assert.deepEqual(reloadedLoader.getExtensions().errors, []);
    const { session: reloaded } = await createAgentSession({ cwd: root, agentDir, modelRuntime: runtime, model, thinkingLevel: "high",
      sessionManager: branch(), resourceLoader: reloadedLoader, settingsManager: settings });
    sessions.push(reloaded);
    await reloaded.bindExtensions({});
    assert.deepEqual(reloaded.getActiveToolNames().sort(), parent.getActiveToolNames().sort());
    assert.equal(JSON.stringify(reloaded.getAllTools()), JSON.stringify(parent.getAllTools()));
    assert.deepEqual(reloadedLoader.getSkills(), parentLoader.getSkills());
    assert.equal(reloaded.systemPrompt, parent.systemPrompt);
    plan = "inline-missing";
    stage = 0;
    await reloaded.prompt("Check the same write after rediscovering resources.");
    await reloaded.waitForIdle();
    assert.equal(reloaded.getLastAssistantText(), "Verified inline-missing", JSON.stringify(reloaded.messages.at(-1)));
    assert.equal(await fs.readFile(path.join(root, "private.ts"), "utf8"), "inline protection missing\n");
    assert.deepEqual(await fs.readFile(filename), bytes, "Independent children must leave the parent transcript untouched");
  } finally {
    for (const session of sessions.reverse()) {
      try { await session.abort(); } finally { session.dispose(); }
    }
  }
}

export default function (pi: ExtensionAPI): void {
  pi.registerProvider("parley-probe-shell", {
    baseUrl: "http://127.0.0.1:1", api: "parley-probe-shell", apiKey: "offline", models: [{ ...definition, api: "parley-probe-shell", input: [...definition.input] }],
    streamSimple: () => { throw new Error("Outer probe model calls forbidden"); },
  });
  pi.registerCommand("parley-environment-probe", {
    description: "Offline normal-session environment contract probe",
    handler: async (directory) => {
      try {
        await probe(directory);
        console.log("PARLEY_ENVIRONMENT_PROBE_OK");
      } catch (error) {
        console.log("PARLEY_ENVIRONMENT_PROBE_FAILED", error);
        throw error;
      }
    },
  });
}
