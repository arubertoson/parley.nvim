// Loaded explicitly by ParleyProcess, never as a global extension. A private
// socket connects to the sole artifact writer in the parent. Source
// work still uses the normally started child's native tools and extensions.
import net from "node:net";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  let channel: net.Socket | undefined;
  let recap = false;
  const pending = new Map<string, { resolve(text: string): void; reject(error: Error): void }>();

  function disconnect(error?: unknown): void {
    for (const entry of pending.values()) entry.reject(new Error(`Parley publication channel closed; nothing replayed: ${String(error ?? "disconnected")}`));
    pending.clear();
    channel?.destroy();
  }

  pi.on("session_start", async () => {
    const endpoint = process.env.PARLEY_PUBLICATION_SOCKET;
    if (!endpoint) throw new Error("Missing parent publication endpoint");
    const socket = net.createConnection(endpoint);
    channel = socket;
    socket.setEncoding("utf8");
    let input = "";
    socket.on("data", (chunk: string) => {
      input += chunk;
      if (Buffer.byteLength(input) > 128 * 1024) { disconnect(); return; }
      let end: number;
      while ((end = input.indexOf("\n")) !== -1) {
        const line = input.slice(0, end);
        input = input.slice(end + 1);
        try {
          const value: unknown = JSON.parse(line);
          if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).length !== 2
            || !("id" in value) || typeof value.id !== "string") throw new Error("Invalid publication response");
          const entry = pending.get(value.id);
          if (!entry) continue;
          pending.delete(value.id);
          if ("text" in value && typeof value.text === "string") entry.resolve(value.text);
          else entry.reject(new Error("error" in value && typeof value.error === "string" ? value.error : "Invalid publication response"));
        } catch (error) { disconnect(error); }
      }
    });
    socket.on("error", disconnect);
    socket.on("close", disconnect);
    pi.setActiveTools([...pi.getActiveTools().filter(name => !name.startsWith("review_") && !name.startsWith("parley_")), "parley_reply"]);
    await new Promise<void>((resolve, reject) => {
      socket.once("connect", () => { socket.removeListener("error", reject); resolve(); });
      socket.once("error", reject);
    });
  });
  pi.on("session_shutdown", disconnect);
  pi.on("cache_warming_decision", () => ({ action: "stop" }));
  pi.on("tool_call", event => {
    if (recap || event.toolName.startsWith("review_") || (event.toolName.startsWith("parley_") && event.toolName !== "parley_reply")) {
      return { block: true, reason: "No host control authority in the implementation child, and no tool authority during recap" };
    }
  });
  pi.registerCommand("parley-child-recap-lock", {
    description: "Internal: withdraw implementation tools before the final recap",
    handler: async (_args, ctx) => {
      if (!ctx.isIdle() || pending.size) throw new Error("Implementation work is still active");
      recap = true;
      pi.setActiveTools([]);
    },
  });
  pi.registerTool({
    name: "parley_reply", label: "Reply in editor",
    description: "Publish a reply extending this turn's exact submitted conversation tip/version. Assistant text stays in the child transcript. Never invent IDs.",
    parameters: { type: "object", additionalProperties: false, required: ["conversationId", "parentId", "version", "lines"], properties: {
      conversationId: { type: "string" }, parentId: { type: "string" }, version: { type: "integer", minimum: 1 },
      lines: { type: "array", minItems: 1, items: { type: "string" } },
    } }, executionMode: "sequential",
    async execute(id, value, signal) {
      const socket = channel;
      if (recap || !socket || socket.destroyed || signal?.aborted) throw new Error("No implementation publication authority");
      const frame = JSON.stringify({ id, value }) + "\n";
      if (Buffer.byteLength(frame) > 128 * 1024) throw new Error("Oversized editor reply");
      let cancel: (() => void) | undefined;
      try {
        const text = await new Promise<string>((resolve, reject) => {
          pending.set(id, { resolve, reject });
          cancel = () => { pending.delete(id); reject(new Error("Publication cancelled; delivery may already be durable, nothing replayed")); };
          signal?.addEventListener("abort", cancel, { once: true });
          socket.write(frame, error => { if (error) disconnect(error); });
        });
        return { content: [{ type: "text", text }], details: undefined };
      } finally {
        if (cancel) signal?.removeEventListener("abort", cancel);
        pending.delete(id);
      }
    },
  });
}
