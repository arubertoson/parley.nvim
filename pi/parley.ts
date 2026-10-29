// /parley owns one hosted implementation period. The parent waits in one tool;
// the independent child transcript contains the detailed turns. No terminal
// injection, parent session switching, background parent execution or replay.
import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext, ExtensionToolContext } from "@earendil-works/pi-coding-agent";
import { WorkspaceBridge, workspaceRoot } from "./bridge.ts";
import { ReviewRequests } from "./requests.ts";
import type { ParleyFork } from "./parley-interaction.ts";

const brief = { objective: "Carry out explicitly submitted editor instructions in the implementation fork. Do not resume the entire inherited plan.",
  scope: [], decisions: [], guidelines: [], context: [] };

type Interaction = {
  readonly id: string;
  readonly sessionId: string;
  readonly transcriptPath: string;
  readonly startEntryId: string | null;
  readonly ctx: ExtensionContext;
  fork?: ParleyFork;
  owner?: ReviewRequests;
  bridge?: WorkspaceBridge;
  startup?: Promise<void>;
  cleanup?: Promise<void>;
  stopping?: Promise<void>;
  ready?: boolean;
  stopped?: boolean;
  hostCallId?: string;
  launchAllowed: boolean;
  failed?: unknown;
  resolve?: (summary: string) => void;
  reject?: (error: unknown) => void;
};

export function installParley(pi: ExtensionAPI, review: {
  busy(): boolean;
  release(): Promise<void>;
  captureCommit(root: string, signal?: AbortSignal): Promise<string>;
}): {
  active(): boolean;
  close(): Promise<void>;
  start(args: string, ctx: ExtensionCommandContext): Promise<void>;
  stop(args: string, ctx: ExtensionCommandContext): Promise<void>;
} {
  let interaction: Interaction | undefined;
  let retained: Interaction | undefined;

  function current(owner: Interaction): boolean {
    return interaction === owner && !owner.stopped && owner.ctx.sessionManager.getSessionId() === owner.sessionId
      && owner.ctx.sessionManager.getSessionFile() === owner.transcriptPath;
  }

  function cleanup(owner: Interaction): Promise<void> {
    owner.cleanup ??= (async () => {
      // Finish acquisition before teardown, and settle execution before releasing
      // the workspace lease. Host failure, stop and shutdown share this cleanup.
      const results = await Promise.allSettled([owner.startup]);
      results.push(...await Promise.allSettled([owner.owner?.close()]));
      results.push(...await Promise.allSettled([owner.bridge?.stop()]));
      const failure = results.find(result => result.status === "rejected");
      if (failure) throw failure.reason;
    })();
    return owner.cleanup;
  }

  async function close(): Promise<void> {
    const owner = interaction;
    if (owner) {
      owner.stopped = true;
      owner.launchAllowed = false;
      owner.reject?.(new Error("Parley host closed; edits and transcripts retained, no rollback"));
    }
    const previous = retained;
    retained = undefined;
    try {
      const results = await Promise.allSettled([...new Set([owner, previous])].filter((item): item is Interaction => !!item).map(cleanup));
      const failure = results.find(result => result.status === "rejected");
      if (failure) throw failure.reason;
    } finally {
      if (interaction === owner) interaction = undefined;
    }
  }

  // The independent child owns execution. The waiting parent has no nested
  // implementation authority, even under the host call.
  pi.on("tool_call", event => {
    const owner = interaction;
    if (!owner) return;
    if (event.toolName === "parley_interact" && !owner.hostCallId) return;
    return { block: true, reason: "The editor implementation fork owns execution. Finish or cancel Parley before parent work." };
  });
  pi.on("user_bash", () => {
    if (interaction) throw new Error("Parley owns execution; finish or cancel it before running parent shell commands");
  });
  pi.on("before_agent_start", () => {
    const owner = interaction;
    if (!owner) return;
    if (owner.launchAllowed) { owner.launchAllowed = false; return; }
    throw new Error("Parley owns execution; no concurrent parent run");
  });
  pi.on("input", (event, ctx) => {
    if (interaction && event.source !== "extension") {
      ctx.ui.notify("Parley is active. Use :Parley submit / :Parley done in Neovim, or /parley stop here. Input was not queued.", "warning");
      return { action: "handled" };
    }
  });
  pi.on("agent_settled", async () => {
    const owner = interaction;
    if (owner && !owner.hostCallId) {
      owner.failed = new Error("Parent did not enter parley_interact; no implementation started");
      await close();
      owner.ctx.ui.notify(String(owner.failed), "error");
    }
  });

  async function start(args: string, ctx: ExtensionCommandContext): Promise<void> {
    if (args.trim() || ctx.mode !== "tui" || !ctx.isIdle() || ctx.hasPendingMessages() || interaction || review.busy()) {
      ctx.ui.notify("Use /parley without arguments from an idle parent, after completing any open review. Nothing queued.", "error");
      return;
    }
    const transcriptPath = ctx.sessionManager.getSessionFile();
    if (!transcriptPath || !ctx.model) {
      ctx.ui.notify("Parley requires a persistent parent transcript and explicit model.", "error");
      return;
    }
    const owner: Interaction = { id: randomUUID(), sessionId: ctx.sessionManager.getSessionId(), transcriptPath,
      startEntryId: ctx.sessionManager.getLeafId(), ctx, launchAllowed: false };
    interaction = owner;
    try {
      if (retained) { await cleanup(retained); retained = undefined; }
      await review.release();
      const { ParleyFork } = await import("./parley-interaction.ts");
      if (!current(owner)) throw new Error("Parent changed during fork setup");
      owner.fork = ParleyFork.capture(ctx, pi.getThinkingLevel());
      owner.launchAllowed = true;
      pi.sendMessage({ customType: "parley-enter", display: false, details: { interactionId: owner.id },
        content: `The user invoked /parley. Call parley_interact with interactionId ${owner.id} as your only tool call. Do not implement, plan or run other tools in this parent. That tool hosts an independent context-preserving implementation fork, accepts editor instructions, and returns the recap when the user finishes. After it returns, use the recap to continue the parent conversation.` }, { triggerTurn: true });
    } catch (error) {
      if (interaction === owner) interaction = undefined;
      ctx.ui.notify(`Parley startup failed: ${String(error)}. Any fork evidence is retained; nothing replayed.`, "error");
    }
  }

  pi.registerTool({
    name: "parley_interact", label: "Parley editor interaction", exposure: "model-only",
    description: "Only after the user invokes /parley: host that exact implementation interaction until editor Done returns its recap. Do not call alongside other tools. A normal independent Pi child owns implementation; detailed conversation stays in its transcript.",
    parameters: { type: "object", additionalProperties: false, required: ["interactionId"], properties: { interactionId: { type: "string" } } },
    executionMode: "sequential",
    async execute(callId, input, signal, update, ctx: ExtensionToolContext) {
      const owner = interaction;
      if (!owner || owner.hostCallId || !owner.fork || !current(owner) || input === null || typeof input !== "object"
        || Object.keys(input).length !== 1 || !("interactionId" in input) || input.interactionId !== owner.id) {
        throw new Error("No matching /parley interaction; no fork or tools started");
      }
      owner.hostCallId = callId;
      const fork = owner.fork;
      const completed = new Promise<string>((resolve, reject) => { owner.resolve = resolve; owner.reject = reject; });
      // Startup may throw before we await completed. Always observe cancellation.
      completed.catch(() => {});
      const cancel = (): void => { owner.reject?.(new Error("Parley cancelled; edits and transcript retained, no rollback")); };
      signal?.addEventListener("abort", cancel, { once: true });
      try {
        if (signal?.aborted) throw new Error("Parley host was cancelled before startup");
        fork.bind(ctx, signal);
        const root = await workspaceRoot(ctx.cwd);
        const startingCommit = await review.captureCommit(root, signal);
        if (!current(owner) || signal?.aborted) throw new Error("Implementation owner changed during startup");
        const requests = new ReviewRequests(root, owner.sessionId, [], error => {
          owner.failed = error;
          owner.reject?.(error);
        }, fork);
        owner.owner = requests;
        await requests.prepare(brief, { sessionId: owner.sessionId, transcriptPath: owner.transcriptPath, startEntryId: owner.startEntryId,
          model: { provider: fork.model.provider, modelId: fork.model.id, thinkingLevel: fork.thinkingLevel } }, startingCommit,
          () => current(owner) && !signal?.aborted, fork.model);
        if (!current(owner) || signal?.aborted) throw new Error("Implementation owner changed during preparation");
        const bridge = new WorkspaceBridge(root, owner.sessionId);
        owner.bridge = bridge;
        bridge.onReviewRequest = async request => {
          if (owner.stopped || (interaction !== owner && retained !== owner)
            || owner.ctx.sessionManager.getSessionId() !== owner.sessionId
            || owner.ctx.sessionManager.getSessionFile() !== owner.transcriptPath) {
            throw new Error("Parley owner stopped or changed; nothing queued or accepted");
          }
          const result = await requests.handle(request);
          if (request.action === "review-finish-status" && result.state === "completed" && typeof result.summary === "string") {
            // Let the bridge enqueue its response before the parent receives the
            // recap. Keep the completed owner available for saved-summary reads.
            setImmediate(() => owner.resolve?.(result.summary as string));
          }
          return result;
        };
        bridge.onFailure = error => owner.reject?.(error);
        owner.startup = bridge.start();
        await owner.startup;
        if (!current(owner) || signal?.aborted) throw new Error("Implementation owner changed while publishing offer");
        owner.ready = true;
        ctx.ui.setStatus("parley-implementation", "Parley · :Parley start in Neovim");
        ctx.ui.notify("Implementation fork ready. Use :Parley start, :Parley submit, then :Parley done in Neovim. Save source buffers before each turn.", "info");
        update?.({ content: [{ type: "text", text: "Editor interaction active; parent execution paused." }], details: { transcriptPath: fork.manager.getSessionFile() } });
        const summary = await completed;
        if (!current(owner)) throw new Error("Originating parent changed; recap retained without rerouting");
        retained = owner;
        return { content: [{ type: "text", text: summary }], usage: structuredClone(fork.usage),
          details: { interactionId: owner.id, artifactPath: requests.artifactPath, transcriptPath: fork.manager.getSessionFile() } };
      } catch (error) {
        try { await cleanup(owner); } catch (cleanupError) { console.error("Parley implementation cleanup failed", cleanupError); }
        return { content: [{ type: "text", text: `Parley stopped: ${String(error)}. Edits and evidence retained; no rollback. Do not automatically resume the inherited implementation plan.` }],
          isError: true, terminate: owner.stopped || undefined, usage: structuredClone(fork.usage),
          details: { interactionId: owner.id, artifactPath: owner.owner?.artifactPath, transcriptPath: fork.manager.getSessionFile() } };
      } finally {
        signal?.removeEventListener("abort", cancel);
        // An explicit stop retains admission ownership until its own await and
        // notification finish. Never clear a replacement owner's status.
        if (interaction === owner && !owner.stopping) {
          interaction = undefined;
          ctx.ui.setStatus("parley-implementation", undefined);
        }
      }
    },
  });

  async function stop(args: string, ctx: ExtensionCommandContext): Promise<void> {
    if (args.trim() || ctx.mode !== "tui") {
      ctx.ui.notify("Use /parley stop without arguments in the originating Pi session. Nothing queued or cancelled.", "error");
      return;
    }
    const owner = interaction;
    if (!owner) { ctx.ui.notify("No active Parley implementation interaction.", "info"); return; }
    const originating = (): boolean => interaction === owner
      && ctx.sessionManager.getSessionId() === owner.sessionId && ctx.sessionManager.getSessionFile() === owner.transcriptPath;
    if (!originating() || !current(owner) || owner.stopping || !owner.ready || !owner.owner?.reviewId) {
      ctx.ui.notify("/parley stop requires the originating Pi session and a ready interaction, not initialization or an ongoing stop. Nothing queued or cancelled.", "error");
      return;
    }
    let closing: Promise<void>;
    try {
      closing = owner.owner.stopParent(owner.owner.reviewId,
        { sessionId: owner.sessionId, transcriptPath: owner.transcriptPath }, ctx.sessionManager.getLeafId(),
        () => originating() && current(owner));
    } catch (error) {
      ctx.ui.notify(`Parley: ${String(error)}`, "error");
      return;
    }
    owner.stopped = true;
    owner.launchAllowed = false;
    // Observe the exact withdrawal immediately; cleanup also awaits its
    // idempotent close before releasing the bridge, even on persistence failure.
    const stopping = (async () => {
      const results = await Promise.allSettled([closing, cleanup(owner)]);
      const failure = results.find(result => result.status === "rejected");
      if (failure) throw failure.reason;
    })();
    owner.stopping = stopping;
    owner.reject?.(new Error("User cancelled Parley; edits retained, no rollback"));
    try {
      await stopping;
      if (originating()) ctx.ui.notify("Parley stopped without wrap-up. Edits, drafts and transcripts retained; no rollback. Use /parley to start fresh.", "info");
    } catch (error) {
      if (originating()) ctx.ui.notify(`Parley withdrawn, but cleanup failed: ${String(error)}. Edits and evidence retained; no replay.`, "error");
    } finally {
      try {
        if (originating()) ctx.ui.setStatus("parley-implementation", undefined);
      } catch (error) {
        console.error("Parley stop status cleanup failed", error);
      }
      if (interaction === owner) interaction = undefined;
    }
  }

  return { active: () => !!interaction, close, start, stop };
}
