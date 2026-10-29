// Paired request policy and bounded upload staging, not mechanical sockets or
// agent execution. Pi is the only artifact writer. Lost delivery never resumes
// an upload or replays an accepted request; evidence remains inspectable.
import { createHash, randomUUID } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { isDeepStrictEqual, TextDecoder } from "node:util";
import { parseArtifactRecord, ReviewArtifactWriter } from "./artifact.ts";
import type { ArtifactRecord, ConversationRecord, MessageRecord, OutcomeRecord, PreparationRecord, RequestRecord, ReviewArtifactSnapshot, SessionRecord, SourceAnchor } from "./artifact.ts";
import type { ReviewPeerRequest } from "./bridge.ts";
import type { DiscoveryTool, ReviewInteraction, ReviewModel } from "./interaction.ts";
import { reviewHandback, reviewWrapUpEvidence, reviewWrapUpSummary } from "./handback.ts";
import type { ReviewHandback } from "./handback.ts";
import type { ParleyFork, ParleyInteraction } from "./parley-interaction.ts";

const maxBatchBytes = 4 * 1024 * 1024;
const chunkBytes = 16 * 1024;
const maxPreparationBytes = 32 * 1024;
const maxResultBytes = 16 * 1024 * 1024;
const identityKeys = ["instanceId", "sessionId", "editorId", "nonce"] as const;

export type ReviewCompletion = {
  readonly reviewId: string;
  readonly finishId: string;
  readonly state: "wrapping" | "completed" | "failed";
  readonly summary: string | null;
  readonly artifactPath: string;
  readonly error: string | null;
  readonly cleanupError: string | null;
};

type ResultDownload = {
  readonly id: string;
  readonly digest: string;
  readonly size: number;
  readonly parts: number;
  bytes?: Buffer;
  nextChunkIndex: number;
  // Consume before receipt I/O. Uncertain writes never permit a second claim.
  readonly claimedMessageIds: Set<string>;
};

type BatchUpload = {
  readonly id: string;
  readonly digest: string;
  readonly expectedBytes: number;
  readonly expectedParts: number;
  readonly peer: ReviewPeerRequest;
  readonly chunks: Buffer[];
  readonly expiresAt: number;
  receivedBytes: number;
};

type ParentBoundary = Pick<SessionRecord, "sessionId" | "transcriptPath" | "startEntryId" | "model">;

type ResultMessage = Pick<MessageRecord, "id" | "parentId" | "role" | "author" | "origin" | "createdAt" | "lines" | "version">;

type ResultConversation = {
  readonly id: string;
  readonly anchor: SourceAnchor;
  readonly new: boolean;
  readonly baseVersion: number;
  readonly baseTipId: string | null;
  readonly messages: readonly ResultMessage[];
};

function requireCondition(value: unknown, message: string): asserts value {
  if (!value) {
    throw new Error(message);
  }
}

function fields(value: unknown, keys: readonly string[]): Readonly<Record<string, unknown>> {
  requireCondition(value !== null && typeof value === "object" && !Array.isArray(value), "Expected a JSON object");
  const record = value as Record<string, unknown>;
  requireCondition(Object.keys(record).length === keys.length && keys.every(key => Object.hasOwn(record, key)),
    `Expected exactly these fields: ${keys.join(", ")}`);
  return record;
}

function identifier(value: unknown): string {
  requireCondition(typeof value === "string" && /^[a-zA-Z0-9_-]{1,128}$/.test(value), "Invalid request identifier");
  return value;
}

function integer(value: unknown, minimum: number, maximum: number): number {
  requireCondition(typeof value === "number" && Number.isSafeInteger(value) && value >= minimum && value <= maximum, "Invalid bounded upload integer");
  return value;
}

function array(value: unknown): readonly unknown[] {
  requireCondition(Array.isArray(value), "Expected a JSON array");
  return value;
}

function finishErrorDetail(error: unknown): string {
  return String(error instanceof Error ? error.message : error).slice(0, 4096);
}

// Existence and placement are distinct. Historical observations of deleted files
// remain valid evidence; canonical containment must still be demonstrable.
async function validateSource(root: string, anchor: SourceAnchor): Promise<void> {
  let filename = path.join(root, anchor.path);
  for (;;) {
    try {
      const resolved = await fs.realpath(filename);
      const relative = path.relative(root, resolved);
      requireCondition(relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative), "Source resolves outside the review workspace");
      return;
    } catch (error) {
      if (!(error instanceof Error) || !("code" in error) || error.code !== "ENOENT") throw error;
      try {
        await fs.lstat(filename);
        throw new Error("Unresolvable source symlink; no source association accepted");
      } catch (statError) {
        if (!(statError instanceof Error) || !("code" in statError) || statError.code !== "ENOENT") throw statError;
      }
      const parent = path.dirname(filename);
      requireCondition(parent !== filename && parent.length >= root.length, "Cannot validate source containment");
      filename = parent;
    }
  }
}

// Project only this request's publications. Account each record before allocating
// the aggregate buffer; oversized evidence stays intact in the artifact.
function serializeResult(snapshot: ReviewArtifactSnapshot, request: RequestRecord, outcome: OutcomeRecord): Buffer {
  const session = snapshot.sessions.find(item => item.record.role !== "parent")?.record;
  const envelope = {
    reviewId: snapshot.header.id,
    requestId: request.id,
    sessionId: session?.sessionId ?? null,
    outcome: { id: outcome.id, status: outcome.status, detail: outcome.detail, createdAt: outcome.createdAt },
    ...(snapshot.header.type === "review" ? { report: {
      publishedMessages: snapshot.records.filter(record => record.type === "message" && record.role === "agent" && record.requestId === request.id).length,
      newFindings: snapshot.conversations.filter(history => history.record.requestId === request.id).length,
      explanation: snapshot.requests.find(item => item.record.id === request.id)?.explanation?.text ?? null,
    } } : {}),
  };
  let size = Buffer.byteLength(JSON.stringify({ ...envelope, conversations: [] }));
  const account = (bytes: number): void => {
    size += bytes;
    requireCondition(size <= maxResultBytes, "Results exceed the 16 MiB delivery bound; evidence retained without truncation/application");
  };
  const conversations: ResultConversation[] = [];
  for (const history of snapshot.conversations) {
    const messages = snapshot.records.filter((record): record is MessageRecord => record.type === "message"
      && record.requestId === request.id && record.role === "agent" && record.conversationId === history.record.id);
    if (messages.length === 0) {
      continue;
    }
    const submitted = request.submissions.find(item => item.conversationId === history.record.id);
    requireCondition(submitted || history.record.requestId === request.id, "Published result has no accepted parent/finding relationship");
    const conversation = {
      id: history.record.id,
      anchor: history.record.anchor,
      new: !submitted,
      baseVersion: submitted?.version ?? 0,
      baseTipId: submitted?.tipId ?? null,
    };
    account(Buffer.byteLength(JSON.stringify({ ...conversation, messages: [] })) + (conversations.length > 0 ? 1 : 0));
    const projectedMessages = messages.map((message, index): ResultMessage => {
      const record = {
        id: message.id, parentId: message.parentId, role: message.role, author: message.author,
        origin: message.origin, createdAt: message.createdAt, lines: message.lines, version: message.version,
      };
      account(Buffer.byteLength(JSON.stringify(record)) + (index > 0 ? 1 : 0));
      return record;
    });
    conversations.push({ ...conversation, messages: projectedMessages });
  }
  const bytes = Buffer.from(JSON.stringify({ ...envelope, conversations }));
  requireCondition(bytes.length === size && size <= maxResultBytes, "Result byte accounting mismatch; nothing delivered or truncated");
  return bytes;
}

export class ReviewRequests {
  private writer?: ReviewArtifactWriter;
  private preparation?: PreparationRecord;
  private upload?: BatchUpload;
  private readonly seenBatchIds = new Set<string>();
  private operation?: Promise<unknown>;
  private closed = false;
  private closing?: Promise<void>;
  private creationFailure?: Error;
  private interaction?: ReviewInteraction | ParleyInteraction;
  private executionFailure?: Error;
  private selectedModel?: ReviewModel;
  private readonly requestOwners = new Map<string, ReviewPeerRequest>();
  private readonly resultDownloads = new Map<string, ResultDownload>();
  private completion?: ReviewCompletion;
  private readonly finishIds = new Set<string>();

  constructor(readonly root: string, readonly sessionId: string, private readonly discovery: readonly DiscoveryTool[],
    private readonly reportFailure: (error: unknown) => void, private readonly parley?: ParleyFork) {}

  get reviewId(): string | undefined {
    return this.writer?.snapshot().header.id;
  }

  get initialized(): boolean {
    return this.preparation !== undefined;
  }

  get ended(): boolean {
    return !!this.writer?.snapshot().end;
  }

  get artifactPath(): string | undefined {
    return this.writer?.filename;
  }

  get parentTranscriptPath(): string | undefined {
    return this.writer?.snapshot().sessions.find(item => item.record.role === "parent")?.record.transcriptPath;
  }

  // Both command and socket entry points call this exact operation. Returning
  // 'wrapping' acknowledges coordination, NOT durable review completion.
  beginFinish(reviewId: string, finishId: string, current: () => boolean): ReviewCompletion {
    const writer = this.writer;
    requireCondition(!this.closed && current() && writer?.snapshot().header.id === reviewId && this.preparation,
      "No matching initialized review; nothing wrapped up");
    if (writer.snapshot().end) {
      requireCondition(this.completion, "Completed evidence requires inspection; no summary regenerated");
      return this.completion;
    }
    // Repeated Done observes a durable attempt even when it failed. A failed
    // summary is not permission to replay model work. Pre-acceptance rejection
    // can be retried explicitly because no wrap-up intent/model work occurred.
    const previousCompletion = this.completion;
    if (previousCompletion && (previousCompletion.state === "wrapping"
      || writer.snapshot().requests.some(item => item.record.id === previousCompletion.finishId))) {
      return previousCompletion;
    }
    this.expireTransfers();
    requireCondition(!this.operation && !this.upload && !writer.snapshot().activeRequestId && !this.interaction?.busy,
      "Review work is active or settling. Wait or explicitly cancel it before :Parley done; nothing queued");
    identifier(finishId);
    requireCondition(!this.finishIds.has(finishId) && !writer.snapshot().records.some(item => item.id === finishId),
      "Duplicate finish attempt; query its status, no replay");
    const request: RequestRecord = { type: "request", id: finishId, reviewId, createdAt: Math.floor(Date.now() / 1000),
      kind: "wrap-up", preparationId: this.preparation.id, instructions: null, submissions: [] };
    this.finishIds.add(finishId);
    const completion: ReviewCompletion = { reviewId, finishId, state: "wrapping", summary: null, artifactPath: writer.filename, error: null, cleanupError: null };
    this.completion = completion;
    const operation = this.finish(request, writer, current);
    this.operation = operation;
    operation.catch(error => {
      this.completion = { ...completion, state: "failed", error: finishErrorDetail(error) };
    }).finally(() => {
      if (this.operation === operation) {
        this.operation = undefined;
      }
    });
    return completion;
  }

  beginParentFinish(reviewId: string, finishId: string, parent: Pick<ParentBoundary, "sessionId" | "transcriptPath">,
    current: () => boolean): ReviewCompletion {
    const origin = this.writer?.snapshot().sessions.find(item => item.record.role === "parent")?.record;
    requireCondition(origin?.sessionId === parent.sessionId && origin?.transcriptPath === parent.transcriptPath,
      ":Parley done requires the originating parent session/transcript; no cross-session completion");
    return this.beginFinish(reviewId, finishId, current);
  }

  finishStatus(reviewId: string, finishId?: string): ReviewCompletion {
    requireCondition(!this.closed && this.writer?.snapshot().header.id === reviewId && this.completion
      && (finishId === undefined || this.completion.finishId === finishId), "No matching finish operation; no replay or regeneration");
    return this.completion;
  }

  async waitForFinish(reviewId: string): Promise<ReviewCompletion> {
    const operation = this.operation;
    try {
      await operation;
    } catch {
      // The exact completion state reports the failure.
    }
    return this.finishStatus(reviewId);
  }

  private async finish(request: RequestRecord, writer: ReviewArtifactWriter, current: () => boolean): Promise<void> {
    await Promise.resolve(); // beginFinish owns this operation before any await.
    const snapshot = await writer.inspect();
    requireCondition(!this.closed && current(), "Finish caller changed before acceptance; review remains open");
    const evidence = reviewWrapUpEvidence(snapshot);
    await writer.append([request]); // Durable intent precedes summary model work.
    let summary: string;
    try {
      const prose = await this.interaction?.summarize(request, evidence);
      requireCondition(!this.closed, "Review host shut down during wrap-up; no completion recorded");
      summary = this.parley
        ? this.parley.summary(writer.filename, prose)
        : reviewWrapUpSummary(snapshot, writer.filename, prose);
    } catch (error) {
      await writer.append([{ type: "outcome", id: randomUUID(), reviewId: request.reviewId, createdAt: Math.floor(Date.now() / 1000),
        requestId: request.id, status: this.closed ? "cancelled" : "failed", detail: finishErrorDetail(error) || "Wrap-up failed" }]);
      throw error;
    }
    await writer.append([
      { type: "outcome", id: randomUUID(), reviewId: request.reviewId, createdAt: Math.floor(Date.now() / 1000), requestId: request.id,
        status: "completed", detail: "Wrap-up generated; completion is recorded separately from cleanup/delivery" },
      { type: "review-end", id: randomUUID(), reviewId: request.reviewId, createdAt: Math.floor(Date.now() / 1000), summary },
    ]);
    // Completion is already durable. Cleanup failure must not masquerade as an
    // open review or cause another summary turn on the next explicit Done.
    let cleanupError: string | null = null;
    try {
      await this.interaction?.close();
    } catch (error) {
      cleanupError = finishErrorDetail(error);
    }
    this.completion = { reviewId: request.reviewId, finishId: request.id, state: "completed", summary,
      artifactPath: writer.filename, error: null, cleanupError };
  }

  // /parley review persists a context-free baseline; explicit parent handoffs append
  // revisions. Pairing and health checks never initialize or enrich a review.
  async prepare(value: unknown, parent: ParentBoundary, startingCommit: string, current: () => boolean, model: ReviewModel): Promise<PreparationRecord> {
    if (this.creationFailure) throw this.creationFailure;
    this.expireTransfers();
    requireCondition(!this.closed && !this.operation && !this.upload && !this.writer?.snapshot().activeRequestId && !this.interaction?.busy,
      "Review is busy; preparation was not queued");
    requireCondition(!this.ended, "Review is completed; use /parley review for a new owner, never reopen the old artifact");
    requireCondition(current() && parent.sessionId === this.sessionId, "Parent session changed before preparation");
    const parentSession = this.writer?.snapshot().sessions.find(item => item.record.role === "parent")?.record;
    const selection = parentSession?.model;
    requireCondition(parent.model && model.provider === parent.model.provider && model.id === parent.model.modelId, "Preparation model identity mismatch");
    requireCondition(!this.selectedModel || isDeepStrictEqual(this.selectedModel, model), "Selected review model configuration changed; no silent reconfiguration");
    const selectedModel = structuredClone(model);
    requireCondition(!selection || JSON.stringify(selection) === JSON.stringify(parent.model), "Review model/thinking selection is already frozen; no silent reconfiguration");
    const handoff = fields(value, ["objective", "scope", "decisions", "guidelines", "context"]);
    requireCondition(Buffer.byteLength(JSON.stringify(handoff)) <= maxPreparationBytes, "Bounded preparation exceeds 32 KiB; curate it instead of cloning the parent transcript");
    const id = this.writer?.snapshot().header.id ?? randomUUID();
    const now = Math.floor(Date.now() / 1000);
    const parentId = parentSession?.id ?? randomUUID();
    const preparation = parseArtifactRecord({ ...handoff, type: "preparation", id: randomUUID(), reviewId: id, createdAt: now, parentSessionRecordId: parentId });
    requireCondition(preparation.type === "preparation", "Expected preparation");
    const parentRecord = parseArtifactRecord({ ...parent, type: "session", id: parentId, reviewId: id, createdAt: now, role: "parent", parentSessionRecordId: null });
    const operation = (async () => {
      if (!this.writer) {
        try {
          this.writer = await ReviewArtifactWriter.create({ type: this.parley ? "parley" : "review", schemaVersion: 1, id, workspace: this.root, startingCommit, createdAt: now });
        } catch (error) {
          // Creation may have left partial evidence. Do not silently allocate a
          // different review on the next preparation attempt in this host.
          this.creationFailure = error instanceof Error ? error : new Error(String(error));
          throw this.creationFailure;
        }
      }
      requireCondition(current() && !this.closed, "Parent changed during preparation; retained artifact was not replayed");
      const records = this.writer.snapshot().sessions.length === 0 ? [parentRecord, preparation] : [preparation];
      await this.writer.append(records);
      this.preparation = preparation;
      this.selectedModel = selectedModel;
      return preparation;
    })();
    this.operation = operation;
    try {
      return await operation;
    } finally {
      if (this.operation === operation) this.operation = undefined;
    }
  }

  // Explicit parent pickup only. No staging expiry, model start, socket action,
  // application, evidence append or completion marker is caused by this read.
  async pickup(reviewId: string, parent: Pick<ParentBoundary, "sessionId" | "transcriptPath">,
    current: () => boolean): Promise<ReviewHandback> {
    const writer = this.writer;
    requireCondition(writer && parent.sessionId === this.sessionId, "No matching live parent review owner; inspect the retained artifact manually, without rebinding");
    requireCondition(!this.parley, "Implementation recap returns through its owning interaction, not review pickup");
    const requireReady = (): void => {
      requireCondition(current() && !this.closed && this.writer === writer, "Parent review owner changed during pickup; no handback delivered");
      const snapshot = writer.snapshot();
      const origin = snapshot.sessions.find(item => item.record.role === "parent")?.record;
      requireCondition(snapshot.header.id === reviewId && origin?.sessionId === parent.sessionId
        && origin.transcriptPath === parent.transcriptPath, "Pickup requires the exact originating parent review/session/transcript; no cross-session routing");
      // Stale/disconnected staging is not active work. Observe its validity
      // without expiring/mutating it merely because the parent reads evidence.
      const uploading = this.upload && this.upload.expiresAt >= Date.now() && this.upload.peer.current();
      requireCondition(!this.operation && !uploading && snapshot.activeRequestId === null && !this.interaction?.busy,
        "Review preparation/upload/work is still active or settling; pickup was not queued");
    };
    requireReady();
    const snapshot = await writer.inspect();
    requireReady();
    requireCondition(snapshot === writer.snapshot() || isDeepStrictEqual(snapshot.records, writer.snapshot().records),
      "Review evidence advanced during pickup; request a fresh pickup explicitly");
    return reviewHandback(snapshot, writer.filename);
  }

  private expireTransfers(): void {
    for (const [id, owner] of this.requestOwners) {
      if (!owner.current()) {
        this.resultDownloads.delete(id);
        this.requestOwners.delete(id);
      }
    }
    if (this.upload && (this.upload.expiresAt < Date.now() || !this.upload.peer.current())) {
      this.upload = undefined;
    }
  }

  async handle(request: ReviewPeerRequest): Promise<Readonly<Record<string, unknown>>> {
    if (this.creationFailure) throw this.creationFailure;
    this.expireTransfers();
    requireCondition(!this.closed && request.current() && request.peer.sessionId === this.sessionId, "Review host/peer is no longer current");
    const writer = this.writer;
    const preparation = this.preparation;
    requireCondition(writer && preparation, "Review initialization is incomplete; inspect retained evidence in Pi, without replay");
    const reviewId = writer.snapshot().header.id;
    const payload = request.payload;
    if (request.action === "review-info") {
      fields(payload, identityKeys);
      requireCondition(request.reviewId === undefined, "Review discovery must not assert another review identity");
      return { reviewId, preparationId: preparation.id, activeRequestId: writer.snapshot().activeRequestId,
        busy: !!this.operation || !!this.upload || !!this.interaction?.busy, ended: !!writer.snapshot().end,
        ...(this.parley ? { workflow: "parley" } : {}) };
    }
    requireCondition(request.reviewId === reviewId, "Review identity changed; no request retargeted");
    if (request.action === "review-finish-begin") {
      fields(payload, [...identityKeys, "finishId"]);
      return { ...this.beginFinish(reviewId, identifier(payload.finishId), request.current) };
    }
    if (request.action === "review-finish-status") {
      fields(payload, [...identityKeys, "finishId"]);
      return { ...this.finishStatus(reviewId, identifier(payload.finishId)) };
    }
    if (request.action === "review-result-begin" || request.action === "review-result-chunk" || request.action === "review-result-receipt") {
      return this.handleResult(request, writer);
    }
    if (request.action === "review-batch-begin") {
      return this.beginUpload(request, writer, preparation);
    }
    const upload = this.upload;
    requireCondition(upload && upload.peer.peer.editorId === request.peer.editorId && upload.peer.current() && payload.batchId === upload.id, "Missing/stale upload; it was not resumed or replayed");
    if (request.action === "review-batch-chunk") {
      return this.appendUploadChunk(payload, upload, reviewId);
    }
    fields(payload, [...identityKeys, "batchId", "digest"]);
    requireCondition(request.action === "review-batch-commit" && payload.digest === upload.digest, "Invalid batch commit correlation");
    requireCondition(upload.chunks.length === upload.expectedParts && upload.receivedBytes === upload.expectedBytes, "Incomplete batch; no request accepted");
    const bytes = Buffer.concat(upload.chunks);
    requireCondition(createHash("sha256").update(bytes).digest("hex") === upload.digest, "Captured batch digest mismatch");
    const contents = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    const value: unknown = JSON.parse(contents);
    // Consume before the first await: a concurrent commit cannot append twice.
    this.upload = undefined;
    const operation = this.acceptBatch(value, upload, writer, preparation, request);
    this.operation = operation;
    try {
      return await operation;
    } finally {
      if (this.operation === operation) this.operation = undefined;
    }
  }

  private beginUpload(request: ReviewPeerRequest, writer: ReviewArtifactWriter, preparation: PreparationRecord): Readonly<Record<string, unknown>> {
    requireCondition(!writer.snapshot().end, "Review is completed; use /parley review in Pi, then :Parley start review to select the new review");
    if (this.executionFailure) {
      throw this.executionFailure;
    }
    requireCondition(!writer.snapshot().sessions.some(item => item.record.role !== "parent" && item.end), "Execution session ended after failed startup; inspect retained evidence, no implicit restart");
    const payload = fields(request.payload, [...identityKeys, "batchId", "digest", "bytes", "parts", "preparationId"]);
    requireCondition(payload.preparationId === preparation.id, "Preparation changed before capture acceptance");
    requireCondition(!this.operation && !this.upload && writer.snapshot().activeRequestId === null, "Review is busy; request was not queued");
    const id = identifier(payload.batchId);
    requireCondition(!this.seenBatchIds.has(id) && !writer.snapshot().records.some(record => record.id === id), "Duplicate/stale batch; no replay permitted");
    requireCondition(typeof payload.digest === "string" && /^[a-f0-9]{64}$/.test(payload.digest), "Invalid SHA-256 capture digest");
    const expectedBytes = integer(payload.bytes, 1, maxBatchBytes);
    const expectedParts = integer(payload.parts, 1, maxBatchBytes / chunkBytes);
    requireCondition(expectedParts === Math.ceil(expectedBytes / chunkBytes), "Upload part count does not match exact byte count");
    this.seenBatchIds.add(id);
    this.upload = {
      id, digest: payload.digest, expectedBytes, expectedParts, peer: request,
      chunks: [], receivedBytes: 0, expiresAt: Date.now() + 60_000,
    };
    return { reviewId: writer.snapshot().header.id, batchId: id, status: "staging" };
  }

  private appendUploadChunk(payload: Readonly<Record<string, unknown>>, upload: BatchUpload, reviewId: string): Readonly<Record<string, unknown>> {
    fields(payload, [...identityKeys, "batchId", "index", "hex"]);
    requireCondition(payload.index === upload.chunks.length && upload.chunks.length < upload.expectedParts, "Duplicate/out-of-order batch chunk");
    requireCondition(typeof payload.hex === "string" && payload.hex.length > 0 && payload.hex.length <= chunkBytes * 2 && /^(?:[a-f0-9]{2})+$/.test(payload.hex), "Invalid bounded hexadecimal chunk");
    const chunk = Buffer.from(payload.hex, "hex");
    const expectedBytes = Math.min(chunkBytes, upload.expectedBytes - upload.receivedBytes);
    requireCondition(chunk.length === expectedBytes, "Chunk does not match the declared exact byte sequence");
    upload.chunks.push(chunk);
    upload.receivedBytes += chunk.length;
    return { reviewId, batchId: upload.id, index: upload.chunks.length - 1, status: "staging" };
  }

  private async acceptBatch(value: unknown, upload: BatchUpload, writer: ReviewArtifactWriter, preparation: PreparationRecord, peer: ReviewPeerRequest): Promise<Readonly<Record<string, unknown>>> {
    const payload = fields(value, ["workspace", "sessionId", "editorId", "request", "conversations", "messages"]);
    requireCondition(payload.workspace === this.root && payload.sessionId === this.sessionId && payload.editorId === peer.peer.editorId, "Captured workspace/parent/editor mismatch");
    const rawRequest = fields(payload.request, ["id", "kind", "instructions", "submissions"]);
    requireCondition(rawRequest.id === upload.id, "Captured request does not match its batch identity");
    const reviewId = writer.snapshot().header.id;
    const now = Math.floor(Date.now() / 1000);
    const request = parseArtifactRecord({ ...rawRequest, type: "request", reviewId, createdAt: now, preparationId: preparation.id });
    requireCondition(request.type === "request", "Expected accepting request record");
    requireCondition(request.kind !== "wrap-up", "Wrap-up requires the explicit :Parley done entry point, not a captured batch");
    const conversations: ConversationRecord[] = [];
    const conversationIds = new Set<string>();
    for (const value of array(payload.conversations)) {
      const source = fields(value, ["id", "anchor", "placement"]);
      const record = parseArtifactRecord({ type: "conversation", id: source.id, reviewId, createdAt: now, requestId: null, anchor: source.anchor });
      requireCondition(record.type === "conversation" && !conversationIds.has(record.id), "Duplicate/invalid captured conversation");
      conversationIds.add(record.id);
      const existing = writer.snapshot().conversations.find(item => item.record.id === record.id);
      if (!existing) {
        requireCondition(record.anchor.side === "workspace" && record.anchor.source.kind === "editor" && record.anchor.source.editorId === peer.peer.editorId, "New workspace source observation is not owned by this editor");
      }
      if (source.placement !== null) {
        const placement = fields(source.placement, ["first", "last"]);
        const first = integer(placement.first, 1, Number.MAX_SAFE_INTEGER);
        const last = integer(placement.last, first, Number.MAX_SAFE_INTEGER);
        requireCondition(last - first === record.anchor.last - record.anchor.first, "Placement differs from captured source range");
      }
      await validateSource(this.root, record.anchor);
      if (existing) {
        requireCondition(JSON.stringify(existing.record.anchor) === JSON.stringify(record.anchor), "Original conversation anchor changed; no retargeting permitted");
      } else {
        conversations.push(record);
      }
    }
    const messages: MessageRecord[] = array(payload.messages).map(value => {
      const message = fields(value, ["id", "conversationId", "requestId", "parentId", "role", "author", "origin", "createdAt", "lines", "version", "supersedes", "replacesId"]);
      const record = parseArtifactRecord({ ...message, type: "message", reviewId });
      requireCondition(record.type === "message" && record.role === "human" && record.requestId === request.id
        && record.origin === `editor/${peer.peer.editorId}` && conversationIds.has(record.conversationId)
        && record.lines.join("\n").trim().length > 0, "Invalid captured human provenance/content");
      return record;
    });
    requireCondition(conversationIds.size === request.submissions.length && messages.length === request.submissions.length
      && request.submissions.every(item => conversationIds.has(item.conversationId)), "Batch must capture exactly one human message per submitted conversation");
    requireCondition(request.kind !== "investigate" || (messages.length === 0 && conversationIds.size === 0), "Investigation must not implicitly submit human drafts");
    requireCondition(peer.current() && !this.closed, "Peer changed before durable acceptance; nothing replayed");
    requireCondition(this.selectedModel, "Missing frozen review model configuration");
    const additions: ArtifactRecord[] = [...conversations, ...messages, request];
    const { ReviewInteraction } = await import("./interaction.ts");
    requireCondition(peer.current() && !this.closed, "Peer changed before acceptance; nothing replayed");
    await writer.append(additions);
    this.requestOwners.set(request.id, peer);
    this.interaction ??= this.parley
      ? this.parley.interaction(writer)
      : new ReviewInteraction(writer, this.discovery, this.selectedModel);
    // Model completion is not the acknowledgment. Already accepted work is not
    // replayed if the socket/editor disappears; its outcome remains evidence.
    this.interaction.start(request, preparation).catch(error => {
      this.executionFailure = error instanceof Error ? error : new Error(String(error));
      try {
        this.reportFailure(error);
      } catch (reportError) {
        console.error("Parley execution failure reporting failed", reportError);
      }
    });
    return { reviewId, requestId: request.id, digest: upload.digest, preparationId: preparation.id, createdAt: now, status: "accepted" };
  }

  // Results are fetched only by the socket which accepted this request. Polling
  // pending work is observational; a ready download is single-use, ordered and
  // digest-bound. Disconnect/reconnect does not resume an uncertain application.
  private async handleResult(peer: ReviewPeerRequest, writer: ReviewArtifactWriter): Promise<Readonly<Record<string, unknown>>> {
    const payload = peer.payload;
    const requestId = identifier(payload.requestId);
    const owner = this.requestOwners.get(requestId);
    requireCondition(owner?.current() && owner.peer === peer.peer && peer.current(), "Result owner changed; no recovery or replay performed");
    const snapshot = writer.snapshot();
    const reviewId = snapshot.header.id;
    const accepted = snapshot.requests.find(item => item.record.id === requestId);
    requireCondition(accepted, "Results require an accepted request");
    if (peer.action === "review-result-begin") {
      fields(payload, [...identityKeys, "requestId"]);
      requireCondition(!this.resultDownloads.has(requestId), "Result delivery already began; uncertain delivery must not be replayed");
      if (!accepted.outcome) {
        if (this.executionFailure) throw this.executionFailure;
        const activity = this.interaction?.activity(requestId);
        requireCondition(activity, "Accepted request has no observable runner/outcome; inspect retained evidence");
        return { reviewId, requestId, status: "pending", activity };
      }
      const bytes = serializeResult(snapshot, accepted.record, accepted.outcome);
      const download: ResultDownload = { id: randomUUID(), digest: createHash("sha256").update(bytes).digest("hex"), size: bytes.length,
        parts: Math.ceil(bytes.length / chunkBytes), bytes, nextChunkIndex: 0, claimedMessageIds: new Set() };
      this.resultDownloads.set(requestId, download);
      return { reviewId, requestId, status: "ready", downloadId: download.id, digest: download.digest, bytes: download.size, parts: download.parts };
    }
    const download = this.resultDownloads.get(requestId);
    requireCondition(download && payload.downloadId === download.id, "Unknown/stale result download");
    if (peer.action === "review-result-chunk") {
      fields(payload, [...identityKeys, "requestId", "downloadId", "index"]);
      requireCondition(payload.index === download.nextChunkIndex && download.nextChunkIndex < download.parts && download.bytes, "Duplicate/out-of-order result chunk; no replay");
      const index = download.nextChunkIndex;
      download.nextChunkIndex += 1;
      const hex = download.bytes.subarray(index * chunkBytes, (index + 1) * chunkBytes).toString("hex");
      if (download.nextChunkIndex === download.parts) {
        download.bytes = undefined;
      }
      return { reviewId, requestId, downloadId: download.id, index, hex };
    }
    fields(payload, [...identityKeys, "requestId", "downloadId", "digest", "receiptId", "messageIds", "status", "placement", "detail"]);
    requireCondition(download.nextChunkIndex === download.parts && payload.digest === download.digest, "Receipt precedes complete digest-bound result delivery");
    const receipt = parseArtifactRecord({ type: "application", id: payload.receiptId, reviewId, createdAt: Math.floor(Date.now() / 1000),
      requestId, editorId: peer.peer.editorId, messageIds: payload.messageIds, status: payload.status, placement: payload.placement, detail: payload.detail });
    requireCondition(receipt.type === "application" && receipt.messageIds.length <= 128
      && (receipt.detail === null || receipt.detail.length <= 2048), "Oversized/invalid application receipt");
    let conversationId: string | undefined;
    for (const id of receipt.messageIds) {
      const message = snapshot.records.find(record => record.id === id);
      requireCondition(message?.type === "message" && message.role === "agent" && message.requestId === requestId,
        "Receipt must identify this request's published agent messages");
      requireCondition(!conversationId || conversationId === message.conversationId, "Receipt mixes conversations/placement facts");
      conversationId = message.conversationId;
      requireCondition(!download.claimedMessageIds.has(id) && !snapshot.applications.some(record => record.editorId === peer.peer.editorId && record.messageIds.includes(id)),
        "Message already has an application/incompatibility claim; no replay");
    }
    for (const id of receipt.messageIds) {
      download.claimedMessageIds.add(id);
    }
    await writer.append([receipt]);
    return { reviewId, requestId, downloadId: download.id, receiptId: receipt.id, status: "recorded" };
  }

  async cancel(reviewId: string, requestId: string): Promise<void> {
    requireCondition(!this.closed && this.writer?.snapshot().header.id === reviewId && this.interaction, "No matching live review; nothing cancelled");
    await this.interaction.cancel(requestId);
  }

  // Explicit withdrawal (Review or Parley) is not Done. Refuse acceptance/summary/settlement races
  // before closing authority; ordinary running work is cancelled by close().
  stopParent(reviewId: string, parent: Pick<ParentBoundary, "sessionId" | "transcriptPath">,
    endEntryId: string | null, current: () => boolean): Promise<void> {
    const snapshot = this.writer?.snapshot();
    const origin = snapshot?.sessions.find(item => item.record.role === "parent")?.record;
    const command = "/parley stop";
    requireCondition(!this.closed && current() && snapshot?.header.id === reviewId
      && origin?.sessionId === parent.sessionId && origin?.transcriptPath === parent.transcriptPath,
      `${command} requires the exact originating parent and live review; nothing stopped`);
    requireCondition(!snapshot.end, "Review is already completed; no withdrawal or wrap-up performed");
    requireCondition(!this.operation && this.completion?.state !== "wrapping",
      `Review preparation, acceptance or wrap-up is active. Wait before ${command}; nothing queued or cancelled`);
    const activity = snapshot.activeRequestId ? this.interaction?.activity(snapshot.activeRequestId) : undefined;
    requireCondition((snapshot.activeRequestId === null && !this.interaction?.busy) || activity === "starting" || activity === "working",
      `Review work is settling. Wait before ${command}; nothing queued or cancelled`);
    return this.close(endEntryId);
  }

  close(endEntryId?: string | null): Promise<void> {
    if (this.closing) {
      return this.closing;
    }
    this.closed = true;
    this.upload = undefined;
    for (const download of this.resultDownloads.values()) {
      download.bytes = undefined;
    }
    this.requestOwners.clear();
    this.closing = this.closeResources(endEntryId);
    return this.closing;
  }

  private async closeResources(endEntryId: string | null | undefined): Promise<void> {
    const pending = await Promise.allSettled([this.operation, this.interaction?.close()]);
    const writer = this.writer;
    let failure: { readonly reason: unknown } | undefined = pending.find(item => item.status === "rejected");
    try {
      // A pending commit may have created the interaction while shutdown waited.
      await this.interaction?.close();
    } catch (error) {
      failure ??= { reason: error };
    }
    if (writer) {
      try {
        const snapshot = writer.snapshot();
        const parent = snapshot.sessions.find(item => item.record.role === "parent");
        if (parent && !parent.end && endEntryId !== undefined) {
          await writer.append([{ type: "session-end", id: randomUUID(), reviewId: snapshot.header.id,
            createdAt: Math.floor(Date.now() / 1000), sessionRecordId: parent.record.id, endEntryId }]);
        }
      } catch (error) {
        failure ??= { reason: error };
      } finally {
        try {
          await writer.close();
        } catch (error) {
          failure ??= { reason: error };
        }
      }
    }
    if (failure) {
      throw failure.reason;
    }
  }
}
