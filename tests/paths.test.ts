import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { stateDirectory } from "../pi/paths.ts";

test("state directory follows environment precedence and ignores empty values", t => {
  const previousOverride = process.env.PARLEY_STATE_DIR;
  const previousStateHome = process.env.XDG_STATE_HOME;
  t.after(() => {
    if (previousOverride === undefined) {
      delete process.env.PARLEY_STATE_DIR;
    } else {
      process.env.PARLEY_STATE_DIR = previousOverride;
    }
    if (previousStateHome === undefined) {
      delete process.env.XDG_STATE_HOME;
    } else {
      process.env.XDG_STATE_HOME = previousStateHome;
    }
  });

  const stateHome = path.join(os.tmpdir(), "parley-xdg-state");
  process.env.XDG_STATE_HOME = stateHome;
  process.env.PARLEY_STATE_DIR = "custom/../state/";
  assert.equal(stateDirectory(), "custom/../state/");

  process.env.PARLEY_STATE_DIR = "";
  assert.equal(stateDirectory(), path.join(stateHome, "parley"));

  delete process.env.PARLEY_STATE_DIR;
  assert.equal(stateDirectory(), path.join(stateHome, "parley"));

  process.env.XDG_STATE_HOME = "";
  assert.equal(stateDirectory(), path.join(os.homedir(), ".local/state/parley"));

  delete process.env.XDG_STATE_HOME;
  assert.equal(stateDirectory(), path.join(os.homedir(), ".local/state/parley"));
});
