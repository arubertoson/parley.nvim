import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { Connection } from "../pi/connection.ts";
import { workspaceKey, ReviewStore, readWorkspacePreparationModel, saveWorkspacePreparationModel, type Review, type Request, type Note } from "../pi/state.ts";
import { capture, discover } from "../pi/review-vcs.ts";
import { TurnRunner, replyPrompt } from "../pi/turns.ts";
import extension from "../pi/extension.ts";
import { boundedSession, sessionFromBranch, prepareContext, type PreparationInput, type PreparationProgress } from "../pi/preparation.ts";
import { parseFindings } from "../pi/turns.ts";
import { createHash } from "node:crypto";

const exec = promisify(execFile);
async function fixture(t: test.TestContext) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "parley-test-"));
  const root = path.join(dir, "work"), state = path.join(dir, "state");
  await fs.mkdir(root);
  const git = (...args: string[]) => exec("git", args, { cwd: root });
  await git("init", "-q"); await git("config", "user.name", "Test"); await git("config", "user.email", "test@example.invalid");
  await fs.writeFile(path.join(root, "code.txt"), "before\nstable\n");
  await git("add", "."); await git("commit", "-qm", "base");
  await fs.writeFile(path.join(root, "code.txt"), "after\nstable\n");
  const cleanup: (() => unknown | Promise<unknown>)[] = [];
  t.after(async () => {
    try { for (const close of cleanup.reverse()) await close(); }
    finally { await fs.rm(dir, { recursive: true, force: true }); }
  });
  return { dir, root, state, git, cleanup };
}
async function owner(t: test.TestContext) {
  const f = await fixture(t);
  const connection = new Connection(f.state, f.root);
  await connection.start();
  f.cleanup.push(() => connection.stop());
  const record = await connection.store.create(await capture(await discover(f.root), { kind: "working" }), "Curated seed, not session history");
  const note: Note = { id: "human-1", text: "Why this change?", target: { path: "code.txt", side: "new", first: 1, last: 1, scope: "line", context: ["after"] } };
  const handle = (action: Request["action"], version: number, payload = {}, requestId = action + "-request") => connection.serial(() => connection.store.handle({ version: 1, requestId, action, reviewId: record.id, payload: { expectedVersion: version, ...payload } })) as Promise<Review>;
  return { ...f, connection, record, note, handle };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(yes => { resolve = yes; });
  return { resolve, promise };
}

test("staged and working scopes freeze distinct bytes; reopening never resnapshots", async t => {
  const f = await fixture(t);
  await f.git("add", ".");
  await fs.writeFile(path.join(f.root, "code.txt"), "later\nstable\n");
  await fs.writeFile(path.join(f.root, "untracked.txt"), "new\r\n");
  const repo = await discover(f.root);
  const staged = await capture(repo, { kind: "staged" });
  const working = await capture(repo, { kind: "working" });
  assert.equal(staged.files[0].new, "after\nstable\n");
  assert.equal(working.files[0].new, "later\nstable\n");
  assert.equal(working.files[1].new_fileformat, "dos");
  const connection = new Connection(f.state, f.root); await connection.start(); f.cleanup.push(() => connection.stop());
  const review = await connection.store.create(staged, "seed");
  await fs.writeFile(path.join(f.root, "code.txt"), "changed again\n");
  assert.deepEqual((await connection.store.read(review.id)).files, staged.files);
  await fs.symlink("code.txt", path.join(f.root, "link"));
  await assert.rejects(capture(repo, { kind: "working" }), /regular files/);
});

test("jj freezes an explicit revision pair without checkout or later working-copy refresh", async t => {
  const f = await fixture(t);
  await exec("jj", ["git", "init", "--colocate"], { cwd: f.root });
  const repo = await discover(f.root);
  assert.equal(repo.vcs, "jj");
  const snapshot = await capture(repo, { kind: "range", from: "@-", to: "@" });
  assert.equal(snapshot.files[0].old, "before\nstable\n");
  assert.equal(snapshot.files[0].new, "after\nstable\n");
  await fs.writeFile(path.join(f.root, "code.txt"), "later\n");
  assert.equal(snapshot.files[0].new, "after\nstable\n");
});

test("acknowledged saves do not submit; explicit turns freeze notes and reject stale writes", async t => {
  const f = await owner(t);
  let review = await f.handle("save", 1, { notes: [f.note] });
  assert.equal(review.turns.length, 0);
  assert.equal((await f.handle("save", 1, { notes: [f.note] })).version, review.version); // Receipt retry.
  await assert.rejects(f.handle("save", 1, { notes: [] }, "stale"), /changed/);
  await assert.rejects(f.handle("save", review.version, { notes: [{ ...f.note, target: { ...f.note.target, context: ["wrong"] } }] }, "bad"), /context/);
  review = await f.handle("submit", review.version, { turnId: "turn-1" });
  await assert.rejects(f.handle("save", review.version, { notes: [] }, "during-agent"), /pending/);
  const original = structuredClone(review.turns[0].notes);
  let available = false, calls = 0;
  const runner = new TurnRunner(f.connection, () => available, async (record, turn) => {
    calls++; assert.equal(record.seed, "Curated seed, not session history");
    assert(!replyPrompt(record, turn).includes("implementation conversation"));
    return JSON.stringify(turn.notes.map(note => ({ replyTo: note.id, text: "Reasoned reply" })));
  }, () => {});
  f.cleanup.push(() => runner.stop());
  runner.kick(); assert.equal(runner.active, undefined);
  available = true; runner.kick(); await runner.active;
  assert.equal(calls, 1);
  review = await f.connection.store.read(review.id);
  assert.equal(review.turns[0].status, "complete");
  const reply = review.turns[0].replies[0];
  const followUp = { ...f.note, id: "human-2", text: "Follow-up", replyTo: reply.id };
  review = await f.handle("save", review.version, { notes: [followUp] }, "follow-up");
  assert.deepEqual(review.turns[0].notes, original);
  review = await f.handle("submit", review.version, { turnId: "turn-2" }, "submit-follow-up");
  runner.kick(); await runner.active;
  review = await f.connection.store.read(review.id);
  await assert.rejects(f.handle("save", review.version, { notes: [{ ...followUp, replyTo: undefined }] }, "retarget"), /reply relationship/);
  review = await f.handle("close", review.version);
  assert.equal((await f.connection.store.read(review.id)).status, "closed");
  assert.equal(review.turns[0].replies[0].text, "Reasoned reply");
});

test("turn acquisition rechecks availability, and shutdown aborts without closing the review", async t => {
  const f = await owner(t);
  let record = await f.handle("save", 1, { notes: [f.note] });
  record = await f.handle("submit", record.version, { turnId: "turn-1" });
  let available = true, calls = 0;
  const gate = deferred<void>(), entered = deferred<void>();
  const blocking = f.connection.serial(() => gate.promise);
  const runner = new TurnRunner(f.connection, () => available, async (_review, _turn, signal) => {
    calls++; entered.resolve();
    return new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true }));
  }, () => {});
  runner.kick(); available = false; gate.resolve(); await blocking; await runner.active;
  assert.equal(calls, 0);
  assert.equal((await f.connection.store.read(record.id)).turns[0].status, "queued");
  available = true; runner.kick(); await entered.promise;
  await runner.stop();
  record = await f.connection.store.read(record.id);
  assert.equal(record.status, "open"); assert.equal(record.turns[0].status, "error");
});

test("queued reviews remain explicitly routed when a submission arrives during an active turn", async t => {
  const f = await owner(t);
  let first = await f.handle("save", 1, { notes: [f.note] });
  first = await f.handle("submit", first.version, { turnId: "first-turn" });
  const entered = deferred<void>(), release = deferred<void>(), secondEntered = deferred<void>();
  const seen: string[] = [];
  const runner = new TurnRunner(f.connection, () => true, async (review, turn) => {
    seen.push(review.id);
    if (review.id === first.id) { entered.resolve(); await release.promise; }
    else secondEntered.resolve();
    return JSON.stringify(turn.notes.map(note => ({ replyTo: note.id, text: `Reply for ${review.id}` })));
  }, () => {});
  f.cleanup.push(() => runner.stop());
  runner.kick(); await entered.promise;
  let second = await f.connection.serial(() => f.connection.store.create(f.record, "Independent seed"));
  second = await f.connection.serial(() => f.connection.store.handle({ version: 1, requestId: "second-save", action: "save", reviewId: second.id, payload: { expectedVersion: second.version, notes: [{ ...f.note, id: "second-note" }] } })) as Review;
  await f.connection.serial(() => f.connection.store.handle({ version: 1, requestId: "second-submit", action: "submit", reviewId: second.id, payload: { expectedVersion: second.version, turnId: "second-turn" } }));
  runner.kick(); release.resolve();
  await secondEntered.promise; await runner.active;
  assert.deepEqual(seen, [first.id, second.id]);
  const [savedFirst, savedSecond] = await Promise.all([f.connection.store.read(first.id), f.connection.store.read(second.id)]);
  assert.equal(savedFirst.turns[0].replies[0].replyTo, "human-1");
  assert.equal(savedSecond.turns[0].replies[0].replyTo, "second-note");
  assert.equal(savedSecond.seed, "Independent seed");
});

test("malformed agent relationships fail the turn without changing frozen code or closing the review", async t => {
  const f = await owner(t);
  let record = await f.handle("save", 1, { notes: [f.note] });
  record = await f.handle("submit", record.version, { turnId: "bad-reply" });
  const runner = new TurnRunner(f.connection, () => true, async () => '[{"replyTo":"another-review-note","text":"Invalid"}]', () => {});
  f.cleanup.push(() => runner.stop());
  runner.kick(); await runner.active;
  const saved = await f.connection.store.read(record.id);
  assert.equal(saved.turns[0].status, "error");
  assert.match(saved.turns[0].error!, /reply relationship/);
  assert.deepEqual(saved.turns[0].replies, []);
  assert.deepEqual(saved.files, record.files);
  assert.deepEqual(saved.notes, record.notes);
  assert.equal(saved.status, "open");
});

test("workspace lease excludes a second owner; recovery marks interrupted turns, retaining frozen contents", async t => {
  const f = await owner(t);
  const second = new Connection(f.state, f.root);
  await assert.rejects(second.start(), /live Parley Pi owner/);
  let record = await f.handle("save", 1, { notes: [f.note] });
  record = await f.handle("submit", record.version, { turnId: "interrupted" });
  await Promise.all([f.connection.stop(), f.connection.stop()]);
  const replacement = new Connection(f.state, f.root); await replacement.start(); f.cleanup.push(() => replacement.stop());
  const recovered = await replacement.store.read(record.id);
  assert.equal(recovered.status, "open"); assert.equal(recovered.turns[0].status, "error");
  assert.deepEqual(recovered.files, record.files);
});

test("Unix socket rejects malformed or misrouted messages and acknowledges explicit request IDs", async t => {
  const f = await owner(t);
  const descriptor = JSON.parse(await fs.readFile(path.join(f.state, "endpoints", workspaceKey(f.root) + ".json"), "utf8"));
  const socket = net.createConnection(descriptor.socket); f.cleanup.push(() => socket.destroy()); socket.setEncoding("utf8");
  await new Promise<void>((yes, no) => { socket.once("connect", yes); socket.once("error", no); });
  const responses: any[] = [], ready = deferred<void>();
  let buffer = "";
  socket.on("data", data => {
    buffer += data;
    while (buffer.includes("\n")) {
      const end = buffer.indexOf("\n"); responses.push(JSON.parse(buffer.slice(0, end))); buffer = buffer.slice(end + 1);
      if (responses.length === 3) ready.resolve();
    }
  });
  socket.write(JSON.stringify({ version: 2, requestId: "wrong-version", action: "read", reviewId: f.record.id }) + "\n");
  socket.write(JSON.stringify({ version: 1, requestId: "wrong-root", action: "list", workspace: "/elsewhere" }) + "\n");
  const message = JSON.stringify({ version: 1, requestId: "read", action: "read", reviewId: f.record.id }) + "\n";
  socket.write(message.slice(0, 8)); socket.write(message.slice(8));
  await ready.promise;
  assert.deepEqual(responses.map(r => [r.requestId, r.ok]), [["wrong-version", false], ["wrong-root", false], ["read", true]]);
  assert.equal(responses[2].result.id, f.record.id);
});

test("Pi review creation returns; implementation waits only for an already-running isolated review turn", async t => {
  const f = await fixture(t);
  const previous = process.env.PARLEY_STATE_DIR;
  process.env.PARLEY_STATE_DIR = f.state;
  f.cleanup.push(() => { if (previous === undefined) delete process.env.PARLEY_STATE_DIR; else process.env.PARLEY_STATE_DIR = previous; });
  const hooks = new Map<string, Function>(), commands = new Map<string, any>();
  extension({ registerFlag() {}, getFlag() {}, on: (event: string, handler: Function) => hooks.set(event, handler), registerCommand: (name: string, definition: any) => commands.set(name, definition) } as any);
  const entered = deferred<void>(), result = deferred<any>();
  let calls = 0, idle = true, received: any;
  const context = {
    cwd: f.root, mode: "tui", model: { contextWindow: 100_000 },
    isIdle: () => idle, hasPendingMessages: () => false,
    ui: { notify() {}, select: async (prompt: string, choices: string[]) => choices[prompt.includes("Git") || prompt.startsWith("Create frozen review") ? 1 : 0], editor: async () => "Only curated seed" },
    modelRegistry: { streamSimple: (_model: unknown, transcript: any) => {
      calls++; received = transcript; entered.resolve(); return { result: () => result.promise };
    } },
  };
  await hooks.get("session_start")!({}, context);
  f.cleanup.push(() => hooks.get("session_shutdown")!({ reason: "quit" }, context));
  await commands.get("review").handler("", context);
  assert.equal(calls, 0);
  const store = new ReviewStore(f.state, f.root), list = await store.list();
  assert.equal(list.length, 1);
  const descriptor = JSON.parse(await fs.readFile(path.join(f.state, "endpoints", workspaceKey(f.root) + ".json"), "utf8"));
  const request = async (action: string, payload: unknown): Promise<Review> => {
    const socket = net.createConnection(descriptor.socket); socket.setEncoding("utf8");
    try {
      await new Promise<void>((yes, no) => { socket.once("connect", yes); socket.once("error", no); });
      const ack = new Promise<Review>((yes, no) => {
        let buffer = "";
        socket.on("data", chunk => { buffer += chunk; if (buffer.includes("\n")) { const response = JSON.parse(buffer); response.ok ? yes(response.result) : no(new Error(response.error)); } });
        socket.on("error", no);
      });
      socket.write(JSON.stringify({ version: 1, requestId: action, reviewId: list[0].id, action, payload }) + "\n");
      return await ack;
    } finally { socket.destroy(); }
  };
  let record = await request("save", { expectedVersion: 1, notes: [{ id: "note", text: "Discuss", target: { path: "code.txt", side: "new", first: 1, last: 1, scope: "line", context: ["after"] } }] });
  assert.equal(calls, 0);
  record = await request("submit", { expectedVersion: record.version, turnId: "turn" });
  await entered.promise;
  assert.equal(received.messages.length, 1); assert.equal(JSON.parse(received.messages[0].content).seed, "Only curated seed");
  assert.equal(received.tools, undefined);
  let codingStarted = false;
  idle = false;
  const coding = hooks.get("before_agent_start")!({}, context).then(() => { codingStarted = true; });
  await new Promise<void>(yes => setImmediate(yes)); assert.equal(codingStarted, false);
  result.resolve({ stopReason: "stop", content: [{ type: "text", text: '[{"replyTo":"note","text":"Discussed"}]' }] });
  await coding;
  assert.equal((await store.read(record.id)).turns[0].status, "complete");
  idle = true; hooks.get("agent_settled")!({}, context);
});

for (const phase of ["discovery", "confirmation"]) {
  test(`Pi shutdown during review ${phase} cannot publish a late owner or review`, async t => {
    const f = await fixture(t);
    const previous = process.env.PARLEY_STATE_DIR;
    process.env.PARLEY_STATE_DIR = f.state;
    f.cleanup.push(() => { if (previous === undefined) delete process.env.PARLEY_STATE_DIR; else process.env.PARLEY_STATE_DIR = previous; });
    const hooks = new Map<string, Function>(), commands = new Map<string, any>();
    extension({ registerFlag() {}, getFlag() {}, on: (event: string, handler: Function) => hooks.set(event, handler), registerCommand: (name: string, definition: any) => commands.set(name, definition) } as any);
    const confirming = deferred<void>(), confirmation = deferred<boolean>();
    const context = {
      cwd: f.root, mode: "tui", isIdle: () => true, hasPendingMessages: () => false,
      ui: { notify() {}, select: async (prompt: string, choices: string[]) => {
        if (prompt.startsWith("Create frozen review")) { confirming.resolve(); await confirmation.promise; return choices[1]; }
        return choices[prompt.includes("Git") ? 1 : 0];
      }, editor: async () => "Seed" },
    };
    await hooks.get("session_start")!({}, context);
    f.cleanup.push(() => hooks.get("session_shutdown")!({}, context));
    const creation = commands.get("review").handler("", context);
    if (phase === "confirmation") await confirming.promise;
    await hooks.get("session_shutdown")!({}, context);
    confirmation.resolve(true);
    await creation;
    assert.deepEqual(await new ReviewStore(f.state, f.root).list(), []);
    const descriptors = await fs.readdir(path.join(f.state, "endpoints")).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return []; throw error; });
    assert.deepEqual(descriptors, []);
  });
}

test("Neovim attaches workspace buffers, saves without submitting, displays replies and retains edits on reattach", async t => {
  const f = await owner(t);
  await fs.writeFile(path.join(f.root, "code.txt"), "implementation moved on\n");
  const script = path.join(f.dir, "editor.lua");
  await fs.writeFile(script, `
vim.opt.runtimepath:append(${JSON.stringify(process.cwd())})
vim.api.nvim_set_current_dir(${JSON.stringify(f.root)})
vim.o.lines, vim.o.columns = 40, 100
vim.ui.select = function(items, _, done) done(items[1]) end
vim.cmd.edit('code.txt')
local original = vim.api.nvim_get_current_buf()
local parley, composer = require('parley'), require('parley.composer')
local function wait(test) assert(vim.wait(8000, test, 10), vim.api.nvim_exec2('messages', { output = true }).output) end
parley.start()
wait(function() return parley.active_window() ~= nil end)
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'implementation moved on')
assert(vim.bo.modifiable)
parley.comment('line')
wait(function() return composer.current_item() ~= nil end)
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'Human comment'})
vim.cmd.stopinsert()
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
wait(function() return #composer.comments == 1 and composer.current_item() == nil end)
vim.wait(1000, function() return false end, 10)
parley.submit()
wait(function()
  local note = composer.comments[1]
  return note.replies and #note.replies == 1
end)
assert(composer.comments[1].replies[1].text == 'Editor reply')
parley.stop()
assert(vim.api.nvim_get_current_buf() == original)
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'implementation moved on')
vim.wait(300, function() return false end, 10)
parley.start()
wait(function() return parley.active_window() ~= nil end)
assert(#composer.comments == 1)
assert(composer.comments[1].lines[1] == 'Human comment')
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'implementation moved on')
parley.move_note(1)
vim.ui.select = function(items, _, done) done(items[#items]) end
parley.reply()
wait(function() return composer.current_item() ~= nil end)
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'Explicit follow-up'})
vim.cmd.stopinsert()
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
wait(function() return #composer.comments == 2 and composer.current_item() == nil end)
parley.save()
vim.wait(500, function() return false end, 10)
parley.stop()
vim.cmd('qa!')
`);
  let calls = 0;
  const runner = new TurnRunner(f.connection, () => true, async (_record, turn) => {
    calls++;
    return JSON.stringify(turn.notes.map(note => ({ replyTo: note.id, text: "Editor reply" })));
  }, () => {});
  f.connection.onSubmit = () => runner.kick(); f.cleanup.push(() => runner.stop());
  const result = await exec("nvim", ["--headless", "--noplugin", "-u", "NONE", "-l", script], {
    env: { ...process.env, PARLEY_STATE_DIR: f.state }, timeout: 20_000,
  });
  assert(!result.stderr.includes("Error"), result.stderr);
  let record = await f.connection.store.read(f.record.id);
  assert.equal(calls, 1); assert.equal(record.turns.length, 1);
  assert.equal(record.notes[0].text, "Human comment"); assert.equal(record.status, "open");
  assert.equal(record.notes[1].replyTo, record.turns[0].replies[0].id);
  await fs.writeFile(script, `
vim.opt.runtimepath:append(${JSON.stringify(process.cwd())})
vim.api.nvim_set_current_dir(${JSON.stringify(f.root)})
vim.o.lines, vim.o.columns = 40, 100
vim.ui.select = function(items, _, done) done(items[1]) end
vim.cmd.edit('code.txt')
local parley, composer = require('parley'), require('parley.composer')
parley.start()
assert(vim.wait(8000, function() return parley.active_window() ~= nil end, 10))
assert(#composer.comments == 2)
assert(composer.comments[2].reply_to == ${JSON.stringify(record.notes[1].replyTo)})
assert(composer.comments[1].replies[1].text == 'Editor reply')
parley.move_note(1)
parley.move_note(1)
parley.edit_note()
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'Edited follow-up'})
vim.cmd.stopinsert()
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(8000, function() return composer.current_item() == nil end, 10))
parley.save()
vim.wait(500, function() return false end, 10)
parley.stop()
vim.cmd('qa!')
`);
  await exec("nvim", ["--headless", "--noplugin", "-u", "NONE", "-l", script], { env: { ...process.env, PARLEY_STATE_DIR: f.state }, timeout: 20_000 });
  record = await f.connection.store.read(f.record.id);
  assert.equal(record.notes[1].text, "Edited follow-up");
  assert.equal(record.notes[1].replyTo, record.turns[0].replies[0].id);
  assert.equal(calls, 1);
});

test("session sharing respects the active branch's compaction/redactions and bounded text-only projection", () => {
  const excerpt = sessionFromBranch([
    { id: "old", type: "message", message: { role: "user", content: "Old private text" } },
    { id: "kept", type: "message", message: { role: "user", content: "Redacted original" } },
    { id: "compact", type: "compaction", summary: "Implementation intent", firstKeptEntryId: "kept" },
    { id: "edit", type: "context_edit", targetId: "kept", replacement: "Edited public text" },
    { id: "tool", type: "message", message: { role: "toolResult", content: [{ type: "text", text: "Tool secret" }] } },
    { id: "assistant", type: "message", message: { role: "assistant", content: [{ type: "thinking", thinking: "Secret thinking" }, { type: "text", text: "Relevant decision" }, { type: "toolCall", arguments: { secret: "Tool input" } }] } },
    { id: "hidden", type: "message", message: { role: "user", content: "Hidden private text" } },
    { id: "hide", type: "context_edit", targetId: "hidden", replacement: null },
    { id: "branch", type: "branch_summary", summary: "Abandoned branch" },
  ], "session", "hide");
  assert.deepEqual(excerpt.messages.map(m => m.text), ["Implementation intent", "Edited public text", "Relevant decision"]);
  assert.equal(excerpt.sessionId, "session");
  assert(!JSON.stringify(excerpt).includes("private"));
  const bounded = boundedSession(Array.from({ length: 30 }, (_, n) => ({ role: "user", content: `${n}:` + "x".repeat(10_000) })));
  assert(bounded.truncated && bounded.omitted > 0);
  assert(bounded.messages.length <= 16 && bounded.messages.reduce((n, m) => n + m.text.length, 0) <= 32_000);
});

test("preparation selects only catalogued Markdown guidelines/references, confines reads, and freezes provenance", async t => {
  const f = await fixture(t), skillDir = path.join(f.dir, "skill");
  await fs.mkdir(path.join(skillDir, "references"), { recursive: true });
  const skillFile = path.join(skillDir, "SKILL.md"), styleFile = path.join(skillDir, "references/style.md");
  const skillText = "Review style: references/style.md. Also ../outside.md, linked.md, huge.md, code.ts and unmentioned.md are not review authority.";
  await fs.writeFile(skillFile, skillText);
  await fs.writeFile(styleFile, "Review immutable buffers. More detail: more.md");
  await fs.writeFile(path.join(skillDir, "references/more.md"), "Preserve draft state.");
  await fs.writeFile(path.join(f.dir, "outside.md"), "Outside secret");
  await fs.symlink(path.join(f.dir, "outside.md"), path.join(skillDir, "linked.md"));
  await fs.writeFile(path.join(skillDir, "huge.md"), "x".repeat(64_001));
  const input: PreparationInput = { model: "test/fast", session: boundedSession([{ role: "user", content: "Preserve drafts" }]), skills: [{ name: "review", description: "Review conventions", filePath: skillFile }], omittedSkills: 0 };
  const requests = [
    [{ skill: "review", path: "SKILL.md" }],
    ["references/style.md", "../outside.md", "linked.md", "huge.md", "code.ts", "unknown.md"].map(path => ({ skill: "review", path })),
    [{ skill: "review", path: "references/more.md" }, { skill: "absent", path: "SKILL.md" }], [],
  ];
  let calls = 0;
  const prepared = await prepareContext(input, { scope: "frozen", seed: "Human curation", files: [] }, async (_system, prompt) => {
    const data = JSON.parse(prompt);
    assert.equal(data.seed, "Human curation");
    assert(!prompt.includes("Outside secret"));
    return JSON.stringify({ summary: "Intent: preserve drafts", read: requests[calls++], limitations: [] });
  }, new AbortController().signal);
  assert.equal(calls, 4);
  assert.deepEqual(prepared.guidelines.map(g => path.basename(g.path)), ["SKILL.md", "style.md", "more.md"]);
  assert.equal(prepared.guidelines[0].sha256, createHash("sha256").update(skillText).digest("hex"));
  assert(prepared.limitations.some(l => l.includes("escapes")));
  assert(prepared.limitations.some(l => l.includes("not mentioned")));
  assert(prepared.limitations.some(l => l.includes("regular Markdown")));
  await fs.writeFile(skillFile, "New guidelines");
  assert.equal(prepared.guidelines[0].content, skillText);
  await assert.rejects(prepareContext(input, { scope: "x", seed: "", files: [] }, async () => "{}", new AbortController().signal), /Invalid preparation/);
  const cancelled = new AbortController(); cancelled.abort();
  await assert.rejects(prepareContext(input, { scope: "x", seed: "", files: [] }, async () => { throw new Error("Should not call"); }, cancelled.signal), /abort/i);
});

test("interrupted preparation freezes each completed document and resumes pending reads with cumulative budgets", async t => {
  const f = await owner(t), skillDir = path.join(f.dir, "skill");
  await fs.mkdir(skillDir);
  const skillFile = path.join(skillDir, "SKILL.md"), original = "style.md extra.md\n".padEnd(60_000, "x");
  await fs.writeFile(skillFile, original);
  await fs.writeFile(path.join(skillDir, "style.md"), "y".repeat(60_000));
  await fs.writeFile(path.join(skillDir, "extra.md"), "z");
  const input: PreparationInput = { model: "test/fast", session: boundedSession([]), skills: [{ name: "review", description: "Review conventions", filePath: skillFile }], omittedSkills: 0 };
  const record = await f.connection.store.create(f.record, "Human focus", input);
  const cancelled = new AbortController();
  const checkpoint = (progress: PreparationProgress) => f.connection.serial(async () => {
    const current = await f.connection.store.read(record.id);
    current.preparation!.progress = structuredClone(progress);
    await f.connection.store.write(current);
    if (progress.guidelines.length === 1 && progress.pending.length === 2) cancelled.abort();
  });
  await assert.rejects(prepareContext(input, record, async () => JSON.stringify({ summary: "Frozen intent", read: ["SKILL.md", "style.md", "extra.md"].map(path => ({ skill: "review", path })), limitations: [] }), cancelled.signal, undefined, checkpoint), /abort/i);
  await fs.writeFile(skillFile, "Changed guidelines; do not silently reread");
  const reopened = await new ReviewStore(f.state, f.root).read(record.id);
  assert.equal(reopened.preparation!.progress!.guidelines[0].content, original);
  assert.deepEqual(reopened.preparation!.progress!.pending.map(r => r.path), ["style.md", "extra.md"]);
  let calls = 0;
  const prepared = await prepareContext(input, reopened, async (_system, prompt) => {
    calls++;
    const context = JSON.parse(prompt);
    assert.equal(context.guidelines[0].content, original);
    assert(!prompt.includes("Changed guidelines"));
    return JSON.stringify({ summary: "Frozen intent", read: context.final ? [] : [{ skill: "review", path: "SKILL.md" }], limitations: [] });
  }, new AbortController().signal, reopened.preparation!.progress, checkpoint);
  assert.equal(calls, 4); // Only the remaining rounds; retry does not reset the budget.
  assert.deepEqual(prepared.guidelines.map(g => path.basename(g.path)), ["SKILL.md", "style.md"]);
  assert(prepared.limitations.some(l => l.includes("budget exceeded")));
  assert(prepared.limitations.some(l => l.includes("No implementation-session text")));
  assert.equal((await f.connection.store.read(record.id)).seed, "Human focus");
});

test("initial preparation/finding turns wait for availability, checkpoint context and discuss explicit finding IDs", async t => {
  const f = await owner(t);
  const input: PreparationInput = { model: "test/fast", session: boundedSession([{ role: "user", content: "Implementation intent" }]), skills: [], omittedSkills: 0 };
  let record = await f.connection.store.create(f.record, "Human focus", input);
  let available = false, preparations = 0, calls = 0;
  const packet = { model: "test/fast", summary: "Intent", guidelines: [], limitations: ["No supporting code"] };
  const runner = new TurnRunner(f.connection, () => available, async (review, turn) => {
    calls++;
    assert.deepEqual(review.preparation!.context, packet);
    assert(!replyPrompt(review, turn).includes("Implementation intent")); // Raw excerpt is preparation-only.
    if (turn.kind === "initial") return '[{"path":"code.txt","side":"new","first":1,"last":1,"text":"Concrete issue"}]';
    return JSON.stringify(turn.notes.map(note => ({ replyTo: note.id, text: "Discussion" })));
  }, () => {}, async () => { preparations++; available = false; return packet; });
  f.cleanup.push(() => runner.stop());
  runner.kick(); assert.equal(runner.active, undefined); assert.equal(preparations, 0);
  available = true; runner.kick(); await runner.active;
  record = await f.connection.store.read(record.id);
  assert.equal(record.turns[0].status, "queued"); assert.equal(calls, 0); assert.deepEqual(record.preparation!.context, packet);
  available = true; runner.kick(); await runner.active;
  record = await f.connection.store.read(record.id);
  assert.equal(preparations, 1); assert.equal(record.turns[0].status, "complete"); assert.deepEqual(record.notes, []);
  const finding = record.turns[0].findings![0]; assert.equal(finding.author, "agent"); assert.match(finding.id, /^[\da-f-]{36}$/);
  await assert.rejects(f.connection.store.handle({ version: 1, requestId: "forged-finding", action: "save", reviewId: record.id,
    payload: { expectedVersion: record.version, notes: [{ ...f.note, id: finding.id }] } }), /cannot reuse an agent/);
  await fs.writeFile(path.join(f.root, "code.txt"), "Implementation has moved on\n");
  const mutate = (action: Request["action"], payload: Request["payload"]) => f.connection.serial(() => f.connection.store.handle({ version: 1, requestId: "initial-" + action, reviewId: record.id, action, payload: { expectedVersion: record.version, ...payload } })) as Promise<Review>;
  record = await mutate("save", { notes: [{ ...f.note, replyTo: finding.id }] });
  record = await mutate("submit", { turnId: "discussion" });
  runner.kick(); await runner.active;
  record = await f.connection.store.read(record.id);
  assert.equal(preparations, 1); assert.equal(record.turns[1].replies[0].replyTo, f.note.id);
  assert.deepEqual(record.turns[0].findings![0], finding);
  await assert.rejects(f.connection.store.handle({ version: 1, requestId: "forged-reply", action: "save", reviewId: record.id,
    payload: { expectedVersion: record.version, notes: [{ ...f.note, id: record.turns[1].replies[0].id }] } }), /cannot reuse an agent/);
  assert.equal(record.seed, "Human focus"); assert.equal(record.files[0].new, "after\nstable\n");
});

test("invalid initial anchors fail closed; explicit retry reuses the frozen prepared packet and allows no findings", async t => {
  const f = await owner(t);
  let record = await f.connection.store.create(f.record, "", { model: "test/fast", session: boundedSession([]), skills: [], omittedSkills: 0 });
  let preparations = 0, bad = true;
  const runner = new TurnRunner(f.connection, () => true, async () => bad ? '[{"path":"code.txt","side":"new","first":30,"last":30,"text":"Invalid"}]' : "[]", () => {}, async () => {
    preparations++; return { model: "test/fast", summary: "Frozen", guidelines: [], limitations: [] };
  });
  f.cleanup.push(() => runner.stop()); runner.kick(); await runner.active;
  record = await f.connection.store.read(record.id);
  assert.equal(record.turns[0].status, "error"); assert.match(record.turns[0].error!, /outside frozen text/);
  assert.equal(record.status, "open"); assert.deepEqual(record.turns[0].findings, []);
  for (const finding of [ { path: "outside", side: "new", first: 1, last: 1 }, { path: "code.txt", side: "wrong", first: 1, last: 1 }, { path: "code.txt", side: "new", first: 0, last: 1 } ]) {
    assert.throws(() => parseFindings(JSON.stringify([{ ...finding, text: "Invalid" }]), record));
  }
  bad = false;
  await f.connection.serial(() => f.connection.store.handle({ version: 1, action: "submit", requestId: "retry-initial", reviewId: record.id, payload: { expectedVersion: record.version, turnId: "retry-initial", kind: "initial" } }));
  runner.kick(); await runner.active;
  record = await f.connection.store.read(record.id);
  assert.equal(preparations, 1); assert.equal(record.turns[1].status, "complete"); assert.deepEqual(record.turns[1].findings, []);
  await assert.rejects(f.connection.store.handle({ version: 1, action: "submit", requestId: "again", reviewId: record.id, payload: { expectedVersion: record.version, turnId: "again", kind: "initial" } }), /No failed initial/);
  await f.handle("close", f.record.version);
  const script = path.join(f.dir, "no-findings.lua");
  await fs.writeFile(script, `
vim.opt.runtimepath:append(${JSON.stringify(process.cwd())})
vim.api.nvim_set_current_dir(${JSON.stringify(f.root)})
vim.o.lines, vim.o.columns = 40, 100
vim.ui.select = function(items, _, done) done(items[1]) end
vim.cmd.edit('code.txt')
local parley, composer = require('parley'), require('parley.composer')
parley.start()
assert(vim.wait(8000, function() return parley.status():find('no agent findings', 1, true) ~= nil end, 10))
assert(#composer.findings == 0 and #composer.comments == 0)
parley.stop()
vim.cmd('qa!')
`);
  await exec("nvim", ["--headless", "--noplugin", "-u", "NONE", "-l", script], { env: { ...process.env, PARLEY_STATE_DIR: f.state }, timeout: 15_000 });
  assert.equal((await f.connection.store.read(record.id)).turns.length, 2);
});

test("freeze-only needs no preparation model or selection and shares no session", async t => {
  const f = await fixture(t);
  for (const [key, value] of Object.entries({ PARLEY_STATE_DIR: f.state, PARLEY_PREPARATION_MODEL: undefined })) {
    const previous = process.env[key];
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
    f.cleanup.push(() => { if (previous === undefined) delete process.env[key]; else process.env[key] = previous; });
  }
  const hooks = new Map<string, Function>(), commands = new Map<string, any>(), notifications: string[] = [];
  extension({ registerFlag() {}, getFlag: () => undefined, on: (name: string, hook: Function) => hooks.set(name, hook), registerCommand: (name: string, command: unknown) => commands.set(name, command) } as any);
  const unexpected = () => { throw new Error("Freeze-only must not share context or call models"); };
  const ctx = { cwd: f.root, mode: "tui", model: { provider: "test", id: "implementation" }, isIdle: () => false, hasPendingMessages: () => false,
    modelRegistry: { find: unexpected, getAvailable: unexpected, streamSimple: unexpected }, getSystemPromptOptions: unexpected, sessionManager: { getBranch: unexpected },
    ui: { notify: (message: string) => notifications.push(message), editor: async (_title: string, value: string) => value,
      select: async (title: string, choices: string[]) => { if (title.includes("Git")) return choices[1]; assert(title.includes("choose a workspace default once")); return choices[1]; } },
  };
  await hooks.get("session_start")!({}, ctx);
  f.cleanup.push(() => hooks.get("session_shutdown")!({}, ctx));
  const store = new ReviewStore(f.state, f.root);
  await commands.get("review").handler("Human focus", ctx);
  const reviews = await store.list();
  assert.equal(reviews.length, 1);
  const frozen = await store.read(reviews[0].id);
  assert.equal(frozen.seed, "Human focus");
  assert.equal(frozen.preparation, undefined);
  assert.deepEqual(frozen.turns, []);
  assert.equal(ctx.model.id, "implementation");
  assert.equal(await readWorkspacePreparationModel(f.state, f.root), undefined);
});

// A small command-boundary fake; filesystem, workspace discovery and capture remain real.
async function preparationFixture(t: test.TestContext) {
  const f = await fixture(t);
  for (const [key, value] of Object.entries({ PARLEY_STATE_DIR: f.state, PARLEY_PREPARATION_MODEL: undefined })) {
    const previous = process.env[key];
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
    f.cleanup.push(() => { if (previous === undefined) delete process.env[key]; else process.env[key] = previous; });
  }
  const config = { flag: undefined as string | undefined, selection: "test/fast" as string | undefined, freezeOnly: false,
    selectModel: undefined as ((choices: string[]) => Promise<string | undefined>) | undefined };
  const available = ["test/other", "test/fast", "test/override"], prompts: string[] = [], notifications: string[] = [], sessionReads: string[] = [];
  const start = async (root = f.root) => {
    const hooks = new Map<string, Function>(), commands = new Map<string, any>();
    extension({ registerFlag() {}, getFlag: () => config.flag, on: (name: string, hook: Function) => hooks.set(name, hook), registerCommand: (name: string, command: unknown) => commands.set(name, command) } as any);
    const model = (key: string) => ({ provider: key.split("/")[0], id: key.slice(key.indexOf("/") + 1), contextWindow: 100_000, maxTokens: 8192 });
    const ctx = { cwd: root, mode: "tui", model: model("test/implementation"), isIdle: () => false, hasPendingMessages: () => false,
      modelRegistry: { find: (provider: string, id: string) => available.includes(`${provider}/${id}`) ? model(`${provider}/${id}`) : undefined,
        getAvailable: () => available.map(model), streamSimple: () => { throw new Error("Creation must not call a model"); } },
      getSystemPromptOptions: () => { sessionReads.push("skills"); return { skills: [] }; },
      sessionManager: { getBranch: () => { sessionReads.push("branch"); return []; }, getSessionId: () => "session", getLeafId: () => undefined },
      ui: { notify: (message: string) => notifications.push(message), editor: async (_title: string, value: string) => value,
        select: async (title: string, choices: string[]) => {
          prompts.push(title);
          if (title.startsWith("Choose a fast preparation model")) {
            assert.deepEqual(choices, [...available].sort());
            return config.selectModel ? config.selectModel(choices) : config.selection;
          }
          return choices[title.includes("Git") || (title.startsWith("Create frozen review") && config.freezeOnly) ? 1 : 0];
        } },
    };
    await hooks.get("session_start")!({}, ctx);
    const stop = () => hooks.get("session_shutdown")!({}, ctx);
    f.cleanup.push(stop);
    return { ctx, stop, request: () => commands.get("review").handler("Human focus", ctx), store: new ReviewStore(f.state, root) };
  };
  const selections = () => prompts.filter(title => title.startsWith("Choose a fast preparation model"));
  return { ...f, start, config, available, prompts, notifications, sessionReads, selections };
}

test("first agent-first request saves a private workspace model; restart reuses it without changing frozen reviews", async t => {
  const f = await preparationFixture(t), first = await f.start();
  await first.request();
  const items = await first.store.list(); assert.equal(items.length, 1);
  const frozen = await first.store.read(items[0].id);
  assert.equal(frozen.preparation!.input.model, "test/fast");
  assert.equal(await readWorkspacePreparationModel(f.state, f.root), "test/fast");
  assert.equal(f.selections().length, 1); assert.equal(first.ctx.model.id, "implementation");
  const settings = path.join(f.state, "settings", workspaceKey(f.root) + ".json");
  assert.equal((await fs.stat(settings)).mode & 0o777, 0o600);
  assert.equal((await fs.stat(path.dirname(settings))).mode & 0o777, 0o700);
  assert.deepEqual((await fs.readdir(f.root)).sort(), [".git", "code.txt"]);
  await first.stop();
  const restarted = await f.start(); await restarted.request();
  assert.equal((await restarted.store.list()).length, 2); assert.equal(f.selections().length, 1);
  assert(f.prompts.some(title => title.includes("Preparation: test/fast")));
  await saveWorkspacePreparationModel(f.state, f.root, "test/other");
  assert.equal((await restarted.store.read(frozen.id)).preparation!.input.model, "test/fast");
  const other = await fixture(t), otherHost = await f.start(other.root);
  assert.equal(await readWorkspacePreparationModel(f.state, other.root), undefined);
  f.config.selection = "test/override"; await otherHost.request();
  assert.equal(await readWorkspacePreparationModel(f.state, other.root), "test/override");
  assert.equal(await readWorkspacePreparationModel(f.state, f.root), "test/other");
});

test("CLI then environment override the saved default without persisting either override", async t => {
  const f = await preparationFixture(t), host = await f.start();
  await saveWorkspacePreparationModel(f.state, f.root, "test/fast");
  const settings = path.join(f.state, "settings", workspaceKey(f.root) + ".json"), original = await fs.readFile(settings, "utf8");
  process.env.PARLEY_PREPARATION_MODEL = "test/other"; f.config.flag = "test/override";
  const expected = ["test/override", "test/other", "test/fast"];
  for (const key of expected) {
    const before = new Set((await host.store.list()).map(item => item.id));
    await host.request();
    const created = (await host.store.list()).filter(item => !before.has(item.id)); assert.equal(created.length, 1);
    assert.equal((await host.store.read(created[0].id)).preparation!.input.model, key);
    assert.equal(await fs.readFile(settings, "utf8"), original);
    if (f.config.flag) f.config.flag = undefined; else delete process.env.PARLEY_PREPARATION_MODEL;
  }
  assert.equal(f.selections().length, 0); assert.equal(host.ctx.model.id, "implementation");
});

test("cancelled and shutdown model choices create no review, default or shared session context", async t => {
  const f = await preparationFixture(t), host = await f.start();
  f.config.selection = undefined; await host.request();
  assert.deepEqual(await host.store.list(), []); assert.equal(await readWorkspacePreparationModel(f.state, f.root), undefined);
  const entered = deferred<void>(), selected = deferred<string | undefined>();
  f.config.selectModel = async () => { entered.resolve(); return selected.promise; };
  const request = host.request(); await entered.promise;
  await host.stop(); selected.resolve("test/fast"); await request;
  assert.deepEqual(await host.store.list(), []); assert.equal(await readWorkspacePreparationModel(f.state, f.root), undefined);
  assert.deepEqual(f.sessionReads, []);
});

test("unavailable saved models require an explicit replacement; invalid overrides never change the default", async t => {
  const f = await preparationFixture(t), host = await f.start();
  await saveWorkspacePreparationModel(f.state, f.root, "missing/fast");
  f.config.selection = undefined; await host.request();
  assert.equal(await readWorkspacePreparationModel(f.state, f.root), "missing/fast"); assert.deepEqual(await host.store.list(), []);
  assert(f.selections()[0].includes("Saved model missing/fast is unavailable"));
  f.config.selection = "test/other"; await host.request();
  assert.equal(await readWorkspacePreparationModel(f.state, f.root), "test/other");
  assert.equal((await host.store.list()).length, 1);
  const selections = f.selections().length;
  for (const source of ["flag", "env"]) {
    if (source === "flag") f.config.flag = "missing/override";
    else { f.config.flag = undefined; process.env.PARLEY_PREPARATION_MODEL = "missing/override"; }
    await host.request();
    assert.equal((await host.store.list()).length, 1);
    assert.equal(await readWorkspacePreparationModel(f.state, f.root), "test/other");
    assert.equal(f.selections().length, selections);
    assert(f.notifications.at(-1)!.includes("override missing/override is unavailable"));
  }
});

test("no available models or an invalid picker result fail without storing a default", async t => {
  const f = await preparationFixture(t), host = await f.start();
  f.config.selection = "outside/model"; await host.request();
  assert(f.notifications.at(-1)!.includes("Selected preparation model is unavailable"));
  f.available.splice(0); await host.request();
  assert(f.notifications.at(-1)!.includes("No preparation models available"));
  assert.deepEqual(await host.store.list(), []); assert.equal(await readWorkspacePreparationModel(f.state, f.root), undefined);
  assert.deepEqual(f.sessionReads, []);
});

test("workspace preferences reject malformed, wrong-version and wrong-workspace data without blocking freeze-only", async t => {
  const f = await preparationFixture(t), host = await f.start();
  await saveWorkspacePreparationModel(f.state, f.root, "test/fast");
  const settings = path.join(f.state, "settings", workspaceKey(f.root) + ".json");
  for (const contents of ["{", "null", JSON.stringify({ version: 2, workspace: f.root, preparationModel: "test/fast" }),
    JSON.stringify({ version: 1, workspace: "/elsewhere", preparationModel: "test/fast" }), JSON.stringify({ version: 1, workspace: f.root, preparationModel: 7 })]) {
    await fs.writeFile(settings, contents);
    await assert.rejects(readWorkspacePreparationModel(f.state, f.root));
    await host.request(); assert.deepEqual(await host.store.list(), []);
    assert.equal(await fs.readFile(settings, "utf8"), contents);
  }
  await assert.rejects(saveWorkspacePreparationModel(f.state, f.root, "unqualified"), /provider\/id/);
  f.config.freezeOnly = true; await host.request();
  const items = await host.store.list(); assert.equal(items.length, 1);
  assert.equal((await host.store.read(items[0].id)).preparation, undefined);
  assert.deepEqual(f.sessionReads, []); assert.deepEqual(f.selections(), []);
});

test("jj /review defaults to the current change and uses a separate preparation model without sharing later session text", async t => {
  const f = await fixture(t);
  await exec("jj", ["git", "init", "--colocate"], { cwd: f.root });
  const previous = process.env.PARLEY_STATE_DIR;
  process.env.PARLEY_STATE_DIR = f.state;
  f.cleanup.push(() => { if (previous === undefined) delete process.env.PARLEY_STATE_DIR; else process.env.PARLEY_STATE_DIR = previous; });
  const hooks = new Map<string, Function>(), commands = new Map<string, any>();
  extension({ registerFlag() {}, getFlag: () => "test/fast", on: (name: string, hook: Function) => hooks.set(name, hook), registerCommand: (name: string, command: unknown) => commands.set(name, command) } as any);
  let idle = false;
  const reviewModel = { provider: "test", id: "review", contextWindow: 100_000 }, fastModel = { ...reviewModel, id: "fast" }, models: string[] = [], notifications: string[] = [];
  const branch = [{ type: "message", id: "human", message: { role: "user", content: "Original implementation intent" } }];
  const ctx = { cwd: f.root, mode: "tui", model: reviewModel, isIdle: () => idle, hasPendingMessages: () => false,
    sessionManager: { getBranch: () => branch, getLeafId: () => "human", getSessionId: () => "implementation" }, getSystemPromptOptions: () => ({ skills: [] }),
    ui: { notify: (message: string) => notifications.push(message), editor: async (_title: string, value: string) => value, input: () => { throw new Error("jj should not ask for revisions"); }, select: async (title: string, choices: string[]) => { assert(title.includes("share") || choices[0].includes("share")); return choices[0]; } },
    modelRegistry: { find: (provider: string, id: string) => provider === "test" && id === "fast" ? fastModel : undefined,
      streamSimple: (model: typeof reviewModel, transcript: any) => { models.push(model.id); assert.equal(transcript.tools, undefined);
        const prompt = transcript.messages[0].content; assert(!prompt.includes("Later private conversation"));
        if (model.id === "fast") assert(prompt.includes("Original implementation intent"));
        else { assert(prompt.includes("Prepared intent")); assert(!prompt.includes("Original implementation intent")); }
        return { result: async () => ({ stopReason: "stop", content: [{ type: "text", text: model.id === "fast" ? '{"summary":"Prepared intent","read":[],"limitations":[]}' : "[]" }] }) };
      } },
  };
  await hooks.get("session_start")!({}, ctx); f.cleanup.push(() => hooks.get("session_shutdown")!({}, ctx));
  await commands.get("review").handler("Focus on draft retention", ctx);
  assert.deepEqual(models, []);
  const store = new ReviewStore(f.state, f.root), items = await store.list(); assert.equal(items.length, 1);
  let record = await store.read(items[0].id); assert(record.scope.includes("@-")); assert.equal(record.turns[0].kind, "initial");
  assert.equal(record.seed, "Focus on draft retention");
  branch[0].message.content = "Later private conversation";
  idle = true; hooks.get("agent_settled")!({}, ctx);
  for (let n = 0; n < 100 && record.turns[0].status !== "complete"; n++) { await new Promise(yes => setTimeout(yes, 10)); record = await store.read(record.id); }
  assert.equal(record.turns[0].status, "complete", notifications.join("\n"));
  assert.deepEqual(models, ["fast", "review"]); assert.equal(ctx.model, reviewModel); assert.deepEqual(record.notes, []);
});

test("Neovim restores read-only initial findings on both sides and saves explicit human replies separately", async t => {
  const f = await owner(t);
  const record = await f.connection.store.create(f.record, "", { model: "test/fast", session: boundedSession([]), skills: [], omittedSkills: 0 });
  // The owner's original review is freeze-only; make the initial-review record the only picker choice.
  await f.handle("close", f.record.version);
  let preparations = 0;
  const runner = new TurnRunner(f.connection, () => true, async (_record, turn) => turn.kind === "initial" ? '[{"path":"code.txt","side":"new","first":1,"last":1,"text":"New-side finding"},{"path":"code.txt","side":"old","first":1,"last":1,"text":"Old-side finding"}]' : JSON.stringify(turn.notes.map(note => ({ replyTo: note.id, text: "Reply to human" }))), () => {}, async () => {
    preparations++; return { model: "test/fast", summary: "Frozen intent", guidelines: [], limitations: [] };
  });
  f.cleanup.push(() => runner.stop()); f.connection.onSubmit = () => runner.kick(); runner.kick(); await runner.active;
  const saved = await f.connection.store.read(record.id), findingId = saved.turns[0].findings![0].id;
  const script = path.join(f.dir, "findings.lua");
  await fs.writeFile(script, `
vim.opt.runtimepath:append(${JSON.stringify(process.cwd())})
vim.api.nvim_set_current_dir(${JSON.stringify(f.root)})
vim.o.lines, vim.o.columns = 40, 110
vim.ui.select = function(items, _, done) done(items[1]) end
vim.cmd.edit('code.txt')
local parley, composer = require('parley'), require('parley.composer')
local function wait(test) assert(vim.wait(8000, test, 10), vim.api.nvim_exec2('messages', { output = true }).output) end
parley.start()
wait(function() return parley.active_window() ~= nil end)
assert(#composer.findings == 2 and #composer.comments == 0)
assert(composer.findings[1].author == 'agent')
assert(composer.findings[1].remote_id == ${JSON.stringify(findingId)})
parley.move_note(1)
parley.delete_note()
assert(#composer.findings == 2 and #composer.comments == 0)
parley.edit_note() -- Enter on an immutable finding opens an explicit reply, never edits it.
wait(function() return composer.current_item() ~= nil end)
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'Explicit human follow-up'})
vim.cmd.stopinsert()
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
wait(function() return composer.current_item() == nil and #composer.comments == 1 end)
assert(composer.comments[1].reply_to == ${JSON.stringify(findingId)})
parley.submit()
wait(function() return composer.comments[1].replies and #composer.comments[1].replies == 1 end)
assert(composer.comments[1].replies[1].text == 'Reply to human')
vim.wait(1200, function() return false end, 10)
assert(#composer.findings == 2)
parley.stop()
vim.wait(300, function() return false end, 10)
parley.start()
wait(function() return parley.active_window() ~= nil end)
assert(#composer.findings == 2 and #composer.comments == 1)
parley.move_note(1)
parley.move_note(1)
parley.move_note(1)
assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'before')
assert(not vim.bo.modifiable)
parley.stop()
vim.cmd('qa!')
`);
  await exec("nvim", ["--headless", "--noplugin", "-u", "NONE", "-l", script], { env: { ...process.env, PARLEY_STATE_DIR: f.state }, timeout: 20_000 });
  const discussed = await f.connection.store.read(record.id);
  assert.equal(preparations, 1); assert.equal(discussed.notes.length, 1);
  assert.equal(discussed.notes[0].replyTo, findingId); assert.equal(discussed.turns.length, 2);
  assert.equal(discussed.turns[0].findings!.length, 2); assert.deepEqual(discussed.turns[0].notes, []);
});
