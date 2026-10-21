import test from "node:test";
import type { TestContext } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import { once } from "node:events";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { WorkspaceBridge, workspaceRoot } from "../pi/bridge.ts";
import type { ReviewAction, ReviewPeerRequest } from "../pi/bridge.ts";

type BridgeMessage = Readonly<Record<string, unknown>>;

type BridgeIdentity = {
  readonly instanceId: string;
  readonly sessionId: string;
};

type BridgeResponse = {
  readonly version: 1;
  readonly requestId: string;
} & (
  | { readonly ok: true; readonly result: unknown }
  | { readonly ok: false; readonly error: string }
);

type TestEditor = {
  send(message: unknown): void;
  read(): Promise<BridgeMessage>;
  request(action: string, editorId?: string, extra?: BridgeMessage): Promise<BridgeResponse>;
};

type BridgeFixture = {
  readonly bridge: WorkspaceBridge;
  readonly root: string;
  readonly endpointsDirectory: string;
  readonly identity: BridgeIdentity;
  connect(): Promise<TestEditor>;
};

function assertMessage(value: unknown): asserts value is BridgeMessage {
  assert(value !== null && typeof value === "object" && !Array.isArray(value), "Expected a bridge message object");
}

function assertResponse(message: BridgeMessage, requestId: string): asserts message is BridgeResponse {
  assert.equal(message.version, 1);
  assert.equal(message.requestId, requestId);
  assert(typeof message.ok === "boolean", "Expected a bridge response status");
  if (message.ok) {
    assert("result" in message, "Expected a bridge success result");
  } else {
    assert.equal(typeof message.error, "string", "Expected bridge failure text");
  }
}

function createTestEditor(socket: net.Socket, workspace: string, identity: BridgeIdentity): TestEditor {
  const reader = createInterface({ input: socket });
  const lines = reader[Symbol.asyncIterator]();
  socket.once("close", () => reader.close());
  let requestSerial = 0;

  function send(message: unknown): void {
    socket.write(JSON.stringify(message) + "\n");
  }

  async function read(): Promise<BridgeMessage> {
    const line = await lines.next();
    assert(!line.done, "Socket closed before the next bridge message");
    const message: unknown = JSON.parse(line.value);
    assertMessage(message);
    return message;
  }

  async function request(action: string, editorId = "editor", extra: BridgeMessage = {}): Promise<BridgeResponse> {
    const requestId = `request-${++requestSerial}`;
    send({
      version: 1,
      requestId,
      workspace,
      action,
      payload: { ...identity, editorId, nonce: requestId, ...extra },
    });

    for (;;) {
      const response = await read();
      if (!("action" in response)) {
        assertResponse(response, requestId);
        return response;
      }

      // Pairing challenges must be answered before the attach response can arrive.
      assert.equal(response.action, "bridge-ping");
      assert.deepEqual(response.payload, {
        version: 1,
        workspace,
        pid: process.pid,
        ...identity,
        nonce: response.requestId,
        editorId,
      });
      send({
        version: 1,
        requestId: response.requestId,
        ok: true,
        result: { version: 1, workspace, ...identity, nonce: response.requestId, editorId },
      });
    }
  }

  return { send, read, request };
}

async function startBridge(t: TestContext): Promise<BridgeFixture> {
  const temporaryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-bridge-test-"));
  const previousStateDirectory = process.env.PARLEY_STATE_DIR;
  const sockets: net.Socket[] = [];
  let bridge: WorkspaceBridge | undefined;
  t.after(async () => {
    try {
      for (const socket of sockets) {
        socket.destroy();
      }
      await bridge?.stop();
    } finally {
      if (previousStateDirectory === undefined) {
        delete process.env.PARLEY_STATE_DIR;
      } else {
        process.env.PARLEY_STATE_DIR = previousStateDirectory;
      }
      await fs.rm(temporaryDirectory, { recursive: true, force: true });
    }
  });

  const root = path.join(temporaryDirectory, "work");
  const stateDirectory = path.join(temporaryDirectory, "state");
  await fs.mkdir(path.join(root, ".git"), { recursive: true });
  process.env.PARLEY_STATE_DIR = stateDirectory;
  bridge = new WorkspaceBridge(root, "parent-session");
  await bridge.start();

  assert.deepEqual(await fs.readdir(stateDirectory), ["endpoints"]);
  const endpointsDirectory = path.join(stateDirectory, "endpoints");
  const leases = await fs.readdir(endpointsDirectory);
  assert.equal(leases.length, 1, "Expected a single workspace lease");
  const descriptor: unknown = JSON.parse(await fs.readFile(path.join(endpointsDirectory, leases[0]), "utf8"));
  assertMessage(descriptor);
  assert(typeof descriptor.socket === "string");
  assert(typeof descriptor.instanceId === "string");
  assert(descriptor.sessionId === "parent-session");
  const socketPath = descriptor.socket;
  const identity = { instanceId: descriptor.instanceId, sessionId: descriptor.sessionId };

  async function connect(): Promise<TestEditor> {
    const socket = net.createConnection(socketPath);
    sockets.push(socket);
    await once(socket, "connect");
    return createTestEditor(socket, root, identity);
  }

  return { bridge, root, endpointsDirectory, identity, connect };
}

test("socket pairing verifies both directions, restricts dispatch to its editor, and releases ownership on detach", { timeout: 10_000 }, async t => {
  const { bridge, root, endpointsDirectory, connect } = await startBridge(t);
  await fs.mkdir(path.join(root, "nested"));
  assert.equal(await workspaceRoot(path.join(root, "nested")), root);
  const dispatched: ReviewPeerRequest[] = [];
  bridge.onReviewRequest = async request => {
    dispatched.push(request);
    return { ready: true };
  };
  assert.deepEqual(bridge.editorChoices(), []);
  const editor = await connect();
  assert.equal((await editor.request("review-info")).ok, false);
  assert.equal(dispatched.length, 0);
  assert.equal((await editor.request("bridge-attach", "editor", { label: "Neo\nvim" })).ok, true);
  assert.deepEqual(bridge.editorChoices(), [{ editorId: "editor", sessionId: "parent-session", label: "Neo vim" }]);
  assert.equal((await editor.request("bridge-ping")).ok, true);
  assert.equal(dispatched.length, 0);
  const reviewActions: readonly ReviewAction[] = [
    "review-info",
    "review-batch-begin",
    "review-batch-chunk",
    "review-batch-commit",
    "review-result-begin",
    "review-result-chunk",
    "review-result-receipt",
    "review-finish-begin",
    "review-finish-status",
  ];
  for (const action of reviewActions) {
    assert.equal((await editor.request(action, "editor", { extraReviewData: true })).ok, true, action);
  }
  assert.deepEqual(dispatched.map(request => request.action), reviewActions);
  const [reviewRequest] = dispatched;
  assert(reviewRequest, "Expected a dispatched review request");
  assert.equal(reviewRequest.payload.extraReviewData, true);
  assert.equal(reviewRequest.peer.editorId, "editor");
  assert.equal(reviewRequest.current(), true);
  const competingAttachment = await editor.request("bridge-attach", "other-editor", { label: "Other" });
  assert(competingAttachment.ok === false);
  assert.match(competingAttachment.error, /Another Neovim owns/);
  assert.equal((await editor.request("bridge-detach")).ok, true);
  assert.equal(reviewRequest.current(), false);
  assert.deepEqual(bridge.editorChoices(), []);
  assert.equal((await editor.request("review-info")).ok, false);
  assert.equal(dispatched.length, reviewActions.length);
  const closing = bridge.stop();
  assert.equal(bridge.stop(), closing);
  await closing;
  assert.deepEqual(await fs.readdir(endpointsDirectory), []);
});

test("malformed envelopes and identity payloads are rejected without closing a usable connection", { timeout: 10_000 }, async t => {
  const { bridge, root, identity, connect } = await startBridge(t);
  const editor = await connect();
  const attachRequest = { version: 1, requestId: "invalid-request", workspace: root, action: "bridge-attach",
    payload: { ...identity, editorId: "editor", nonce: "nonce", label: "Neovim" } };
  const cases = [
    { message: null, expectedError: "Unsupported bridge envelope", expectedRequestId: "invalid" },
    { message: { ...attachRequest, version: 2 }, expectedError: "Unsupported bridge envelope", expectedRequestId: "invalid" },
    { message: { ...attachRequest, extra: true }, expectedError: "Invalid bridge request fields" },
    { message: { ...attachRequest, payload: [] }, expectedError: "Bridge identity changed" },
    { message: { ...attachRequest, reviewId: null }, expectedError: "Invalid bridge identity payload fields" },
    { message: { ...attachRequest, payload: { ...attachRequest.payload, extra: true } }, expectedError: "Invalid bridge identity payload fields" },
    { message: { ...attachRequest, payload: { ...attachRequest.payload, label: 42 } }, expectedError: "Invalid editor label" },
    { message: { version: 1, requestId: attachRequest.requestId, ok: true }, expectedError: "Invalid bridge response fields" },
    { message: { version: 1, requestId: attachRequest.requestId, ok: true, result: {}, extra: true }, expectedError: "Invalid bridge response fields" },
    { message: { version: 1, requestId: attachRequest.requestId, ok: false, error: {} }, expectedError: "Invalid bridge failure text" },
  ];
  for (const scenario of cases) {
    editor.send(scenario.message);
    const response = await editor.read();
    assertResponse(response, scenario.expectedRequestId ?? attachRequest.requestId);
    assert(response.ok === false);
    assert(response.error.startsWith(scenario.expectedError), response.error);
    assert.deepEqual(bridge.editorChoices(), []);
  }
  assert.equal((await editor.request("bridge-attach", "editor", { label: "Neovim" })).ok, true);
});

test("a rejected verification releases its pairing claim and permits an explicit retry", { timeout: 10_000 }, async t => {
  const { bridge, root, identity, connect } = await startBridge(t);
  const editor = await connect();
  editor.send({ version: 1, requestId: "attach", workspace: root, action: "bridge-attach",
    payload: { ...identity, editorId: "editor", nonce: "attach", label: "Neovim" } });
  const verification = await editor.read();
  assert.equal(verification.action, "bridge-ping");
  editor.send({ version: 1, requestId: verification.requestId, ok: false, error: "Editor refused verification" });
  assert.deepEqual(await editor.read(), { version: 1, requestId: "attach", ok: false, error: "Editor refused verification" });
  assert.deepEqual(bridge.editorChoices(), []);
  assert.equal((await editor.request("bridge-attach", "other-editor", { label: "Other" })).ok, true);
});

test("detaching during review dispatch invalidates its lifetime and rejects the stale result", { timeout: 10_000 }, async t => {
  const { bridge, root, identity, connect } = await startBridge(t);
  const editor = await connect();
  assert.equal((await editor.request("bridge-attach", "editor", { label: "Neovim" })).ok, true);
  const dispatchStarted = Promise.withResolvers<ReviewPeerRequest>();
  const reviewCompletion = Promise.withResolvers<Readonly<Record<string, unknown>>>();
  t.after(() => reviewCompletion.resolve({ ready: true }));
  bridge.onReviewRequest = request => {
    dispatchStarted.resolve(request);
    return reviewCompletion.promise;
  };
  editor.send({ version: 1, requestId: "review", workspace: root, action: "review-info", reviewId: "review-id",
    payload: { ...identity, editorId: "editor", nonce: "review" } });
  const reviewRequest = await dispatchStarted.promise;
  assert.equal(reviewRequest.reviewId, "review-id");
  assert.equal(reviewRequest.current(), true);
  assert.equal((await editor.request("bridge-detach")).ok, true);
  assert.equal(reviewRequest.current(), false);
  reviewCompletion.resolve({ ready: true });
  const response = await editor.read();
  assertResponse(response, "review");
  assert(response.ok === false);
  assert.match(response.error, /Review peer changed during request/);
});

test("a competing bridge cannot replace or remove a live workspace lease", { timeout: 10_000 }, async t => {
  const { bridge, root, endpointsDirectory, connect } = await startBridge(t);
  const leases = await fs.readdir(endpointsDirectory);
  const contender = new WorkspaceBridge(root, "another-session");
  t.after(() => contender.stop());
  await assert.rejects(contender.start(), /already has a live Parley Pi owner/);
  await contender.stop();
  assert.deepEqual(await fs.readdir(endpointsDirectory), leases);
  const editor = await connect();
  assert.equal((await editor.request("bridge-attach", "editor", { label: "Neovim" })).ok, true);
  assert.equal(bridge.editorChoices()[0].sessionId, "parent-session");
});
