// Repository discovery adapted from silicon-housekeeping/support/review-vcs.ts.
// Unlike that command, Parley captures owned text, never checks out or authorizes fixes.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { promises as fs } from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import type { ReviewFile } from "./state.ts";

const exec = promisify(execFile);
export type Repository = { root: string; vcs: "git" | "jj" };
export type Scope = { kind: "staged" | "working" } | { kind: "range"; from: string; to: string };
async function command(repo: Repository, args: string[]): Promise<string> {
  const options = repo.vcs === "jj" ? ["--no-pager", "--color=never"] : [];
  const result = await exec(repo.vcs, [...options, ...args], { cwd: repo.root, maxBuffer: 64 * 1024 * 1024 });
  return result.stdout;
}
export async function discover(cwd: string): Promise<Repository> {
  let dir = await fs.realpath(cwd);
  for (;;) {
    for (const [marker, vcs] of [[".jj", "jj"], [".git", "git"]] as const) {
      try { await fs.lstat(path.join(dir, marker)); }
      catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") continue; throw error; }
      const repo = { root: dir, vcs };
      const root = (await command(repo, vcs === "jj" ? ["root"] : ["rev-parse", "--show-toplevel"])).trim();
      return { root: await fs.realpath(root), vcs };
    }
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error("Not a jj or Git workspace");
    dir = parent;
  }
}
function text(content: string): { text: string; format: "unix" | "dos" } {
  if (content.includes("\0")) throw new Error("Review supports text files only");
  return { text: content.replaceAll("\r\n", "\n"), format: content.includes("\r\n") ? "dos" : "unix" };
}
function file(filename: string, old: string, fresh: string, deleted: boolean, status: string, oldPath = filename): ReviewFile {
  const a = text(old), b = text(fresh);
  return { path: filename, old_path: oldPath, status, old: a.text, new: b.text,
    old_fileformat: a.format, new_fileformat: b.format, deleted };
}
type Entry = { id: string; mode: string };
async function gitTree(repo: Repository, revision: string): Promise<Map<string, Entry>> {
  const entries = new Map<string, Entry>();
  for (const row of (await command(repo, ["ls-tree", "-rz", revision])).split("\0").filter(Boolean)) {
    const match = /^(\d+) \w+ ([0-9a-f]+)\t([\s\S]+)$/.exec(row);
    if (!match) throw new Error("Malformed Git tree");
    entries.set(match[3], { mode: match[1], id: match[2] });
  }
  return entries;
}
function supported(entry: Entry | undefined, filename: string) {
  if (entry && !["100644", "100755"].includes(entry.mode)) throw new Error(`Review requires regular text files: ${filename}`);
}
async function blob(repo: Repository, entry: Entry | undefined, filename: string): Promise<string> {
  supported(entry, filename);
  return entry ? command(repo, ["cat-file", "blob", entry.id]) : "";
}
export async function capture(repo: Repository, scope: Scope): Promise<{ root: string; vcs: "git" | "jj"; revision?: string; scope: string; files: ReviewFile[] }> {
  const files: ReviewFile[] = [];
  let revision: string | undefined, label: string;
  if (repo.vcs === "jj") {
    if (scope.kind !== "range") throw new Error("jj requires an explicit baseline and tip (it has no Git index)");
    const resolve = async (expr: string) => {
      const row = await command(repo, ["log", "--no-graph", "-r", `exactly((${expr}), 1)`, "-T", 'commit_id ++ "\\t" ++ conflict']);
      const [id, conflict] = row.split("\t");
      if (!/^[0-9a-f]{40,64}$/.test(id) || conflict !== "false") throw new Error(`Expected one conflict-free jj revision: ${expr}`);
      return id;
    };
    const from = await resolve(scope.from), to = await resolve(scope.to);
    revision = to;
    label = `jj ${scope.from}..${scope.to} (${from.slice(0, 12)}..${to.slice(0, 12)})`;
    const fields = (await command(repo, ["--ignore-working-copy", "diff", "--from", from, "--to", to, "-T",
      'status ++ "\\0" ++ path ++ "\\0" ++ source.path() ++ "\\0"'])).split("\0");
    if (fields.pop() !== "" || fields.length % 3) throw new Error("Malformed jj file listing");
    for (let i = 0; i < fields.length; i += 3) {
      const [status, filename, oldPath] = fields.slice(i, i + 3);
      // Full-context patches reliably reject symlinks and binary deltas before file show.
      const quote = (name: string) => 'file:"' + name.replace(/[\x00-\x1f\x7f\\"]/g, c => c === '"' || c === "\\" ? "\\" + c : "\\x" + c.charCodeAt(0).toString(16).padStart(2, "0")) + '"';
      const patch = await command(repo, ["--ignore-working-copy", "diff", "--git", "--from", from, "--to", to, quote(filename)]);
      if (/^(?:new file mode|deleted file mode|old mode|new mode) 120000$|^index .* 120000$|^Binary files |^GIT binary patch/m.test(patch))
        throw new Error(`Review requires regular text files: ${filename}`);
      const old = status === "added" ? "" : await command(repo, ["--ignore-working-copy", "file", "show", "-r", from, oldPath || filename]);
      const fresh = status === "removed" ? "" : await command(repo, ["--ignore-working-copy", "file", "show", "-r", to, filename]);
      files.push(file(filename, old, fresh, status === "removed", status, oldPath || filename));
    }
  } else {
    let before: Map<string, Entry>, after: Map<string, Entry>;
    let working: Map<string, string> | undefined;
    if (scope.kind === "range") {
      const resolve = async (expr: string) => (await command(repo, ["rev-parse", "--verify", "--end-of-options", `${expr}^{commit}`])).trim();
      const from = await resolve(scope.from), to = await resolve(scope.to);
      before = await gitTree(repo, from); after = await gitTree(repo, to);
      revision = to; label = `git ${scope.from}..${scope.to} (${from.slice(0, 12)}..${to.slice(0, 12)})`;
    } else {
      try { revision = (await command(repo, ["rev-parse", "--verify", "HEAD"])).trim(); }
      catch (error) {
        // Only an absent symbolic HEAD permits the unborn-repository baseline.
        const ref = (await command(repo, ["symbolic-ref", "HEAD"])).trim();
        try { await command(repo, ["show-ref", "--verify", ref]); throw error; }
        catch (missing) { if ((missing as { code?: number }).code !== 1) throw missing; }
      }
      before = revision ? await gitTree(repo, revision) : new Map();
      const listing = await command(repo, ["ls-files", "--stage", "-z"]);
      after = new Map();
      for (const row of listing.split("\0").filter(Boolean)) {
        const match = /^(\d+) ([0-9a-f]+) (\d)\t([\s\S]+)$/.exec(row);
        if (!match || match[3] !== "0") throw new Error("Resolve index conflicts before reviewing");
        after.set(match[4], { mode: match[1], id: match[2] });
      }
      label = `git ${scope.kind} against ${revision?.slice(0, 12) ?? "unborn HEAD"}`;
      if (scope.kind === "working") {
        working = new Map();
        const names = new Set([...after.keys(), ...(await command(repo, ["ls-files", "--others", "--exclude-standard", "-z"])).split("\0").filter(Boolean)]);
        after = new Map();
        for (const filename of names) {
          let stat;
          try { stat = await fs.lstat(path.join(repo.root, filename)); }
          catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") continue; throw error; }
          if (!stat.isFile()) throw new Error(`Review requires regular files: ${filename}`);
          const content = await fs.readFile(path.join(repo.root, filename), "utf8");
          working.set(filename, content);
          // Compare working bytes using Git's object format, without writing repository objects.
          const format = (await command(repo, ["rev-parse", "--show-object-format"])).trim();
          const bytes = Buffer.from(content);
          after.set(filename, { mode: stat.mode & 0o111 ? "100755" : "100644", id: createHash(format).update(`blob ${bytes.length}\0`).update(bytes).digest("hex") });
        }
      }
      if (listing !== await command(repo, ["ls-files", "--stage", "-z"])) throw new Error("Index changed during capture; retry review creation");
      const headNow = await command(repo, ["rev-parse", "--verify", "--quiet", "HEAD"]).catch((error: { code?: number }) => { if (error.code === 1) return ""; throw error; });
      if (headNow.trim() !== (revision ?? "")) throw new Error("HEAD changed during capture; retry review creation");
    }
    for (const filename of [...new Set([...before.keys(), ...after.keys()])].sort()) {
      const old = before.get(filename), fresh = after.get(filename);
      if (old?.id === fresh?.id && old?.mode === fresh?.mode) continue;
      supported(fresh, filename);
      files.push(file(filename, await blob(repo, old, filename), working ? working.get(filename) ?? "" : await blob(repo, fresh, filename), !fresh, !old ? "added" : !fresh ? "removed" : "modified"));
    }
  }
  files.sort((a, b) => a.path.localeCompare(b.path));
  if (!files.length) throw new Error("No changed files in the selected scope");
  return { ...repo, revision, scope: label, files };
}
