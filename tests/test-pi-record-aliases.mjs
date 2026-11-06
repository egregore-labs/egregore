import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { registerObserveHook } from "../bin/pi-observe-context.mjs";

const repository = resolve(dirname(fileURLToPath(import.meta.url)), "..");
mkdirSync(join(repository, "tmp"), { recursive: true });
const fixture = mkdtempSync(join(repository, "tmp/pi-record-aliases."));
const home = join(fixture, "home");
const root = join(fixture, "project");
mkdirSync(join(root, "bin"), { recursive: true });
mkdirSync(home, { recursive: true });
writeFileSync(join(root, "bin/observe-context.sh"), "#!/bin/sh\ncat >/dev/null\nprintf '%s' '{}'\n");
process.env.HOME = home;
const prefix = root.replace(/[/.]/g, "-");
let checks = 0;
function check(name, run) { run(); checks++; console.log(`PASS: ${name}`); }
async function bind(path, harness = "pi", project = root) {
  let handler;
  registerObserveHook({ on(_event, callback) { handler = callback; } }, { root: project, harness });
  await handler({ prompt: "Synthetic alias fixture" }, { sessionManager: { getSessionFile: () => path } });
}
function header(id = "pi-native", cwd = root) {
  return JSON.stringify({ type: "session", version: 3, id, cwd, timestamp: "2026-10-15T10:00:00Z" }) + "\n";
}

try {
  const sessions = join(home, ".pi/agent/sessions");
  mkdirSync(join(sessions, "physical"), { recursive: true });
  symlinkSync(join(sessions, "physical"), join(sessions, "alias"), "dir");
  const spelling = join(sessions, "alias/session.jsonl");
  writeFileSync(spelling, header());
  await bind(spelling);
  const aliases = join(home, ".egregore/trails", prefix + "--pi", "aliases.jsonl");
  const hash = createHash("sha256").update(String(spelling)).digest("hex");
  check("Pi alias preserves the producer's symlinked spelling and native header id", () => {
    assert.deepEqual(JSON.parse(readFileSync(aliases, "utf8")), { hash, path: spelling, session: "pi-native" });
    assert.equal(process.env.EGREGORE_NATIVE_SESSION_ID, hash);
    assert.equal(process.env.EGREGORE_NATIVE_HARNESS, "pi");
    assert.equal(statSync(aliases).mode & 0o777, 0o600);
  });
  await bind(spelling);
  check("repeated prompt binding does not duplicate aliases", () => {
    assert.equal(readFileSync(aliases, "utf8").trim().split("\n").length, 1);
  });
  const lockedSession = join(sessions, "physical/locked.jsonl");
  writeFileSync(lockedSession, header("locked-native"));
  const lock = join(dirname(aliases), ".aliases.lock");
  mkdirSync(lock);
  await bind(lockedSession);
  check("a fresh alias lock prevents concurrent writing and remains owned", () => {
    assert.equal(readFileSync(aliases, "utf8").trim().split("\n").length, 1);
    assert.equal(existsSync(lock), true);
  });
  const stale = new Date(Date.now() - 120_000);
  utimesSync(lock, stale, stale);
  await bind(lockedSession);
  check("a stale alias lock is reclaimed before writing", () => {
    const rows = readFileSync(aliases, "utf8").trim().split("\n").map(JSON.parse);
    assert.equal(rows.at(-1).session, "locked-native");
    assert.equal(existsSync(lock), false);
  });
  // Keep the original one-row baseline for the remaining boundary fixtures.
  writeFileSync(aliases, JSON.stringify({ hash, path: spelling, session: "pi-native" }) + "\n");
  const outside = join(fixture, "outside");
  mkdirSync(outside);
  const rejected = join(sessions, "physical/outside.jsonl");
  writeFileSync(rejected, header("outside-native", outside));
  await bind(rejected);
  check("an outside working directory cannot append a session alias", () => {
    assert.equal(readFileSync(aliases, "utf8").trim().split("\n").length, 1);
  });
  const oversized = join(sessions, "physical/oversized.jsonl");
  writeFileSync(oversized, JSON.stringify({ type: "session", version: 3, id: "oversized", cwd: root,
    padding: "x".repeat(1024 * 1024) }) + "\n");
  await bind(oversized);
  check("alias header read has a one MiB bound", () => {
    assert.equal(readFileSync(aliases, "utf8").trim().split("\n").length, 1);
  });
  const primeSession = join(home, ".prime/agent/sessions/prime.jsonl");
  mkdirSync(dirname(primeSession), { recursive: true });
  writeFileSync(primeSession, header("prime-native"));
  await bind(primeSession, "prime");
  const primeFolder = join(home, ".egregore/trails", prefix + "--prime");
  check("Prime aliases use its own admitted trail folder", () => {
    assert.equal(JSON.parse(readFileSync(join(primeFolder, "aliases.jsonl"), "utf8")).session, "prime-native");
  });
  const target = join(fixture, "target.jsonl");
  writeFileSync(target, "private sentinel\n");
  rmSync(join(primeFolder, "aliases.jsonl"));
  symlinkSync(target, join(primeFolder, "aliases.jsonl"));
  await bind(primeSession, "prime");
  check("a symlinked aliases file is never followed", () => {
    assert.equal(readFileSync(target, "utf8"), "private sentinel\n");
  });
  rmSync(primeFolder, { recursive: true });
  symlinkSync(outside, primeFolder, "dir");
  await bind(primeSession, "prime");
  check("a symlinked trail folder is refused", () => {
    assert.equal(existsSync(join(outside, "aliases.jsonl")), false);
  });
  const worktree = join(root, ".claude/worktrees/fixture");
  const gitdir = join(root, ".git/worktrees/fixture");
  mkdirSync(gitdir, { recursive: true });
  mkdirSync(join(worktree, "bin"), { recursive: true });
  writeFileSync(join(worktree, ".git"), `gitdir: ${gitdir}\n`);
  writeFileSync(join(worktree, "bin/observe-context.sh"), "#!/bin/sh\ncat >/dev/null\nprintf '%s' '{}'\n");
  const worktreeSession = join(sessions, "physical/worktree.jsonl");
  writeFileSync(worktreeSession, header("worktree-native", worktree));
  await bind(worktreeSession, "pi", worktree);
  check("worktree aliases use the shared instance prefix without running git", () => {
    assert.equal(readFileSync(aliases, "utf8").trim().split("\n").map(JSON.parse).at(-1).session, "worktree-native");
  });
  const heldCheck = spawnSync("python3", ["-c", `
import hashlib
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "bin/lib"))
from session_record import Context
root, path, original = map(Path, sys.argv[2:])
context = Context(root)
base = context.home / ".egregore/trails" / (context.prefix + "--pi")
holds = base / "holds"
holds.mkdir()
spelling_hash = hashlib.sha256(str(original).encode()).hexdigest()
(holds / spelling_hash).write_text("held")
assert context.held("pi-native"), "header id must resolve a producer alias hold"
assert context.held("pi-native", path), "physical discovery must resolve a producer alias hold"
assert context.held("pi-native", original), "hook spelling must resolve a producer alias hold"
(holds / spelling_hash).unlink()
(base / "aliases.jsonl").unlink()
physical_hash = hashlib.sha256(str(path).encode()).hexdigest()
(holds / physical_hash).write_text("held")
assert context.held("pi-native"), "publication must resolve a pre-alias physical hash hold"
assert context.held("pi-native", path), "build must resolve a pre-alias physical hash hold"
(holds / physical_hash).unlink()
target = root / "not-a-hold"
target.write_text("ignored")
(holds / "pi-native").symlink_to(target)
assert not context.held("pi-native"), "symlink markers must be refused"
`, repository, root, join(sessions, "physical/session.jsonl"), spelling],
  { encoding: "utf8", env: { ...process.env, HOME: home } });
  check("alias and pre-alias Pi holds apply to discovery, builds and publications", () => {
    assert.equal(heldCheck.status, 0, heldCheck.stderr || heldCheck.stdout);
  });
  writeFileSync(aliases, "x".repeat(1024 * 1024 + 1));
  const before = statSync(aliases).size;
  await bind(spelling);
  check("an oversized aliases file is left unchanged", () => assert.equal(statSync(aliases).size, before));
  console.log(`${checks} passed, 0 failed`);
} finally {
  rmSync(fixture, { recursive: true, force: true });
}
