import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Opt in because this needs the installed Pi executable, not an npm dependency.
// All model responses are scripted in-process; this never contacts a provider.
test("installed Pi preserves a supplied environment, but equal tool/prompt metadata cannot attest permission-hook fidelity", {
  skip: process.env.PARLEY_PI_RUNTIME_TESTS !== "1", timeout: 75_000,
}, async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "parley-environment-contract-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const fixture = fileURLToPath(new URL("./fixtures/parley-environment-probe.ts", import.meta.url));
  const child = spawn("pi", ["--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes",
    "-e", fixture, "--model", "parley-probe-shell/offline", "--mode", "rpc"], {
    cwd: directory,
    env: { ...process.env, HOME: directory, XDG_CONFIG_HOME: path.join(directory, "config"), PI_CODING_AGENT_DIR: path.join(directory, "outer-agent") },
    stdio: ["pipe", "pipe", "pipe"],
  });
  t.after(() => { if (child.exitCode === null) child.kill("SIGKILL"); });
  let output = "";
  const collect = (chunk: Buffer) => {
    output += chunk.toString();
    if (output.includes("PARLEY_ENVIRONMENT_PROBE_OK") || output.includes("PARLEY_ENVIRONMENT_PROBE_FAILED")) child.stdin.end();
  };
  child.stdout.on("data", collect);
  child.stderr.on("data", collect);
  const timeout = setTimeout(() => child.kill("SIGKILL"), 60_000);
  t.after(() => clearTimeout(timeout));
  const closed = new Promise<number | null>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
    child.stdin.once("error", reject);
  });
  child.stdin.write(JSON.stringify({ type: "prompt", message: `/parley-environment-probe ${directory}` }) + "\n");
  const exitCode = await closed;
  assert.equal(exitCode, 0, output);
  assert(!output.includes("PARLEY_ENVIRONMENT_PROBE_FAILED"), output);
  assert(output.includes("PARLEY_ENVIRONMENT_PROBE_OK"), output);
});
