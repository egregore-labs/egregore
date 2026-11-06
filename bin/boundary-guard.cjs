#!/usr/bin/env node
"use strict";

// boundary-guard.cjs — the one implementation of Egregore's environment
// isolation policy. Every runtime calls it before each action:
//   Claude Code  .claude/hooks/boundary-check.sh → bin/boundary-hook.sh
//   Codex        .codex/hooks.json PreToolUse    → bin/boundary-hook.sh
//   Pi / Prime   tool_call handler → toolCallBlock() ({ block, reason })
// bin/boundary-hook.sh runs this file with the PreToolUse exit contract and
// turns any failure to start into a denial. Session starts write the boundary
// cache through writeCache() (CLI: `write-cache <project_dir>`) and Claude's
// native deny rules through nativeDenials() (CLI: `native-denials`);
// bin/boundary.sh delegates its `check` and `compute-denied` modes here.
// Adapters stay thin; no rule lives anywhere else.
//
// Two-tier model (decided 2026-07-08, harvest-2026-07-08-boundary-hook-refinement):
//   HARD tier — other instances, their Claude transcripts, and shared
//               per-user state except documented agent-facing families:
//               denied for every tool, always. No consent path exists.
//   SOFT tier — everything else outside the boundary: consent-gated. Grants
//               live in .egregore-boundary-consent (session-scoped, cleared by
//               session start) or in config read roots.
// Posture (strict|standard|open), lock, and read roots are merged from
// egregore.json .boundary + .egregore-boundary.local.json into the cached
// boundary JSON. permission_mode=bypassPermissions skips the soft tier (never
// the hard tier) unless the org boundary is locked.
//
// Failure policy: the hard tier fails closed. Denied instances are the
// registry's entries plus the session cache's, never fewer: a registry that
// has gone missing while the cache still lists denials keeps those denials.
// Known denials are enforced before any other rule. An unreadable or empty
// registry then denies every path outside the core boundary; an unexpected
// error denies paths outside the core boundary and allows paths inside it.
// The registry and the boundary cache can be read, never changed, through a
// tool.
//
// What this check guarantees, and what it does not. Structured tools (read,
// write, edit, search, patch, unknown tools with path fields) are checked on
// their resolved paths. Shell text is read literally, in linear time: words
// after quote removal, ~ / $HOME / ${HOME} / $PWD, names relative to the
// working directory as literal cd / pushd steps change it, brace lists of up
// to 64 items, wildcards (judged by their literal directory prefix), and
// recursive walks (judged by their root). The shell check never guesses
// which directory a name might belong to. It cannot see a path assembled at
// run time (a variable root, command output, interpreter path arithmetic,
// encoded text), a command split across separate write_stdin calls, or a
// directory changed in an earlier call. Confining those is the job of an
// OS-level sandbox, the planned follow-up layer.

const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const POSTURES = new Set(["strict", "standard", "open"]);
// Agent-facing operations name only these shared per-user families. The drift
// test imports this single source of truth; a trailing * means a name prefix.
const EGREGORE_ALLOWED_FAMILIES = Object.freeze([
  "loom*", "telemetry*", "platform", "exports", "emissary-config.json", "context", "trails",
]);
const SHARED_NATIVE_DENIALS = [
  "mind", "runtime", "attendant", "graph-cache", "notifications", "notices-*",
  "session-*", "greeting-card-*", "graph-wal*", "autosave.log",
  "gh-identity-mismatch-*", "dashboard-id-*",
];
const READ_TOOLS = new Set(["Read", "read", "ls", "view_image", "NotebookRead"]);
// Structured searches walk a directory tree from their root and honour ignore
// files (Claude's Grep and Glob, Pi's grep and find).
const SEARCH_TOOLS = new Set(["Glob", "Grep", "grep", "find"]);
const WRITE_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit", "write", "edit"]);
// write_stdin continues a Codex interactive session; each chunk is checked as
// shell text on its own.
const SHELL_TOOLS = new Set(["Bash", "exec_command", "shell_command", "shell", "bash", "ipython", "write_stdin"]);
const PATCH_TOOLS = new Set(["apply_patch"]);
// Egregore's own tools that open a file named in their input.
const TOOL_PATHS = { egregore_publish_scroll: { kind: "read", fields: ["source"] } };
// Any other tool: path-named fields (snake_case after splitting camelCase), at
// any depth, get the hard-tier check.
const PATH_KEY = /(?:^|_)(?:path|paths|file|files|filename|filenames|source|sources|src|dir|dirs|directory|directories|cwd|workdir|target|targets|dest|destination|root|roots)$/;

// Soft tier, best effort: only user-home-area literals. System paths are core
// and relative paths stay inside the project; a miss degrades to "no prompt",
// never to a hard-tier breach.
const SOFT_TOKEN = /(?:~|\/Users\/[A-Za-z0-9._-]+|\/home\/[A-Za-z0-9._-]+)\/[A-Za-z0-9._/-]+/g;

// Markers inside a lexed shell word. Input control characters are replaced
// before lexing, so a command cannot forge them.
const UNKNOWN = "\u0000"; // a value known only at run time ($VAR, $(…), `…`)
const PWD_MARK = "\u0001"; // $PWD: the working directory where the word runs
const LITERAL = "\u0002"; // the next character was quoted or escaped
const WILD = "*?[]{},";
// Inside a word, the characters that end a path written in code or options.
const FRAGMENT = /[\s;&|()<>=:"'`]+/;
const BRACE_LIMIT = 64;
const DIR_SCAN_LIMIT = 10000;

// Command classes, by program basename.
const WRAPPERS = new Set(["sudo", "doas", "command", "builtin", "env", "nohup", "nice", "time", "exec", "xargs",
  "timeout", "stdbuf", "caffeinate", "then", "do", "else", "elif", "if", "while", "until", "!", "{", "}", "fi", "done"]);
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh"]);
const INTERPRETERS = new Set(["python", "python3", "node", "ruby", "perl", "php", "osascript", "deno", "bun", "eval",
  "awk", "gawk", ...SHELLS]);
const DELETERS = new Set(["rm", "rmdir", "unlink", "shred", "srm", "trash"]);
const COPIERS = new Set(["cp", "install", "ln", "rsync", "ditto", "scp", "gcp"]);
const OVERWRITERS = new Set(["truncate", "tee", "dd"]);

function home() {
  return process.env.HOME || os.homedir();
}

function md5(value) {
  return crypto.createHash("md5").update(String(value)).digest("hex");
}

function cachePath(projectDir) {
  return `/tmp/egregore-boundary-${md5(projectDir)}.json`;
}

function registryPath() {
  return path.join(home(), ".egregore", "instances.json");
}

function within(candidate, root) {
  return Boolean(root) && (candidate === root || candidate.startsWith(`${root}/`));
}

function strings(value) {
  return Array.isArray(value) ? value.filter((item) => typeof item === "string" && item) : [];
}

function unique(values) {
  return [...new Set(values)];
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function isDirectory(candidate) {
  try {
    return fs.statSync(candidate).isDirectory();
  } catch {
    return false;
  }
}

function exists(candidate) {
  try {
    fs.lstatSync(candidate);
    return true;
  } catch {
    return false;
  }
}

// ── Path resolution ──────────────────────────────────────────────────────

// Physical resolution, like the kernel's: symlinks are followed and ".." is
// applied to the resolved directory (realpath.native, not node's lexical
// pre-pass). A target that does not exist yet resolves its nearest existing
// ancestor, so a write through a symlinked directory with several missing
// levels below it still lands where the kernel would put it.
function physicalPath(candidate, depth = 0) {
  try {
    return fs.realpathSync.native(candidate);
  } catch {}
  const parts = candidate.split("/");
  for (let i = parts.length - 1; i > 0; i--) {
    let base;
    try {
      base = fs.realpathSync.native(parts.slice(0, i).join("/") || "/");
    } catch {
      continue;
    }
    const rest = parts.slice(i);
    const joined = path.posix.normalize(`${base}/${rest.join("/")}`);
    // ".." past a missing level can climb back into existing, possibly
    // linked, directories: resolve the collapsed path again.
    if (rest.includes("..") && depth < 8) return physicalPath(joined, depth + 1);
    return joined.length > 1 ? joined.replace(/\/$/, "") : joined;
  }
  return path.posix.normalize(candidate);
}

function expandHome(target, h) {
  return String(target).replace(/^~(?=\/|$)/, h).replace(/^\$\{?HOME\}?(?=\/|$)/, h);
}

function absolute(target, baseDir, h) {
  const expanded = expandHome(target, h);
  return expanded.startsWith("/") ? expanded : `${baseDir}/${expanded}`;
}

function resolvePath(target, baseDir) {
  return physicalPath(absolute(target, baseDir, home()));
}

// ── Boundary computation (session start, worktree creation, every check) ──

// Registered instances not proven to share this project's identity. An entry
// is excluded only when it IS the project, is the caller-proven same instance
// (allowPath: the main checkout a linked worktree shares its git dir with), or
// both org_ids are present and equal. No path relationship proves identity.
// A registry that exists but cannot be read, is empty, or does not parse is
// reported, never treated as empty: the caller fails closed on it. Session
// start writes the registry through a temporary file and a rename, so an
// empty registry is damage, not a write in progress.
function computeDenied(registry, projectDir, orgId = "", allowPath = "") {
  let raw;
  try {
    raw = fs.readFileSync(registry, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") return { paths: [], unreadable: false };
    return { paths: [], unreadable: true };
  }
  let entries;
  try {
    entries = JSON.parse(raw);
  } catch {
    return { paths: [], unreadable: true };
  }
  if (!Array.isArray(entries)) return { paths: [], unreadable: true };
  const paths = entries
    .filter((entry) => entry && typeof entry === "object" && typeof entry.path === "string" && entry.path)
    .filter((entry) => entry.path !== projectDir)
    .filter((entry) => !allowPath || entry.path !== allowPath)
    .filter((entry) => !orgId || (typeof entry.org_id === "string" ? entry.org_id : "") !== orgId)
    .map((entry) => entry.path);
  return { paths, unreadable: false };
}

// A linked worktree's .git is a file naming its git dir inside the main
// checkout (<main>/.git/worktrees/<name>); the main checkout is that dir's
// great-grandparent. Same derivation as worktree-create.sh. The .git file
// sits in the project and anyone working there can rewrite it, so the claim
// counts only when the git dir links back to this project, as git's own
// <gitdir>/gitdir file does for a real linked worktree.
function mainCheckout(projectDir) {
  try {
    const gitFile = path.join(projectDir, ".git");
    if (!fs.statSync(gitFile).isFile()) return "";
    const match = fs.readFileSync(gitFile, "utf8").match(/^gitdir:\s*(.+)$/m);
    if (!match) return "";
    const gitDir = path.resolve(projectDir, match[1].trim());
    const back = fs.readFileSync(path.join(gitDir, "gitdir"), "utf8").trim();
    if (fs.realpathSync(path.resolve(gitDir, back)) !== fs.realpathSync(gitFile)) return "";
    const main = path.resolve(gitDir, "..", "..", "..");
    return isDirectory(main) ? main : "";
  } catch {
    return "";
  }
}

function managedRepos(projectDir, main) {
  const parent = path.dirname(main || projectDir);
  const config = readJson(path.join(projectDir, "egregore.json")) || {};
  const repos = Array.isArray(config.repos) ? config.repos : [];
  const resolved = main ? [main] : [];
  for (const entry of repos) {
    const name = typeof entry === "string" ? entry : entry && typeof entry.name === "string" ? entry.name : "";
    if (!name || name.includes("..") || name.startsWith("/")) continue;
    let real;
    try {
      real = fs.realpathSync(path.join(parent, name));
    } catch {
      continue;
    }
    if (!real.startsWith(`${parent}/`)) continue;
    if (!resolved.includes(real)) resolved.push(real);
  }
  return resolved;
}

// Posture, lock, and read roots: the org layer (egregore.json .boundary,
// committed) merged with the personal layer (.egregore-boundary.local.json,
// gitignored), which is ignored entirely when the org layer is locked.
function boundaryPolicy(configDir) {
  const org = (readJson(path.join(configDir, "egregore.json")) || {}).boundary || {};
  let posture = POSTURES.has(org.posture) ? org.posture : "standard";
  const locked = org.locked === true || org.locked === "true";
  const personal = locked ? null : readJson(path.join(configDir, ".egregore-boundary.local.json"));
  if (personal && POSTURES.has(personal.posture)) posture = personal.posture;
  const h = home();
  const roots = posture === "strict" ? [] : [`${h}/Downloads`, `${h}/Desktop`];
  roots.push(...strings(org.read));
  if (personal) roots.push(...strings(personal.read));
  const readRoots = [...new Set(roots.map((root) => root.replace(/^~/, h)))].sort();
  return { posture, locked, read_roots: readRoots };
}

function computeBoundary(projectDir) {
  const main = mainCheckout(projectDir);
  let memoryDir = "";
  try {
    const memory = path.join(projectDir, "memory");
    if (fs.lstatSync(memory).isSymbolicLink()) memoryDir = fs.realpathSync(memory);
  } catch {}
  const config = readJson(path.join(projectDir, "egregore.json")) ||
    (main ? readJson(path.join(main, "egregore.json")) : null) || {};
  const orgId = typeof config.org_id === "string" ? config.org_id : "";
  const denied = computeDenied(registryPath(), projectDir, orgId, main);
  const boundary = {
    project_dir: projectDir,
    main_checkout: main,
    memory_dir: memoryDir,
    ...boundaryPolicy(main || projectDir),
    managed_repos: managedRepos(projectDir, main),
    denied_paths: denied.paths,
  };
  if (denied.unreadable) boundary.registry_unreadable = true;
  return boundary;
}

function writeCache(projectDir) {
  const boundary = computeBoundary(projectDir);
  const target = cachePath(projectDir);
  const temporary = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(boundary, null, 2)}\n`);
  fs.renameSync(temporary, target);
  return target;
}

// Claude Code's native permission rules, the second line of defence there.
// "//" marks an absolute path in Claude's rule syntax. Native rules cannot
// express deny-by-default with exceptions, so enumerate known and present
// state; the hook handles unknown families created after generation.
function nativeDenials(projectDir) {
  const ctx = context(projectDir, {});
  const rules = [];
  const own = ownRoots(ctx);
  const ownTranscripts = transcriptRoots(ctx).flatMap((root) => ownEncodings(ctx).map((name) => `${root}/${name}`));
  const add = (target, file = false) => {
    // Native rules cannot carve a project out of an enclosing denied tree.
    // The hook still enforces the remainder of that tree on every call.
    const covers = new RegExp(`^${escapeRegex(target).replace(/\\\*/g, "[^/]*")}(?:/|$)`);
    if ([...own, ...ownTranscripts].some((root) => covers.test(root))) return;
    rules.push(`Read(/${target}/**)`, `Edit(/${target}/**)`);
    if (file) rules.push(`Read(/${target})`, `Edit(/${target})`);
  };
  for (const denied of ctx.boundary.denied) add(denied);
  for (const root of sharedRoots(ctx)) {
    const entries = directoryEntries(root);
    const names = unique([...SHARED_NATIVE_DENIALS, ...entries.map((entry) => entry.name)]);
    for (const name of names) {
      if (name === "instances.json" || allowedFamily(name)) continue;
      const entry = entries.find((entry) => entry.name === name);
      // The fixed wildcard families include files (notices, lifecycle, WALs,
      // identity markers); cover their bare names even before one exists.
      add(`${root}/${name}`, name === "autosave.log" || name.endsWith("*") || Boolean(entry && !entry.isDirectory()));
    }
  }
  // Enumerate existing folders, not worktree globs: an own encoding may
  // collide with another instance's worktree prefix. New families/folders
  // created after generation are always covered by the hook.
  for (const root of transcriptRoots(ctx)) {
    for (const entry of directoryEntries(root)) {
      const target = `${root}/${entry.name}`;
      if (isDirectory(target) && transcriptDenial(target, ctx)) add(target);
    }
  }
  // Edit() covers Write/NotebookEdit too; Write() rules are never matched.
  rules.push("Edit(~/.egregore/instances.json)");
  return unique(rules);
}

// ── Boundary loading ─────────────────────────────────────────────────────

function normalizeBoundary(raw) {
  const b = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const posture = POSTURES.has(b.posture) ? b.posture : "standard";
  const h = home();
  // Legacy caches (no read_roots key) get the inbox defaults unless strict.
  const readRoots = Object.prototype.hasOwnProperty.call(b, "read_roots")
    ? strings(b.read_roots)
    : posture === "strict" ? [] : [`${h}/Downloads`, `${h}/Desktop`];
  return {
    projectDir: typeof b.project_dir === "string" ? b.project_dir : "",
    mainCheckout: typeof b.main_checkout === "string" ? b.main_checkout : "",
    memoryDir: typeof b.memory_dir === "string" ? b.memory_dir : "",
    posture,
    locked: b.locked === true || b.locked === "true",
    readRoots,
    managedRepos: strings(b.managed_repos),
    denied: strings(b.denied_paths),
    registryUnreadable: b.registry_unreadable === true,
  };
}

// A cache is used only when its shape is intact; anything else is ignored.
function usableCache(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const list = (key) => !(key in value) || (Array.isArray(value[key]) && value[key].every((item) => typeof item === "string"));
  return Array.isArray(value.denied_paths) && list("denied_paths") && list("managed_repos") && list("read_roots");
}

// Each denied entry in its registered spelling and its on-disk form, so a link
// or a different letter case in either spelling still matches a physically
// resolved target.
function deniedForms(entries) {
  return unique(entries.flatMap((denied) => [denied, physicalPath(denied)]));
}

// The registry is read on every check (one small file). The session cache
// supplies the soft-tier policy and core roots it was written with, and its
// denials are kept: denied = registry ∪ cache, never fewer. A registry that
// disappeared after session start therefore keeps the cached denials, and a
// stale, emptied or planted cache cannot open the wall.
function loadBoundary(projectDir) {
  const fresh = normalizeBoundary(computeBoundary(projectDir));
  const cached = readJson(cachePath(projectDir));
  const boundary = usableCache(cached) ? normalizeBoundary(cached) : { ...fresh };
  boundary.denied = deniedForms([...fresh.denied, ...boundary.denied]);
  boundary.registryUnreadable = fresh.registryUnreadable || boundary.registryUnreadable;
  // Roots that relax a hard-tier rule come from disk, never from the cache.
  boundary.verified = { memoryDir: fresh.memoryDir, managedRepos: fresh.managedRepos, mainCheckout: fresh.mainCheckout };
  return boundary;
}

// ── Policy ───────────────────────────────────────────────────────────────

function context(projectDir, input) {
  const boundary = loadBoundary(projectDir);
  const permissionMode = String(input.permission_mode || input.permissionMode || "");
  let realProject = projectDir;
  try { realProject = fs.realpathSync.native(projectDir); } catch {}
  return {
    projectDir,
    // The project as it sits on disk: the hard tier's self-scope carve-out
    // keys on the project the hook runs for, never on a cached value.
    realProject,
    boundary,
    home: home(),
    // A session the user runs in bypassPermissions has already declared
    // maximal trust — Egregore doesn't re-ask (soft tier off). The hard tier
    // stays on. An org lock disables this relaxation.
    relaxed: !boundary.locked && permissionMode === "bypassPermissions",
    // A deleted project (removed worktree) keeps the hard tier only.
    softOff: !isDirectory(projectDir),
    memo: new Map(),
  };
}

// physicalPath, remembered for one decision: a long command names the same
// path many times.
function resolved(ctx, candidate) {
  if (!ctx.memo) return physicalPath(candidate);
  let value = ctx.memo.get(candidate);
  if (value === undefined) {
    value = physicalPath(candidate);
    ctx.memo.set(candidate, value);
  }
  return value;
}

function lexicalPath(candidate) {
  return path.posix.normalize(candidate).replace(/\/$/, "") || "/";
}

function pathSpellings(target, ctx) {
  return unique([lexicalPath(target), resolved(ctx, target)]);
}

function sharedRoots(ctx) {
  return pathSpellings(`${ctx.home}/.egregore`, ctx);
}

function transcriptRoots(ctx) {
  return pathSpellings(`${ctx.home}/.claude/projects`, ctx);
}

function allowedFamily(name) {
  return EGREGORE_ALLOWED_FAMILIES.some((family) => family.endsWith("*")
    ? name.startsWith(family.slice(0, -1)) : name === family);
}

function ownRoots(ctx) {
  const main = ctx.boundary.verified.mainCheckout;
  return unique([ctx.projectDir, ctx.realProject, ...(main ? pathSpellings(main, ctx) : [])]);
}

function encodeProject(project) {
  return project.replace(/[^A-Za-z0-9]/g, "-");
}

function ownEncodings(ctx) {
  return ownRoots(ctx).map(encodeProject);
}

function encodingMatches(name, encoding) {
  return name === encoding || name.startsWith(`${encoding}--claude-worktrees-`);
}

// Both normalized lexical and physical spellings must pass. In particular,
// an unknown name linked into reports is still unknown; reports linked into
// runtime is still runtime. Only HOME's state tree is reserved, never a
// project's own .egregore directory. Apply self-scope per spelling so a link
// inside the project does not grant access to state outside the project.
function sharedDenial(target, ctx) {
  for (const candidate of pathSpellings(target, ctx)) {
    if (inOwnProject(candidate, ctx)) continue;
    for (const root of sharedRoots(ctx)) {
      if (candidate === root || !within(candidate, root)) continue;
      const rel = candidate.slice(root.length + 1);
      if (rel === "instances.json" || allowedFamily(rel.split("/")[0])) continue;
      return "shared-state";
    }
  }
  return null;
}

function transcriptDenial(target, ctx) {
  const own = ownEncodings(ctx);
  for (const candidate of pathSpellings(target, ctx)) {
    for (const root of transcriptRoots(ctx)) {
      if (candidate === root || !within(candidate, root)) continue;
      const name = candidate.slice(root.length + 1).split("/")[0];
      if (own.some((encoding) => encodingMatches(name, encoding))) continue;
      if (ctx.boundary.registryUnreadable) return "registry";
      if (ctx.boundary.denied.some((denied) => encodingMatches(name, encodeProject(denied)))) return "transcripts";
    }
  }
  return null;
}

function directoryEntries(root) {
  try { return fs.readdirSync(root, { withFileTypes: true }); } catch { return []; }
}

// Files count too: a recursive grep and a wildcard can read a direct state
// file just as they can reach a directory. Ignore missing future entries.
function containedState(root, ctx) {
  for (const [roots, denial] of [[sharedRoots(ctx), sharedDenial], [transcriptRoots(ctx), transcriptDenial]]) {
    for (const parent of roots) {
      for (const entry of directoryEntries(parent)) {
        const target = `${parent}/${entry.name}`;
        const kind = denial(target, ctx);
        if (!kind) continue;
        if (pathSpellings(target, ctx).some((candidate) => candidate !== root && within(candidate, root))) {
          return { path: target, kind };
        }
      }
    }
  }
  return null;
}

function inSystem(target, h) {
  if (target === "/tmp" || target.startsWith("/tmp/") || target === "/private" || target.startsWith("/private/")) return true;
  if (within(target, `${h}/.claude`)) return true;
  if (/^\/(usr|etc|var|bin|sbin|opt|proc|sys|System|Applications|Library)\//.test(target)) return true;
  return target === "/dev" || target.startsWith("/dev/");
}

// Core boundary: no consent needed, every tier. `strict` drops the parent
// directory allowance and uses only roots verified on disk, for when the
// registry cannot be read: the siblings of a checkout are exactly where
// other instances live.
function inCore(target, ctx, strict = false) {
  const h = ctx.home;
  if (inSystem(target, h)) return true;
  // Names-only listing, the read-only registry, and documented families.
  // All hard-tier checks run first, including for symlinked spellings.
  if (sharedRoots(ctx).some((root) => target === root || target === `${root}/instances.json`
    || (within(target, root) && allowedFamily(target.slice(root.length + 1).split("/")[0])))) return true;
  const b = ctx.boundary;
  if (within(target, ctx.realProject) || within(target, ctx.projectDir)) return true;
  const roots = strict ? b.verified : b;
  if (within(target, roots.memoryDir)) return true;
  if (roots.managedRepos.some((repo) => within(target, repo))) return true;
  if (strict) return false;
  if (within(target, b.projectDir)) return true;
  // Parent directory (sibling repo operations). The hard tier is always
  // checked before this helper, so a denied sibling never reaches it.
  return within(target, path.dirname(b.projectDir || ctx.projectDir));
}

function enclosesProject(denied, ctx) {
  return within(ctx.realProject, denied) || within(ctx.projectDir, denied);
}

function inOwnProject(target, ctx) {
  return within(target, ctx.realProject) || within(target, ctx.projectDir);
}

// The project's own tree: the project, and the main checkout a linked
// worktree belongs to. An instance registered inside it is nested.
function inOwnTree(target, ctx) {
  return inOwnProject(target, ctx) || within(target, ctx.boundary.verified.mainCheckout);
}

// HARD tier. Known denials come first, on every path, so neither the core
// boundary nor a damaged registry can hide them. Self-scope carve-out, per
// entry: an ENCLOSING denied checkout (different or unproven identity) never
// covers the project's own files. A denied entry nested INSIDE the project
// is still enforced: residence under the project proves nothing about
// identity. With the registry unreadable, every path outside the verified
// core boundary is then denied.
function deniedEntry(target, ctx) {
  const state = sharedDenial(target, ctx) || transcriptDenial(target, ctx);
  if (state) return state;
  target = resolved(ctx, target);
  const b = ctx.boundary;
  const inProject = inOwnProject(target, ctx);
  for (const denied of b.denied) {
    if (!within(target, denied)) continue;
    if (inProject && enclosesProject(denied, ctx)) continue;
    return denied;
  }
  if (b.registryUnreadable && !inCore(target, ctx, true)) return "registry";
  return null;
}

// Denied state or an instance strictly inside `root` that exists on disk:
// a walk or wildcard from root can reach it. A deleted entry cannot.
function containedDenied(root, ctx) {
  return containedState(root, ctx)
    || ctx.boundary.denied.find((denied) => denied !== root && within(denied, root) && exists(denied)) || null;
}

// The registry and this project's boundary cache: readable, never changed
// through a tool. Any boundary cache in the temporary directory counts.
function protectedFiles(ctx) {
  if (!ctx.protectedFiles) {
    const files = [path.join(ctx.home, ".egregore", "instances.json"), cachePath(ctx.projectDir)];
    const main = ctx.boundary && ctx.boundary.verified && ctx.boundary.verified.mainCheckout;
    if (main) files.push(cachePath(main));
    ctx.protectedFiles = unique(files.flatMap((file) => [file, physicalPath(file)]));
  }
  return ctx.protectedFiles;
}

function isProtected(target, ctx) {
  if (protectedFiles(ctx).includes(target)) return true;
  const dir = path.dirname(target);
  return /^egregore-boundary-[0-9a-f]{32}\.json$/.test(path.basename(target))
    && (dir === "/tmp" || dir === physicalPath("/tmp"));
}

// A folder holding protected state: deleting or moving it removes the state.
function holdsProtected(target, ctx) {
  return protectedFiles(ctx).some((file) => file !== target && within(file, target));
}

function inReadRoots(target, ctx) {
  return ctx.boundary.readRoots.some((root) => within(target, root));
}

function isConsented(target, ctx) {
  // A locked org boundary has no consent path — stale grant files are void.
  if (ctx.boundary.locked) return false;
  let lines;
  try {
    lines = fs.readFileSync(path.join(ctx.projectDir, ".egregore-boundary-consent"), "utf8").split("\n");
  } catch {
    return false;
  }
  return lines.some((line) => line && within(target, line.replace(/^~/, ctx.home)));
}

function allow() {
  return { outcome: "allow", reason: "inside", message: "" };
}

function hardBlock(target, entry) {
  if (entry === "shared-state" || entry === "transcripts") {
    const area = entry === "shared-state" ? "protected shared per-user state" : "another instance's Claude transcripts";
    return {
      outcome: "deny", reason: entry,
      message: `Environment isolation: ${target} names ${area}. Access is denied for every tool and cannot be consented — do not retry and do not attempt via other tools.`,
    };
  }
  if (entry === "registry") {
    return {
      outcome: "deny",
      reason: "registry-unreadable",
      message: `Environment isolation: ${target} cannot be verified because the instance registry (~/.egregore/instances.json) cannot be read, so Egregore cannot tell which folders belong to other instances. Access to this path is denied until the registry is readable again — do not retry and do not attempt via other tools. Ask the user to repair or remove the registry file, then restart the session.`,
    };
  }
  return {
    outcome: "deny",
    reason: "instance",
    message: `Environment isolation: ${target} belongs to another Egregore instance. Access is denied for every tool and cannot be consented — do not retry and do not attempt via other tools. If the user needs something from it, they must fetch it themselves in that instance.`,
  };
}

function walkBlock(root, entry, nested) {
  if (typeof entry === "object") return hardBlock(`${root} (contains ${entry.path})`, entry.kind);
  const where = nested
    ? `${root} holds another Egregore instance registered inside this project (${entry}), and this command walks it without ignore rules`
    : `${root} contains another Egregore instance (${entry}), and a recursive search, copy or listing from there would read it`;
  return {
    outcome: "deny",
    reason: "instance",
    message: `Environment isolation: ${where}. Access is denied for every tool and cannot be consented — do not retry and do not attempt via other tools. Narrow the search to a folder that does not contain ${entry}${nested ? ", or use a search that respects ignore rules (rg without -u / --no-ignore)" : ""}.`,
  };
}

function wildcardBlock(pattern, prefix, entry) {
  if (typeof entry === "object") return hardBlock(`${pattern} (contains ${entry.path})`, entry.kind);
  return {
    outcome: "deny",
    reason: "instance",
    message: `Environment isolation: the wildcard ${pattern} starts at ${prefix}, which contains another Egregore instance (${entry}), so it could expand into that instance. Access is denied for every tool and cannot be consented — do not retry and do not attempt via other tools. Name the files explicitly or narrow the wildcard to a folder that does not contain ${entry}.`,
  };
}

function stateBlock(target) {
  return {
    outcome: "deny",
    reason: "state-write",
    message: `Environment isolation: ${target} is Egregore's isolation state (the instance registry ~/.egregore/instances.json or a boundary cache), which only session start maintains. Changing, moving or deleting it is denied for every tool and cannot be consented — do not retry and do not attempt via other tools.`,
  };
}

function softBlock(target, action, ctx) {
  const dir = path.dirname(target);
  if (ctx.boundary.locked) {
    return {
      outcome: "deny",
      reason: "locked",
      message: `Environment isolation: ${target} is outside this instance's boundary and the org boundary is locked (egregore.json boundary.locked) — no consent path exists. Do not retry. Use AskUserQuestion with options: 'Paste contents inline' / 'Move the file into the repo and point me at the new path' / 'Cancel'.`,
    };
  }
  const session = `'Allow ${dir} for this session' (on approval: append ${dir} as one line to ${ctx.projectDir}/.egregore-boundary-consent, then retry)`;
  // read[] grants reads only, so a blocked write never offers it: every
  // option must grant what it names.
  const always = action === "write"
    ? ""
    : ` / 'Always allow on this instance' (on approval: add "${dir}" to the read[] array in ${ctx.projectDir}/.egregore-boundary.local.json, then retry)`;
  return {
    outcome: "consent",
    reason: "consent",
    message: `Boundary consent needed: ${target} is outside this instance's ${action} surface (posture: ${ctx.boundary.posture}). Do not retry yet and do not route around via other tools. Ask via AskUserQuestion with exactly these options: ${session}${always} / 'Paste contents inline' / 'Cancel'. Never write a consent grant without the user's explicit approval in this exchange.`,
  };
}

function hardCheck(target, ctx) {
  const entry = deniedEntry(target, ctx);
  return entry ? hardBlock(target, entry) : null;
}

// A walk from root: stopped by an instance below a root outside the
// project's own tree, and by an instance nested inside the project only when
// the walk ignores ignore files (nested instances live in gitignored runtime
// state).
function walkCheck(root, ctx, bypassesIgnore) {
  const nested = inOwnTree(root, ctx);
  if (nested && !bypassesIgnore) return null;
  const inside = containedDenied(root, ctx);
  return inside ? walkBlock(root, inside, nested) : null;
}

function checkPath(target, action, ctx, baseDir) {
  const named = absolute(target, baseDir, ctx.home);
  const place = resolved(ctx, named);
  const hard = hardCheck(named, ctx);
  if (hard) return hard;
  if (action === "write" && isProtected(place, ctx)) return stateBlock(place);
  if (inCore(place, ctx) || ctx.softOff) return null;
  if (action === "read" && ctx.boundary.posture === "open") return null;
  if (ctx.relaxed) return null;
  if (action === "read" && inReadRoots(place, ctx)) return null;
  if (isConsented(place, ctx)) return null;
  return softBlock(place, action, ctx);
}

// ── Wildcards ────────────────────────────────────────────────────────────

function plainText(text) {
  return text.split(LITERAL).join("");
}

function escapeLiteral(text) {
  return String(text).replace(/[*?[\]{},]/g, (char) => LITERAL + char);
}

// Index of the first character that makes a word a pattern: an unquoted
// wildcard or brace, or a run-time value.
function firstSpecial(text) {
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === LITERAL) { i++; continue; }
    if (c === "*" || c === "?" || c === "[" || c === "{" || c === UNKNOWN) return i;
  }
  return -1;
}

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
}

// A pattern component as a regular expression, or null when it could match
// any name (a brace list too large to expand). A run-time value matches any
// run of characters.
function componentRegex(component) {
  let out = "";
  for (let i = 0; i < component.length; i++) {
    const c = component[i];
    if (c === LITERAL) {
      i++;
      if (i < component.length) out += escapeRegex(component[i]);
    } else if (c === "{") {
      return null;
    } else if (c === UNKNOWN) {
      out += ".*";
    } else if (c === "*") {
      out += "[^/]*";
    } else if (c === "?") {
      out += "[^/]";
    } else if (c === "[") {
      const close = component.indexOf("]", i + 2);
      if (close < 0) { out += "\\["; continue; }
      const body = plainText(component.slice(i + 1, close)).replace(/^!/, "^").replace(/\\/g, "\\\\");
      out += `[${body}]`;
      i = close;
    } else {
      out += escapeRegex(c);
    }
  }
  return out;
}

function componentMatches(component, name) {
  if (firstSpecial(component) < 0) return plainText(component) === name;
  const source = componentRegex(component);
  if (source === null) return true;
  try {
    return new RegExp(`^${source}$`).test(name);
  } catch {
    return true; // an unparseable pattern could match anything
  }
}

// Does a pattern (components after its literal prefix) name `rel` (the
// components of a path below that prefix)? `exact` asks for the path itself;
// otherwise naming a folder above it counts too. Inside the project a `**`
// walk does not reach a nested instance (shells skip dot-folders, where
// nested runtime state lives); elsewhere it reaches everything.
function patternNames(rest, rel, { exact = false, globstar = true } = {}) {
  if (exact && rest.length !== rel.length && !rest.some((part) => part.includes("**"))) return false;
  for (let i = 0; i < rest.length && i < rel.length; i++) {
    if (rest[i].includes("**")) return globstar;
    if (!componentMatches(rest[i], rel[i])) return false;
    // A run-time value can carry further components of its own.
    if (rest[i].includes(UNKNOWN)) return true;
  }
  return exact ? rest.length >= rel.length : true;
}

function relativeParts(prefix, target) {
  return target.slice(prefix === "/" ? 1 : prefix.length + 1).split("/");
}

// The literal directory before a pattern's first wildcard, resolved
// physically. Each ".." after the wildcard can climb one level above it.
function wildcardRoot(abs, ctx) {
  const parts = abs.split("/");
  const first = parts.findIndex((part) => firstSpecial(part) >= 0);
  const rest = parts.slice(first);
  let lexicalPrefix = plainText(parts.slice(0, first).join("/")) || "/";
  let prefix = resolved(ctx, lexicalPrefix);
  const climbs = rest.filter((part) => plainText(part) === "..").length;
  for (let k = 0; k < climbs && prefix !== "/"; k++) {
    prefix = path.dirname(prefix);
    lexicalPrefix = path.dirname(lexicalPrefix);
  }
  return { prefix, lexicalPrefix, rest, climbs: climbs > 0 };
}

// The first wildcard component, matched against the prefix's entries: a
// symlink it matches is followed, so it must not lead into an instance.
function linkedEntry(dir, component, ctx) {
  if (!component || firstSpecial(component) < 0) return null;
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return null;
  }
  if (entries.length > DIR_SCAN_LIMIT) return null;
  for (const entry of entries) {
    if (!entry.isSymbolicLink() || !componentMatches(component, entry.name)) continue;
    const verdict = hardCheck(path.join(dir, entry.name), ctx);
    if (verdict) return verdict;
  }
  return null;
}

// A wildcard is judged by its literal prefix. Outside the project's own tree
// it is denied when that prefix is, or contains, another instance. Inside, it
// is denied only when it names a nested instance or matches a symlink into
// an instance.
function wildcardCheck(abs, ctx) {
  const { prefix, lexicalPrefix, rest, climbs } = wildcardRoot(abs, ctx);
  const hard = hardCheck(lexicalPrefix, ctx) || hardCheck(prefix, ctx);
  if (hard) return hard;
  if (!inOwnTree(prefix, ctx)) {
    const inside = containedDenied(prefix, ctx);
    if (inside) return wildcardBlock(plainText(abs).split(UNKNOWN).join("${…}"), prefix, inside);
  } else {
    for (const denied of ctx.boundary.denied) {
      if (denied === prefix || !within(denied, prefix)) continue;
      if (climbs || patternNames(rest, relativeParts(prefix, denied), { globstar: false })) return hardBlock(denied, denied);
    }
  }
  return climbs ? null : linkedEntry(prefix, rest[0], ctx);
}

function checkCandidate(abs, ctx) {
  return firstSpecial(abs) >= 0 ? wildcardCheck(abs, ctx) : hardCheck(plainText(abs), ctx);
}

// ── Shell text ───────────────────────────────────────────────────────────

// Brace lists expanded the way the shell expands them, innermost group first.
// A brace left over (no comma list, unbalanced) is literal, as in the shell.
// More than BRACE_LIMIT words returns null: the word stays a pattern, which
// the prefix rule then judges.
function braceGroup(text) {
  const open = [];
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === LITERAL) { i++; continue; }
    if (c === "{") open.push({ start: i, commas: [] });
    else if (c === "," && open.length) open[open.length - 1].commas.push(i);
    else if (c === "}" && open.length) {
      const group = open.pop();
      if (group.commas.length) return { ...group, end: i };
    }
  }
  return null;
}

function braceExpand(word) {
  if (word.length > 4096) return null;
  const done = [];
  const work = [word];
  let steps = 0;
  while (work.length) {
    const text = work.pop();
    const group = braceGroup(text);
    if (!group) {
      done.push(text);
      continue;
    }
    steps++;
    if (steps > 256 || done.length + work.length + group.commas.length + 1 > BRACE_LIMIT) return null;
    const cuts = [group.start, ...group.commas, group.end];
    for (let k = 0; k + 1 < cuts.length; k++) {
      work.push(text.slice(0, group.start) + text.slice(cuts[k] + 1, cuts[k + 1]) + text.slice(group.end + 1));
    }
  }
  return done.map(literalBraces);
}

function literalBraces(text) {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    if (text[i] === LITERAL) { out += text[i] + (text[i + 1] || ""); i++; continue; }
    out += text[i] === "{" ? LITERAL + "{" : text[i];
  }
  return out;
}

// A linear reading of shell text: simple commands in execution order, each
// with its words (quotes removed), input files and output targets. Subshells
// and substitutions are bracketed by push/pop markers so a directory change
// inside them does not leak out. Heredoc bodies are read as scripts of their
// own. It reads text; it runs nothing and expands no run-time value.
function lexShell(source, ctx, depth = 0) {
  const s = String(source).replace(/[\u0000-\u0002]/g, "\uFFFD");
  const items = [];
  const stack = [];
  const docs = [];
  const fresh = () => ({ words: [], inputs: [], redirects: [] });
  let cmd = fresh();
  let word = null;
  let pending = null; // what the next word is: write | read | skip | doc | doc-
  let dq = false;

  const add = (text) => { word = (word === null ? "" : word) + text; };
  const lit = (char) => (WILD.includes(char) ? LITERAL + char : char);
  const endWord = () => {
    if (word === null) return;
    if (pending === "write") cmd.redirects.push(word);
    else if (pending === "read") cmd.inputs.push(word);
    else if (pending === "doc" || pending === "doc-") docs.push({ delimiter: plainText(word), strip: pending === "doc-" });
    else if (pending !== "skip") cmd.words.push(word);
    pending = null;
    word = null;
  };
  const endCommand = () => {
    endWord();
    pending = null;
    if (cmd.words.length || cmd.inputs.length || cmd.redirects.length) items.push(cmd);
    cmd = fresh();
  };
  const openSubstitution = (type) => {
    add(UNKNOWN); // the outer word holds a run-time value here
    stack.push({ type, cmd, word, pending, dq });
    items.push({ push: true });
    cmd = fresh();
    word = null;
    pending = null;
    dq = false;
  };
  const closeSubstitution = () => {
    endCommand();
    const frame = stack.pop();
    items.push({ pop: true });
    ({ cmd, word, pending, dq } = frame);
  };
  const variable = (name) => {
    if (name === "HOME") return escapeLiteral(ctx.home);
    if (name === "PWD") return PWD_MARK;
    if (name === "CLAUDE_PROJECT_DIR") return escapeLiteral(ctx.projectDir);
    return UNKNOWN;
  };
  const top = () => stack[stack.length - 1];
  // Redirection operators; returns the index of the operator's last char.
  const redirect = (i) => {
    let j = i;
    let kind = "write";
    if (s[j] === "<") {
      if (s[j + 1] === "<") {
        j++;
        if (s[j + 1] === "<") { j++; kind = "skip"; } // here-string: a value
        else if (s[j + 1] === "-") { j++; kind = "doc-"; }
        else kind = "doc";
      } else if (s[j + 1] === ">") { j++; kind = "write"; }
      else if (s[j + 1] === "&") { j++; kind = "dup"; }
      else kind = "read";
    } else {
      if (s[j + 1] === ">") j++;
      if (s[j + 1] === "|") j++;
      else if (s[j + 1] === "&") { j++; kind = "dup"; }
    }
    if (kind === "dup") {
      // >&2, <&0, >&- name a descriptor; ">& file" writes the file.
      if (/[0-9-]/.test(s[j + 1] || "")) {
        while (j + 1 < s.length && /[0-9-]/.test(s[j + 1])) j++;
        pending = null;
        return j;
      }
      kind = s[i] === "<" ? "read" : "write";
    }
    pending = kind;
    return j;
  };
  // Heredoc bodies start after the newline that ends their command; each is
  // read as its own script (it often feeds a shell or an interpreter).
  const heredocs = (newline) => {
    let i = newline;
    while (docs.length) {
      const { delimiter, strip } = docs.shift();
      let start = i + 1;
      let end = s.length;
      let next = s.length;
      for (let line = start; line < s.length;) {
        const stop = s.indexOf("\n", line);
        const lineEnd = stop < 0 ? s.length : stop;
        const text = s.slice(line, lineEnd);
        if ((strip ? text.replace(/^\t+/, "") : text) === delimiter) {
          end = line;
          next = lineEnd;
          break;
        }
        line = lineEnd + 1;
      }
      if (depth < 4) {
        items.push({ push: true });
        items.push(...lexShell(s.slice(start, end), ctx, depth + 1));
        items.push({ pop: true });
      }
      i = next;
    }
    return i;
  };

  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "$") {
      const n = s[i + 1];
      if (n === "(") { openSubstitution("subst"); i++; continue; }
      if (n === "{") {
        const end = s.indexOf("}", i + 2);
        add(variable(end < 0 ? "" : s.slice(i + 2, end)));
        i = end < 0 ? s.length : end;
        continue;
      }
      if (!dq && (n === "'" || n === '"')) continue; // $'…' and $"…": the quote follows
      if (n && /[A-Za-z_]/.test(n)) {
        let j = i + 1;
        while (j < s.length && /[A-Za-z0-9_]/.test(s[j])) j++;
        add(variable(s.slice(i + 1, j)));
        i = j - 1;
        continue;
      }
      if (n && /[0-9@*#?$!-]/.test(n)) { add(UNKNOWN); i++; continue; }
      add("$");
      continue;
    }
    if (c === "`") {
      if (top() && top().type === "tick") closeSubstitution();
      else openSubstitution("tick");
      continue;
    }
    if (dq) {
      if (c === '"') { dq = false; continue; }
      if (c === "\\" && i + 1 < s.length && '$`"\\\n'.includes(s[i + 1])) {
        i++;
        if (s[i] !== "\n") add(lit(s[i]));
        continue;
      }
      add(lit(c));
      continue;
    }
    if (c === "'") {
      const end = s.indexOf("'", i + 1);
      add(escapeLiteral(end < 0 ? s.slice(i + 1) : s.slice(i + 1, end)));
      i = end < 0 ? s.length : end;
      continue;
    }
    if (c === '"') { dq = true; add(""); continue; }
    if (c === "\\") {
      if (i + 1 < s.length) {
        i++;
        if (s[i] !== "\n") add(lit(s[i]));
      }
      continue;
    }
    if (c === " " || c === "\t" || c === "\r") { endWord(); continue; }
    if (c === "#" && word === null) {
      const newline = s.indexOf("\n", i);
      i = newline < 0 ? s.length : newline - 1;
      continue;
    }
    if (c === "&" && s[i + 1] === ">") { endWord(); i = redirect(i + 1); continue; }
    if (c === "\n") {
      endCommand();
      if (docs.length) i = heredocs(i);
      continue;
    }
    if (c === ";" || c === "&" || c === "|") { endCommand(); continue; }
    if ((c === "<" || c === ">") && s[i + 1] === "(") { openSubstitution("subst"); i++; continue; }
    if (c === "(") { endCommand(); stack.push({ type: "group" }); items.push({ push: true }); continue; }
    if (c === ")") {
      const frame = top();
      if (frame && frame.type === "group") { endCommand(); stack.pop(); items.push({ pop: true }); }
      else if (frame && frame.type === "subst") closeSubstitution();
      else endCommand();
      continue;
    }
    if (c === "<" || c === ">") {
      if (word !== null && /^[0-9]+$/.test(word)) word = null; // a descriptor number
      endWord();
      i = redirect(i);
      continue;
    }
    add(c);
  }
  while (stack.length) {
    if (top().type === "group") { endCommand(); stack.pop(); items.push({ pop: true }); }
    else closeSubstitution();
  }
  endCommand();
  return items;
}

// The program a simple command runs, past assignments, wrappers and shell
// keywords, with its arguments.
function programOf(words) {
  let i = 0;
  while (i < words.length) {
    const text = plainText(words[i]);
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(text)) { i++; continue; }
    const name = path.posix.basename(text);
    if (!WRAPPERS.has(name)) return { prog: name, args: words.slice(i + 1) };
    i++;
    while (i < words.length && plainText(words[i]).startsWith("-")) i++;
    if (name === "timeout" && i < words.length) i++;
  }
  return { prog: "", args: [] };
}

// Absolute candidates a word names: the word itself and, for words carrying
// code or options, every path-shaped piece of it, each resolved against the
// working directory where the word runs (null: unknown, so relative names
// are not resolved).
function candidates(word, cwd, ctx, wholeOnly = false) {
  const out = [];
  for (const text of braceExpand(word) || [word]) {
    // NAME=value: the value is the candidate, not the assignment.
    const whole = /^[A-Za-z_][A-Za-z0-9_]*=/.test(plainText(text)) ? [] : [{ piece: text, start: 0 }];
    let offset = 0;
    const pieces = wholeOnly ? whole : [...whole, ...text.split(FRAGMENT).map((piece) => {
      const start = text.indexOf(piece, offset);
      offset = start + piece.length;
      return { piece, start };
    })];
    for (let { piece, start } of pieces) {
      if (piece.startsWith("@")) piece = piece.slice(1);
      if (!piece || piece[0] === UNKNOWN || piece[0] === "-") continue;
      // Only <scheme>:// introduces a URL authority. An assignment or
      // option value such as if=//home//user is still an absolute path.
      if (piece.startsWith("//") && text[start - 1] === ":") {
        let scheme = start - 2;
        while (scheme >= 0 && /[A-Za-z0-9+.-]/.test(text[scheme])) scheme--;
        if (scheme < start - 2) continue;
      }
      piece = piece.replace(/\/{2,}/g, "/");
      if (piece.includes(PWD_MARK)) {
        if (cwd === null) continue;
        piece = piece.split(PWD_MARK).join(escapeLiteral(cwd));
      }
      if (piece === "~" || piece.startsWith("~/")) piece = escapeLiteral(ctx.home) + piece.slice(1);
      if (piece.startsWith("/")) out.push(piece);
      else if (cwd !== null) {
        const candidate = `${escapeLiteral(cwd)}/${piece}`;
        // Keep the uncollapsed form too: resolving a logical cwd follows its
        // current symlinks, including after logical cd .. has diverged from
        // the physical scan. Ordinary file operands still use kernel '..'.
        out.push(candidate);
        if (ctx.logicalCwd && firstSpecial(candidate) < 0) out.push(lexicalPath(candidate));
      }
    }
  }
  return out;
}

// The directory a literal word names, or null.
function literalDir(word, cwd, ctx) {
  const text = plainText(word);
  if (text === "-" || firstSpecial(word) >= 0) return null;
  const [abs] = candidates(word, cwd, ctx, true);
  return abs ? (ctx.logicalCwd ? lexicalPath(plainText(abs)) : resolved(ctx, plainText(abs))) : null;
}

function nextCwd(cmd, state, ctx) {
  const { cwd, oldcwd, dirs } = state;
  const move = (next, stack = dirs) => ({ cwd: next, oldcwd: cwd, dirs: stack });
  const { prog, args } = programOf(cmd.words);
  if (prog === "popd") return move(dirs ? dirs.cwd : null, dirs ? dirs.next : null);
  if (prog !== "cd" && prog !== "pushd") return state;
  const operands = args.filter((word) => !/^-[A-Za-z@-]+$/.test(plainText(word)));
  if (prog === "cd" && plainText(operands[0] || "") === "-") return move(oldcwd);
  if (prog === "pushd" && !operands.length) return move(dirs ? dirs.cwd : null, dirs ? { cwd, next: dirs.next } : null);
  const stack = prog === "pushd" ? { cwd, next: dirs } : dirs;
  let physicalCd = false;
  if (prog === "cd") {
    for (const word of args) {
      const flag = plainText(word);
      if (flag === "--" || !flag.startsWith("-")) break;
      for (const option of flag.slice(1)) {
        if (option === "P") physicalCd = true;
        if (option === "L") physicalCd = false;
      }
    }
  }
  // Explicit -P resets the logical PWD to the resolved directory. The last
  // -L/-P wins, matching shell option order; the physical scan stays intact.
  const nextCtx = ctx.logicalCwd && physicalCd ? { ...ctx, logicalCwd: false } : ctx;
  if (!operands.length) return move(nextCtx.logicalCwd ? lexicalPath(ctx.home) : resolved(ctx, ctx.home));
  return move(literalDir(operands[0], cwd, nextCtx), stack);
}

const shortFlag = (flags, letters) => flags.some((flag) => /^-[A-Za-z0-9]+$/.test(flag)
  && [...letters].some((letter) => flag.slice(1).includes(letter)));
const longFlag = (flags, ...names) => flags.some((flag) => names.some((name) => flag === name || flag.startsWith(`${name}=`)));
const longPrefix = (flags, prefix) => flags.some((flag) => flag.startsWith(prefix));

// Does this command walk a tree? { pattern: its first operand is a search
// pattern, bypass: it ignores ignore files, leading: only operands before
// the first option are roots }.
function walkOf(prog, flags) {
  const walk = (pattern, bypass, leading = false) => ({ pattern, bypass, leading });
  switch (prog) {
    case "rg":
      return walk(true, shortFlag(flags, "u") || longPrefix(flags, "--no-ignore") || longFlag(flags, "--unrestricted"));
    case "fd": case "fdfind":
      return walk(true, shortFlag(flags, "uI") || longPrefix(flags, "--no-ignore") || longFlag(flags, "--unrestricted"));
    case "ag":
      return walk(true, shortFlag(flags, "uU") || longFlag(flags, "--unrestricted", "--skip-vcs-ignores"));
    case "ack":
      return walk(true, true);
    case "find":
      return walk(false, true, true);
    case "tree": case "du": case "tar": case "gtar": case "bsdtar": case "rsync":
      return walk(false, true);
    case "grep": case "egrep": case "fgrep": case "ggrep": case "zgrep": {
      const recurse = flags.some((flag, k) => flag === "-d" && flags[k + 1] === "recurse");
      return shortFlag(flags, "rR") || recurse
        || longFlag(flags, "--recursive", "--dereference-recursive", "--directories=recurse") ? walk(true, true) : null;
    }
    case "ls": case "gls":
      return shortFlag(flags, "R") || longFlag(flags, "--recursive") ? walk(false, true) : null;
    case "cp": case "gcp": case "scp":
      return shortFlag(flags, "rRa") || longFlag(flags, "--recursive", "--archive") ? walk(false, true) : null;
    case "rm":
      return shortFlag(flags, "rR") || longFlag(flags, "--recursive") ? walk(false, true) : null;
    case "chmod": case "chown": case "chgrp":
      return shortFlag(flags, "R") ? walk(false, true) : null;
    case "zip":
      return shortFlag(flags, "r") ? walk(false, true) : null;
    default:
      return null;
  }
}

function walkVerdict(cmd, cwd, ctx) {
  const { prog, args } = programOf(cmd.words);
  const flags = args.map(plainText);
  const walk = walkOf(prog, flags);
  if (!walk) return null;
  const roots = [];
  let operands = 0;
  for (let k = 0; k < args.length; k++) {
    if (flags[k].startsWith("-")) {
      if (walk.leading) break;
      continue;
    }
    operands++;
    for (const abs of candidates(args[k], cwd, ctx, true)) {
      const root = firstSpecial(abs) >= 0 ? wildcardRoot(abs, ctx).prefix : resolved(ctx, plainText(abs));
      if (isDirectory(root)) roots.push(root);
    }
  }
  // No directory operand: the walk starts from the working directory.
  if (!roots.length && operands <= (walk.pattern ? 1 : 0) && cwd !== null) roots.push(resolved(ctx, cwd));
  for (const root of unique(roots)) {
    const verdict = walkCheck(root, ctx, walk.bypass);
    if (verdict) return verdict;
  }
  return null;
}

// Does this word name protected state? `deep` also counts a folder that holds
// it (a delete or a move takes the folder's contents with it).
function namesState(word, cwd, ctx, deep, wholeOnly) {
  for (const abs of candidates(word, cwd, ctx, wholeOnly)) {
    if (firstSpecial(abs) >= 0) {
      const { prefix, rest } = wildcardRoot(abs, ctx);
      for (const file of protectedFiles(ctx)) {
        if (file !== prefix && within(file, prefix) && patternNames(rest, relativeParts(prefix, file), { exact: !deep })) return file;
      }
      continue;
    }
    const target = resolved(ctx, plainText(abs));
    if (isProtected(target, ctx) || (deep && holdsProtected(target, ctx))) return target;
  }
  return null;
}

// A copy or move into a folder lands at folder/basename(source).
function landsOnState(sources, dest, cwd, ctx) {
  const dir = literalDir(dest, cwd, ctx);
  if (!dir || !isDirectory(dir)) return null;
  for (const source of sources) {
    const target = path.join(dir, path.posix.basename(plainText(source)));
    if (isProtected(target, ctx)) return target;
  }
  return null;
}

// Changes to the registry and the boundary cache: redirections, deletes,
// moves, copies over, in-place edits, and any interpreter naming them.
function stateVerdict(cmd, cwd, ctx) {
  for (const word of cmd.redirects) {
    const hit = namesState(word, cwd, ctx, false, true);
    if (hit) return stateBlock(hit);
  }
  const { prog, args } = programOf(cmd.words);
  const flags = args.map(plainText);
  const operands = args.filter((_, k) => !flags[k].startsWith("-"));
  const check = (words, deep, wholeOnly = true) => {
    for (const word of words) {
      const hit = namesState(word, cwd, ctx, deep, wholeOnly);
      if (hit) return stateBlock(hit);
    }
    return null;
  };
  if (DELETERS.has(prog)) return check(operands, true);
  if (prog === "mv" || COPIERS.has(prog)) {
    const sources = operands.slice(0, -1);
    const dest = operands[operands.length - 1];
    const deepDest = prog === "rsync" && longPrefix(flags, "--delete");
    const moved = prog === "mv" ? check(sources, true) : null;
    if (moved) return moved;
    if (!dest) return null;
    const over = check([dest], deepDest);
    if (over) return over;
    const landed = landsOnState(sources, dest, cwd, ctx);
    return landed ? stateBlock(landed) : null;
  }
  if (OVERWRITERS.has(prog)) return check(operands, false, false);
  if (prog === "sed" && flags.some((flag) => /^-[A-Za-z]*i/.test(flag) || flag.startsWith("--in-place"))) {
    return check(operands, false);
  }
  if (prog === "find" && flags.some((flag) => /^-(?:delete|exec|execdir|ok|okdir)$/.test(flag))) {
    const roots = [];
    for (let k = 0; k < args.length && !flags[k].startsWith("-"); k++) roots.push(args[k]);
    return check(roots, true);
  }
  if (INTERPRETERS.has(prog)) {
    const registryDir = path.join(ctx.home, ".egregore");
    for (const word of cmd.words) {
      const hit = namesState(word, cwd, ctx, false, false);
      if (hit) return stateBlock(hit);
      for (const abs of candidates(word, cwd, ctx)) {
        if (firstSpecial(abs) < 0 && resolved(ctx, plainText(abs)) === resolved(ctx, registryDir)) return stateBlock(registryDir);
      }
    }
  }
  return null;
}

// Shell text a command runs in turn: `bash -c '…'`, `eval …`.
function innerScript(cmd) {
  const { prog, args } = programOf(cmd.words);
  const source = (word) => word.split(LITERAL).join("").split(UNKNOWN).join("${__egregore_unknown}").split(PWD_MARK).join("$PWD");
  if (prog === "eval") return args.map(source).join(" ");
  if (SHELLS.has(prog)) {
    const k = args.findIndex((word) => /^-[A-Za-z]*c[A-Za-z]*$/.test(plainText(word)));
    if (k >= 0 && k + 1 < args.length) return source(args[k + 1]);
  }
  return null;
}

function checkCommand(cmd, cwd, ctx, depth) {
  for (const word of [...cmd.words, ...cmd.inputs, ...cmd.redirects]) {
    for (const abs of candidates(word, cwd, ctx)) {
      const verdict = checkCandidate(abs, ctx);
      if (verdict) return verdict;
    }
  }
  const inner = depth < 3 ? innerScript(cmd) : null;
  if (inner !== null) {
    const verdict = checkScript(inner, ctx, cwd, depth + 1);
    if (verdict) return verdict;
  }
  return walkVerdict(cmd, cwd, ctx) || stateVerdict(cmd, cwd, ctx);
}

// Each scan carries one cwd spelling through cd / pushd / popd and restores
// it across subshells. A logical scan keeps symlink names until '..' has
// collapsed; a physical scan follows the filesystem. Both must pass.
function checkScriptItems(items, ctx, baseDir, depth) {
  // Immutable directory state makes subshell snapshots O(1), including
  // OLDPWD and the pushd stack. Each scan owns its own history.
  let state = { cwd: baseDir, oldcwd: null, dirs: null };
  const frames = [];
  for (const item of items) {
    if (item.push) { frames.push(state); continue; }
    if (item.pop) { if (frames.length) state = frames.pop(); continue; }
    const verdict = checkCommand(item, state.cwd, ctx, depth);
    if (verdict) return verdict;
    const next = nextCwd(item, state, ctx);
    if (next.cwd !== null && next.cwd !== state.cwd) {
      const hard = hardCheck(next.cwd, ctx);
      if (hard) return hard;
    }
    state = next;
  }
  return null;
}

function checkScript(text, ctx, baseDir, depth = 0) {
  const items = lexShell(text, ctx);
  // Nested shell scripts keep their caller's mode, so nested scans do not
  // branch exponentially. Parse once and run at most two linear scans.
  if (Object.prototype.hasOwnProperty.call(ctx, "logicalCwd")) return checkScriptItems(items, ctx, baseDir, depth);
  return checkScriptItems(items, { ...ctx, logicalCwd: false }, baseDir === null ? null : resolved(ctx, baseDir), depth)
    || checkScriptItems(items, { ...ctx, logicalCwd: true }, baseDir === null ? null : lexicalPath(baseDir), depth);
}

// Another instance's absolute path written anywhere in the text: in code, a
// heredoc, a quoted string. Matched on a path boundary so a longer sibling
// name sharing the prefix never matches.
function literalDenial(command, ctx) {
  const h = ctx.home;
  const known = (text) => text.replace(/\$\{HOME\}|\$HOME(?![A-Za-z0-9_])/g, h);
  const texts = unique([known(command), known(command.replace(/\\(.)/g, "$1").replace(/["']/g, ""))]);
  for (const denied of ctx.boundary.denied) {
    if (enclosesProject(denied, ctx)) continue;
    const pattern = new RegExp(`${escapeRegex(denied)}(?:$|[^A-Za-z0-9._-])`, "m");
    if (texts.some((text) => pattern.test(text))) return hardBlock(denied, denied);
  }
  return null;
}

function softShell(command, ctx, baseDir) {
  const text = command.replace(/\\(.)/g, "$1").replace(/["']/g, "").replace(/\$\{HOME\}|\$HOME(?![A-Za-z0-9_])/g, ctx.home)
    .replace(/\/{2,}/g, "/");
  for (const token of unique(text.match(SOFT_TOKEN) || [])) {
    if (/[*?[{]/.test(token)) continue;
    const named = absolute(token, baseDir, ctx.home);
    const hard = hardCheck(named, ctx);
    if (hard) return hard;
    if (ctx.softOff || ctx.boundary.posture === "open" || ctx.relaxed) continue;
    const target = resolved(ctx, named);
    if (inCore(target, ctx) || inReadRoots(target, ctx) || isConsented(target, ctx)) continue;
    return softBlock(target, "shell", ctx);
  }
  return null;
}

function checkShell(command, ctx, baseDir) {
  return literalDenial(command, ctx) || checkScript(command, ctx, baseDir) || softShell(command, ctx, baseDir);
}

// ── Operations ───────────────────────────────────────────────────────────

function extractApplyPatchPaths(patch) {
  const paths = [];
  for (const line of String(patch || "").split(/\r?\n/)) {
    const match = line.match(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/) || line.match(/^\*\*\* Move to: (.+)$/);
    if (match && match[1]) paths.push(match[1].trim());
  }
  return paths;
}

function textOf(value) {
  if (Array.isArray(value)) return value.map(String).join(" ");
  return typeof value === "string" ? value : "";
}

// An argv array (Codex `shell`) as the shell text that runs it: each element
// quoted, so `["bash", "-lc", "cd .. && …"]` keeps its script intact.
function shellText(value) {
  if (Array.isArray(value)) return value.map((item) => `'${String(item).replace(/'/g, "'\\''")}'`).join(" ");
  return typeof value === "string" ? value : "";
}

// Pi accepts "@path" for a file; check the path both ways.
function pathForms(value) {
  if (typeof value !== "string" || !value) return [];
  return value.startsWith("@") && value.length > 1 ? [value, value.slice(1)] : [value];
}

function pathKey(key) {
  return PATH_KEY.test(String(key).replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase());
}

// Every string under a path-named key, at any depth: directly, in an array
// (paths: [...]), or below it in nested objects (files: [{ path }],
// options: { target: { dir } }).
function pathFields(value) {
  const found = [];
  const seen = new Set();
  const visit = (item, named) => {
    if (typeof item === "string") {
      if (named) found.push(...pathForms(item));
      return;
    }
    if (!item || typeof item !== "object" || seen.has(item)) return;
    seen.add(item);
    if (Array.isArray(item)) {
      for (const entry of item) visit(entry, named);
      return;
    }
    for (const [key, entry] of Object.entries(item)) visit(entry, pathKey(key));
  };
  visit(value, false);
  return found;
}

// One canonical operation from Claude Code, Codex, Pi, or Prime tool input.
function normalizeOperation(input, projectDir) {
  const name = String(input.tool_name || input.toolName || "");
  let toolInput = input.tool_input ?? input.input ?? {};
  if (typeof toolInput === "string") toolInput = { command: toolInput };
  if (!toolInput || typeof toolInput !== "object") toolInput = {};
  const workdir = [toolInput.workdir, toolInput.cwd, input.cwd].find((value) => typeof value === "string" && value) || ".";
  // Preserve symlink/.. traversal until the hard tier has inspected BOTH
  // spellings. path.resolve here would discard the physical destination.
  const baseDir = absolute(workdir, projectDir, home());
  if (READ_TOOLS.has(name)) {
    return { kind: "read", targets: pathForms(name === "Read" ? toolInput.file_path : toolInput.path), baseDir };
  }
  if (SEARCH_TOOLS.has(name)) {
    // Glob (Claude) and find (Pi) take a glob `pattern`; Grep's `pattern` is a regex.
    const pattern = name === "Glob" || name === "find" ? String(toolInput.pattern || "") : "";
    return { kind: "search", targets: pathForms(toolInput.path), pattern, baseDir };
  }
  if (WRITE_TOOLS.has(name)) {
    return { kind: "write", targets: pathForms(toolInput.file_path || toolInput.notebook_path || toolInput.path), baseDir };
  }
  if (PATCH_TOOLS.has(name)) {
    const patch = textOf(toolInput.command) || textOf(toolInput.patch) || textOf(toolInput.input);
    return { kind: "write", targets: extractApplyPatchPaths(patch), baseDir };
  }
  if (SHELL_TOOLS.has(name)) {
    const command = shellText(toolInput.command) || shellText(toolInput.cmd) || textOf(toolInput.code) || textOf(toolInput.chars);
    return { kind: "shell", command, baseDir };
  }
  const known = TOOL_PATHS[name];
  if (known) {
    return { kind: known.kind, targets: known.fields.flatMap((field) => pathForms(toolInput[field])), baseDir };
  }
  return { kind: "other", targets: pathFields(toolInput), baseDir };
}

// Structured searches honour ignore files: a nested instance inside the
// project does not stop them; an instance below a root outside it does.
function checkSearch(op, ctx) {
  for (const target of op.targets) {
    const verdict = checkPath(target, "read", ctx, op.baseDir);
    if (verdict) return verdict;
  }
  const root = op.targets.length ? resolvePath(op.targets[op.targets.length - 1], op.baseDir) : resolved(ctx, op.baseDir);
  const walk = walkCheck(root, ctx, false);
  if (walk) return walk;
  for (const pattern of op.pattern ? braceExpand(op.pattern) || [op.pattern] : []) {
    const candidate = absolute(pattern, root, ctx.home);
    if (firstSpecial(candidate) >= 0) {
      const verdict = wildcardCheck(candidate, ctx);
      if (verdict) return verdict;
    }
    const prefix = firstSpecial(candidate) >= 0 ? wildcardRoot(candidate, ctx).prefix : resolved(ctx, plainText(candidate));
    const fromPrefix = hardCheck(firstSpecial(candidate) < 0 ? plainText(candidate) : prefix, ctx)
      || walkCheck(prefix, ctx, false);
    if (fromPrefix) return fromPrefix;
    // An absolute pattern names its own root, which needs consent like a path.
    if (prefix !== root && !within(prefix, root)) {
      const soft = checkPath(prefix, "read", ctx, op.baseDir);
      if (soft) return soft;
    }
  }
  return null;
}

function decideInner(input, projectDir) {
  if (process.env.EGREGORE_BOUNDARY_TEST_FAULT === "1") throw new Error("injected test fault");
  const op = normalizeOperation(input, projectDir);
  const ctx = context(projectDir, input);
  // The effective working directory is itself an access.
  const cwd = hardCheck(op.baseDir, ctx);
  if (cwd) return cwd;
  if (op.kind === "shell") return checkShell(op.command, ctx, op.baseDir) || allow();
  if (op.kind === "search") return checkSearch(op, ctx) || allow();
  for (const target of op.targets) {
    const verdict = op.kind === "other"
      ? hardCheck(absolute(target, op.baseDir, ctx.home), ctx)
      : checkPath(target, op.kind, ctx, op.baseDir);
    if (verdict) return verdict;
  }
  return allow();
}

// An unexpected error must neither open the wall nor block normal work. Known
// denials (registry ∪ cache, read again here) are enforced first; then
// anything that cannot be shown to sit inside the project, memory, managed
// repositories, or system paths is denied, and the rest allowed.
function failSafe(input, projectDir, error) {
  const denial = (subject) => ({
    outcome: "deny",
    reason: "internal-error",
    message: `Environment isolation: the boundary check failed (${error && error.message ? error.message : error}), so ${subject} cannot be verified and access outside this project is denied. Paths inside the project still work. Do not retry and do not attempt via other tools; ask the user to report this.`,
  });
  try {
    const op = normalizeOperation(input, projectDir);
    let fresh = {};
    try { fresh = computeBoundary(projectDir); } catch {}
    const cached = readJson(cachePath(projectDir));
    const listed = [...strings(fresh.denied_paths), ...(usableCache(cached) ? strings(cached.denied_paths) : [])];
    let denied = listed;
    try { denied = deniedForms(listed); } catch {}
    let realProject = projectDir;
    try { realProject = fs.realpathSync.native(projectDir); } catch {}
    const verified = {
      memoryDir: fresh.memory_dir || "",
      managedRepos: strings(fresh.managed_repos),
      mainCheckout: fresh.main_checkout || "",
    };
    const registryUnreadable = fresh.registry_unreadable === true
      || (usableCache(cached) && cached.registry_unreadable === true);
    const ctx = { projectDir, realProject, home: home(), boundary: { projectDir, denied, registryUnreadable, ...verified, verified } };
    const h = ctx.home;
    let targets = op.targets || [];
    if (op.kind === "search" && op.pattern) {
      const root = targets.length ? absolute(targets[targets.length - 1], op.baseDir, h) : op.baseDir;
      for (const pattern of braceExpand(op.pattern) || [op.pattern]) {
        const candidate = absolute(pattern, root, h);
        const hard = checkCandidate(candidate, ctx);
        if (hard) return hard;
        const prefix = firstSpecial(candidate) >= 0 ? wildcardRoot(candidate, ctx).prefix : physicalPath(candidate);
        if (!inCore(prefix, ctx, true)) return denial(prefix);
        const walk = walkCheck(prefix, ctx, false);
        if (walk) return walk;
      }
    }
    if (op.kind === "shell") {
      const named = literalDenial(op.command, ctx);
      if (named) return named;
      const text = op.command.replace(/\\(.)/g, "$1").replace(/["']/g, "").replace(/\$\{HOME\}|\$HOME(?![A-Za-z0-9_])/g, h);
      // Retain walk containment and protected-state writes in the error
      // path too; these use the same hard tier and no consent decisions.
      const hard = checkScript(op.command, ctx, op.baseDir);
      if (hard) return hard;
      // Nothing run-time can be verified here: a variable, substitution,
      // glob or directory change outside plain project paths is refused.
      if (/[$`*?[{]|(?:^|[\s;&|(])(?:cd|pushd)\s/.test(text) && /[/~]|\.\./.test(text)) return denial("this command");
      targets = text.split(/[\s;&|()<>=:,]+/).filter((token) => token.includes("/") || token === ".." || token.startsWith("~"));
    }
    for (const candidate of [op.baseDir, ...targets.map((target) => absolute(target, op.baseDir, h))]) {
      const target = physicalPath(candidate);
      const entry = deniedEntry(candidate, ctx);
      if (entry) return hardBlock(target, entry);
      if (op.kind === "write" && isProtected(target, ctx)) return stateBlock(target);
      // An internal error only trusts roots verified on disk, regardless of
      // whether the registry itself is damaged. Keep that failure distinct
      // from actual registry failure so all adapters give the same reason.
      if (!inCore(target, ctx, true)) return denial(target);
      if (op.kind === "search") {
        const walk = walkCheck(target, ctx, false);
        if (walk) return walk;
      }
    }
    return allow();
  } catch {
    return {
      outcome: "deny",
      reason: "internal-error",
      message: "Environment isolation: the boundary check failed and could not verify this action, so it is denied. Do not retry and do not attempt via other tools; ask the user to report this.",
    };
  }
}

function defaultProjectDir() {
  return process.env.CLAUDE_PROJECT_DIR || path.resolve(__dirname, "..");
}

// Returns { outcome: "allow" | "consent" | "deny", reason, message }.
function decide(input, options = {}) {
  const projectDir = options.projectDir || defaultProjectDir();
  const payload = input && typeof input === "object" ? input : {};
  try {
    return decideInner(payload, projectDir);
  } catch (error) {
    return failSafe(payload, projectDir, error);
  }
}

// Pi and Prime tool_call adapter: block the same way the branch policy does.
function toolCallBlock(event, ctx, projectDir) {
  const verdict = decide(
    { tool_name: event && event.toolName, tool_input: event && event.input, cwd: ctx && ctx.cwd },
    { projectDir: projectDir || (ctx && ctx.cwd) || process.cwd() },
  );
  return verdict.outcome === "allow" ? undefined : { block: true, reason: verdict.message };
}

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

// PreToolUse hook contract shared by Claude Code and Codex: exit 0 allows;
// exit 2 with the reason on stderr blocks (deny and consent alike).
function main(options = {}) {
  let input;
  try {
    input = JSON.parse(readStdin() || "{}");
  } catch {
    input = {};
  }
  const verdict = decide(input, options);
  if (verdict.outcome === "allow") return;
  process.stderr.write(`${verdict.message}\n`);
  process.exitCode = 2;
}

function cli(argv) {
  const [mode, ...rest] = argv;
  const flag = (name) => {
    const index = rest.indexOf(name);
    return index >= 0 ? rest.splice(index, 2)[1] : "";
  };
  if (mode === "write-cache") {
    if (!rest[0]) throw new Error("usage: boundary-guard.cjs write-cache <project_dir>");
    process.stdout.write(`${writeCache(rest[0])}\n`);
    return;
  }
  if (mode === "native-denials") {
    if (!rest[0]) throw new Error("usage: boundary-guard.cjs native-denials <project_dir>");
    process.stdout.write(`${JSON.stringify(nativeDenials(rest[0]))}\n`);
    return;
  }
  if (mode === "compute-denied") {
    const [registry, projectDir, orgId = "", allowPath = ""] = rest;
    if (!registry || !projectDir) throw new Error("usage: boundary-guard.cjs compute-denied <registry> <project_dir> [org_id] [allow_path]");
    const result = computeDenied(registry, projectDir, orgId, allowPath);
    if (result.unreadable) {
      process.stderr.write(`boundary-guard: instance registry ${registry} cannot be read\n`);
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`${JSON.stringify(result.paths, null, 2)}\n`);
    return;
  }
  if (mode === "check") {
    const projectDir = flag("--project-dir") || defaultProjectDir();
    if (!rest[0]) throw new Error("usage: boundary-guard.cjs check <path> [--project-dir DIR]");
    const ctx = context(projectDir, {});
    const target = absolute(rest[0], projectDir, ctx.home);
    const entry = deniedEntry(target, ctx);
    if (entry) {
      process.stdout.write(entry === "registry"
        ? `BLOCKED: ${target} cannot be verified (instance registry unreadable)\n`
        : `${hardBlock(target, entry).message}\n`);
      process.exitCode = 1;
    } else if (!inCore(resolved(ctx, target), ctx)) {
      process.stdout.write(`BLOCKED: ${target} is outside the session boundary\n`);
      process.exitCode = 1;
    }
    return;
  }
  const projectDir = mode === "--project-dir" ? rest[0] : "";
  main(projectDir ? { projectDir } : {});
}

module.exports = {
  EGREGORE_ALLOWED_FAMILIES,
  cachePath,
  computeBoundary,
  computeDenied,
  decide,
  main,
  nativeDenials,
  toolCallBlock,
  writeCache,
};

if (require.main === module) {
  try {
    cli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error && error.message ? error.message : error}\n`);
    process.exitCode = 1;
  }
}
