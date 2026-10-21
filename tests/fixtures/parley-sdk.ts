// Offline boundary fake for workflow tests. Actual SessionManager/tool forwarding
// compatibility is checked separately against the installed Pi executable.
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { model } from "./review-sdk.ts";
export { createAgentSession, createExtensionRuntime, SettingsManager } from "./review-sdk.ts";
export const ModelRuntime = { create: async () => ({ getModel: () => model, registerProvider() {} }) };

type Entry = { readonly id: string; readonly parentId: string | null; readonly type: string; readonly [key: string]: unknown };
export class SessionManager {
  constructor(private filename: string, private id: string, private entries: Entry[]) {}
  static open(filename: string): SessionManager {
    const [header, ...entries] = readFileSync(filename, "utf8").trim().split("\n").map(line => JSON.parse(line));
    return new SessionManager(filename, header.id, entries);
  }
  getSessionId(): string { return this.id; }
  getSessionFile(): string { return this.filename; }
  getLeafId(): string | null { return this.entries.at(-1)?.id ?? null; }
  getBranch(leaf: string): Entry[] {
    const result: Entry[] = [];
    let current = this.entries.find(entry => entry.id === leaf);
    while (current) { result.unshift(current); current = this.entries.find(entry => entry.id === current?.parentId); }
    return result;
  }
  createBranchedSession(leaf: string): string {
    this.entries = this.getBranch(leaf);
    this.id = randomUUID();
    this.filename = path.join(path.dirname(this.filename), `${this.id}.jsonl`);
    writeFileSync(this.filename, [{ type: "session", id: this.id }, ...this.entries].map(entry => JSON.stringify(entry)).join("\n") + "\n", { flag: "wx" });
    return this.filename;
  }
}
