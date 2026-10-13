import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";

// Exercise the installed host, not a hand-written imitation of its extension context.
// Isolated RPC commands use an in-memory provider: no network or personal resources.
test("installed Pi resolves Parley's own flag and makes isolated, tool-free nested model calls", { timeout: 20_000 }, async t => {
  try { await promisify(execFile)("pi", ["--version"]); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") { t.skip("Pi peer is not installed"); return; } throw error; }
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "parley-host-"));
  let stop: (() => Promise<void>) | undefined;
  t.after(async () => { try { await stop?.(); } finally { await fs.rm(dir, { recursive: true, force: true }); } });
  const probe = path.join(dir, "probe.ts"), result = path.join(dir, "result.json");
  await fs.writeFile(probe, `
import { writeFileSync } from "node:fs";
import { createAssistantMessageEventStream, getCurrentSystemPrompt, getCurrentTools } from "@earendil-works/pi-ai";
import parley from ${JSON.stringify(path.resolve("pi/extension.ts"))};
export default function(pi) {
  parley(pi);
  const requests = [];
  pi.registerProvider("parley-offline", {
    api: "parley-offline", apiKey: "unused-offline-fixture", baseUrl: "https://offline.invalid",
    models: ["fast", "review"].map(id => ({ id, name: id, reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 8192 })),
    streamSimple(model, context) {
      requests.push({ model: model.id, system: getCurrentSystemPrompt(context.messages), tools: getCurrentTools(context.messages).length, users: context.messages.filter(m => m.role === "user").map(m => m.content) });
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const message = { role: "assistant", content: [{ type: "text", text: "" }], api: model.api, provider: model.provider, model: model.id, stopReason: "pending", timestamp: Date.now(), usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
        stream.push({ type: "start", partial: message });
        stream.push({ type: "text_start", contentIndex: 0, partial: message });
        message.content[0].text = "[]";
        stream.push({ type: "text_delta", contentIndex: 0, delta: "[]", partial: message });
        stream.push({ type: "text_end", contentIndex: 0, content: "[]", partial: message });
        message.stopReason = "stop";
        stream.push({ type: "done", reason: "stop", message }); stream.end();
      });
      return stream;
    }
  });
  pi.registerCommand("probe", { handler: async (_, ctx) => {
    const selected = ctx.model, branch = JSON.stringify(ctx.sessionManager.getBranch());
    for (const id of ["fast", "review"]) {
      const response = await ctx.modelRegistry.streamSimple(ctx.modelRegistry.find("parley-offline", id), { systemPrompt: "Read-only " + id, messages: [{ role: "user", content: "Frozen " + id, timestamp: Date.now() }] }).result();
      if (response.stopReason !== "stop" || response.content[0].text !== "[]") throw new Error("Invalid offline stream response");
    }
    writeFileSync(${JSON.stringify(result)}, JSON.stringify({
      flag: pi.getFlag("parley-preparation-model"),
      getBranch: typeof ctx.sessionManager.getBranch,
      getSessionId: typeof ctx.sessionManager.getSessionId,
      getLeafId: typeof ctx.sessionManager.getLeafId,
      find: typeof ctx.modelRegistry.find,
      available: ctx.modelRegistry.getAvailable().filter(model => model.provider === "parley-offline").map(model => model.provider + "/" + model.id).sort(),
      streamSimple: typeof ctx.modelRegistry.streamSimple,
      skills: ctx.getSystemPromptOptions().skills,
      requests, selectedUnchanged: ctx.model === selected, branchUnchanged: JSON.stringify(ctx.sessionManager.getBranch()) === branch
    }));
  }});
}`);
  const child = spawn("pi", ["--mode", "rpc", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates", "-e", probe, "--parley-preparation-model", "test/fast"], {
    cwd: dir, env: { ...process.env, PI_CODING_AGENT_DIR: path.join(dir, "agent"), PARLEY_STATE_DIR: path.join(dir, "state") }, stdio: ["pipe", "pipe", "pipe"],
  });
  let output = "", errors = "";
  const exited = new Promise(resolve => child.once("exit", resolve));
  child.stdout.on("data", data => { output += data; });
  child.stderr.on("data", data => { errors += data; });
  stop = async () => { child.kill("SIGTERM"); await exited; };
  const request = async (command: Record<string, unknown>) => {
    child.stdin.write(JSON.stringify(command) + "\n");
    for (let n = 0; n < 200; n++) {
      const response = output.split("\n").slice(0, -1).filter(Boolean).map(line => JSON.parse(line)).find(message => message.type === "response" && message.id === command.id);
      if (response) { assert(response.success, JSON.stringify(response)); return response; }
      assert.equal(child.exitCode, null, errors || output);
      await new Promise(resolve => setTimeout(resolve, 25));
    }
    assert.fail("Pi did not acknowledge RPC command: " + (errors || output));
  };
  const response = await request({ type: "get_commands", id: "commands" });
  assert.equal(response.data.commands.filter((command: { name: string }) => command.name === "review").length, 1);
  assert.equal(response.data.commands.filter((command: { name: string }) => command.name === "end-review").length, 0);
  await request({ type: "prompt", id: "probe", message: "/probe" });
  const host = JSON.parse(await fs.readFile(result, "utf8"));
  assert.equal(host.flag, "test/fast");
  assert.deepEqual(host.available, ["parley-offline/fast", "parley-offline/review"]);
  for (const method of ["getBranch", "getSessionId", "getLeafId", "find", "streamSimple"]) assert.equal(host[method], "function", method);
  assert.deepEqual(host.skills, []);
  assert.equal(host.selectedUnchanged, true);
  assert.equal(host.branchUnchanged, true);
  assert.deepEqual(host.requests, [
    { model: "fast", system: "Read-only fast", tools: 0, users: ["Frozen fast"] },
    { model: "review", system: "Read-only review", tools: 0, users: ["Frozen review"] },
  ]);
  assert(!output.includes('"type":"extension_error"'), output);
});
