import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { Connection } from "../pi/connection.ts";
import { workspaceKey, ReviewStore, type Review, type Request, type Note } from "../pi/state.ts";
import { capture, discover } from "../pi/review-vcs.ts";
import { TurnRunner, replyPrompt } from "../pi/turns.ts";
import extension from "../pi/extension.ts";

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
  extension({ on: (event: string, handler: Function) => hooks.set(event, handler), registerCommand: (name: string, definition: any) => commands.set(name, definition) } as any);
  const entered = deferred<void>(), result = deferred<any>();
  let calls = 0, idle = true, received: any;
  const context = {
    cwd: f.root, mode: "tui", model: { contextWindow: 100_000 },
    isIdle: () => idle, hasPendingMessages: () => false,
    ui: { notify() {}, select: async (prompt: string, choices: string[]) => choices[prompt.includes("Git") ? 1 : 0], editor: async () => "Only curated seed", confirm: async () => true },
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
    extension({ on: (event: string, handler: Function) => hooks.set(event, handler), registerCommand: (name: string, definition: any) => commands.set(name, definition) } as any);
    const confirming = deferred<void>(), confirmation = deferred<boolean>();
    const context = {
      cwd: f.root, mode: "tui", isIdle: () => true, hasPendingMessages: () => false,
      ui: { notify() {}, select: async (prompt: string, choices: string[]) => choices[prompt.includes("Git") ? 1 : 0], editor: async () => "Seed", confirm: async () => { confirming.resolve(); return confirmation.promise; } },
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

test("Neovim attaches frozen bytes, saves without submitting, displays replies and retains edits on reattach", async t => {
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
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'after')
assert(not vim.bo.modifiable)
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
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'after')
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
