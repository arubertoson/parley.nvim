import test from "node:test";
import type { TestContext } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { once } from "node:events";
import { createHash } from "node:crypto";
import { createInterface } from "node:readline";
import { registerHooks } from "node:module";
import { setImmediate, setTimeout } from "node:timers/promises";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import extension from "../pi/extension.ts";
import { readReviewArtifact } from "../pi/artifact.ts";
import { model, resetSdk, sdk } from "./fixtures/review-sdk.ts";

// Only Pi and its SDK are substituted. Commands, sockets, acceptance, artifact
// persistence and reviewer policy run unchanged, without credentials or a model.
const hooks = registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "@earendil-works/pi-coding-agent") {
      return { url: new URL("./fixtures/review-sdk.ts", import.meta.url).href, shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
});
try {
  await import("../pi/interaction.ts");
} finally {
  hooks.deregister();
}

const handoff = { objective: "Review extension", scope: ["pi/extension.ts"], decisions: [], guidelines: [], context: [] };
const commitResult = { code: 0, killed: false, stdout: "a".repeat(40), stderr: "" };

type ParentHost = {
  readonly root: string;
  readonly state: string;
  readonly notices: string[];
  readonly messages: unknown[];
  readonly messageOptions: unknown[];
  readonly statuses: Map<string, string | undefined>;
  command(name: string, args?: string): Promise<void>;
  tool(name: string, value: unknown, signal?: AbortSignal): ReturnType<ToolDefinition["execute"]>;
  event(name: "session_start" | "session_shutdown"): Promise<void>;
};

type HostOptions = {
  readonly exec?: ExtensionAPI["exec"];
  readonly getLeafId?: () => string | null;
  readonly getModel?: () => ExtensionContext["model"];
  readonly getSessionFile?: () => string | undefined;
  readonly getThinkingLevel?: ExtensionAPI["getThinkingLevel"];
  readonly getCwd?: (root: string) => string;
};

async function createParentHost(t: TestContext, options: HostOptions = {}): Promise<ParentHost> {
  resetSdk();
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "parley-extension-"));
  const root = path.join(dir, "work");
  const state = path.join(dir, "state");
  const previousState = process.env.PARLEY_STATE_DIR;
  const commands = new Map<string, Parameters<ExtensionAPI["registerCommand"]>[1]>();
  const tools = new Map<string, ToolDefinition>();
  const events = new Map<string, (_event: unknown, ctx: ExtensionContext) => Promise<void>>();
  const notices: string[] = [];
  const messages: unknown[] = [];
  const messageOptions: unknown[] = [];
  const statuses = new Map<string, string | undefined>();
  // No internal collaborators are mocked. Parent commands use the real owners,
  // sockets and artifacts; accepted requests use the offline SDK boundary fake.
  const api = {
    registerFlag() {}, getFlag: () => "none", getThinkingLevel: options.getThinkingLevel ?? (() => "off"),
    registerCommand: (name: string, command: Parameters<ExtensionAPI["registerCommand"]>[1]) => commands.set(name, command),
    registerTool: (tool: ToolDefinition) => tools.set(tool.name, tool),
    on: (name: string, handler: (_event: unknown, ctx: ExtensionContext) => Promise<void>) => events.set(name, handler),
    exec: options.exec ?? (async () => commitResult),
    sendMessage(message: unknown, options: unknown) { messages.push(message); messageOptions.push(options); },
  } as unknown as ExtensionAPI;
  const ctx = {
    get cwd() { return options.getCwd ? options.getCwd(root) : root; },
    mode: "tui",
    get model() { return options.getModel ? options.getModel() : model; },
    isIdle: () => true, hasPendingMessages: () => false,
    sessionManager: {
      getSessionId: () => "parent",
      getSessionFile: options.getSessionFile ?? (() => path.join(dir, "parent.jsonl")),
      getLeafId: options.getLeafId ?? (() => "parent-entry"),
    },
    ui: { notify: (message: string) => notices.push(message),
      setStatus: (key: string, value: string | undefined) => statuses.set(key, value) },
  } as unknown as ExtensionCommandContext;
  const host: ParentHost = {
    root, state, notices, messages, messageOptions, statuses,
    async command(name, args = "") {
      const command = commands.get(name);
      assert(command, `Command ${name} is registered`);
      await command.handler(args, ctx);
    },
    async tool(name, value, signal) {
      const tool = tools.get(name);
      assert(tool, `Tool ${name} is registered`);
      const toolContext: ExtensionToolContext = {
        ...ctx,
        tools: [],
        executeTool: async () => { throw new Error("Unexpected nested tool execution in parent fixture"); },
      };
      return tool.execute("test-call", value, signal, undefined, toolContext);
    },
    async event(name) {
      const handler = events.get(name);
      assert(handler, `Event ${name} is registered`);
      await handler({ type: name }, ctx);
    },
  };
  t.after(async () => {
    try {
      await host.event("session_shutdown");
    } finally {
      if (previousState === undefined) delete process.env.PARLEY_STATE_DIR;
      else process.env.PARLEY_STATE_DIR = previousState;
      await fs.rm(dir, { recursive: true, force: true });
    }
  });
  await fs.mkdir(path.join(root, ".git"), { recursive: true });
  process.env.PARLEY_STATE_DIR = state;
  extension(api);
  await host.event("session_start");
  return host;
}

function object(value: unknown): Record<string, unknown> {
  assert(value !== null && typeof value === "object" && !Array.isArray(value));
  return value as Record<string, unknown>;
}

async function currentArtifact(host: ParentHost) {
  const files = await fs.readdir(path.join(host.state, "reviews"));
  assert.equal(files.length, 1);
  const filename = path.join(host.state, "reviews", files[0]);
  return { filename, snapshot: await readReviewArtifact(filename) };
}

// A real editor connection, including the challenge/response attach protocol.
async function attachEditor(t: TestContext, host: ParentHost) {
  const [lease] = await fs.readdir(path.join(host.state, "endpoints"));
  const descriptor = object(JSON.parse(await fs.readFile(path.join(host.state, "endpoints", lease), "utf8")));
  assert.equal(typeof descriptor.socket, "string");
  const socket = net.createConnection(String(descriptor.socket));
  const reader = createInterface({ input: socket });
  const lines = reader[Symbol.asyncIterator]();
  t.after(() => {
    reader.close();
    socket.destroy();
  });
  await once(socket, "connect");
  let serial = 0;
  async function exchange(action: string, payload: Readonly<Record<string, unknown>>, reviewId?: string) {
    const requestId = `transport-${++serial}`;
    const envelope = {
      version: 1,
      requestId,
      workspace: host.root,
      action,
      reviewId,
      payload: {
        instanceId: descriptor.instanceId,
        sessionId: descriptor.sessionId,
        editorId: "editor",
        nonce: requestId,
        ...payload,
      },
    };
    socket.write(JSON.stringify(envelope) + "\n");
    for (;;) {
      const line = await lines.next();
      assert(!line.done, "Socket closed before the response");
      const response = object(JSON.parse(line.value));
      if (response.action === "bridge-ping") {
        const challenge = object(response.payload);
        const answer = {
          version: 1,
          requestId: response.requestId,
          ok: true,
          result: {
            version: 1,
            workspace: host.root,
            instanceId: descriptor.instanceId,
            sessionId: descriptor.sessionId,
            editorId: "editor",
            nonce: challenge.nonce,
          },
        };
        socket.write(JSON.stringify(answer) + "\n");
        continue;
      }
      assert.equal(response.requestId, requestId);
      assert.equal(response.ok, true, String(response.error));
      return object(response.result);
    }
  }
  await exchange("bridge-attach", { label: "Test editor" });
  return {
    socket,
    disconnect() { socket.destroy(); },
    async request(action: string, payload: Readonly<Record<string, unknown>> = {}, reviewId?: string) {
      const response = await exchange(action, payload, reviewId);
      return object(response.data);
    },
  };
}

test("pickup and cancellation reject malformed exact IDs before looking up an owner", async t => {
  const host = await createParentHost(t);
  for (const value of [null, [], "review"]) {
    await assert.rejects(host.tool("parley_cancel", value), /Expected cancellation IDs/);
    await assert.rejects(host.tool("parley_pickup", value), /Expected the exact review ID/);
  }
  for (const reviewId of [undefined, 12, "", "with space", "a".repeat(129)]) {
    await assert.rejects(host.tool("parley_cancel", { reviewId, requestId: "request" }), /Invalid exact review\/request/);
    await assert.rejects(host.tool("parley_pickup", { reviewId }), /Invalid exact review ID/);
  }
  for (const requestId of [null, 12, "", "with space", "a".repeat(129)]) {
    await assert.rejects(host.tool("parley_cancel", { reviewId: "review", requestId }), /Invalid exact review\/request/);
  }
  await assert.rejects(host.tool("parley_cancel", { reviewId: "review", requestId: "request", extra: true }), /Invalid exact/);
  await assert.rejects(host.tool("parley_pickup", { reviewId: "review", extra: true }), /Invalid exact/);
  for (const reviewId of ["a", "AZ_09-", "a".repeat(128)]) {
    await assert.rejects(host.tool("parley_cancel", { reviewId, requestId: reviewId }), /No matching parent review owner/);
    await assert.rejects(host.tool("parley_pickup", { reviewId }), /No available originating parent review owner/);
  }
});

test("/parley review initializes durable context-free evidence and captures Git or jj commits only once", async t => {
  const calls: Parameters<ExtensionAPI["exec"]>[] = [];
  let result = commitResult;
  const host = await createParentHost(t, {
    exec: async (...args) => { calls.push(args); return result; },
  });
  await assert.rejects(fs.access(host.state), { code: "ENOENT" });
  for (const failure of [
    { ...commitResult, code: 1 },
    { ...commitResult, killed: true },
    { ...commitResult, stdout: "not-a-commit" },
  ]) {
    result = failure;
    await host.command("parley", "review");
    assert.match(String(host.notices.at(-1)), /Cannot capture the starting commit/);
    assert.deepEqual(await fs.readdir(host.state), ["endpoints"]);
  }
  result = { ...commitResult, stdout: ` ${"b".repeat(40)}\n` };
  await host.command("parley", "review");
  assert.deepEqual(calls.at(-1), ["git", ["rev-parse", "HEAD"], { cwd: host.root, timeout: 10_000, signal: undefined }]);
  const { filename: artifactPath, snapshot: artifact } = await currentArtifact(host);
  assert.deepEqual(artifact.records.map(record => record.type), ["review", "session", "preparation"]);
  assert.deepEqual(artifact.preparations[0].context, []);
  assert.deepEqual(artifact.preparations[0].guidelines, []);
  assert.deepEqual(artifact.preparations[0].decisions, []);
  assert.deepEqual(artifact.preparations[0].scope, []);
  assert.deepEqual(artifact.sessions[0].record.model, { provider: model.provider, modelId: model.id, thinkingLevel: "off" });
  assert.equal(sdk.creations, 0);

  const callsBeforeRepeat = calls.length;
  await host.command("parley", "review");
  assert.equal(calls.length, callsBeforeRepeat, "Repeated /parley review does not reinitialize an open review");
  assert.deepEqual((await readReviewArtifact(artifactPath)).records, artifact.records);
  assert.equal(artifact.header.startingCommit, "b".repeat(40));
  const evidence = await fs.readFile(artifactPath);
  const pickup = await host.tool("parley_pickup", { reviewId: artifact.header.id });
  assert.deepEqual(pickup.details, {
    reviewId: artifact.header.id, artifactPath,
    recordCount: artifact.records.length, lastRecordId: artifact.records.at(-1)?.id,
  });
  assert.deepEqual(await fs.readFile(artifactPath), evidence, "Pickup does not append or rewrite evidence");

  await host.command("parley", "done");
  await fs.mkdir(path.join(host.root, ".jj"));
  await host.command("parley", "review");
  assert.deepEqual(calls.at(-1), ["jj", ["--ignore-working-copy", "log", "-r", "@", "--no-graph", "-T", "commit_id"],
    { cwd: host.root, timeout: 10_000, signal: undefined }]);
  assert.equal((await fs.readdir(path.join(host.state, "reviews"))).length, 2);
  assert.equal(sdk.creations, 0, "Neither initialization nor empty completion creates a reviewer");
  const cancelled = new AbortController();
  cancelled.abort();
  await assert.rejects(host.tool("parley_pickup", { reviewId: artifact.header.id }, cancelled.signal), /No available originating/);
});

test("initialization blocks requests and Done until durable readiness, without starting a reviewer", async t => {
  const started = Promise.withResolvers<void>();
  const commit = Promise.withResolvers<typeof commitResult>();
  const host = await createParentHost(t, {
    exec: async () => { started.resolve(); return commit.promise; },
  });
  const startup = host.command("parley", "review");
  try {
    await started.promise;
    const editor = await attachEditor(t, host);
    await assert.rejects(editor.request("review-info"), /initialization is active/);
    await host.command("parley", "done");
    assert.match(String(host.notices.at(-1)), /Nothing queued/);
    await host.command("parley", "stop");
    assert.match(String(host.notices.at(-1)), /Nothing queued or cancelled/);
    await host.command("parley", "review");
    assert.match(String(host.notices.at(-1)), /busy/);
    assert.equal(sdk.creations, 0);
    commit.resolve(commitResult);
    await startup;
    assert.equal((await editor.request("review-info")).ended, false);
  } finally {
    commit.resolve(commitResult);
    await startup;
  }
});

test("a fresh /parley review retains exact old completion reads while its new identity initializes", async t => {
  const started = Promise.withResolvers<void>();
  const commit = Promise.withResolvers<typeof commitResult>();
  let startingFresh = false;
  const host = await createParentHost(t, {
    exec: async () => {
      if (startingFresh) {
        started.resolve();
        return commit.promise;
      }
      return commitResult;
    },
  });
  await host.command("parley", "review");
  const editor = await attachEditor(t, host);
  const firstInfo = await editor.request("review-info");
  const reviewId = String(firstInfo.reviewId);
  await host.command("parley", "done");
  const { filename, snapshot } = await currentArtifact(host);
  const finishId = snapshot.requests[0].record.id;
  const savedEvidence = await fs.readFile(filename);

  startingFresh = true;
  const startup = host.command("parley", "review");
  try {
    await started.promise;
    await assert.rejects(editor.request("review-info"), /initialization is active/);
    const previous = await editor.request("review-finish-status", { finishId }, reviewId);
    assert.equal(previous.summary, snapshot.end?.summary);
    await assert.rejects(editor.request("review-batch-begin", {}, reviewId), /Review is completed/);
    commit.resolve(commitResult);
    await startup;
    const fresh = await editor.request("review-info");
    assert.notEqual(fresh.reviewId, reviewId);
    assert.equal(fresh.ended, false);
    assert.deepEqual(await fs.readFile(filename), savedEvidence);
    assert.equal(sdk.creations, 0);
  } finally {
    commit.resolve(commitResult);
    await startup;
  }
});

test("a session change during /parley review initialization withdraws the offer without publishing evidence", async t => {
  const started = Promise.withResolvers<void>();
  const commit = Promise.withResolvers<typeof commitResult>();
  const host = await createParentHost(t, {
    exec: async () => { started.resolve(); return commit.promise; },
  });
  const startup = host.command("parley", "review");
  await started.promise;
  const withdrawn = assert.rejects(host.event("session_start"), /Review is busy; preparation was not queued/);
  commit.resolve(commitResult);
  await Promise.all([startup, withdrawn]);
  assert.deepEqual(await fs.readdir(host.state), ["endpoints"]);
  assert.deepEqual(await fs.readdir(path.join(host.state, "endpoints")), []);
});

for (const kind of ["ask", "investigate"] as const) {
  test(`/parley review and editor ${kind} work without a parent handoff`, async t => {
    const host = await createParentHost(t);
    await host.command("parley", "review");
    const before = await currentArtifact(host);
    const editor = await attachEditor(t, host);
    const info = await editor.request("review-info");
    assert.equal(typeof info.reviewId, "string");
    const reviewId = String(info.reviewId);
    assert.equal(sdk.creations, 0, "Initialization and pairing never create a reviewer");
    assert.deepEqual((await readReviewArtifact(before.filename)).records, before.snapshot.records);

    await fs.writeFile(path.join(host.root, "source.ts"), "source\n");
    const conversation = {
      id: "conversation",
      anchor: {
        path: "source.ts", side: "workspace", first: 1, last: 1, lines: ["source"], observedAt: 1,
        source: { kind: "editor", editorId: "editor", bufferId: 1, changedTick: 1 },
      },
      placement: { first: 1, last: 1 },
    };
    const message = {
      id: "human", conversationId: conversation.id, requestId: "batch", parentId: null,
      role: "human", author: "Human", origin: "editor/editor", createdAt: 1,
      lines: ["Explain this source"], version: 1, supersedes: [], replacesId: null,
    };
    const capture = {
      workspace: host.root, sessionId: "parent", editorId: "editor",
      conversations: kind === "ask" ? [conversation] : [],
      messages: kind === "ask" ? [message] : [],
      request: {
        id: "batch", kind, instructions: kind === "investigate" ? "Inspect source.ts" : null,
        submissions: kind === "ask" ? [{
          conversationId: conversation.id, baseVersion: 0, baseTipId: null,
          messageIds: [message.id], version: 1, tipId: message.id,
        }] : [],
      },
    };
    let reviewerPrompt: Record<string, unknown> | undefined;
    const promptStarted = Promise.withResolvers<void>();
    const releasePrompt = Promise.withResolvers<void>();
    sdk.beforePrompt = async () => { promptStarted.resolve(); await releasePrompt.promise; };
    sdk.onPrompt = async (_session, prompt) => {
      reviewerPrompt = object(JSON.parse(prompt.slice(prompt.indexOf("\n") + 1)));
    };
    const bytes = Buffer.from(JSON.stringify(capture));
    const digest = createHash("sha256").update(bytes).digest("hex");
    await editor.request("review-batch-begin", {
      batchId: "batch", digest, bytes: bytes.length, parts: 1, preparationId: info.preparationId,
    }, reviewId);
    await editor.request("review-batch-chunk", { batchId: "batch", index: 0, hex: bytes.toString("hex") }, reviewId);
    assert.equal(sdk.creations, 0, "Staging is not model authority");
    try {
      const accepted = await editor.request("review-batch-commit", { batchId: "batch", digest }, reviewId);
      assert.equal(accepted.status, "accepted");
      assert.equal(accepted.preparationId, info.preparationId);
      await promptStarted.promise;
      await assert.rejects(host.tool("parley_prepare", handoff), /busy/);
      await host.command("parley", "done");
      assert.match(String(host.notices.at(-1)), /active or settling/);
    } finally {
      releasePrompt.resolve();
    }
    let result: Record<string, unknown> = {};
    for (let attempt = 0; attempt < 100; attempt++) {
      result = await editor.request("review-result-begin", { requestId: "batch" }, reviewId);
      if (result.status === "ready") break;
      await setImmediate();
    }
    assert.equal(result.status, "ready");
    assert.equal(sdk.creations, 1);
    assert(reviewerPrompt);
    assert.deepEqual(object(reviewerPrompt.handoff).context, []);
    assert.deepEqual(object(reviewerPrompt.handoff).guidelines, []);
    assert.equal(object(reviewerPrompt.request).kind, kind);
    const after = await readReviewArtifact(before.filename);
    assert.equal(after.requests[0].outcome?.status, "completed");
    assert.equal(after.requests[0].record.preparationId, info.preparationId);

    // Enrichment is a revision, not a new review or a rewrite of accepted work.
    const enriched = { ...handoff, context: [{ source: "explicit user brief", content: "Selected context only" }] };
    await host.tool("parley_prepare", enriched);
    const revised = await readReviewArtifact(before.filename);
    assert.equal(revised.header.id, reviewId);
    assert.equal(revised.preparations.length, 2);
    assert.deepEqual(revised.preparations[1].context, enriched.context);
    assert.equal(revised.requests[0].record.preparationId, info.preparationId);
    const latest = await editor.request("review-info");
    assert.equal(latest.preparationId, revised.preparations[1].id);
    assert.notEqual(latest.preparationId, info.preparationId);
    assert.equal(sdk.creations, 1, "Enrichment itself starts no reviewer work");
  });
}

test("/parley review fails early without a persistent transcript or selected model", async t => {
  for (const missing of ["model", "transcript"] as const) {
    await t.test(missing, async t => {
      const host = await createParentHost(t, {
        getModel: () => missing === "model" ? undefined : model,
        getSessionFile: () => missing === "transcript" ? undefined : path.join(host.state, "parent.jsonl"),
      });
      await host.command("parley", "review");
      assert.match(String(host.notices.at(-1)), /persistent parent transcript.*explicitly selected model/);
      assert.deepEqual(await fs.readdir(host.state), ["endpoints"]);
      assert.deepEqual(await fs.readdir(path.join(host.state, "endpoints")), []);
      assert.equal(sdk.creations, 0);
    });
  }
});

test("a fresh /parley review cannot silently move an existing offer to another workspace", async t => {
  let useOtherWorkspace = false;
  const host = await createParentHost(t, {
    getCwd: root => useOtherWorkspace ? path.join(root, "other") : root,
  });
  await host.command("parley", "review");
  await host.command("parley", "done");
  const { filename, snapshot } = await currentArtifact(host);
  const savedEvidence = await fs.readFile(filename);
  await fs.mkdir(path.join(host.root, "other", ".git"), { recursive: true });
  useOtherWorkspace = true;
  await host.command("parley", "review");
  assert.match(String(host.notices.at(-1)), /another workspace\/session; no silent rebinding/);
  assert.deepEqual(await fs.readFile(filename), savedEvidence);
  assert.equal((await currentArtifact(host)).snapshot.header.id, snapshot.header.id);
  assert.equal(sdk.creations, 0);
});

test("failed artifact initialization stays failed instead of silently creating a replacement", async t => {
  const host = await createParentHost(t);
  await fs.mkdir(host.state, { recursive: true });
  const blockedStorage = path.join(host.state, "reviews");
  await fs.writeFile(blockedStorage, "Existing external data");
  await host.command("parley", "review");
  assert.match(String(host.notices.at(-1)), /EEXIST/);
  assert.deepEqual(await fs.readdir(path.join(host.state, "endpoints")), []);
  assert.equal(await fs.readFile(blockedStorage, "utf8"), "Existing external data");

  // Even after the external obstacle disappears, the failed owner is sticky.
  // An explicit command must not silently retry uncertain artifact creation.
  await fs.unlink(blockedStorage);
  await host.command("parley", "review");
  assert.match(String(host.notices.at(-1)), /EEXIST/);
  await assert.rejects(fs.access(blockedStorage), { code: "ENOENT" });
  assert.deepEqual(await fs.readdir(path.join(host.state, "endpoints")), []);
  assert.equal(sdk.creations, 0);
});

test("optional handoff cannot silently change the model/thinking frozen by /parley review", async t => {
  let thinking: "off" | "high" = "off";
  const host = await createParentHost(t, { getThinkingLevel: () => thinking });
  await host.command("parley", "review");
  const { filename } = await currentArtifact(host);
  const evidence = await fs.readFile(filename);
  thinking = "high";
  await assert.rejects(host.tool("parley_prepare", handoff), /already frozen/);
  assert.deepEqual(await fs.readFile(filename), evidence);
  assert.equal(sdk.creations, 0);
});

test("shutdown withdraws the offer and closes retained reviews even if the parent boundary cannot be read", async t => {
  let boundaryError: Error | undefined;
  const host = await createParentHost(t, {
    getLeafId: () => {
      if (boundaryError) throw boundaryError;
      return "parent-entry";
    },
  });
  await host.command("parley", "review");
  await host.tool("parley_prepare", handoff);
  await host.command("parley", "done");
  await host.tool("parley_prepare", handoff);
  assert.equal((await fs.readdir(path.join(host.state, "reviews"))).length, 2);
  boundaryError = new Error("Parent boundary unavailable");
  await assert.rejects(host.event("session_shutdown"), error => error === boundaryError);
  assert.deepEqual(await fs.readdir(path.join(host.state, "endpoints")), []);
  await assert.rejects(host.tool("parley_prepare", handoff), /preparation is unavailable/);
  await host.event("session_shutdown"); // Cleanup remains idempotent after failure.
});

test("/parley stop withdraws idle offers and pairing without wrap-up, then permits a fresh exact review", async t => {
  for (const pairing of ["unpaired", "paired", "disconnected"] as const) {
    await t.test(pairing, async t => {
      let captures = 0;
      const host = await createParentHost(t, { exec: async () => { captures++; return commitResult; } });
      await host.command("parley", "review");
      const before = await currentArtifact(host);
      const reviewId = before.snapshot.header.id;
      const editor = pairing === "unpaired" ? undefined : await attachEditor(t, host);
      const disconnected = editor ? once(editor.socket, "close") : undefined;
      if (pairing === "disconnected") {
        editor?.disconnect();
        await disconnected;
      }
      await host.command("parley", "stop " + "stale-review");
      assert.match(String(host.notices.at(-1)), /No matching active review/);
      assert.deepEqual((await readReviewArtifact(before.filename)).records, before.snapshot.records);
      await host.command("parley", "stop " + reviewId);
      await disconnected;
      assert.match(String(host.notices.at(-1)), /stopped without wrap-up/);
      assert.equal(host.statuses.get("parley-bridge"), undefined);
      assert.deepEqual(await fs.readdir(path.join(host.state, "endpoints")), []);
      const stopped = await readReviewArtifact(before.filename);
      assert.deepEqual(stopped.records.slice(0, before.snapshot.records.length), before.snapshot.records);
      assert.deepEqual(stopped.records.slice(before.snapshot.records.length).map(record => record.type), ["session-end"]);
      assert.equal(stopped.sessions[0].end?.endEntryId, "parent-entry");
      assert.equal(stopped.end, undefined);
      assert.equal(captures, 1, "Stop performs no new capture");
      assert.equal(sdk.creations, 0);
      assert.deepEqual(host.messages, [], "Stop sends no completion summary or parent turn");
      const evidence = await fs.readFile(before.filename);
      await host.command("parley", "stop");
      assert.match(String(host.notices.at(-1)), /No active review/);
      await host.command("parley", "review");
      const freshEditor = await attachEditor(t, host);
      const fresh = await freshEditor.request("review-info");
      assert.notEqual(fresh.reviewId, reviewId);
      await host.command("parley", "stop " + reviewId);
      assert.match(String(host.notices.at(-1)), /No matching active review/);
      await assert.rejects(freshEditor.request("review-result-begin", { requestId: "old-request" }, reviewId), /No matching initialized review/);
      assert.equal((await freshEditor.request("review-info")).reviewId, fresh.reviewId);
      assert.deepEqual(await fs.readFile(before.filename), evidence);
      assert.equal(sdk.creations, 0);
    });
  }
});

async function stageInvestigation(host: ParentHost, editor: Awaited<ReturnType<typeof attachEditor>>) {
  const info = await editor.request("review-info");
  const reviewId = String(info.reviewId);
  const bytes = Buffer.from(JSON.stringify({
    workspace: host.root, sessionId: "parent", editorId: "editor", conversations: [], messages: [],
    request: { id: "batch", kind: "investigate", instructions: "Inspect source.ts", submissions: [] },
  }));
  const digest = createHash("sha256").update(bytes).digest("hex");
  await editor.request("review-batch-begin", { batchId: "batch", digest, bytes: bytes.length, parts: 1,
    preparationId: info.preparationId }, reviewId);
  await editor.request("review-batch-chunk", { batchId: "batch", index: 0, hex: bytes.toString("hex") }, reviewId);
  return { reviewId, digest };
}

test("/parley stop cancels actual work and retains the lease until late startup/preflight/execution settles", async t => {
  for (const phase of ["startup", "preflight", "working", "cleanup-failure"] as const) {
    await t.test(phase, async t => {
      const host = await createParentHost(t);
      const started = Promise.withResolvers<void>();
      const release = Promise.withResolvers<void>();
      const hold = async () => { started.resolve(); await release.promise; };
      let prompts = 0;
      if (phase === "startup") sdk.beforeCreate = hold;
      if (phase === "preflight") sdk.beforePrompt = hold;
      sdk.onPrompt = async () => {
        prompts++;
        if (phase === "working" || phase === "cleanup-failure") await hold();
      };
      await host.command("parley", "review");
      await fs.writeFile(path.join(host.root, "source.ts"), "retain workspace content\n");
      const editor = await attachEditor(t, host);
      const { filename } = await currentArtifact(host);
      const { reviewId, digest } = await stageInvestigation(host, editor);
      await editor.request("review-batch-commit", { batchId: "batch", digest }, reviewId);
      await started.promise;
      if (phase === "cleanup-failure") {
        assert(sdk.session);
        sdk.session.dispose = () => { throw new Error("offline SDK disposal failure"); };
      }
      const before = await readReviewArtifact(filename);
      let settled = false;
      const stopping = host.command("parley", "stop").then(() => { settled = true; });
      try {
        await setImmediate();
        assert.equal(settled, false);
        assert.equal((await fs.readdir(path.join(host.state, "endpoints"))).length, 1, "Do not release execution ownership early");
        await host.command("parley", "stop");
        assert.match(String(host.notices.at(-1)), /Nothing queued or cancelled/);
        await host.command("parley", "review");
        assert.match(String(host.notices.at(-1)), /busy/);
        await host.command("parley");
        assert.match(String(host.notices.at(-1)), /Nothing queued/);
        await assert.rejects(host.tool("parley_prepare", handoff), /unavailable or busy/);
        await host.command("parley", "done");
        assert.match(String(host.notices.at(-1)), /Nothing queued/);
        if (phase === "working") editor.disconnect();
      } finally {
        release.resolve();
        await stopping;
      }
      assert.match(String(host.notices.at(-1)), phase === "cleanup-failure" ? /cleanup failed.*offline SDK disposal failure/ : /stopped without wrap-up/);
      assert.deepEqual(await fs.readdir(path.join(host.state, "endpoints")), []);
      const stopped = await readReviewArtifact(filename);
      assert.deepEqual(stopped.records.slice(0, before.records.length), before.records);
      assert.equal(stopped.requests.length, 1);
      assert.equal(stopped.requests[0].outcome?.status, "cancelled");
      assert.equal(stopped.activeRequestId, null);
      assert.equal(stopped.end, undefined);
      assert(stopped.sessions.every(session => session.end));
      assert.equal(await fs.readFile(path.join(host.root, "source.ts"), "utf8"), "retain workspace content\n");
      assert.deepEqual(host.messages, []);
      assert.equal(sdk.creations, 1);
      assert.equal(prompts, phase === "startup" ? 0 : 1, "No summary or replacement reviewer turn");
      if (phase !== "cleanup-failure") assert.equal(sdk.session?.disposed, true);
      const evidence = await fs.readFile(filename);
      await host.command("parley", "review");
      const fresh = await attachEditor(t, host);
      assert.notEqual((await fresh.request("review-info")).reviewId, reviewId);
      assert.deepEqual(await fs.readFile(filename), evidence);
    });
  }
});

test("/parley stop discards unaccepted staging without submitting or replaying it", async t => {
  const host = await createParentHost(t);
  await host.command("parley", "review");
  const editor = await attachEditor(t, host);
  const { filename, snapshot } = await currentArtifact(host);
  await stageInvestigation(host, editor);
  await host.command("parley", "stop");
  const stopped = await readReviewArtifact(filename);
  assert.deepEqual(stopped.records.slice(0, snapshot.records.length), snapshot.records);
  assert.equal(stopped.requests.length, 0);
  assert.equal(sdk.creations, 0);
  assert.deepEqual(host.messages, []);
});

test("/parley stop rejects active preparation and Done without queuing or cancelling them", async t => {
  const captured = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  let preparing = false;
  const host = await createParentHost(t, { exec: async () => {
    if (preparing) { captured.resolve(); await release.promise; }
    return commitResult;
  } });
  await host.command("parley", "review");
  preparing = true;
  const preparation = host.tool("parley_prepare", handoff);
  try {
    await captured.promise;
    await host.command("parley", "stop");
    assert.match(String(host.notices.at(-1)), /Nothing queued or cancelled/);
  } finally {
    release.resolve();
    await preparation;
  }
  const editor = await attachEditor(t, host);
  const { filename } = await currentArtifact(host);
  const { reviewId, digest } = await stageInvestigation(host, editor);
  await editor.request("review-batch-commit", { batchId: "batch", digest }, reviewId);
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    const result = await editor.request("review-result-begin", { requestId: "batch" }, reviewId);
    if (result.status === "ready") { ready = true; break; }
    await setImmediate();
  }
  assert(ready, "Investigation did not settle before explicit Done");
  const summarizing = Promise.withResolvers<void>();
  const finish = Promise.withResolvers<void>();
  sdk.onPrompt = async () => { summarizing.resolve(); await finish.promise; };
  const done = host.command("parley", "done");
  try {
    await summarizing.promise;
    const before = await fs.readFile(filename);
    await host.command("parley", "stop");
    assert.match(String(host.notices.at(-1)), /wrap-up is active.*nothing queued or cancelled/);
    assert.deepEqual(await fs.readFile(filename), before);
    assert.equal(sdk.session?.aborted, false);
  } finally {
    finish.resolve();
    await done;
  }
  const completed = await readReviewArtifact(filename);
  assert(completed.end);
  const evidence = await fs.readFile(filename);
  await host.command("parley", "stop");
  assert.match(String(host.notices.at(-1)), /already completed/);
  assert.deepEqual(await fs.readFile(filename), evidence);
  assert.equal(host.messages.length, 1);
  await host.command("parley", "done");
  assert.equal(host.messages.length, 2, "Saved completion remains readable without another summary");
});

test("editor Done delivers the saved recap to its Pi parent, once and independently of editor polling", async t => {
  for (const mode of ["concurrent-done", "editor-disconnected", "foreign-transcript"] as const) {
    await t.test(mode, async t => {
      let transcriptPath = path.join(os.tmpdir(), "parley-original-parent.jsonl");
      const host = await createParentHost(t, { getSessionFile: () => transcriptPath });
      await host.command("parley", "review");
      const editor = await attachEditor(t, host);
      const { filename } = await currentArtifact(host);
      const { reviewId, digest } = await stageInvestigation(host, editor);
      await editor.request("review-batch-commit", { batchId: "batch", digest }, reviewId);
      let ready = false;
      for (let attempt = 0; attempt < 1000; attempt++) {
        const info = await editor.request("review-info");
        if (!info.busy) {
          const result = await editor.request("review-result-begin", { requestId: "batch" }, reviewId);
          assert.equal(result.status, "ready");
          ready = true;
          break;
        }
        await setTimeout(1);
      }
      assert(ready, "Investigation settles before Done");
      const summarizing = Promise.withResolvers<void>();
      const release = Promise.withResolvers<void>();
      let wrapUpTurns = 0;
      let parentDone: Promise<void> | undefined;
      sdk.onPrompt = async () => { wrapUpTurns++; summarizing.resolve(); await release.promise; };
      try {
        // Even a matching session ID must not deliver into another transcript.
        if (mode === "foreign-transcript") transcriptPath = path.join(os.tmpdir(), "parley-foreign-parent.jsonl");
        const begun = await editor.request("review-finish-begin", { finishId: "editor-done" }, reviewId);
        assert.equal(begun.state, "wrapping");
        await summarizing.promise;
        const repeated = await editor.request("review-finish-begin", { finishId: "repeat-done" }, reviewId);
        assert.equal(repeated.finishId, "editor-done");
        assert.equal(host.messages.length, 0, "No recap before durable completion");
        if (mode === "concurrent-done") parentDone = host.command("parley", "done");
        if (mode === "editor-disconnected") editor.disconnect();
      } finally {
        release.resolve();
        await parentDone;
      }
      let completed = false;
      for (let attempt = 0; attempt < 1000; attempt++) {
        if (mode === "foreign-transcript"
          ? (await editor.request("review-finish-status", { finishId: "editor-done" }, reviewId)).state === "completed"
          : host.messages.length === 1) { completed = true; break; }
        await setTimeout(1);
      }
      assert(completed, "Accepted Done finishes without a second Pi command or editor polling");
      const saved = await readReviewArtifact(filename);
      assert(saved.end);
      assert.equal(wrapUpTurns, 1);
      assert.equal(saved.requests.filter(item => item.record.kind === "wrap-up").length, 1);
      if (mode === "foreign-transcript") {
        assert.deepEqual(host.messages, [], "No recap is routed into a foreign parent transcript");
      } else {
        assert.equal(host.messages.length, 1, "Concurrent Done observers deliver only one recap");
        const recap = object(host.messages[0]);
        assert.equal(recap.customType, "parley-review-done");
        assert.equal(recap.content, saved.end.summary);
        assert.deepEqual(recap.details, { reviewId, artifactPath: filename });
        assert.deepEqual(host.messageOptions, [{ triggerTurn: false }]);
      }
      if (mode === "concurrent-done") {
        const evidence = await fs.readFile(filename);
        await editor.request("review-finish-begin", { finishId: "reopen-editor" }, reviewId);
        await setTimeout(1);
        assert.equal(host.messages.length, 1, "Editor summary reopen does not inject another parent recap");
        await host.command("parley", "done");
        assert.equal(host.messages.length, 2, "Explicit Pi Done can redisplay the same saved summary");
        assert.equal(object(host.messages[1]).content, saved.end.summary);
        assert.equal(wrapUpTurns, 1);
        assert.deepEqual(await fs.readFile(filename), evidence);
      }
    });
  }
});

test("session withdrawal cannot release a stopping review's lease before settlement or route its late notification", async t => {
  const host = await createParentHost(t);
  const started = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  sdk.beforeCreate = async () => { started.resolve(); await release.promise; };
  await host.command("parley", "review");
  const editor = await attachEditor(t, host);
  const { filename } = await currentArtifact(host);
  const { reviewId, digest } = await stageInvestigation(host, editor);
  await editor.request("review-batch-commit", { batchId: "batch", digest }, reviewId);
  await started.promise;
  const stopping = host.command("parley", "stop");
  const changed = host.event("session_start");
  try {
    await setImmediate();
    assert.equal((await fs.readdir(path.join(host.state, "endpoints"))).length, 1);
    await host.command("parley", "review");
    assert.match(String(host.notices.at(-1)), /busy/);
  } finally {
    release.resolve();
    await Promise.all([stopping, changed]);
  }
  assert(!host.notices.some(notice => notice.includes("stopped without wrap-up")), "No late notification into a replacement session");
  assert.deepEqual(await fs.readdir(path.join(host.state, "endpoints")), []);
  assert.equal((await readReviewArtifact(filename)).requests[0].outcome?.status, "cancelled");
  await host.command("parley", "review");
  const fresh = await attachEditor(t, host);
  assert.notEqual((await fresh.request("review-info")).reviewId, reviewId);
  assert.match(String(host.statuses.get("parley-bridge")), /editor paired/);
});
