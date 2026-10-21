import test from "node:test";
import type { TestContext } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import { ReviewArtifactWriter } from "../pi/artifact.ts";
import type { PreparationRecord, RequestRecord } from "../pi/artifact.ts";
import type { DiscoveryTool } from "../pi/interaction.ts";
import { model, resetSdk, sdk } from "./fixtures/review-sdk.ts";
import type { FakeSession } from "./fixtures/review-sdk.ts";

// Replace only the external SDK at module loading, without changing production
// dependencies or requiring a locally installed SDK. Other tests use real I/O.
const { ReviewInteraction } = await (async () => {
  const hooks = registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier === "@earendil-works/pi-coding-agent") {
        return { url: new URL("./fixtures/review-sdk.ts", import.meta.url).href, shortCircuit: true };
      }
      return nextResolve(specifier, context);
    },
  });
  try {
    return await import("../pi/interaction.ts");
  } finally {
    hooks.deregister();
  }
})();

type InteractionFixture = {
  readonly root: string;
  readonly writer: ReviewArtifactWriter;
  readonly interaction: InstanceType<typeof ReviewInteraction>;
  readonly preparation: PreparationRecord;
  accept(id: string, kind?: "investigate" | "wrap-up"): Promise<RequestRecord>;
};

async function fixture(t: TestContext, discovery: readonly DiscoveryTool[] = ["read", "list"]): Promise<InteractionFixture> {
  resetSdk();
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-interaction-"));
  const root = path.join(directory, "work");
  const previousState = process.env.PARLEY_STATE_DIR;
  process.env.PARLEY_STATE_DIR = path.join(directory, "state");
  let writer: ReviewArtifactWriter | undefined;
  let interaction: InstanceType<typeof ReviewInteraction> | undefined;
  t.after(async () => {
    try {
      await interaction?.close();
    } finally {
      try {
        await writer?.close();
      } finally {
        if (previousState === undefined) delete process.env.PARLEY_STATE_DIR;
        else process.env.PARLEY_STATE_DIR = previousState;
        await fs.rm(directory, { recursive: true, force: true });
      }
    }
  });
  await fs.mkdir(root);
  writer = await ReviewArtifactWriter.create({ type: "review", schemaVersion: 1, id: "review", workspace: root,
    startingCommit: "a".repeat(40), createdAt: 1 });
  const preparation: PreparationRecord = { type: "preparation", id: "preparation", reviewId: "review", createdAt: 1,
    parentSessionRecordId: "parent", objective: "Review source", scope: ["source.ts"], decisions: [], guidelines: [], context: [] };
  await writer.append([
    { type: "session", id: "parent", reviewId: "review", createdAt: 1, role: "parent", sessionId: "parent-session",
      transcriptPath: path.join(directory, "parent.jsonl"), startEntryId: null, parentSessionRecordId: null,
      model: { provider: model.provider, modelId: model.id, thinkingLevel: "off" } },
    preparation,
  ]);
  interaction = new ReviewInteraction(writer, discovery, model);
  const artifact = writer;
  return {
    root, writer, interaction, preparation,
    async accept(id, kind = "investigate") {
      const request: RequestRecord = { type: "request", id, reviewId: "review", createdAt: 1, kind,
        preparationId: preparation.id, instructions: kind === "investigate" ? "Review source" : null, submissions: [] };
      await artifact.append([request]);
      return request;
    },
  };
}

async function executeTool(session: FakeSession, name: string, parameters: unknown): ReturnType<ToolDefinition["execute"]> {
  const tool = session.tools.get(name);
  assert(tool, `Tool ${name} exists`);
  // These review tools never use the host context. No parent host capabilities
  // are supplied; exercising the SDK's context construction is outside this fake.
  return tool.execute("call", parameters, undefined, undefined, {} as Parameters<ToolDefinition["execute"]>[4]);
}

async function callTool(session: FakeSession, name: string, parameters: unknown): Promise<Record<string, unknown>> {
  const result = await executeTool(session, name, parameters);
  const content = result.content[0];
  assert(content?.type === "text");
  const value: unknown = JSON.parse(content.text);
  assert(value !== null && typeof value === "object" && !Array.isArray(value));
  return value as Record<string, unknown>;
}

test("discovery receipts publish immutable notes and exact-version replies, not editor application", async t => {
  const { root, writer, interaction, preparation, accept } = await fixture(t);
  await fs.writeFile(path.join(root, "source.ts"), "alpha\nbeta\ngamma\n");
  await fs.mkdir(path.join(root, ".git"));
  const request = await accept("investigate");
  sdk.onPrompt = async session => {
    const result = await executeTool(session, "review_list", { requestId: request.id, path: "." });
    assert.deepEqual(result.content, [{ type: "text", text: JSON.stringify([{ name: "source.ts", kind: "file" }]) }]);
    const observation = await callTool(session, "review_read", { requestId: request.id, path: "source.ts", first: 1, last: 3 });
    assert.deepEqual(observation.lines, ["alpha", "beta", "gamma"]);
    // Publication uses captured evidence even if disk content disappears.
    await fs.unlink(path.join(root, "source.ts"));
    const note = await callTool(session, "review_add_note", { requestId: request.id,
      observationId: observation.observationId, first: 2, last: 2, lines: ["Finding"] });
    const reply = { requestId: request.id, conversationId: note.conversationId, parentId: note.messageId,
      version: note.version, lines: ["Clarification"] };
    await callTool(session, "review_reply", reply);
    await assert.rejects(callTool(session, "review_reply", reply), /Stale or foreign/);
    await assert.rejects(callTool(session, "review_reply", { ...reply, requestId: "foreign" }), /Foreign request/);
    await assert.rejects(callTool(session, "review_read", { requestId: request.id, path: "source.ts", first: 1, last: 1, extra: true }), /exactly these fields/);
  };
  await interaction.start(request, preparation);
  const snapshot = writer.snapshot();
  assert.equal(snapshot.requests[0].outcome?.status, "completed", snapshot.requests[0].outcome?.detail ?? "");
  assert.match(snapshot.requests[0].outcome?.detail ?? "", /2 published message/);
  assert.deepEqual(snapshot.conversations[0].record.anchor.lines, ["beta"]);
  assert.deepEqual(snapshot.conversations[0].messages.map(message => message.lines), [["Finding"], ["Clarification"]]);
  assert.equal(snapshot.conversations[0].messages[0].origin, "pi/review-session");
  assert.equal(snapshot.applications.length, 0);
  assert.equal(interaction.busy, false);
  assert.equal(sdk.session?.listeners.size, 0);
});

test("source discovery rejects unsafe paths, invalid text and oversized ranges or files", async t => {
  const { root, writer, interaction, preparation, accept } = await fixture(t);
  await fs.writeFile(path.join(root, "source.ts"), "one\ntwo\n");
  await fs.writeFile(path.join(root, "binary"), Buffer.from([0]));
  await fs.writeFile(path.join(root, "invalid-utf8"), Buffer.from([0xff]));
  await fs.writeFile(path.join(root, "large"), Buffer.alloc(1024 * 1024 + 1, 97));
  await fs.mkdir(path.join(root, ".git"));
  await fs.writeFile(path.join(root, ".git", "config"), "private");
  await fs.symlink(path.dirname(root), path.join(root, "outside"));
  await fs.symlink(".git/config", path.join(root, "metadata"));
  const request = await accept("investigate");
  sdk.onPrompt = async session => {
    for (const sourcePath of ["../escape", "/absolute", "a/../source.ts", ".git/config", "outside", "metadata"]) {
      await assert.rejects(callTool(session, "review_read", { requestId: request.id, path: sourcePath, first: 1, last: 1 }));
    }
    for (const sourcePath of ["binary", "invalid-utf8", "large"]) {
      await assert.rejects(callTool(session, "review_read", { requestId: request.id, path: sourcePath, first: 1, last: 1 }));
    }
    await assert.rejects(callTool(session, "review_read", { requestId: request.id, path: "source.ts", first: 1, last: 513 }), /512 lines/);
    await assert.rejects(callTool(session, "review_read", { requestId: request.id, path: "source.ts", first: 1, last: 3 }), /exact source line count/);
    const observation = await callTool(session, "review_read", { requestId: request.id, path: "source.ts", first: 1, last: 2 });
    for (const lines of [[], [" "], ["bad\nline"], [12], ["x".repeat(64 * 1024)]]) {
      await assert.rejects(callTool(session, "review_add_note", { requestId: request.id,
        observationId: observation.observationId, first: 1, last: 1, lines }), /message lines|publication/);
    }
    await assert.rejects(callTool(session, "review_add_note", { requestId: request.id,
      observationId: observation.observationId, first: 1, last: 3, lines: ["Outside observation"] }), /incompatible range/);
  };
  await interaction.start(request, preparation);
  assert.equal(writer.snapshot().requests[0].outcome?.status, "completed", writer.snapshot().requests[0].outcome?.detail ?? "");
  assert.equal(writer.snapshot().conversations.length, 0);
});

test("observations belong to one request while the same reviewer session is reused", async t => {
  const { root, writer, interaction, preparation, accept } = await fixture(t, ["read"]);
  await fs.writeFile(path.join(root, "source.ts"), "one\n");
  const first = await accept("first");
  let observationId: unknown;
  sdk.onPrompt = async session => {
    assert.deepEqual(session.getActiveToolNames(), ["review_reply", "review_add_note", "review_read"]);
    observationId = (await callTool(session, "review_read", { requestId: first.id, path: "source.ts", first: 1, last: 1 })).observationId;
  };
  await interaction.start(first, preparation);
  const second = await accept("second");
  sdk.onPrompt = async session => {
    await assert.rejects(callTool(session, "review_add_note", { requestId: second.id, observationId,
      first: 1, last: 1, lines: ["Stale evidence"] }), /Missing\/foreign observation/);
  };
  await interaction.start(second, preparation);
  assert.deepEqual(writer.snapshot().requests.map(item => item.outcome?.status), ["completed", "completed"]);
  assert.equal(sdk.creations, 1);
});

test("cancellation during prompt preflight is reasserted at late agent start", async t => {
  const { writer, interaction, preparation, accept } = await fixture(t);
  const request = await accept("investigate");
  const preflight = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  sdk.beforePrompt = async () => { preflight.resolve(); await release.promise; };
  const operation = interaction.start(request, preparation);
  try {
    await preflight.promise;
    assert.equal(interaction.busy, true);
    assert.equal(interaction.activity(request.id), "starting");
    assert.throws(() => interaction.start(request, preparation), /busy\/closed/);
    const cancellation = interaction.cancel(request.id);
    release.resolve();
    await cancellation;
    await operation;
  } finally {
    release.resolve();
  }
  assert.equal(writer.snapshot().requests[0].outcome?.status, "cancelled");
  assert.equal(interaction.busy, false);
  assert.equal(interaction.activity(request.id), undefined);
  assert.equal(sdk.session?.listeners.size, 0);
});

test("wrap-up runs without tools, restores the allowlist, and releases ownership on failure", async t => {
  const { writer, interaction, preparation, accept } = await fixture(t, []);
  await interaction.start(await accept("investigate"), preparation);
  const session = sdk.session;
  assert(session);
  const allowed = session.getActiveToolNames();
  const wrap = await accept("wrap", "wrap-up");
  sdk.onPrompt = async current => {
    assert.deepEqual(current.getActiveToolNames(), []);
    assert.deepEqual(current.getCallableToolNames(), []);
    await assert.rejects(callTool(current, "review_add_note", {}), /wrap-up grants no tools/);
  };
  const operation = interaction.summarize(wrap, "Recorded evidence");
  assert.equal(interaction.busy, true);
  assert.equal(await operation, "Reviewer summary");
  assert.deepEqual(session.getActiveToolNames(), allowed);
  assert.equal(session.listeners.size, 0);
  assert.equal(interaction.busy, false);
  // The caller, not summarize(), persists the wrap-up outcome.
  await writer.append([{ type: "outcome", id: "wrap-outcome", reviewId: "review", createdAt: 1,
    requestId: wrap.id, status: "completed", detail: null }]);
  const failedWrap = await accept("failed-wrap", "wrap-up");
  const failure = new Error("Summary unavailable");
  sdk.onPrompt = async () => { throw failure; };
  await assert.rejects(interaction.summarize(failedWrap, "Recorded evidence"), error => error === failure);
  assert.deepEqual(session.getActiveToolNames(), allowed);
  assert.equal(session.listeners.size, 0);
  assert.equal(interaction.busy, false);
});

test("shutdown owns and disposes a late SDK creation and records one session boundary", async t => {
  const { writer, interaction, preparation, accept } = await fixture(t);
  const creating = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  sdk.beforeCreate = async () => { creating.resolve(); await release.promise; };
  const operation = interaction.start(await accept("investigate"), preparation);
  try {
    await creating.promise;
    const closing = interaction.close();
    assert.equal(interaction.close(), closing);
    release.resolve();
    await closing;
    await operation;
  } finally {
    release.resolve();
  }
  assert.equal(writer.snapshot().requests[0].outcome?.status, "cancelled");
  assert.equal(writer.snapshot().sessions.length, 2);
  assert(writer.snapshot().sessions[1].end);
  assert.equal(sdk.session?.disposed, true);
  assert.equal(sdk.creations, 1);
});
