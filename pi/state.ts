// Durable review contents are independent of Pi sessions, branches and sockets.
// One live owner per workspace serializes mutations; atomic replacement is the acknowledgement boundary.
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import { randomUUID, createHash } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import type { PreparationInput, PreparedContext, PreparationProgress } from "./preparation.ts";
import { REJECTED_RESPONSE_BYTES, type ReviewGrouping, type GroupingProgress, type GroupingResponseDiagnostic } from "./grouping.ts";

export type ReviewFile = { path: string; old_path: string; status: string; old: string; new: string;
  old_fileformat: "unix" | "dos"; new_fileformat: "unix" | "dos"; deleted: boolean };
export type Note = { id: string; target: { path: string; side: "old" | "new"; first: number; last: number;
  scope: "line" | "range" | "hunk"; context: string[]; sourceId?: string }; text: string; replyTo?: string };
export type Reply = { id: string; replyTo: string; text: string };
export type Finding = { id: string; author: "agent"; target: Note["target"]; text: string };
export type ConclusionDraft = { threadId: string; decision?: Conclusion["decision"]; previousConclusionId?: string;
  previousSummary?: string; discussion: DiscussionMessage[]; summary?: string; autoRecord?: boolean };
export type ReviewStage = { id: string; purpose: string; paths: string[]; unitIds?: string[]; dependencies?: string[]; inputTokenBound?: number };
export type Turn = { id: string; stageId?: string; kind?: "initial" | "discussion" | "conclusion" | "grouping"; status: "queued" | "running" | "complete" | "error";
  notes: Note[]; replies: Reply[]; findings?: Finding[]; conclusionDraft?: ConclusionDraft; error?: string;
  groupingResponse?: GroupingResponseDiagnostic };
export type Evidence = { id: string; path: string; text: string; fileformat: "unix" | "dos";
  origin: "buffer"; modified: boolean; capturedAt: string };
export type Conclusion = { id: string; threadId: string; state: "concluded" | "reopened";
  decision?: "change-requested" | "no-change" | "deferred"; summary: string; createdAt: string;
  messages: string[]; targets: Note["target"][]; discussion: DiscussionMessage[];
  generated?: { author: "agent"; turnId: string; summary: string } };
export type DiscussionMessage = { id: string; author: "human" | "agent"; text: string; replyTo?: string;
  target?: Note["target"]; turnId?: string; current?: boolean };
export type SessionOrigin = { sessionId: string; sessionFile?: string; leafId: string | null };
export type PlanningHandoff = { id: string; requestedAt: string; status: "queued" | "creating" | "open" | "returning" | "returned" | "error";
  requestedFrom: SessionOrigin; returnTo?: SessionOrigin; returnDraft?: string; error?: string };
// Legacy delivery states remain readable; collection itself now only freezes data.
export type Collection = { id: string; createdAt: string; status: "frozen" | "queued" | "delivering" | "delivered" | "error";
  sessionId?: string; error?: string; planning?: { sessionId: string; sessionFile: string; draft?: string };
  handoffs?: PlanningHandoff[]; bundle: { reviewId: string; root: string; scope: string; seed: string;
    threads: { threadId?: string; conclusion?: Conclusion; discussion: DiscussionMessage[] }[]; files: ReviewFile[];
    evidence: Evidence[]; preparedContext?: PreparedContext;
    reviewCoverage?: { stages: ReviewStage[]; activeStageId?: string; reviewedPaths: string[];
      grouping?: ReviewGrouping; reviewedUnits?: string[] } } };
export type Review = { id: string; root: string; vcs: "git" | "jj"; revision?: string; createdAt: string; scope: string;
  seed: string; status: "open" | "closed"; version: number; files: ReviewFile[]; notes: Note[]; turns: Turn[];
  receipts: Record<string, string>; evidence?: Evidence[]; conclusions?: Conclusion[]; collections?: Collection[];
  origin?: SessionOrigin; stages?: ReviewStage[]; activeStageId?: string;
  grouping?: ReviewGrouping; groupingProgress?: GroupingProgress;
  preparation?: { input: PreparationInput; progress?: PreparationProgress; context?: PreparedContext } };
// Coverage derives only from successful initial passes, never viewing a buffer or resolving a thread.
export function reviewedPaths(review: Review): Set<string> {
  const paths = new Set<string>();
  for (const turn of review.turns) {
    if (turn.kind !== "initial" || turn.status !== "complete") continue;
    const stage = review.stages?.find(s => s.id === turn.stageId);
    for (const file of stage?.unitIds ? [] : stage?.paths ?? (turn.stageId ? [] : review.files.map(f => f.path))) paths.add(file);
  }
  const units = review.grouping?.units ?? [];
  const covered = reviewedUnits(review);
  for (const file of review.files) {
    const members = units.filter(u => u.path === file.path);
    if (members.length && members.every(u => covered.has(u.id))) paths.add(file.path);
  }
  return paths;
}

export function reviewedUnits(review: Review): Set<string> {
  const covered = new Set<string>();
  for (const turn of review.turns) {
    if (turn.kind !== "initial" || turn.status !== "complete") continue;
    const stage = review.stages?.find(s => s.id === turn.stageId);
    if (stage?.unitIds) for (const id of stage.unitIds) covered.add(id);
    else for (const unit of review.grouping?.units ?? []) {
      if (!turn.stageId || stage?.paths.includes(unit.path)) covered.add(unit.id);
    }
  }
  return covered;
}

export type Request = { version: 1; requestId: string; action: "list" | "read" | "save" | "submit" | "close" | "capture" | "conclude" | "reopen" | "collect" | "finish" | "draft-conclusion" | "watch" | "open-offer" | "dismiss-offer";
  workspace?: string; reviewId?: string; payload?: { expectedVersion?: number; notes?: Note[]; turnId?: string; kind?: "initial" | "discussion";
    path?: string; text?: string; fileformat?: "unix" | "dos"; modified?: boolean;
    editorId?: string; editorLabel?: string; eligible?: boolean; offerId?: string;
    conclusionId?: string; threadId?: string; previousConclusionId?: string; decision?: Conclusion["decision"];
    summary?: string; collectionId?: string; conclusionIds?: string[]; handoffId?: string; draftTurnId?: string } };
export function stateDirectory(): string {
  return process.env.PARLEY_STATE_DIR || path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), ".local/state"), "parley");
}
export function workspaceKey(root: string): string { return createHash("sha256").update(root).digest("hex"); }
export async function atomicJson(filename: string, data: unknown): Promise<void> {
  await fs.mkdir(path.dirname(filename), { recursive: true, mode: 0o700 });
  const temp = filename + "." + randomUUID() + ".tmp";
  try {
    const handle = await fs.open(temp, "wx", 0o600);
    try { await handle.writeFile(JSON.stringify(data) + "\n"); await handle.sync(); } finally { await handle.close(); }
    await fs.rename(temp, filename);
    const dir = await fs.open(path.dirname(filename), "r");
    try { await dir.sync(); } finally { await dir.close(); }
  } finally { await fs.rm(temp, { force: true }); }
}
function check(condition: unknown, message: string): asserts condition { if (!condition) throw new Error(message); }
function identifier(value: unknown): value is string { return typeof value === "string" && /^[a-zA-Z0-9_-]{1,128}$/.test(value); }
export function validateRequest(value: unknown): asserts value is Request {
  check(value && typeof value === "object", "Expected request object");
  const r = value as Request;
  check(r.version === 1, "Unsupported Parley protocol version");
  check(identifier(r.requestId), "Invalid request ID");
  check(["list", "read", "save", "submit", "close", "capture", "conclude", "reopen", "collect", "finish", "draft-conclusion", "watch", "open-offer", "dismiss-offer"].includes(r.action), "Unknown action");
  check(["list", "watch"].includes(r.action) ? typeof r.workspace === "string" : identifier(r.reviewId), "Explicit workspace/review ID required");
  if (r.action === "watch") {
    check(identifier(r.payload?.editorId) && typeof r.payload?.editorLabel === "string" && r.payload.editorLabel.length <= 256
      && typeof r.payload.eligible === "boolean", "Invalid editor registration");
  }
  if (["open-offer", "dismiss-offer"].includes(r.action)) check(identifier(r.payload?.offerId), "Explicit offer ID required");
  if (!["list", "read", "watch", "open-offer", "dismiss-offer"].includes(r.action)) check(r.payload && Number.isSafeInteger(r.payload.expectedVersion), "Expected version required");
}
export function validateTarget(t: Note["target"], review: Review): void {
  check(t && ["old", "new"].includes(t.side) && ["line", "range", "hunk"].includes(t.scope), "Invalid note target");
  const file = review.files.find(f => f.path === t.path);
  const evidence = t.sourceId === undefined ? undefined : review.evidence?.find(e => e.id === t.sourceId);
  check(t.sourceId === undefined ? file : evidence && evidence.path === t.path && t.side === "new", "Note path outside frozen review");
  const text = evidence ? evidence.text : file![t.side];
  const lines = text.replace(/\n$/, "").split("\n");
  check(text.length && Number.isSafeInteger(t.first) && Number.isSafeInteger(t.last) && t.first >= 1 && t.last >= t.first && t.last <= lines.length, "Note range outside frozen text");
  check(Array.isArray(t.context) && JSON.stringify(t.context) === JSON.stringify(lines.slice(t.first - 1, t.last)), "Note context does not match frozen text");
}
function validateNotes(notes: unknown, review: Review): asserts notes is Note[] {
  check(Array.isArray(notes), "Expected notes array");
  const ids = new Set<string>();
  const agentIds = new Set(review.turns.flatMap(t => [...t.replies.map(r => r.id), ...(t.findings ?? []).map(f => f.id)]));
  const ancestry = new Set([...review.turns.flatMap(t => [...t.notes.map(n => n.id), ...t.replies.map(r => r.id), ...(t.findings ?? []).map(f => f.id)]), ...review.notes.map(n => n.id)]);
  for (const note of notes as Note[]) {
    check(note && identifier(note.id) && !ids.has(note.id), "Invalid or duplicate note ID"); ids.add(note.id);
    check(!agentIds.has(note.id), "Human note cannot reuse an agent finding/reply ID");
    check(typeof note.text === "string" && note.text.trim() && note.text.length <= 1024 * 1024, "Empty or oversized note");
    const t = note.target;
    validateTarget(t, review);
    check(!note.replyTo || (identifier(note.replyTo) && ancestry.has(note.replyTo) && note.replyTo !== note.id), "Unknown reply relationship");
    const previous = review.turns.flatMap(turn => turn.notes).find(n => n.id === note.id)
      ?? review.conclusions?.flatMap(c => c.discussion).find(m => m.id === note.id && m.author === "human");
    check(!previous || isDeepStrictEqual(previous.target, t), "Cannot retarget a submitted or concluded note");
    check(!previous || previous.replyTo === note.replyTo, "Cannot change a submitted or concluded note's reply relationship");
  }
}
// Historical messages keep thread identity valid even if a human note is later deleted.
export function discussionMessages(review: Review): DiscussionMessage[] {
  const messages: DiscussionMessage[] = [...(review.conclusions ?? []).flatMap(c => (c.discussion ?? []).map(m => m.current ? { ...m, current: false } : { ...m })), ...review.turns.filter(t => t.kind !== "conclusion" && t.kind !== "grouping").flatMap(turn => [
    ...turn.notes.map(note => ({ ...note, author: "human" as const, turnId: turn.id })),
    ...(turn.findings ?? []).map(finding => ({ ...finding, turnId: turn.id })),
    ...turn.replies.map(reply => ({ ...reply, author: "agent" as const, turnId: turn.id })),
  ]), ...review.notes.map(note => ({ ...note, author: "human" as const, current: true }))];
  const unique = new Map<string, DiscussionMessage>();
  for (const message of messages) unique.set(JSON.stringify([message.id, message.author, message.text, message.replyTo,
    message.target, message.turnId, message.current]), message);
  return [...unique.values()];
}
export function threadRoot(messages: DiscussionMessage[], id: string): string {
  const byId = new Map(messages.map(message => [message.id, message]));
  const visited = new Set<string>();
  let message = byId.get(id);
  check(message, "Unknown thread message");
  while (message.replyTo) {
    check(!visited.has(message.id), "Cyclic discussion relationship"); visited.add(message.id);
    const parent = byId.get(message.replyTo);
    check(parent, "Missing historical thread parent"); message = parent;
  }
  return message.id;
}
export function latestConclusions(review: Review): Conclusion[] {
  const latest = new Map<string, Conclusion>();
  for (const conclusion of review.conclusions ?? []) latest.set(conclusion.threadId, conclusion);
  return [...latest.values()];
}
// New handoffs include every thread, even without a conclusion or any findings.
// Explicit conclusion selections remain readable for existing callers and bundles.
function freezeCollection(review: Review, collectionId: string, conclusionIds?: string[]): Collection {
  const messages = discussionMessages(review), latest = latestConclusions(review);
  const grouped = new Map<string, DiscussionMessage[]>();
  for (const message of messages) {
    const root = threadRoot(messages, message.id);
    const discussion = grouped.get(root) ?? [];
    discussion.push(message); grouped.set(root, discussion);
  }
  let threads: Collection["bundle"]["threads"];
  if (conclusionIds !== undefined) {
    check(Array.isArray(conclusionIds) && conclusionIds.length > 0 && conclusionIds.length <= 64
      && new Set(conclusionIds).size === conclusionIds.length, "Select 1–64 distinct conclusions");
    threads = conclusionIds.map(id => {
      const conclusion = latest.find(c => c.id === id && c.state === "concluded");
      check(conclusion, "Selected conclusion changed or was reopened; select again");
      return { conclusion, discussion: grouped.get(conclusion.threadId) ?? [] };
    });
  } else {
    threads = [...grouped].map(([threadId, discussion]) => ({ threadId, discussion,
      conclusion: latest.find(c => c.threadId === threadId) }));
  }
  const targets = threads.flatMap(t => [...(t.conclusion?.targets ?? []), ...t.discussion.flatMap(m => m.target ? [m.target] : [])]);
  const paths = new Set(targets.map(t => t.path)), sources = new Set(targets.map(t => t.sourceId));
  const bundle: Collection["bundle"] = { reviewId: review.id, root: review.root, scope: review.scope, seed: review.seed, threads,
    files: conclusionIds === undefined ? review.files : review.files.filter(f => paths.has(f.path)),
    evidence: (review.evidence ?? []).filter(e => sources.has(e.id)), preparedContext: review.preparation?.context,
    reviewCoverage: { stages: review.stages ?? [], activeStageId: review.activeStageId, reviewedPaths: [...reviewedPaths(review)],
      grouping: review.grouping, reviewedUnits: [...reviewedUnits(review)] } };
  check(Buffer.byteLength(JSON.stringify(bundle)) <= 2 * 1024 * 1024,
    "Review handoff exceeds 2 MiB; use a smaller review scope. No threads were omitted.");
  return { id: collectionId, createdAt: new Date().toISOString(), status: "frozen", bundle: structuredClone(bundle) };
}

// The frozen discussion is the draft's authority. Saving a generated draft must
// not silently apply it to a revised/reopened conversation.
function conclusionDraftMatches(review: Review, draft: ConclusionDraft, p: NonNullable<Request["payload"]>): void {
  check(draft.threadId === p.threadId && draft.decision === p.decision
    && draft.previousConclusionId === p.previousConclusionId, "Conclusion draft is stale; request a new draft");
  const messages = discussionMessages(review);
  check(latestConclusions(review).find(c => c.threadId === draft.threadId)?.id === draft.previousConclusionId
    && isDeepStrictEqual(draft.discussion, messages.filter(m => threadRoot(messages, m.id) === draft.threadId)),
    "Conclusion draft is stale; request a new draft");
}

// Called inside the owner's serialized atomic write, never by an editor callback.
// The turn ID also identifies its tail record, so retries cannot append it twice.
export function recordGeneratedConclusion(review: Review, turn: Turn): void {
  const draft = turn.conclusionDraft;
  check(turn.kind === "conclusion" && draft?.summary, "Conclusion draft is not ready");
  check(typeof draft.summary === "string" && draft.summary.trim() && !draft.summary.includes("\0") && draft.summary.length <= 32_000,
    "Conclusion requires a text summary (up to 32,000 characters)");
  const existing = review.conclusions?.find(c => c.id === turn.id);
  if (existing) {
    check(existing.generated?.turnId === turn.id && existing.generated.summary === draft.summary
      && existing.threadId === draft.threadId && existing.decision === draft.decision, "Conclusion ID reused with different content");
    return;
  }
  check(review.status === "open", "Review is closed; conclusion not recorded");
  conclusionDraftMatches(review, draft, draft);
  const targets = draft.discussion.flatMap(message => message.target ? [message.target] : []);
  (review.conclusions ??= []).push({ id: turn.id, threadId: draft.threadId, state: "concluded", decision: draft.decision,
    summary: draft.summary, generated: { author: "agent", turnId: turn.id, summary: draft.summary }, createdAt: new Date().toISOString(),
    messages: [...new Set(draft.discussion.map(m => m.id))], discussion: structuredClone(draft.discussion),
    targets: structuredClone(targets.filter((t, i) => targets.findIndex(other => isDeepStrictEqual(t, other)) === i)) });
}

// Workspace preferences are separate from frozen reviews and survive Pi restarts.
function preparationModelKey(value: unknown): value is string {
  return typeof value === "string" && value.length <= 512 && value === value.trim() && !/[\x00-\x1f\x7f]/.test(value) && value.indexOf("/") > 0 && value.indexOf("/") < value.length - 1;
}
function settingsFilename(directory: string, root: string): string { return path.join(directory, "settings", workspaceKey(root) + ".json"); }
export async function readWorkspacePreparationModel(directory: string, root: string): Promise<string | undefined> {
  let contents: string;
  try { contents = await fs.readFile(settingsFilename(directory, root), "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
  const settings = JSON.parse(contents) as { version?: unknown; workspace?: unknown; preparationModel?: unknown } | null;
  check(settings && settings.version === 1 && settings.workspace === root && preparationModelKey(settings.preparationModel), "Invalid Parley workspace settings");
  return settings.preparationModel;
}
export async function saveWorkspacePreparationModel(directory: string, root: string, model: string): Promise<void> {
  check(preparationModelKey(model), "Invalid preparation model; expected provider/id");
  await atomicJson(settingsFilename(directory, root), { version: 1, workspace: root, preparationModel: model });
}

export class ReviewStore {
  readonly directory: string;
  readonly root: string;
  constructor(directory: string, root: string) { this.directory = path.join(directory, "reviews", workspaceKey(root)); this.root = root; }
  private filename(id: string) { check(identifier(id), "Invalid review ID"); return path.join(this.directory, id + ".json"); }
  async read(id: string): Promise<Review> {
    const review: Review = JSON.parse(await fs.readFile(this.filename(id), "utf8"));
    check(review.id === id && review.root === this.root && Number.isSafeInteger(review.version) && Array.isArray(review.files) && Array.isArray(review.turns) && Array.isArray(review.notes) && review.receipts && ["open", "closed"].includes(review.status), "Invalid stored review");
    if (review.stages !== undefined) {
      check(Array.isArray(review.stages) && new Set(review.stages.map(s => s.id)).size === review.stages.length
        && review.stages.every(s => identifier(s.id) && typeof s.purpose === "string" && s.purpose.trim() && s.purpose.length <= 2000
          && Array.isArray(s.paths) && s.paths.length > 0 && new Set(s.paths).size === s.paths.length
          && s.paths.every(p => typeof p === "string" && review.files.some(f => f.path === p))), "Invalid frozen review pieces");
    }
    for (const progress of [review.groupingProgress, review.grouping]) if (progress) {
      check(preparationModelKey(progress.model) && preparationModelKey(progress.reviewModel)
        && Number.isSafeInteger(progress.contextWindow) && progress.contextWindow > 0
        && Array.isArray(progress.units) && progress.units.length > 0
        && new Set(progress.units.map(u => u.id)).size === progress.units.length, "Invalid frozen grouping inventory");
      for (const unit of progress.units) {
        const file = review.files.find(f => f.path === unit.path);
        check(identifier(unit.id) && file, "Invalid frozen source unit");
        if (unit.side === undefined) check(unit.first === undefined && unit.last === undefined, "Whole-file unit has ranges");
        else {
          check(["old", "new"].includes(unit.side) && Number.isSafeInteger(unit.first) && Number.isSafeInteger(unit.last)
            && unit.first! >= 1 && unit.last! >= unit.first! && file[unit.side].length > 0
            && unit.last! <= file[unit.side].replace(/\n$/, "").split("\n").length, "Grouping range outside frozen source");
        }
      }
      for (const file of review.files) {
        const units = progress.units.filter(u => u.path === file.path);
        if (units.some(u => u.side === undefined)) check(units.length === 1, "Overlapping grouping units");
        else for (const side of ["old", "new"] as const) {
          let next = 1;
          for (const unit of units.filter(u => u.side === side).sort((a, b) => a.first! - b.first!)) {
            check(unit.first === next, "Frozen grouping source coverage is incomplete or overlaps"); next = unit.last! + 1;
          }
          check(next - 1 === (file[side] ? file[side].replace(/\n$/, "").split("\n").length : 0), "Frozen grouping omitted source");
        }
        check(units.length, "Frozen grouping omitted a file");
      }
      check(Array.isArray(progress.summaries) && new Set(progress.summaries.map(s => s.unitId)).size === progress.summaries.length
        && progress.summaries.every(s => progress.units.some(u => u.id === s.unitId) && typeof s.summary === "string"
          && s.summary.trim() && s.summary.length <= 1600 && Array.isArray(s.relatedPaths) && s.relatedPaths.length <= review.files.length
          && s.relatedPaths.every(p => review.files.some(f => f.path === p)) && Array.isArray(s.questions) && s.questions.length <= 8
          && s.questions.every(q => typeof q === "string" && q.length <= 400)), "Invalid frozen grouping summaries");
    }
    const units = review.grouping?.units ?? review.groupingProgress?.units;
    for (const stage of review.stages ?? []) {
      if (stage.unitIds !== undefined) check(Array.isArray(stage.unitIds) && stage.unitIds.length > 0
        && new Set(stage.unitIds).size === stage.unitIds.length && stage.unitIds.every(id => units?.some(u => u.id === id))
        && isDeepStrictEqual([...new Set(units!.filter(u => stage.unitIds!.includes(u.id)).map(u => u.path))].sort(), [...stage.paths].sort()), "Invalid frozen group source scope");
      if (stage.dependencies !== undefined) check(Array.isArray(stage.dependencies) && new Set(stage.dependencies).size === stage.dependencies.length
        && stage.dependencies.every(id => id !== stage.id && review.stages?.some(s => s.id === id)), "Invalid frozen group dependencies");
      if (stage.inputTokenBound !== undefined) check(Number.isSafeInteger(stage.inputTokenBound) && stage.inputTokenBound > 0, "Invalid group input bound");
    }
    if (review.grouping) {
      const grouping = review.grouping;
      check(grouping.budgetMethod === "utf8-upper-bound" && grouping.targetRatio === 0.4 && grouping.limitRatio === 0.5
        && typeof grouping.awaitingPick === "boolean" && Array.isArray(grouping.limitations) && grouping.limitations.every(l => typeof l === "string")
        && Array.isArray(grouping.stageIds) && grouping.stageIds.length > 0 && new Set(grouping.stageIds).size === grouping.stageIds.length
        && grouping.summaries.length === grouping.units.length, "Invalid stored grouping proposal");
      const primary = grouping.stageIds.flatMap(id => {
        const stage = review.stages?.find(s => s.id === id);
        check(stage?.unitIds && Number.isSafeInteger(stage.inputTokenBound) && stage.inputTokenBound! <= Math.floor(grouping.contextWindow / 2), "Stored grouping stage/budget is missing");
        return stage.unitIds;
      });
      check(new Set(primary).size === primary.length && primary.length === grouping.units.length, "Stored grouping primary coverage is incomplete or duplicated");
    }
    check(review.activeStageId === undefined || review.stages?.some(s => s.id === review.activeStageId), "Active review piece is missing");
    check(review.turns.every(t => t.stageId === undefined || review.stages?.some(s => s.id === t.stageId)), "Turn's frozen review piece is missing");
    for (const turn of review.turns) if (turn.groupingResponse) {
      const response = turn.groupingResponse;
      check(turn.status === "error" && turn.kind === "grouping" && ["summary", "proposal"].includes(response.phase)
        && (response.phase === "summary" ? units?.some(u => u.id === response.unitId) : response.unitId === undefined)
        && Number.isSafeInteger(response.byteLength) && response.byteLength >= 0
        && response.truncated === (response.byteLength > REJECTED_RESPONSE_BYTES)
        && typeof response.head === "string" && (response.tail === undefined || typeof response.tail === "string")
        && (response.truncated ? response.tail !== undefined : response.tail === undefined), "Invalid retained grouping response");
      const retainedBytes = Buffer.byteLength(response.head, "utf8") + Buffer.byteLength(response.tail ?? "", "utf8");
      check(retainedBytes <= REJECTED_RESPONSE_BYTES && (response.truncated ? retainedBytes < response.byteLength
        : retainedBytes === response.byteLength), "Retained grouping response exceeds its byte bound or has inconsistent length");
    }
    return review;
  }
  async list() {
    let names: string[];
    try { names = await fs.readdir(this.directory); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return []; throw error; }
    const reviews = await Promise.all(names.filter(n => n.endsWith(".json")).map(n => this.read(n.slice(0, -5))));
    return reviews.sort((a, b) => b.createdAt.localeCompare(a.createdAt)).map(({ id, root, status, createdAt, scope }) => ({ id, root, status, createdAt, scope }));
  }
  async create(snapshot: Pick<Review, "root" | "vcs" | "revision" | "scope" | "files">, seed: string, input?: PreparationInput, origin?: SessionOrigin) {
    check(snapshot.root === this.root && snapshot.files.length, "Empty or wrong-workspace snapshot");
    const review: Review = { ...snapshot, id: randomUUID(), createdAt: new Date().toISOString(), seed, status: "open", version: 1, notes: [], turns: [], receipts: {} };
    if (origin) review.origin = structuredClone(origin);
    if (input) {
      review.preparation = { input: structuredClone(input) };
      review.turns.push({ id: randomUUID(), kind: "initial", status: "queued", notes: [], replies: [], findings: [] });
    }
    await atomicJson(this.filename(review.id), review); return review;
  }
  // Explicit Pi request: selecting a completed piece only changes presentation scope.
  // Pending/failed pieces get a fresh turn; successful findings are never overwritten.
  async stage(id: string, paths: string[], purpose: string, stageId?: string): Promise<Review> {
    const review = await this.read(id);
    check(review.status === "open" && review.preparation, "Stage generation requires an open agent-first review");
    check(!review.turns.some(t => t.status === "queued" || t.status === "running"), "Wait for the current review request to settle before selecting a piece");
    check(paths.length > 0 && new Set(paths).size === paths.length && paths.every(p => review.files.some(f => f.path === p)), "Select distinct paths from the original frozen review");
    check(typeof purpose === "string" && purpose.trim().length > 0 && purpose.length <= 2000 && !purpose.includes("\0"), "Piece purpose must be nonempty bounded text");
    const ordered = review.files.filter(f => paths.includes(f.path)).map(f => f.path);
    let stage = stageId ? review.stages?.find(s => s.id === stageId) : review.stages?.find(s => !s.unitIds && isDeepStrictEqual(s.paths, ordered) && s.purpose === purpose);
    check(!stageId || (stage && isDeepStrictEqual([...stage.paths].sort(), [...ordered].sort()) && stage.purpose === purpose), "Frozen stage identity/scope changed");
    if (!stage) {
      stage = { id: randomUUID(), paths: ordered, purpose };
      (review.stages ??= []).push(stage);
    }
    review.activeStageId = stage.id;
    if (review.grouping) review.grouping.awaitingPick = false;
    if (!review.turns.some(t => t.stageId === stage.id && t.kind === "initial" && t.status === "complete")) {
      review.turns.push({ id: randomUUID(), stageId: stage.id, kind: "initial", status: "queued", notes: [], replies: [], findings: [] });
    }
    await this.write(review); return review;
  }

  async requestGrouping(id: string): Promise<Review> {
    const review = await this.read(id);
    check(review.status === "open" && review.preparation, "Grouping requires an open agent-first capture");
    check(!review.turns.some(t => t.status === "queued" || t.status === "running"), "Wait for the current review request to settle");
    if (!review.grouping) review.turns.push({ id: randomUUID(), kind: "grouping", status: "queued", notes: [], replies: [] });
    await this.write(review); return review;
  }

  async recover(preserveQueued = false) {
    for (const { id } of await this.list()) {
      const review = await this.read(id);
      let changed = false;
      for (const turn of review.turns) if (turn.status === "running" || (!preserveQueued && turn.status === "queued")) {
        turn.status = "error"; turn.error = "Pi disconnected before completion; submit a new turn explicitly to retry."; changed = true;
      }
      // Old queues must not silently become handoffs. Keep the frozen bundle intact.
      for (const collection of review.collections ?? []) if (collection.status === "queued") {
        collection.status = "frozen"; changed = true;
      }
      if (!preserveQueued) for (const collection of review.collections ?? []) for (const handoff of collection.handoffs ?? []) {
        if (handoff.status === "queued" || handoff.status === "creating" || handoff.status === "returning") {
          handoff.status = "error"; handoff.error = "Pi disconnected during handoff. Finish explicitly to retry; any recorded planning session is reused."; changed = true;
        }
      }
      if (changed) await this.write(review);
    }
  }
  async write(review: Review) { review.version++; await atomicJson(this.filename(review.id), review); }
  async handle(request: Request, origin?: SessionOrigin): Promise<unknown> {
    if (request.action === "list") { check(request.workspace === this.root, "Workspace mismatch"); return this.list(); }
    const review = await this.read(request.reviewId!);
    if (request.action === "read") return review;
    const fingerprint = createHash("sha256").update(JSON.stringify(request)).digest("hex");
    const receipt = review.receipts[request.requestId];
    if (receipt) { check(receipt === fingerprint, "Request ID reused with different content"); return review; }
    // turnId is independently idempotent across reconnects and request IDs.
    if (request.action === "submit" && review.turns.some(t => t.id === request.payload?.turnId)) return review;
    if (request.action === "draft-conclusion") {
      const existing = review.turns.find(t => t.id === request.payload?.turnId);
      if (existing) {
        check(existing.kind === "conclusion" && existing.conclusionDraft && existing.status !== "error", "Invalid or failed conclusion draft ID; retry with a new ID");
        const draft = existing.conclusionDraft, p = request.payload!;
        const recorded = review.conclusions?.find(c => c.generated?.turnId === existing.id);
        if (recorded) {
          check(draft.threadId === p.threadId && draft.decision === p.decision && draft.previousConclusionId === p.previousConclusionId,
            "Conclusion draft ID reused with different content");
          return review;
        }
        check(review.status === "open", "Review is closed");
        conclusionDraftMatches(review, draft, p);
        // An explicit request can authorize recording a retained legacy draft too.
        draft.autoRecord = true;
        if (existing.status === "complete") recordGeneratedConclusion(review, existing);
        await this.write(review);
        return review;
      }
    }
    if (["conclude", "reopen"].includes(request.action)) {
      const existing = review.conclusions?.find(c => c.id === request.payload?.conclusionId);
      if (existing) {
        const p = request.payload!;
        const previous = review.conclusions!.slice(0, review.conclusions!.indexOf(existing)).findLast(c => c.threadId === existing.threadId);
        check(existing.threadId === p.threadId && existing.state === (request.action === "reopen" ? "reopened" : "concluded")
          && previous?.id === p.previousConclusionId
          && existing.summary === p.summary && existing.decision === p.decision
          && existing.generated?.turnId === (p.draftTurnId ?? (request.action === "conclude" ? previous?.generated?.turnId : undefined)), "Conclusion ID reused with different content");
        return review;
      }
    }
    if (request.action === "collect") {
      const existing = review.collections?.find(c => c.id === request.payload?.collectionId);
      if (existing) {
        check(request.payload?.conclusionIds === undefined
          ? existing.bundle.threads.every(t => t.threadId !== undefined)
          : isDeepStrictEqual(existing.bundle.threads.map(t => t.conclusion?.id), request.payload.conclusionIds),
          "Collection ID reused with different selection");
        return review;
      }
    }
    if (request.action === "finish") {
      const collection = review.collections?.find(c => c.id === request.payload?.collectionId);
      const existing = collection?.handoffs?.find(h => h.id === request.payload?.handoffId);
      if (existing) return review; // An uncertain acknowledgement never creates another session/opening.
    }
    check(review.status === "open", "Review is closed");
    check(request.payload!.expectedVersion === review.version, "Review changed; refresh before saving (local notes retained)");
    if (request.action !== "capture") check(!review.turns.some(t => t.status === "queued" || t.status === "running"), "An agent turn is pending");
    if (request.action === "capture") {
      // Explicit human composition captures buffer evidence; never reads or changes workspace files.
      // Append-only evidence can arrive during a turn, whose submitted source IDs remain fixed.
      const p = request.payload!;
      check(typeof p.path === "string" && p.path.length <= 4096 && !path.posix.isAbsolute(p.path)
        && p.path.split("/").every(part => part && part !== "." && part !== ".." && part !== ".git" && part !== ".jj")
        && !/[\x00-\x1f\x7f\\]/.test(p.path), "Expected canonical workspace-relative evidence path");
      check(typeof p.text === "string" && !p.text.includes("\0") && Buffer.byteLength(p.text) <= 1024 * 1024, "Buffer evidence exceeds 1 MiB or is not text");
      check(["unix", "dos"].includes(p.fileformat!) && typeof p.modified === "boolean", "Invalid buffer evidence provenance");
      const evidence = review.evidence ??= [];
      if (!evidence.some(e => e.path === p.path && e.text === p.text && e.fileformat === p.fileformat && e.modified === p.modified)) {
        check(evidence.length < 64 && evidence.reduce((size, e) => size + Buffer.byteLength(e.text), 0) + Buffer.byteLength(p.text) <= 8 * 1024 * 1024, "Review evidence budget exhausted (64 sources / 8 MiB)");
        evidence.push({ id: randomUUID(), path: p.path, text: p.text, fileformat: p.fileformat!, modified: p.modified!, origin: "buffer", capturedAt: new Date().toISOString() });
      }
    } else if (request.action === "draft-conclusion") {
      const p = request.payload!;
      check(identifier(p.turnId) && identifier(p.threadId), "Explicit draft/thread IDs required");
      check(p.decision === undefined || ["change-requested", "no-change", "deferred"].includes(p.decision), "Invalid conclusion decision");
      const messages = discussionMessages(review);
      check(threadRoot(messages, p.threadId) === p.threadId, "Expected root thread ID");
      const previous = latestConclusions(review).find(c => c.threadId === p.threadId);
      check(previous?.id === p.previousConclusionId, "Conclusion changed; request a new draft");
      review.turns.push({ id: p.turnId, kind: "conclusion", status: "queued", notes: [], replies: [],
        conclusionDraft: { autoRecord: true, threadId: p.threadId, decision: p.decision, previousConclusionId: previous?.id,
          previousSummary: previous?.summary, discussion: structuredClone(messages.filter(m => threadRoot(messages, m.id) === p.threadId)) } });
    } else if (request.action === "conclude" || request.action === "reopen") {
      const p = request.payload!;
      check(identifier(p.conclusionId) && identifier(p.threadId), "Explicit conclusion/thread IDs required");
      const messages = discussionMessages(review);
      check(threadRoot(messages, p.threadId) === p.threadId, "Expected root thread ID");
      const previous = latestConclusions(review).find(c => c.threadId === p.threadId);
      check(previous?.id === p.previousConclusionId, "Conclusion changed; reopen the editor before revising");
      check(typeof p.summary === "string" && p.summary.trim() && !p.summary.includes("\0") && p.summary.length <= 32_000, "Conclusion requires a text summary (up to 32,000 characters)");
      if (request.action === "reopen") check(previous?.state === "concluded" && p.decision === undefined, "Only concluded threads can be reopened");
      else check(p.decision === undefined || ["change-requested", "no-change", "deferred"].includes(p.decision), "Invalid conclusion decision");
      const discussion = messages.filter(message => threadRoot(messages, message.id) === p.threadId);
      // Human edits of the latest decision retain the original agent draft's authorship.
      let generated: Conclusion["generated"] = request.action === "conclude" ? previous?.generated : undefined;
      if (p.draftTurnId !== undefined) {
        check(request.action === "conclude" && identifier(p.draftTurnId), "Invalid generated conclusion provenance");
        const turn = review.turns.find(t => t.id === p.draftTurnId);
        check(turn?.kind === "conclusion" && turn.status === "complete" && turn.conclusionDraft?.summary, "Conclusion draft is not ready");
        conclusionDraftMatches(review, turn.conclusionDraft, p);
        generated = { author: "agent", turnId: turn.id, summary: turn.conclusionDraft.summary };
      }
      const targets = discussion.flatMap(message => message.target ? [message.target] : []);
      (review.conclusions ??= []).push({ id: p.conclusionId, threadId: p.threadId,
        state: request.action === "reopen" ? "reopened" : "concluded", decision: p.decision,
        summary: p.summary, generated, createdAt: new Date().toISOString(), messages: [...new Set(discussion.map(m => m.id))],
        discussion: structuredClone(discussion),
        targets: structuredClone(targets.filter((t, i) => targets.findIndex(other => isDeepStrictEqual(t, other)) === i)) });
    } else if (request.action === "collect") {
      const p = request.payload!;
      check(identifier(p.collectionId), "Explicit collection ID required");
      (review.collections ??= []).push(freezeCollection(review, p.collectionId, p.conclusionIds));
    } else if (request.action === "finish") {
      const p = request.payload!;
      check(identifier(p.collectionId) && identifier(p.handoffId), "Explicit collection/handoff IDs required");
      check(origin?.sessionFile, "Handoff requires an existing persistent Pi session");
      const workspaceReviews = await Promise.all((await this.list()).map(({ id }) => this.read(id)));
      check(!workspaceReviews.some(r => r.collections?.some(c => c.handoffs?.some(h => ["queued", "creating", "returning"].includes(h.status)))), "A planning handoff is already pending in this workspace");
      let collection = review.collections?.find(c => c.id === p.collectionId);
      if (!collection) {
        collection = freezeCollection(review, p.collectionId);
        (review.collections ??= []).push(collection);
      }
      (collection.handoffs ??= []).push({ id: p.handoffId, requestedAt: new Date().toISOString(), status: "queued", requestedFrom: structuredClone(origin) });
    } else if (request.action === "save") {
      validateNotes(request.payload!.notes, review); review.notes = request.payload!.notes;
    } else if (request.action === "submit") {
      check(identifier(request.payload!.turnId), "Invalid turn ID");
      check(request.payload!.kind === undefined || ["initial", "discussion"].includes(request.payload!.kind), "Invalid turn kind");
      if (request.payload!.kind === "initial") {
        const stageId = review.activeStageId;
        check(review.preparation && review.turns.some(t => t.kind === "initial" && t.stageId === stageId && t.status === "error")
          && !review.turns.some(t => t.kind === "initial" && t.stageId === stageId && t.status === "complete"), "No failed initial piece to retry");
        review.turns.push({ id: request.payload!.turnId!, stageId, kind: "initial", status: "queued", notes: [], replies: [], findings: [] });
      } else {
        // A turn contains only new/revised messages, not the full saved discussion.
        // Failed turns never advance the answered baseline; older versions remain durable context.
        const answered = new Map<string, Note>();
        for (const turn of review.turns) {
          if (turn.status !== "complete" || turn.kind === "initial" || turn.kind === "conclusion" || turn.kind === "grouping") continue;
          const replied = new Set(turn.replies.map(reply => reply.replyTo));
          for (const note of turn.notes) if (replied.has(note.id)) answered.set(note.id, note);
        }
        const notes = review.notes.filter(note => !isDeepStrictEqual(answered.get(note.id), note));
        check(notes.length, "No new or revised comments to submit");
        review.turns.push({ id: request.payload!.turnId!, kind: "discussion", status: "queued", notes: structuredClone(notes), replies: [] });
      }
    } else if (request.action === "close") {
      check(!review.collections?.some(c => c.handoffs?.some(h => ["queued", "creating", "returning"].includes(h.status))),
        "Wait for the planning handoff to settle before closing this review");
      review.status = "closed";
    }
    review.receipts[request.requestId] = fingerprint;
    await this.write(review); return review;
  }
}
