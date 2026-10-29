// Pi-owned, append-only review evidence. No SDK, socket, editor, model work or
// import-time I/O. A request marker accepts preceding human captures; unmarked
// captures are evidence, not submitted history. Times are Unix seconds, matching
// editor messages. Record order, never timestamps, establishes relationships.
import { promises as fs } from "node:fs";
import type { FileHandle } from "node:fs/promises";
import path from "node:path";
import { isDeepStrictEqual, TextDecoder } from "node:util";
import { stateDirectory } from "./paths.ts";

export type ReviewHeader = {
  readonly schemaVersion: 1;
  readonly id: string;
  readonly workspace: string;
  readonly startingCommit: string;
  readonly createdAt: number;
} & ({ readonly type: "review" } | { readonly type: "parley" });

type RecordIdentity = {
  readonly id: string;
  readonly reviewId: string;
  readonly createdAt: number;
};

type ModelSelection = {
  readonly provider: string;
  readonly modelId: string;
  readonly thinkingLevel: string;
};

export type SessionRecord = RecordIdentity & {
  readonly type: "session";
  readonly role: "parent" | "review" | "implementation";
  readonly sessionId: string;
  readonly transcriptPath: string;
  // Null means the transcript was empty at this boundary, not "unknown".
  readonly startEntryId: string | null;
  readonly parentSessionRecordId: string | null;
  readonly model: ModelSelection | null;
};

export type SessionEndRecord = RecordIdentity & {
  readonly type: "session-end";
  readonly sessionRecordId: string;
  readonly endEntryId: string | null;
};

type ContextCapture = {
  readonly source: string;
  readonly content: string;
};

export type PreparationRecord = RecordIdentity & {
  readonly type: "preparation";
  readonly parentSessionRecordId: string;
  readonly objective: string;
  readonly scope: readonly string[];
  readonly decisions: readonly string[];
  readonly guidelines: readonly ContextCapture[];
  readonly context: readonly ContextCapture[];
};

export type SourceAnchor = {
  readonly path: string;
  readonly side: "workspace" | "base";
  readonly first: number;
  readonly last: number;
  readonly lines: readonly string[];
  readonly observedAt: number;
  readonly source:
    | { readonly kind: "disk" }
    | { readonly kind: "editor"; readonly editorId: string; readonly bufferId: number; readonly changedTick: number }
    | { readonly kind: "commit"; readonly commit: string };
};

export type ConversationRecord = RecordIdentity & {
  readonly type: "conversation";
  // Non-null for a new agent finding; null for an editor-origin conversation.
  readonly requestId: string | null;
  readonly anchor: SourceAnchor;
};

export type MessageRecord = RecordIdentity & {
  readonly type: "message";
  readonly conversationId: string;
  readonly requestId: string;
  readonly parentId: string | null;
  readonly role: "human" | "agent";
  readonly author: string;
  readonly origin: string;
  readonly lines: readonly string[];
  // Version after accepting this message. A rewind increments once, just like
  // append. Explicit suffix IDs prevent a stale capture from pruning updates.
  readonly version: number;
  readonly supersedes: readonly string[];
  readonly replacesId: string | null;
};

export type Submission = {
  readonly conversationId: string;
  readonly baseVersion: number;
  readonly baseTipId: string | null;
  readonly messageIds: readonly string[];
  readonly version: number;
  readonly tipId: string;
};

export type RequestRecord = RecordIdentity & {
  readonly type: "request";
  // This ID is durable. Transport correlation IDs do not belong in this file.
  readonly kind: "ask" | "investigate" | "wrap-up";
  readonly preparationId: string;
  readonly instructions: string | null;
  readonly submissions: readonly Submission[];
};

// Normal final reviewer prose, not a host verdict or another model turn.
export type RequestExplanationRecord = RecordIdentity & {
  readonly type: "request-explanation";
  readonly requestId: string;
  readonly text: string;
};

export type OutcomeRecord = RecordIdentity & {
  readonly type: "outcome";
  readonly requestId: string;
  readonly status: "completed" | "failed" | "cancelled";
  readonly detail: string | null;
};

export type ApplicationRecord = RecordIdentity & {
  readonly type: "application";
  readonly requestId: string;
  readonly editorId: string;
  readonly messageIds: readonly string[];
  readonly status: "applied" | "incompatible";
  // Applied history may deliberately remain unplaced. This is an editor fact,
  // not permission for the reader to open a source or relocate an anchor.
  readonly placement: "placed" | "unplaced" | null;
  readonly detail: string | null;
};

export type ReviewEndRecord = RecordIdentity & {
  readonly type: "review-end";
  readonly summary: string;
};

export type ArtifactRecord = ReviewHeader | SessionRecord | SessionEndRecord
  | PreparationRecord | ConversationRecord | MessageRecord | RequestRecord
  | RequestExplanationRecord | OutcomeRecord | ApplicationRecord | ReviewEndRecord;

export type ConversationHistory = {
  readonly record: ConversationRecord;
  readonly version: number;
  readonly messages: readonly MessageRecord[];
  readonly superseded: readonly {
    readonly version: number;
    readonly messages: readonly MessageRecord[];
  }[];
};

export type ReviewArtifactSnapshot = {
  readonly header: ReviewHeader;
  readonly records: readonly ArtifactRecord[];
  readonly sessions: readonly { readonly record: SessionRecord; readonly end?: SessionEndRecord }[];
  readonly preparations: readonly PreparationRecord[];
  readonly conversations: readonly ConversationHistory[];
  readonly requests: readonly { readonly record: RequestRecord; readonly explanation?: RequestExplanationRecord; readonly outcome?: OutcomeRecord }[];
  readonly applications: readonly ApplicationRecord[];
  // Complete lines without their accepting marker, e.g. an interrupted append.
  // They remain inspectable but never change a conversation's active history.
  readonly unacceptedMessages: readonly MessageRecord[];
  readonly diagnostics: readonly {
    readonly code: "unaccepted-captures";
    readonly message: string;
    readonly messageIds: readonly string[];
  }[];
  readonly activeRequestId: string | null;
  readonly end?: ReviewEndRecord;
};

export class ArtifactError extends Error {
  constructor(
    readonly filename: string,
    readonly line: number | null,
    message: string,
    options?: ErrorOptions,
  ) {
    super(`${filename}${line === null ? "" : `:${line}`}: ${message}`, options);
    this.name = "ArtifactError";
  }
}

function requireCondition(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

function object(value: unknown): Record<string, unknown> {
  requireCondition(value !== null && typeof value === "object" && !Array.isArray(value), "expected an object");
  return value as Record<string, unknown>;
}

function fields(value: unknown, names: readonly string[]): Record<string, unknown> {
  const record = object(value);
  requireCondition(Object.keys(record).length === names.length
    && names.every(name => Object.hasOwn(record, name)), `expected exactly these fields: ${names.join(", ")}`);
  return record;
}

function text(value: unknown): string {
  requireCondition(typeof value === "string", "expected a string");
  return value;
}

function nonempty(value: unknown): string {
  const result = text(value);
  requireCondition(result.trim().length > 0, "expected a nonempty string");
  return result;
}

function identifier(value: unknown): string {
  const result = text(value);
  requireCondition(/^[a-zA-Z0-9_-]{1,128}$/.test(result), "invalid identifier");
  return result;
}

function nullableIdentifier(value: unknown): string | null {
  return value === null ? null : identifier(value);
}

function integer(value: unknown, minimum = 0): number {
  requireCondition(typeof value === "number" && Number.isSafeInteger(value) && value >= minimum,
    `expected a safe integer >= ${minimum}`);
  return value;
}

function choice<const T extends string>(value: unknown, options: readonly T[]): T {
  for (const option of options) {
    if (value === option) {
      return option;
    }
  }
  throw new Error(`expected one of: ${options.join(", ")}`);
}

function list<T>(value: unknown, parse: (item: unknown) => T): T[] {
  requireCondition(Array.isArray(value), "expected an array");
  const result: T[] = [];
  for (let index = 0; index < value.length; index++) {
    requireCondition(Object.hasOwn(value, index), "sparse arrays are not valid JSON sequences");
    result.push(parse(value[index]));
  }
  requireCondition(Object.keys(value).length === value.length, "unexpected array properties");
  return result;
}

function identifiers(value: unknown): string[] {
  const result = list(value, identifier);
  requireCondition(new Set(result).size === result.length, "duplicate identifiers in a sequence");
  return result;
}

function lines(value: unknown): string[] {
  return list(value, item => {
    const line = text(item);
    requireCondition(!line.includes("\n"), "lines must not contain embedded newlines");
    return line;
  });
}

function absolutePath(value: unknown): string {
  const filename = nonempty(value);
  requireCondition(!filename.includes("\0") && path.isAbsolute(filename) && path.normalize(filename) === filename,
    "expected a normalized absolute filesystem path");
  return filename;
}

function commit(value: unknown): string {
  const result = text(value);
  requireCondition(/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(result), "expected a full Git commit identity");
  return result;
}

function contextCapture(value: unknown): ContextCapture {
  const record = fields(value, ["source", "content"]);
  return { source: nonempty(record.source), content: text(record.content) };
}

function sourceAnchor(value: unknown): SourceAnchor {
  const record = fields(value, ["path", "side", "first", "last", "lines", "observedAt", "source"]);
  const filename = nonempty(record.path);
  // Portable workspace-relative paths, never repository metadata. Actual file
  // existence/symlink containment and live placement are validated by the host.
  requireCondition(!filename.includes("\\") && !/[\x00-\x1f\x7f]/.test(filename)
    && !path.posix.isAbsolute(filename) && !/^[a-zA-Z]:/.test(filename)
    && filename.split("/").every(part => part !== "" && part !== "." && part !== ".." && part !== ".git" && part !== ".jj"),
  "invalid workspace-relative source path");
  const side = choice(record.side, ["workspace", "base"]);
  const first = integer(record.first, 1);
  const last = integer(record.last, first);
  const capturedLines = lines(record.lines);
  requireCondition(capturedLines.length === last - first + 1, "anchor range and captured line count differ");
  const observation = sourceObservation(record.source);
  requireCondition((side === "base") === (observation.kind === "commit"), "source observation does not match anchor side");
  return { path: filename, side, first, last, lines: capturedLines, observedAt: integer(record.observedAt), source: observation };
}

function sourceObservation(value: unknown): SourceAnchor["source"] {
  const source = object(value);
  switch (source.kind) {
    case "disk":
      fields(source, ["kind"]);
      return { kind: "disk" };
    case "editor":
      fields(source, ["kind", "editorId", "bufferId", "changedTick"]);
      return {
        kind: "editor", editorId: identifier(source.editorId),
        bufferId: integer(source.bufferId, 1), changedTick: integer(source.changedTick),
      };
    case "commit":
      fields(source, ["kind", "commit"]);
      return { kind: "commit", commit: commit(source.commit) };
    default:
      throw new Error("unsupported source observation");
  }
}

function submission(value: unknown): Submission {
  const record = fields(value, ["conversationId", "baseVersion", "baseTipId", "messageIds", "version", "tipId"]);
  return {
    conversationId: identifier(record.conversationId), baseVersion: integer(record.baseVersion),
    baseTipId: nullableIdentifier(record.baseTipId), messageIds: identifiers(record.messageIds),
    version: integer(record.version, 1), tipId: identifier(record.tipId),
  };
}

// Validate and copy fields, including nested arrays, without trusting assertions
// or retaining caller-owned data. Cross-record relationships are checked during
// reconstruction by both the reader and the writer, not by this parser alone.
export function parseArtifactRecord(value: unknown): ArtifactRecord {
  const record = object(value);
  if (record.type === "review" || record.type === "parley") {
    fields(record, ["type", "schemaVersion", "id", "workspace", "startingCommit", "createdAt"]);
    requireCondition(record.schemaVersion === 1, `unsupported artifact schema: ${String(record.schemaVersion)}`);
    return {
      type: record.type, schemaVersion: 1, id: identifier(record.id), workspace: absolutePath(record.workspace),
      startingCommit: commit(record.startingCommit), createdAt: integer(record.createdAt),
    };
  }
  const base = { id: identifier(record.id), reviewId: identifier(record.reviewId), createdAt: integer(record.createdAt) };
  const common = ["type", "id", "reviewId", "createdAt"];
  switch (record.type) {
    case "session": {
      fields(record, [...common, "role", "sessionId", "transcriptPath", "startEntryId", "parentSessionRecordId", "model"]);
      let model: ModelSelection | null = null;
      if (record.model !== null) {
        const selection = fields(record.model, ["provider", "modelId", "thinkingLevel"]);
        model = {
          provider: nonempty(selection.provider), modelId: nonempty(selection.modelId),
          thinkingLevel: nonempty(selection.thinkingLevel),
        };
      }
      const role = choice(record.role, ["parent", "review", "implementation"]);
      const parentSessionRecordId = nullableIdentifier(record.parentSessionRecordId);
      requireCondition((role === "parent") === (parentSessionRecordId === null), "invalid session parent provenance");
      requireCondition(role === "parent" || model !== null, "execution session must preserve explicit model/thinking selection");
      return {
        ...base, type: "session", role, sessionId: identifier(record.sessionId), transcriptPath: absolutePath(record.transcriptPath),
        startEntryId: nullableIdentifier(record.startEntryId), parentSessionRecordId, model,
      };
    }
    case "session-end":
      fields(record, [...common, "sessionRecordId", "endEntryId"]);
      return { ...base, type: "session-end", sessionRecordId: identifier(record.sessionRecordId), endEntryId: nullableIdentifier(record.endEntryId) };
    case "preparation":
      fields(record, [...common, "parentSessionRecordId", "objective", "scope", "decisions", "guidelines", "context"]);
      return {
        ...base, type: "preparation", parentSessionRecordId: identifier(record.parentSessionRecordId), objective: nonempty(record.objective),
        scope: list(record.scope, text), decisions: list(record.decisions, text),
        guidelines: list(record.guidelines, contextCapture), context: list(record.context, contextCapture),
      };
    case "conversation":
      fields(record, [...common, "requestId", "anchor"]);
      return { ...base, type: "conversation", requestId: nullableIdentifier(record.requestId), anchor: sourceAnchor(record.anchor) };
    case "message":
      fields(record, [...common, "conversationId", "requestId", "parentId", "role", "author", "origin", "lines", "version", "supersedes", "replacesId"]);
      return {
        ...base, type: "message", conversationId: identifier(record.conversationId), requestId: identifier(record.requestId),
        parentId: nullableIdentifier(record.parentId), role: choice(record.role, ["human", "agent"]),
        author: nonempty(record.author), origin: nonempty(record.origin), lines: lines(record.lines),
        version: integer(record.version, 1), supersedes: identifiers(record.supersedes), replacesId: nullableIdentifier(record.replacesId),
      };
    case "request": {
      fields(record, [...common, "kind", "preparationId", "instructions", "submissions"]);
      const kind = choice(record.kind, ["ask", "investigate", "wrap-up"]);
      const instructions = record.instructions === null ? null : nonempty(record.instructions);
      const submissions = list(record.submissions, submission);
      const payloadError = "Ask requires comments, Investigate requires instructions, and wrap-up submits neither";
      switch (kind) {
        case "ask":
          requireCondition(instructions === null && submissions.length > 0, payloadError);
          break;
        case "investigate":
          requireCondition(instructions !== null && submissions.length === 0, payloadError);
          break;
        case "wrap-up":
          requireCondition(instructions === null && submissions.length === 0, payloadError);
          break;
      }
      requireCondition(new Set(submissions.map(item => item.conversationId)).size === submissions.length, "duplicate submitted conversation");
      return { ...base, type: "request", kind, preparationId: identifier(record.preparationId), instructions, submissions };
    }
    case "request-explanation": {
      fields(record, [...common, "requestId", "text"]);
      const explanation = nonempty(record.text);
      requireCondition(Buffer.byteLength(explanation) <= 16 * 1024 && Buffer.from(explanation).toString("utf8") === explanation
        && !/[\x00-\x08\x0b-\x1f\x7f]/.test(explanation),
        "reviewer explanation exceeds 16 KiB or contains invalid text/control characters");
      return { ...base, type: "request-explanation", requestId: identifier(record.requestId), text: explanation };
    }
    case "outcome": {
      fields(record, [...common, "requestId", "status", "detail"]);
      const status = choice(record.status, ["completed", "failed", "cancelled"]);
      const detail = record.detail === null ? null : nonempty(record.detail);
      requireCondition(status === "completed" || detail !== null, "failed/cancelled outcomes require a diagnostic");
      return { ...base, type: "outcome", requestId: identifier(record.requestId), status, detail };
    }
    case "application": {
      fields(record, [...common, "requestId", "editorId", "messageIds", "status", "placement", "detail"]);
      const status = choice(record.status, ["applied", "incompatible"]);
      const placement = record.placement === null ? null : choice(record.placement, ["placed", "unplaced"]);
      const detail = record.detail === null ? null : nonempty(record.detail);
      const messageIds = identifiers(record.messageIds);
      requireCondition(messageIds.length > 0, "application must identify published messages");
      requireCondition(status === "applied" ? placement !== null : placement === null && detail !== null,
        "applied history needs placement status; incompatible results need a diagnostic, not placement");
      return { ...base, type: "application", requestId: identifier(record.requestId), editorId: identifier(record.editorId), messageIds, status, placement, detail };
    }
    case "review-end":
      fields(record, [...common, "summary"]);
      return { ...base, type: "review-end", summary: text(record.summary) };
    default:
      throw new Error(`unsupported artifact record type: ${String(record.type)}`);
  }
}

function sameIds(actual: readonly string[], expected: readonly string[]): boolean {
  return actual.length === expected.length && actual.every((id, index) => id === expected[index]);
}

type MutableConversationHistory = {
  record: ConversationRecord;
  version: number;
  messages: MessageRecord[];
  superseded: { version: number; messages: MessageRecord[] }[];
};

// A human capture must be valid without changing submitted history.
// Reconstruction checks it again when its accepting request marker is reached.
function validateMessageExtension(history: ConversationHistory, message: MessageRecord): MessageRecord[] {
  requireCondition(message.version === history.version + 1, "message version does not extend the exact conversation version");
  const parentIndex = message.parentId === null ? -1 : history.messages.findIndex(item => item.id === message.parentId);
  requireCondition(message.parentId === null || parentIndex >= 0, "message parent is not active in this conversation");
  const removed = history.messages.slice(parentIndex + 1);
  requireCondition(sameIds(message.supersedes, removed.map(item => item.id)), "superseded suffix does not match exact active history");
  if (message.replacesId !== null) {
    requireCondition(message.role === "human" && removed[0]?.id === message.replacesId && removed[0].role === "human",
      "revision must identify the exact superseded human message");
  }
  if (message.role === "agent") {
    requireCondition(removed.length === 0 && message.replacesId === null, "agent publication cannot rewrite submitted history");
  }
  return removed;
}

function acceptMessage(history: MutableConversationHistory, message: MessageRecord): void {
  const removed = validateMessageExtension(history, message);
  if (removed.length > 0) {
    history.superseded.push({ version: history.version, messages: removed });
  }
  const retainedCount = history.messages.length - removed.length;
  history.messages = [...history.messages.slice(0, retainedCount), message];
  history.version = message.version;
}

// Used only for already copied, acyclic parsed records and reconstructed data.
// Snapshots are safe to lend out, including from a still-active writer.
function freeze<T>(value: T): T {
  if (value !== null && typeof value === "object") {
    for (const nested of Object.values(value)) {
      freeze(nested);
    }
    Object.freeze(value);
  }
  return value;
}

function reconstruct(records: readonly ArtifactRecord[], filename: string): ReviewArtifactSnapshot {
  const header = records[0];
  if (!header || (header.type !== "review" && header.type !== "parley")) {
    throw new ArtifactError(filename, 1, "review header must be the first record; empty files are not empty reviews");
  }
  const ids = new Set([header.id]);
  const executionRole = header.type === "parley" ? "implementation" : "review";
  const sessions = new Map<string, { record: SessionRecord; end?: SessionEndRecord }>();
  const preparations = new Map<string, PreparationRecord>();
  const conversations = new Map<string, MutableConversationHistory>();
  const messages = new Map<string, MessageRecord>();
  const pendingCaptures = new Map<string, MessageRecord[]>();
  const requests = new Map<string, { record: RequestRecord; explanation?: RequestExplanationRecord; outcome?: OutcomeRecord }>();
  const applications: ApplicationRecord[] = [];
  const appliedMessagesByEditor = new Map<string, Set<string>>();
  let activeRequestId: string | null = null;
  let end: ReviewEndRecord | undefined;

  for (let index = 1; index < records.length; index++) {
    const record = records[index];
    try {
      requireCondition(record.type !== "review" && record.type !== "parley", "duplicate workflow header");
      requireCondition(record.reviewId === header.id, "record belongs to another review");
      requireCondition(!ids.has(record.id), `duplicate record identity: ${record.id}`);
      requireCondition(!pendingCaptures.has(record.id) || record.type === "request", "captured request identity reused by a different record type");
      requireCondition(!end || record.type === "session-end" || record.type === "application", "review is already ended");
      switch (record.type) {
        case "session": {
          requireCondition(![...sessions.values()].some(item => item.record.role === record.role || item.record.sessionId === record.sessionId),
            "review requires distinct single parent/review sessions; session replacement is not implicit recovery");
          requireCondition(record.role === "parent" || record.role === executionRole, "execution role does not match workflow authority");
          if (record.role === executionRole) {
            requireCondition(record.parentSessionRecordId !== null && sessions.get(record.parentSessionRecordId)?.record.role === "parent",
              "review session must reference its recorded parent session");
            requireCondition(activeRequestId !== null, "review session cannot start before explicit request acceptance");
            requireCondition(requests.get(activeRequestId)?.record.kind !== "wrap-up", "wrap-up cannot start a reviewer session");
          }
          sessions.set(record.id, { record });
          break;
        }
        case "session-end": {
          const session = sessions.get(record.sessionRecordId);
          requireCondition(session && !session.end, "session end requires an existing session without an ending boundary");
          session.end = record;
          break;
        }
        case "preparation":
          requireCondition(sessions.get(record.parentSessionRecordId)?.record.role === "parent", "preparation requires parent session provenance");
          preparations.set(record.id, record);
          break;
        case "conversation":
          requireCondition(record.requestId === null || (record.requestId === activeRequestId && requests.get(record.requestId)?.record.kind !== "wrap-up"),
            "agent conversation must belong to an active publication-capable request");
          conversations.set(record.id, { record, version: 0, messages: [], superseded: [] });
          break;
        case "message": {
          const history = conversations.get(record.conversationId);
          requireCondition(history, "message references a missing conversation");
          if (record.parentId !== null) {
            const parent = messages.get(record.parentId);
            requireCondition(parent && parent.conversationId === record.conversationId, "message parent belongs to a missing/different conversation");
            requireCondition(requests.has(parent.requestId),
              "message cannot reply to unaccepted captured prose");
          }
          if (record.role === "human") {
            requireCondition(activeRequestId === null, "review is busy; human captures cannot be accepted during an active request");
            requireCondition(!ids.has(record.requestId) && record.requestId !== record.id, "human capture must precede its accepting request marker");
            requireCondition(history.record.requestId === null || requests.has(history.record.requestId), "human capture references an unaccepted finding");
            validateMessageExtension(history, record);
            const captured = pendingCaptures.get(record.requestId) ?? [];
            requireCondition(!captured.some(item => item.conversationId === record.conversationId), "capture only one eligible human draft per conversation/request");
            captured.push(record);
            pendingCaptures.set(record.requestId, captured);
          } else {
            requireCondition(record.requestId === activeRequestId, "agent publication requires the exact active request");
            const request = requests.get(record.requestId);
            requireCondition(request && request.record.kind !== "wrap-up", "agent publication requires an investigation or Ask, not wrap-up");
            requireCondition([...sessions.values()].some(item => item.record.role === executionRole && !item.end),
              "agent publication requires recorded live review-session provenance");
            const submitted = request.record.submissions.find(item => item.conversationId === record.conversationId);
            const previous = history.messages.at(-1);
            if (history.record.requestId === record.requestId) {
              requireCondition(!previous || previous.requestId === record.requestId, "new finding has incompatible history");
            } else {
              requireCondition(submitted && previous && (previous.id === submitted.tipId || (previous.role === "agent" && previous.requestId === record.requestId)),
                "reply must extend an exact submitted tip or this request's previous reply");
            }
            acceptMessage(history, record);
          }
          messages.set(record.id, record);
          break;
        }
        case "request": {
          requireCondition(activeRequestId === null, "review is busy; implicit request queuing is forbidden");
          const preparation = preparations.get(record.preparationId);
          requireCondition(preparation, "request references missing preparation");
          const reviewSession = [...sessions.values()].find(item => item.record.role === executionRole);
          requireCondition(record.kind === "wrap-up" || !reviewSession?.end, "review session has ended; automatic restart is not supported");
          requireCondition(!reviewSession || reviewSession.record.parentSessionRecordId === preparation.parentSessionRecordId,
            "request preparation and review session have different parent provenance");
          const captured = pendingCaptures.get(record.id) ?? [];
          const accepted = new Set<string>();
          for (const submitted of record.submissions) {
            const history = conversations.get(submitted.conversationId);
            requireCondition(history, "request references a missing conversation");
            requireCondition(history.version === submitted.baseVersion && (history.messages.at(-1)?.id ?? null) === submitted.baseTipId,
              "submission base does not match exact active version/tip");
            const additions = captured.filter(item => item.conversationId === submitted.conversationId);
            requireCondition(sameIds(submitted.messageIds, additions.map(item => item.id)), "submission does not reference its exact captured message sequence");
            for (const message of additions) {
              acceptMessage(history, message);
              accepted.add(message.id);
            }
            const tip = history.messages.at(-1);
            requireCondition(tip?.id === submitted.tipId && history.version === submitted.version,
              "submission must identify the exact accepted tip/version");
            requireCondition(record.kind !== "ask" || tip.role === "human", "Ask must submit eligible human comments");
          }
          requireCondition(accepted.size === captured.length, "request marker leaves captured messages outside its submitted conversations");
          pendingCaptures.delete(record.id);
          requests.set(record.id, { record });
          activeRequestId = record.id;
          break;
        }
        case "request-explanation": {
          const request = requests.get(record.requestId);
          requireCondition(header.type === "review" && request && request.record.kind !== "wrap-up"
            && !request.explanation && !request.outcome && activeRequestId === record.requestId
            && [...sessions.values()].some(item => item.record.role === "review" && !item.end),
          "explanation requires this active request's recorded reviewer; no duplicate or late explanation");
          request.explanation = record;
          break;
        }
        case "outcome": {
          const request = requests.get(record.requestId);
          requireCondition(request && !request.outcome && activeRequestId === record.requestId, "outcome requires an unfinished active request");
          requireCondition(record.status !== "completed" || request.record.kind === "wrap-up" || [...sessions.values()].some(item => item.record.role === executionRole),
            "completed model work requires recorded review-session provenance");
          request.outcome = record;
          activeRequestId = null;
          break;
        }
        case "application": {
          requireCondition(requests.has(record.requestId), "application references a missing request");
          const editorMessages = appliedMessagesByEditor.get(record.editorId) ?? new Set<string>();
          for (const id of record.messageIds) {
            const message = messages.get(id);
            requireCondition(message?.role === "agent" && message.requestId === record.requestId, "application must reference this request's published messages");
            requireCondition(!editorMessages.has(id), "published message was already applied by this editor");
            if (record.status === "applied") {
              editorMessages.add(id);
            }
          }
          appliedMessagesByEditor.set(record.editorId, editorMessages);
          applications.push(record);
          break;
        }
        case "review-end":
          requireCondition(activeRequestId === null && pendingCaptures.size === 0, "unfinished requests/captures cannot be marked as an ended review");
          end = record;
          break;
      }
      ids.add(record.id);
    } catch (error) {
      throw new ArtifactError(filename, index + 1, error instanceof Error ? error.message : String(error), { cause: error });
    }
  }
  const unacceptedMessages = [...messages.values()].filter(message => message.role === "human" && !requests.has(message.requestId));
  return freeze({
    header, records: [...records], sessions: [...sessions.values()], preparations: [...preparations.values()],
    conversations: [...conversations.values()], requests: [...requests.values()], applications,
    unacceptedMessages,
    diagnostics: unacceptedMessages.length === 0 ? [] : [{
      code: "unaccepted-captures" as const,
      message: "Captured messages lack an accepting request marker and are not submitted history. Inspect without automatic replay.",
      messageIds: unacceptedMessages.map(message => message.id),
    }],
    activeRequestId, ...(end ? { end } : {}),
  });
}

function decodeArtifact(data: Buffer, filename: string): ReviewArtifactSnapshot {
  let contents: string;
  try {
    contents = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(data);
  } catch (error) {
    throw new ArtifactError(filename, null, "artifact contains invalid UTF-8; inspect it without repair/replay", { cause: error });
  }
  if (contents.length === 0) {
    throw new ArtifactError(filename, 1, "empty artifact; no review header");
  }
  if (!contents.endsWith("\n")) {
    throw new ArtifactError(filename, contents.split("\n").length, "incomplete JSONL tail; inspect it without repair/replay");
  }
  const records = contents.slice(0, -1).split("\n").map((line, index) => {
    try {
      const value: unknown = JSON.parse(line);
      return parseArtifactRecord(value);
    } catch (error) {
      throw new ArtifactError(filename, index + 1, error instanceof Error ? error.message : String(error), { cause: error });
    }
  });
  return reconstruct(records, filename);
}

// Purely observational: never opens a writer, repairs a tail, pairs, applies
// messages, resumes an unfinished request or starts a review session.
export async function readReviewArtifact(filename: string): Promise<ReviewArtifactSnapshot> {
  return decodeArtifact(await fs.readFile(filename), filename);
}

async function syncDirectory(directory: string): Promise<void> {
  const handle = await fs.open(directory, "r");
  try {
    await handle.sync();
  } catch (error) {
    try {
      await handle.close();
    } catch (cleanupError) {
      console.error("Parley directory sync cleanup failed", cleanupError);
    }
    throw error;
  }
  await handle.close();
}

// Resolve existing ancestors before mkdir, so a configured alias into the
// workspace cannot create source directories before containment is checked.
async function resolveStorageDirectory(directory: string): Promise<string> {
  let ancestor = directory;
  const missing: string[] = [];
  for (;;) {
    try {
      return path.join(await fs.realpath(ancestor), ...missing.reverse());
    } catch (error) {
      if (!(error instanceof Error) || !("code" in error) || error.code !== "ENOENT") {
        throw error;
      }
      const parent = path.dirname(ancestor);
      requireCondition(parent !== ancestor, "cannot resolve a storage ancestor");
      missing.push(path.basename(ancestor));
      ancestor = parent;
    }
  }
}

async function syncStorageParents(state: string, firstCreated: string | undefined): Promise<void> {
  const last = firstCreated === undefined ? state : path.dirname(firstCreated);
  for (let directory = state; ; directory = path.dirname(directory)) {
    await syncDirectory(directory);
    if (directory === last) {
      return;
    }
  }
}

async function appendBytes(handle: FileHandle, contents: Buffer): Promise<void> {
  let offset = 0;
  while (offset < contents.length) {
    const { bytesWritten } = await handle.write(contents, offset, contents.length - offset, null);
    requireCondition(bytesWritten > 0, "artifact append made no progress");
    offset += bytesWritten;
  }
  await handle.sync();
}

function serializeRecord(record: ArtifactRecord): string {
  return JSON.stringify(record) + "\n";
}

function artifactByteLength(records: readonly ArtifactRecord[]): number {
  return records.reduce((bytes, record) => bytes + Buffer.byteLength(serializeRecord(record)), 0);
}

function outsideWorkspace(filename: string, workspace: string): boolean {
  const relative = path.relative(workspace, filename);
  return relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative);
}

export class ReviewArtifactWriter {
  private tail: Promise<void> = Promise.resolve();
  private closing?: Promise<void>;
  private failure?: ArtifactError;

  private constructor(
    readonly filename: string,
    private readonly handle: FileHandle,
    private current: ReviewArtifactSnapshot,
  ) {}

  // Exclusive creation is the sole writer acquisition path. There is no
  // reopen-for-append/restart recovery API. Existing evidence is never replaced.
  static async create(value: unknown): Promise<ReviewArtifactWriter> {
    const header = parseArtifactRecord(value);
    requireCondition(header.type === "review" || header.type === "parley", "artifact creation requires a workflow header");
    requireCondition(await fs.realpath(header.workspace) === header.workspace, "review workspace must be canonical");
    const state = path.resolve(stateDirectory());
    requireCondition(outsideWorkspace(state, header.workspace), "Parley state directory must be outside the review workspace");
    const resolvedState = await resolveStorageDirectory(state);
    requireCondition(outsideWorkspace(resolvedState, header.workspace), "Parley state directory resolves inside the review workspace");
    const firstCreated = await fs.mkdir(resolvedState, { recursive: true, mode: 0o700 });
    const realState = await fs.realpath(resolvedState);
    requireCondition(realState === resolvedState && outsideWorkspace(realState, header.workspace), "Parley state directory changed during creation");
    const directory = path.join(realState, header.type === "parley" ? "parleys" : "reviews");
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    const realDirectory = await fs.realpath(directory);
    requireCondition(realDirectory === directory && outsideWorkspace(realDirectory, header.workspace), "review storage must not be redirected through a symlink");
    const filename = path.join(directory, `${header.id}.jsonl`);
    const current = reconstruct([header], filename);
    const handle = await fs.open(filename, "ax", 0o600);
    try {
      await appendBytes(handle, Buffer.from(serializeRecord(header)));
      await syncDirectory(directory);
      await syncStorageParents(realState, firstCreated);
      return new ReviewArtifactWriter(filename, handle, current);
    } catch (error) {
      try {
        await handle.close();
      } catch (cleanupError) {
        console.error("Parley artifact creation cleanup failed", cleanupError);
      }
      // Even a complete header may have uncertain persistence. Preserve it for
      // inspection and fail, never unlink/recreate or claim a fresh empty review.
      throw new ArtifactError(filename, null, "artifact creation failed; persistence may be partial/uncertain. Inspect before continuing; no automatic replay.", { cause: error });
    }
  }

  // Deeply frozen and safe to borrow. Advances only after a successful sync.
  snapshot(): ReviewArtifactSnapshot {
    return this.current;
  }

  // Observational pickup verifies the actual file against a committed prefix.
  // Do not mask partial/foreign writes with the last cached successful snapshot,
  // or wait/retry/reopen a writer when an append races this read.
  async inspect(): Promise<ReviewArtifactSnapshot> {
    if (this.failure) {
      throw this.failure;
    }
    const expected = this.current;
    const observed = await readReviewArtifact(this.filename);
    const stat = await this.handle.stat();
    const named = await fs.lstat(this.filename);
    const expectedBytes = artifactByteLength(expected.records);
    if (this.failure) {
      throw this.failure;
    }
    if (expected !== this.current || !named.isFile() || named.dev !== stat.dev || named.ino !== stat.ino
      || named.size !== stat.size || stat.size !== expectedBytes || !isDeepStrictEqual(observed.records, expected.records)) {
      throw new ArtifactError(this.filename, null, "artifact identity/contents changed during pickup or differ from its committed prefix; inspect evidence without repair/replay");
    }
    return observed;
  }

  append(values: readonly unknown[]): Promise<void> {
    if (this.closing) {
      return Promise.reject(new ArtifactError(this.filename, null, "artifact writer is closing/closed"));
    }
    let additions: ArtifactRecord[];
    try {
      requireCondition(Array.isArray(values) && values.length > 0, "append requires a nonempty record sequence");
      additions = list(values, parseArtifactRecord);
    } catch (error) {
      return Promise.reject(new ArtifactError(this.filename, null,
        `invalid append records: ${error instanceof Error ? error.message : String(error)}`, { cause: error }));
    }
    // Capture before yielding/queuing. Later caller edits cannot change this
    // accepted sequence or its serialized bytes.
    const contents = Buffer.from(additions.map(serializeRecord).join(""));
    const operation = this.tail.then(async () => {
      if (this.failure) {
        throw this.failure;
      }
      const next = reconstruct([...this.current.records, ...additions], this.filename);
      requireCondition(next.unacceptedMessages.length === 0, "append must include the complete accepting request marker for all human captures");
      try {
        const stat = await this.handle.stat();
        const named = await fs.lstat(this.filename);
        requireCondition(named.isFile() && stat.dev === named.dev && stat.ino === named.ino
          && stat.size === artifactByteLength(this.current.records),
        "artifact identity/size changed outside its sole writer");
        await appendBytes(this.handle, contents);
      } catch (error) {
        this.failure = new ArtifactError(this.filename, null,
          "append failed; persistence may be partial/uncertain. Writer stopped; inspect evidence without repair/replay.", { cause: error });
        throw this.failure;
      }
      this.current = next;
    });
    // The caller owns operation's rejection. A rejected validation must not
    // strand the queue; an I/O failure separately poisons all future appends.
    this.tail = operation.catch(() => {});
    return operation;
  }

  close(): Promise<void> {
    if (!this.closing) {
      this.closing = this.tail.then(async () => {
        try {
          await this.handle.close();
        } catch (error) {
          if (!this.failure) {
            throw error;
          }
          console.error("Parley artifact close failed after persistence failure", error);
        }
        if (this.failure) {
          throw this.failure;
        }
      });
    }
    // Closing a writer is not an outcome or review-end record.
    return this.closing;
  }
}
