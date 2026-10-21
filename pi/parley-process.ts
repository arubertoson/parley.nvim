// Normal Pi owns the child tools, resources and transcript. This is only its
// process/RPC lifetime; editor requests and artifact publication stay elsewhere.
import { spawn } from "node:child_process";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import net from "node:net";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { Usage } from "@earendil-works/pi-ai";

type ChildOptions = {
  readonly cwd: string;
  readonly transcriptPath: string; // Already branched; never the live parent file.
  readonly parentSessionId: string;
  readonly model: { readonly provider: string; readonly id: string };
  readonly thinkingLevel: string;
  readonly env?: NodeJS.ProcessEnv;
  readonly publish?: (input: unknown) => Promise<string>;
  readonly ui?: (request: Readonly<Record<string, unknown>>) => Promise<Record<string, unknown> | undefined>;
};

type Pending = { resolve(value: Record<string, unknown>): void; reject(error: Error): void };

function object(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

export class ParleyProcess {
  private serial = 0;
  private readonly pending = new Map<string, Pending>();
  private failure?: Error;
  private turn?: Pending;
  private closing?: Promise<void>;
  private readonly exited: Promise<void>;
  private stderr = "";
  private text = "";
  private stopReason?: string;
  private modelError?: string;
  private id = "";
  private publication?: net.Socket;
  private server?: net.Server;
  private runtimeDirectory?: string;
  readonly usage: Usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

  get sessionId(): string { return this.id; }

  private constructor(private readonly child: ChildProcessWithoutNullStreams, readonly parentSessionId: string,
    private readonly options: ChildOptions) {
    let input = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      input += chunk;
      let end: number;
      while ((end = input.indexOf("\n")) !== -1) {
        const line = input.slice(0, end);
        input = input.slice(end + 1);
        if (!line.trim()) continue;
        try { this.receive(JSON.parse(line)); }
        catch (error) { this.fail(error instanceof Error ? error : new Error(String(error))); }
      }
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => { this.stderr = (this.stderr + chunk).slice(-8192); });
    child.on("error", error => this.fail(error));
    child.stdin.on("error", error => this.fail(error));
    this.exited = new Promise(resolve => {
      child.once("close", (code, signal) => {
        this.fail(new Error(`Parley child exited (${signal ?? code}). ${this.stderr}`));
        resolve();
      });
    });
  }

  private connectPublication(publication: net.Socket): void {
    if (this.publication || this.closing || this.failure) { publication.destroy(); return; }
    this.publication = publication;
    publication.setEncoding("utf8");
    let input = "";
    publication.on("data", (chunk: string) => {
      input += chunk;
      if (Buffer.byteLength(input) > 128 * 1024) { this.fail(new Error("Oversized child publication")); return; }
      let end: number;
      while ((end = input.indexOf("\n")) !== -1) {
        const line = input.slice(0, end);
        input = input.slice(end + 1);
        try {
          const record = object(JSON.parse(line));
          if (!record || typeof record.id !== "string" || Object.keys(record).length !== 2 || !Object.hasOwn(record, "value")) throw new Error("Invalid child publication");
          const id = record.id;
          const publish = this.options.publish;
          if (!publish || !this.turn) throw new Error("No current editor publication authority");
          publish(record.value).then(
            text => publication.write(JSON.stringify({ id, text }) + "\n"),
            error => publication.write(JSON.stringify({ id, error: String(error) }) + "\n"),
          ).catch(error => this.fail(error instanceof Error ? error : new Error(String(error))));
        } catch (error) { this.fail(error instanceof Error ? error : new Error(String(error))); }
      }
    });
    publication.on("error", error => this.fail(error));
    publication.on("close", () => { if (!this.closing) this.fail(new Error("Child publication channel closed; nothing replayed")); });
  }

  static async start(options: ChildOptions): Promise<ParleyProcess> {
    const args = ["--mode", "rpc", "--session", options.transcriptPath,
      "--provider", options.model.provider, "--model", options.model.id, "--thinking", options.thinkingLevel];
    let server: net.Server | undefined;
    let directory: string | undefined;
    let publication: net.Socket | undefined;
    let owner: ParleyProcess | undefined;
    if (options.publish) {
      const runtimeDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-child-"));
      directory = runtimeDirectory;
      const listener = net.createServer(socket => {
        if (publication) { socket.destroy(); return; }
        publication = socket;
        owner?.connectPublication(socket);
      });
      server = listener;
      try {
        await new Promise<void>((resolve, reject) => {
          listener.once("error", reject);
          listener.listen(path.join(runtimeDirectory, "reply.sock"), () => { listener.removeListener("error", reject); resolve(); });
        });
      } catch (error) {
        listener.close();
        try { await fs.rm(runtimeDirectory, { recursive: true, force: true }); } catch (cleanupError) { console.error("Parley socket cleanup failed", cleanupError); }
        throw error;
      }
      args.push("--extension", fileURLToPath(new URL("./parley-child.ts", import.meta.url)));
    }
    const child = new ParleyProcess(spawn("pi", args, {
      cwd: options.cwd, env: { ...(options.env ?? process.env),
        ...(directory ? { PARLEY_PUBLICATION_SOCKET: path.join(directory, "reply.sock") } : {}) }, stdio: ["pipe", "pipe", "pipe"],
    }), options.parentSessionId, options);
    owner = child;
    child.server = server;
    child.runtimeDirectory = directory;
    if (publication) child.connectPublication(publication);
    server?.on("error", error => child.fail(error));
    try {
      const state = await child.command("get_state");
      const model = object(state.model);
      if (typeof state.sessionId !== "string" || state.sessionFile !== options.transcriptPath
        || model?.provider !== options.model.provider || model.id !== options.model.id || state.thinkingLevel !== options.thinkingLevel) {
        throw new Error("Pi child did not open the requested transcript/model/thinking level");
      }
      child.id = state.sessionId;
      if (child.sessionId === options.parentSessionId) throw new Error("Parley child must not use the live parent session");
      if (options.publish) {
        const result = await child.command("get_commands");
        if (!child.publication || !Array.isArray(result.commands)
          || !result.commands.some(command => object(command)?.name === "parley-child-recap-lock")) throw new Error("Child publication extension did not start");
      }
      await child.command("set_auto_retry", { enabled: false });
      return child;
    } catch (error) {
      try { await child.close(); } catch (cleanupError) { console.error("Parley child startup cleanup failed", cleanupError); }
      throw error;
    }
  }

  private fail(error: Error): void {
    this.failure ??= error;
    for (const pending of this.pending.values()) pending.reject(this.failure);
    this.pending.clear();
    this.turn?.reject(this.failure);
    // A broken channel cannot leave unobserved implementation running while
    // the parent records a failed turn. Normal cancellation uses RPC abort.
    if (!this.closing) this.child.kill("SIGTERM");
  }

  private receive(value: unknown): void {
    const record = object(value);
    if (!record) throw new Error("Invalid Pi RPC record");
    if (record.type === "response") {
      if (typeof record.id !== "string") return;
      const pending = this.pending.get(record.id);
      if (!pending) return;
      this.pending.delete(record.id);
      if (record.success === true) pending.resolve(object(record.data) ?? {});
      else pending.reject(new Error(typeof record.error === "string" ? record.error : "Pi RPC command failed"));
    } else if (record.type === "extension_ui_request") {
      // RPC data is unknown: the host validates dialog fields before using them.
      if (typeof record.id !== "string" || typeof record.method !== "string") throw new Error("Invalid child UI request");
      this.respondUI(record).catch(error => this.fail(error instanceof Error ? error : new Error(String(error))));
    } else if (record.type === "message_end" && this.turn) {
      const message = object(record.message);
      if (message?.role !== "assistant") return;
      const usage = object(message.usage);
      const cost = object(usage?.cost);
      for (const key of ["input", "output", "cacheRead", "cacheWrite", "totalTokens"] as const) {
        const value = usage?.[key];
        if (typeof value !== "number" || !Number.isFinite(value) || value < 0) throw new Error("Invalid child usage");
        this.usage[key] += value;
      }
      for (const key of ["input", "output", "cacheRead", "cacheWrite", "total"] as const) {
        const value = cost?.[key];
        if (typeof value !== "number" || !Number.isFinite(value) || value < 0) throw new Error("Invalid child cost");
        this.usage.cost[key] += value;
      }
      this.stopReason = typeof message.stopReason === "string" ? message.stopReason : undefined;
      this.modelError = typeof message.errorMessage === "string" ? message.errorMessage : undefined;
      this.text = Array.isArray(message.content) ? message.content.map(block => {
        const content = object(block);
        return content?.type === "text" && typeof content.text === "string" ? content.text : "";
      }).join("") : "";
    } else if (record.type === "agent_settled" && this.turn) {
      if (record.aborted || this.stopReason !== "stop") this.turn.reject(new Error(this.modelError ?? `Parley turn stopped: ${this.stopReason ?? "no assistant response"}`));
      else this.turn.resolve({ text: this.text });
    }
  }

  private async respondUI(record: Record<string, unknown>): Promise<void> {
    // ExtensionUIRequest is not asserted here: individual fields remain unknown
    // until the owning host validates them.
    const response = await this.options.ui?.(record);
    if (["select", "confirm", "input", "editor"].includes(String(record.method)) && !this.closing && !this.failure) {
      await new Promise<void>((resolve, reject) => {
        this.child.stdin.write(JSON.stringify({ ...response, type: "extension_ui_response", id: record.id,
          ...(response ? {} : { cancelled: true }) }) + "\n", error => error ? reject(error) : resolve());
      });
    }
  }

  async lockRecap(): Promise<void> {
    if (this.turn) throw new Error("Implementation work is still active");
    const result = await this.command("prompt", { message: "/parley-child-recap-lock" });
    if (result.disposition !== "handled") throw new Error("Child did not withdraw implementation tools");
  }

  private async command(type: string, payload: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    if (this.failure) throw this.failure;
    if (this.closing) throw new Error("Parley child is closing");
    const id = `parley-${++this.serial}`;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await new Promise<Record<string, unknown>>((resolve, reject) => {
        this.pending.set(id, { resolve, reject });
        timer = setTimeout(() => this.fail(new Error(`Pi did not acknowledge ${type}; nothing replayed`)), 30_000);
        this.child.stdin.write(JSON.stringify({ ...payload, id, type }) + "\n", error => { if (error) this.fail(error); });
      });
    } finally {
      clearTimeout(timer);
      this.pending.delete(id);
    }
  }

  async prompt(message: string): Promise<string> {
    if (this.turn) throw new Error("Parley child is busy; nothing queued");
    this.text = "";
    this.stopReason = undefined;
    this.modelError = undefined;
    const settled = new Promise<Record<string, unknown>>((resolve, reject) => { this.turn = { resolve, reject }; });
    settled.catch(() => {});
    try {
      const result = await this.command("prompt", { message });
      if (result.disposition !== "started") {
        const error = new Error(`Parley prompt was ${result.disposition}; no turn queued or replayed`);
        this.fail(error);
        throw error;
      }
      return String((await settled).text);
    } finally { this.turn = undefined; }
  }

  async abort(): Promise<void> {
    await this.command("clear_queue");
    await this.command("abort");
  }

  close(): Promise<void> {
    this.closing ??= (async () => {
      this.child.stdin.end();
      const timer = setTimeout(() => this.child.kill("SIGKILL"), 2000);
      try { await this.exited; } finally {
        clearTimeout(timer);
        this.publication?.destroy();
        const server = this.server;
        const results = await Promise.allSettled([
          server?.listening ? new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())) : undefined,
          this.runtimeDirectory ? fs.rm(this.runtimeDirectory, { recursive: true, force: true }) : undefined,
        ]);
        const failure = results.find(result => result.status === "rejected");
        if (failure) throw failure.reason;
      }
    })();
    return this.closing;
  }
}
