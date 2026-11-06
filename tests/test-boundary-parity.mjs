#!/usr/bin/env node
// Instance-wall parity across runtimes.
//
// One fixture table of (operation, path or command, posture, consent / lock /
// bypass state, cache and registry state) → expected outcome, run through
// every adapter of bin/boundary-guard.cjs, each reached the way its host
// reaches it:
//   claude — the .claude/settings.json PreToolUse entries whose matcher takes
//            the tool, running .claude/hooks/boundary-check.sh with Claude
//            Code hook stdin
//   codex  — the .codex/hooks.json PreToolUse entries whose matcher takes the
//            tool, running their command from the checkout with Codex hook
//            stdin (reads go through the shell, writes through apply_patch:
//            Codex has no separate read or write tool)
//   pi     — the tool_call delegate the Pi and Prime extensions call, and the
//            real .pi/extensions/egregore.ts and
//            .prime/agent/extensions/egregore.ts handlers. On a Node that
//            strips types the real handlers are required: an import failure
//            fails the suite.
// Outcomes must be identical. Pi exposes no permission mode, so it always
// runs in the default mode: rows that use bypassPermissions name the Pi
// outcome separately.
//
// The shell check reads text literally. Rows marked `limit` are shell forms
// text cannot see (paths built at run time, commands split across calls):
// they are expected to pass the check, and the suite says so, because their
// confinement belongs to the OS-level sandbox planned as the follow-up layer.
//
// Fixtures live in a temporary HOME under the checkout (never /tmp or
// /private, which are core-allowed and would mask the soft tier) with its own
// instance registry. No real instance, registry, or user path is read.
// Usage: node tests/test-boundary-parity.mjs

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const GUARD = path.join(ROOT, "bin", "boundary-guard.cjs");
const CLAUDE_HOOK = process.env.BOUNDARY_PARITY_CLAUDE_HOOK || path.join(ROOT, ".claude", "hooks", "boundary-check.sh");
const read_ = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const CLAUDE_SETTINGS = JSON.parse(read_(".claude/settings.json"));
const CODEX_HOOKS = JSON.parse(read_(".codex/hooks.json"));
const guard = require(GUARD);

let pass = 0;
let fail = 0;
let limits = 0;
const ok = (name) => { pass++; console.log(`  PASS: ${name}`); };
const bad = (name, detail = "") => { fail++; console.log(`  FAIL: ${name}${detail ? `\n        ${detail}` : ""}`); };

// ── Fixture world ─────────────────────────────────────────────────────────
const fixtureParent = path.join(ROOT, "tmp");
fs.mkdirSync(fixtureParent, { recursive: true });
const H = fs.realpathSync(fs.mkdtempSync(path.join(fixtureParent, "boundary-parity-")));
// A separate disposable system-path target exposes logical-cd escapes that
// a physical-only scan would mistake for core /tmp access.
const SYSTEM_TMP = fs.realpathSync(fs.mkdtempSync("/tmp/egregore-parity-cwd-"));
for (const dir of ["exports", "runtime", "other/nest", "rival"]) fs.mkdirSync(`${SYSTEM_TMP}/${dir}`, { recursive: true });
const P = `${H}/dev/acme`;                 // the project
const MEMORY = `${H}/dev/acme-memory`;     // its memory repo (symlinked)
const SITE = `${H}/dev/acme-site`;         // its managed repo
const R = `${H}/dev/rival`;                // another org's instance
const OUTER = `${H}/dev/outer`;            // another org's instance enclosing N
const N = `${OUTER}/nested`;               // a project nested inside OUTER
const MAIN = `${H}/dev/legacy-main`;       // main checkout of a linked worktree
const W = `${MAIN}/.claude/worktrees/task`; // the linked worktree
const F = `${H}/dev/forger`;               // a project whose .git claims R as its main checkout
const P_ALIAS = `${H}/dev/acme-alias`;
const R_ALIAS = `${H}/dev/rival-alias`;
// A stale evaluation sandbox registered inside the project's runtime state,
// as on a machine where an older eval run self-registered (no org_id).
const NESTED = `${P}/.egregore/eval-runs/run-2/sandbox/egregore`;
const REGISTRY = `${H}/.egregore/instances.json`;
const CACHE = guard.cachePath(P);
const EVAL = `${H}/.egregore/runtime/eval`;
const COLLISION_OTHER = `${H}/work/a`;
const COLLISION_OWN = `${H}/work/a--claude-worktrees-local`;
const enc = (dir) => dir.replace(/[^A-Za-z0-9]/g, "-");
const transcript = (dir) => `${H}/.claude/projects/${enc(dir)}`;
const OTHER_TRANSCRIPTS = transcript(R);
const UNKNOWN_TRANSCRIPTS = `${H}/.claude/projects/unregistered-project`;
const projects = [P, N, W, F, EVAL, COLLISION_OWN];

for (const dir of [P, `${P}/src`, `${P}/rival`, `${P}/tmp`, `${P}/deep/nest`, NESTED, MEMORY, SITE, R, `${R}/sub`,
  `${H}/dev/rival-notes`, N, `${H}/dev/other`, `${H}/Documents`, `${H}/Downloads`, `${H}/.egregore`,
  `${MAIN}/.git/worktrees/task`, W, F, COLLISION_OTHER, COLLISION_OWN]) {
  fs.mkdirSync(dir, { recursive: true });
}
fs.writeFileSync(`${P}/README.md`, "acme\n");
fs.writeFileSync(`${P}/package.json`, "{}\n");
fs.writeFileSync(`${P}/src/index.js`, "// TODO\n");
fs.writeFileSync(`${P}/rival/README.md`, "a project folder that shares a name with another instance\n");
fs.writeFileSync(`${NESTED}/secret.txt`, "sandbox secret\n");
fs.writeFileSync(`${MEMORY}/note.md`, "memory\n");
fs.writeFileSync(`${SITE}/README.md`, "site\n");
fs.writeFileSync(`${R}/secret.txt`, "rival secret\n");
fs.writeFileSync(`${OUTER}/note.md`, "outer note\n");
fs.writeFileSync(`${N}/README.md`, "nested\n");
fs.writeFileSync(`${H}/Documents/plan.md`, "plan\n");
fs.writeFileSync(`${H}/Downloads/report.txt`, "report\n");
fs.symlinkSync(MEMORY, `${P}/memory`);
fs.symlinkSync(P, P_ALIAS);
fs.symlinkSync(R, R_ALIAS);
fs.symlinkSync(R, `${P}/link-to-rival`);
fs.symlinkSync(`${R}/sub`, `${P}/link-to-rival-sub`);
fs.symlinkSync(`${SYSTEM_TMP}/other/nest`, `${P}/link-to-tmp`);
fs.mkdirSync(`${H}/dev/bridge`, { recursive: true });
fs.symlinkSync(`${H}/dev/bridge`, `${P}/link-to-bridge`);
fs.symlinkSync(`${SYSTEM_TMP}/other/nest`, `${H}/dev/bridge/link`);
fs.symlinkSync(R, `${P}/deep/nest/inner-link`); // a link below the first wildcard level
fs.writeFileSync(`${W}/.git`, `gitdir: ${MAIN}/.git/worktrees/task\n`);
fs.writeFileSync(`${MAIN}/.git/worktrees/task/gitdir`, `${W}/.git\n`); // git's back-link
fs.writeFileSync(`${F}/.git`, `gitdir: ${R}/.git/worktrees/forged\n`);
fs.writeFileSync(`${F}/egregore.json`, JSON.stringify({ org_id: "org-forger" }));
fs.writeFileSync(`${N}/egregore.json`, JSON.stringify({ org_id: "org-acme" }));
fs.writeFileSync(`${W}/egregore.json`, JSON.stringify({ org_id: "org-legacy" }));
fs.writeFileSync(`${COLLISION_OWN}/egregore.json`, JSON.stringify({ org_id: "org-collision" }));
fs.symlinkSync(`${H}/.egregore/runtime`, `${P}/link-to-runtime`);
fs.symlinkSync(`${H}/.egregore/mind`, `${P}/link-to-mind`);
fs.symlinkSync(`${H}/.egregore/exports`, `${P}/link-to-exports`);
// A case-insensitive file system resolves another spelling of the instance.
const CASE_FOLDS = fs.existsSync(`${H}/dev/RIVAL`);

const registryEntries = [
  { slug: "acme", name: "Acme", path: P, org_id: "org-acme" },
  { slug: "rival", name: "Rival", path: R, org_id: "org-rival" },
  { slug: "outer", name: "Outer", path: OUTER, org_id: "org-outer" },
  { slug: "legacy", name: "Legacy", path: MAIN },
];
const nestedEntry = { slug: "curvelabs", name: "Curve Labs", path: NESTED };

function cleanup() {
  fs.rmSync(H, { recursive: true, force: true });
  fs.rmSync(SYSTEM_TMP, { recursive: true, force: true });
  for (const project of projects) fs.rmSync(guard.cachePath(project), { force: true });
}
process.on("exit", cleanup);

function withHome(fn) {
  const saved = process.env.HOME;
  process.env.HOME = H;
  try { return fn(); } finally { process.env.HOME = saved; }
}

// state: { posture, locked, personal, consent, nested,
//          cache: "write" | "none" | "empty-object" | "planted",
//          registry: "ok" | "corrupt" | "empty" | "missing" | "unreadable",
//          registryAfterCache: "empty" | "missing" }
// Reset only this synthetic HOME. Directory-shaped registry fixtures produce
// an actual read error even when the test runner is privileged.
function resetSharedState(state) {
  for (const dir of [REGISTRY.replace(/\/instances\.json$/, ""), `${H}/shared-state`, `${H}/.claude/projects`, `${H}/shared-transcripts`]) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  if (state.shared !== "absent") {
    if (state.sharedSymlink) {
      fs.mkdirSync(`${H}/shared-state`, { recursive: true });
      fs.symlinkSync(`${H}/shared-state`, `${H}/.egregore`);
    } else fs.mkdirSync(`${H}/.egregore`, { recursive: true });
    if (state.shared === "file-only") fs.writeFileSync(`${H}/.egregore/secret-state.json`, "secret\n");
    else {
      for (const family of ["loom", "loom-ledger", "telemetry", "telemetry-spool", "platform", "exports", "context", "runtime", "mind"]) {
        fs.mkdirSync(`${H}/.egregore/${family}`, { recursive: true });
      }
      fs.writeFileSync(`${H}/.egregore/emissary-config.json`, "{}\n");
      fs.mkdirSync(EVAL, { recursive: true });
      fs.writeFileSync(`${EVAL}/egregore.json`, JSON.stringify({ org_id: "org-acme" }));
      fs.writeFileSync(`${EVAL}/own.txt`, "own\n");
      fs.mkdirSync(`${H}/.egregore/mind/sub`, { recursive: true });
      fs.symlinkSync(`${H}/.egregore/exports`, `${H}/.egregore/unknown-to-exports`);
      fs.symlinkSync(`${H}/.egregore/mind/sub`, `${H}/.egregore/exports/link`);
      if (state.exportsExternal) {
        fs.rmSync(`${H}/.egregore/exports`, { recursive: true });
        fs.symlinkSync(`${SYSTEM_TMP}/exports`, `${H}/.egregore/exports`);
      } else if (state.exportsWalkLink) {
        fs.unlinkSync(`${H}/.egregore/exports/link`);
        fs.symlinkSync("../mind", `${H}/.egregore/exports/link`);
      }
    }
  }
  fs.mkdirSync(`${H}/.claude`, { recursive: true });
  if (state.transcriptsSymlink) {
    fs.mkdirSync(`${H}/shared-transcripts`, { recursive: true });
    fs.symlinkSync(`${H}/shared-transcripts`, `${H}/.claude/projects`);
  } else fs.mkdirSync(`${H}/.claude/projects`, { recursive: true });
  for (const dir of [transcript(P), transcript(P_ALIAS), transcript(R), transcript(R_ALIAS), `${transcript(R)}--claude-worktrees-task`, transcript(OUTER), transcript(MAIN), transcript(W), UNKNOWN_TRANSCRIPTS,
    transcript(COLLISION_OTHER), transcript(COLLISION_OWN), `${transcript(COLLISION_OWN)}--claude-worktrees-child`]) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(`${dir}/session.jsonl`, "transcript\n");
  }
}

function applyState(state = {}) {
  resetSharedState(state);
  const boundary = {};
  if (state.posture) boundary.posture = state.posture;
  if (state.locked) boundary.locked = true;
  if (state.readRoots) boundary.read = state.readRoots;
  fs.writeFileSync(`${P}/egregore.json`, JSON.stringify({ org_id: "org-acme", repos: ["acme-site"], boundary }));
  const personal = `${P}/.egregore-boundary.local.json`;
  if (state.personal) fs.writeFileSync(personal, JSON.stringify(state.personal));
  else fs.rmSync(personal, { force: true });
  const consent = `${P}/.egregore-boundary-consent`;
  if (state.consent) fs.writeFileSync(consent, state.consent.map((line) => `${line}\n`).join(""));
  else fs.rmSync(consent, { force: true });
  const entries = state.noInstances ? [] : state.aliasRegistry ? registryEntries.map((entry) => entry.path === R ? { ...entry, path: R_ALIAS } : entry) : state.collision ? [
    { path: COLLISION_OTHER, org_id: "org-other" },
    { path: COLLISION_OWN, org_id: "org-collision" },
  ] : state.nested ? [...registryEntries, nestedEntry] : registryEntries;
  const registry = { corrupt: "{ not json", empty: "" }[state.registry] ?? JSON.stringify(entries);
  if (state.shared !== "absent" && state.registry !== "missing") {
    if (state.registry === "unreadable") fs.mkdirSync(REGISTRY);
    else fs.writeFileSync(REGISTRY, registry);
  }
  for (const project of projects) {
    const cache = guard.cachePath(project);
    fs.rmSync(cache, { force: true });
    if (state.cache === "empty-object") fs.writeFileSync(cache, "{}\n");
    else if (state.cache === "planted") fs.writeFileSync(cache, JSON.stringify({ project_dir: project, posture: "open", managed_repos: [], denied_paths: [] }));
    else if (state.cache !== "none") withHome(() => guard.writeCache(project));
  }
  // Damage after session start: the cache keeps what the registry lost.
  if (state.registryAfterCache === "empty") fs.writeFileSync(REGISTRY, "");
  if (state.registryAfterCache === "missing") fs.rmSync(REGISTRY, { force: true });
  if (state.lateFamily) {
    withHome(() => guard.nativeDenials(P));
    fs.mkdirSync(`${H}/.egregore/created-after-native`, { recursive: true });
  }
}

// ── Adapters ──────────────────────────────────────────────────────────────
const nativeEnv = (row, extra) => {
  const env = { ...process.env, HOME: H };
  // Each adapter names its own project; nothing leaks in from this shell.
  delete env.CLAUDE_PROJECT_DIR;
  delete env.EGREGORE_CODEX_PROJECT_DIR;
  delete env.EGREGORE_BOUNDARY_TEST_FAULT;
  delete env.NODE_OPTIONS;
  if (row.fault) env.EGREGORE_BOUNDARY_TEST_FAULT = "1";
  return { ...env, ...extra };
};

function spawnHook(command, args, row, payload, extraEnv, cwd = ROOT) {
  const result = spawnSync(command, args, {
    cwd,
    input: JSON.stringify(payload),
    encoding: "utf8",
    env: nativeEnv(row, extraEnv),
  });
  return { status: result.status, message: String(result.stderr || "").trim() };
}

// The PreToolUse entries a host runs for this tool: matchers are anchored
// alternations of tool names.
function registered(groups, tool, script) {
  return (groups || [])
    .filter((group) => new RegExp(`^(?:${group.matcher || ".*"})$`).test(tool))
    .flatMap((group) => group.hooks || [])
    .filter((hook) => script.test(String(hook.command || "")));
}

const UNMATCHED = { status: 0, message: "", unmatched: true };

function claudeDispatch(tool, payload, row, extraEnv) {
  if (!registered(CLAUDE_SETTINGS.hooks.PreToolUse, tool, /boundary-check\.sh/).length) return UNMATCHED;
  return spawnHook("bash", [CLAUDE_HOOK], row, payload, extraEnv);
}

function codexDispatch(tool, payload, row, extraEnv, cwd = ROOT) {
  const hooks = registered(CODEX_HOOKS.hooks.PreToolUse, tool, /boundary-hook\.sh/);
  if (!hooks.length) return UNMATCHED;
  // Codex runs the command from the checkout; the launcher's project
  // override names the fixture project.
  return spawnHook("bash", ["-c", hooks[0].command], row, payload, extraEnv, cwd);
}

function claude(row) {
  const project = row.project || P;
  const { op } = row;
  const tool = {
    read: ["Read", { file_path: op.target }],
    search: ["Grep", { pattern: "plan", path: op.target }],
    glob: ["Glob", { pattern: op.target }],
    write: ["Write", { file_path: op.target, content: "x" }],
    shell: ["Bash", { command: op.command }],
  }[op.kind];
  const payload = {
    hook_event_name: "PreToolUse",
    cwd: row.cwd || project,
    permission_mode: row.bypass ? "bypassPermissions" : "default",
    tool_name: tool[0],
    tool_input: tool[1],
  };
  return claudeDispatch(tool[0], payload, row, { CLAUDE_PROJECT_DIR: project });
}

function codex(row) {
  const project = row.project || P;
  const { op } = row;
  const quote = (value) => `'${value}'`;
  const exec = (cmd) => ["exec_command", { cmd, workdir: row.cwd || project }];
  const tool = {
    read: () => exec(`cat ${op.target.startsWith("~") ? op.target : quote(op.target)}`),
    search: () => exec(`rg -n plan ${quote(op.target)}`),
    glob: () => exec(`ls ${op.target}`),
    write: () => ["apply_patch", { command: `*** Begin Patch\n*** Add File: ${op.target}\n+x\n*** End Patch\n` }],
    shell: () => exec(op.command),
  }[op.kind]();
  const payload = {
    hook_event_name: "PreToolUse",
    cwd: project,
    permission_mode: row.bypass ? "bypassPermissions" : "default",
    tool_name: tool[0],
    tool_input: tool[1],
  };
  return codexDispatch(tool[0], payload, row, { EGREGORE_CODEX_PROJECT_DIR: project });
}

function piEvent(op) {
  return {
    read: { toolName: "read", input: { path: op.target } },
    search: { toolName: "grep", input: { pattern: "plan", path: op.target } },
    glob: { toolName: "find", input: { pattern: op.target } },
    write: { toolName: "write", input: { path: op.target, content: "x" } },
    shell: { toolName: "bash", input: { command: op.command } },
  }[op.kind] || op.event;
}

function inProcess(row, fn) {
  const saved = { HOME: process.env.HOME, FAULT: process.env.EGREGORE_BOUNDARY_TEST_FAULT };
  process.env.HOME = H;
  if (row.fault) process.env.EGREGORE_BOUNDARY_TEST_FAULT = "1";
  else delete process.env.EGREGORE_BOUNDARY_TEST_FAULT;
  try {
    return fn();
  } finally {
    process.env.HOME = saved.HOME;
    if (saved.FAULT === undefined) delete process.env.EGREGORE_BOUNDARY_TEST_FAULT;
    else process.env.EGREGORE_BOUNDARY_TEST_FAULT = saved.FAULT;
  }
}

function pi(row) {
  const project = row.project || P;
  const block = inProcess(row, () => guard.toolCallBlock(piEvent(row.op), { cwd: row.cwd || project }, project));
  return block ? { status: 2, message: block.reason } : { status: 0, message: "" };
}

function classify({ status, message, unmatched }) {
  if (unmatched) return "unmatched";
  if (status === 0) return "allow";
  if (status !== 2) return `exit-${status}`;
  if (/shared per-user state|Claude transcripts/.test(message)) return "hard-state";
  if (/another Egregore instance/.test(message)) return "instance";
  if (/instance registry .* cannot be read/.test(message)) return "registry";
  if (/isolation state/.test(message)) return "state-write";
  if (/boundary is locked/.test(message)) return "locked";
  if (/Boundary consent needed/.test(message)) return "consent";
  if (/boundary check failed/.test(message)) return "internal";
  if (/boundary guard missing/.test(message)) return "missing";
  if (/boundary check could not run/.test(message)) return "startup";
  return "unclassified";
}

// ── Fixture table ─────────────────────────────────────────────────────────
const read = (target) => ({ kind: "read", target });
const search = (target) => ({ kind: "search", target });
const glob = (target) => ({ kind: "glob", target });
const write = (target) => ({ kind: "write", target });
const shell = (command) => ({ kind: "shell", command });
const OS_LAYER = "same-uid limit, OS track";

// Ordinary project work: every one must pass on every runtime. Includes the
// review-2 false denials (a project folder named like an instance, a cd that
// returns before a search, and the rest of the realistic sample).
const NORMAL_WORK = [
  "git status",
  "git log --oneline -5",
  "git diff HEAD~1 -- src/",
  "ls -la",
  "ls -la ..",
  "cat README.md",
  "cat rival/README.md",
  "cd src && cd .. && rg TODO .",
  "cd src && cat ../README.md",
  'rg -n "TODO|FIXME" src',
  "grep -rn plan src/ | head -5",
  'find src -name "*.js"',
  'find . -name "*.md" -not -path "./node_modules/*"',
  "sed -n 1,20p src/index.js",
  "head -50 memory/note.md",
  "cat memory/*.md",
  "git -C ../acme-site status",
  "ls ../acme-site/*.md",
  'rg -n "secret" ../acme-site',
  "npm test 2>&1 | tail -20",
  'node -e "console.log(process.cwd())"',
  `python3 -c "import json; print(json.load(open('package.json')))"`,
  "mkdir -p tmp/scratch && echo hi > tmp/scratch/note.txt",
  "cat /tmp/egregore-parity.log 2>/dev/null; ls /tmp",
  'echo "$USER" && pwd',
  "cat ~/.egregore/instances.json | jq length",
  "jq length ~/.egregore/instances.json",
  "cp ~/.egregore/instances.json /tmp/egregore-parity-registry-copy.json",
  "ls /tmp/egregore-boundary-*.json",
  'for f in src/*.js; do wc -l "$f"; done',
  "tar czf /tmp/acme-src.tgz src",
  "cp -r src /tmp/acme-src-copy",
  "du -sh src 2>/dev/null",
  "cd src && ls -R",
  "cd .. && ls",
  "make -C src build 2>/dev/null || true",
  'git commit -m "fix: update parser"',
  "echo 'a,b' | cut -d, -f1",
  "awk -F/ '{print $NF}' src/index.js",
  "curl -s https://api.github.com/repos/x/y | jq .name",
  "sort -u src/index.js > tmp/sorted.txt",
  "cat <<'EOF' > tmp/note.md\nUse the rival API docs.\nEOF",
  "(cd src && ls) && cat rival/README.md",
  "pushd src && popd && cat rival/README.md",
  "ls ~/Downloads/*.txt",
];

// With a stale sandbox registered inside the project's gitignored runtime
// state: ignore-respecting work goes on; direct access and walks that skip
// ignore rules are denied.
const NESTED_WORK = [
  "git status",
  "cat README.md",
  "rg TODO src",
  'rg -n "TODO" .',
  "cd src && cd .. && rg TODO .",
  "grep -rn plan src/",
  'find src -name "*.js"',
  "ls -la .egregore",
  "ls -R src",
];

const ROWS = [
  ...["standard", "open"].flatMap((posture) => [
    { name: `round 2: dd assignment fragment with repeated separators ${posture}`, state: { posture }, op: shell(`dd if=${H.replaceAll("/", "//")}//.egregore/runtime/x`), expect: "hard-state" },
    { name: `round 2: Mind path with repeated inner separators ${posture}`, state: { posture }, op: shell(`cat ${H}//.egregore//mind/x`), expect: "hard-state" },
    { name: `round 2: literal transcript assignment is checked ${posture}`, state: { posture }, op: shell(`x=/${OTHER_TRANSCRIPTS}/s.jsonl cat "$x"`), expect: "hard-state" },
    { name: `round 2: URL with repeated separators stays allowed ${posture}`, state: { posture }, op: shell("curl https://example.com//a"), expect: "allow" },
    { name: `round 2: git format is not protected state ${posture}`, state: { posture }, op: shell("git log --format=//%H"), expect: "allow" },
    { name: `round 2: sed empty pattern stays allowed ${posture}`, state: { posture }, op: shell("sed 's//x/' README.md"), expect: "allow" },
  ]),
  { name: "round 2: cd minus restores shared state root", op: shell("cd ~/.egregore; cd exports; cd -; cat runtime/secret"), expect: "hard-state" },
  { name: "round 2: popd restores shared state root", op: shell("cd ~/.egregore; pushd exports; popd; cat runtime/secret"), expect: "hard-state" },
  { name: "round 2: cd minus returns to own project", op: shell("cd src; cd -; cat README.md"), expect: "allow" },
  { name: "round 2: pushd updates previous directory", op: shell(`cd ~/.egregore/exports; pushd ${P}; cd -; cat ../runtime/secret`), expect: "hard-state" },
  { name: "round 2: popd updates previous directory", op: shell(`cd ~/.egregore/exports; pushd ${P}; popd; cd -; cat ../runtime/secret`), expect: "allow" },
  { name: "round 2: repeated cd minus swaps directories", op: shell(`cd ~/.egregore/exports; cd ${P}; cd -; cd -; cat ../runtime/secret`), expect: "allow" },
  { name: "round 2: cd dot updates previous directory", op: shell(`cd ~/.egregore/exports; cd ${P}; cd .; cd -; cat ../runtime/secret`), expect: "allow" },
  { name: "round 2: subshell restores previous directory", op: shell(`cd ~/.egregore/exports; cd ${P}; (cd src); cd -; cat ../runtime/secret`), expect: "hard-state" },
  { name: "round 2: subshell restores directory stack", op: shell(`cd ~/.egregore/exports; pushd ${P}; (pushd src); popd; cat ../runtime/secret`), expect: "hard-state" },
  { name: "round 2: subshell history does not leak into own work", op: shell(`cd ~/.egregore/exports; (cd ${P}); cd -; cat ../runtime/secret`), expect: "allow" },
  { name: "round 2: cd minus preserves logical symlink spelling", state: { exportsExternal: true }, op: shell(`cd ~/.egregore/exports; cd ${P}; cd -; cd ../runtime; cat secret`), expect: "hard-state" },
  ...["standard", "open"].flatMap((posture) => [
    { name: `round 1: double-slash Runtime path ${posture}`, state: { posture }, op: shell(`cat /${H}/.egregore/runtime/x`), expect: "hard-state" },
    { name: `round 1: triple-slash Mind path ${posture}`, state: { posture }, op: shell(`cat //${H}/.egregore/mind/x`), expect: "hard-state" },
    { name: `round 1: double-slash transcripts path ${posture}`, state: { posture }, op: shell(`cat /${OTHER_TRANSCRIPTS}/s.jsonl`), expect: "hard-state" },
    { name: `round 1: URL authority stays allowed ${posture}`, state: { posture }, op: shell("curl https://example.com/a"), expect: "allow" },
    { name: `round 1: logical cd escapes exports symlink ${posture}`, state: { posture, exportsExternal: true }, op: shell("cd ~/.egregore/exports; cd ../runtime; cat secret"), expect: "hard-state" },
    { name: `round 1: logical cd reaches rival via project symlink ${posture}`, state: { posture }, op: shell(`cd ${P}/link-to-tmp; cd ../../rival; cat secret`), expect: "instance" },
  ]),
  { name: "round 1: double-slash Mind stays hard under bypass", bypass: true, op: shell(`cat /${H}/.egregore/mind/x`), expect: "hard-state" },
  { name: "round 1: logical cwd survives pushd and popd", state: { exportsExternal: true }, op: shell(`cd ~/.egregore/exports; pushd ${P}; popd; cd ../runtime; cat secret`), expect: "hard-state" },
  { name: "round 1: logical cwd inside nested shell", state: { exportsExternal: true }, op: shell("bash -c 'cd ~/.egregore/exports; cd ../runtime; cat secret'"), expect: "hard-state" },
  { name: "round 1: incoming logical cwd retained", state: { exportsExternal: true }, cwd: `${H}/.egregore/exports`, op: shell("cd ../runtime; cat secret"), expect: "hard-state" },
  { name: "round 1: explicit physical cd keeps its resolved PWD", state: { exportsExternal: true }, op: shell("cd -P -- ~/.egregore/exports; cd ../runtime; cat secret"), expect: "allow" },
  { name: "round 1: last cd option restores logical traversal", state: { exportsExternal: true }, op: shell("cd -P -L ~/.egregore/exports; cd ../runtime; cat secret"), expect: "hard-state" },
  { name: "round 1: file operand uses physical cwd after logical cd diverges", op: shell("cd link-to-bridge/link; cd ..; cat ../rival/secret.txt"), expect: "instance" },
  // Shared HOME state is hard tier even when it belongs to this instance.
  { name: "shared state: other instance Runtime/QMD", op: read(`${H}/.egregore/runtime/org-rival/qmd/index.sqlite`), expect: "hard-state" },
  { name: "shared state: own instance Runtime/QMD", op: read(`${H}/.egregore/runtime/org-acme/qmd/index.sqlite`), expect: "hard-state" },
  ...["notices-org-rival.json", "session-org-rival.json", "greeting-card-org-rival.json", "graph-wal-org-rival.jsonl", "autosave.log", "attendant/state.json", "graph-cache/index.json", "notifications/state.json", "gh-identity-mismatch-rival", "dashboard-id-rival", "mind/org-rival/slot.json", "zzz-new/x"].map((suffix) => ({
    name: `shared state: denied family ${suffix}`, op: read(`${H}/.egregore/${suffix}`), expect: "hard-state",
  })),
  ...["loom/x", "loom-ledger/x", "telemetry/x", "telemetry-spool/x", "platform/x", "exports/x", "emissary-config.json", "context/x"].flatMap((suffix) => [
    { name: `shared state: allow-list read ${suffix}`, op: read(`${H}/.egregore/${suffix}`), expect: "allow" },
    { name: `shared state: allow-list write ${suffix}`, op: write(`${H}/.egregore/${suffix}`), expect: "allow" },
  ]),
  { name: "shared state: retired reports family denied", op: read(`${H}/.egregore/reports/x`), expect: "hard-state" },
  { name: "shared state: shell Runtime read", op: shell("cat ~/.egregore/runtime/x"), expect: "hard-state" },
  { name: "shared state: shell HOME Mind read", op: shell("cat $HOME/.egregore/mind/x"), expect: "hard-state" },
  { name: "shared state: shell unknown write", op: shell("echo hi > ~/.egregore/zzz-new/x"), expect: "hard-state" },
  { name: "shared state: shell loom ledger read", op: shell("cat ~/.egregore/loom/ledger-2026-10.jsonl"), expect: "allow" },
  { name: "shared state: survives consent", state: { consent: [`${H}/.egregore`] }, op: write(`${H}/.egregore/runtime/x`), expect: "hard-state" },
  { name: "shared state: survives read roots", state: { readRoots: [`${H}/.egregore`] }, op: read(`${H}/.egregore/runtime/x`), expect: "hard-state" },
  { name: "shared state: survives bypassPermissions", bypass: true, op: read(`${H}/.egregore/runtime/x`), expect: "hard-state" },
  { name: "shared state: survives open posture", state: { posture: "open" }, op: read(`${H}/.egregore/runtime/x`), expect: "hard-state" },
  { name: "shared state: missing root unknown family denied", state: { shared: "absent", cache: "none" }, op: read(`${H}/.egregore/zzz-new/x`), expect: "hard-state" },
  { name: "shared state: missing root allowed family allowed", state: { shared: "absent", cache: "none" }, op: write(`${H}/.egregore/exports/x`), expect: "allow" },
  { name: "shared state: missing root registry read allowed", state: { shared: "absent", cache: "none" }, op: read(REGISTRY), expect: "allow" },
  { name: "shared state: lexical unknown symlink into exports denied", op: read(`${H}/.egregore/unknown-to-exports/x`), expect: "hard-state" },
  { name: "shared state: allowed exports symlink into Mind denied", op: read(`${H}/.egregore/exports/link/x`), expect: "hard-state" },
  { name: "shared state: project symlink into Runtime denied", op: read(`${P}/link-to-runtime/x`), expect: "hard-state" },
  { name: "shared state: missing file beneath symlink into Mind denied", op: write(`${P}/link-to-mind/not-yet/nested/new.json`), expect: "hard-state" },
  { name: "shared state: project symlink into exports allowed", op: read(`${P}/link-to-exports/x`), expect: "allow" },
  { name: "shared state: symlinked HOME state Mind denied", state: { sharedSymlink: true }, op: read(`${H}/.egregore/mind/x`), expect: "hard-state" },
  { name: "shared state: symlinked HOME state physical Mind denied", state: { sharedSymlink: true }, op: read(`${H}/shared-state/mind/x`), expect: "hard-state" },
  { name: "shared state: symlinked HOME state exports allowed", state: { sharedSymlink: true }, op: read(`${H}/.egregore/exports/x`), expect: "allow" },
  { name: "shared state: normalized root traversal denied", op: read(`${H}/.egregore/../.egregore/mind/x`), expect: "hard-state" },
  { name: "shared state: normalized family traversal denied", op: read(`${H}/.egregore/exports/../mind/x`), expect: "hard-state" },
  { name: "shared state: trailing slash denied", op: read(`${H}/.egregore/mind/`), expect: "hard-state" },
  { name: "shared state: cwd keeps symlink then parent physical meaning", cwd: `${H}/.egregore/exports/link/../x`, op: shell("pwd"), expect: "hard-state" },
  { name: "shared state: own project under Runtime allowed", project: EVAL, op: read(`${EVAL}/own.txt`), expect: "allow" },
  { name: "shared state: Runtime outside nested own project denied", project: EVAL, op: read(`${H}/.egregore/runtime/other/x`), expect: "hard-state" },
  { name: "shared state: project-local .egregore stays allowed", op: write(`${P}/.egregore/runtime/own.json`), expect: "allow" },
  { name: "shared state: names-only listing allowed", op: shell("ls ~/.egregore"), expect: "allow" },
  { name: "shared state: recursive walk denied", op: shell("grep -r x ~/.egregore"), expect: "hard-state" },
  { name: "shared state: wildcard from shared root denied", op: shell("cat ~/.egregore/*/state.json"), expect: "hard-state" },
  { name: "shared state: structured search denied", op: search(`${H}/.egregore`), expect: "hard-state" },
  { name: "shared state: contained file alone denies walk", state: { shared: "file-only" }, op: shell("grep -r x ~/.egregore"), expect: "hard-state" },
  { name: "shared state: contained file alone denies wildcard", state: { shared: "file-only" }, op: shell("cat ~/.egregore/*.json"), expect: "hard-state" },
  { name: "shared state: contained file does not deny registry read", state: { shared: "file-only" }, op: read(REGISTRY), expect: "allow" },
  // A HOME walk now also encounters denied shared state without any registered
  // instance beneath HOME. This expands containment, not shell text visibility.
  { name: "shared state: HOME walk reaches denied file without other instances", state: { shared: "file-only", noInstances: true }, op: shell("grep -r x ~"), expect: "hard-state" },
  { name: "shared state: family created after native rules generated is hook-denied", state: { lateFamily: true }, op: read(`${H}/.egregore/created-after-native/state.json`), expect: "hard-state" },
  { name: "shared state: internal error still denies unknown family", fault: true, op: read(`${H}/.egregore/zzz-new/x`), expect: "hard-state" },
  { name: "shared state: internal error still denies lexical unknown symlink", fault: true, op: read(`${H}/.egregore/unknown-to-exports/x`), expect: "hard-state" },
  { name: "shared state: internal error permits exports", fault: true, op: read(`${H}/.egregore/exports/x`), expect: "allow" },
  { name: "shared state: internal error still denies unknown-family Glob", fault: true, op: glob(`${H}/.egregore/unknown-to-exports/*.txt`), expect: "hard-state" },
  { name: "shared state: internal error still denies recursive root walk", fault: true, op: shell("grep -r x ~/.egregore"), expect: "hard-state" },
  { name: "transcripts: other instance denied", op: read(`${OTHER_TRANSCRIPTS}/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: other instance worktree denied", op: read(`${OTHER_TRANSCRIPTS}--claude-worktrees-task/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: future other-instance worktree denied", op: write(`${OTHER_TRANSCRIPTS}--claude-worktrees-future/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: own instance allowed", op: read(`${transcript(P)}/session.jsonl`), expect: "allow" },
  { name: "transcripts: own future worktree allowed", op: write(`${transcript(P)}--claude-worktrees-future/session.jsonl`), expect: "allow" },
  { name: "transcripts: linked-worktree main encoding allowed", project: W, op: read(`${transcript(MAIN)}/session.jsonl`), expect: "allow" },
  { name: "transcripts: symlinked project lexical encoding allowed", project: P_ALIAS, op: read(`${transcript(P_ALIAS)}/session.jsonl`), expect: "allow" },
  { name: "transcripts: symlinked project physical encoding allowed", project: P_ALIAS, op: read(`${transcript(P)}/session.jsonl`), expect: "allow" },
  { name: "transcripts: denied registry alias lexical encoding denied", state: { aliasRegistry: true }, op: read(`${transcript(R_ALIAS)}/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: denied registry alias physical encoding denied", state: { aliasRegistry: true }, op: read(`${transcript(R)}/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: unregistered folder allowed with readable registry", op: read(`${UNKNOWN_TRANSCRIPTS}/session.jsonl`), expect: "allow" },
  { name: "transcripts: survives consent and open posture", state: { posture: "open", consent: [`${H}/.claude`] }, op: read(`${OTHER_TRANSCRIPTS}/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: survives bypassPermissions", bypass: true, op: read(`${OTHER_TRANSCRIPTS}/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: recursive walk denied", op: shell("grep -r x ~/.claude/projects"), expect: "hard-state" },
  { name: "transcripts: wildcard denied", op: shell("cat ~/.claude/projects/*/session.jsonl"), expect: "hard-state" },
  { name: "transcripts: names-only listing allowed", op: shell("ls ~/.claude/projects"), expect: "allow" },
  { name: "transcripts: symlinked projects root denied", state: { transcriptsSymlink: true }, op: read(`${OTHER_TRANSCRIPTS}/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: symlinked projects physical root denied", state: { transcriptsSymlink: true }, op: read(`${H}/shared-transcripts/${enc(R)}/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: cached denial survives registry deletion", state: { registryAfterCache: "missing" }, op: read(`${OTHER_TRANSCRIPTS}/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: cached denial survives registry corruption", state: { registryAfterCache: "empty" }, op: read(`${OTHER_TRANSCRIPTS}/session.jsonl`), expect: "registry" },
  ...["strict", "standard", "open"].flatMap((posture) => ["unreadable", "corrupt"].flatMap((registry) => [
    { name: `transcripts: ${registry} registry ${posture} denies other instance despite consent`, state: { posture, registry, cache: "none", consent: [`${H}/.claude`] }, op: read(`${OTHER_TRANSCRIPTS}/session.jsonl`), expect: "registry" },
    { name: `transcripts: ${registry} registry ${posture} denies unregistered folder despite consent`, state: { posture, registry, cache: "none", consent: [`${H}/.claude`] }, op: read(`${UNKNOWN_TRANSCRIPTS}/session.jsonl`), expect: "registry" },
    { name: `transcripts: ${registry} registry ${posture} allows own folder`, state: { posture, registry, cache: "none" }, op: read(`${transcript(P)}/session.jsonl`), expect: "allow" },
  ])),
  { name: "transcripts: absent registry permits own folder", state: { registry: "missing", cache: "none" }, op: read(`${transcript(P)}/session.jsonl`), expect: "allow" },
  { name: "transcripts: absent registry permits other folder", state: { registry: "missing", cache: "none" }, op: read(`${OTHER_TRANSCRIPTS}/session.jsonl`), expect: "allow" },
  { name: "transcripts: own encoding wins denied worktree collision", state: { collision: true }, project: COLLISION_OWN, op: read(`${transcript(COLLISION_OWN)}/session.jsonl`), expect: "allow" },
  { name: "transcripts: own worktree wins denied worktree collision", state: { collision: true }, project: COLLISION_OWN, op: read(`${transcript(COLLISION_OWN)}--claude-worktrees-child/session.jsonl`), expect: "allow" },
  { name: "transcripts: collision still denies other instance base", state: { collision: true }, project: COLLISION_OWN, op: read(`${transcript(COLLISION_OTHER)}/session.jsonl`), expect: "hard-state" },
  { name: "transcripts: internal error still denies other instance", fault: true, op: read(`${OTHER_TRANSCRIPTS}/session.jsonl`), expect: "hard-state" },
  // Hard tier: another instance, every form, every tool.
  { name: "read instance (absolute)", op: read(`${R}/secret.txt`), expect: "instance" },
  { name: "write instance (absolute)", op: write(`${R}/new.txt`), expect: "instance" },
  { name: "search instance", op: search(R), expect: "instance" },
  { name: "shell read instance", op: shell(`cat ${R}/secret.txt`), expect: "instance" },
  { name: "shell write instance", op: shell(`echo x > ${R}/new.txt`), expect: "instance" },
  { name: "read instance via ~", op: read("~/dev/rival/secret.txt"), expect: "instance" },
  { name: "shell instance via ~", op: shell("cat ~/dev/rival/secret.txt"), expect: "instance" },
  { name: "shell instance via $HOME", op: shell("cat $HOME/dev/rival/secret.txt"), expect: "instance" },
  { name: "shell instance via ${HOME} in quotes", op: shell('cat "${HOME}/dev/rival/secret.txt"'), expect: "instance" },
  { name: "shell instance via ../", op: shell("cat ../rival/secret.txt"), expect: "instance" },
  { name: "read instance via ../", op: read(`${P}/../rival/secret.txt`), expect: "instance" },
  { name: "read instance via symlink", op: read(`${P}/link-to-rival/secret.txt`), expect: "instance" },
  { name: "write instance via symlink", op: write(`${P}/link-to-rival/new.txt`), expect: "instance" },
  { name: "write via symlink below missing levels", op: write(`${P}/link-to-rival/a/b/new.txt`), expect: "instance" },
  { name: "read via symlink then .. (physical, not lexical)", op: read(`${P}/link-to-rival-sub/../secret.txt`), expect: "instance" },
  { name: "shell instance via symlink", op: shell("cat link-to-rival/secret.txt"), expect: "instance" },
  // The bash hook checked only the first 40 sorted tokens; this one sorts 46th.
  { name: "shell instance past 40 path tokens", op: shell(`ls ${Array.from({ length: 45 }, (_, i) => `src/f${i}`).join(" ")} zz/../../rival/secret.txt`), expect: "instance" },
  // Literal shell forms: quoting, cd / pushd in order, subshells, nested shells.
  { name: "shell cd then relative name", op: shell("cd .. && cat rival/secret.txt"), expect: "instance" },
  { name: "shell cd into the instance", op: shell("cd .. && cd rival && cat secret.txt"), expect: "instance" },
  { name: "shell cd to an absolute folder, bare name", op: shell("cd $HOME/dev && ls rival"), expect: "instance" },
  { name: "shell pushd then relative name", op: shell("pushd .. && cat rival/secret.txt"), expect: "instance" },
  { name: "shell subshell cd then relative name", op: shell("(cd .. && cat rival/secret.txt)"), expect: "instance" },
  { name: "shell bash -c script", op: shell("bash -c 'cd .. && cat rival/secret.txt'"), expect: "instance" },
  { name: "shell eval script", op: shell('eval "cd ..; cat rival/secret.txt"'), expect: "instance" },
  { name: "shell heredoc script to an interpreter", op: shell("python3 - <<'EOF'\nprint(open('../rival/secret.txt').read())\nEOF"), expect: "instance" },
  { name: "shell literal path inside a substitution", op: shell("cat $(echo ../rival)/secret.txt"), expect: "instance" },
  { name: "shell process substitution", op: shell("diff <(cat ../rival/secret.txt) README.md"), expect: "instance" },
  { name: "shell glob reaching the instance", op: shell("cat ../riv*/secret.txt"), expect: "instance" },
  { name: "shell quotes splitting the name", op: shell('cat ../ri"val"/secret.txt'), expect: "instance" },
  { name: "shell partly variable component", op: shell("D=val; cat ../ri${D}/secret.txt"), expect: "instance" },
  { name: "shell brace list", op: shell("cat ../{other,rival}/secret.txt"), expect: "instance" },
  { name: "shell command substitution", op: shell(`echo "$(cat ${R}/secret.txt)"`), expect: "instance" },
  // Review 2, finding 2: brace lists across components, wildcards through
  // symlinks, absolute program paths.
  { name: "review-2: brace list across path components", op: shell("cat {../rival,src}/secret.txt"), expect: "instance" },
  { name: "review-2: wildcard through a project symlink", op: shell("cat ./*/secret.txt"), expect: "hard-state" },
  { name: "review-2: absolute program path, recursive grep of the parent", op: shell("/usr/bin/grep -R secret .."), expect: "instance" },
  { name: "brace list above 64 items falls back to its prefix", op: shell(`cat ../{${Array.from({ length: 70 }, (_, i) => `n${i}`).join(",")}}/secret.txt`), expect: "instance" },
  // A relative name is read from the working directory; nothing is guessed.
  { name: "shell relative name from the working directory is project-local", op: shell("cat dev/rival/secret.txt"), expect: "allow" },
  // Recursive walks reach an instance below their root.
  { name: "shell recursive grep of the parent", op: shell("grep -rn secret .."), expect: "instance" },
  { name: "shell find from home", op: shell("find ~ -name secret.txt"), expect: "hard-state" },
  { name: "shell recursive walk after cd", op: shell("cd .. && rg secret"), expect: "instance" },
  { name: "shell rg from the parent", op: shell("rg secret .."), expect: "instance" },
  { name: "search the parent", op: search(`${H}/dev`), expect: "instance" },
  { name: "glob with an absolute pattern", op: glob(`${R}/*.txt`), expect: "instance" },
  { name: "glob whose wildcard reaches the instance", op: glob(`${H}/dev/riv*/*.txt`), expect: "instance" },
  { name: "working directory inside the instance", op: shell("cat secret.txt"), cwd: R, expect: "instance" },
  { name: "listing the parent is not a walk", op: shell("ls -la .."), expect: "allow" },
  { name: "sibling managed repo", op: shell("git -C ../acme-site status"), expect: "allow" },
  { name: "hard tier survives bypassPermissions", op: read(`${R}/secret.txt`), bypass: true, expect: "instance" },
  { name: "hard tier survives open posture", state: { posture: "open" }, op: read(`${R}/secret.txt`), expect: "instance" },
  { name: "hard tier survives a consent grant", state: { consent: [R] }, op: read(`${R}/secret.txt`), expect: "instance" },
  { name: "sibling sharing the instance prefix is not the instance", op: shell(`ls ${H}/dev/rival-notes/x`), expect: "allow" },
  // Isolation state: readable, never changed, moved or deleted.
  { name: "registry read allowed", op: read(REGISTRY), expect: "allow" },
  { name: "registry shell read allowed", op: shell("cat ~/.egregore/instances.json"), expect: "allow" },
  { name: "registry write denied", op: write(REGISTRY), expect: "state-write" },
  { name: "internal error: registry write denied", fault: true, op: write(REGISTRY), expect: "state-write" },
  { name: "boundary cache write denied", op: write(CACHE), expect: "state-write" },
  ...[
    "echo [] > ~/.egregore/instances.json",
    "echo [] >> ~/.egregore/instances.json",
    "echo [] | tee ~/.egregore/instances.json",
    "rm ~/.egregore/instances.json",
    "unlink ~/.egregore/instances.json",
    "/usr/bin/unlink ~/.egregore/instances.json",
    "mv ~/.egregore/instances.json /tmp/egregore-parity-moved.json",
    "truncate -s 0 ~/.egregore/instances.json",
    "cp /tmp/egregore-parity-empty.json ~/.egregore/instances.json",
    "cp /tmp/instances.json ~/.egregore/",
    "ln -sf /tmp/egregore-parity-empty.json ~/.egregore/instances.json",
    "sed -i '' 's/rival/x/' ~/.egregore/instances.json",
    "rm -rf ~/.egregore",
    "mv ~/.egregore ~/.egregore-old",
    "find ~/.egregore -name '*.json' -delete",
    `python3 -c "import os; os.remove(os.path.expanduser('~/.egregore/instances.json'))"`,
    "bash -c 'rm ~/.egregore/instances.json'",
    `rm ${CACHE}`,
    `echo '{}' > ${CACHE}`,
    "rm -f /tmp/egregore-boundary-*.json",
  ].map((command) => ({ name: `state: ${command}`, op: shell(command), expect: /^(?:rm -rf|find) ~\/.egregore(?:\s|$)/.test(command) ? "hard-state" : "state-write" })),
  // Self-scope carve-out: a project nested inside an unproven enclosing instance.
  { name: "nested project: own file allowed", project: N, op: read(`${N}/README.md`), expect: "allow" },
  { name: "nested project: shell own file allowed", project: N, op: shell("cat ./README.md"), expect: "allow" },
  { name: "nested project: own glob allowed", project: N, op: shell("cat ./*.md"), expect: "allow" },
  { name: "nested project: enclosing instance denied", project: N, op: read(`${OUTER}/note.md`), expect: "instance" },
  { name: "nested project: enclosing instance via ../ denied", project: N, op: shell("cat ../note.md"), expect: "instance" },
  { name: "nested project: wildcard over the enclosing instance denied", project: N, op: shell("cat ../*.md"), expect: "instance" },
  // Linked worktree: its main checkout is the same instance even without org_id.
  { name: "worktree: main checkout allowed", project: W, op: read(`${MAIN}/.git/worktrees/task`), expect: "allow" },
  { name: "worktree: foreign instance denied", project: W, op: read(`${R}/secret.txt`), expect: "instance" },
  { name: "forged .git naming an instance as main checkout", project: F, op: read(`${R}/secret.txt`), expect: "instance" },
  // An instance registered inside the project's runtime state (review 2, finding 4).
  ...NESTED_WORK.map((command) => ({ name: `nested sandbox: normal work: ${command}`, state: { nested: true }, op: shell(command), expect: "allow" })),
  { name: "nested sandbox: Grep the project (respects ignore rules)", state: { nested: true }, op: search(P), expect: "allow" },
  { name: "nested sandbox: glob in the project", state: { nested: true }, op: glob(`${P}/src/**/*.js`), expect: "allow" },
  { name: "nested sandbox: read inside the project", state: { nested: true }, op: read(`${P}/README.md`), expect: "allow" },
  { name: "nested sandbox: write inside the project", state: { nested: true }, op: write(`${P}/src/new.js`), expect: "allow" },
  { name: "nested sandbox: direct read denied", state: { nested: true }, op: read(`${NESTED}/secret.txt`), expect: "instance" },
  { name: "nested sandbox: direct write denied", state: { nested: true }, op: write(`${NESTED}/new.txt`), expect: "instance" },
  { name: "nested sandbox: shell relative read denied", state: { nested: true }, op: shell("cat .egregore/eval-runs/run-2/sandbox/egregore/secret.txt"), expect: "instance" },
  { name: "nested sandbox: wildcard naming it denied", state: { nested: true }, op: shell("cat .egregore/eval-runs/run-2/sandbox/*/secret.txt"), expect: "instance" },
  ...[
    "rg -uuu secret .",
    "rg --no-ignore secret .",
    "grep -R secret .",
    "grep -rn secret .",
    "ls -R .",
    "find . -name secret.txt",
    "cd .egregore && find .",
  ].map((command) => ({ name: `nested sandbox: walk without ignore rules denied: ${command}`, state: { nested: true }, op: shell(command), expect: "instance" })),
  // Soft tier and postures.
  { name: "read outside: consent", op: read(`${H}/Documents/plan.md`), expect: "consent" },
  { name: "write outside: consent", op: write(`${H}/Documents/out.md`), expect: "consent" },
  { name: "shell outside: consent", op: shell("cat ~/Documents/plan.md"), expect: "consent" },
  { name: "standard: inbox read allowed", op: read(`${H}/Downloads/report.txt`), expect: "allow" },
  { name: "standard: inbox write gated", op: write(`${H}/Downloads/out.txt`), expect: "consent" },
  { name: "strict: inbox read gated", state: { posture: "strict" }, op: read(`${H}/Downloads/report.txt`), expect: "consent" },
  { name: "open: outside read allowed", state: { posture: "open" }, op: read(`${H}/Documents/plan.md`), expect: "allow" },
  { name: "open: outside write gated", state: { posture: "open" }, op: write(`${H}/Documents/out.md`), expect: "consent" },
  { name: "personal open posture", state: { personal: { posture: "open" } }, op: read(`${H}/Documents/plan.md`), expect: "allow" },
  { name: "consent grant: read", state: { consent: [`${H}/Documents`] }, op: read(`${H}/Documents/plan.md`), expect: "allow" },
  { name: "consent grant: write", state: { consent: ["~/Documents"] }, op: write(`${H}/Documents/out.md`), expect: "allow" },
  { name: "consent grant for another dir", state: { consent: [`${H}/Music`] }, op: read(`${H}/Documents/plan.md`), expect: "consent" },
  { name: "locked: no consent path", state: { locked: true }, op: read(`${H}/Documents/plan.md`), expect: "locked" },
  { name: "locked: stale grant void", state: { locked: true, consent: [`${H}/Documents`] }, op: read(`${H}/Documents/plan.md`), expect: "locked" },
  { name: "locked: personal posture ignored", state: { locked: true, personal: { posture: "open" } }, op: read(`${H}/Documents/plan.md`), expect: "locked" },
  { name: "locked: bypass not honored", state: { locked: true }, op: read(`${H}/Documents/plan.md`), bypass: true, expect: "locked" },
  { name: "locked: inbox read allowed", state: { locked: true }, op: read(`${H}/Downloads/report.txt`), expect: "allow" },
  { name: "bypassPermissions skips soft read", op: read(`${H}/Documents/plan.md`), bypass: true, expect: "allow", pi: "consent" },
  { name: "bypassPermissions skips soft write", op: write(`${H}/Documents/out.md`), bypass: true, expect: "allow", pi: "consent" },
  { name: "bypassPermissions skips soft shell", op: shell("cat ~/Documents/plan.md"), bypass: true, expect: "allow", pi: "consent" },
  // Missing or damaged cache: the registry still decides, never fail-open.
  { name: "no cache: instance denied", state: { cache: "none" }, op: read(`${R}/secret.txt`), expect: "instance" },
  { name: "no cache: shell instance denied", state: { cache: "none" }, op: shell("cat ../rival/secret.txt"), expect: "instance" },
  { name: "no cache: outside still consent", state: { cache: "none" }, op: read(`${H}/Documents/plan.md`), expect: "consent" },
  { name: "no cache: inside allowed", state: { cache: "none" }, op: write(`${P}/src/new.js`), expect: "allow" },
  { name: "no cache: worktree main allowed", state: { cache: "none" }, project: W, op: read(`${MAIN}/.git/worktrees/task`), expect: "allow" },
  { name: "cache {}: instance denied", state: { cache: "empty-object" }, op: read(`${R}/secret.txt`), expect: "instance" },
  { name: "cache emptied of denials: instance denied", state: { cache: "planted" }, op: shell("cat ../rival/secret.txt"), expect: "instance" },
  // Registry gone after session start: denied = registry ∪ cache, never fewer.
  { name: "registry deleted after session start: cached denial kept", state: { registryAfterCache: "missing" }, op: shell("cat ../rival/secret.txt"), expect: "instance" },
  { name: "registry deleted after session start: read denied", state: { registryAfterCache: "missing" }, op: read(`${R}/secret.txt`), expect: "instance" },
  { name: "registry deleted after session start: inside allowed", state: { registryAfterCache: "missing" }, op: read(`${P}/README.md`), expect: "allow" },
  // Unreadable registry: known denials first, then everything outside the core boundary.
  { name: "registry unreadable: instance denied", state: { cache: "none", registry: "corrupt" }, op: read(`${R}/secret.txt`), expect: "registry" },
  { name: "registry unreadable: sibling denied", state: { cache: "none", registry: "corrupt" }, op: shell(`ls ${H}/dev/other`), expect: "registry" },
  { name: "registry unreadable: inbox denied", state: { cache: "none", registry: "corrupt" }, op: read(`${H}/Downloads/report.txt`), expect: "registry" },
  { name: "registry unreadable: inside allowed", state: { cache: "none", registry: "corrupt" }, op: read(`${P}/README.md`), expect: "allow" },
  { name: "registry unreadable: memory allowed", state: { cache: "none", registry: "corrupt" }, op: read(`${P}/memory/note.md`), expect: "allow" },
  { name: "registry unreadable: managed repo allowed", state: { cache: "none", registry: "corrupt" }, op: read(`${SITE}/README.md`), expect: "allow" },
  { name: "registry unreadable at session start", state: { registry: "corrupt" }, op: shell("cat ../rival/secret.txt"), expect: "registry" },
  { name: "registry unreadable after session start", state: { registry: "corrupt", cache: "planted" }, op: shell("cat ../rival/secret.txt"), expect: "registry" },
  { name: "empty registry: instance denied", state: { cache: "none", registry: "empty" }, op: read(`${R}/secret.txt`), expect: "registry" },
  { name: "empty registry: inside allowed", state: { cache: "none", registry: "empty" }, op: read(`${P}/README.md`), expect: "allow" },
  // Review 2, finding 5: a damaged registry never hides a known nested denial.
  { name: "registry emptied after session start: nested denial kept", state: { nested: true, registryAfterCache: "empty" }, op: read(`${NESTED}/secret.txt`), expect: "instance" },
  { name: "registry emptied after session start: nested shell denial kept", state: { nested: true, registryAfterCache: "empty" }, op: shell("cat .egregore/eval-runs/run-2/sandbox/egregore/secret.txt"), expect: "instance" },
  { name: "registry emptied after session start: inside allowed", state: { nested: true, registryAfterCache: "empty" }, op: read(`${P}/README.md`), expect: "allow" },
  // Internal error: known denials first, then deny outside the core boundary, allow inside.
  { name: "internal error: instance denied", fault: true, op: read(`${R}/secret.txt`), expect: "instance" },
  { name: "internal error: outside denied", fault: true, op: shell("cat ~/Documents/plan.md"), expect: "internal" },
  { name: "internal error: symlink escape denied", fault: true, op: read(`${P}/link-to-rival/secret.txt`), expect: "instance" },
  { name: "internal error: nested instance denied", fault: true, state: { nested: true }, op: read(`${NESTED}/secret.txt`), expect: "instance" },
  { name: "internal error: nested shell read denied", fault: true, state: { nested: true }, op: shell(`cat ${NESTED}/secret.txt`), expect: "instance" },
  { name: "internal error: inside read allowed", fault: true, op: read(`${P}/README.md`), expect: "allow" },
  { name: "internal error: inside write allowed", fault: true, op: write(`${P}/src/new.js`), expect: "allow" },
  { name: "internal error: managed repo allowed", fault: true, op: read(`${SITE}/README.md`), expect: "allow" },
  { name: "internal error: relative shell allowed", fault: true, op: shell("grep -r plan src/"), expect: "allow" },
  // Ordinary work (review 2, finding 7 and the realistic sample).
  ...NORMAL_WORK.map((command) => ({ name: `normal work: ${command.split("\n")[0]}`, op: shell(command), expect: "allow" })),
  // Linear time: 200 chained `cd .` steps (exponential before; timed below).
  { name: "200 chained cd . steps", op: shell(`${Array.from({ length: 200 }, () => "cd .").join(" && ")} && cat README.md`), expect: "allow" },
  // Documented limits: forms a text check cannot see. Expected to pass the
  // check on every runtime; their confinement is the OS-level layer's job.
  { name: "variable root (review 2)", op: shell('p=../; cat "${p}rival/secret.txt"'), expect: "allow", limit: OS_LAYER },
  { name: "path from command output", op: shell(`cat "$(printf '../ri%s' val)/secret.txt"`), expect: "allow", limit: OS_LAYER },
  { name: "directory from command output", op: shell('cd "$(dirname "$PWD")" && cat rival/secret.txt'), expect: "allow", limit: OS_LAYER },
  { name: "interpreter path arithmetic", op: shell(`python3 -c "import os; print(open(os.path.join('..', 'rival', 'secret.txt')).read())"`), expect: "allow", limit: OS_LAYER },
  { name: "encoded command", op: shell("echo Y2F0IC4uL3JpdmFsL3NlY3JldC50eHQ= | base64 -d | sh"), expect: "allow", limit: OS_LAYER },
  { name: "wildcard through a symlink below its first wildcard level", op: shell("cat deep/*/*/secret.txt"), expect: "allow", limit: OS_LAYER },
  { name: "recursive walk following a symlink planted in the project", op: shell("grep -R secret deep"), expect: "allow", limit: OS_LAYER },
  { name: "recursive walk following exports/link -> ../mind (same-uid limit, OS track)", state: { exportsWalkLink: true }, op: shell("grep -R x ~/.egregore/exports"), expect: "allow", limit: OS_LAYER },
];
if (CASE_FOLDS) {
  ROWS.push({ name: "letter case does not hide an instance", op: read(`${H}/dev/RIVAL/secret.txt`), expect: "instance" });
}

// Message contracts that ride on specific rows.
const MESSAGES = {
  "read outside: consent": { has: ["Always allow on this instance", "for this session", "Paste contents inline"] },
  // A blocked write offers only options that grant writes.
  "write outside: consent": { has: ["for this session", "Paste contents inline", "Cancel"], lacks: ["Always allow"] },
  "standard: inbox write gated": { lacks: ["Always allow"] },
  "read instance (absolute)": { has: ["cannot be consented"], lacks: ["AskUserQuestion"] },
  "registry write denied": { has: ["only session start maintains"] },
  "shared state: other instance Runtime/QMD": { has: ["cannot be consented"], lacks: ["AskUserQuestion", "Always allow"] },
  "transcripts: other instance denied": { has: ["cannot be consented"], lacks: ["AskUserQuestion", "Always allow"] },
  // The nested-walk denial names the nested path and suggests narrowing.
  "nested sandbox: walk without ignore rules denied: grep -R secret .": { has: [NESTED, "Narrow the search"] },
  "shell glob reaching the instance": { has: ["wildcard", R] },
};

// ── The real Pi / Prime extension handlers ───────────────────────────────
// Node strips the extensions' types natively; the two UI-only packages they
// import (rendering and tool schemas) are stubbed. On such a Node every
// import must succeed. An older Node without type stripping runs the shared
// delegate alone, and says so.
const STRIPS_TYPES = Boolean(process.features && process.features.typescript);

async function loadExtensionHandlers() {
  const stubs = {
    "@earendil-works/pi-tui": "export class Text { constructor(...args) { this.args = args; } }",
    typebox: "const any = new Proxy(function () {}, { get: () => any, apply: () => any }); export const Type = any; export default any;",
  };
  const loader = `const stubs = ${JSON.stringify(stubs)};
export async function resolve(specifier, context, next) {
  if (Object.hasOwn(stubs, specifier)) return { url: "data:text/javascript," + encodeURIComponent(stubs[specifier]), shortCircuit: true };
  return next(specifier, context);
}`;
  const handlers = {};
  const errors = {};
  const { register } = await import("node:module");
  register(`data:text/javascript,${encodeURIComponent(loader)}`);
  for (const [label, file] of [["pi-extension", ".pi/extensions/egregore.ts"], ["prime-extension", ".prime/agent/extensions/egregore.ts"]]) {
    try {
      const mod = await import(new URL(`file://${path.join(ROOT, file)}`).href);
      const activate = mod.default;
      handlers[label] = (project) => {
        const toolCall = [];
        const fake = new Proxy({}, {
          get: (_, key) => {
            if (key === "on") return (event, handler) => { if (event === "tool_call") toolCall.push(handler); };
            if (key === "exec") return async () => ({ stdout: "", stderr: "", code: 1 });
            return () => undefined;
          },
        });
        const cwd = process.cwd();
        process.chdir(project); // the extension captures its root at load
        try { activate(fake); } finally { process.chdir(cwd); }
        return async (event, ctx) => {
          for (const handler of toolCall) {
            const result = await handler(event, ctx);
            if (result && result.block) return result;
          }
          return undefined;
        };
      };
    } catch (error) {
      errors[label] = error;
    }
  }
  return { handlers, errors };
}

async function extensionAdapter(factory, row) {
  const project = row.project || P;
  const handler = factory(project);
  const saved = { HOME: process.env.HOME, FAULT: process.env.EGREGORE_BOUNDARY_TEST_FAULT };
  process.env.HOME = H;
  if (row.fault) process.env.EGREGORE_BOUNDARY_TEST_FAULT = "1";
  else delete process.env.EGREGORE_BOUNDARY_TEST_FAULT;
  try {
    const result = await handler(piEvent(row.op), { cwd: row.cwd || project, hasUI: false });
    return result && result.block ? { status: 2, message: result.reason } : { status: 0, message: "" };
  } finally {
    process.env.HOME = saved.HOME;
    if (saved.FAULT === undefined) delete process.env.EGREGORE_BOUNDARY_TEST_FAULT;
    else process.env.EGREGORE_BOUNDARY_TEST_FAULT = saved.FAULT;
  }
}

// ── Run ───────────────────────────────────────────────────────────────────
console.log("=== instance wall parity: Claude Code, Codex, Pi/Prime ===\n");
const loaded = await loadExtensionHandlers();
const extensions = loaded.handlers;
if (STRIPS_TYPES) {
  for (const label of ["pi-extension", "prime-extension"]) {
    loaded.errors[label]
      ? bad(`${label} loads on a Node that strips types`, String(loaded.errors[label] && loaded.errors[label].stack || loaded.errors[label]).split("\n").slice(0, 3).join(" | "))
      : ok(`${label} loads; its real tool_call handler runs every row`);
  }
} else {
  console.log(`  (this Node does not strip types; Pi rows run through the shared delegate only)\n`);
}

for (const row of ROWS) {
  applyState(row.state);
  const adapters = { claude: claude(row), codex: codex(row), pi: pi(row) };
  for (const [label, factory] of Object.entries(extensions)) {
    adapters[label] = await extensionAdapter(factory, row);
  }
  const problems = [];
  for (const [label, result] of Object.entries(adapters)) {
    const want = label === "claude" || label === "codex" ? row.expect : row.pi || row.expect;
    const got = classify(result);
    if (got !== want) problems.push(`${label}: expected ${want}, got ${got}${result.message ? ` — ${result.message.split("\n")[0].slice(0, 160)}` : ""}`);
    const contract = MESSAGES[row.name];
    if (contract && label !== "codex") {
      // Codex reads arrive as shell commands, so only the shell surface wording differs.
      for (const text of contract.has || []) if (!result.message.includes(text)) problems.push(`${label}: message lacks "${text}"`);
      for (const text of contract.lacks || []) if (result.message.includes(text)) problems.push(`${label}: message offers "${text}"`);
    }
  }
  const name = row.limit ? `LIMIT (${row.limit}): ${row.name}` : row.name;
  if (row.limit) limits++;
  problems.length ? bad(name, problems.join("\n        ")) : ok(name);
}

// ── Single-runtime surfaces ──────────────────────────────────────────────
console.log("");
applyState({});
const codexEnv = { EGREGORE_CODEX_PROJECT_DIR: P };
const stdin = (chars) => ({ hook_event_name: "PreToolUse", cwd: P, tool_name: "write_stdin", tool_input: { session_id: 7, chars } });
// write_stdin: each chunk is checked with the same literal rules.
for (const [name, chunks, want, limit] of [
  ["Codex write_stdin: a literal path into the instance", ["cat ../rival/secret.txt\n"], "instance"],
  ["Codex write_stdin: cd then a relative name in one chunk", ["cd .. && cat rival/secret.txt\n"], "instance"],
  ["Codex write_stdin: ordinary project search (review 2, finding 7)", ["rg TODO src\n"], "allow"],
  ["Codex write_stdin: an answer to a prompt", ["y\n"], "allow"],
  // Text checks cannot join chunks or remember a cd sent in an earlier call.
  ["Codex write_stdin: one command split across two calls (review 2, finding 3)", ["cat ../ri", "val/secret.txt\n"], "allow", OS_LAYER],
  ["Codex write_stdin: relative name after a cd sent in an earlier call", ["cat rival/secret.txt\n"], "allow", OS_LAYER],
]) {
  const got = chunks.map((chars) => classify(codexDispatch("write_stdin", stdin(chars), {}, codexEnv)));
  const label = limit ? `LIMIT (${limit}): ${name}` : name;
  if (limit) limits++;
  got.every((value) => value === want) ? ok(label) : bad(label, `expected ${want} for every chunk, got ${got.join(", ")}`);
}
// Codex `shell` takes an argv array; its script keeps its quoting.
const argv = codexDispatch("shell", { hook_event_name: "PreToolUse", cwd: P, tool_name: "shell", tool_input: { command: ["bash", "-lc", "cd .. && cat rival/secret.txt"] } }, {}, codexEnv);
classify(argv) === "instance" ? ok("Codex shell argv: the bash -lc script is read with its cd") : bad("Codex shell argv", JSON.stringify(argv));

const scroll = (source) => ({ toolName: "egregore_publish_scroll", input: { source, slug: "x", title: "x", author: "x", description: "x", version: "v1" } });
const mystery = (input) => ({ toolName: "mystery_tool", input });
const piSurfaces = [
  ["Pi publish_scroll source in another instance", scroll(`${R}/secret.txt`), "instance"],
  ["Pi publish_scroll @-source in another instance", scroll(`@${R}/secret.txt`), "instance"],
  ["Pi publish_scroll source inside the project", scroll("tmp/scroll/index.html"), "allow"],
  ["Pi unknown tool with a path field", mystery({ file_path: `${R}/secret.txt` }), "instance"],
  // Review 2, finding 8: nested objects, arrays and camelCase keys.
  ["Pi unknown tool: files[].path", mystery({ files: [{ path: `${R}/secret.txt` }] }), "instance"],
  ["Pi unknown tool: camelCase filePath", mystery({ filePath: `${R}/secret.txt` }), "instance"],
  ["Pi unknown tool: nested options.target.dir", mystery({ options: { target: { dir: R } } }), "instance"],
  ["Pi unknown tool: paths array", mystery({ paths: [`${P}/README.md`, `${R}/secret.txt`] }), "instance"],
  ["Pi unknown tool: sourceDir", mystery({ sourceDir: R }), "instance"],
  ["Pi unknown tool: workdir in another instance", mystery({ workdir: R }), "instance"],
  ["Pi unknown tool: content beside a path is not a path", mystery({ files: [{ path: "src/index.js", content: `see ${R}/secret.txt` }] }), "allow"],
  ["Pi tool text that only mentions a path", { toolName: "egregore_handoff", input: { briefing: `compare with ${R}` } }, "allow"],
  ["Prime ipython code is scanned like a shell command", { toolName: "ipython", input: { code: `print(open("${R}/secret.txt").read())` } }, "instance"],
];
for (const [name, event, want] of piSurfaces) {
  const row = { op: { kind: "event", event } };
  const results = { pi: pi(row) };
  for (const [label, factory] of Object.entries(extensions)) results[label] = await extensionAdapter(factory, row);
  const problems = Object.entries(results).map(([label, result]) => [label, classify(result)]).filter(([, got]) => got !== want);
  problems.length ? bad(name, problems.map(([label, got]) => `${label}: expected ${want}, got ${got}`).join("; ")) : ok(name);
}
const image = codexDispatch("view_image", { tool_name: "view_image", tool_input: { path: `${R}/x.png` }, cwd: P }, {}, codexEnv);
classify(image) === "instance" ? ok("Codex view_image is checked as a read") : bad("Codex view_image", JSON.stringify(image));

// ── Linear time ──────────────────────────────────────────────────────────
console.log("");
const timed = (steps) => {
  const command = `${Array.from({ length: steps }, () => "cd .").join(" && ")} && cat README.md`;
  const input = { tool_name: "Bash", tool_input: { command }, cwd: P };
  withHome(() => guard.decide(input, { projectDir: P })); // warm the module
  // The median of three runs: one run on a shared one-CPU runner can stall
  // past any budget (it did on 22 October at five times the budget).
  const runs = [0, 1, 2].map(() => {
    const start = process.hrtime.bigint();
    const verdict = withHome(() => guard.decide(input, { projectDir: P }));
    return { verdict, ms: Number(process.hrtime.bigint() - start) / 1e6 };
  }).sort((a, b) => a.ms - b.ms);
  return runs[1];
};
// A budget is a contract on a developer machine and a reading with a ceiling
// on a shared runner; bin/lib/budget.py holds the one rule for every suite.
// The helper is this checkout's, not the fixture project's (P has no bin/lib),
// and a failure to read it is loud: a silent fallback once left CI unwidened.
const budgetMs = (ms) => {
  const run = spawnSync("python3", [path.join(ROOT, "bin/lib/budget.py"), String(ms)], { encoding: "utf8" });
  const value = run.status === 0 ? Number(run.stdout.trim()) : NaN;
  if (!(Number.isFinite(value) && value > 0)) throw new Error(`bin/lib/budget.py ${ms}: ${run.stderr || run.error}`);
  return value;
};
const limit200 = budgetMs(200), limit2000 = budgetMs(2000);
const t200 = timed(200);
t200.verdict.outcome === "allow" && t200.ms < limit200
  ? ok(`200 chained cd . steps decide in ${t200.ms.toFixed(1)} ms median (budget 200 ms, limit ${limit200} ms)`)
  : bad("200 chained cd . steps", `${t200.verdict.outcome} in ${t200.ms.toFixed(1)} ms (limit ${limit200} ms)`);
const t2000 = timed(2000);
t2000.verdict.outcome === "allow" && t2000.ms < limit2000
  ? ok(`2000 chained cd . steps decide in ${t2000.ms.toFixed(1)} ms median (linear; budget 2000 ms, limit ${limit2000} ms)`)
  : bad("2000 chained cd . steps", `${t2000.verdict.outcome} in ${t2000.ms.toFixed(1)} ms (limit ${limit2000} ms)`);
const nestedBraces = timed(0); // baseline
const deepBrace = (() => {
  const command = `cat ${"{a,".repeat(200)}x${"}".repeat(200)}/secret.txt ${"(".repeat(300)}ls${")".repeat(300)}`;
  const start = process.hrtime.bigint();
  const verdict = withHome(() => guard.decide({ tool_name: "Bash", tool_input: { command }, cwd: P }, { projectDir: P }));
  return { verdict, ms: Number(process.hrtime.bigint() - start) / 1e6 };
})();
deepBrace.ms < 200 + nestedBraces.ms
  ? ok(`deeply nested braces and subshells stay bounded (${deepBrace.ms.toFixed(1)} ms)`)
  : bad("deeply nested braces and subshells", `${deepBrace.ms.toFixed(1)} ms`);

// ── Hook dispatch: a missing guard blocks, never a non-blocking error ────
console.log("");
const hookPayload = { tool_name: "Read", tool_input: { file_path: `${P}/README.md` }, cwd: P };
const preload = spawnHook("bash", [CLAUDE_HOOK], {}, { ...hookPayload, tool_input: { file_path: `${R}/secret.txt` } }, { CLAUDE_PROJECT_DIR: P, NODE_OPTIONS: `--require=${H}/missing-preload.cjs` });
classify(preload) === "instance" ? ok("an inherited Node preload cannot replace the check") : bad("NODE_OPTIONS preload", JSON.stringify(preload));
const copy = `${H}/hook-copy`;
fs.mkdirSync(`${copy}/bin`, { recursive: true });
fs.mkdirSync(`${copy}/.claude/hooks`, { recursive: true });
fs.copyFileSync(path.join(ROOT, ".claude/hooks/boundary-check.sh"), `${copy}/.claude/hooks/boundary-check.sh`);
spawnSync("git", ["init", "-q"], { cwd: copy });
const copyClaude = () => spawnHook("bash", [`${copy}/.claude/hooks/boundary-check.sh`], {}, hookPayload, { CLAUDE_PROJECT_DIR: P });
const codexCommand = registered(CODEX_HOOKS.hooks.PreToolUse, "exec_command", /boundary-hook\.sh/)[0].command;
const copyCodex = () => spawnHook("bash", ["-c", codexCommand], {}, { ...hookPayload, tool_name: "exec_command", tool_input: { cmd: "cat README.md", workdir: P } }, codexEnv, copy);
const expectMissing = (name, result, file) => (classify(result) === "missing" && result.message.includes(file) && result.message.includes("/update")
  ? ok(name) : bad(name, JSON.stringify(result)));
expectMissing("Claude adapter: missing bin/boundary-hook.sh blocks (exit 2, run /update)", copyClaude(), "bin/boundary-hook.sh");
expectMissing("Codex hook command: missing bin/boundary-hook.sh blocks (exit 2, run /update)", copyCodex(), "bin/boundary-hook.sh");
fs.copyFileSync(path.join(ROOT, "bin/boundary-hook.sh"), `${copy}/bin/boundary-hook.sh`);
expectMissing("Claude adapter: missing bin/boundary-guard.cjs blocks (exit 2, run /update)", copyClaude(), "bin/boundary-guard.cjs");
expectMissing("Codex hook command: missing bin/boundary-guard.cjs blocks (exit 2, run /update)", copyCodex(), "bin/boundary-guard.cjs");
fs.writeFileSync(`${copy}/bin/boundary-guard.cjs`, "process.exit(1);\n");
let started = copyClaude();
classify(started) === "startup" ? ok("a check that exits abnormally: denied") : bad("guard exit 1", JSON.stringify(started));
fs.writeFileSync(`${copy}/bin/boundary-guard.cjs`, "throw new Error('broken module');\n");
started = copyCodex();
classify(started) === "startup" ? ok("Codex entry: a module that fails to load is denied") : bad("Codex broken module", JSON.stringify(started));
fs.copyFileSync(GUARD, `${copy}/bin/boundary-guard.cjs`);
started = copyCodex();
classify(started) === "allow" ? ok("Codex hook command with its guard present runs the check") : bad("Codex hook command intact", JSON.stringify(started));

// ── Shared computation contracts ─────────────────────────────────────────
console.log("");
applyState({});
const cache = JSON.parse(fs.readFileSync(guard.cachePath(P), "utf8"));
(cache.denied_paths.includes(R) && cache.denied_paths.includes(OUTER) && !cache.denied_paths.includes(P))
  ? ok("write-cache: other orgs denied, the project itself excluded")
  : bad("write-cache denied paths", JSON.stringify(cache.denied_paths));
cache.memory_dir === MEMORY ? ok("write-cache: memory symlink resolved") : bad("write-cache memory_dir", cache.memory_dir);
const wtCache = JSON.parse(fs.readFileSync(guard.cachePath(W), "utf8"));
(!wtCache.denied_paths.includes(MAIN) && wtCache.managed_repos.includes(MAIN) && wtCache.denied_paths.includes(R))
  ? ok("write-cache: linked worktree allows its main checkout (no org_id needed)")
  : bad("write-cache worktree", JSON.stringify(wtCache));
const native = withHome(() => guard.nativeDenials(N));
(native.includes(`Read(/${R}/**)`) && native.includes(`Edit(/${R}/**)`) && !native.some((rule) => rule.includes(OUTER))
  && native.includes("Edit(~/.egregore/instances.json)"))
  ? ok("native-denials: absolute rules for other instances, none for an enclosing one, registry protected")
  : bad("native-denials", JSON.stringify(native));

// Exact native rule sets are independent expectations, not copies of the
// exported allow list or the generator. Native rules enumerate existing
// unknown families/transcripts; the hook covers entries created afterwards.
const FIXED_NATIVE = ["mind", "runtime", "attendant", "graph-cache", "notifications", "notices-*", "session-*", "greeting-card-*", "graph-wal*", "autosave.log", "gh-identity-mismatch-*", "dashboard-id-*"];
const nativePair = (target, bare = false) => ["Read", "Edit"].flatMap((action) => [
  `${action}(/${target}/**)`, ...(bare ? [`${action}(/${target})`] : []),
]);
function expectedNative({ roots = [`${H}/.egregore`], instances = [R, OUTER, MAIN], transcripts = [OTHER_TRANSCRIPTS, `${OTHER_TRANSCRIPTS}--claude-worktrees-task`, transcript(OUTER), transcript(MAIN), transcript(W)], entries = [["unknown-to-exports", true]], omit = [] } = {}) {
  return [...new Set([
    ...instances.flatMap((dir) => nativePair(dir)),
    ...roots.flatMap((root) => [
      ...FIXED_NATIVE.filter((family) => !omit.includes(family)).flatMap((family) => nativePair(`${root}/${family}`, family === "autosave.log" || family.includes("*"))),
      ...entries.flatMap(([entry, bare]) => nativePair(`${root}/${entry}`, bare)),
    ]),
    ...transcripts.flatMap((dir) => nativePair(dir)),
    "Edit(~/.egregore/instances.json)",
  ])].sort();
}
function assertNative(name, project, expected) {
  const actual = withHome(() => guard.nativeDenials(project)).sort();
  const missing = expected.filter((rule) => !actual.includes(rule));
  const extra = actual.filter((rule) => !expected.includes(rule));
  JSON.stringify(actual) === JSON.stringify(expected)
    ? ok(name)
    : bad(name, `missing ${JSON.stringify(missing)}; extra ${JSON.stringify(extra)}`);
}
assertNative("native exact set: fixed families, existing unknown entry, registered transcripts only", P, expectedNative());
applyState({ aliasRegistry: true });
assertNative("native exact set: registry aliases protect both instance and transcript spellings", P, expectedNative({
  instances: [R_ALIAS, R, OUTER, MAIN],
  transcripts: [transcript(R_ALIAS), OTHER_TRANSCRIPTS, `${OTHER_TRANSCRIPTS}--claude-worktrees-task`, transcript(OUTER), transcript(MAIN), transcript(W)],
}));
applyState({ shared: "file-only" });
assertNative("native exact set: an unknown file receives bare and recursive rules", P, expectedNative({ entries: [["secret-state.json", true]] }));
applyState({});
assertNative("native exact set: Runtime project omits its enclosing family rule", EVAL, expectedNative({ omit: ["runtime"] }));
const sessionEval = `${H}/.egregore/session-eval/eval`;
fs.mkdirSync(sessionEval, { recursive: true });
fs.writeFileSync(`${sessionEval}/egregore.json`, JSON.stringify({ org_id: "org-acme" }));
assertNative("native exact set: wildcard family rules cannot cover the own project", sessionEval, expectedNative({ omit: ["session-*"] }));
applyState({ collision: true });
assertNative("native exact set: own transcript encoding wins a denied-instance worktree collision", COLLISION_OWN, expectedNative({ instances: [COLLISION_OTHER], transcripts: [transcript(COLLISION_OTHER)] }));
applyState({ registry: "unreadable", cache: "none" });
const allOtherTranscripts = [P_ALIAS, R, R_ALIAS, OUTER, MAIN, W, COLLISION_OTHER, COLLISION_OWN].map(transcript).concat([
  `${OTHER_TRANSCRIPTS}--claude-worktrees-task`, UNKNOWN_TRANSCRIPTS, `${transcript(COLLISION_OWN)}--claude-worktrees-child`,
]);
assertNative("native exact set: unreadable registry denies every existing non-own transcript folder", P, expectedNative({ instances: [], transcripts: allOtherTranscripts }));
assertNative("native exact set: unreadable registry preserves lexical and physical own encodings", P_ALIAS, expectedNative({
  instances: [], transcripts: allOtherTranscripts.filter((dir) => dir !== transcript(P_ALIAS)),
}));
applyState({ sharedSymlink: true, transcriptsSymlink: true });
const transcriptForms = expectedNative().filter((rule) => rule.startsWith(`Read(/${H}/.claude/projects/`)).map((rule) => rule.slice(6, -4));
assertNative("native exact set: symlinked shared roots protect lexical and physical spellings", P, expectedNative({
  roots: [`${H}/.egregore`, `${H}/shared-state`],
  transcripts: transcriptForms.flatMap((dir) => [dir, dir.replace(`${H}/.claude/projects`, `${H}/shared-transcripts`)]),
}));
applyState({ lateFamily: true });
// The preceding applyState generates native rules before this family exists.
// Test the hook, not just a freshly generated native list, for that gap.
const lateInput = { tool_name: "Read", tool_input: { file_path: `${H}/.egregore/created-after-native/state.json` }, cwd: P };
const lateVerdict = withHome(() => guard.decide(lateInput, { projectDir: P }));
lateVerdict.outcome === "deny" && /shared per-user state/.test(lateVerdict.message)
  ? ok("native generation gap: a later unknown family is still hard-denied by the hook")
  : bad("native generation gap", JSON.stringify(lateVerdict));

// The standalone check command enters the same hard tier, including lexical
// aliases whose physical target would otherwise be core-allowed.
applyState({});
for (const [label, target, want] of [
  ["shared unknown", `${H}/.egregore/zzz-new/x`, 1],
  ["lexical unknown symlink", `${H}/.egregore/unknown-to-exports/x`, 1],
  ["physical Mind symlink", `${P}/link-to-mind/new/x`, 1],
  ["other transcripts", `${OTHER_TRANSCRIPTS}/session.jsonl`, 1],
  ["allowed exports", `${H}/.egregore/exports/x`, 0],
  ["retired reports", `${H}/.egregore/reports/x`, 1],
  ["own transcripts", `${transcript(P)}/session.jsonl`, 0],
]) {
  const checked = spawnSync(process.execPath, [GUARD, "check", target, "--project-dir", P], { encoding: "utf8", env: nativeEnv({}, {}) });
  checked.status === want ? ok(`check CLI: ${label}`) : bad(`check CLI: ${label}`, `expected ${want}, got ${checked.status}: ${checked.stdout}${checked.stderr}`);
}

applyState({ registry: "corrupt" });
const corrupt = JSON.parse(fs.readFileSync(guard.cachePath(P), "utf8"));
corrupt.registry_unreadable === true
  ? ok("write-cache: an unreadable registry is recorded, not read as empty")
  : bad("write-cache unreadable registry", JSON.stringify(corrupt));
const cli = spawnSync("bash", [path.join(ROOT, "bin", "boundary.sh"), "compute-denied", REGISTRY, P, "org-acme"], { encoding: "utf8", env: { ...process.env, HOME: H } });
(cli.status === 1 && !cli.stdout.trim())
  ? ok("boundary.sh compute-denied fails on an unreadable registry")
  : bad("compute-denied unreadable registry", `status ${cli.status}: ${cli.stdout}`);

// Every runtime entry point routes through the one implementation.
const codexEntry = CODEX_HOOKS.hooks.PreToolUse.find((entry) => entry.hooks.some((hook) => /bin\/boundary-hook\.sh/.test(hook.command)));
const codexMatcher = codexEntry ? new RegExp(`^(?:${codexEntry.matcher})$`) : null;
(codexMatcher && ["Bash", "exec_command", "shell", "write_stdin", "apply_patch", "view_image"].every((name) => codexMatcher.test(name))
  && codexEntry.hooks.some((hook) => /exec bash "\$h" codex/.test(hook.command) && /exit 2$/.test(hook.command)))
  ? ok("Codex PreToolUse registers the boundary hook for shell, continuation, patch and image reads, failing closed")
  : bad("Codex hooks.json boundary entry", JSON.stringify(codexEntry));
const claudeMatcher = ["Read", "Edit", "Write", "NotebookEdit", "Bash", "Glob", "Grep"]
  .every((name) => registered(CLAUDE_SETTINGS.hooks.PreToolUse, name, /boundary-check\.sh/).length);
claudeMatcher ? ok("Claude PreToolUse registers the boundary hook for every file and shell tool") : bad("Claude settings.json boundary matcher");
for (const rel of [".pi/extensions/egregore.ts", ".prime/agent/extensions/egregore.ts"]) {
  /boundaryGuard\.toolCallBlock\(event, ctx, root\)/.test(read_(rel))
    ? ok(`${rel} gates tool_call through the shared check`)
    : bad(`${rel} does not delegate tool_call to boundary-guard`);
}
/bin\/boundary-hook\.sh/.test(read_(".claude/hooks/boundary-check.sh")) && !/jq/.test(read_(".claude/hooks/boundary-check.sh"))
  ? ok("Claude hook is a thin adapter")
  : bad("Claude hook still carries policy");
for (const rel of ["bin/session-start.sh", "bin/codex-session-start.sh", "bin/worktree-create.sh"]) {
  /boundary-guard\.cjs" write-cache/.test(read_(rel))
    ? ok(`${rel} writes the boundary cache through the shared computation`)
    : bad(`${rel} does not use boundary-guard write-cache`);
}
/boundary-guard\.cjs" native-denials/.test(read_("bin/session-start.sh")) && !/"Read\(" \+/.test(read_("bin/session-start.sh"))
  ? ok("Claude native deny rules come from the shared module")
  : bad("bin/session-start.sh builds its own deny rules");

// ── Registry maintenance (session start) ─────────────────────────────────
// Synthetic registry only: the developer's real registry is never touched.
console.log("");
const LIB = path.join(ROOT, "bin/lib/instance-registry.sh");
const MAINT = `${H}/maint`;
const maintRegistry = `${MAINT}/instances.json`;
const M = `${H}/dev/main-checkout`;
const sandboxes = [`${M}/.egregore/eval-runs/egregore-value/run-2/sandbox/egregore`, `${M}/.egregore/eval-runs/egregore-value/run-2/sandbox/bare`];
fs.mkdirSync(MAINT, { recursive: true });
const library = (script) => spawnSync("bash", ["-c", `source "${LIB}" && ${script}`], { encoding: "utf8", env: { ...process.env, HOME: MAINT } });
const registryNow = () => JSON.parse(fs.readFileSync(maintRegistry, "utf8"));
const before = [
  { slug: "curvelabs", name: "Curve Labs", path: M, org_id: "org-cl" },
  { slug: "rival", name: "Rival", path: R, org_id: "org-rival" },
  ...sandboxes.map((sandbox) => ({ slug: "curvelabs", name: "Curve Labs", path: sandbox })),
  { slug: "notes", name: "Notes", path: `${M}/.egregore-notes/x` }, // beside, not inside, .egregore/
  "a malformed entry stays",
];
fs.writeFileSync(maintRegistry, `${JSON.stringify(before, null, 2)}\n`);
library(`egregore_registry_prune "${maintRegistry}"`);
const pruned = registryNow();
const prunedPaths = pruned.map((entry) => entry && entry.path).filter(Boolean);
(sandboxes.every((sandbox) => !prunedPaths.includes(sandbox)) && [M, R, `${M}/.egregore-notes/x`].every((p) => prunedPaths.includes(p))
  && pruned.includes("a malformed entry stays") && pruned.length === before.length - 2)
  ? ok(`prune: removed ${before.length - pruned.length} entries inside another instance's .egregore/ (eval sandboxes), kept the rest`)
  : bad("prune", JSON.stringify(pruned));
fs.readdirSync(MAINT).filter((name) => name.includes(".tmp")).length === 0
  ? ok("prune: writes through a renamed temporary file, none left behind")
  : bad("prune temporaries", fs.readdirSync(MAINT).join(", "));
const stable = fs.readFileSync(maintRegistry, "utf8");
fs.writeFileSync(maintRegistry, JSON.stringify(registryNow()));
const compact = fs.readFileSync(maintRegistry, "utf8");
library(`egregore_registry_prune "${maintRegistry}"`);
fs.readFileSync(maintRegistry, "utf8") === compact ? ok("prune: nothing to prune leaves the registry byte-for-byte") : bad("prune rewrote a clean registry");
fs.writeFileSync(maintRegistry, stable);
library(`egregore_registry_register "${maintRegistry}" "${sandboxes[0]}" curvelabs "Curve Labs" ""`);
!registryNow().some((entry) => entry && entry.path === sandboxes[0])
  ? ok("register: a checkout inside another instance's .egregore/ never registers itself")
  : bad("register sandbox", JSON.stringify(registryNow()));
library(`egregore_registry_register "${maintRegistry}" "${H}/dev/fresh" fresh Fresh org-fresh`);
library(`egregore_registry_register "${maintRegistry}" "${H}/dev/fresh" fresh Fresh org-fresh`);
registryNow().filter((entry) => entry && entry.path === `${H}/dev/fresh`).length === 1
  ? ok("register: an ordinary checkout registers once")
  : bad("register fresh", JSON.stringify(registryNow()));
fs.writeFileSync(maintRegistry, JSON.stringify([{ slug: "legacy", name: "Legacy", path: `${H}/dev/legacy` }]));
library(`egregore_registry_register "${maintRegistry}" "${H}/dev/legacy" legacy Legacy org-legacy`);
registryNow()[0].org_id === "org-legacy" ? ok("register: a legacy entry gains its org_id") : bad("register legacy", JSON.stringify(registryNow()));
for (const rel of ["bin/session-start.sh", "bin/codex-session-start.sh"]) {
  const text = read_(rel);
  /bin\/lib\/instance-registry\.sh/.test(text) && /egregore_registry_prune/.test(text)
    ? ok(`${rel} prunes the registry through the shared maintenance`)
    : bad(`${rel} does not run the shared registry maintenance`);
}
/egregore_registry_register/.test(read_("bin/session-start.sh")) && !/jq --argjson e "\$ENTRY"/.test(read_("bin/session-start.sh"))
  ? ok("bin/session-start.sh registers through the shared maintenance (no second copy)")
  : bad("bin/session-start.sh carries its own registration");

console.log(`\nboundary parity: ${pass} passed, ${fail} failed (${limits} documented limits included as passes)`);
process.exitCode = fail ? 1 : 0;
