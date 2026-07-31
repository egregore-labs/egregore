#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function readStdin() {
  try {
    return fs.readFileSync(0, "utf-8");
  } catch {
    return "";
  }
}

function parseJson(raw) {
  try {
    return JSON.parse(raw || "{}");
  } catch {
    return {};
  }
}

function run(cmd, args, cwd) {
  const result = spawnSync(cmd, args, { cwd, encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] });
  if (result.status !== 0) return "";
  return String(result.stdout || "").trim();
}

function realish(filePath) {
  const absolute = path.resolve(filePath);
  let cursor = absolute;
  while (!fs.existsSync(cursor)) {
    const parent = path.dirname(cursor);
    if (parent === cursor) return absolute;
    cursor = parent;
  }
  try {
    const resolved = fs.realpathSync(cursor);
    return path.join(resolved, path.relative(cursor, absolute));
  } catch {
    return absolute;
  }
}

function inside(child, parent) {
  const rel = path.relative(parent, child);
  return rel === "" || (!!rel && !rel.startsWith("..") && !path.isAbsolute(rel));
}

function nearestExistingDirectory(candidate) {
  let cursor = path.resolve(candidate);
  try {
    if (fs.existsSync(cursor) && !fs.statSync(cursor).isDirectory()) cursor = path.dirname(cursor);
  } catch {}
  while (!fs.existsSync(cursor)) {
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  return cursor;
}

function gitContext(candidate) {
  if (!candidate) return null;
  const probe = nearestExistingDirectory(candidate);
  const top = run("git", ["-C", probe, "rev-parse", "--show-toplevel"], probe);
  if (!top) return null;
  const commonRaw = run("git", ["-C", top, "rev-parse", "--git-common-dir"], top);
  const common = commonRaw
    ? realish(path.isAbsolute(commonRaw) ? commonRaw : path.join(top, commonRaw))
    : realish(path.join(top, ".git"));
  return { top: realish(top), common };
}

function shellRetarget(command) {
  // Only retarget a single operation. Mixed command chains are evaluated from
  // the hub context so one external `git -C` cannot mask a later project write.
  if (shellSegments(command).length !== 1) return "";
  const gitC = String(command || "").match(/(?:^|[;&|]\s*)git\s+-C\s+("[^"]*"|'[^']*'|[^\s;&|]+)/);
  const cdAnd = String(command || "").match(/^\s*cd\s+("[^"]*"|'[^']*'|[^\s;&|]+)\s*&&/);
  const raw = (gitC && gitC[1]) || (cdAnd && cdAnd[1]) || "";
  const target = raw.replace(/^['"]|['"]$/g, "");
  return /[$`*?]/.test(target) ? "" : target;
}

function operationCandidate(input, baseDir) {
  const toolName = input.tool_name || "";
  const toolInput = input.tool_input || {};
  const explicitWorkdir = toolInput.workdir || toolInput.cwd || "";
  let candidate = explicitWorkdir
    ? (path.isAbsolute(explicitWorkdir) ? explicitWorkdir : path.join(baseDir, explicitWorkdir))
    : baseDir;

  if (toolName === "Edit" || toolName === "Write") {
    const target = toolInput.file_path || toolInput.path || "";
    if (target) candidate = path.isAbsolute(target) ? target : path.join(candidate, target);
  } else if (toolName === "Bash") {
    const target = shellRetarget(toolInput.command || "");
    if (target) candidate = path.isAbsolute(target) ? target : path.join(candidate, target);
  }

  return candidate;
}

function findProjectContext(input) {
  // The launcher keeps EGREGORE_CODEX_PROJECT_DIR on the hub checkout while
  // individual tool calls can target a task worktree, memory, or a managed
  // repo. Compare Git common dirs: a task worktree shares the hub common dir
  // and must use its own branch; memory/managed repos are separate and exempt.
  const fallback = input.cwd || process.cwd();
  const hubSeed = process.env.EGREGORE_CODEX_PROJECT_DIR || fallback;
  const hub = gitContext(hubSeed);
  const baseDir = input.cwd || hub?.top || fallback;
  const candidate = operationCandidate(input, baseDir);
  const operation = gitContext(candidate);

  if (!hub) return { projectDir: operation?.top || realish(baseDir), external: false };
  if (operation && operation.common === hub.common) {
    return { projectDir: operation.top, external: false };
  }
  if (operation && operation.common !== hub.common) {
    return { projectDir: hub.top, external: true };
  }

  const resolvedCandidate = realish(candidate);
  if (!inside(resolvedCandidate, hub.top)) {
    return { projectDir: hub.top, external: true };
  }
  return { projectDir: hub.top, external: false };
}

function currentBranch(projectDir) {
  return run("git", ["-C", projectDir, "rev-parse", "--abbrev-ref", "HEAD"], projectDir);
}

function currentAuthor(projectDir) {
  try {
    const raw = fs.readFileSync(path.join(projectDir, ".egregore-state.json"), "utf-8");
    const state = JSON.parse(raw);
    const value = state.handle || state.display_name || state.name || "dev";
    return String(value).trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "") || "dev";
  } catch {
    return "dev";
  }
}

function isProtectedBranch(branch) {
  return branch === "develop" || branch === "main" || branch === "master";
}

function isExemptPath(rawPath, projectDir, memoryDir) {
  if (!rawPath) return false;
  const absolute = path.isAbsolute(rawPath) ? rawPath : path.join(projectDir, rawPath);
  const resolved = realish(absolute);

  for (const dir of [".claude", ".codex", "memory"]) {
    const target = realish(path.join(projectDir, dir));
    if (inside(resolved, target)) return true;
  }

  for (const file of [".egregore-state.json", ".egregore-branch-consent", ".env"]) {
    if (resolved === realish(path.join(projectDir, file))) return true;
  }

  if (memoryDir && inside(resolved, memoryDir)) return true;

  return !inside(resolved, projectDir);
}

function extractApplyPatchPaths(command) {
  const paths = [];
  for (const line of String(command || "").split(/\r?\n/)) {
    const match = line.match(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/) || line.match(/^\*\*\* Move to: (.+)$/);
    if (match && match[1]) paths.push(match[1].trim());
  }
  return paths;
}

function commandTargetsOtherRepo(command, projectDir, memoryDir) {
  const paths = [];
  const patterns = [
    /\bcd\s+["']?([^"';&|]+)["']?/g,
    /\bgit\s+-C\s+["']?([^"';&|]+)["']?/g,
  ];
  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(command))) paths.push(match[1]);
  }

  for (const raw of paths) {
    const resolved = realish(path.isAbsolute(raw) ? raw : path.join(projectDir, raw));
    if (memoryDir && inside(resolved, memoryDir)) return true;
    if (!inside(resolved, projectDir)) return true;
  }
  return false;
}

function isBranchSetupCommand(command) {
  if (shellSegments(command).length !== 1) return false;
  return (
    /^\s*bin\/agent\.sh\s+branch\b/.test(command) ||
    /^\s*git\s+(checkout|switch)\s+(-b|-c)\b/.test(command) ||
    /^\s*git\s+branch\s+(dev|feature|bugfix)\//.test(command) ||
    /^\s*git\s+worktree\s+add\b/.test(command) ||
    /^\s*bin\/worktree\.sh\s+setup\b/.test(command)
  );
}

function stagedOnlyFrameworkPaths(projectDir) {
  const files = run("git", ["-C", projectDir, "diff", "--cached", "--name-only"], projectDir)
    .split(/\r?\n/)
    .filter(Boolean);
  return files.length > 0 && files.every((file) => /^(bin\/|\.claude\/|\.codex\/|CLAUDE\.md$|AGENTS\.md$|skills\/)/.test(file));
}

function stripQuotedSegments(command) {
  let out = "";
  let quote = null;
  for (let i = 0; i < String(command || "").length; i++) {
    const ch = command[i];
    if (quote) {
      if (quote === '"' && ch === "\\") i++;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      out += "x";
      continue;
    }
    out += ch;
  }
  return out;
}

function maskQuotedOperators(command) {
  let out = "";
  let quote = null;
  for (let i = 0; i < String(command || "").length; i++) {
    const ch = command[i];
    if (quote) {
      if (quote === '"' && ch === "\\") {
        out += ch;
        if (i + 1 < command.length) out += command[++i];
        continue;
      }
      if (ch === quote) quote = null;
      out += /[><|;&]/.test(ch) ? " " : ch;
      continue;
    }
    if (ch === "'" || ch === '"') quote = ch;
    out += ch;
  }
  return out;
}

function shellSegments(command) {
  const segments = [];
  let current = "";
  let quote = null;
  for (let i = 0; i < String(command || "").length; i++) {
    const ch = command[i];
    if (quote) {
      current += ch;
      if (quote === '"' && ch === "\\" && i + 1 < command.length) current += command[++i];
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      current += ch;
      continue;
    }
    if (ch === ";" || ch === "|" || ch === "&" || ch === "\n") {
      if (current.trim()) segments.push(current.trim());
      current = "";
      continue;
    }
    current += ch;
  }
  if (current.trim()) segments.push(current.trim());
  return segments;
}

function shellWords(segment) {
  const words = [];
  let current = "";
  let quote = null;
  for (let i = 0; i < String(segment || "").length; i++) {
    const ch = segment[i];
    if (quote) {
      if (quote === '"' && ch === "\\" && i + 1 < segment.length) current += segment[++i];
      else if (ch === quote) quote = null;
      else current += ch;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      continue;
    }
    if (/\s/.test(ch)) {
      if (current) words.push(current);
      current = "";
      continue;
    }
    if (ch === "\\") {
      if (i + 1 < segment.length) current += segment[++i];
      continue;
    }
    current += ch;
  }
  if (current) words.push(current);
  return words;
}

function filesystemMutationStatus(command, projectDir, memoryDir) {
  const commands = new Set(["rm", "mv", "cp", "mkdir", "rmdir", "touch", "chmod", "chown", "ln", "tee"]);
  let unsafe = false;

  for (const segment of shellSegments(command)) {
    const words = shellWords(segment);
    while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0])) words.shift();
    while (words[0] === "sudo" || words[0] === "command" || words[0] === "env") words.shift();
    if (!words.length) continue;

    const name = path.basename(words.shift());
    if (!commands.has(name)) continue;

    const args = words.filter((word) => !word.startsWith("-"));
    let targets = args;
    if (name === "cp" || name === "ln") targets = args.length ? [args[args.length - 1]] : [];
    if (name === "chmod" || name === "chown") targets = args.slice(1);

    if (!targets.length || targets.some((target) =>
      /[$`*?{}]/.test(target) || !isExemptPath(target, projectDir, memoryDir)
    )) unsafe = true;
  }

  return { unsafe };
}

function redirectLooksMutating(command, projectDir, memoryDir) {
  const visible = maskQuotedOperators(command);
  const redirectPatterns = [
    /(?:^|[\s;|&])(?:\d*)>>?\s*([^&\s;|]+)/g,
    /\|\s*tee\s+(?:-a\s+)?([^&\s;|]+)/g,
  ];

  for (const pattern of redirectPatterns) {
    let match;
    while ((match = pattern.exec(visible))) {
      const target = String(match[1] || "").replace(/^["']|["']$/g, "");
      if (!target || target === "/dev/null" || target.startsWith("$")) continue;
      if (!isExemptPath(target, projectDir, memoryDir)) return true;
    }
  }
  return false;
}

function shellLooksMutating(command, projectDir, memoryDir) {
  if (!command.trim()) return false;
  const visible = stripQuotedSegments(command);
  if (isBranchSetupCommand(visible)) return false;

  const mutatingPatterns = [
    /(?:^|[;&|(\n]\s*)(?:sudo\s+)?git(?:\s+-C\s+\S+)?\s+(add|commit|push|rm|mv|reset|restore|checkout\s+--|clean|rebase|merge|cherry-pick)\b/,
    /(?:^|[;&|(\n]\s*)(?:sudo\s+)?apply_patch\b/,
    /(?:^|[;&|(\n]\s*)(?:sudo\s+)?(sed|perl)\b[^;&|]*\s-i(\s|$)/,
    /(?:^|[;&|(\n]\s*)(?:sudo\s+)?(npm|pnpm|yarn|bun)\s+(install|add|remove|update|dedupe|ci)\b/,
    /(?:^|[;&|(\n]\s*)(?:sudo\s+)?(go\s+mod\s+tidy|cargo\s+(fmt|fix|update)|rustfmt|prettier\s+--write|eslint\s+--fix)\b/,
  ];

  const gitCommit = /(?:^|[;&|(\n]\s*)(?:sudo\s+)?git(?:\s+-C\s+\S+)?\s+commit\b/.test(visible);
  if (gitCommit && stagedOnlyFrameworkPaths(projectDir)) return false;

  const filesystem = filesystemMutationStatus(command, projectDir, memoryDir);
  return mutatingPatterns.some((pattern) => pattern.test(visible)) ||
    filesystem.unsafe ||
    redirectLooksMutating(command, projectDir, memoryDir);
}

function isConsentCommand(command, branch) {
  const escaped = branch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(
    `^\\s*echo\\s+['"]?${escaped}['"]?\\s*>\\s*(?:\\./)?\\.egregore-branch-consent\\s*$`
  ).test(String(command || ""));
}

function deny(reason) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  }));
}

function main() {
  const input = parseJson(readStdin());
  const context = findProjectContext(input);
  if (context.external) return;
  const projectDir = context.projectDir;
  const branch = currentBranch(projectDir);
  if (!isProtectedBranch(branch)) return;

  // Consent bypass: the user explicitly chose to work on this protected branch.
  // Written only after they pick "Proceed on <branch>"; cleared on session start,
  // so consent is asked once per session, not per write.
  try {
    const consent = fs.readFileSync(path.join(projectDir, ".egregore-branch-consent"), "utf-8").trim();
    if (consent === branch) return;
  } catch {}

  const toolName = input.tool_name || "";
  const toolInput = input.tool_input || {};
  const memoryDir = realish(path.join(projectDir, "memory"));
  const author = currentAuthor(projectDir);
  const reason = [
    `Protected branch (${branch}). Move project work to a task branch before writing.`,
    `If the work topic is clear, run bin/agent.sh branch --topic "<work topic>" automatically (prefix dev/${author}/...), continue in the printed worktree, and briefly tell the user.`,
    "Ask only when the work topic is genuinely ambiguous; ask for the topic, not for routine Git permission.",
    `Only when the user explicitly requested writing on ${branch}, record consent with: echo '${branch}' > .egregore-branch-consent`,
    "Memory, framework-runtime, and managed-repo writes are exempt and should not trigger this guard.",
  ].join("\n");

  if (toolName === "apply_patch") {
    const changedPaths = extractApplyPatchPaths(toolInput.command || "");
    if (changedPaths.length === 0 || changedPaths.some((p) => !isExemptPath(p, projectDir, memoryDir))) {
      deny(reason);
    }
    return;
  }

  if (toolName === "Edit" || toolName === "Write") {
    const target = toolInput.file_path || toolInput.path || "";
    if (!target || !isExemptPath(target, projectDir, memoryDir)) deny(reason);
    return;
  }

  if (toolName === "Bash") {
    const command = String(toolInput.command || "");
    if (isConsentCommand(command, branch)) return;
    if (commandTargetsOtherRepo(command, projectDir, memoryDir)) return;
    if (shellLooksMutating(command, projectDir, memoryDir)) deny(reason);
  }
}

main();
