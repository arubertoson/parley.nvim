// The normal independent Pi child owns implementation tools and its transcript.
// This parent-side owner alone accepts editor requests and appends publications.
import { randomUUID } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import path from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { ExtensionCommandContext, ExtensionToolContext } from "@earendil-works/pi-coding-agent";
import type { Usage } from "@earendil-works/pi-ai";
import type { MessageRecord, PreparationRecord, RequestRecord, ReviewArtifactWriter, SessionRecord } from "./artifact.ts";
import type { ReviewModel } from "./interaction.ts";
import { ParleyProcess } from "./parley-process.ts";

const now = (): number => Math.floor(Date.now() / 1000);
const maxPromptBytes = 4 * 1024 * 1024;
const emptyUsage: Usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

function requireCondition(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

export class ParleyFork {
  private context?: ExtensionToolContext;
  private signal?: AbortSignal;
  private runner?: ParleyInteraction;

  private constructor(readonly manager: SessionManager, readonly model: ReviewModel, readonly thinkingLevel: string) {}

  // Never mutate the parent's live manager. Branch its persisted context at the
  // selected leaf before asking the parent to enter the waiting host tool.
  static capture(ctx: ExtensionCommandContext, thinkingLevel: string): ParleyFork {
    const filename = ctx.sessionManager.getSessionFile();
    const leaf = ctx.sessionManager.getLeafId();
    requireCondition(filename && leaf && ctx.model, "Parley requires a persistent, nonempty parent session and an explicit model");
    const relative = path.relative(ctx.cwd, filename);
    requireCondition(relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative), "Parent transcripts must live outside the implementation workspace");
    const manager = SessionManager.open(filename);
    // JSONL omits optional undefined fields retained by the live manager.
    requireCondition(manager.getSessionId() === ctx.sessionManager.getSessionId()
      && isDeepStrictEqual(manager.getBranch(leaf), JSON.parse(JSON.stringify(ctx.sessionManager.getBranch(leaf)))),
    "Parent transcript has not persisted the selected context; no fork started");
    const forkPath = manager.createBranchedSession(leaf);
    requireCondition(forkPath && forkPath !== filename, "Cannot persist an independent implementation fork");
    return new ParleyFork(manager, structuredClone(ctx.model), thinkingLevel);
  }

  bind(ctx: ExtensionToolContext, signal: AbortSignal | undefined): void {
    requireCondition(!this.context, "Implementation host is already bound");
    this.context = ctx;
    this.signal = signal;
  }

  get usage(): Usage { return this.runner?.usage ?? emptyUsage; }

  interaction(writer: ReviewArtifactWriter): ParleyInteraction {
    requireCondition(this.context, "Implementation host tool is not running");
    this.runner ??= new ParleyInteraction(writer, this, this.context, this.signal);
    return this.runner;
  }

  summary(artifactPath: string, prose?: string): string {
    const text = ["# Parley completed", "", prose ?? "No implementation turns were submitted.", "",
      `Details: ${this.manager.getSessionFile()}`, `Artifact: ${artifactPath}`,
      "Changes already exist in the shared workspace; this recap does not apply or roll back edits.",
      "Unsubmitted drafts are preserved and excluded. Conversation resolution is not verification."].join("\n");
    requireCondition(Buffer.byteLength(text) <= 16 * 1024 && !/[\x00-\x08\x0b-\x1f\x7f]/.test(text), "Implementation recap exceeds 16 KiB or contains control characters; no truncation");
    return text;
  }
}

type Run = {
  readonly request: RequestRecord;
  readonly controller: AbortController;
  activity: "starting" | "working" | "settling";
};

export class ParleyInteraction {
  private session?: ParleyProcess;
  private sessionRecord?: SessionRecord;
  private run?: Run;
  private operation?: Promise<unknown>;
  private startupFailure?: unknown;
  private closed = false;
  private closing?: Promise<void>;

  constructor(private readonly writer: ReviewArtifactWriter, private readonly fork: ParleyFork,
    private readonly host: ExtensionToolContext, private readonly hostSignal?: AbortSignal) {}

  get usage(): Usage { return this.session?.usage ?? emptyUsage; }
  get busy(): boolean { return !!this.operation; }

  activity(requestId: string): Run["activity"] | undefined {
    return this.run?.request.id === requestId ? this.run.activity : undefined;
  }

  private current(run: Run): void {
    requireCondition(!this.closed && this.run === run && !run.controller.signal.aborted && !this.hostSignal?.aborted
      && this.writer.snapshot().activeRequestId === run.request.id, "Implementation request is no longer current");
  }

  private async publish(input: unknown): Promise<string> {
    const run = this.run;
    requireCondition(run && run.request.kind !== "wrap-up", "No active implementation publication request");
    this.current(run);
    requireCondition(input !== null && typeof input === "object" && !Array.isArray(input), "Expected reply object");
    const value = input as Record<string, unknown>;
    requireCondition(Object.keys(value).length === 4 && ["conversationId", "parentId", "version", "lines"].every(key => Object.hasOwn(value, key)), "Unexpected reply fields");
    const history = this.writer.snapshot().conversations.find(item => item.record.id === value.conversationId);
    requireCondition(history && run.request.submissions.some(item => item.conversationId === history.record.id)
      && history.version === value.version && history.messages.at(-1)?.id === value.parentId, "Reply must extend this turn's exact submitted history");
    requireCondition(Array.isArray(value.lines) && value.lines.length > 0 && value.lines.every(line => typeof line === "string" && !line.includes("\n"))
      && value.lines.join("\n").trim().length > 0 && Buffer.byteLength(JSON.stringify(value.lines)) <= 64 * 1024, "Invalid or oversized reply");
    const record: MessageRecord = { type: "message", id: randomUUID(), reviewId: run.request.reviewId, requestId: run.request.id, createdAt: now(),
      conversationId: history.record.id, parentId: history.messages.at(-1)!.id, role: "agent", author: "Implementation agent", origin: `pi/${this.fork.manager.getSessionId()}`,
      lines: value.lines, version: history.version + 1, supersedes: [], replacesId: null };
    await this.writer.append([record]);
    return JSON.stringify({ id: record.id, version: record.version });
  }

  private async childUI(request: Readonly<Record<string, unknown>>): Promise<Record<string, unknown> | undefined> {
    const run = this.run;
    if (!run || this.closed || this.hostSignal?.aborted || run.controller.signal.aborted) return;
    const ui = this.host.ui;
    if (request.method === "notify" && typeof request.message === "string") {
      ui.notify(request.message, request.notifyType === "error" || request.notifyType === "warning" ? request.notifyType : "info");
      return;
    }
    const title = request.title;
    if (typeof title !== "string") return;
    const opts = { signal: AbortSignal.any([run.controller.signal, ...(this.hostSignal ? [this.hostSignal] : [])]),
      timeout: typeof request.timeout === "number" && Number.isFinite(request.timeout) && request.timeout > 0 ? request.timeout : undefined };
    if (request.method === "confirm" && typeof request.message === "string") {
      return { confirmed: await ui.confirm(title, request.message, opts) };
    }
    if (request.method === "select" && Array.isArray(request.options) && request.options.every(value => typeof value === "string")) {
      const value = await ui.select(title, request.options, opts);
      return value === undefined ? undefined : { value };
    }
    if (request.method === "input" && (request.placeholder === undefined || typeof request.placeholder === "string")) {
      const value = await ui.input(title, request.placeholder, opts);
      return value === undefined ? undefined : { value };
    }
    // The host editor API has no abort signal. Never leave an orphan modal over
    // a cancelled interaction or mutate the parent's composer/status/layout.
    if (request.method === "editor") ui.notify("The child requested an unsupported multiline dialog; it was cancelled.", "warning");
  }

  private async ensureSession(run: Run, preparation: PreparationRecord): Promise<ParleyProcess> {
    if (this.startupFailure) throw this.startupFailure;
    if (this.session) return this.session;
    try {
      this.current(run);
      const parent = this.writer.snapshot().sessions.find(item => item.record.id === preparation.parentSessionRecordId)?.record;
      requireCondition(parent, "Missing originating parent provenance");
      const transcriptPath = this.fork.manager.getSessionFile();
      requireCondition(transcriptPath, "Missing implementation transcript");
      const session = await ParleyProcess.start({ cwd: this.host.cwd, transcriptPath, parentSessionId: parent.sessionId,
        model: this.fork.model, thinkingLevel: this.fork.thinkingLevel,
        publish: input => this.publish(input), ui: request => this.childUI(request) });
      this.session = session;
      requireCondition(session.sessionId === this.fork.manager.getSessionId(), "Implementation session identity changed during startup");
      this.current(run);
      const record: SessionRecord = { type: "session", id: randomUUID(), reviewId: run.request.reviewId, createdAt: now(), role: "implementation",
        sessionId: session.sessionId, transcriptPath, startEntryId: this.fork.manager.getLeafId(), parentSessionRecordId: parent.id,
        model: { provider: this.fork.model.provider, modelId: this.fork.model.id, thinkingLevel: this.fork.thinkingLevel } };
      await this.writer.append([record]);
      this.sessionRecord = record;
      this.current(run);
      return session;
    } catch (error) {
      this.startupFailure = error;
      throw error;
    }
  }

  start(request: RequestRecord, preparation: PreparationRecord): Promise<void> {
    requireCondition(!this.closed && !this.operation && request.kind !== "wrap-up", "Implementation host is busy or closed");
    const run: Run = { request, controller: new AbortController(), activity: "starting" };
    this.run = run;
    const operation = this.execute(run, preparation);
    this.operation = operation;
    return operation.finally(() => { if (this.operation === operation) this.operation = undefined; });
  }

  private async execute(run: Run, preparation: PreparationRecord): Promise<void> {
    let status: "completed" | "failed" | "cancelled" = "failed";
    let detail = "Implementation did not settle normally";
    try {
      const snapshot = this.writer.snapshot();
      const conversations = run.request.submissions.map(submission => {
        const history = snapshot.conversations.find(item => item.record.id === submission.conversationId);
        requireCondition(history && history.version === submission.version && history.messages.at(-1)?.id === submission.tipId, "Accepted implementation history changed");
        return history;
      });
      const prompt = `Parley implementation turn. Work only on these explicitly submitted instructions, not the entire inherited plan. Use normal tools, obey guidelines and publish editor replies with parley_reply. Source captures may be unsaved: never overwrite unsaved editor content; conflicting source must be saved/reconciled by the user first. This is a shared workspace, not a checkout or worktree. Do not resolve conversations automatically.\n${JSON.stringify({ request: run.request, conversations })}`;
      requireCondition(Buffer.byteLength(prompt) <= maxPromptBytes, "Implementation turn exceeds 4 MiB; no truncation");
      const session = await this.ensureSession(run, preparation);
      run.activity = "working";
      await this.prompt(run, session, prompt);
      status = "completed";
      detail = "Implementation turn settled; edits and verification are recorded in the fork transcript. Editor delivery is separate.";
    } catch (error) {
      status = run.controller.signal.aborted || this.closed || this.hostSignal?.aborted ? "cancelled" : "failed";
      detail = String(error instanceof Error ? error.message : error);
    }
    run.activity = "settling";
    try {
      await this.writer.append([{ type: "outcome", id: randomUUID(), reviewId: run.request.reviewId, createdAt: now(), requestId: run.request.id,
        status, detail: detail.slice(0, 8192) || "Implementation failed" }]);
    } finally { if (this.run === run) this.run = undefined; }
  }

  private async prompt(run: Run, session: ParleyProcess, prompt: string): Promise<string> {
    this.current(run);
    const text = await session.prompt(prompt);
    this.current(run);
    return text;
  }

  summarize(request: RequestRecord, evidence: string): Promise<string | undefined> {
    requireCondition(!this.closed && !this.operation, "Implementation work is still active");
    if (!this.session) return Promise.resolve(undefined);
    const session = this.session;
    const run: Run = { request, controller: new AbortController(), activity: "starting" };
    this.run = run;
    const operation = (async () => {
      await session.lockRecap();
      const text = await this.prompt(run, session, `Finish Parley with a concise recap: changes, decisions, verification actually performed, failures/cancellations and outstanding questions. Do not resume implementation or claim resolved conversations prove correctness. Refer to the detailed transcript; changes already exist in the workspace. Artifact evidence follows:\n${evidence}`);
      requireCondition(text.trim(), "Implementation recap is empty");
      return text;
    })();
    this.operation = operation;
    return operation.finally(() => { this.operation = undefined; this.run = undefined; });
  }

  async cancel(requestId: string): Promise<void> {
    const run = this.run;
    requireCondition(run?.request.id === requestId && run.activity !== "settling", "No matching cancellable implementation request");
    run.controller.abort();
    await this.session?.abort();
    await this.operation;
  }

  close(): Promise<void> {
    if (!this.closing) {
      this.closed = true;
      this.run?.controller.abort();
      this.closing = (async () => {
        const results = await Promise.allSettled([this.session?.abort(), this.operation]);
        // Startup can still be acquiring the child. Wait before final close.
        results.push(...await Promise.allSettled([this.session?.close()]));
        if (this.sessionRecord) {
          const manager = SessionManager.open(this.sessionRecord.transcriptPath);
          await this.writer.append([{ type: "session-end", id: randomUUID(), reviewId: this.sessionRecord.reviewId,
            createdAt: now(), sessionRecordId: this.sessionRecord.id, endEntryId: manager.getLeafId() }]);
        }
        const failure = results.find(result => result.status === "rejected");
        if (failure) throw failure.reason;
      })();
    }
    return this.closing;
  }
}
