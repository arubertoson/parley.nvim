import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { WorkspaceBridge, workspaceRoot } from "./bridge.ts";

// Only /review publishes an offer. Neovim's ReviewStart owns pairing/activation.
export default function parley(pi: ExtensionAPI): void {
  let bridge: WorkspaceBridge | undefined;
  let context: ExtensionContext | undefined;
  let generation = 0;
  let failed = false;
  let startup: Promise<void> | undefined;

  // Session changes/reloads withdraw the old offer; they never republish it.
  async function withdraw(ctx: ExtensionContext): Promise<void> {
    const token = ++generation;
    const previous = bridge;
    bridge = undefined;
    context = ctx;
    // An interrupted /review cleans up its own not-yet-published owner. Both
    // lifetimes must finish even if one fails; preserve the first failure.
    const results = await Promise.allSettled([startup, previous?.stop()]);
    const rejected = results.find(result => result.status === "rejected");
    try {
      if (generation === token && context === ctx && ctx.mode === "tui") {
        ctx.ui.setStatus("parley-bridge", undefined);
      }
    } catch (error) {
      if (!rejected) {
        throw error;
      }
      console.error("Parley status cleanup failed", error);
    }
    if (rejected) {
      throw rejected.reason;
    }
  }

  pi.on("session_start", (_event, ctx) => withdraw(ctx));
  pi.on("session_shutdown", async (_event, ctx) => {
    try {
      await withdraw(ctx);
    } finally {
      if (context === ctx) {
        context = undefined;
      }
    }
  });

  pi.registerCommand("review", {
    description: "Offer this Pi session for review; use :ReviewStart in Neovim to pair and activate",
    handler: async (args, ctx) => {
      if (ctx.mode !== "tui") {
        ctx.ui.notify("Parley requires the existing interactive Pi process", "error");
        return;
      }
      if (args.trim()) {
        ctx.ui.notify("Use /review without arguments, then :ReviewStart in Neovim.", "error");
        return;
      }
      if (startup || !ctx.isIdle() || ctx.hasPendingMessages()) {
        ctx.ui.notify("Pi is busy; no review offer started.", "error");
        return;
      }
      const sessionId = ctx.sessionManager.getSessionId();
      if (bridge && !failed && bridge.sessionId === sessionId) {
        ctx.ui.notify("This Pi session is already available; use :ReviewStart in Neovim.", "info");
        return;
      }
      const sessionGeneration = generation;
      const previous = bridge;
      bridge = undefined;
      const current = (): boolean => generation === sessionGeneration
        && context === ctx
        && ctx.sessionManager.getSessionId() === sessionId;
      // Command contexts may be distinct objects from the lifecycle context.
      context = ctx;
      const operation = (async () => {
        await previous?.stop();
        const root = await workspaceRoot(ctx.cwd);
        if (!current()) {
          return;
        }
        const owner = new WorkspaceBridge(root, sessionId);
        owner.onPeersChanged = () => {
          if (bridge === owner && !failed && current()) {
            const attached = owner.editorChoices().length > 0;
            ctx.ui.setStatus("parley-bridge", attached
              ? "Parley review · editor paired"
              : "Parley review available · :ReviewStart in Neovim");
          }
        };
        owner.onFailure = error => {
          if (bridge !== owner || !current()) {
            return;
          }
          failed = true;
          ctx.ui.setStatus("parley-bridge", "Parley unavailable · /review");
          ctx.ui.notify(`Parley bridge: ${error.message}`, "error");
        };
        try {
          await owner.start();
          if (!current()) {
            await owner.stop();
            return;
          }
          bridge = owner;
          failed = false;
          owner.onPeersChanged();
        } catch (error) {
          if (bridge === owner) {
            bridge = undefined;
          }
          try {
            await owner.stop();
          } catch (cleanupError) {
            console.error("Parley offer cleanup failed", cleanupError);
          }
          throw error;
        }
      })();
      startup = operation;
      try {
        await operation;
        if (current() && bridge) {
          ctx.ui.notify("Review available. Use :ReviewStart in Neovim. No model or capture started.", "info");
        }
      } catch (error) {
        if (current()) {
          ctx.ui.setStatus("parley-bridge", undefined);
          ctx.ui.notify(`Parley: ${String(error)}. No review offer started.`, "error");
        }
      } finally {
        if (startup === operation) {
          startup = undefined;
        }
      }
    },
  });
}
