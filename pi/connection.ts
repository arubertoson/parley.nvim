// The interactive Pi runtime owns this socket and its workspace lease, not the review contents.
import net from "node:net";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { ReviewStore, atomicJson, workspaceKey, validateRequest } from "./state.ts";

export class Connection {
  readonly store: ReviewStore;
  private server?: net.Server;
  private sockets = new Set<net.Socket>();
  private tail: Promise<unknown> = Promise.resolve();
  private runtime?: string;
  private lease: string;
  private instanceId = randomUUID();
  private ownsLease = false;
  private stopping = false;
  private closing?: Promise<void>;
  onFailure: (error: Error) => Promise<void> = async () => {};
  onSubmit: () => void = () => {};
  readonly directory: string;
  readonly root: string;
  constructor(directory: string, root: string) {
    this.directory = directory; this.root = root;
    this.store = new ReviewStore(directory, root);
    this.lease = path.join(directory, "endpoints", workspaceKey(root) + ".json");
  }
  serial<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.tail.then(operation);
    this.tail = result.catch(() => {}); // Each caller receives its failure; the queue remains usable.
    return result;
  }
  async start() {
    await fs.mkdir(path.dirname(this.lease), { recursive: true, mode: 0o700 });
    // All lease contenders use the same exclusive acquisition guard. A crash
    // during acquisition fails closed instead of risking removal of a new owner.
    const guardPath = this.lease + ".acquiring";
    let guard;
    try { guard = await fs.open(guardPath, "wx", 0o600); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new Error(`Workspace acquisition in progress or interrupted; inspect ${guardPath}`);
      throw error;
    }
    try {
      await guard.writeFile(String(process.pid));
    // Reserve the workspace before recovery or record mutations. Never steal a live lease.
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const handle = await fs.open(this.lease, "wx", 0o600);
        try { await handle.writeFile(JSON.stringify({ version: 1, workspace: this.root, pid: process.pid, instanceId: this.instanceId })); }
        finally { await handle.close(); }
        this.ownsLease = true; break;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        const owner = JSON.parse(await fs.readFile(this.lease, "utf8"));
        if (!Number.isSafeInteger(owner.pid)) throw new Error("Incomplete Parley workspace lease; inspect it before recovery");
        try { process.kill(owner.pid, 0); throw new Error("This workspace already has a live Parley Pi owner"); }
        catch (alive) { if ((alive as NodeJS.ErrnoException).code !== "ESRCH") throw alive; }
        // Dead process cannot update its descriptor; deletion is only for this proven-dead lease.
        await fs.unlink(this.lease);
      }
    }
      if (!this.ownsLease) throw new Error("Could not acquire Parley workspace");
    } finally { await guard.close(); await fs.unlink(guardPath); }
    try {
      await this.store.recover();
      this.runtime = await fs.mkdtemp(path.join(os.tmpdir(), "parley-"));
      await fs.chmod(this.runtime, 0o700);
      const socket = path.join(this.runtime, "pi.sock");
      this.server = net.createServer(client => this.accept(client));
      await new Promise<void>((resolve, reject) => {
        this.server!.once("error", reject); this.server!.listen(socket, () => { this.server!.off("error", reject); resolve(); });
      });
      this.server.on("error", error => {
        void this.onFailure(error).finally(() => this.stop()).catch(failure => console.error("Parley shutdown failed", failure));
      });
      await fs.chmod(socket, 0o600);
      await atomicJson(this.lease, { version: 1, workspace: this.root, socket, pid: process.pid, instanceId: this.instanceId });
    } catch (error) { await this.stop(); throw error; }
  }
  private accept(client: net.Socket) {
    this.sockets.add(client); client.setEncoding("utf8");
    client.setTimeout(30_000, () => client.destroy());
    client.on("error", () => client.destroy()); client.on("close", () => this.sockets.delete(client));
    let buffer = "", pending = 0;
    const reply = (data: unknown) => { if (!client.destroyed) client.write(JSON.stringify(data) + "\n"); };
    client.on("data", (chunk: string) => {
      buffer += chunk;
      if (Buffer.byteLength(buffer) > 64 * 1024 * 1024) { client.destroy(); return; }
      for (;;) {
        const end = buffer.indexOf("\n"); if (end < 0) break;
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        if (++pending > 16) { client.destroy(); return; }
        let requestId = "invalid";
        void this.serial(async () => {
          try {
            if (this.stopping) throw new Error("Pi is shutting down");
            const request: unknown = JSON.parse(line);
            if (request && typeof request === "object" && typeof (request as {requestId?: unknown}).requestId === "string") requestId = (request as {requestId: string}).requestId;
            validateRequest(request);
            const result = await this.store.handle(request);
            reply({ version: 1, requestId, ok: true, result });
            if (request.action === "submit") this.onSubmit();
          } catch (error) { reply({ version: 1, requestId, ok: false, error: error instanceof Error ? error.message : String(error) }); }
          finally { pending--; }
        });
      }
    });
  }
  stop(): Promise<void> {
    if (!this.closing) { this.stopping = true; this.closing = this.shutdown(); }
    return this.closing;
  }
  private async shutdown() {
    for (const client of this.sockets) client.destroy();
    if (this.server?.listening) await new Promise<void>(resolve => this.server!.close(() => resolve()));
    await this.tail;
    if (this.ownsLease) {
      const descriptor = JSON.parse(await fs.readFile(this.lease, "utf8"));
      if (descriptor.instanceId === this.instanceId) await fs.unlink(this.lease);
      this.ownsLease = false;
    }
    if (this.runtime) await fs.rm(this.runtime, { recursive: true, force: true });
  }
}
