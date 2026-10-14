import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { WorkspaceBridge, workspaceRoot } from "./bridge.ts";

// Registration is inert. The session owns a passive bridge; /review owns activation.
export default function parley(pi: ExtensionAPI): void {
  let bridge: WorkspaceBridge | undefined;
  let context: ExtensionContext | undefined;
  let generation = 0;
  let activating = false;
  let startup: Promise<void> | undefined;

  pi.on("session_start", async (_event, ctx) => {
    if (ctx.mode !== "tui") {
      return;
    }
    const sessionGeneration = ++generation;
    context = ctx;
    const previous = bridge;
    const previousStartup = startup;
    bridge = undefined;
    startup = (async () => {
      // The previous session handler reports its own startup failure.
      await previousStartup?.catch(() => {});
      await previous?.stop();
      const root = await workspaceRoot(ctx.cwd);
      if (generation !== sessionGeneration) {
        return;
      }
      const owner = new WorkspaceBridge(root, ctx.sessionManager.getSessionId());
      let failed = false;
      owner.onPeersChanged = () => {
        if (bridge === owner && !failed && context?.mode === "tui") {
          context.ui.setStatus("parley-bridge", `Parley bridge · ${owner.editorChoices().length} editor(s)`);
        }
      };
      owner.onFailure = error => {
        if (bridge !== owner) {
          return;
        }
        failed = true;
        ctx.ui.setStatus("parley-bridge", "Parley bridge unavailable · /reload");
        ctx.ui.notify(`Parley bridge: ${error.message}`, "error");
      };
      try {
        await owner.start();
        if (generation !== sessionGeneration) {
          await owner.stop();
          return;
        }
        bridge = owner;
        owner.onPeersChanged();
      } catch (error) {
        await owner.stop();
        throw error;
      }
    })();
    try {
      await startup;
    } catch (error) {
      if (generation !== sessionGeneration) {
        return;
      }
      ctx.ui.setStatus("parley-bridge", "Parley bridge unavailable · /reload in a workspace");
      ctx.ui.notify(`Parley bridge: ${String(error)}. No review activated.`, "error");
    }
  });

  pi.on("session_shutdown", async () => {
    ++generation;
    const owner = bridge;
    bridge = undefined;
    if (context?.mode === "tui") {
      context.ui.setStatus("parley-bridge", undefined);
    }
    context = undefined;
    // The startup handler reports its own failure.
    await startup?.catch(() => {});
    await owner?.stop();
  });

  pi.registerCommand("review", {
    description: "Enable workspace review mode in the matching connected Neovim; no capture or model work",
    handler: async (args, ctx) => {
      if (ctx.mode !== "tui") {
        ctx.ui.notify("Parley requires the existing interactive Pi process", "error");
        return;
      }
      if (args.trim()) {
        ctx.ui.notify("Use /review without arguments. This command only activates workspace review mode.", "error");
        return;
      }
      if (activating || !ctx.isIdle() || ctx.hasPendingMessages()) {
        ctx.ui.notify("Pi is busy; no review activated.", "error");
        return;
      }
      const owner = bridge;
      const sessionGeneration = generation;
      const sessionId = ctx.sessionManager.getSessionId();
      if (!owner || owner.sessionId !== sessionId) {
        ctx.ui.notify("No matching workspace bridge; /reload in this workspace.", "error");
        return;
      }
      // Recheck ownership and availability after dialogs and transport awaits.
      const canActivate = (): boolean => {
        return generation === sessionGeneration
          && bridge === owner
          && ctx.sessionManager.getSessionId() === sessionId
          && ctx.isIdle()
          && !ctx.hasPendingMessages();
      };
      activating = true;
      try {
        const editors = owner.editorChoices();
        if (editors.length === 0) {
          throw new Error("No matching connected Neovim; check :checkhealth parley");
        }
        let editor = editors.length === 1 ? editors[0] : undefined;
        if (!editor) {
          const labels = editors.map(peer => `${peer.label} · ${peer.editorId}`);
          const selected = await ctx.ui.select("Activate review in which Neovim?", labels);
          if (selected === undefined || !canActivate()) {
            return;
          }
          editor = editors[labels.indexOf(selected)];
          if (!editor) {
            throw new Error("Unknown editor selection");
          }
        }
        if (!canActivate()) {
          return;
        }
        await owner.activateEditor(editor.editorId);
        if (canActivate()) {
          ctx.ui.notify(`Workspace review active in ${editor.label}. No capture or model work started.`, "info");
        }
      } catch (error) {
        if (generation === sessionGeneration) {
          ctx.ui.notify(`Parley: ${error instanceof Error ? error.message : String(error)}`, "error");
        }
      } finally {
        activating = false;
      }
    },
  });
}
