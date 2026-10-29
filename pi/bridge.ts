// The interactive Pi process owns this workspace lease and mechanical socket.
// Review policy is dispatched only for a verified selected peer, outside this
// mechanical transport. No models, session switching or recovery live here.
import net from "node:net";
import { promises as fs } from "node:fs";
import type { FileHandle } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { stateDirectory } from "./paths.ts";

const reviewActions = [
  "review-info",
  "review-batch-begin",
  "review-batch-chunk",
  "review-batch-commit",
  "review-result-begin",
  "review-result-chunk",
  "review-result-receipt",
  "review-finish-begin",
  "review-finish-status",
] as const;

const actions = {
  attach: "bridge-attach",
  ping: "bridge-ping",
  detach: "bridge-detach",
} as const;

export const frameBytes = 64 * 1024;
export type ReviewAction = typeof reviewActions[number];
export type ReviewPeerRequest = {
  readonly action: ReviewAction;
  readonly reviewId: unknown;
  readonly payload: Readonly<Record<string, unknown>>;
  readonly peer: EditorPeer;
  // Invalidated by disconnect, detach, replacement or shutdown, across await.
  readonly current: () => boolean;
};

export type EditorPeer = {
  readonly editorId: string;
  readonly sessionId: string;
  readonly label: string;
};

type WorkspaceIdentity = {
  readonly version: 1;
  readonly workspace: string;
  readonly pid: number;
  readonly instanceId: string;
  readonly sessionId: string;
};

// Verification accepts only this identity result; there are no model-turn results.
type VerificationIdentity = {
  readonly version: 1;
  readonly nonce: string;
  readonly editorId: string;
  readonly instanceId: string;
  readonly sessionId: string;
  readonly workspace: string;
};

// The envelope is checked here; action-specific payloads remain untrusted.
type RequestEnvelope = {
  readonly action: unknown;
  readonly workspace: unknown;
  readonly payload: unknown;
  readonly reviewId?: unknown;
};

type ResponseEnvelope = {
  readonly version: 1;
  readonly requestId: string;
};

type Response = ResponseEnvelope & (
  | { readonly ok: true; readonly result: unknown }
  | { readonly ok: false; readonly error: string }
);

type RequestResult = WorkspaceIdentity & {
  readonly editorId: string;
  readonly nonce: string;
  readonly data?: Readonly<Record<string, unknown>>;
};

type PendingVerification = {
  readonly socket: net.Socket;
  readonly peer: EditorPeer;
  readonly timer: ReturnType<typeof setTimeout>;
  readonly resolve: (result: VerificationIdentity) => void;
  readonly reject: (error: Error) => void;
};

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

function exactKeys(value: Readonly<Record<string, unknown>>, keys: readonly string[]): boolean {
  return Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function isReviewAction(value: unknown): value is ReviewAction {
  return reviewActions.some(action => action === value);
}

function parseResponse(message: Readonly<Record<string, unknown>>, requestId: string, ok: boolean): Response {
  const keys = ok ? ["version", "requestId", "ok", "result"] : ["version", "requestId", "ok", "error"];
  if (!exactKeys(message, keys)) {
    throw new Error("Invalid bridge response fields");
  }
  if (ok) {
    return { version: 1, requestId, ok: true, result: message.result };
  }
  if (typeof message.error !== "string") {
    throw new Error("Invalid bridge failure text");
  }
  return { version: 1, requestId, ok: false, error: message.error };
}

function isIdentifier(value: unknown): value is string {
  return typeof value === "string" && /^[a-zA-Z0-9_-]{1,128}$/.test(value);
}

// Match Neovim's filesystem-only discovery; this does not run Git/jj or capture text.
export async function workspaceRoot(cwd: string): Promise<string> {
  let directory = await fs.realpath(cwd);
  for (;;) {
    for (const marker of [".jj", ".git"]) {
      try {
        await fs.lstat(path.join(directory, marker));
        return directory;
      } catch (error) {
        if (asRecord(error)?.code !== "ENOENT") {
          throw error;
        }
      }
    }
    const parent = path.dirname(directory);
    if (parent === directory) {
      throw new Error("Not in a jj or Git workspace");
    }
    directory = parent;
  }
}

async function advertise(filename: string, data: unknown): Promise<void> {
  const temporaryPath = `${filename}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporaryPath, JSON.stringify(data), { flag: "wx", mode: 0o600 });
    await fs.rename(temporaryPath, filename);
  } finally {
    await fs.rm(temporaryPath, { force: true });
  }
}

export class WorkspaceBridge {
  private server?: net.Server;
  private readonly sockets = new Set<net.Socket>();
  private readonly peers = new Map<net.Socket, EditorPeer>();
  private readonly verified = new Set<net.Socket>();
  // Retain the chosen editor through disconnects. Only its explicit detach (or
  // withdrawing this offer) releases the slot; another editor cannot steal it.
  private editor?: EditorPeer;
  private readonly pendingVerifications = new Map<string, PendingVerification>();
  private readonly instanceId = randomUUID();
  private readonly lease: string;
  private runtime?: string;
  private ownsLease = false;
  private stopping = false;
  private closing?: Promise<void>;
  onPeersChanged: () => void = () => {};
  onFailure: (error: Error) => void = () => {};
  onReviewRequest?: (request: ReviewPeerRequest) => Promise<Readonly<Record<string, unknown>>>;

  constructor(readonly root: string, readonly sessionId: string) {
    const endpointsDirectory = path.join(stateDirectory(), "endpoints");
    const workspaceKey = createHash("sha256").update(root).digest("hex");
    this.lease = path.join(endpointsDirectory, `${workspaceKey}.json`);
  }

  private identity(): WorkspaceIdentity {
    return {
      version: 1,
      workspace: this.root,
      pid: process.pid,
      instanceId: this.instanceId,
      sessionId: this.sessionId,
    };
  }

  private async acquireLease(): Promise<void> {
    await fs.mkdir(path.dirname(this.lease), { recursive: true, mode: 0o700 });
    // Exclusive guard prevents contenders from removing a newly acquired lease.
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
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const handle = await fs.open(this.lease, "wx", 0o600);
          this.ownsLease = true;
          try {
            await handle.writeFile(JSON.stringify(this.identity()));
          } finally {
            await handle.close();
          }
          break;
        } catch (error) {
          if (asRecord(error)?.code !== "EEXIST") {
            throw error;
          }
          const leaseData: unknown = JSON.parse(await fs.readFile(this.lease, "utf8"));
          const owner = asRecord(leaseData);
          const pid = owner?.pid;
          if (typeof pid !== "number" || !Number.isSafeInteger(pid) || pid <= 0) {
            throw new Error("Incomplete Parley workspace lease; inspect it before recovery");
          }
          try {
            process.kill(pid, 0);
            throw new Error("This workspace already has a live Parley Pi owner");
          } catch (error) {
            if (asRecord(error)?.code !== "ESRCH") {
              throw error;
            }
          }
          // PID is only a liveness check for lease cleanup, never attach identity.
          await fs.unlink(this.lease);
        }
      }
      if (!this.ownsLease) {
        throw new Error("Could not acquire Parley workspace");
      }
    } finally {
      await guard.close();
      await fs.unlink(guardPath);
    }
  }

  async start(): Promise<void> {
    await this.acquireLease();
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
      let ready = false;
      let startupFailure: Error | undefined;
      server.on("error", error => {
        if (!ready) {
          // start() owns cleanup until publication finishes. Stopping during
          // advertise() could otherwise recreate a lease after its removal.
          startupFailure = error;
          return;
        }
        try {
          this.onFailure(error);
        } catch (failure) {
          console.error("Parley failure reporting failed", failure);
        } finally {
          void this.stop().catch(failure => console.error("Parley shutdown failed", failure));
        }
      });
      await fs.chmod(socket, 0o600);
      await advertise(this.lease, { ...this.identity(), socket });
      if (startupFailure) {
        throw startupFailure;
      }
      ready = true;
    } catch (error) {
      try {
        await this.stop();
      } catch (cleanupError) {
        console.error("Parley startup cleanup failed", cleanupError);
      }
      throw error;
    }
  }

  editorChoices(): EditorPeer[] {
    return [...this.peers.values()].map(peer => ({ ...peer }));
  }

  // Attach proves both socket directions before acknowledging the pairing.
  private async verifyEditor(editorId: string): Promise<void> {
    const matches = [...this.peers].filter(([, peer]) => peer.editorId === editorId);
    if (this.stopping || matches.length !== 1) {
      throw new Error("Editor is missing or ambiguous; select an exact connected peer");
    }
    const [socket, peer] = matches[0];
    const requestId = randomUUID();
    await new Promise<VerificationIdentity>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingVerifications.delete(requestId);
        reject(new Error(`Editor result timed out for ${requestId}; delivery unknown. Check Neovim review status; no automatic replay.`));
        socket.destroy();
      }, 10_000);
      this.pendingVerifications.set(requestId, { socket, peer, timer, resolve, reject });
      this.send(socket, {
        version: 1,
        requestId,
        action: actions.ping,
        workspace: this.root,
        payload: { ...this.identity(), nonce: requestId, editorId },
      });
    });
  }

  private matchesIdentity(value: unknown, requestId: string, peer: EditorPeer): value is VerificationIdentity {
    const result = asRecord(value);
    return result !== undefined
      && exactKeys(result, ["version", "nonce", "editorId", "instanceId", "sessionId", "workspace"])
      && result.version === 1
      && result.nonce === requestId
      && result.editorId === peer.editorId
      && result.instanceId === this.instanceId
      && result.sessionId === this.sessionId
      && result.workspace === this.root;
  }

  private accept(client: net.Socket): void {
    this.sockets.add(client);
    client.setEncoding("utf8");
    client.setTimeout(30_000, () => client.destroy());
    client.on("error", () => client.destroy());
    client.on("close", () => {
      this.sockets.delete(client);
      this.verified.delete(client);
      for (const [requestId, entry] of this.pendingVerifications) {
        if (entry.socket !== client) {
          continue;
        }
        clearTimeout(entry.timer);
        this.pendingVerifications.delete(requestId);
        entry.reject(new Error(`Editor disconnected before result for ${requestId}; delivery unknown. No automatic replay.`));
      }
      if (this.peers.delete(client)) {
        try {
          this.onPeersChanged();
        } catch (error) {
          console.error("Parley peer status reporting failed", error);
        }
      }
    });
    let buffer = "";
    client.on("data", (chunk: string) => {
      buffer += chunk;
      for (;;) {
        const end = buffer.indexOf("\n");
        if (end < 0) {
          if (Buffer.byteLength(buffer) > frameBytes) {
            this.send(client, { version: 1, requestId: "invalid", ok: false, error: "Bridge frame exceeds 64 KiB; no truncation or replay" });
            client.end();
          }
          break;
        }
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        if (Buffer.byteLength(line) > frameBytes) {
          this.send(client, { version: 1, requestId: "invalid", ok: false, error: "Bridge frame exceeds 64 KiB; no truncation or replay" });
          client.end();
          return;
        }
        void this.handleMessage(client, line).catch(error => {
          // A reporting failure must still close this peer, not the offer.
          client.destroy();
          console.error("Parley peer handler failed", error);
        });
        if (client.destroyed) {
          return;
        }
      }
    });
  }

  private async handleMessage(client: net.Socket, line: string): Promise<void> {
    let requestId = "invalid";
    try {
      if (this.stopping) {
        throw new Error("Pi is shutting down");
      }
      const parsed: unknown = JSON.parse(line);
      const message = asRecord(parsed);
      if (!message || message.version !== 1 || !isIdentifier(message.requestId)) {
        throw new Error("Unsupported bridge envelope");
      }
      requestId = message.requestId;
      if (typeof message.ok === "boolean") {
        this.handleResponse(client, parseResponse(message, requestId, message.ok));
        return;
      }
      const requestFields = ["version", "requestId", "action", "workspace", "payload"];
      if (Object.hasOwn(message, "reviewId")) {
        requestFields.push("reviewId");
      }
      if (!exactKeys(message, requestFields)) {
        throw new Error("Invalid bridge request fields");
      }
      const result = await this.handleRequest(client, {
        action: message.action,
        workspace: message.workspace,
        payload: message.payload,
        reviewId: message.reviewId,
      });
      this.send(client, { version: 1, requestId, ok: true, result });
    } catch (error) {
      this.send(client, {
        version: 1,
        requestId,
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private handleResponse(client: net.Socket, message: Response): void {
    const entry = this.pendingVerifications.get(message.requestId);
    if (!entry || entry.socket !== client || this.peers.get(client) !== entry.peer) {
      client.destroy();
      return;
    }
    clearTimeout(entry.timer);
    this.pendingVerifications.delete(message.requestId);
    if (!message.ok) {
      entry.reject(new Error(message.error));
    } else if (!this.matchesIdentity(message.result, message.requestId, entry.peer)) {
      entry.reject(new Error("Editor result identity mismatch"));
      client.destroy();
    } else {
      entry.resolve(message.result);
    }
  }

  private async handleRequest(client: net.Socket, message: RequestEnvelope): Promise<RequestResult> {
    const payload = asRecord(message.payload);
    const editorId = payload?.editorId;
    if (!payload
      || message.workspace !== this.root
      || payload.instanceId !== this.instanceId
      || payload.sessionId !== this.sessionId
      || !isIdentifier(editorId)
      || !isIdentifier(payload.nonce)) {
      throw new Error("Bridge identity changed; rediscover and explicitly rebind if the session changed");
    }
    const peer = this.peers.get(client);
    if (isReviewAction(message.action)) {
      if (!peer
        || !this.verified.has(client)
        || this.editor?.editorId !== editorId
        || peer.editorId !== editorId
        || !this.onReviewRequest) {
        throw new Error("Review interaction requires the verified selected editor and an initialized review host");
      }
      const current = (): boolean => !this.stopping
        && !client.destroyed
        && this.peers.get(client) === peer
        && this.verified.has(client)
        && this.editor?.editorId === peer.editorId;
      const data = await this.onReviewRequest({ action: message.action, reviewId: message.reviewId, payload, peer, current });
      if (!current()) {
        throw new Error("Review peer changed during request; delivery may be unknown. No automatic replay.");
      }
      return { ...this.identity(), editorId, nonce: payload.nonce, data };
    }
    const identityFields = ["instanceId", "sessionId", "editorId", "nonce"];
    const payloadFields = message.action === actions.attach ? [...identityFields, "label"] : identityFields;
    if (message.reviewId !== undefined || !exactKeys(payload, payloadFields)) {
      throw new Error("Invalid bridge identity payload fields");
    }
    switch (message.action) {
      case actions.attach: {
        await this.attachEditor(client, editorId, payload.label);
        break;
      }
      case actions.detach: {
        if (this.editor?.editorId !== editorId
          || [...this.peers].some(([socket]) => socket !== client)) {
          throw new Error("Only the selected editor can release its review attachment");
        }
        this.peers.delete(client);
        this.editor = undefined;
        this.verified.delete(client);
        this.onPeersChanged();
        break;
      }
      case actions.ping: {
        if (this.peers.get(client)?.editorId !== editorId) {
          throw new Error("Attach before pinging this Pi session");
        }
        break;
      }
      default:
        throw new Error("Unsupported bridge request");
    }
    return { ...this.identity(), editorId, nonce: payload.nonce };
  }

  private async attachEditor(client: net.Socket, editorId: string, label: unknown): Promise<void> {
    if (typeof label !== "string" || label.length > 512) {
      throw new Error("Invalid editor label");
    }
    if (this.editor && this.editor.editorId !== editorId) {
      throw new Error("Another Neovim owns this review; :Parley stop there before pairing another editor");
    }
    if (this.peers.size > 0) {
      throw new Error("The selected editor already has a live connection; no connection replaced");
    }
    const peer: EditorPeer = {
      editorId,
      sessionId: this.sessionId,
      label: label.replace(/[\x00-\x1f\x7f]/g, " "),
    };
    // The retained object also identifies this claim's lifetime: an old
    // failed verification must never clear a replacement claim.
    this.editor ??= peer;
    this.peers.set(client, peer);
    try {
      await this.verifyEditor(editorId);
      if (client.destroyed || this.peers.get(client) !== peer) {
        throw new Error("Editor disconnected during pairing");
      }
      this.verified.add(client);
      this.onPeersChanged();
    } catch (error) {
      if (this.peers.get(client) === peer) {
        this.peers.delete(client);
      }
      if (this.editor === peer && this.peers.size === 0) {
        this.editor = undefined;
      }
      throw error;
    }
  }

  private send(client: net.Socket, message: unknown): void {
    if (client.destroyed) {
      return;
    }
    try {
      const encoded = JSON.stringify(message);
      if (Buffer.byteLength(encoded) > frameBytes) {
        throw new Error("Outgoing bridge frame exceeds 64 KiB; no truncation");
      }
      client.write(encoded + "\n", error => {
        if (error) {
          client.destroy();
        }
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
    let failed = false;
    let failure: unknown;
    const finish = async (action: () => Promise<void>): Promise<void> => {
      try {
        await action();
      } catch (error) {
        if (!failed) {
          failed = true;
          failure = error;
        }
      }
    };
    await finish(async () => {
      for (const client of this.sockets) {
        client.destroy();
      }
      const server = this.server;
      if (server?.listening) {
        await new Promise<void>(resolve => server.close(() => resolve()));
      }
    });
    await finish(async () => {
      if (this.ownsLease) {
        const leaseData: unknown = JSON.parse(await fs.readFile(this.lease, "utf8"));
        const descriptor = asRecord(leaseData);
        if (descriptor?.instanceId === this.instanceId) {
          await fs.unlink(this.lease);
        }
        this.ownsLease = false;
      }
    });
    await finish(async () => {
      if (this.runtime) {
        await fs.rm(this.runtime, { recursive: true, force: true });
      }
    });
    if (failed) {
      throw failure;
    }
  }
}
