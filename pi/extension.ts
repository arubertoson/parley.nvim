import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { discover, capture, type Scope } from "./review-vcs.ts";
import { Connection } from "./connection.ts";
import { stateDirectory, readWorkspacePreparationModel, saveWorkspacePreparationModel, reviewedPaths, reviewedUnits, type Review } from "./state.ts";
import { groupReview, stageUnits } from "./grouping.ts";
import { checkInputBudget, inputFits } from "./budget.ts";
import { TurnRunner, TurnDeferred, INITIAL_PROMPT, REVIEW_PROMPT, CONCLUSION_PROMPT, replyPrompt, type ReviewActivity } from "./turns.ts";
import { sessionFromBranch, prepareContext, type PreparationInput } from "./preparation.ts";
import { registerPlanning, planningSession, workspaceSession, WORKSPACE } from "./planning.ts";

// Factory only registers capabilities. Socket/lease creation is lazy and session_shutdown owns cleanup.
export default function parley(pi: ExtensionAPI) {
  pi.registerFlag("parley-preparation-model", { type: "string", description: "Preparation model override (provider/id); otherwise PARLEY_PREPARATION_MODEL or the saved workspace default." });
  let connection: Connection | undefined, runner: TurnRunner | undefined, context: ExtensionContext | undefined;
  let codingPending = false, stopping = false, creating = false, reconnecting = false, offering = false;
  let dialogs = 0;
  let generation = 0;
  let activity: ReviewActivity | undefined, activityTimer: ReturnType<typeof setInterval> | undefined, frame = 0;
  // Presentation only: never use Pi's coding-turn loader, focus, transcript or editor contents.
  const renderActivity = () => {
    if (stopping || context?.mode !== "tui") return;
    const text = activity ? `${activity.state === "running" ? "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[frame++ % 10] + " " : ""}Parley${activity.reviewId ? " " + activity.reviewId.slice(0, 8) : ""} · ${activity.text}` : undefined;
    context.ui.setStatus("parley", text?.replace(/[\x00-\x1f\x7f-\x9f]/g, " ").slice(0, 220));
  };
  const setActivity = (next: ReviewActivity) => {
    if (stopping) return;
    // A newly queued request must not hide another review's actual running work.
    if (next.state === "queued" && activity?.state === "running" && activity.reviewId !== next.reviewId) return;
    activity = next;
    if (activityTimer && (next.state !== "running" || context?.mode !== "tui")) { clearInterval(activityTimer); activityTimer = undefined; }
    if (!activityTimer && next.state === "running" && context?.mode === "tui") {
      activityTimer = setInterval(renderActivity, 120); activityTimer.unref();
    }
    renderActivity();
  };
  const storedActivity = (review: Review) => {
    const turn = review.turns.find(t => t.status === "queued" || t.status === "running") ?? review.turns.at(-1);
    if (!turn) return;
    const saved = review.groupingProgress;
    const progress = saved ? ` · ${saved.summaries.length}/${saved.units.length} summaries saved` : "";
    setActivity({ reviewId: review.id, state: turn.status === "error" ? "error" : turn.status === "complete" ? "ready" : "queued",
      text: turn.status === "error" ? `Failed${progress}: ${turn.error ?? "unknown error"}`
        : turn.status !== "complete" ? `${turn.kind === "grouping" ? "Grouping" : "Review request"} queued${progress} · waiting for Pi availability`
        : turn.kind === "grouping" ? `Groups ready · ${review.grouping?.stageIds.length ?? 0} stored · /review to choose (not review coverage)`
        : turn.kind === "initial" ? `Findings ready · ${turn.findings?.length ?? 0} · examined, not approval`
        : turn.kind === "conclusion" ? "Thread conclusion ready (not verification)" : "Discussion replies ready" });
  };
  const notify = (message: string) => context?.ui.notify(message, "info");
  const hostAvailable = () => !stopping && !creating && !reconnecting && !offering && !codingPending && !dialogs && !!context?.isIdle() && !context.hasPendingMessages();
  const planning = registerPlanning(pi, () => connection, () => context, () => hostAvailable() && !runner?.active,
    async () => { await runner?.active?.catch(() => {}); },
    async (ctx, root) => { context = ctx; await ensureConnection(root, true); });
  const available = () => hostAvailable() && !planning.switching;
  const kick = () => { void offerEditors(); planning.kick(); if (!planning.switching) void runner?.kick(); };
  async function offerEditors() {
    const owner = connection, ctx = context, token = generation;
    if (!owner || ctx?.mode !== "tui" || !available() || runner?.active) return;
    const offer = owner.nextOffer(), editors = owner.editorChoices();
    if (!offer || !editors.length) return;
    if (editors.length === 1) { owner.assignOffer(offer, editors[0].id); return; }
    offering = true;
    try {
      const labels = editors.map(e => `${e.label} · ${e.id}`);
      const choice = await ctx.ui.select(`Offer frozen review ${offer.reviewId} to which Neovim?`, labels);
      if (stopping || generation !== token || connection !== owner || context !== ctx) return;
      const selected = choice === undefined ? undefined : editors[labels.indexOf(choice)];
      if (choice !== undefined && !selected) throw new Error("Unknown editor selection");
      owner.assignOffer(offer, selected?.id);
    } catch (error) {
      if (generation === token) { owner.assignOffer(offer); notify(`Parley editor pairing: ${String(error)}. ReviewStart remains available.`); }
    } finally { if (generation === token) offering = false; }
  }
  const preparationModel = () => String(pi.getFlag("parley-preparation-model") || process.env.PARLEY_PREPARATION_MODEL || "").trim();
  let idleTimer: ReturnType<typeof setInterval> | undefined;
  // Compaction and branch summaries mark ctx non-idle before these hooks.
  // Wait out a nested review call before their model request, without copying context.
  const waitForReview = async (_event: unknown, ctx: ExtensionContext) => { context = ctx; await runner?.active?.catch(() => {}); };
  pi.on("session_before_compact", waitForReview);
  pi.on("session_before_tree", waitForReview);
  pi.on("session_start", async (_event, ctx) => {
    generation++; context = ctx; stopping = false; codingPending = false; offering = false;
    renderActivity();
    const plan = planningSession(ctx), workspace = workspaceSession(ctx);
    const root = plan?.root ?? workspace?.root;
    if (!root) return;
    try {
      await ensureConnection(root, workspace?.processId === process.pid);
      await planning.attached(ctx);
    } catch (error) {
      await planning.attachmentError(error);
      ctx.ui.notify(`Parley reconnect: ${String(error)}. Frozen review contents retained.`, "error");
    }
  });
  // The coding turn waits for an already-running review call. Conversely, review calls start only at idle.
  // Isolated review calls never copy input or navigate trees; explicit planning handoffs own session replacement.
  pi.on("before_agent_start", async (_event, ctx) => {
    context = ctx; codingPending = true;
    await runner?.active?.catch(() => {}); // Runner already reports persistence/provider failures.
  });
  pi.on("agent_settled", (_event, ctx) => {
    context = ctx; codingPending = false;
    setImmediate(kick); // Notification-only hook: work starts after Pi has settled.
  });
  pi.on("ui_prompt_start", () => { dialogs++; });
  pi.on("ui_prompt_end", () => { dialogs = Math.max(0, dialogs - 1); setImmediate(kick); });
  pi.on("session_shutdown", async () => {
    stopping = true; generation++;
    if (idleTimer) clearInterval(idleTimer); idleTimer = undefined;
    if (activityTimer) clearInterval(activityTimer); activityTimer = undefined;
    if (context?.mode === "tui") context.ui.setStatus("parley", undefined);
    activity = undefined;
    try { await runner?.stop(); }
    finally { await connection?.stop(); runner = undefined; connection = undefined; context = undefined; }
  });
  async function ensureConnection(root: string, preserveQueued = false) {
    if (connection) {
      if (connection.root !== root) throw new Error("This Pi runtime already owns reviews in another workspace");
      return;
    }
    const token = generation;
    reconnecting = true;
    try {
      const owner = new Connection(stateDirectory(), root);
      await owner.start(preserveQueued);
      if (stopping || generation !== token) { await owner.stop(); return; }
      connection = owner;
      runner = new TurnRunner(owner,
        available,
        async (review, turn, signal) => {
          const current = context;
          if (!current?.model) throw new Error("Select a Pi model before submitting a review turn");
          const prompt = replyPrompt(review, turn);
          const systemPrompt = turn.kind === "initial" ? INITIAL_PROMPT : turn.kind === "conclusion" ? CONCLUSION_PROMPT : REVIEW_PROMPT;
          checkInputBudget(current.model.contextWindow, systemPrompt, prompt,
            turn.kind === "initial" ? `Use /review --groups ${review.id} to propose bounded groups or /review-stage ${review.id} for an advanced scope. No evidence was refreshed or omitted.`
              : "No discussion was omitted. This request requires finer-grained evidence/context support before it can run.");
          const response = await current.modelRegistry.streamSimple(current.model, {
            systemPrompt,
            messages: [{ role: "user", content: prompt, timestamp: Date.now() }],
          }, { signal, maxTokens: Math.min(8192, current.model.maxTokens, Math.floor(current.model.contextWindow / 2)) }).result();
          if (response.stopReason !== "stop") throw new Error(response.errorMessage || `Review stopped: ${response.stopReason}`);
          return response.content.filter(part => part.type === "text").map(part => part.text).join("\n");
        }, notify, async (review, signal) => {
          const ctx = context;
          if (!ctx || !review.preparation) throw new Error("Preparation context is unavailable");
          if (!ctx.model) throw new Error("Select a Pi review model before preparing review context");
          const reviewModel = ctx.model;
          const key = review.preparation.input.model, separator = key.indexOf("/");
          const model = separator > 0 ? ctx.modelRegistry.find(key.slice(0, separator), key.slice(separator + 1)) : undefined;
          if (!model) throw new Error(`Frozen preparation model ${key || "(unset)"} is unavailable; make it available in Pi and explicitly retry. Changing the default does not refresh this review.`);
          return prepareContext(review.preparation.input, review, async (systemPrompt, prompt, signal) => {
            if (!available()) throw new TurnDeferred("Pi is busy");
            checkInputBudget(model.contextWindow, systemPrompt, prompt, "Frozen preparation inputs are retained; nothing was recaptured and the selected model was not changed.");
            const response = await ctx.modelRegistry.streamSimple(model, { systemPrompt, messages: [{ role: "user", content: prompt, timestamp: Date.now() }] }, { signal, maxTokens: Math.min(4096, model.maxTokens) }).result();
            if (response.stopReason !== "stop") throw new Error(response.errorMessage || `Preparation stopped: ${response.stopReason}`);
            return response.content.filter(part => part.type === "text").map(part => part.text).join("\n");
          }, signal, review.preparation.progress, progress => owner.serial(async () => {
            const current = await owner.store.read(review.id);
            current.preparation!.progress = structuredClone(progress);
            await owner.store.write(current);
          }), (system, prompt, guidelines) => inputFits(model.contextWindow, system, prompt)
            // Reusable guidelines/summary get at most half the allowed review input; leave room for a file piece.
            && inputFits(reviewModel.contextWindow / 2, INITIAL_PROMPT, JSON.stringify({ guidelines, summary: " ".repeat(8000) })));
        }, async (review, turn, signal) => {
          const ctx = context;
          if (!ctx?.model || !review.preparation?.context) throw new Error("Select a Pi review model and prepare context before grouping");
          if (turn.kind !== "grouping" && !review.groupingProgress && inputFits(ctx.model.contextWindow, INITIAL_PROMPT, replyPrompt(review, turn), 0.4)) return;
          if (review.grouping) throw new Error(`Stored groups already exist; use /review --groups ${review.id} to choose one`);
          await owner.serial(async () => {
            const current = await owner.store.read(review.id);
            current.turns.find(t => t.id === turn.id)!.kind = "grouping";
            await owner.store.write(current);
          });
          turn.kind = "grouping";
          const reviewModel = ctx.model, key = review.preparation.input.model, separator = key.indexOf("/");
          const model = ctx.modelRegistry.find(key.slice(0, separator), key.slice(separator + 1));
          if (!model) throw new Error(`Frozen preparation/grouping model ${key} is unavailable; no fallback or recapture was performed`);
          notify(`Organizing frozen review ${review.id} with ${key}, sized for ${reviewModel.provider}/${reviewModel.id}. Sharing original source in bounded summary calls; summaries do not count as review coverage. Target 40%, hard ceiling 50%, using conservative UTF-8 bounds.`);
          return groupReview(review, { model: key, reviewModel: `${reviewModel.provider}/${reviewModel.id}`,
            progress: text => setActivity({ reviewId: review.id, state: "running", text }),
            contextWindow: reviewModel.contextWindow, modelWindow: model.contextWindow, reviewSystem: INITIAL_PROMPT,
            reviewPrompt: (stage, units) => replyPrompt({ ...review, stages: [stage], groupingProgress: {
              model: key, reviewModel: `${reviewModel.provider}/${reviewModel.id}`, contextWindow: reviewModel.contextWindow,
              units, summaries: review.groupingProgress?.summaries ?? [],
            } }, { id: "budget", kind: "initial", stageId: stage.id, status: "queued", notes: [], replies: [] }),
            call: async (systemPrompt, prompt, signal) => {
              if (!available()) throw new TurnDeferred("Pi is busy");
              checkInputBudget(model.contextWindow, systemPrompt, prompt, "Grouping progress is retained. No source was omitted or marked reviewed; the bounded grouping catalogue cannot fit this selected model.");
              const response = await ctx.modelRegistry.streamSimple(model, { systemPrompt,
                messages: [{ role: "user", content: prompt, timestamp: Date.now() }] }, {
                signal, maxTokens: Math.min(8192, model.maxTokens, Math.floor(model.contextWindow / 2)),
              }).result();
              if (response.stopReason !== "stop") throw new Error(response.errorMessage || `Grouping stopped: ${response.stopReason}`);
              return response.content.filter(part => part.type === "text").map(part => part.text).join("\n");
            }, checkpoint: progress => owner.serial(async () => {
              const current = await owner.store.read(review.id);
              current.groupingProgress = structuredClone(progress);
              await owner.store.write(current);
              review.groupingProgress = structuredClone(progress);
            }),
          }, signal);
        }, setActivity);
      owner.onSubmit = reviewId => {
        void owner.serial(async () => {
          const review = await owner.store.read(reviewId);
          if (connection === owner && activity?.state !== "running") storedActivity(review);
        }).catch(error => notify(`Parley activity: ${String(error)}`));
        kick();
      };
      owner.origin = () => context ? { sessionId: context.sessionManager.getSessionId(), sessionFile: context.sessionManager.getSessionFile(), leafId: context.sessionManager.getLeafId() } : undefined;
      owner.onFinish = (reviewId, collectionId, handoffId) => { planning.request(reviewId, collectionId, handoffId); kick(); };
      owner.onFailure = async error => {
        setActivity({ state: "error", text: "Workspace socket disconnected · /reload to reconnect (review retained)" });
        stopping = true;
        notify(`Parley socket failed: ${error.message}. Reload Pi to reconnect; review contents are retained.`);
        await runner?.stop();
      };
      // Reconstruct the most recent durable outcome on reload without queuing generation.
      for (const row of await owner.store.list()) {
        if (stopping || generation !== token || connection !== owner) break;
        if (row.status !== "open") continue;
        const review = await owner.store.read(row.id);
        if (stopping || generation !== token || connection !== owner) break;
        if (!review.turns.length) continue;
        storedActivity(review); break;
      }
      idleTimer = setInterval(kick, 500); idleTimer.unref();
    } finally { reconnecting = false; }
  }
  pi.registerCommand("review-stage", {
    description: "Explicitly review/retry a frozen file piece: <review ID> [piece ID | paths | JSON path array]; completed pieces only activate scope",
    handler: async (args, ctx) => {
      if (ctx.mode !== "tui" || stopping || creating || runner?.active) {
        ctx.ui.notify("Parley: wait for the current Pi/review request to settle before selecting a piece", "warning"); return;
      }
      const match = /^([a-zA-Z0-9_-]{1,128})(?:\s+([\s\S]*))?$/.exec(args.trim());
      if (!match) { ctx.ui.notify("Use /review-stage <review ID> [piece ID | frozen paths | JSON path array]", "error"); return; }
      creating = true; context = ctx;
      const token = generation, current = () => !stopping && generation === token && context === ctx;
      try {
        const repo = await discover(ctx.cwd);
        if (!current()) return;
        await ensureConnection(repo.root);
        if (!current() || !connection) return;
        const owner = connection, review = await owner.serial(() => owner.store.read(match[1]));
        if (workspaceSession(ctx)?.root !== repo.root || workspaceSession(ctx)?.processId !== process.pid) {
          pi.appendEntry(WORKSPACE, { root: repo.root, processId: process.pid });
        }
        if (!current()) return;
        if (review.status !== "open" || !review.preparation) throw new Error("Choose an open agent-first frozen review");
        const covered = reviewedPaths(review);
        let stage = review.stages?.find(s => s.id === match[2]);
        let paths: string[];
        if (stage) paths = stage.paths;
        else if (match[2]) {
          const raw: unknown = match[2].startsWith("[") ? JSON.parse(match[2]) : match[2].split(/\s+/);
          if (!Array.isArray(raw) || raw.some(p => typeof p !== "string")) throw new Error("Expected frozen paths or a JSON array of paths");
          paths = raw;
        } else {
          const existing = (review.stages ?? []).map(s => ({ stage: s, paths: s.paths,
            label: `${s.purpose} · ${review.turns.some(t => t.stageId === s.id && t.status === "complete" && t.kind === "initial") ? "agent pass complete" : "not yet examined"} · ${s.id}` }));
          const choices = [...existing, ...review.files.filter(f => !covered.has(f.path)).map(f => ({
            stage: undefined, paths: [f.path], label: `New piece: ${f.path} · not yet examined`,
          }))];
          if (!choices.length) throw new Error("All files have an agent pass; use explicit frozen paths for a separate scoped pass");
          const selected = await ctx.ui.select(`Review ${review.id}: ${covered.size}/${review.files.length} files examined. Choose a piece to generate findings (completed pieces only activate scope).`, choices.map(c => c.label));
          if (!selected || !current()) return;
          const choice = choices.find(c => c.label === selected);
          if (!choice) throw new Error("Unknown piece selection");
          paths = choice.paths; stage = choice.stage;
        }
        if (!paths.length || new Set(paths).size !== paths.length || paths.some(p => !review.files.some(f => f.path === p))) throw new Error("Select distinct original frozen file paths; live files are not captured");
        const purpose = stage?.purpose ?? await ctx.ui.input("Purpose/boundaries for this piece (other files remain outside scope)", `Review ${paths.join(", ")}`);
        if (!purpose?.trim() || !current()) return;
        const saved = await owner.serial(async () => current() ? owner.store.stage(review.id, paths, purpose.trim(), stage?.id) : undefined);
        if (!saved || !current()) return;
        const queued = saved.turns.some(t => t.stageId === saved.activeStageId && t.status === "queued");
        storedActivity(saved);
        owner.offer(saved);
        notify(`Frozen review ${saved.id} · piece ${saved.activeStageId}: ${paths.join(", ")} · ${queued ? "findings explicitly queued using frozen session context/guidelines and only this piece's source contents" : "scope activated; no model work"}. Other files remain outside this piece; evidence is unchanged. Each input is limited to 50% of its model window using a conservative UTF-8 byte token bound.`);
      } catch (error) { if (current()) ctx.ui.notify(`Parley: ${error instanceof Error ? error.message : String(error)}`, "error"); }
      finally { creating = false; kick(); }
    },
  });

  async function chooseGroup(review: Review, ctx: ExtensionContext, current: () => boolean) {
    const owner = connection!;
    if (review.status !== "open" || !review.preparation) throw new Error("Choose an open agent-first frozen review");
    if (!review.grouping) {
      const choice = await ctx.ui.select(`Organize original frozen review ${review.id}? No recapture. Bounded source summaries go to ${review.preparation.input.model}; they are not review coverage.`, ["Propose review groups", "Cancel"]);
      if (choice !== "Propose review groups" || !current()) return;
      const saved = await owner.serial(async () => current() ? owner.store.requestGrouping(review.id) : undefined);
      if (!saved || !current()) return;
      storedActivity(saved);
      notify(`Frozen review ${review.id}: grouping explicitly queued; progress will be retained. Use /review to choose stored groups when ready.`);
      return;
    }
    const covered = reviewedUnits(review);
    const groups = review.grouping.stageIds.map(id => review.stages!.find(s => s.id === id)!);
    const labels = groups.map(s => `${s.purpose} · ${s.unitIds!.filter(id => covered.has(id)).length}/${s.unitIds!.length} units examined · ${s.id}`);
    const selected = await ctx.ui.select(`Frozen review ${review.id}: ${covered.size}/${review.grouping.units.length} source units examined. Choose a group (other units excluded). Selection requests findings unless this exact group already completed.`, labels);
    if (!selected || !current()) return;
    const stage = groups[labels.indexOf(selected)];
    if (!stage) throw new Error("Unknown stored group");
    const scope = stageUnits(review, stage).map(u => `${u.id}: ${u.path}${u.side ? `:${u.side}:${u.first}-${u.last}` : " (whole file)"}`);
    const excluded = review.grouping.units.filter(u => !stage.unitIds!.includes(u.id)).map(u => u.id);
    notify(`Group ${stage.id}: ${scope.join(", ")}. Excluded units: ${excluded.join(", ") || "none"}. Advisory dependencies: ${stage.dependencies?.join(", ") || "none"}. Group questions: ${review.grouping.summaries.filter(s => stage.unitIds!.includes(s.unitId)).flatMap(s => s.questions).join("; ") || "none recorded"}. ${review.grouping.limitations.join(" ")}`);
    const saved = await owner.serial(async () => current() ? owner.store.stage(review.id, stage.paths, stage.purpose, stage.id) : undefined);
    if (!saved || !current()) return;
    owner.offer(saved);
    storedActivity(saved);
    notify(`Frozen group ${stage.id} selected; all discussion and drafts remain in review ${review.id}. Completed passes mean examined, not accepted, resolved or fixed.`);
  }

  pi.registerCommand("review", {
    description: "Prepare/choose a frozen review [focus]; --groups ID resumes grouping; --close ID retains contents and retires a review; --freeze-only, --curate, --reopen ID, range are advanced options",
    handler: async (args, ctx) => {
      if (ctx.mode !== "tui") { ctx.ui.notify("Parley requires the existing interactive Pi process", "error"); return; }
      if (stopping) { ctx.ui.notify("Parley is disconnected; reload Pi before creating another review", "error"); return; }
      if (creating) { ctx.ui.notify("Review creation already in progress", "warning"); return; }
      const freezeOnly = /(?:^|\s)--freeze-only(?=\s|$)/.test(args);
      const curate = /(?:^|\s)--curate(?=\s|$)/.test(args);
      const remaining = args.replace(/(?:^|\s)--(?:freeze-only|curate)(?=\s|$)/g, " ").trim();
      const range = remaining === "range" || remaining.startsWith("range ");
      const focus = range ? remaining.slice(5).trim() : remaining;
      creating = true; context = ctx;
      // A reference only: freeze-only never projects or shares conversation text.
      const origin = { sessionId: ctx.sessionManager.getSessionId(),
        sessionFile: ctx.sessionManager.getSessionFile(), leafId: ctx.sessionManager.getLeafId() };
      const token = generation;
      const current = () => !stopping && generation === token;
      try {
        const repo = await discover(ctx.cwd);
        if (!current()) return;
        if (connection && connection.root !== repo.root) throw new Error("This Pi runtime already owns reviews in another workspace");
        await ensureConnection(repo.root);
        if (!current() || !connection) return;
        if (workspaceSession(ctx)?.root !== repo.root || workspaceSession(ctx)?.processId !== process.pid) {
          pi.appendEntry(WORKSPACE, { root: repo.root, processId: process.pid });
        }
        if (remaining.startsWith("--close")) {
          const id = /^--close ([a-zA-Z0-9_-]{1,128})$/.exec(remaining)?.[1];
          if (!id || freezeOnly || curate) throw new Error("Use /review --close <review ID>; contents are retained, not deleted");
          if (planning.switching) throw new Error("Wait for the planning session switch to settle before closing a review");
          const closed = await connection.closeReview(id);
          if (!current()) return;
          if (activity?.reviewId === closed.id) setActivity({ reviewId: closed.id, state: "ready", text: "Closed · evidence and discussion retained (not approval)" });
          notify(`Review ${closed.id} closed and removed from open pickers/offers; frozen evidence, findings, discussion and saved grouping progress retained. No generation or planning handoff requested. Attached Neovim drafts remain local; :ReviewStop detaches.`);
          return;
        }
        if (remaining.startsWith("--groups")) {
          const id = /^--groups ([a-zA-Z0-9_-]{1,128})$/.exec(remaining)?.[1];
          if (!id || freezeOnly || curate) throw new Error("Use /review --groups <review ID> to propose/retry or select original frozen groups");
          if (runner?.active) throw new Error("Wait for the current review request to settle before choosing a group");
          await chooseGroup(await connection.serial(() => connection!.store.read(id)), ctx, current);
          return;
        }
        if (!remaining && !freezeOnly && !curate && !runner?.active) {
          const reviews = await connection.serial(async () => Promise.all((await connection!.store.list()).filter(r => r.status === "open").map(r => connection!.store.read(r.id))));
          if (!current()) return;
          const resumable = reviews.filter(r => r.grouping || r.groupingProgress || r.turns.some(t => t.kind === "initial" && !t.stageId && t.status === "error"));
          if (resumable.length) {
            const labels = resumable.map(r => `Frozen ${r.id} · ${r.scope} · ${r.grouping ? "choose stored group" : "propose/retry groups"}`);
            const selected = await ctx.ui.select("Resume frozen review groups or prepare a new review?", [...labels, "Freeze a new review"]);
            if (!selected || !current()) return;
            if (selected !== "Freeze a new review") {
              const review = resumable[labels.indexOf(selected)];
              if (!review) throw new Error("Unknown frozen review selection");
              await chooseGroup(review, ctx, current); return;
            }
          }
        }
        if (remaining.startsWith("--reopen")) {
          const id = /^--reopen ([a-zA-Z0-9_-]{1,128})$/.exec(remaining)?.[1];
          if (!id) throw new Error("Use /review --reopen <review ID>; reopening preserves the original scope and context");
          const selected = await connection.serial(() => connection!.store.read(id));
          if (!current()) return;
          if (selected.status !== "open") throw new Error("Review is closed; reopening cannot refresh or replace it");
          connection.offer(selected, true);
          notify(`Review ${selected.id} offered with its original frozen contents; ReviewStart remains available.`);
          return;
        }
        if (freezeOnly && curate) throw new Error("Freeze-only uses the supplied focus directly; omit --curate");
        let scope: Scope;
        if (range) scope = { kind: "range", from: "", to: "" };
        else if (repo.vcs === "git") {
          const kind = await ctx.ui.select("Freeze which Git state?", ["Staged changes only", "Working tree (including staged and untracked)", "Explicit revision range"]);
          if (!kind || !current()) return;
          scope = kind.startsWith("Staged") ? { kind: "staged" } : kind.startsWith("Working") ? { kind: "working" } : { kind: "range", from: "", to: "" };
        } else scope = { kind: "range", from: "@-", to: "@" };
        if (scope.kind === "range" && !scope.from) {
          const from = await ctx.ui.input("Baseline revision", repo.vcs === "jj" ? "@-" : "main");
          if (!from?.trim() || !current()) return;
          const to = await ctx.ui.input("Tip revision to freeze", repo.vcs === "jj" ? "@" : "HEAD");
          if (!to?.trim() || !current()) return;
          scope = { kind: "range", from: from.trim(), to: to.trim() };
        }
        const seed = curate ? await ctx.ui.editor("Human focus/context (kept separate from generated context)", focus) : focus;
        if (seed === undefined || !current()) return;
        const snapshot = await capture(repo, scope);
        if (!current()) return;
        const override = preparationModel();
        let modelKey = override;
        let settingsError: unknown;
        if (!freezeOnly && !override) {
          try { modelKey = await readWorkspacePreparationModel(connection.directory, repo.root) ?? ""; }
          catch (error) { settingsError = error; }
        }
        if (!current()) return;
        const resolveModel = (key: string | undefined) => {
          const separator = key?.indexOf("/") ?? -1;
          return key && separator > 0 ? ctx.modelRegistry.find(key.slice(0, separator), key.slice(separator + 1)) : undefined;
        };
        let input: PreparationInput | undefined;
        if (!freezeOnly) {
          if (settingsError) throw settingsError;
          if (!override && !resolveModel(modelKey)) {
            const models = ctx.modelRegistry.getAvailable().map(model => `${model.provider}/${model.id}`).sort();
            if (!models.length) throw new Error("No preparation models available in Pi; configure a model or use /review --freeze-only");
            const selected = await ctx.ui.select(`Choose a fast preparation model (saved for this workspace only)${modelKey ? `\nSaved model ${modelKey} is unavailable; choose a replacement.` : ""}`, models);
            if (!selected || !current()) return;
            if (!models.includes(selected) || !resolveModel(selected)) throw new Error("Selected preparation model is unavailable");
            modelKey = selected;
            await connection.serial(async () => {
              if (current()) await saveWorkspacePreparationModel(connection!.directory, repo.root, selected);
            });
            if (!current()) return;
            notify(`Preparation default saved for this workspace: ${modelKey}`);
          }
          if (!modelKey || !resolveModel(modelKey)) throw new Error(`Preparation model override ${modelKey || "(unset)"} is unavailable; correct or remove --parley-preparation-model / PARLEY_PREPARATION_MODEL to use the workspace default`);
          notify(`Requesting agent-first review of ${snapshot.scope} · ${snapshot.files.length} files. Sharing up to 16 session text messages / 32,000 characters including the latest compaction summary, trusted skill descriptions and selected reference content. Preparation sees file metadata, not source contents. Preparation: ${modelKey}; review: selected Pi model. Inputs are limited to 50% of each model window using a conservative UTF-8 byte token bound. Human focus stays separate; no fixing authority.`);
          const skills = (ctx.getSystemPromptOptions().skills ?? []).filter(skill => !skill.disableModelInvocation);
          input = { model: modelKey, session: sessionFromBranch(ctx.sessionManager.getBranch(), ctx.sessionManager.getSessionId(), ctx.sessionManager.getLeafId() ?? undefined),
            skills: skills.slice(0, 80).map(({ name, description, filePath }) => ({ name, description: description.slice(0, 1_200), filePath })), omittedSkills: Math.max(0, skills.length - 80) };
        }
        const review = await connection.serial(async () => {
          if (!current()) return;
          return connection!.store.create(snapshot, seed, input, origin);
        });
        if (review && current()) {
          storedActivity(review);
          if (!input) connection.offer(review);
          notify(`Review ${review.id} frozen${input ? "; preparation and budget check queued for Pi availability. Oversized inputs produce stored groups for /review; otherwise initial findings are prepared before the editor offer" : " (freeze-only); Neovim will offer Open/Dismiss"}. ReviewStart remains available.`);
        }
      } catch (error) { if (current()) ctx.ui.notify(`Parley: ${error instanceof Error ? error.message : String(error)}`, "error"); }
      finally { creating = false; kick(); }
    },
  });
}
