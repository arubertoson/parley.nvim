import test from "node:test";
import type { TestContext } from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { ReviewRequests } from "../pi/requests.ts";
import { readReviewArtifact } from "../pi/artifact.ts";
import type { PreparationRecord } from "../pi/artifact.ts";
import type { EditorPeer } from "../pi/bridge.ts";
import { reviewWrapUpSummary } from "../pi/handback.ts";
import extension from "../pi/extension.ts";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";

const model: NonNullable<ExtensionContext["model"]> = {
  provider: "offline", id: "review", name: "Offline", api: "openai-completions",
  baseUrl: "https://invalid.example", reasoning: false, input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 8192, maxTokens: 1024,
};
const handoff = { objective: "Review UX", scope: ["code.lua"], decisions: [], guidelines: [], context: [] };
const identity = { instanceId: "instance", sessionId: "parent", editorId: "editor", nonce: "nonce" };

type ParentBoundary = Parameters<ReviewRequests["prepare"]>[1];
type PreparedReview = {
  readonly owner: ReviewRequests;
  readonly parent: ParentBoundary;
  readonly preparation: PreparationRecord;
  readonly peer: EditorPeer;
};

async function createPreparedReview(t: TestContext): Promise<PreparedReview> {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-finish-"));
  const previousState = process.env.PARLEY_STATE_DIR;
  const root = path.join(directory, "work");
  const owner = new ReviewRequests(root, "parent", [], error => { throw error; });
  t.after(async () => {
    try {
      await owner.close();
    } finally {
      if (previousState === undefined) delete process.env.PARLEY_STATE_DIR;
      else process.env.PARLEY_STATE_DIR = previousState;
      await fs.rm(directory, { recursive: true, force: true });
    }
  });
  process.env.PARLEY_STATE_DIR = path.join(directory, "state");
  await fs.mkdir(path.join(root, ".git"), { recursive: true });
  const parent: ParentBoundary = {
    sessionId: "parent", transcriptPath: path.join(directory, "parent.jsonl"), startEntryId: null,
    model: { provider: model.provider, modelId: model.id, thinkingLevel: "off" },
  };
  const preparation = await owner.prepare(handoff, parent, "a".repeat(40), () => true, model);
  const peer = { editorId: "editor", sessionId: "parent", label: "Neovim" };
  return { owner, parent, preparation, peer };
}

type ParentMessage = {
  readonly content: Parameters<ExtensionAPI["sendMessage"]>[0]["content"];
  readonly options: Parameters<ExtensionAPI["sendMessage"]>[1];
};

type ParentHost = {
  readonly stateDirectory: string;
  readonly messages: readonly ParentMessage[];
  readonly notices: readonly string[];
  command(name: "review" | "review-done", args?: string): Promise<void>;
  prepare(callId: string): ReturnType<ToolDefinition["execute"]>;
};

async function createParentHost(t: TestContext): Promise<ParentHost> {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-finish-parent-"));
  const root = path.join(directory, "work");
  const stateDirectory = path.join(directory, "state");
  const previousState = process.env.PARLEY_STATE_DIR;
  const commands = new Map<string, Parameters<ExtensionAPI["registerCommand"]>[1]>();
  const tools = new Map<string, ToolDefinition>();
  const events = new Map<string, (_event: unknown, ctx: ExtensionContext) => Promise<void>>();
  const messages: ParentMessage[] = [];
  const notices: string[] = [];

  // Only the parent host is faked. Review owners, artifacts and sockets are real;
  // no model calls, tool dispatch or session switching are needed for empty reviews.
  const api = {
    registerFlag() {}, getFlag: () => "none", getThinkingLevel: () => "off",
    registerCommand: (name: string, command: Parameters<ExtensionAPI["registerCommand"]>[1]) => commands.set(name, command),
    registerTool: (tool: ToolDefinition) => tools.set(tool.name, tool),
    on: (name: string, handler: (_event: unknown, ctx: ExtensionContext) => Promise<void>) => events.set(name, handler),
    exec: async () => ({ code: 0, killed: false, stdout: "a".repeat(40), stderr: "" }),
    sendMessage: (message: Parameters<ExtensionAPI["sendMessage"]>[0], options: ParentMessage["options"]) => {
      messages.push({ content: message.content, options });
    },
  } as unknown as ExtensionAPI;
  const ctx = {
    cwd: root, mode: "tui", model, isIdle: () => true, hasPendingMessages: () => false,
    sessionManager: {
      getSessionId: () => "parent",
      getSessionFile: () => path.join(directory, "parent.jsonl"),
      getLeafId: () => null,
    },
    ui: { notify: (message: string) => notices.push(message), setStatus() {} },
  } as unknown as ExtensionCommandContext;

  async function event(name: "session_start" | "session_shutdown"): Promise<void> {
    const handler = events.get(name);
    assert(handler, `Event ${name} is registered`);
    await handler({ type: name }, ctx);
  }

  t.after(async () => {
    try {
      await event("session_shutdown");
    } finally {
      if (previousState === undefined) delete process.env.PARLEY_STATE_DIR;
      else process.env.PARLEY_STATE_DIR = previousState;
      await fs.rm(directory, { recursive: true, force: true });
    }
  });
  process.env.PARLEY_STATE_DIR = stateDirectory;
  await fs.mkdir(path.join(root, ".git"), { recursive: true });
  extension(api);
  await event("session_start");
  return {
    stateDirectory, messages, notices,
    async command(name, args = "") {
      const command = commands.get(name);
      assert(command, `Command ${name} is registered`);
      await command.handler(args, ctx);
    },
    async prepare(callId) {
      const tool = tools.get("parley_prepare");
      assert(tool, "Tool parley_prepare is registered");
      const toolContext: ExtensionToolContext = {
        ...ctx,
        tools: [],
        executeTool: async () => { throw new Error("Unexpected nested tool execution in parent fixture"); },
      };
      return tool.execute(callId, handoff, undefined, undefined, toolContext);
    },
  };
}

test("editor and parent Done share one durable completion, preserve evidence, and never regenerate", async t => {
  const { owner, parent, preparation, peer } = await createPreparedReview(t);
  const reviewId = preparation.reviewId;
  const begun = await owner.handle({
    action: "review-finish-begin", reviewId, peer, current: () => true,
    payload: { ...identity, finishId: "finish" },
  });
  assert.equal(begun.state, "wrapping");
  assert.equal(owner.beginParentFinish(reviewId, "another-finish", parent, () => true).finishId, "finish");

  const completion = await owner.waitForFinish(reviewId);
  assert.equal(completion.state, "completed", JSON.stringify(completion));
  const summary = completion.summary;
  assert(typeof summary === "string", "Completed reviews have a summary");
  assert.match(summary, /0 investigation\/Ask request/);
  assert.match(summary, /drafts are excluded and preserved/);
  assert.match(summary, /No usable reviewer summary/);
  const artifact = await readReviewArtifact(completion.artifactPath);
  assert.equal(artifact.end?.summary, summary);
  assert.deepEqual(artifact.requests.map(item => [item.record.kind, item.outcome?.status]), [["wrap-up", "completed"]]);
  assert.equal(artifact.sessions.length, 1, "Empty review must not construct an SDK reviewer");

  const savedEvidence = await fs.readFile(completion.artifactPath);
  assert.equal(owner.beginParentFinish(reviewId, "done-again", parent, () => true).summary, summary);
  const status = await owner.handle({
    action: "review-finish-status", reviewId, peer, current: () => true,
    payload: { ...identity, finishId: "finish" },
  });
  assert.equal(status.summary, summary);
  assert.deepEqual(await fs.readFile(completion.artifactPath), savedEvidence);
  assert.throws(() => owner.beginParentFinish(reviewId, "wrong-parent", { ...parent, transcriptPath: "other" }, () => true), /originating parent/);
  await assert.rejects(owner.prepare(handoff, parent, "b".repeat(40), () => true, model), /completed/);
  await assert.rejects(owner.handle({
    action: "review-batch-begin", reviewId, peer, current: () => true, payload: identity,
  }), /completed/);
  assert.throws(() => reviewWrapUpSummary(artifact, completion.artifactPath, "x".repeat(16 * 1024)), /16 KiB/);
});

test("Done rejects staging, records a pre-acceptance failure without ending, and diagnoses corruption without repair", async t => {
  const { owner, parent, preparation, peer } = await createPreparedReview(t);
  const reviewId = preparation.reviewId;
  let editorConnected = true;
  await owner.handle({
    action: "review-batch-begin", reviewId, peer, current: () => editorConnected,
    payload: { ...identity, batchId: "upload", digest: "a".repeat(64), bytes: 1, parts: 1, preparationId: preparation.id },
  });
  assert.throws(() => owner.beginParentFinish(reviewId, "busy", parent, () => true), /active or settling/);
  editorConnected = false; // Disconnected staging is not submitted history.

  let parentCurrent = true;
  owner.beginParentFinish(reviewId, "lost-before-acceptance", parent, () => parentCurrent);
  parentCurrent = false; // Invalidate the caller before finish accepts durable work.
  const failedCompletion = await owner.waitForFinish(reviewId);
  assert.equal(failedCompletion.state, "failed");
  assert.equal(owner.ended, false);
  assert.equal((await readReviewArtifact(failedCompletion.artifactPath)).requests.length, 0);

  const originalEvidence = await fs.readFile(failedCompletion.artifactPath);
  const corruptedEvidence = Buffer.concat([originalEvidence, Buffer.from('{"incomplete":')]);
  await fs.writeFile(failedCompletion.artifactPath, corruptedEvidence);
  owner.beginParentFinish(reviewId, "corrupt-evidence", parent, () => true);
  const corruptedCompletion = await owner.waitForFinish(reviewId);
  assert.equal(corruptedCompletion.state, "failed");
  assert(typeof corruptedCompletion.error === "string", "Corruption failures include a diagnostic");
  assert.match(corruptedCompletion.error, /incomplete|changed|size/i);
  assert.equal(owner.ended, false);
  assert.deepEqual(await fs.readFile(failedCompletion.artifactPath), corruptedEvidence);
});

test("/review creates empty reviews, starts a fresh identity after Done, and retains old summaries", async t => {
  const host = await createParentHost(t);
  const { messages, notices } = host;
  await host.command("review");
  await host.command("review-done");
  assert.equal(messages.length, 1, notices.join("\n"));
  const firstMessage = messages[0];
  assert(firstMessage && typeof firstMessage.content === "string", "Done delivers a text summary");
  assert.match(firstMessage.content, /# Review completed/);
  assert.deepEqual(firstMessage.options, { triggerTurn: false });

  const reviewsDirectory = path.join(host.stateDirectory, "reviews");
  const files = (await fs.readdir(reviewsDirectory)).filter(name => name.endsWith(".jsonl"));
  assert.equal(files.length, 1, "/review creates one durable context-free review");
  const [firstArtifactFilename] = files;
  assert(firstArtifactFilename, "The completed review has an artifact");
  const firstArtifact = await readReviewArtifact(path.join(reviewsDirectory, firstArtifactFilename));
  assert.equal(firstArtifact.end?.summary, firstMessage.content);

  await host.command("review");
  await host.prepare("optional-handoff");
  assert.equal(messages.length, 1, "Fresh review and optional handoff do not inject a parent summary");
  await host.command("review-done");
  assert.equal(messages.length, 2);
  assert.notEqual(firstMessage.content, messages[1].content);
  await host.command("review-done", firstArtifact.header.id);
  assert.equal(messages.length, 3);
  assert.equal(messages[2].content, firstMessage.content);
  assert(!notices.some(message => /requires|failed|unavailable/i.test(message)), notices.join("\n"));
});
