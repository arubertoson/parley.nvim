import os from "node:os";
import path from "node:path";

// Shared by workspace advertisement and review artifacts; neither owns a
// second storage-location policy.
export function stateDirectory(): string {
  const stateDirectoryOverride = process.env.PARLEY_STATE_DIR;
  // Empty environment values fall through to the next storage location.
  if (stateDirectoryOverride) {
    return stateDirectoryOverride;
  }

  const stateHome = process.env.XDG_STATE_HOME || path.join(os.homedir(), ".local/state");
  return path.join(stateHome, "parley");
}
