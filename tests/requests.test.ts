import test from "node:test";
import type { TestContext } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import { setImmediate } from "node:timers/promises";
import { ReviewRequests } from "../pi/requests.ts";
import { readReviewArtifact } from "../pi/artifact.ts";
import type { PreparationRecord } from "../pi/artifact.ts";
import type { EditorPeer, ReviewAction } from "../pi/bridge.ts";
import { model, resetSdk, sdk } from "./fixtures/review-sdk.ts";
import type { FakeSession } from "./fixtures/review-sdk.ts";

// Replace only the external SDK. Request policy, artifacts and filesystem checks
// run unchanged; this fake does not establish compatibility with the real SDK.
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

const chunkBytes = 16 * 1024;
const identity = { instanceId: "instance", sessionId: "parent", editorId: "editor", nonce: "nonce" };
type Response = Readonly<Record<string, unknown>>;
type RequestFixture = {
  readonly root: string;
  readonly owner: ReviewRequests;
  readonly preparation: PreparationRecord;
  readonly peer: EditorPeer;
  send(action: ReviewAction, payload: Readonly<Record<string, unknown>>): Promise<Response>;
  stage(value: unknown, batchId?: string): Promise<{ readonly digest: string }>;
  disconnect(): void;
};

async function fixture(t: TestContext): Promise<RequestFixture> {
  resetSdk();
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-requests-"));
  const root = path.join(directory, "work");
  const previousState = process.env.PARLEY_STATE_DIR;
  process.env.PARLEY_STATE_DIR = path.join(directory, "state");
  const owner = new ReviewRequests(root, "parent", ["read"], error => { assert.fail(String(error)); });
  t.after(async () => {
    try {
      await owner.close();
    } finally {
      if (previousState === undefined) delete process.env.PARLEY_STATE_DIR;
      else process.env.PARLEY_STATE_DIR = previousState;
      await fs.rm(directory, { recursive: true, force: true });
    }
  });
  await fs.mkdir(root);
  await fs.writeFile(path.join(root, "source.ts"), "source\n");
  const preparation = await owner.prepare({ objective: "Review source", scope: ["source.ts"], decisions: [], guidelines: [], context: [] },
    { sessionId: "parent", transcriptPath: path.join(directory, "parent.jsonl"), startEntryId: null,
      model: { provider: model.provider, modelId: model.id, thinkingLevel: "off" } }, "a".repeat(40), () => true, model);
  const peer = { editorId: "editor", sessionId: "parent", label: "Neovim" };
  let connected = true;
  const send: RequestFixture["send"] = (action, payload) => owner.handle({
    action, reviewId: preparation.reviewId, payload: { ...identity, ...payload }, peer, current: () => connected,
  });
  return {
    root, owner, preparation, peer, send,
    disconnect() { connected = false; },
    async stage(value, batchId = "batch") {
      const bytes = Buffer.from(JSON.stringify(value));
      const digest = createHash("sha256").update(bytes).digest("hex");
      const parts = Math.ceil(bytes.length / chunkBytes);
      await send("review-batch-begin", { batchId, digest, bytes: bytes.length, parts, preparationId: preparation.id });
      for (let index = 0; index < parts; index++) {
        await send("review-batch-chunk", { batchId, index, hex: bytes.subarray(index * chunkBytes, (index + 1) * chunkBytes).toString("hex") });
      }
      return { digest };
    },
  };
}

function capture(root: string) {
  const conversations = ["one", "two"].map(id => ({
    id,
    anchor: { path: "source.ts", side: "workspace", first: 1, last: 1, lines: ["source"], observedAt: 1,
      source: { kind: "editor", editorId: "editor", bufferId: 1, changedTick: 1 } },
    placement: { first: 1, last: 1 },
  }));
  const messages = conversations.map(conversation => ({
    id: `human-${conversation.id}`, conversationId: conversation.id, requestId: "batch", parentId: null,
    role: "human", author: "Human", origin: "editor/editor", createdAt: 1, lines: ["Question界".repeat(1000)],
    version: 1, supersedes: [], replacesId: null,
  }));
  return { workspace: root, sessionId: "parent", editorId: "editor", conversations, messages,
    request: { id: "batch", kind: "ask", instructions: null, submissions: messages.map(message => ({
      conversationId: message.conversationId, baseVersion: 0, baseTipId: null,
      messageIds: [message.id], version: 1, tipId: message.id,
    })) } };
}

function object(value: unknown): Record<string, unknown> {
  assert(value !== null && typeof value === "object" && !Array.isArray(value));
  return value as Record<string, unknown>;
}

async function callTool(session: FakeSession, name: string, parameters: unknown): Promise<Record<string, unknown>> {
  const tool = session.tools.get(name);
  assert(tool);
  const result = await tool.execute("call", parameters, undefined, undefined, {} as Parameters<typeof tool.execute>[4]);
  const content = result.content[0];
  assert(content?.type === "text");
  const value: unknown = JSON.parse(content.text);
  return object(value);
}

async function readyResult(send: RequestFixture["send"]): Promise<Response> {
  const deadline = Date.now() + 5000;
  for (;;) {
    const result = await send("review-result-begin", { requestId: "batch" });
    if (result.status === "ready") return result;
    assert.equal(result.status, "pending");
    assert(Date.now() < deadline, "Review result did not settle");
    await setImmediate();
  }
}

async function downloadResult(send: RequestFixture["send"], ready: Response): Promise<Buffer> {
  assert.equal(typeof ready.parts, "number");
  const chunks: Buffer[] = [];
  for (let index = 0; index < ready.parts; index++) {
    const chunk = await send("review-result-chunk", { requestId: "batch", downloadId: ready.downloadId, index });
    assert.equal(chunk.index, index);
    assert.equal(typeof chunk.hex, "string");
    chunks.push(Buffer.from(chunk.hex, "hex"));
  }
  const bytes = Buffer.concat(chunks);
  assert.equal(bytes.length, ready.bytes);
  assert.equal(createHash("sha256").update(bytes).digest("hex"), ready.digest);
  return bytes;
}

test("acceptance, pending observation, bounded delivery and application receipts remain separate and single-use", async t => {
  const started = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  t.after(() => release.resolve());
  const { root, owner, preparation, peer, send, stage, disconnect } = await fixture(t);
  sdk.onPrompt = async session => {
    started.resolve();
    await release.promise;
    const first = await callTool(session, "review_reply", { requestId: "batch", conversationId: "one",
      parentId: "human-one", version: 1, lines: ["答😀".repeat(4000)] });
    await callTool(session, "review_reply", { requestId: "batch", conversationId: "one",
      parentId: first.messageId, version: first.version, lines: ["Follow-up"] });
    await callTool(session, "review_reply", { requestId: "batch", conversationId: "two",
      parentId: "human-two", version: 1, lines: ["Second answer"] });
    const observation = await callTool(session, "review_read", { requestId: "batch", path: "source.ts", first: 1, last: 1 });
    await callTool(session, "review_add_note", { requestId: "batch", observationId: observation.observationId,
      first: 1, last: 1, lines: ["New finding"] });
  };
  const { digest } = await stage(capture(root));
  const commit = send("review-batch-commit", { batchId: "batch", digest });
  await assert.rejects(send("review-batch-commit", { batchId: "batch", digest }), /Missing\/stale upload/);
  assert.equal((await commit).status, "accepted");
  await started.promise;
  const before = await fs.readFile(owner.artifactPath!);
  assert.equal((await send("review-result-begin", { requestId: "batch" })).status, "pending");
  assert.deepEqual(await fs.readFile(owner.artifactPath!), before, "Polling does not append evidence");
  release.resolve();
  const ready = await readyResult(send);
  assert(Number(ready.parts) > 1, "Exercise multi-chunk UTF-8 delivery");
  const receipt = { requestId: "batch", downloadId: ready.downloadId, digest: ready.digest, receiptId: "receipt",
    messageIds: [], status: "applied", placement: "placed", detail: null };
  await assert.rejects(send("review-result-receipt", receipt), /precedes complete/);
  await assert.rejects(send("review-result-chunk", { requestId: "batch", downloadId: ready.downloadId, index: 1 }), /out-of-order/);
  const bytes = await downloadResult(send, ready);
  const parsed: unknown = JSON.parse(bytes.toString("utf8"));
  const result = object(parsed);
  assert.equal(result.reviewId, preparation.reviewId);
  assert.equal(result.sessionId, "review-session");
  assert.equal(object(result.outcome).status, "completed");
  assert(Array.isArray(result.conversations));
  const groups = result.conversations.map(object);
  assert.deepEqual(groups.map(group => group.new), [false, false, true]);
  assert.deepEqual(groups.map(group => [group.baseVersion, group.baseTipId]), [[1, "human-one"], [1, "human-two"], [0, null]]);
  const messages = groups.map(group => {
    assert(Array.isArray(group.messages));
    return group.messages.map(object);
  });
  assert.deepEqual(messages.map(group => group.map(message => message.lines)), [[ ["答😀".repeat(4000)], ["Follow-up"] ], [["Second answer"]], [["New finding"]]]);
  assert.deepEqual(Object.keys(messages[0][0]), ["id", "parentId", "role", "author", "origin", "createdAt", "lines", "version"]);
  await assert.rejects(send("review-result-begin", { requestId: "batch" }), /already began/);
  await assert.rejects(send("review-result-chunk", { requestId: "batch", downloadId: ready.downloadId, index: 0 }), /out-of-order/);
  const claimed = { ...receipt, messageIds: messages[0].map(message => message.id) };
  const recording = send("review-result-receipt", claimed);
  await assert.rejects(send("review-result-receipt", { ...claimed, receiptId: "duplicate" }), /already has an application/);
  assert.equal((await recording).status, "recorded");
  const artifact = await readReviewArtifact(owner.artifactPath!);
  assert.equal(artifact.requests.length, 1);
  assert.equal(artifact.applications.length, 1);
  assert.equal(artifact.end, undefined);
  disconnect();
  await assert.rejects(owner.handle({ action: "review-result-begin", reviewId: preparation.reviewId,
    payload: { ...identity, requestId: "batch" }, peer: { ...peer }, current: () => true }), /Result owner changed/);
  const closing = owner.close(null);
  assert.equal(owner.close("ignored"), closing);
  await closing;
  const closed = await readReviewArtifact(owner.artifactPath!);
  assert.equal(closed.sessions.find(session => session.record.role === "parent")?.end?.endEntryId, null);
});

test("upload staging rejects invalid ordering and content without accepting or replaying a batch", async t => {
  const { owner, preparation, peer, send, disconnect } = await fixture(t);
  const begin = { batchId: "batch", digest: "a".repeat(64), bytes: 1, parts: 1, preparationId: preparation.id };
  await assert.rejects(send("review-batch-begin", { ...begin, parts: 2 }), /part count/);
  await send("review-batch-begin", begin);
  await assert.rejects(send("review-batch-commit", { batchId: "batch", digest: begin.digest }), /Incomplete batch/);
  await assert.rejects(send("review-batch-chunk", { batchId: "batch", index: 1, hex: "61" }), /out-of-order/);
  await assert.rejects(send("review-batch-chunk", { batchId: "batch", index: 0, hex: "gg" }), /hexadecimal/);
  await assert.rejects(send("review-batch-chunk", { batchId: "batch", index: 0, hex: "6161" }), /exact byte sequence/);
  await send("review-batch-chunk", { batchId: "batch", index: 0, hex: "61" });
  await assert.rejects(send("review-batch-commit", { batchId: "batch", digest: begin.digest }), /digest mismatch/);
  disconnect();
  await assert.rejects(send("review-batch-begin", begin), /no longer current/);
  await assert.rejects(owner.handle({ action: "review-batch-begin", reviewId: preparation.reviewId,
    payload: { ...identity, ...begin }, peer: { ...peer }, current: () => true }), /Duplicate\/stale batch/);
  assert.equal((await readReviewArtifact(owner.artifactPath!)).requests.length, 0);
  assert.equal(sdk.creations, 0);
});

test("an investigation captures no drafts and delivers an empty publication envelope", async t => {
  const { root, send, stage } = await fixture(t);
  const { digest } = await stage({ workspace: root, sessionId: "parent", editorId: "editor",
    request: { id: "batch", kind: "investigate", instructions: "Review source", submissions: [] },
    conversations: [], messages: [] });
  assert.equal((await send("review-batch-commit", { batchId: "batch", digest })).status, "accepted");
  const ready = await readyResult(send);
  const bytes = await downloadResult(send, ready);
  const parsed: unknown = JSON.parse(bytes.toString("utf8"));
  const result = object(parsed);
  assert.equal(object(result.outcome).status, "completed");
  assert.deepEqual(result.conversations, []);
});

test("disconnect during source validation consumes staging without accepting or replaying work", async t => {
  const { root, owner, send, stage, disconnect } = await fixture(t);
  const { digest } = await stage(capture(root));
  const commit = send("review-batch-commit", { batchId: "batch", digest });
  disconnect(); // commit is awaiting realpath, before durable acceptance.
  await assert.rejects(commit, /Peer changed before durable acceptance/);
  assert.equal((await readReviewArtifact(owner.artifactPath!)).requests.length, 0);
  assert.equal(sdk.creations, 0);
});

test("source containment accepts deleted observations but rejects escaping and dangling symlinks", async t => {
  for (const source of ["deleted", "escape", "dangling"] as const) {
    await t.test(source, async t => {
      const { root, owner, send, stage } = await fixture(t);
      const value = capture(root);
      if (source === "escape") await fs.symlink(path.dirname(root), path.join(root, source));
      if (source === "dangling") await fs.symlink("missing-target", path.join(root, source));
      for (const conversation of value.conversations) {
        conversation.anchor.path = source === "escape" ? "escape/foreign.ts" : `${source}/source.ts`;
      }
      const { digest } = await stage(value);
      const commit = send("review-batch-commit", { batchId: "batch", digest });
      if (source === "deleted") {
        assert.equal((await commit).status, "accepted");
      } else {
        await assert.rejects(commit, /outside|Unresolvable source symlink/);
        assert.equal((await readReviewArtifact(owner.artifactPath!)).requests.length, 0);
        assert.equal(sdk.creations, 0);
      }
    });
  }
});

test("parent withdrawal rejects stale identities, preparation/acceptance and natural settlement without changing evidence", async t => {
  const { root, owner, preparation, send } = await fixture(t);
  const parent = { sessionId: "parent", transcriptPath: path.join(path.dirname(root), "parent.jsonl") };
  const reviewId = preparation.reviewId;
  const before = await fs.readFile(owner.artifactPath!);
  for (const attempt of [
    () => owner.stopParent("stale", parent, null, () => true),
    () => owner.stopParent(reviewId, { ...parent, sessionId: "other" }, null, () => true),
    () => owner.stopParent(reviewId, { ...parent, transcriptPath: "/other.jsonl" }, null, () => true),
    () => owner.stopParent(reviewId, parent, null, () => false),
  ]) assert.throws(attempt, /exact originating parent and live review/);
  assert.deepEqual(await fs.readFile(owner.artifactPath!), before);

  const preparing = owner.prepare({ objective: "Explicit revision", scope: [], decisions: [], guidelines: [], context: [] },
    { ...parent, startEntryId: null, model: { provider: model.provider, modelId: model.id, thinkingLevel: "off" } },
    "a".repeat(40), () => true, model);
  assert.throws(() => owner.stopParent(reviewId, parent, null, () => true), /preparation, acceptance or wrap-up is active/);
  const revised = await preparing;
  // Discover the revised preparation instead of reusing a staged old capture.
  const value = capture(root);
  const bytes = Buffer.from(JSON.stringify(value));
  const digest = createHash("sha256").update(bytes).digest("hex");
  await send("review-batch-begin", { batchId: "batch", digest, bytes: bytes.length,
    parts: Math.ceil(bytes.length / chunkBytes), preparationId: revised.id });
  for (let index = 0; index < Math.ceil(bytes.length / chunkBytes); index++) {
    await send("review-batch-chunk", { batchId: "batch", index, hex: bytes.subarray(index * chunkBytes, (index + 1) * chunkBytes).toString("hex") });
  }
  let observedSettlement = false;
  sdk.onPrompt = async session => {
    session.listeners.add(event => {
      if (event.type !== "agent_settled") return;
      observedSettlement = true;
      assert.throws(() => owner.stopParent(reviewId, parent, null, () => true), /work is settling/);
    });
  };
  const accepting = send("review-batch-commit", { batchId: "batch", digest });
  assert.throws(() => owner.stopParent(reviewId, parent, null, () => true), /preparation, acceptance or wrap-up is active/);
  await accepting;
  await readyResult(send);
  assert.equal(observedSettlement, true);
  const settled = await readReviewArtifact(owner.artifactPath!);
  assert.equal(settled.requests[0].outcome?.status, "completed", "Rejected stop must not relabel natural completion");
  assert.equal(settled.sessions[0].end, undefined);
  assert.equal(sdk.session?.aborted, false);
});

test("parent withdrawal retains accepted prose and published replies, cancels once and revokes late publication", async t => {
  const { root, owner, preparation, stage, send } = await fixture(t);
  const parent = { sessionId: "parent", transcriptPath: path.join(path.dirname(root), "parent.jsonl") };
  const started = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  t.after(() => release.resolve());
  sdk.onPrompt = async session => {
    await callTool(session, "review_reply", { requestId: "batch", conversationId: "one", parentId: "human-one", version: 1,
      lines: ["Published evidence survives withdrawal"] });
    started.resolve();
    await release.promise;
    await assert.rejects(callTool(session, "review_reply", { requestId: "batch", conversationId: "two", parentId: "human-two", version: 1,
      lines: ["Must not publish after withdrawal"] }), /cancelled, settled or replaced/);
  };
  const { digest } = await stage(capture(root));
  await send("review-batch-commit", { batchId: "batch", digest });
  await started.promise;
  const before = await readReviewArtifact(owner.artifactPath!);
  const stopping = owner.stopParent(preparation.reviewId, parent, "withdrawal-boundary", () => true);
  try {
    assert.throws(() => owner.stopParent(preparation.reviewId, parent, null, () => true), /exact originating parent and live review/);
    await assert.rejects(send("review-info", {}), /no longer current/);
  } finally {
    release.resolve();
    await stopping;
  }
  const stopped = await readReviewArtifact(owner.artifactPath!);
  assert.deepEqual(stopped.records.slice(0, before.records.length), before.records);
  assert.equal(stopped.requests.length, 1);
  assert.equal(stopped.requests[0].outcome?.status, "cancelled");
  assert.equal(stopped.records.filter(record => record.type === "outcome").length, 1);
  assert.equal(stopped.end, undefined);
  assert.equal(stopped.sessions[0].end?.endEntryId, "withdrawal-boundary");
  assert.equal(sdk.session?.disposed, true);
});
