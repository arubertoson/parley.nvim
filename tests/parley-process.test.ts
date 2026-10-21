import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import { randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { ParleyProcess } from "../pi/parley-process.ts";

// Needs the installed Pi CLI. The real process runs only the scripted offline
// provider, with ordinary resource discovery in an isolated agent directory.
test("normal Pi child edits through native codemode, retains context and leaves the parent unchanged", {
  skip: process.env.PARLEY_PI_RUNTIME_TESTS !== "1", timeout: 30_000,
}, async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-process-"));
  const root = path.join(directory, "work"), agentDir = path.join(directory, "agent");
  let child: ParleyProcess | undefined;
  t.after(async () => {
    try { await child?.close(); } finally { await fs.rm(directory, { recursive: true, force: true }); }
  });
  await fs.mkdir(root);
  await fs.mkdir(path.join(agentDir, "extensions"), { recursive: true });
  await fs.mkdir(path.join(agentDir, "skills", "fixture"), { recursive: true });
  await fs.copyFile(new URL("./fixtures/parley-process-provider.ts", import.meta.url), path.join(agentDir, "extensions", "offline.ts"));
  await fs.writeFile(path.join(agentDir, "skills", "fixture", "SKILL.md"), "---\nname: fixture\ndescription: Process fixture skill\n---\nFixture instructions.\n");
  await fs.writeFile(path.join(agentDir, "settings.json"), JSON.stringify({ defaultTools: ["+codemode"], cacheWarming: "off",
    compaction: { enabled: false }, retry: { enabled: false } }));
  await fs.writeFile(path.join(root, "source.txt"), "original source\n");
  const parentId = randomUUID(), childId = randomUUID(), timestamp = new Date().toISOString();
  const parentPath = path.join(directory, "parent.jsonl"), childPath = path.join(directory, "child.jsonl");
  const header = { type: "session", version: 3, id: parentId, timestamp, cwd: root };
  const entries = [{ type: "message", id: "a1b2c3d4", parentId: null, timestamp,
    message: { role: "user", content: "Inherited decision from parent", timestamp: Date.now() } }];
  const serialize = (records: readonly unknown[]) => records.map(record => JSON.stringify(record)).join("\n") + "\n";
  const parentBytes = serialize([header, ...entries]);
  await fs.writeFile(parentPath, parentBytes);
  await fs.writeFile(childPath, serialize([{ ...header, id: childId, parentSession: parentPath }, ...entries]));
  child = await ParleyProcess.start({ cwd: root, transcriptPath: childPath, parentSessionId: parentId,
    model: { provider: "parley-process-offline", id: "offline" }, thinkingLevel: "high",
    env: { ...process.env, HOME: directory, XDG_CONFIG_HOME: path.join(directory, "config"), PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: "1" },
  });
  assert.equal(child.sessionId, childId);
  assert.equal(await child.prompt("Make the localized source edit."), "Changed source.txt using native codemode.");
  assert.equal(await fs.readFile(path.join(root, "source.txt"), "utf8"), "changed source\n");
  assert.equal(await child.prompt("Recap only; do not edit."), "Recap: source.txt changed; native read/write verified. λ\u2028✓");
  await child.close();
  await child.close();
  assert.equal(await fs.readFile(path.join(root, "child-stopped"), "utf8"), "yes\n", "Orderly shutdown runs extension cleanup");
  assert.equal(await fs.readFile(parentPath, "utf8"), parentBytes);
  const transcript = (await fs.readFile(childPath, "utf8")).trim().split("\n").map(line => JSON.parse(line));
  const startup = transcript.find(entry => entry.type === "custom" && entry.customType === "process-fixture");
  assert(startup);
  assert.notEqual(startup.data.pid, process.pid);
  assert.equal(startup.data.sessionId, childId);
  assert(transcript.some(entry => entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "codemode"));
  assert(transcript.some(entry => entry.type === "message" && JSON.stringify(entry.message).includes("Recap: source.txt changed")));
});
