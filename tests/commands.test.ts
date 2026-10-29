import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import extension from "../pi/extension.ts";
import { model, resetSdk } from "./fixtures/review-sdk.ts";
import { SessionManager } from "./fixtures/parley-sdk.ts";

const hooks = registerHooks({ resolve(specifier, context, nextResolve) {
  if (specifier === "@earendil-works/pi-coding-agent") {
    return { url: new URL("./fixtures/parley-sdk.ts", import.meta.url).href, shortCircuit: true };
  }
  return nextResolve(specifier, context);
} });
try { await import("../pi/parley-interaction.ts"); await import("../pi/interaction.ts"); }
finally { hooks.deregister(); }

test("one Pi command completes subcommands, validates arguments, and routes implementation controls", { timeout: 15_000 }, async t => {
  resetSdk();
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-commands-"));
  const root = path.join(directory, "work"), state = path.join(directory, "state");
  const parentFile = path.join(directory, "parent.jsonl");
  const previousState = process.env.PARLEY_STATE_DIR;
  process.env.PARLEY_STATE_DIR = state;
  await fs.mkdir(path.join(root, ".git"), { recursive: true });
  await fs.writeFile(parentFile, [
    { type: "session", id: "parent" },
    { type: "message", id: "user", parentId: null, message: { role: "user", content: "Implement the editor instructions" } },
  ].map(entry => JSON.stringify(entry)).join("\n") + "\n");
  const commands = new Map<string, Parameters<ExtensionAPI["registerCommand"]>[1]>();
  const tools = new Map<string, ToolDefinition>();
  const events = new Map<string, (_event: unknown, ctx: ExtensionCommandContext) => unknown>();
  const notices: string[] = [], messages: Array<{ details?: { interactionId?: string } }> = [];
  const statuses = new Map<string, string | undefined>();
  let notifyReady: () => void;
  const ready = new Promise<void>(resolve => { notifyReady = resolve; });
  const api = {
    registerFlag() {}, getFlag: () => "none", getThinkingLevel: () => "off",
    registerCommand: (name: string, command: Parameters<ExtensionAPI["registerCommand"]>[1]) => commands.set(name, command),
    registerTool: (tool: ToolDefinition) => tools.set(tool.name, tool),
    on: (name: string, handler: (_event: unknown, ctx: ExtensionCommandContext) => unknown) => events.set(name, handler),
    exec: async () => ({ code: 0, killed: false, stdout: "a".repeat(40), stderr: "" }),
    getActiveTools: () => ["write", "parley_interact"],
    getAllTools: () => [{ name: "write", exposure: "direct" }],
    sendMessage: (message: typeof messages[number]) => messages.push(message),
  } as unknown as ExtensionAPI;
  const ctx = {
    cwd: root, model, mode: "tui", isIdle: () => true, hasPendingMessages: () => false,
    sessionManager: SessionManager.open(parentFile),
    getSystemPrompt: () => "Inherited guidelines",
    modelRegistry: { find: () => model, streamSimple: () => { throw new Error("No live model calls allowed"); } },
    ui: { notify: (message: string) => notices.push(message),
      setStatus: (key: string, value: string | undefined) => {
        statuses.set(key, value);
        if (key === "parley-implementation" && value) notifyReady();
      } },
  } as unknown as ExtensionCommandContext;
  const controller = new AbortController();
  let running: ReturnType<ToolDefinition["execute"]> | undefined;
  t.after(async () => {
    controller.abort();
    try { await events.get("session_shutdown")?.({}, ctx); await running; }
    finally {
      if (previousState === undefined) delete process.env.PARLEY_STATE_DIR;
      else process.env.PARLEY_STATE_DIR = previousState;
      await fs.rm(directory, { recursive: true, force: true });
    }
  });
  extension(api);
  assert.deepEqual([...commands.keys()], ["parley"], "Legacy commands are not registered");
  const command = commands.get("parley")!;
  const complete = command.getArgumentCompletions!;
  assert.deepEqual((await complete(""))?.map(item => item.value), ["review", "stop", "done"]);
  assert.deepEqual((await complete("st"))?.map(item => item.value), ["stop"]);
  assert.deepEqual((await complete("d"))?.map(item => item.value), ["done"]);
  assert.deepEqual((await complete("rev"))?.map(item => item.value), ["review"]);
  for (const prefix of ["unknown", "stop ", "done saved-id", "review "]) {
    assert.equal(await complete(prefix), null);
  }
  for (const invalid of ["unknown", "review extra", "stop one two", "done one two"]) {
    await command.handler(invalid, ctx);
    assert.match(notices.at(-1)!, /Use \/parley/);
    assert.equal(messages.length, 0);
    await assert.rejects(fs.stat(state), { code: "ENOENT" });
  }

  await command.handler("", ctx);
  const interactionId = messages.at(-1)?.details?.interactionId;
  assert.equal(typeof interactionId, "string", "Bare /parley starts implementation");
  running = tools.get("parley_interact")!.execute("host", { interactionId }, controller.signal,
    undefined, { ...ctx } as unknown as ExtensionToolContext);
  // Wait for publication or an explicit startup failure, not a timing delay.
  await Promise.race([ready, running.then(result => { throw new Error(JSON.stringify(result)); })]);
  assert.match(statuses.get("parley-implementation")!, /:Parley start/);
  await command.handler("done", ctx);
  assert.match(notices.at(-1)!, /Finish implementation in Neovim with :Parley done/);
  assert(statuses.get("parley-implementation"));
  await command.handler("stop stale-review", ctx);
  assert.match(notices.at(-1)!, /without arguments/);
  assert(statuses.get("parley-implementation"), "An ID cannot cancel implementation");
  await command.handler("stop", ctx);
  assert.match(notices.at(-1)!, /stopped without wrap-up/);
  assert.equal(statuses.get("parley-implementation"), undefined);
  assert.equal((await running).isError, true);
});
