// The interactive Pi process owns this workspace lease and mechanical socket.
// No review records, models, session switching or retained-work recovery live here.
import net from "node:net";
import { promises as fs } from "node:fs";
import type { FileHandle } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";

const actions = { attach: "bridge-attach", ping: "bridge-ping", activate: "workspace-activate" } as const;
export type EditorPeer = { editorId: string; sessionId: string; label: string };
type ResultIdentity = Record<string, unknown> & {
  version: 1; nonce: string; editorId: string; instanceId: string; sessionId: string; workspace: string;
};
type Response = Record<string, unknown> & { version: 1; requestId: string; ok: boolean };
type PendingRequest = {
  socket: net.Socket;
  peer: EditorPeer;
  timer: ReturnType<typeof setTimeout>;
  resolve: (result: ResultIdentity) => void;
  reject: (error: Error) => void;
};

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : undefined;
}
function identifier(value: unknown): value is string {
  return typeof value === "string" && /^[a-zA-Z0-9_-]{1,128}$/.test(value);
}
function stateDirectory(): string {
  return process.env.PARLEY_STATE_DIR || path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), ".local/state"), "parley");
}
// Match Neovim's filesystem-only discovery; this does not run Git/jj or capture text.
export async function workspaceRoot(cwd: string): Promise<string> {
  let dir = await fs.realpath(cwd);
  for (;;) {
    for (const marker of [".jj", ".git"]) {
      try { await fs.lstat(path.join(dir, marker)); return dir; }
      catch (error) { if (record(error)?.code !== "ENOENT") throw error; }
    }
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error("Not in a jj or Git workspace");
    dir = parent;
  }
}
async function advertise(filename: string, data: unknown): Promise<void> {
  const temp = filename + "." + randomUUID() + ".tmp";
  try {
    await fs.writeFile(temp, JSON.stringify(data), { flag: "wx", mode: 0o600 });
    await fs.rename(temp, filename);
  } finally {
    await fs.rm(temp, { force: true });
  }
}

export class WorkspaceBridge {
  private server?: net.Server;
  private sockets = new Set<net.Socket>();
  private peers = new Map<net.Socket, EditorPeer>();
  private pending = new Map<string, PendingRequest>();
  private instanceId = randomUUID();
  private lease: string;
  private runtime?: string;
  private ownsLease = false;
  private stopping = false;
  private closing?: Promise<void>;
  onPeersChanged: () => void = () => {};
  onFailure: (error: Error) => void = () => {};

  constructor(readonly root: string, readonly sessionId: string) {
    this.lease = path.join(stateDirectory(), "endpoints", createHash("sha256").update(root).digest("hex") + ".json");
  }
  private identity() {
    return { version: 1, workspace: this.root, pid: process.pid, instanceId: this.instanceId, sessionId: this.sessionId };
  }
  async start(): Promise<void> {
    await fs.mkdir(path.dirname(this.lease), { recursive: true, mode: 0o700 });
    // Exclusive guard prevents contenders from removing a newly acquired lease.
    const guardPath = this.lease + ".acquiring";
    let guard: FileHandle;
    try { guard = await fs.open(guardPath, "wx", 0o600); }
    catch (error) {
      if (record(error)?.code === "EEXIST") throw new Error(`Workspace acquisition in progress or interrupted; inspect ${guardPath}`);
      throw error;
    }
    try {
      await guard.writeFile(String(process.pid));
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const handle = await fs.open(this.lease, "wx", 0o600);
          this.ownsLease = true;
          try { await handle.writeFile(JSON.stringify(this.identity())); }
          finally { await handle.close(); }
          break;
        } catch (error) {
          if (record(error)?.code !== "EEXIST") throw error;
          const owner = record(JSON.parse(await fs.readFile(this.lease, "utf8")) as unknown);
          const pid = owner?.pid;
          if (typeof pid !== "number" || !Number.isSafeInteger(pid) || pid <= 0) {
            throw new Error("Incomplete Parley workspace lease; inspect it before recovery");
          }
          try {
            process.kill(pid, 0);
            throw new Error("This workspace already has a live Parley Pi owner");
          } catch (alive) {
            if (record(alive)?.code !== "ESRCH") throw alive;
          }
          // PID is only a liveness check for lease cleanup, never attach identity.
          await fs.unlink(this.lease);
        }
      }
      if (!this.ownsLease) throw new Error("Could not acquire Parley workspace");
    } finally {
      await guard.close();
      await fs.unlink(guardPath);
    }
    try {
      this.runtime = await fs.mkdtemp(path.join(os.tmpdir(), "parley-"));
      await fs.chmod(this.runtime, 0o700);
      const socket = path.join(this.runtime, "pi.sock");
      const server = net.createServer(client => this.accept(client));
      this.server = server;
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(socket, () => { server.off("error", reject); resolve(); });
      });
      server.on("error", error => {
        this.onFailure(error);
        void this.stop().catch(failure => console.error("Parley shutdown failed", failure));
      });
      await fs.chmod(socket, 0o600);
      await advertise(this.lease, { ...this.identity(), socket });
    } catch (error) {
      await this.stop();
      throw error;
    }
  }
  editorChoices(): EditorPeer[] {
    return [...this.peers.values()].map(peer => ({ ...peer }));
  }
  // Activation is idempotent editor state, not creation of a frozen review object.
  async activateEditor(editorId: string): Promise<void> {
    const matches = [...this.peers].filter(([, peer]) => peer.editorId === editorId);
    if (this.stopping || matches.length !== 1) throw new Error("Editor is missing or ambiguous; select an exact connected peer");
    const [socket, peer] = matches[0];
    const requestId = randomUUID();
    const result = await new Promise<ResultIdentity>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error(`Editor result timed out for ${requestId}; delivery unknown. Check Neovim review status; no automatic replay.`));
        socket.destroy();
      }, 10_000);
      this.pending.set(requestId, { socket, peer, timer, resolve, reject });
      this.send(socket, {
        version: 1, requestId, action: actions.activate,
        payload: { ...this.identity(), nonce: requestId, editorId },
      });
    });
    if (result.active !== true) {
      socket.destroy();
      throw new Error("Editor activation result is invalid");
    }
  }
  private matchesIdentity(value: unknown, requestId: string, peer: EditorPeer): value is ResultIdentity {
    const result = record(value);
    return result !== undefined && result.version === 1 && result.nonce === requestId
      && result.editorId === peer.editorId && result.instanceId === this.instanceId
      && result.sessionId === this.sessionId && result.workspace === this.root;
  }
  private accept(client: net.Socket): void {
    this.sockets.add(client);
    client.setEncoding("utf8");
    client.setTimeout(30_000, () => client.destroy());
    client.on("error", () => client.destroy());
    client.on("close", () => {
      this.sockets.delete(client);
      for (const [requestId, entry] of this.pending) {
        if (entry.socket !== client) continue;
        clearTimeout(entry.timer);
        this.pending.delete(requestId);
        entry.reject(new Error(`Editor disconnected before result for ${requestId}; delivery unknown. No automatic replay.`));
      }
      if (this.peers.delete(client)) this.onPeersChanged();
    });
    let buffer = "";
    client.on("data", (chunk: string) => {
      buffer += chunk;
      if (Buffer.byteLength(buffer) > 64 * 1024) { client.destroy(); return; }
      for (;;) {
        const end = buffer.indexOf("\n");
        if (end < 0) break;
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        this.handleMessage(client, line);
        if (client.destroyed) return;
      }
    });
  }
  private handleMessage(client: net.Socket, line: string): void {
    let requestId = "invalid";
    try {
      if (this.stopping) throw new Error("Pi is shutting down");
      const message = record(JSON.parse(line) as unknown);
      if (!message || message.version !== 1 || !identifier(message.requestId)) throw new Error("Unsupported bridge envelope");
      requestId = message.requestId;
      if (typeof message.ok === "boolean") {
        this.handleResponse(client, { ...message, version: 1, requestId, ok: message.ok });
        return;
      }
      const result = this.handleRequest(client, message);
      this.send(client, { version: 1, requestId, ok: true, result });
    } catch (error) {
      this.send(client, { version: 1, requestId, ok: false, error: error instanceof Error ? error.message : String(error) });
    }
  }
  private handleResponse(client: net.Socket, message: Response): void {
    const entry = this.pending.get(message.requestId);
    if (!entry || entry.socket !== client || this.peers.get(client) !== entry.peer) { client.destroy(); return; }
    clearTimeout(entry.timer);
    this.pending.delete(message.requestId);
    if (!message.ok) {
      entry.reject(new Error(typeof message.error === "string" ? message.error : "Editor rejected activation"));
    } else if (!this.matchesIdentity(message.result, message.requestId, entry.peer)) {
      entry.reject(new Error("Editor result identity mismatch"));
      client.destroy();
    } else {
      entry.resolve(message.result);
    }
  }
  private handleRequest(client: net.Socket, message: Record<string, unknown>): unknown {
    const payload = record(message.payload);
    const editorId = payload?.editorId;
    if (message.workspace !== this.root || payload?.instanceId !== this.instanceId
      || payload?.sessionId !== this.sessionId || !identifier(editorId)) {
      throw new Error("Bridge identity changed; rediscover and explicitly rebind if the session changed");
    }
    const handlers: Record<string, () => void> = {
      [actions.attach]: () => {
        const label = payload?.label;
        if (typeof label !== "string" || label.length > 512) throw new Error("Invalid editor label");
        if (this.peers.has(client) || [...this.peers].some(([, peer]) => peer.editorId === editorId)) throw new Error("Editor already attached");
        this.peers.set(client, { editorId, sessionId: this.sessionId, label: label.replace(/[\x00-\x1f\x7f]/g, " ") });
        this.onPeersChanged();
      },
      [actions.ping]: () => {
        if (this.peers.get(client)?.editorId !== editorId || !identifier(payload?.nonce)) throw new Error("Attach before pinging this Pi session");
      },
    };
    const handler = typeof message.action === "string" ? handlers[message.action] : undefined;
    if (!handler || !Object.hasOwn(handlers, String(message.action))) throw new Error("Unsupported bridge request");
    handler();
    return { ...this.identity(), editorId, nonce: payload?.nonce };
  }
  private send(client: net.Socket, message: unknown): void {
    if (client.destroyed) return;
    try {
      client.write(JSON.stringify(message) + "\n", error => {
        if (error) client.destroy();
      });
    } catch {
      // Closure settles pending requests as uncertain delivery; never retry a write.
      client.destroy();
    }
  }
  stop(): Promise<void> {
    if (!this.closing) {
      this.stopping = true;
      this.closing = this.shutdown();
    }
    return this.closing;
  }
  private async shutdown(): Promise<void> {
    for (const client of this.sockets) client.destroy();
    const server = this.server;
    if (server?.listening) await new Promise<void>(resolve => server.close(() => resolve()));
    try {
      if (this.ownsLease) {
        const descriptor = record(JSON.parse(await fs.readFile(this.lease, "utf8")) as unknown);
        if (descriptor?.instanceId === this.instanceId) await fs.unlink(this.lease);
        this.ownsLease = false;
      }
    } finally {
      if (this.runtime) await fs.rm(this.runtime, { recursive: true, force: true });
    }
  }
}
