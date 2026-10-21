import test from "node:test";
import type { TestContext } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { ArtifactError, ReviewArtifactWriter, parseArtifactRecord, readReviewArtifact } from "../pi/artifact.ts";
import type { ApplicationRecord, ConversationRecord, MessageRecord, OutcomeRecord, RequestRecord, SourceAnchor } from "../pi/artifact.ts";
import { reviewHandback, reviewWrapUpEvidence } from "../pi/handback.ts";

const recordIdentity = { reviewId: "review", createdAt: 1 };
const model = { provider: "offline", modelId: "review", thinkingLevel: "off" };

type ArtifactFixture = {
  readonly directory: string;
  readonly writer: ReviewArtifactWriter;
  readonly conversations: readonly ConversationRecord[];
  readonly messages: readonly MessageRecord[];
  readonly request: RequestRecord;
};

function createConversation(id: string): ConversationRecord {
  return {
    ...recordIdentity, type: "conversation", id, requestId: null,
    anchor: {
      path: "code.lua", side: "workspace", first: 1, last: 1,
      lines: ["source"], observedAt: 1, source: { kind: "disk" },
    },
  };
}

async function createArtifactFixture(t: TestContext): Promise<ArtifactFixture> {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-artifact-"));
  const previousStateDirectory = process.env.PARLEY_STATE_DIR;
  let writer: ReviewArtifactWriter | undefined;
  t.after(async () => {
    try {
      await writer?.close();
    } finally {
      if (previousStateDirectory === undefined) {
        delete process.env.PARLEY_STATE_DIR;
      } else {
        process.env.PARLEY_STATE_DIR = previousStateDirectory;
      }
      await fs.rm(directory, { recursive: true, force: true });
    }
  });

  const workspace = path.join(directory, "work");
  await fs.mkdir(workspace);
  process.env.PARLEY_STATE_DIR = path.join(directory, "state");
  writer = await ReviewArtifactWriter.create({
    type: "review", schemaVersion: 1, id: "review",
    workspace, startingCommit: "a".repeat(40), createdAt: 1,
  });
  await writer.append([
    { ...recordIdentity, type: "session", id: "parent", role: "parent", sessionId: "parent-session",
      transcriptPath: path.join(directory, "parent.jsonl"), startEntryId: null, parentSessionRecordId: null, model },
    { ...recordIdentity, type: "preparation", id: "preparation", parentSessionRecordId: "parent",
      objective: "Review error handling", scope: ["code.lua"], decisions: [], guidelines: [], context: [] },
  ]);

  const conversations = ["a", "b"].map(createConversation);
  const messages: MessageRecord[] = conversations.map(conversation => ({
    ...recordIdentity, type: "message", id: `human-${conversation.id}`,
    conversationId: conversation.id, requestId: "ask", parentId: null,
    role: "human", author: "Reviewer", origin: "editor",
    lines: [`Question ${conversation.id}`], version: 1, supersedes: [], replacesId: null,
  }));
  const request: RequestRecord = {
    ...recordIdentity, type: "request", id: "ask", kind: "ask", preparationId: "preparation", instructions: null,
    submissions: messages.map(message => ({
      conversationId: message.conversationId, baseVersion: 0, baseTipId: null,
      messageIds: [message.id], version: 1, tipId: message.id,
    })),
  };
  return { directory, writer, conversations, messages, request };
}

function object(value: unknown): Record<string, unknown> {
  assert(value !== null && typeof value === "object" && !Array.isArray(value));
  return value as Record<string, unknown>;
}

test("durable multi-conversation acceptance, publication and receipts remain distinct from pickup/completion", async t => {
  const { directory, writer, conversations, messages, request } = await createArtifactFixture(t);
  const before = await fs.readFile(writer.filename);
  await assert.rejects(writer.append([...conversations, ...messages]), /complete accepting request marker/);
  assert.deepEqual(await fs.readFile(writer.filename), before);
  await writer.append([...conversations, ...messages, request]);
  assert.equal(writer.snapshot().activeRequestId, "ask");
  assert.deepEqual(writer.snapshot().conversations.map(item => item.messages[0].id), ["human-a", "human-b"]);
  assert.throws(() => reviewHandback(writer.snapshot(), writer.filename), /active/);

  const replies: MessageRecord[] = messages.map(message => ({
    ...message, id: `agent-${message.conversationId}`, parentId: message.id,
    role: "agent", author: "Agent", origin: "review-session", lines: ["Answer"], version: 2,
  }));
  await writer.append([
    { ...recordIdentity, type: "session", id: "agent-session", role: "review", sessionId: "review-session",
      transcriptPath: path.join(directory, "review.jsonl"), startEntryId: null, parentSessionRecordId: "parent", model },
    ...replies,
    { ...recordIdentity, type: "outcome", id: "outcome", requestId: "ask", status: "completed", detail: null },
  ]);
  const receipt: ApplicationRecord = {
    ...recordIdentity, type: "application", id: "receipt", requestId: "ask", editorId: "editor",
    messageIds: ["agent-a"], status: "applied", placement: "unplaced", detail: "Source changed",
  };
  await writer.append([receipt]);
  await assert.rejects(writer.append([{ ...receipt, id: "duplicate-receipt" }]), /already applied/);
  const contents = await fs.readFile(writer.filename);
  const observed = await writer.inspect();
  assert.deepEqual(observed, writer.snapshot());
  const pickup = reviewHandback(observed, writer.filename);
  const parsedSummary: unknown = JSON.parse(pickup.text);
  const summary = object(parsedSummary);
  const totals = object(summary.totals);
  const provenance = object(summary.provenance);
  assert.equal(summary.state, "open");
  assert.equal(totals.publishedMessages, 2);
  assert.equal(totals.messagesWithAnyUnplacedReceipt, 1);
  assert.equal(totals.messagesWithoutReceipt, 1);
  assert.deepEqual(provenance.sessions, observed.sessions);
  assert.equal(observed.sessions[0].record.sessionId, "parent-session");
  assert.equal(pickup.artifactPath, writer.filename);
  assert(Buffer.byteLength(pickup.text) <= 24 * 1024);
  assert.deepEqual(await fs.readFile(writer.filename), contents);
  await writer.append([{ ...request, id: "wrap", kind: "wrap-up", submissions: [] }]);
  await assert.rejects(writer.append([{ ...conversations[0], id: "wrap-note", requestId: "wrap" }]), /publication-capable/);
  await assert.rejects(writer.append([{ ...replies[0], id: "wrap-reply", requestId: "wrap", parentId: "agent-a", version: 3 }]), /not wrap-up/);
  await writer.append([{ ...recordIdentity, type: "outcome", id: "wrap-failed", requestId: "wrap", status: "failed", detail: "No summary" }]);
  await writer.close();
  assert.equal((await readReviewArtifact(writer.filename)).end, undefined);
});

test("read-only artifact inspection retains orphan captures and rejects a truncated tail without repair", async t => {
  const { directory, writer, conversations, messages } = await createArtifactFixture(t);
  const orphanPath = path.join(directory, "orphan.jsonl");
  // Bypass the writer to simulate a crash after capture but before acceptance.
  const unacceptedRecords = [conversations[0], messages[0]];
  const capturedBytes = Buffer.from(unacceptedRecords.map(record => JSON.stringify(record) + "\n").join(""));
  const bytes = Buffer.concat([await fs.readFile(writer.filename), capturedBytes]);
  await fs.writeFile(orphanPath, bytes);
  const observed = await readReviewArtifact(orphanPath);
  assert.equal(observed.conversations[0].messages.length, 0);
  assert.deepEqual(observed.unacceptedMessages.map(item => item.id), ["human-a"]);
  assert.equal(observed.requests.length, 0);
  assert.equal(observed.diagnostics[0].code, "unaccepted-captures");
  const parsedEvidence: unknown = JSON.parse(reviewWrapUpEvidence(observed));
  const evidence = object(parsedEvidence);
  assert.deepEqual(evidence.excludedUnacceptedCaptureIds, ["human-a"]);
  assert.deepEqual(evidence.records, observed.records.filter(record => record.id !== "human-a"));
  assert.deepEqual(await fs.readFile(orphanPath), bytes);

  const truncated = bytes.subarray(0, -1);
  await fs.writeFile(orphanPath, truncated);
  await assert.rejects(readReviewArtifact(orphanPath), /incomplete JSONL tail/);
  assert.deepEqual(await fs.readFile(orphanPath), truncated);
});

test("request parsing preserves the distinct Ask, Investigate and wrap-up payload contracts", () => {
  const submission = {
    conversationId: "a", baseVersion: 0, baseTipId: null,
    messageIds: ["human-a"], version: 1, tipId: "human-a",
  };
  const base = { ...recordIdentity, type: "request", id: "request", preparationId: "preparation" };
  const validPayloads: readonly Pick<RequestRecord, "kind" | "instructions" | "submissions">[] = [
    { kind: "ask", instructions: null, submissions: [submission] },
    { kind: "investigate", instructions: "Inspect error handling", submissions: [] },
    { kind: "wrap-up", instructions: null, submissions: [] },
  ];
  for (const payload of validPayloads) {
    const record = { ...base, ...payload };
    assert.deepEqual(parseArtifactRecord(record), record);
  }
  for (const payload of [
    { kind: "ask", instructions: null, submissions: [] },
    { kind: "ask", instructions: "Not allowed", submissions: [submission] },
    { kind: "investigate", instructions: null, submissions: [] },
    { kind: "investigate", instructions: "Inspect error handling", submissions: [submission] },
    { kind: "wrap-up", instructions: "Not allowed", submissions: [] },
    { kind: "wrap-up", instructions: null, submissions: [submission] },
  ]) {
    assert.throws(() => parseArtifactRecord({ ...base, ...payload }), /Ask requires comments/);
  }
});

test("source observations validate nested fields and must match the anchor side", () => {
  const conversation = createConversation("a");
  const anchor = conversation.anchor;
  const observations: readonly Pick<SourceAnchor, "side" | "source">[] = [
    { side: "workspace", source: { kind: "disk" } },
    { side: "workspace", source: { kind: "editor", editorId: "editor", bufferId: 1, changedTick: 0 } },
    { side: "base", source: { kind: "commit", commit: "a".repeat(40) } },
  ];
  for (const observation of observations) {
    const record = { ...conversation, anchor: { ...anchor, ...observation } };
    assert.deepEqual(parseArtifactRecord(record), record);
    const wrongSide = observation.side === "base" ? "workspace" : "base";
    assert.throws(() => parseArtifactRecord({ ...record, anchor: { ...record.anchor, side: wrongSide } }),
      /source observation does not match anchor side/);
  }
  const invalidObservations = [
    { source: { kind: "disk", extra: true }, error: /expected exactly these fields/ },
    { source: { kind: "editor", editorId: "editor", bufferId: 0, changedTick: 0 }, error: /expected a safe integer >= 1/ },
    { source: { kind: "editor", editorId: "editor", bufferId: 1 }, error: /expected exactly these fields/ },
    { source: { kind: "commit", commit: "short" }, error: /expected a full Git commit identity/ },
    { source: { kind: "unknown" }, error: /unsupported source observation/ },
  ];
  for (const { source, error } of invalidObservations) {
    assert.throws(() => parseArtifactRecord({ ...conversation, anchor: { ...anchor, source } }), error);
  }
});

test("human revisions validate the exact suffix without activating unaccepted captures", async t => {
  const { directory, writer, conversations, messages, request } = await createArtifactFixture(t);
  await writer.append([...conversations, ...messages, request,
    { ...recordIdentity, type: "outcome", id: "failed", requestId: "ask", status: "failed", detail: "Reviewer unavailable" }]);
  const revision: MessageRecord = {
    ...messages[0], id: "revision", requestId: "revise",
    lines: ["Revised question"], version: 2, supersedes: ["human-a"], replacesId: "human-a",
  };
  const revisedRequest: RequestRecord = {
    ...request, id: "revise",
    submissions: [{
      conversationId: "a", baseVersion: 1, baseTipId: "human-a",
      messageIds: ["revision"], version: 2, tipId: "revision",
    }],
  };
  const revisionCapturePath = path.join(directory, "revision-capture.jsonl");
  const revisionBytes = Buffer.from(JSON.stringify(revision) + "\n");
  const capturedBytes = Buffer.concat([await fs.readFile(writer.filename), revisionBytes]);
  await fs.writeFile(revisionCapturePath, capturedBytes);
  const captured = await readReviewArtifact(revisionCapturePath);
  assert.deepEqual(captured.conversations[0].messages.map(message => message.id), ["human-a"]);
  assert.equal(captured.conversations[0].version, 1);
  assert.deepEqual(captured.conversations[0].superseded, []);
  assert.deepEqual(captured.unacceptedMessages, [revision]);

  const before = await fs.readFile(writer.filename);
  const invalidRevisions: readonly MessageRecord[] = [
    { ...revision, supersedes: [] },
    { ...revision, version: 3 },
    { ...revision, replacesId: "human-b" },
    { ...revision, parentId: "human-b" },
  ];
  for (const invalid of invalidRevisions) {
    await assert.rejects(writer.append([invalid, revisedRequest]), ArtifactError);
    assert.deepEqual(await fs.readFile(writer.filename), before);
  }
  await writer.append([revision, revisedRequest]);
  const history = writer.snapshot().conversations[0];
  assert.equal(history.version, 2);
  assert.deepEqual(history.messages, [revision]);
  assert.deepEqual(history.superseded, [{ version: 1, messages: [messages[0]] }]);
  assert.deepEqual(await writer.inspect(), writer.snapshot());
});

test("queued appends capture caller data, recover from invalid records, and drain before close", async t => {
  const { writer, conversations, messages, request } = await createArtifactFixture(t);
  const staleRequest: RequestRecord = {
    ...request,
    submissions: request.submissions.map(submission => ({ ...submission, baseVersion: 1 })),
  };
  const rejectedAppend = assert.rejects(
    writer.append([...conversations, ...messages, staleRequest]),
    /submission base does not match/,
  );
  const mutableMessage = {
    ...messages[0], lines: ["Question 🗂 café"], supersedes: [...messages[0].supersedes],
  };
  const acceptedAppend = writer.append([...conversations, mutableMessage, messages[1], request]);
  // Mutate before yielding: append must capture caller-owned arrays synchronously.
  mutableMessage.lines[0] = "Changed after append";
  mutableMessage.supersedes.push("foreign-id");
  await Promise.all([rejectedAppend, acceptedAppend]);
  const snapshot = writer.snapshot();
  const capturedMessage = snapshot.conversations[0].messages[0];
  assert.deepEqual(capturedMessage.lines, ["Question 🗂 café"]);
  assert.deepEqual(capturedMessage.supersedes, []);
  assert.equal(Reflect.set(capturedMessage.lines, 0, "Mutated snapshot"), false);
  assert.deepEqual(await writer.inspect(), snapshot);

  const outcome: OutcomeRecord = {
    ...recordIdentity, type: "outcome", id: "failed", requestId: "ask",
    status: "failed", detail: "Reviewer unavailable",
  };
  const pendingAppend = writer.append([outcome]);
  const closing = writer.close();
  assert.equal(writer.close(), closing);
  await assert.rejects(writer.append([outcome]), /closing\/closed/);
  await Promise.all([pendingAppend, closing]);
  assert.equal((await readReviewArtifact(writer.filename)).requests[0].outcome?.id, "failed");
});

test("foreign writes stop further appends without advancing or repairing the committed snapshot", async t => {
  const { writer } = await createArtifactFixture(t);
  const damaged = await ReviewArtifactWriter.create({ ...writer.snapshot().header, id: "damaged" });
  let failure: ArtifactError | undefined;
  try {
    const snapshot = damaged.snapshot();
    await fs.appendFile(damaged.filename, "partial foreign write");
    const bytes = await fs.readFile(damaged.filename);
    const ending = { ...recordIdentity, reviewId: "damaged", type: "review-end", id: "end", summary: "Done" };
    await assert.rejects(damaged.append([ending]), (error: unknown) => {
      assert(error instanceof ArtifactError);
      assert.match(error.message, /Writer stopped/);
      failure = error;
      return true;
    });
    assert.equal(damaged.snapshot(), snapshot);
    await assert.rejects(damaged.append([ending]), error => error === failure);
    await assert.rejects(damaged.inspect(), error => error === failure);
    assert.deepEqual(await fs.readFile(damaged.filename), bytes);
  } finally {
    if (failure) {
      await assert.rejects(damaged.close(), error => error === failure);
    } else {
      await damaged.close();
    }
  }
});
