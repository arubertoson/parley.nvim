// The interactive Pi runtime owns this socket and its workspace lease, not the review contents.
import net from "node:net";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { ReviewStore, atomicJson, workspaceKey, validateRequest, type SessionOrigin, type Review } from "./state.ts";

type EditorPeer = { id: string; label: string; eligible: boolean };
type ReadyOffer = { offerId: string; reviewId: string; scope: string; editorId?: string; dismissed?: boolean; opened?: boolean };

export class Connection {
  readonly store: ReviewStore;
  private server?: net.Server;
  private sockets = new Set<net.Socket>();
  private editors = new Map<net.Socket, EditorPeer>();
  // Offers are presentation state, not review state. Reopening never recaptures evidence.
  private offers = new Map<string, ReadyOffer>();
  private tail: Promise<unknown> = Promise.resolve();
  private runtime?: string;
  private lease: string;
  private instanceId = randomUUID();
  private ownsLease = false;
  private stopping = false;
  private closing?: Promise<void>;
  onFailure: (error: Error) => Promise<void> = async () => {};
  onSubmit: (reviewId: string) => void = () => {};
  onFinish: (reviewId: string, collectionId: string, handoffId: string) => void = () => {};
  origin: () => SessionOrigin | undefined = () => undefined;
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
  async start(preserveQueued = false) {
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
      await this.store.recover(preserveQueued);
      for (const item of await this.store.list()) this.offer(await this.store.read(item.id));
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
  // Explicit Pi closure uses the same versioned mutation as Neovim; never deletes evidence.
  closeReview(id: string): Promise<Review> {
    return this.serial(async () => {
      if (this.stopping) throw new Error("Pi is shutting down; retry closing after reconnecting");
      let review = await this.store.read(id);
      if (review.status === "open") review = await this.store.handle({
        version: 1, requestId: randomUUID(), action: "close", reviewId: id,
        payload: { expectedVersion: review.version },
      }) as Review;
      this.offers.delete(id);
      return review;
    });
  }

  offer(review: Review, again = false) {
    const initial = review.turns.findLast(t => t.kind === "initial");
    const ready = review.stages?.length
      ? review.turns.some(t => t.kind === "initial" && t.status === "complete")
      : !initial || initial.status === "complete";
    if (review.status !== "open" || !ready) return;
    if (again || !this.offers.has(review.id)) this.offers.set(review.id, { offerId: randomUUID(), reviewId: review.id, scope: review.scope });
  }
  editorChoices(): EditorPeer[] {
    return [...new Map([...this.editors.values()].filter(e => e.eligible).map(e => [e.id, e])).values()];
  }
  nextOffer(): ReadyOffer | undefined {
    return [...this.offers.values()].find(o => !o.editorId && !o.dismissed);
  }
  assignOffer(offer: ReadyOffer, editorId?: string) {
    if (this.stopping || this.offers.get(offer.reviewId) !== offer) return;
    if (editorId && this.editorChoices().some(e => e.id === editorId)) offer.editorId = editorId;
    else if (!editorId) offer.dismissed = true; // Cancel the presentation, never the review.
  }

  private accept(client: net.Socket) {
    this.sockets.add(client); client.setEncoding("utf8");
    client.setTimeout(30_000, () => client.destroy());
    client.on("error", () => client.destroy()); client.on("close", () => {
      const editor = this.editors.get(client);
      this.sockets.delete(client); this.editors.delete(client);
      if (editor && ![...this.editors.values()].some(e => e.id === editor.id)) {
        for (const offer of this.offers.values()) {
          if (offer.editorId === editor.id && !offer.opened && !offer.dismissed) delete offer.editorId;
        }
      }
    });
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
            let result: unknown;
            if (request.action === "watch") {
              if (request.workspace !== this.root) throw new Error("Editor workspace changed");
              const p = request.payload!;
              const editor = { id: p.editorId!, label: p.editorLabel!.replace(/[\x00-\x1f\x7f]/g, " "), eligible: p.eligible! };
              this.editors.set(client, editor);
              result = [...this.offers.values()].filter(o => o.editorId === editor.id && !o.dismissed);
            } else if (request.action === "open-offer" || request.action === "dismiss-offer") {
              const editor = this.editors.get(client), offer = this.offers.get(request.reviewId!);
              if (!editor || !offer || offer.editorId !== editor.id || offer.offerId !== request.payload!.offerId) throw new Error("Offer is not assigned to this editor; use ReviewStart to reopen manually");
              if (request.action === "dismiss-offer") { offer.dismissed = true; result = {}; }
              else {
                if (!editor.eligible || offer.dismissed) throw new Error("Editor is no longer eligible for this offer");
                result = await this.store.read(offer.reviewId);
                if ((result as Review).status !== "open") throw new Error("Review is no longer open");
                offer.opened = true;
              }
            } else result = await this.store.handle(request, request.action === "finish" ? this.origin() : undefined);
            reply({ version: 1, requestId, ok: true, result });
            if (request.action === "close") this.offers.delete(request.reviewId!);
            if (request.action === "submit" || request.action === "draft-conclusion") this.onSubmit(request.reviewId!);
            // Dispatch outside the serial transaction: session shutdown must be able to drain it.
            if (request.action === "finish") setImmediate(() => this.onFinish(request.reviewId!, request.payload!.collectionId!, request.payload!.handoffId!));
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
