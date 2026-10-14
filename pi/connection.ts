// The interactive Pi runtime owns this socket and its workspace lease, not the review contents.
import net from "node:net";
import { promises as fs } from "node:fs";
import type { FileHandle } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import {
  ReviewStore,
  atomicJson,
  workspaceKey,
  validateRequest,
  type SessionOrigin,
  type Review,
  type Request as ReviewRequest,
} from "./state.ts";

type EditorPeer = { id: string; label: string; eligible: boolean };
type BridgePeer = {
  editorId: string;
  sessionId: string;
  label: string;
};

type BridgeIdentity = {
  version: 1;
  workspace: string;
  pid: number;
  instanceId: string;
  sessionId: string | undefined;
};

// Only the correlated identity fields are validated; other editor metadata stays unknown.
type BridgePingPayload = {
  [key: string]: unknown;
  version: 1;
  nonce: string;
  editorId: string;
  instanceId: string;
  sessionId?: string;
  workspace: string;
};
type BridgePingResult = BridgePingPayload & { requestId: string };

// Recognizing an envelope does not validate its payload or the peer's identity.
type BridgeResponseEnvelope = Record<string, unknown> & {
  version: 1;
  requestId: string;
  ok: boolean;
};
type BridgeRequestEnvelope = Record<string, unknown> & {
  action: "bridge-attach" | "bridge-ping";
};
type BridgeAcknowledgement = BridgeIdentity & { editorId: string; nonce: unknown };

type ResponseEnvelope =
  | {
      version: 1;
      requestId: string;
      ok: true;
      result: unknown;
    }
  | {
      version: 1;
      requestId: string;
      ok: false;
      error: string;
    };

type PendingBridgePing = {
  socket: net.Socket;
  timer: ReturnType<typeof setTimeout>;
  resolve: (result: BridgePingResult) => void;
  reject: (error: Error) => void;
};

// JSON objects are envelopes, not trusted protocol messages. Nested values need their own checks.
function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object"
    ? value as Record<string, unknown>
    : undefined;
}

function isBridgeResponse(message: Record<string, unknown> | undefined): message is BridgeResponseEnvelope {
  return message?.version === 1
    && typeof message.requestId === "string"
    && typeof message.ok === "boolean";
}

function isBridgeRequest(message: Record<string, unknown> | undefined): message is BridgeRequestEnvelope {
  return message?.action === "bridge-attach" || message?.action === "bridge-ping";
}

type ReadyOffer = { offerId: string; reviewId: string; scope: string; editorId?: string; dismissed?: boolean; opened?: boolean };

export class Connection {
  readonly store: ReviewStore;
  private server?: net.Server;
  private sockets = new Set<net.Socket>();
  private editors = new Map<net.Socket, EditorPeer>();
  private peers = new Map<net.Socket, BridgePeer>();
  // This connection owns each ping until result, timeout, or socket closure settles it.
  private pending = new Map<string, PendingBridgePing>();
  onPeersChanged: () => void = () => {};
  private reviewsReady = false;
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
    this.directory = directory;
    this.root = root;
    this.store = new ReviewStore(directory, root);
    this.lease = path.join(directory, "endpoints", workspaceKey(root) + ".json");
  }
  serial<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.tail.then(operation);
    this.tail = result.catch(() => {}); // Each caller receives its failure; the queue remains usable.
    return result;
  }
  async start(): Promise<void> {
    await fs.mkdir(path.dirname(this.lease), { recursive: true, mode: 0o700 });
    // All lease contenders use the same exclusive acquisition guard. A crash
    // during acquisition fails closed instead of risking removal of a new owner.
    const guardPath = this.lease + ".acquiring";
    let guard: FileHandle;
    try {
      guard = await fs.open(guardPath, "wx", 0o600);
    } catch (error) {
      if (asRecord(error)?.code === "EEXIST") {
        throw new Error(`Workspace acquisition in progress or interrupted; inspect ${guardPath}`);
      }
      throw error;
    }
    try {
      await guard.writeFile(String(process.pid));
      // Reserve the workspace before recovery or record mutations. Never steal a live lease.
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const handle = await fs.open(this.lease, "wx", 0o600);
          try {
            await handle.writeFile(JSON.stringify({
              version: 1,
              workspace: this.root,
              pid: process.pid,
              instanceId: this.instanceId,
            }));
          } finally {
            await handle.close();
          }
          this.ownsLease = true;
          break;
        } catch (error) {
          if (asRecord(error)?.code !== "EEXIST") throw error;
          const owner = JSON.parse(await fs.readFile(this.lease, "utf8"));
          if (!Number.isSafeInteger(owner.pid)) {
            throw new Error("Incomplete Parley workspace lease; inspect it before recovery");
          }
          try {
            process.kill(owner.pid, 0);
            throw new Error("This workspace already has a live Parley Pi owner");
          } catch (alive) {
            if (asRecord(alive)?.code !== "ESRCH") throw alive;
          }
          // Dead process cannot update its descriptor; deletion is only for this proven-dead lease.
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
        server.listen(socket, () => {
          server.off("error", reject);
          resolve();
        });
      });
      server.on("error", error => {
        void this.onFailure(error)
          .finally(() => this.stop())
          .catch(failure => console.error("Parley shutdown failed", failure));
      });
      await fs.chmod(socket, 0o600);
      await atomicJson(this.lease, { ...this.identity(), socket });
    } catch (error) {
      await this.stop();
      throw error;
    }
  }
  // Passive bridge startup never recovers reviews or dispatches retained work.
  async activateReviews(preserveQueued = false): Promise<void> {
    if (this.reviewsReady) return;
    await this.store.recover(preserveQueued);
    for (const item of await this.store.list()) this.offer(await this.store.read(item.id));
    this.reviewsReady = true;
  }
  identity(): BridgeIdentity {
    return {
      version: 1,
      workspace: this.root,
      pid: process.pid,
      instanceId: this.instanceId,
      sessionId: this.origin()?.sessionId,
    };
  }
  bridgeChoices(): BridgePeer[] {
    return [...this.peers.values()].map(peer => ({ ...peer }));
  }

  private matchesPingIdentity(value: unknown, requestId: string, peer: BridgePeer): value is BridgePingPayload {
    const result = asRecord(value);
    return result !== undefined
      && result.version === 1
      && result.nonce === requestId
      && result.editorId === peer.editorId
      && result.instanceId === this.instanceId
      && result.sessionId === this.origin()?.sessionId
      && result.workspace === this.root;
  }

  pingEditor(editorId: string): Promise<BridgePingResult> {
    const matches = [...this.peers].filter(([, peer]) => peer.editorId === editorId);
    if (matches.length !== 1) {
      return Promise.reject(new Error("Editor is missing or ambiguous; select an exact connected peer"));
    }
    const [socket, peer] = matches[0];
    const requestId = randomUUID();
    if (peer.sessionId !== this.origin()?.sessionId) {
      return Promise.reject(new Error("Pi session changed; explicitly rebind in Neovim"));
    }
    return new Promise<BridgePingResult>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error(`Editor result timed out for ${requestId}; delivery unknown`));
        socket.destroy();
      }, 10_000);
      this.pending.set(requestId, { socket, timer, resolve, reject });
      socket.write(JSON.stringify({
        version: 1,
        requestId,
        action: "bridge-ping",
        payload: { nonce: requestId, ...this.identity(), editorId },
      }) + "\n");
    });
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

  private accept(client: net.Socket): void {
    this.sockets.add(client);
    client.setEncoding("utf8");
    client.setTimeout(30_000, () => client.destroy());
    client.on("error", () => client.destroy());
    client.on("close", () => this.handleDisconnect(client));
    this.listenForMessages(client);
  }

  private handleDisconnect(client: net.Socket): void {
    const editor = this.editors.get(client);
    this.sockets.delete(client);
    this.editors.delete(client);
    if (this.peers.delete(client)) this.onPeersChanged();

    for (const [requestId, entry] of this.pending) {
      if (entry.socket !== client) continue;
      clearTimeout(entry.timer);
      this.pending.delete(requestId);
      entry.reject(new Error(`Editor disconnected before result for ${requestId}; delivery unknown`));
    }

    // Another watch socket for this editor keeps its offers assigned.
    if (!editor || [...this.editors.values()].some(peer => peer.id === editor.id)) return;
    for (const offer of this.offers.values()) {
      if (offer.editorId === editor.id && !offer.opened && !offer.dismissed) {
        delete offer.editorId;
      }
    }
  }

  private listenForMessages(client: net.Socket): void {
    // Framing and backlog belong to this socket; execution is serialized across all sockets.
    let buffer = "";
    let queuedMessages = 0;

    client.on("data", (chunk: string) => {
      buffer += chunk;
      if (Buffer.byteLength(buffer) > 64 * 1024 * 1024) {
        client.destroy();
        return;
      }

      for (;;) {
        const end = buffer.indexOf("\n");
        if (end < 0) break;
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        queuedMessages++;
        if (queuedMessages > 16) {
          client.destroy();
          return;
        }

        void this.serial(async () => {
          try {
            await this.handleMessage(client, line);
          } finally {
            queuedMessages--;
          }
        });
      }
    });
  }

  private async handleMessage(client: net.Socket, line: string): Promise<void> {
    let requestId = "invalid";
    try {
      if (this.stopping) throw new Error("Pi is shutting down");
      const request: unknown = JSON.parse(line);
      const message = asRecord(request);
      if (typeof message?.requestId === "string") requestId = message.requestId;

      // Responses must be correlated before considering incoming requests.
      if (isBridgeResponse(message)) {
        this.handleBridgeResponse(client, message);
        return;
      }
      if (isBridgeRequest(message)) {
        const result = this.handleBridgeRequest(client, message);
        this.sendResponse(client, { version: 1, requestId, ok: true, result });
        return;
      }

      validateRequest(request);
      const result = await this.handleReviewRequest(client, request);
      this.sendResponse(client, { version: 1, requestId, ok: true, result });

      // Acknowledgement precedes review callbacks and presentation-state updates.
      if (request.action === "close") this.offers.delete(request.reviewId!);
      if (request.action === "submit" || request.action === "draft-conclusion") {
        this.onSubmit(request.reviewId!);
      }
      if (request.action === "finish") {
        // Dispatch outside the serial transaction: shutdown must be able to drain it.
        setImmediate(() => this.onFinish(
          request.reviewId!,
          request.payload!.collectionId!,
          request.payload!.handoffId!,
        ));
      }
    } catch (error) {
      this.sendResponse(client, {
        version: 1,
        requestId,
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private handleBridgeResponse(client: net.Socket, message: BridgeResponseEnvelope): void {
    const entry = this.pending.get(message.requestId);
    const peer = this.peers.get(client);
    if (!entry || entry.socket !== client || !peer) {
      client.destroy();
      return;
    }

    clearTimeout(entry.timer);
    this.pending.delete(message.requestId);
    if (!message.ok) {
      const error = typeof message.error === "string" ? message.error : "Editor rejected request";
      entry.reject(new Error(error));
      return;
    }
    if (!this.matchesPingIdentity(message.result, message.requestId, peer)) {
      entry.reject(new Error("Editor result identity mismatch"));
      client.destroy();
      return;
    }
    entry.resolve({ ...message.result, requestId: message.requestId });
  }

  private handleBridgeRequest(client: net.Socket, message: BridgeRequestEnvelope): BridgeAcknowledgement {
    const payload = asRecord(message.payload);
    const identity = this.identity();
    const sessionId = identity.sessionId;
    const editorId = payload?.editorId;
    const validRequest = message.version === 1
      && typeof message.requestId === "string"
      && /^[a-zA-Z0-9_-]{1,128}$/.test(message.requestId);
    const validEditor = typeof editorId === "string" && /^[a-zA-Z0-9_-]{1,128}$/.test(editorId);

    if (!validRequest
      || message.workspace !== this.root
      || !sessionId
      || payload?.instanceId !== identity.instanceId
      || payload?.sessionId !== sessionId
      || !validEditor) {
      throw new Error("Bridge identity changed or unsupported protocol; rediscover and explicitly rebind if the session changed");
    }

    if (message.action === "bridge-attach") {
      const label = payload?.label;
      if (typeof label !== "string" || label.length > 512) {
        throw new Error("Invalid editor label");
      }
      const alreadyAttached = [...this.peers].some(([socket, peer]) => socket !== client && peer.editorId === editorId);
      if (alreadyAttached) throw new Error("Editor already attached");
      this.peers.set(client, {
        editorId,
        sessionId,
        label: label.replace(/[\x00-\x1f\x7f]/g, " "),
      });
      this.onPeersChanged();
    } else {
      const peer = this.peers.get(client);
      const nonce = payload?.nonce;
      if (!peer
        || peer.editorId !== editorId
        || peer.sessionId !== payload?.sessionId
        || typeof nonce !== "string"
        || nonce.length > 128) {
        throw new Error("Attach before pinging this Pi session");
      }
    }
    return { ...identity, editorId, nonce: payload?.nonce };
  }

  private async handleReviewRequest(client: net.Socket, request: ReviewRequest): Promise<unknown> {
    // validateRequest enforces action-specific fields that the legacy request type leaves optional.
    if (request.action === "watch") {
      if (request.workspace !== this.root) throw new Error("Editor workspace changed");
      const payload = request.payload!;
      const editor: EditorPeer = {
        id: payload.editorId!,
        label: payload.editorLabel!.replace(/[\x00-\x1f\x7f]/g, " "),
        eligible: payload.eligible!,
      };
      this.editors.set(client, editor);
      return [...this.offers.values()].filter(offer => offer.editorId === editor.id && !offer.dismissed);
    }

    if (request.action === "open-offer" || request.action === "dismiss-offer") {
      const editor = this.editors.get(client);
      const offer = this.offers.get(request.reviewId!);
      if (!editor || !offer || offer.editorId !== editor.id || offer.offerId !== request.payload!.offerId) {
        throw new Error("Offer is not assigned to this editor; use ReviewStart to reopen manually");
      }
      if (request.action === "dismiss-offer") {
        offer.dismissed = true;
        return {};
      }
      if (!editor.eligible || offer.dismissed) {
        throw new Error("Editor is no longer eligible for this offer");
      }
      const review = await this.store.read(offer.reviewId);
      if (review.status !== "open") throw new Error("Review is no longer open");
      offer.opened = true;
      return review;
    }

    return await this.store.handle(request, request.action === "finish" ? this.origin() : undefined);
  }

  private sendResponse(client: net.Socket, response: ResponseEnvelope): void {
    if (!client.destroyed) client.write(JSON.stringify(response) + "\n");
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
    await this.tail;
    if (this.ownsLease) {
      const descriptor = JSON.parse(await fs.readFile(this.lease, "utf8"));
      if (descriptor.instanceId === this.instanceId) await fs.unlink(this.lease);
      this.ownsLease = false;
    }
    if (this.runtime) await fs.rm(this.runtime, { recursive: true, force: true });
  }
}
