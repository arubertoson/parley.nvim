// Durable review contents are independent of Pi sessions, branches and sockets.
// One live owner per workspace serializes mutations; atomic replacement is the acknowledgement boundary.
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import { randomUUID, createHash } from "node:crypto";
import { isDeepStrictEqual } from "node:util";

export type ReviewFile = { path: string; old_path: string; status: string; old: string; new: string;
  old_fileformat: "unix" | "dos"; new_fileformat: "unix" | "dos"; deleted: boolean };
export type Note = { id: string; target: { path: string; side: "old" | "new"; first: number; last: number;
  scope: "line" | "range" | "hunk"; context: string[] }; text: string; replyTo?: string };
export type Reply = { id: string; replyTo: string; text: string };
export type Turn = { id: string; status: "queued" | "running" | "complete" | "error"; notes: Note[]; replies: Reply[]; error?: string };
export type Review = { id: string; root: string; vcs: "git" | "jj"; revision?: string; createdAt: string; scope: string;
  seed: string; status: "open" | "closed"; version: number; files: ReviewFile[]; notes: Note[]; turns: Turn[];
  receipts: Record<string, string> };
export type Request = { version: 1; requestId: string; action: "list" | "read" | "save" | "submit" | "close";
  workspace?: string; reviewId?: string; payload?: { expectedVersion?: number; notes?: Note[]; turnId?: string } };
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
  check(["list", "read", "save", "submit", "close"].includes(r.action), "Unknown action");
  check(r.action === "list" ? typeof r.workspace === "string" : identifier(r.reviewId), "Explicit workspace/review ID required");
  if (["save", "submit", "close"].includes(r.action)) check(r.payload && Number.isSafeInteger(r.payload.expectedVersion), "Expected version required");
}
function validateNotes(notes: unknown, review: Review): asserts notes is Note[] {
  check(Array.isArray(notes), "Expected notes array");
  const ids = new Set<string>();
  const ancestry = new Set([...review.turns.flatMap(t => [...t.notes.map(n => n.id), ...t.replies.map(r => r.id)]), ...review.notes.map(n => n.id)]);
  for (const note of notes as Note[]) {
    check(note && identifier(note.id) && !ids.has(note.id), "Invalid or duplicate note ID"); ids.add(note.id);
    check(typeof note.text === "string" && note.text.trim() && note.text.length <= 1024 * 1024, "Empty or oversized note");
    const t = note.target;
    check(t && ["old", "new"].includes(t.side) && ["line", "range", "hunk"].includes(t.scope), "Invalid note target");
    const file = review.files.find(f => f.path === t.path);
    check(file, "Note path outside frozen review");
    const lines = file[t.side].replace(/\n$/, "").split("\n");
    check(Number.isSafeInteger(t.first) && Number.isSafeInteger(t.last) && t.first >= 1 && t.last >= t.first && t.last <= lines.length, "Note range outside frozen text");
    check(Array.isArray(t.context) && JSON.stringify(t.context) === JSON.stringify(lines.slice(t.first - 1, t.last)), "Note context does not match frozen text");
    check(!note.replyTo || (identifier(note.replyTo) && ancestry.has(note.replyTo) && note.replyTo !== note.id), "Unknown reply relationship");
    const previous = review.turns.flatMap(turn => turn.notes).find(n => n.id === note.id);
    check(!previous || isDeepStrictEqual(previous.target, t), "Cannot retarget a submitted note");
    check(!previous || previous.replyTo === note.replyTo, "Cannot change a submitted note's reply relationship");
  }
}
export class ReviewStore {
  readonly directory: string;
  readonly root: string;
  constructor(directory: string, root: string) { this.directory = path.join(directory, "reviews", workspaceKey(root)); this.root = root; }
  private filename(id: string) { check(identifier(id), "Invalid review ID"); return path.join(this.directory, id + ".json"); }
  async read(id: string): Promise<Review> {
    const review: Review = JSON.parse(await fs.readFile(this.filename(id), "utf8"));
    check(review.id === id && review.root === this.root && Number.isSafeInteger(review.version) && Array.isArray(review.files) && Array.isArray(review.turns) && Array.isArray(review.notes) && review.receipts && ["open", "closed"].includes(review.status), "Invalid stored review");
    return review;
  }
  async list() {
    let names: string[];
    try { names = await fs.readdir(this.directory); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return []; throw error; }
    const reviews = await Promise.all(names.filter(n => n.endsWith(".json")).map(n => this.read(n.slice(0, -5))));
    return reviews.sort((a, b) => b.createdAt.localeCompare(a.createdAt)).map(({ id, root, status, createdAt, scope }) => ({ id, root, status, createdAt, scope }));
  }
  async create(snapshot: Pick<Review, "root" | "vcs" | "revision" | "scope" | "files">, seed: string) {
    check(snapshot.root === this.root && snapshot.files.length, "Empty or wrong-workspace snapshot");
    const review: Review = { ...snapshot, id: randomUUID(), createdAt: new Date().toISOString(), seed, status: "open", version: 1, notes: [], turns: [], receipts: {} };
    await atomicJson(this.filename(review.id), review); return review;
  }
  async recover() {
    for (const { id } of await this.list()) {
      const review = await this.read(id);
      let changed = false;
      for (const turn of review.turns) if (turn.status === "running" || turn.status === "queued") {
        turn.status = "error"; turn.error = "Pi disconnected before completion; submit a new turn explicitly to retry."; changed = true;
      }
      if (changed) await this.write(review);
    }
  }
  async write(review: Review) { review.version++; await atomicJson(this.filename(review.id), review); }
  async handle(request: Request): Promise<unknown> {
    if (request.action === "list") { check(request.workspace === this.root, "Workspace mismatch"); return this.list(); }
    const review = await this.read(request.reviewId!);
    if (request.action === "read") return review;
    const fingerprint = createHash("sha256").update(JSON.stringify(request)).digest("hex");
    const receipt = review.receipts[request.requestId];
    if (receipt) { check(receipt === fingerprint, "Request ID reused with different content"); return review; }
    // turnId is independently idempotent across reconnects and request IDs.
    if (request.action === "submit" && review.turns.some(t => t.id === request.payload?.turnId)) return review;
    check(review.status === "open", "Review is closed");
    check(request.payload!.expectedVersion === review.version, "Review changed; refresh before saving (local notes retained)");
    check(!review.turns.some(t => t.status === "queued" || t.status === "running"), "An agent turn is pending");
    if (request.action === "save") {
      validateNotes(request.payload!.notes, review); review.notes = request.payload!.notes;
    } else if (request.action === "submit") {
      check(identifier(request.payload!.turnId), "Invalid turn ID");
      const last = [...review.turns].reverse().find(t => t.status === "complete");
      check(review.notes.length && (!last || !isDeepStrictEqual(last.notes, review.notes)), "No new or revised comments to submit");
      review.turns.push({ id: request.payload!.turnId!, status: "queued", notes: structuredClone(review.notes), replies: [] });
    } else if (request.action === "close") review.status = "closed";
    review.receipts[request.requestId] = fingerprint;
    await this.write(review); return review;
  }
}
