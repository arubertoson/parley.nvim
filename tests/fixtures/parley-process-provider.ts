// Scripted responses for the real CLI process test. Pi discovers this fixture
// normally from its temporary agent directory; there is no network provider.
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

export default function (pi: ExtensionAPI): void {
  pi.on("session_start", (_event, ctx) => {
    pi.appendEntry("process-fixture", { pid: process.pid, sessionId: ctx.sessionManager.getSessionId() });
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    await fs.writeFile(path.join(ctx.cwd, "child-stopped"), "yes\n");
  });
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "codemode" && ctx.sessionManager.getBranch().some(entry => JSON.stringify(entry).includes("Parley implementation turn"))) {
      if (!await ctx.ui.confirm("Offline child permission", "Allow the localized native edit?")) return { block: true, reason: "Not approved" };
    }
  });
  pi.registerProvider("parley-process-offline", {
    baseUrl: "http://127.0.0.1:1", api: "parley-process-offline", apiKey: "offline",
    models: [{ id: "offline", name: "Offline", reasoning: true, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100_000, maxTokens: 1024 }],
    streamSimple: (model, context, options) => {
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const base = { role: "assistant" as const, api: model.api, provider: model.provider, model: model.id, usage, timestamp: Date.now() };
        try {
          assert.equal(options?.reasoning, "high");
          assert(JSON.stringify(context).includes("Inherited decision from parent"));
          assert(JSON.stringify(context).includes("Process fixture skill"), "Normal startup must discover skills");
          const last = context.messages.at(-1);
          let content: AssistantMessage["content"];
          let stopReason: "stop" | "toolUse";
          const lastText = JSON.stringify(last);
          const implementation = [...context.messages].reverse().find(message => message.role === "user" && JSON.stringify(message.content).includes("Parley implementation turn"));
          const implementationText = implementation?.role === "user" ? implementation.content : undefined;
          const turnText = typeof implementationText === "string" ? implementationText : Array.isArray(implementationText)
            ? implementationText.filter(block => block.type === "text").map(block => block.text).join("") : "";
          const turn = turnText ? JSON.parse(turnText.slice(turnText.indexOf("\n") + 1)) : undefined;
          const tip = turn?.request.submissions[0];
          if (lastText.includes("Call parley_interact with interactionId")) {
            const id = lastText.match(/interactionId ([a-f0-9-]+)/)?.[1];
            assert(id);
            content = [{ type: "toolCall", id: "host", name: "parley_interact", arguments: { interactionId: id } }];
            stopReason = "toolUse";
          } else if (last?.role === "toolResult" && last.toolName === "parley_interact") {
            assert(lastText.includes(last.isError ? "no rollback" : "native read/write verified"));
            content = [{ type: "text", text: last.isError ? "Originating parent received cancellation; no rollback." : "Originating parent received the durable recap." }];
            stopReason = "stop";
          } else if (last?.role === "user" && lastText.includes("Finish Parley")) {
            const declared = new Set<string>();
            for (const message of context.messages) {
              if (message.role !== "system") continue;
              for (const tool of message.toolsRemoved ?? []) declared.delete(tool.name);
              for (const tool of message.toolsAdded ?? []) declared.add(tool.name);
            }
            assert.deepEqual([...declared], [], "Recap declares no tools");
            assert(JSON.stringify(context).includes("Implemented the requested change"));
            content = [{ type: "text", text: "Recap: source.txt changed; native read/write verified. Cancellation retained; no rollback. λ\u2028✓" }];
            stopReason = "stop";
          } else if (last?.role === "user" && turn?.conversations[0].messages.at(-1).lines.includes("Wait for cancellation")) {
            fs.writeFile(path.join(process.cwd(), "waiting"), "yes\n").catch(() => stream.end());
            options?.signal?.addEventListener("abort", () => {
              stream.push({ type: "error", reason: "aborted", error: { ...base, content: [], stopReason: "aborted", errorMessage: "Cancelled offline wait" } });
              stream.end();
            }, { once: true });
            return;
          } else if (tip && last?.role === "toolResult" && last.toolName === "codemode") {
            assert(!last.isError, JSON.stringify(last));
            content = [{ type: "toolCall", id: `reply-${tip.tipId}`, name: "parley_reply", arguments: {
              conversationId: tip.conversationId, parentId: tip.tipId, version: tip.version, lines: ["Implemented the requested change."],
            } }];
            stopReason = "toolUse";
          } else if (tip && last?.role === "toolResult" && last.toolName === "parley_reply" && !last.isError) {
            content = [{ type: "toolCall", id: `stale-${tip.tipId}`, name: "parley_reply", arguments: {
              conversationId: tip.conversationId, parentId: tip.tipId, version: tip.version, lines: ["Stale reply must fail"],
            } }];
            stopReason = "toolUse";
          } else if (tip && last?.role === "toolResult" && last.toolName === "parley_reply") {
            assert(last.isError && lastText.includes("exact submitted history"));
            content = [{ type: "text", text: "Implemented the requested change using native codemode; stale reply rejected." }];
            stopReason = "stop";
          } else if (tip) {
            content = [{ type: "toolCall", id: `edit-${tip.tipId}`, name: "codemode", arguments: {
              code: "text(await tools.read({path:'source.txt'})); text(await tools.write({path:'source.txt',content:'changed source\\n'}));",
            } }];
            stopReason = "toolUse";
          } else
          if (last?.role === "toolResult") {
            assert.equal(last.toolName, "codemode");
            assert(!last.isError, JSON.stringify(last));
            assert(JSON.stringify(last).includes("original source"));
            content = [{ type: "text", text: "Changed source.txt using native codemode." }];
            stopReason = "stop";
          } else if (last?.role === "user" && JSON.stringify(last.content).includes("Recap only")) {
            assert(JSON.stringify(context).includes("Changed source.txt using native codemode."));
            content = [{ type: "text", text: "Recap: source.txt changed; native read/write verified. λ\u2028✓" }];
            stopReason = "stop";
          } else {
            // Only the normal CLI registers codemode; this fixture does not
            // supply a replacement or any source-editing tools.
            content = [{ type: "toolCall", id: "native-edit", name: "codemode", arguments: {
              code: "text(await tools.read({path:'source.txt'})); text(await tools.write({path:'source.txt',content:'changed source\\n'}));",
            } }];
            stopReason = "toolUse";
          }
          const message = { ...base, content, stopReason };
          stream.push({ type: "start", partial: message });
          stream.push({ type: "done", reason: stopReason, message });
          stream.end();
        } catch (error) {
          stream.push({ type: "error", reason: "error", error: { ...base, content: [], stopReason: "error", errorMessage: error instanceof Error ? error.stack : String(error) } });
          stream.end();
        }
      });
      return stream;
    },
  });
}
