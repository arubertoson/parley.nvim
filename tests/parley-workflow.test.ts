import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readReviewArtifact } from "../pi/artifact.ts";

function object(value: unknown): Record<string, unknown> {
  assert(value && typeof value === "object" && !Array.isArray(value));
  return value as Record<string, unknown>;
}

async function until<T>(read: () => Promise<T | undefined>): Promise<T> {
  for (let index = 0; index < 1500; index++) {
    const value = await read();
    if (value !== undefined) return value;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw new Error("Timed out waiting for offline workflow");
}

// Normal installed parent + child, real SessionManager branching, native tools,
// actual editor transport, and append-only recap evidence. No network or API key.
test("/parley runs normal child turns, publishes exact-tip replies, returns recap and cancels without rollback", {
  skip: process.env.PARLEY_PI_RUNTIME_TESTS !== "1", timeout: 60_000,
}, async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-workflow-"));
  const root = path.join(directory, "work"), agentDir = path.join(directory, "agent"), state = path.join(directory, "state");
  await fs.mkdir(path.join(root, ".git"), { recursive: true });
  await fs.mkdir(path.join(agentDir, "extensions"), { recursive: true });
  await fs.mkdir(path.join(agentDir, "skills", "fixture"), { recursive: true });
  await fs.copyFile(new URL("./fixtures/parley-process-provider.ts", import.meta.url), path.join(agentDir, "extensions", "offline.ts"));
  await fs.writeFile(path.join(agentDir, "skills", "fixture", "SKILL.md"), "---\nname: fixture\ndescription: Process fixture skill\n---\nFixture instructions.\n");
  await fs.writeFile(path.join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"], cacheWarming: "off",
    compaction: { enabled: false }, retry: { enabled: false } }));
  await fs.writeFile(path.join(root, "source.txt"), "original source\n");
  const sessionId = randomUUID(), timestamp = new Date().toISOString(), parentPath = path.join(directory, "parent.jsonl");
  const original = [{ type: "session", version: 3, id: sessionId, timestamp, cwd: root },
    { type: "message", id: "a1b2c3d4", parentId: null, timestamp,
      message: { role: "user", content: "Inherited decision from parent", timestamp: Date.now() } }].map(value => JSON.stringify(value)).join("\n") + "\n";
  await fs.writeFile(parentPath, original);
  const parent = spawn("pi", ["--mode", "rpc", "--session", parentPath, "--provider", "parley-process-offline", "--model", "offline", "--thinking", "high",
    "--extension", fileURLToPath(new URL("./fixtures/parley-workflow-host.ts", import.meta.url))], {
    cwd: root, env: { ...process.env, HOME: directory, XDG_CONFIG_HOME: path.join(directory, "config"), PI_CODING_AGENT_DIR: agentDir,
      PARLEY_STATE_DIR: state, PI_OFFLINE: "1" }, stdio: ["pipe", "pipe", "pipe"],
  });
  let diagnostic = "", input = "", settled = 0, approvals = 0, serial = 0;
  const pending = new Map<string, { resolve(value: Record<string, unknown>): void; reject(error: Error): void }>();
  parent.stderr.setEncoding("utf8");
  parent.stderr.on("data", (chunk: string) => { diagnostic += chunk; });
  parent.stdout.setEncoding("utf8");
  parent.stdout.on("data", (chunk: string) => {
    input += chunk;
    let end: number;
    while ((end = input.indexOf("\n")) !== -1) {
      const value = object(JSON.parse(input.slice(0, end)));
      input = input.slice(end + 1);
      if (value.type === "response" && typeof value.id === "string") {
        const entry = pending.get(value.id);
        pending.delete(value.id);
        if (value.success) entry?.resolve(object(value.data ?? {}));
        else entry?.reject(new Error(String(value.error)));
      } else if (value.type === "agent_settled") settled++;
      else if (value.type === "extension_ui_request" && value.method === "confirm") {
        assert.equal(value.title, "Offline child permission");
        approvals++;
        parent.stdin.write(JSON.stringify({ type: "extension_ui_response", id: value.id, confirmed: true }) + "\n");
      }
    }
  });
  const exited = new Promise<void>(resolve => parent.once("close", () => resolve()));
  t.after(async () => {
    parent.stdin.end();
    const timer = setTimeout(() => parent.kill("SIGKILL"), 3000);
    try { await exited; } finally { clearTimeout(timer); await fs.rm(directory, { recursive: true, force: true }); }
  });
  function command(type: string, payload: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    const id = `parent-${++serial}`;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      parent.stdin.write(JSON.stringify({ id, type, ...payload }) + "\n");
    });
  }
  assert.equal((await command("get_state")).sessionId, sessionId);

  async function attach() {
    const descriptor = await until(async () => {
      try {
        const filename = (await fs.readdir(path.join(state, "endpoints"))).find(name => name.endsWith(".json"));
        if (filename) {
          const value = object(JSON.parse(await fs.readFile(path.join(state, "endpoints", filename), "utf8")));
          if (typeof value.socket === "string") return value;
        }
      } catch (error) { if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error; }
    });
    const socket = net.createConnection(String(descriptor.socket));
    const replies = new Map<string, (value: Record<string, unknown>) => void>();
    let data = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      data += chunk;
      let end: number;
      while ((end = data.indexOf("\n")) !== -1) {
        const value = object(JSON.parse(data.slice(0, end)));
        data = data.slice(end + 1);
        if (value.action === "bridge-ping") {
          socket.write(JSON.stringify({ version: 1, requestId: value.requestId, ok: true, result: {
            version: 1, workspace: root, instanceId: descriptor.instanceId, sessionId, editorId: "editor", nonce: object(value.payload).nonce,
          } }) + "\n");
        } else { replies.get(String(value.requestId))?.(value); replies.delete(String(value.requestId)); }
      }
    });
    t.after(() => socket.destroy());
    async function request(action: string, payload: Record<string, unknown> = {}, reviewId?: string) {
      const requestId = `editor-${++serial}`;
      const response = new Promise<Record<string, unknown>>(resolve => replies.set(requestId, resolve));
      socket.write(JSON.stringify({ version: 1, requestId, workspace: root, action, reviewId,
        payload: { instanceId: descriptor.instanceId, sessionId, editorId: "editor", nonce: requestId, ...payload } }) + "\n");
      const value = await response;
      assert.equal(value.ok, true, String(value.error));
      return object(object(value.result).data ?? {});
    }
    await request("bridge-attach", { label: "Neovim" });
    const info = await request("review-info");
    assert.equal(info.workflow, "parley");
    const send = (action: string, payload: Record<string, unknown> = {}) => request(action, payload, action === "review-info" ? undefined : String(info.reviewId));
    const artifact = () => readReviewArtifact(path.join(state, "parleys", `${info.reviewId}.jsonl`));
    async function turn(id: string, instruction: string, wait = true) {
      const snapshot = await artifact();
      const history = snapshot.conversations[0];
      const version = history?.version ?? 0, parentId = history?.messages.at(-1)?.id ?? null;
      const batch = { workspace: root, sessionId, editorId: "editor",
        conversations: [{ id: "note", anchor: { path: "source.txt", side: "workspace", first: 1, last: 1,
          lines: history?.record.anchor.lines ?? (await fs.readFile(path.join(root, "source.txt"), "utf8")).trimEnd().split("\n"), observedAt: 1,
          source: { kind: "editor", editorId: "editor", bufferId: 1, changedTick: 1 } }, placement: { first: 1, last: 1 } }],
        messages: [{ id: `${id}-message`, conversationId: "note", requestId: id, parentId, role: "human", author: "Human", origin: "editor/editor", createdAt: 1,
          lines: [instruction], version: version + 1, supersedes: [], replacesId: null }],
        request: { id, kind: "ask", instructions: null, submissions: [{ conversationId: "note", baseVersion: version, baseTipId: parentId,
          messageIds: [`${id}-message`], version: version + 1, tipId: `${id}-message` }] } };
      const bytes = Buffer.from(JSON.stringify(batch)), digest = createHash("sha256").update(bytes).digest("hex");
      await send("review-batch-begin", { batchId: id, preparationId: info.preparationId, bytes: bytes.length, parts: 1, digest });
      await send("review-batch-chunk", { batchId: id, index: 0, hex: bytes.toString("hex") });
      assert.equal((await send("review-batch-commit", { batchId: id, digest })).status, "accepted");
      if (wait) {
        const outcome = await until(async () => (await artifact()).requests.find(item => item.record.id === id)?.outcome);
        if (outcome.status !== "completed") {
          const session = (await artifact()).sessions.find(item => item.record.role === "implementation");
          assert.fail(outcome.detail + diagnostic + (session ? await fs.readFile(session.record.transcriptPath, "utf8") : ""));
        }
        await until(async () => (await send("review-info")).busy === false ? true : undefined);
      }
    }
    return { send, artifact, turn };
  }

  await command("prompt", { message: "/parley" });
  const editor = await attach();
  await editor.turn("first", "Make the localized edit");
  await editor.turn("second", "Verify the localized change again");
  assert.equal(approvals, 2, "Child permission dialogs go to the originating parent UI");
  assert.equal(await fs.readFile(path.join(root, "source.txt"), "utf8"), "changed source\n");
  let snapshot = await editor.artifact();
  assert.equal(snapshot.sessions.filter(item => item.record.role === "implementation").length, 1, "Subsequent turns reuse the same child");
  assert.equal(snapshot.conversations[0].messages.length, 4, "Stale duplicate replies never publish");
  await editor.send("review-finish-begin", { finishId: "finish" });
  const completion = await until(async () => {
    const value = await editor.send("review-finish-status", { finishId: "finish" });
    return value.state === "wrapping" ? undefined : value;
  });
  assert.equal(completion.state, "completed", JSON.stringify(completion) + diagnostic);
  await until(async () => settled === 1 ? true : undefined);
  snapshot = await editor.artifact();
  const implementation = snapshot.sessions.find(item => item.record.role === "implementation");
  assert(implementation?.end);
  const childText = await fs.readFile(implementation.record.transcriptPath, "utf8");
  assert(childText.includes('"toolName":"codemode"'));
  assert(childText.includes('"toolName":"parley_reply"'));
  const parentText = await fs.readFile(parentPath, "utf8");
  assert(parentText.startsWith(original));
  assert(parentText.includes("native read/write verified"));
  assert(parentText.includes("Originating parent received the durable recap"));
  assert(!parentText.includes('"toolName":"codemode"'), "Detailed tool work remains in the child");
  assert.equal((await editor.send("review-finish-status", { finishId: "finish" })).summary, completion.summary);

  await command("prompt", { message: "/parley" });
  const cancelled = await attach();
  await cancelled.turn("cancelled", "Wait for cancellation", false);
  await until(async () => { try { return await fs.readFile(path.join(root, "waiting"), "utf8"); } catch { return undefined; } });
  await command("prompt", { message: "/parley-stop" });
  await until(async () => settled === 2 ? true : undefined);
  const cancelledSnapshot = await cancelled.artifact();
  assert.equal(cancelledSnapshot.requests[0].outcome?.status, "cancelled");
  assert.equal(cancelledSnapshot.requests.length, 1, "Stop adds no recap request");
  assert.equal(cancelledSnapshot.end, undefined);
  assert(cancelledSnapshot.sessions.every(session => session.end), "Acknowledgment follows boundary recording");
  assert.deepEqual(await fs.readdir(path.join(state, "endpoints")), []);
  assert.equal(await fs.readFile(path.join(root, "source.txt"), "utf8"), "changed source\n");
  assert.equal((await command("get_state")).sessionId, sessionId, "No parent session switching");
  const stoppedParent = await fs.readFile(parentPath, "utf8");
  assert(stoppedParent.includes("User cancelled Parley; edits retained, no rollback"));
  assert(!stoppedParent.includes("Originating parent received cancellation; no rollback"), "Stop terminates the host tool without a parent model follow-up");
  await command("prompt", { message: "/parley" });
  const next = await attach();
  await next.turn("after-cancellation", "Make another explicitly localized turn");
  await next.send("review-finish-begin", { finishId: "next-finish" });
  const nextCompletion = await until(async () => {
    const value = await next.send("review-finish-status", { finishId: "next-finish" });
    return value.state === "wrapping" ? undefined : value;
  });
  assert.equal(nextCompletion.state, "completed", JSON.stringify(nextCompletion) + diagnostic);
  await until(async () => settled === 3 ? true : undefined);
  assert.equal((await command("get_state")).sessionId, sessionId);
});
