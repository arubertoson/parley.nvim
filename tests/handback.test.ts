import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { readReviewArtifact } from "../pi/artifact.ts";
import type { ArtifactRecord, ConversationRecord, MessageRecord, OutcomeRecord, RequestRecord, ReviewArtifactSnapshot, SessionRecord } from "../pi/artifact.ts";
import { reviewHandback, reviewWrapUpEvidence, reviewWrapUpSummary } from "../pi/handback.ts";

const common = { reviewId: "review", createdAt: 1 };
const model = { provider: "offline", modelId: "review", thinkingLevel: "off" };
const artifactPath = "/state/review.jsonl";
const reviewer: SessionRecord = {
  ...common, type: "session", id: "reviewer", role: "review", sessionId: "review-session",
  transcriptPath: "/state/reviewer.jsonl", startEntryId: null, parentSessionRecordId: "parent", model,
};

async function readSnapshot(t: test.TestContext, records: readonly ArtifactRecord[]): Promise<ReviewArtifactSnapshot> {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-handback-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const filename = path.join(directory, "review.jsonl");
  const prefix: ArtifactRecord[] = [
    { type: "review", schemaVersion: 1, id: "review", workspace: "/workspace", startingCommit: "a".repeat(40), createdAt: 1 },
    { ...common, type: "session", id: "parent", role: "parent", sessionId: "parent-session",
      transcriptPath: "/state/parent.jsonl", startEntryId: null, parentSessionRecordId: null, model },
    { ...common, type: "preparation", id: "preparation", parentSessionRecordId: "parent",
      objective: "Review recorded evidence", scope: ["code.lua"], decisions: [], guidelines: [], context: [] },
  ];
  await fs.writeFile(filename, [...prefix, ...records].map(record => JSON.stringify(record) + "\n").join(""));
  return readReviewArtifact(filename);
}

function investigation(id: string): RequestRecord {
  return { ...common, type: "request", id, kind: "investigate", preparationId: "preparation",
    instructions: "Inspect error handling", submissions: [] };
}

function outcome(requestId: string, status: OutcomeRecord["status"] = "completed"): OutcomeRecord {
  return { ...common, type: "outcome", id: `outcome-${requestId}`, requestId, status,
    detail: status === "completed" ? null : "Reviewer stopped" };
}

function conversation(id: string): ConversationRecord {
  return { ...common, type: "conversation", id, requestId: "request",
    anchor: { path: "code.lua", side: "workspace", first: 1, last: 1,
      lines: ["source"], observedAt: 1, source: { kind: "disk" } } };
}

function publication(conversationId: string, lines: readonly string[] = ["Finding"]): MessageRecord {
  return { ...common, type: "message", id: `message-${conversationId}`, conversationId, requestId: "request",
    parentId: null, role: "agent", author: "Review agent", origin: "review-session", lines,
    version: 1, supersedes: [], replacesId: null };
}

function object(value: unknown): Record<string, unknown> {
  assert(value !== null && typeof value === "object" && !Array.isArray(value));
  return value as Record<string, unknown>;
}

function array(value: unknown): readonly unknown[] {
  assert(Array.isArray(value));
  return value;
}

test("handback prioritizes recent unsuccessful requests before completed requests and reports omissions", async t => {
  const records: ArtifactRecord[] = [];
  for (let index = 0; index < 12; index++) {
    const id = `request-${index}`;
    records.push(investigation(id));
    if (index === 0) records.push(reviewer);
    const status = index % 4 === 0 ? "failed" : index % 4 === 1 ? "cancelled" : "completed";
    records.push(outcome(id, status));
  }
  const snapshot = await readSnapshot(t, records);
  const handback = object(JSON.parse(reviewHandback(snapshot, artifactPath).text));
  assert.deepEqual(array(handback.requests).map(request => object(request).id), [
    "request-9", "request-8", "request-5", "request-4", "request-1", "request-0", "request-11", "request-10",
  ]);
  assert.deepEqual(handback.omitted, { requests: 4, conversations: 0 });
  assert.deepEqual(object(handback.totals).outcomes, { completed: 6, failed: 3, cancelled: 3, missing: 0 });
  assert.deepEqual(object(array(handback.requests)[0]).outcome, {
    id: "outcome-request-9", status: "cancelled", createdAt: 1, detail: { text: "Reviewer stopped", truncated: false },
  });
});

test("message excerpts preserve exact fits and newlines without splitting surrogate pairs", async t => {
  const records: ArtifactRecord[] = [investigation("request"), reviewer];
  const bodies = [[], ["x".repeat(512)], ["x".repeat(511) + "😀"], ["x".repeat(510), "y"], ["x".repeat(512), ""]];
  for (const [index, lines] of bodies.entries()) {
    const id = `conversation-${index}`;
    records.push(conversation(id), publication(id, lines));
  }
  records.push(outcome("request"));
  const snapshot = await readSnapshot(t, records);
  const handback = object(JSON.parse(reviewHandback(snapshot, artifactPath).text));
  const samples = array(handback.conversations).map(sample => object(object(sample).latest));
  assert.deepEqual(samples.map(sample => sample.body), [
    { text: "x".repeat(512), truncated: true },
    { text: "x".repeat(510) + "\ny", truncated: false },
    { text: "x".repeat(511), truncated: true },
    { text: "x".repeat(512), truncated: false },
    { text: "", truncated: false },
  ]);
  assert.equal(object(array(handback.requests)[0]).publishedMessages, 5);
});

test("receipt totals count messages independently of overlapping editor receipts", async t => {
  const snapshot = await readSnapshot(t, [
    investigation("request"), reviewer,
    conversation("received"), publication("received"), conversation("unknown"), publication("unknown"),
    outcome("request"),
    { ...common, type: "application", id: "incompatible", requestId: "request", editorId: "editor-a",
      messageIds: ["message-received"], status: "incompatible", placement: null, detail: "History changed" },
    { ...common, type: "application", id: "applied-a", requestId: "request", editorId: "editor-a",
      messageIds: ["message-received"], status: "applied", placement: "unplaced", detail: null },
    { ...common, type: "application", id: "applied-b", requestId: "request", editorId: "editor-b",
      messageIds: ["message-received"], status: "applied", placement: "placed", detail: null },
  ]);
  const handback = object(JSON.parse(reviewHandback(snapshot, artifactPath).text));
  const totals = object(handback.totals);
  assert.equal(totals.applicationReceipts, 3);
  assert.equal(totals.messagesWithAnyAppliedReceipt, 1);
  assert.equal(totals.messagesWithAnyIncompatibleReceipt, 1);
  assert.equal(totals.messagesWithAnyUnplacedReceipt, 1);
  assert.equal(totals.messagesWithoutReceipt, 1);
  assert.deepEqual(array(handback.conversations).map(sample => object(object(sample).latest).delivery), [
    { anyApplied: false, anyIncompatible: false, anyUnplaced: false, noRecordedReceipt: true },
    { anyApplied: true, anyIncompatible: true, anyUnplaced: true, noRecordedReceipt: false },
  ]);
  assert.match(reviewWrapUpSummary(snapshot, artifactPath), /1 incompatible receipt\(s\), 1 unplaced receipt\(s\); 1 message\(s\) have no receipt/);
});

test("conversation sampling uses accepted tips in record order, not later orphan captures or timestamps", async t => {
  const records: ArtifactRecord[] = [investigation("request"), reviewer];
  for (let index = 0; index < 10; index++) {
    const id = `conversation-${index}`;
    records.push(conversation(id), { ...publication(id), createdAt: 100 - index });
  }
  records.push(outcome("request"));
  const accepted: MessageRecord = { ...publication("conversation-0"), id: "accepted", role: "human",
    requestId: "ask", parentId: "message-conversation-0", author: "Human", origin: "editor", version: 2 };
  const orphan: MessageRecord = { ...accepted, id: "orphan", conversationId: "conversation-1", requestId: "unaccepted",
    parentId: "message-conversation-1", lines: ["Unaccepted capture"] };
  records.push(accepted, {
    ...common, type: "request", id: "ask", kind: "ask", preparationId: "preparation", instructions: null,
    submissions: [{ conversationId: "conversation-0", baseVersion: 1, baseTipId: "message-conversation-0",
      messageIds: ["accepted"], version: 2, tipId: "accepted" }],
  }, outcome("ask"), orphan);
  const snapshot = await readSnapshot(t, records);
  const handback = object(JSON.parse(reviewHandback(snapshot, artifactPath).text));
  const samples = array(handback.conversations).map(object);
  assert.deepEqual(samples.map(sample => sample.id), [
    "conversation-0", "conversation-9", "conversation-8", "conversation-7",
    "conversation-6", "conversation-5", "conversation-4", "conversation-3",
  ]);
  assert.equal(object(samples[0].opening).id, "message-conversation-0");
  assert.equal(object(samples[0].latest).id, "accepted");
  assert.equal(object(samples[0].latest).delivery, null);
  assert.equal(object(handback.totals).unacceptedHumanCaptures, 1);
  assert.deepEqual(handback.omitted, { requests: 0, conversations: 2 });
  const evidence = object(JSON.parse(reviewWrapUpEvidence(snapshot)));
  assert.deepEqual(evidence.records, snapshot.records.filter(record => record.id !== "orphan"));
  assert.deepEqual(evidence.excludedUnacceptedCaptureIds, ["orphan"]);
  assert.equal(evidence.asOf, "orphan");
});

test("oversized samples roll back omissions and stop without skipping to smaller later samples", async t => {
  const small = conversation("small");
  const large = { ...conversation("large"), anchor: { ...small.anchor, path: "界".repeat(9 * 1024) } };
  const snapshot = await readSnapshot(t, [
    { ...investigation("request"), instructions: "x".repeat(513) }, reviewer,
    small, publication("small"), large, publication("large"), outcome("request"),
  ]);
  const pickup = reviewHandback(snapshot, artifactPath);
  const handback = object(JSON.parse(pickup.text));
  assert.deepEqual(handback.conversations, []);
  assert.deepEqual(handback.omitted, { requests: 0, conversations: 2 });
  assert.deepEqual(object(array(handback.requests)[0]).instructions, { text: "x".repeat(512), truncated: true });
  assert(Buffer.byteLength(pickup.text) <= 24 * 1024);

  const metadataOnly = { ...handback, requests: [], omitted: { requests: 1, conversations: 2 } };
  const availablePathBytes = 24 * 1024 - Buffer.byteLength(JSON.stringify(metadataOnly)) + Buffer.byteLength(artifactPath);
  const constrainedPickup = reviewHandback(snapshot, "/" + "x".repeat(availablePathBytes - 1));
  const constrained = object(JSON.parse(constrainedPickup.text));
  assert.equal(Buffer.byteLength(constrainedPickup.text), 24 * 1024);
  assert.deepEqual(constrained.requests, []);
  assert.deepEqual(constrained.omitted, { requests: 1, conversations: 2 });
  assert.throws(() => reviewHandback(snapshot, "/" + "界".repeat(9 * 1024)), /Essential handback provenance exceeds 24 KiB/);
});

test("wrap-up evidence is complete or rejected at its byte bound, never excerpted", async t => {
  const snapshot = await readSnapshot(t, [
    { ...investigation("large"), instructions: "界".repeat(1400 * 1024) }, outcome("large", "failed"),
  ]);
  assert.throws(() => reviewWrapUpEvidence(snapshot), /exceeds 4 MiB/);
});

test("wrap-up text preserves prose and excludes wrap-up attempts from investigation outcomes", async t => {
  const snapshot = await readSnapshot(t, [
    investigation("completed"), reviewer, outcome("completed"),
    investigation("failed"), outcome("failed", "failed"),
    investigation("cancelled"), outcome("cancelled", "cancelled"),
    { ...investigation("wrap-up"), kind: "wrap-up", instructions: null }, outcome("wrap-up", "failed"),
    { ...common, type: "review-end", id: "end", summary: "Recorded end" },
  ]);
  const summary = reviewWrapUpSummary(snapshot, artifactPath, "## Coverage\nRecorded findings only.");
  assert.match(summary, /3 investigation\/Ask request\(s\); 1 completed, 1 failed, 1 cancelled/);
  assert.match(summary, /## Coverage\nRecorded findings only\./);
  assert.doesNotMatch(summary, /No usable reviewer summary/);
  assert.match(reviewWrapUpSummary(snapshot, artifactPath), /No usable reviewer summary/);
  assert.doesNotMatch(reviewWrapUpSummary(snapshot, artifactPath, ""), /No usable reviewer summary/);
  assert.doesNotThrow(() => reviewWrapUpSummary(snapshot, artifactPath, "Tabs\tand\nnewlines"));
  assert.throws(() => reviewWrapUpSummary(snapshot, artifactPath, "Control\0character"), /control characters/);
  assert.throws(() => reviewWrapUpSummary(snapshot, artifactPath, "界".repeat(6 * 1024)), /16 KiB/);

  const handback = object(JSON.parse(reviewHandback(snapshot, artifactPath).text));
  assert.equal(handback.state, "ended");
  assert.deepEqual(handback.end, { id: "end", createdAt: 1, summary: { text: "Recorded end", truncated: false } });
});
