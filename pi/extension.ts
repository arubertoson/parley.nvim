import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { discover, capture, type Scope } from "./review-vcs.ts";
import { Connection } from "./connection.ts";
import { stateDirectory } from "./state.ts";
import { TurnRunner, REVIEW_PROMPT, replyPrompt } from "./turns.ts";

// Factory only registers capabilities. Socket/lease creation is lazy and session_shutdown owns cleanup.
export default function parley(pi: ExtensionAPI) {
  let connection: Connection | undefined, runner: TurnRunner | undefined, context: ExtensionContext | undefined;
  let codingPending = false, stopping = false, creating = false;
  let dialogs = 0;
  let generation = 0;
  const notify = (message: string) => context?.ui.notify(message, "info");
  const kick = () => runner?.kick();
  let idleTimer: ReturnType<typeof setInterval> | undefined;
  // Compaction and branch summaries mark ctx non-idle before these hooks.
  // Wait out a nested review call before their model request, without copying context.
  for (const event of ["session_before_compact", "session_before_tree"] as const) {
    pi.on(event, async (_event, ctx) => { context = ctx; await runner?.active?.catch(() => {}); });
  }
  pi.on("session_start", (_event, ctx) => { generation++; context = ctx; stopping = false; codingPending = false; });
  // The coding turn waits for an already-running review call. Conversely, review calls start only at idle.
  // No input is consumed or copied into another conversation, and no tree navigation is involved.
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
    try { await runner?.stop(); }
    finally { await connection?.stop(); runner = undefined; connection = undefined; context = undefined; }
  });
  pi.registerCommand("review", {
    description: "Create or reopen a frozen Parley review; continue working while the human reviews",
    handler: async (args, ctx) => {
      if (ctx.mode !== "tui") { ctx.ui.notify("Parley requires the existing interactive Pi process", "error"); return; }
      if (stopping) { ctx.ui.notify("Parley is disconnected; reload Pi before creating another review", "error"); return; }
      if (creating) { ctx.ui.notify("Review creation already in progress", "warning"); return; }
      if (args.trim()) { ctx.ui.notify("Use /review without arguments to select scope or reopen a review", "warning"); return; }
      creating = true; context = ctx;
      const token = generation;
      const current = () => !stopping && generation === token;
      try {
        const repo = await discover(ctx.cwd);
        if (!current()) return;
        if (connection && connection.root !== repo.root) throw new Error("This Pi runtime already owns reviews in another workspace");
        if (!connection) {
          const owner = new Connection(stateDirectory(), repo.root);
          await owner.start();
          if (!current()) { await owner.stop(); return; }
          connection = owner;
          runner = new TurnRunner(owner,
            () => !stopping && !creating && !codingPending && !dialogs && !!context?.isIdle() && !context.hasPendingMessages(),
            async (review, turn, signal) => {
              const current = context;
              if (!current?.model) throw new Error("Select a Pi model before submitting a review turn");
              const prompt = replyPrompt(review, turn);
              if (prompt.length > current.model.contextWindow * 2) throw new Error("Review exceeds safe model context budget; create a smaller scope");
              const response = await current.modelRegistry.streamSimple(current.model, {
                systemPrompt: REVIEW_PROMPT,
                messages: [{ role: "user", content: prompt, timestamp: Date.now() }],
              }, { signal }).result();
              if (response.stopReason !== "stop") throw new Error(response.errorMessage || `Review stopped: ${response.stopReason}`);
              return response.content.filter(part => part.type === "text").map(part => part.text).join("\n");
            }, notify);
          owner.onSubmit = kick;
          owner.onFailure = async error => {
            stopping = true;
            notify(`Parley socket failed: ${error.message}. Reload Pi to reconnect; review contents are retained.`);
            await runner?.stop();
          };
          idleTimer = setInterval(kick, 500); idleTimer.unref();
        }
        const existing = (await connection.store.list()).filter(r => r.status === "open");
        if (!current()) return;
        const choices = ["Create a new frozen review", ...existing.map(r => `${r.id} · ${r.scope} · ${r.createdAt}`)];
        const choice = await ctx.ui.select("Parley reviews in this workspace", choices);
        if (!choice || !current()) return;
        if (choice !== choices[0]) {
          const selected = existing[choices.indexOf(choice) - 1];
          notify(`Review ${selected.id} available in Neovim :ReviewStart (original frozen contents)`); return;
        }
        let scope: Scope;
        if (repo.vcs === "git") {
          const kind = await ctx.ui.select("Freeze which Git state?", ["Staged changes only", "Working tree (including staged and untracked)", "Explicit revision range"]);
          if (!kind || !current()) return;
          scope = kind.startsWith("Staged") ? { kind: "staged" } : kind.startsWith("Working") ? { kind: "working" } : { kind: "range", from: "", to: "" };
        } else scope = { kind: "range", from: "", to: "" };
        if (scope.kind === "range") {
          const from = await ctx.ui.input("Baseline revision (jj has no staging area)", repo.vcs === "jj" ? "trunk()" : "main");
          if (!from?.trim() || !current()) return;
          const to = await ctx.ui.input("Tip revision to freeze", repo.vcs === "jj" ? "@" : "HEAD");
          if (!to?.trim() || !current()) return;
          scope = { kind: "range", from: from.trim(), to: to.trim() };
        }
        const seed = await ctx.ui.editor("Curated review context (only this text is shared; no automatic conversation copy)", "");
        if (seed === undefined || !current()) return;
        const snapshot = await capture(repo, scope);
        if (!current()) return;
        if (!await ctx.ui.confirm("Create frozen review?", `${snapshot.scope}\n${snapshot.files.length} files. No code will be changed.`)) return;
        if (!current()) return;
        const review = await connection.serial(async () => {
          if (!current()) return;
          return connection!.store.create(snapshot, seed);
        });
        if (review && current()) notify(`Review ${review.id} ready. Neovim :ReviewStart attaches; Pi remains available.`);
      } catch (error) { if (current()) ctx.ui.notify(`Parley: ${error instanceof Error ? error.message : String(error)}`, "error"); }
      finally { creating = false; kick(); }
    },
  });
}
