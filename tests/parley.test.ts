import test from "node:test";
import type { TestContext } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import { createHash } from "node:crypto";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { setImmediate } from "node:timers/promises";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { installParley } from "../pi/parley.ts";
import { readReviewArtifact, ReviewArtifactWriter } from "../pi/artifact.ts";
import { model, resetSdk, sdk } from "./fixtures/review-sdk.ts";
import { SessionManager } from "./fixtures/parley-sdk.ts";

const hooks = registerHooks({ resolve(specifier, context, nextResolve) {
  if (specifier === "@earendil-works/pi-coding-agent") return { url: new URL("./fixtures/parley-sdk.ts", import.meta.url).href, shortCircuit: true };
  return nextResolve(specifier, context);
} });
try { await import("../pi/parley-interaction.ts"); await import("../pi/interaction.ts"); }
finally { hooks.deregister(); }

function object(value: unknown): Record<string, unknown> {
  assert(value !== null && typeof value === "object" && !Array.isArray(value));
  return value as Record<string, unknown>;
}

async function until<T>(get: () => Promise<T | undefined>): Promise<T> {
  for (let index = 0; index < 5000; index++) { const result = await get(); if (result !== undefined) return result; await setImmediate(); }
  throw new Error("Timed out waiting for deterministic local work");
}

async function fixture(t: TestContext, options: { busy?: boolean; unsupported?: boolean; captureCommit?: () => Promise<string> } = {}) {
  resetSdk();
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-implementation-"));
  const root = path.join(directory, "work"), state = path.join(directory, "state"), parentFile = path.join(directory, "parent.jsonl");
  const previousState = process.env.PARLEY_STATE_DIR;
  process.env.PARLEY_STATE_DIR = state;
  await fs.mkdir(path.join(root, ".git"), { recursive: true });
  await fs.writeFile(path.join(root, "source.ts"), "source\n");
  const parent = [{ type: "session", id: "parent" }, { type: "message", id: "user", parentId: null, message: { role: "user", content: "Inherited task" } },
    { type: "message", id: "answer", parentId: "user", message: { role: "assistant", content: [{ type: "text", text: "Inherited decision" }] } }];
  const original = parent.map(entry => JSON.stringify(entry)).join("\n") + "\n";
  await fs.writeFile(parentFile, original);
  const manager = SessionManager.open(parentFile);
  const commands = new Map<string, Parameters<ExtensionAPI["registerCommand"]>[1]>();
  const tools = new Map<string, ToolDefinition>();
  const events = new Map<string, (event: Record<string, unknown>, ctx: ExtensionCommandContext) => unknown>();
  const messages: Record<string, unknown>[] = [], notices: string[] = [];
  const statuses = new Map<string, string | undefined>();
  let unsupported = !!options.unsupported;
  const api = {
    registerCommand: (name: string, command: Parameters<ExtensionAPI["registerCommand"]>[1]) => commands.set(name, command),
    registerTool: (tool: ToolDefinition) => tools.set(tool.name, tool),
    on: (name: string, handler: (event: Record<string, unknown>, ctx: ExtensionCommandContext) => unknown) => events.set(name, handler),
    getThinkingLevel: () => "off", getActiveTools: () => ["write", "parley_interact", ...(unsupported ? ["model_only"] : [])],
    getAllTools: () => [{ name: "write", exposure: "direct" }, ...(unsupported ? [{ name: "model_only", exposure: "model-only" }] : [])],
    sendMessage: (message: Record<string, unknown>) => messages.push(message),
  } as unknown as ExtensionAPI;
  const ctx = { cwd: root, model, mode: "tui", isIdle: () => true, hasPendingMessages: () => false, sessionManager: manager,
    getSystemPrompt: () => "Inherited guidelines", modelRegistry: { find: () => model, streamSimple: () => { throw new Error("Fake SDK must never stream"); } },
    ui: { notify: (message: string) => notices.push(message), setStatus: (key: string, value: string | undefined) => statuses.set(key, value) },
  } as unknown as ExtensionCommandContext;
  const coordinator = installParley(api, { busy: () => !!options.busy, release: async () => {},
    captureCommit: options.captureCommit ?? (async () => "a".repeat(40)) });
  const controller = new AbortController();
  let running: ReturnType<ToolDefinition["execute"]> | undefined;
  const host = {
    root, state, ctx, messages, notices, statuses, coordinator,
    activateModelOnly() { unsupported = true; },
    async command(name: string, args = "") {
      const command = commands.get(name);
      assert(command, `Command ${name} is registered`);
      await command.handler(args, ctx);
    },
    async event(name: string, event: Record<string, unknown> = {}) { return events.get(name)?.(event, ctx); },
    start() {
      const message = messages.at(-1)!;
      const id = object(message.details).interactionId;
      // No forwarding context: the parent owns only the waiting host boundary.
      const toolContext = { ...ctx } as unknown as ExtensionToolContext;
      running = tools.get("parley_interact")!.execute("host", { interactionId: id }, controller.signal, undefined, toolContext);
      return running;
    },
    async artifact() {
      const files = await fs.readdir(path.join(state, "parleys"));
      return readReviewArtifact(path.join(state, "parleys", files.find(file => file.endsWith(".jsonl"))!));
    },
    async parentUnchanged() { assert.equal(await fs.readFile(parentFile, "utf8"), original); },
  };
  t.after(async () => {
    controller.abort();
    try { await coordinator.close(); await running; }
    finally {
      if (previousState === undefined) delete process.env.PARLEY_STATE_DIR; else process.env.PARLEY_STATE_DIR = previousState;
      await fs.rm(directory, { recursive: true, force: true });
    }
  });
  return host;
}

async function attach(t: TestContext, host: Awaited<ReturnType<typeof fixture>>) {
  const descriptor = await until(async () => {
    try {
      const file = (await fs.readdir(path.join(host.state, "endpoints"))).find(name => name.endsWith(".json"));
      if (file) {
        const value = object(JSON.parse(await fs.readFile(path.join(host.state, "endpoints", file), "utf8")));
        if (typeof value.socket === "string") return value;
      }
    }
    catch (error) { if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error; }
  });
  const socket = net.createConnection(String(descriptor.socket));
  const reader = createInterface({ input: socket }), lines = reader[Symbol.asyncIterator]();
  t.after(() => { reader.close(); socket.destroy(); });
  await once(socket, "connect");
  let serial = 0;
  async function request(action: string, payload: Record<string, unknown> = {}, reviewId?: string) {
    const requestId = `transport-${++serial}`;
    socket.write(JSON.stringify({ version: 1, requestId, workspace: host.root, action, reviewId,
      payload: { instanceId: descriptor.instanceId, sessionId: "parent", editorId: "editor", nonce: requestId, ...payload } }) + "\n");
    for (;;) {
      const line = await lines.next(); assert(!line.done);
      const response = object(JSON.parse(line.value));
      if (response.action === "bridge-ping") {
        socket.write(JSON.stringify({ version: 1, requestId: response.requestId, ok: true, result: {
          version: 1, workspace: host.root, instanceId: descriptor.instanceId, sessionId: "parent", editorId: "editor", nonce: object(response.payload).nonce,
        } }) + "\n");
        continue;
      }
      assert.equal(response.requestId, requestId);
      assert.equal(response.ok, true, String(response.error));
      return object(object(response.result).data ?? {});
    }
  }
  await request("bridge-attach", { label: "Neovim" });
  const info = await request("review-info");
  assert.equal(info.workflow, "parley");
  return {
    info,
    status: () => request("review-info"),
    send: (action: string, payload: Record<string, unknown> = {}) => request(action, payload, String(info.reviewId)),
    async turn(id = "turn") {
      const batch = { workspace: host.root, sessionId: "parent", editorId: "editor",
        conversations: [{ id: "note", anchor: { path: "source.ts", side: "workspace", first: 1, last: 1, lines: ["source"], observedAt: 1,
          source: { kind: "editor", editorId: "editor", bufferId: 1, changedTick: 1 } }, placement: { first: 1, last: 1 } }],
        messages: [{ id: "instruction", conversationId: "note", requestId: id, parentId: null, role: "human", author: "Human", origin: "editor/editor", createdAt: 1,
          lines: ["Make the localized edit"], version: 1, supersedes: [], replacesId: null }],
        request: { id, kind: "ask", instructions: null, submissions: [{ conversationId: "note", baseVersion: 0, baseTipId: null, messageIds: ["instruction"], version: 1, tipId: "instruction" }] } };
      const bytes = Buffer.from(JSON.stringify(batch)), digest = createHash("sha256").update(bytes).digest("hex");
      await request("review-batch-begin", { batchId: id, preparationId: info.preparationId, bytes: bytes.length, parts: 1, digest }, String(info.reviewId));
      await request("review-batch-chunk", { batchId: id, index: 0, hex: bytes.toString("hex") }, String(info.reviewId));
      const accepted = await request("review-batch-commit", { batchId: id, digest }, String(info.reviewId));
      assert.equal(accepted.status, "accepted");
      await until(async () => (await host.artifact()).requests.find(item => item.record.id === id)?.outcome);
      // The outcome is durable before execution/acceptance promises settle.
      // Done intentionally rejects that interval; wait for the public idle bit.
      await until(async () => (await request("review-info")).busy === false ? true : undefined);
    },
    async done() {
      const begin = await request("review-finish-begin", { finishId: "finish" }, String(info.reviewId));
      assert.equal(begin.state, "wrapping");
      return until(async () => {
        const value = await request("review-finish-status", { finishId: "finish" }, String(info.reviewId));
        return value.state === "wrapping" ? undefined : value;
      });
    },
  };
}


test("/parley without submissions starts no child and durably returns to the exact parent", async t => {
  const host = await fixture(t);
  await host.command("parley");
  assert.equal(host.messages.length, 1);
  assert.equal(host.messages[0].display, false);
  assert.equal(sdk.creations, 0);
  const running = host.start();
  const editor = await attach(t, host);
  assert.equal(sdk.creations, 0, "Pairing starts no child model");
  assert.equal(object(await host.event("tool_call", { toolName: "write" })).block, true);
  assert.equal(object(await host.event("tool_call", { toolName: "write", parentToolCallId: "host" })).block, true);
  assert.equal(object(await host.event("tool_call", { toolName: "write", parentToolCallId: "hostile" })).block, true);
  assert.equal(object(await host.event("tool_call", { toolName: "parley_prepare", parentToolCallId: "host" })).block, true);
  await assert.rejects(host.event("user_bash"), /owns execution/);
  const entered = await host.event("input", { source: "interactive" });
  assert.equal(object(entered).action, "handled");
  const completion = await editor.done();
  assert.equal(completion.state, "completed");
  const result = await running;
  assert(result.content[0]?.type === "text" && result.content[0].text.includes("No implementation turns were submitted"));
  assert.equal(host.coordinator.active(), false);
  assert.equal(sdk.creations, 0);
  const saved = await editor.send("review-finish-status", { finishId: "finish" });
  assert.equal(saved.summary, completion.summary, "Saved recap reads do not regenerate");
  await host.parentUnchanged();
});

test("/parley-stop is the only stop command and permits a fresh interaction after withdrawal without recap", async t => {
  const host = await fixture(t);
  await host.command("parley");
  const running = host.start();
  await attach(t, host);
  const before = await host.artifact();
  const pathBefore = path.join(host.state, "parleys", `${before.header.id}.jsonl`);
  await assert.rejects(host.command("parley-cancel"), /Command parley-cancel is registered/);
  assert.equal(host.coordinator.active(), true, "The removed alias must not stop the interaction");
  assert.equal(await fs.readFile(path.join(host.root, "source.ts"), "utf8"), "source\n");
  // A hosted interaction makes the real parent busy; stop must not require idle.
  host.ctx.isIdle = () => false;
  await host.command("parley-stop");
  assert.equal(host.coordinator.active(), false, "Command acknowledgment follows cleanup");
  assert.deepEqual(await fs.readdir(path.join(host.state, "endpoints")), []);
  assert.equal(host.statuses.get("parley-implementation"), undefined);
  const stopped = await running;
  assert.equal(stopped.isError, true);
  assert.equal(stopped.terminate, true, "Do not ask the parent model for an automatic wrap-up");
  assert(stopped.content[0]?.type === "text" && stopped.content[0].text.includes("no rollback"));
  const artifact = await host.artifact();
  assert.deepEqual(artifact.records.slice(0, before.records.length), before.records);
  assert.equal(artifact.requests.length, 0);
  assert.equal(artifact.end, undefined);
  assert(artifact.sessions.every(session => session.end));
  assert.equal(sdk.creations, 0);
  assert.equal(host.messages.length, 1, "Stop sends no extra parent message");
  assert.match(String(host.notices.at(-1)), /stopped without wrap-up/);
  const saved = await fs.readFile(pathBefore);
  await host.command("parley-stop");
  assert.match(String(host.notices.at(-1)), /No active Parley/);
  host.ctx.isIdle = () => true;
  await host.command("parley");
  assert.equal(host.coordinator.active(), true);
  assert.notEqual(object(host.messages[0].details).interactionId, object(host.messages[1].details).interactionId);
  assert.deepEqual(await fs.readFile(pathBefore), saved);
  await host.parentUnchanged();
});

test("/parley-stop rejects foreign parents, arguments and initialization without queuing withdrawal", async t => {
  const captured = Promise.withResolvers<void>();
  const release = Promise.withResolvers<string>();
  t.after(() => release.resolve("a".repeat(40)));
  const host = await fixture(t, { captureCommit: async () => { captured.resolve(); return release.promise; } });
  await host.command("parley");
  await host.command("parley-stop");
  assert.match(String(host.notices.at(-1)), /not initialization/);
  assert.equal(host.coordinator.active(), true);
  const running = host.start();
  await captured.promise;
  await host.command("parley-stop");
  assert.match(String(host.notices.at(-1)), /not initialization/);
  release.resolve("a".repeat(40));
  const editor = await attach(t, host);
  const before = await host.artifact();
  await host.command("parley-stop", "a reason is not accepted");
  assert.match(String(host.notices.at(-1)), /without arguments/);
  const getSessionId = host.ctx.sessionManager.getSessionId.bind(host.ctx.sessionManager);
  host.ctx.sessionManager.getSessionId = () => "another-parent";
  try {
    await host.command("parley-stop");
    assert.match(String(host.notices.at(-1)), /requires the originating Pi session/);
  } finally {
    host.ctx.sessionManager.getSessionId = getSessionId;
  }
  assert.deepEqual((await host.artifact()).records, before.records);
  assert.equal((await editor.status()).ended, false);
  const entered = await host.event("input", { source: "interactive" });
  assert.equal(object(entered).action, "handled");
  assert.match(String(host.notices.at(-1)), /\/parley-stop here/);
  await host.command("parley-stop");
  assert.equal((await running).isError, true);
});

test("/parley-stop does not cancel or relabel an accepted Done", async t => {
  const host = await fixture(t);
  await host.command("parley");
  const running = host.start();
  const editor = await attach(t, host);
  await editor.send("review-finish-begin", { finishId: "finish" });
  await host.command("parley-stop");
  assert.match(String(host.notices.at(-1)), /wrap-up is active|already completed|No active Parley/);
  const completion = await until(async () => {
    const result = await editor.send("review-finish-status", { finishId: "finish" });
    return result.state === "wrapping" ? undefined : result;
  });
  assert.equal(completion.state, "completed");
  assert.equal((await running).isError, undefined);
  const evidence = await host.artifact();
  assert(evidence.end);
  assert.equal(evidence.requests[0].outcome?.status, "completed");
});

test("fork capture compares persisted JSON without treating optional undefined fields as lost context", async t => {
  const host = await fixture(t);
  const branch = host.ctx.sessionManager.getBranch.bind(host.ctx.sessionManager);
  host.ctx.sessionManager.getBranch = leaf => branch(leaf).map(entry => ({ ...entry, details: undefined }));
  await host.command("parley");
  assert.equal(host.messages.length, 1);
  assert.equal(sdk.creations, 0);
  await host.parentUnchanged();
});

test("fork capture rejects genuinely unpersisted parent context", async t => {
  const host = await fixture(t);
  const branch = host.ctx.sessionManager.getBranch.bind(host.ctx.sessionManager);
  host.ctx.sessionManager.getBranch = leaf => branch(leaf).filter(entry => entry.id !== "user");
  await host.command("parley");
  assert.equal(host.messages.length, 0);
  assert(host.notices.some(message => message.includes("has not persisted")));
  assert.equal(sdk.creations, 0);
  await host.parentUnchanged();
});

test("an open review rejects /parley without starting another owner", async t => {
  const host = await fixture(t, { busy: true });
  await host.command("parley"); assert.equal(host.messages.length, 0);
});

test("active model-only tools no longer reject normal child setup", async t => {
  const host = await fixture(t, { unsupported: true });
  await host.command("parley");
  assert.equal(host.messages.length, 1);
  assert.equal(host.coordinator.active(), true);
  assert.equal(sdk.creations, 0);
  await host.parentUnchanged();
});

test("parent capability changes do not gate the normal child at the host boundary", async t => {
  const host = await fixture(t);
  await host.command("parley");
  assert.equal(host.messages.length, 1);
  host.activateModelOnly();
  const running = host.start();
  await attach(t, host);
  await host.command("parley-stop");
  const stopped = await running;
  assert.equal(stopped.isError, true);
  assert(stopped.content[0]?.type === "text" && stopped.content[0].text.includes("cancelled"));
  assert.equal(host.coordinator.active(), false);
  assert.equal(sdk.creations, 0);
  await host.parentUnchanged();
});

test("review artifacts cannot acquire implementation authority", async t => {
  const host = await fixture(t);
  const writer = await ReviewArtifactWriter.create({ type: "review", schemaVersion: 1, id: "readonly", workspace: host.root, startingCommit: "a".repeat(40), createdAt: 1 });
  t.after(() => writer.close());
  await assert.rejects(writer.append([{ type: "session", id: "implementation", reviewId: "readonly", createdAt: 1, role: "implementation", sessionId: "child", transcriptPath: path.join(host.state, "child.jsonl"),
    startEntryId: null, parentSessionRecordId: "parent", model: { provider: model.provider, modelId: model.id, thinkingLevel: "off" } }]), /workflow authority/);
});
