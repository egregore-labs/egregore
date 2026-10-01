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

const commandCache = new Map();

function run(cmd, args, cwd) {
  const key = JSON.stringify([cmd, args, cwd]);
  if (commandCache.has(key)) return commandCache.get(key);
  const result = spawnSync(cmd, args, { cwd, encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] });
  if (result.status !== 0) return "";
  const output = String(result.stdout || "").trim();
  commandCache.set(key, output);
  return output;
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

function configuredBaseBranch(projectDir) {
  try {
    const raw = fs.readFileSync(path.join(projectDir, "egregore.json"), "utf-8");
    const value = JSON.parse(raw).base_branch;
    return typeof value === "string" && value.trim() ? value.trim() : "develop";
  } catch {
    return "develop";
  }
}

function isProtectedBranch(branch, projectDir) {
  return branch === configuredBaseBranch(projectDir) ||
    branch === "develop" || branch === "main" || branch === "master";
}

function isRuntimePath(candidate, projectDir) {
  const rel = path.relative(projectDir, candidate);
  // A nested task checkout is project code, not disposable runtime state.
  if (rel === ".claude/worktrees" || rel.startsWith(".claude/worktrees/")) return false;
  return [".claude", ".codex", ".pi", ".prime", "memory"].some(
    (dir) => rel === dir || rel.startsWith(`${dir}/`)
  ) || [".egregore-state.json", ".egregore-branch-consent", ".env"].includes(rel);
}

function protectedProject(candidate, hub) {
  const operation = gitContext(candidate);
  if (!operation || (hub && operation.common !== hub.common)) return null;
  const branch = currentBranch(operation.top);
  if (!isProtectedBranch(branch, operation.top)) return null;
  try {
    if (fs.readFileSync(path.join(operation.top, ".egregore-branch-consent"), "utf8").trim() === branch) return null;
  } catch {}
  return { projectDir: operation.top, branch };
}

function guardedTarget(target, baseDir, hub) {
  const candidate = realish(path.resolve(baseDir, target));
  const project = protectedProject(candidate, hub);
  if (!project || isRuntimePath(candidate, project.projectDir)) return null;
  return project;
}

function normalizeInput(input) {
  const raw = input.tool_input;
  const toolInput = typeof raw === "string" ? { command: raw } : { ...raw };
  toolInput.command = toolInput.command ?? toolInput.cmd ?? toolInput.patch ?? toolInput.input ?? "";
  const toolName = input.tool_name === "exec_command" ? "Bash" : input.tool_name;
  return { ...input, tool_name: toolName, tool_input: toolInput };
}

function extractApplyPatchPaths(command) {
  const paths = [];
  for (const line of String(command || "").split(/\r?\n/)) {
    const match = line.match(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/) || line.match(/^\*\*\* Move to: (.+)$/);
    if (match && match[1]) paths.push(match[1].trim());
  }
  return paths;
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

function withoutHeredocBodies(command) {
  // Script/data bodies are stdin, not shell commands. Keep each opener so
  // its real output redirects still participate in destination checks.
  const pending = [];
  const visible = [];
  let quote = null;
  for (const line of String(command).split("\n")) {
    if (pending.length) {
      const { delimiter, tabs } = pending[0];
      if ((tabs ? line.replace(/^\t+/, "") : line) === delimiter) pending.shift();
      continue;
    }
    visible.push(line);
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (ch === "\\" && quote !== "'") { i++; continue; }
      if (quote) {
        if (ch === quote) quote = null;
        continue;
      }
      if (ch === "'" || ch === '"') { quote = ch; continue; }
      if (line.slice(i, i + 3) === "<<<") { i += 2; continue; }
      if (line.slice(i, i + 2) !== "<<") continue;
      const match = line.slice(i).match(/^<<(-)?[ \t]*(?:'([^']+)'|"([^"]+)"|([^\s;&|<>]+))/);
      if (match) {
        pending.push({ delimiter: match[2] || match[3] || match[4], tabs: Boolean(match[1]) });
        i += match[0].length - 1;
      }
    }
  }
  return visible.join("\n");
}

function shellSegments(command) {
  command = withoutHeredocBodies(command);
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

function filesystemMutationStatus(command, isExemptPath) {
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

    if (!targets.length) unsafe = true;
    for (const target of targets) {
      if (/[$`*?{}]/.test(target) || !isExemptPath(target)) unsafe = true;
    }
  }

  return { unsafe };
}

function redirectLooksMutating(command, isExemptPath) {
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
      if (!isExemptPath(target)) return true;
    }
  }
  return false;
}

function shellLooksMutating(command, projectDir, isExemptPath) {
  if (!command.trim()) return false;
  const visible = stripQuotedSegments(command);

  const mutatingPatterns = [
    /(?:^|[;&|(\n]\s*)(?:sudo\s+)?git(?:\s+-C\s+\S+)?\s+(add|commit|push|rm|mv|reset|restore|checkout\s+--|clean|rebase|merge|cherry-pick)\b/,
    /(?:^|[;&|(\n]\s*)(?:sudo\s+)?apply_patch\b/,
    /(?:^|[;&|(\n]\s*)(?:sudo\s+)?(sed|perl)\b[^;&|]*\s-i(\s|$)/,
    /(?:^|[;&|(\n]\s*)(?:sudo\s+)?(npm|pnpm|yarn|bun)\s+(install|add|remove|update|dedupe|ci)\b/,
    /(?:^|[;&|(\n]\s*)(?:sudo\s+)?(go\s+mod\s+tidy|cargo\s+(fmt|fix|update)|rustfmt|prettier\s+--write|eslint\s+--fix)\b/,
  ];

  const gitCommit = /(?:^|[;&|(\n]\s*)(?:sudo\s+)?git(?:\s+-C\s+\S+)?\s+commit\b/.test(visible);
  const exemptOperation = isBranchSetupCommand(visible) || (gitCommit && stagedOnlyFrameworkPaths(projectDir));
  // Inspect destinations even when the command itself is already classified
  // as a mutation (or exempt). A task-worktree git command can redirect into
  // the protected hub, and that destination must not be short-circuited.
  const filesystem = filesystemMutationStatus(command, isExemptPath);
  const redirects = redirectLooksMutating(command, isExemptPath);
  return filesystem.unsafe || redirects ||
    (!exemptOperation && mutatingPatterns.some((pattern) => pattern.test(visible)));
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

function reasonFor({ projectDir, branch }) {
  const author = currentAuthor(projectDir);
  return [
    `Protected branch (${branch}). Move project work to a task branch before writing.`,
    `If the work topic is clear, run bin/agent.sh branch --topic "<work topic>" automatically (prefix dev/${author}/...), continue in the printed worktree, and briefly tell the user.`,
    "Ask only when the work topic is genuinely ambiguous; ask for the topic, not for routine Git permission.",
    `Only when the user explicitly requested writing on ${branch}, record consent with: echo '${branch}' > .egregore-branch-consent`,
    "Memory, framework-runtime, and managed-repo writes are exempt and should not trigger this guard.",
  ].join("\n");
}

function evaluate(input) {
  commandCache.clear();
  input = normalizeInput(input);
  const { tool_name: toolName, tool_input: toolInput } = input;
  const cwd = input.cwd || process.cwd();
  const baseDir = path.resolve(cwd, toolInput.workdir || toolInput.cwd || ".");
  const hub = gitContext(process.env.EGREGORE_CODEX_PROJECT_DIR || cwd);

  if (toolName === "apply_patch") {
    const targets = extractApplyPatchPaths(toolInput.command);
    // Check every patch target, including rename destinations. The launch
    // checkout and the first file say nothing about the remaining targets.
    for (const target of targets) {
      const project = guardedTarget(target, baseDir, hub);
      if (project) return project;
    }
    return targets.length ? null : protectedProject(baseDir, hub);
  }

  if (toolName === "Edit" || toolName === "Write") {
    const target = toolInput.file_path || toolInput.path;
    return target ? guardedTarget(target, baseDir, hub) : protectedProject(baseDir, hub);
  }

  if (toolName !== "Bash") return null;
  let shellDir = baseDir;
  // Some Codex hosts normalize exec_command to Bash and discard workdir.
  // Their event.cwd is the launch checkout, not evidence of execution cwd.
  // Keep ambiguous relative mutations advisory; concrete destinations still
  // meet the hard guard. Never guess a worktree or redirect a command.
  let cwdKnown = Boolean(toolInput.workdir || toolInput.cwd);
  let advisory = null;
  for (const segment of shellSegments(String(toolInput.command))) {
    const words = shellWords(segment);
    // cd changes subsequent shell operations; git -C changes only that git
    // operation. Never exempt a whole chain because one command is external.
    if (words[0] === "cd" && words.length === 2 && !/[$`*?~]/.test(words[1])) {
      cwdKnown = path.isAbsolute(words[1]) || cwdKnown;
      shellDir = path.resolve(shellDir, words[1]);
      continue;
    }
    let operationDir = shellDir;
    let operationKnown = cwdKnown;
    if (words[0] === "git" && words[1] === "-C" && words[2] && !/[$`*?~]/.test(words[2])) {
      operationDir = path.resolve(shellDir, words[2]);
      operationKnown = path.isAbsolute(words[2]) || cwdKnown;
    }
    const project = protectedProject(operationDir, hub);
    if (project && isConsentCommand(segment, project.branch)) continue;
    let blockedTarget = null;
    const exempt = (target) => {
      const blocked = guardedTarget(target, shellDir, hub);
      if (blocked && (cwdKnown || path.isAbsolute(target))) blockedTarget = blocked;
      return !blocked;
    };
    if (shellLooksMutating(segment, operationDir, exempt)) {
      if (blockedTarget) return blockedTarget;
      if (project && operationKnown) return project;
      if (project) advisory = { ...project, advisory: true };
    }
  }
  return advisory;
}

function main() {
  const project = evaluate(parseJson(readStdin()));
  if (!project) return;
  if (project.advisory) {
    process.stdout.write(JSON.stringify({ hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: "The shell hook did not receive the execution directory, so the launch checkout cannot establish the target branch. Keep project writes in the task workspace. Use absolute destinations or git -C with the task workspace path. If no task workspace exists, run bin/agent.sh branch --topic \"<work topic>\" automatically and continue there.",
    } }));
    return;
  }
  deny(reasonFor(project));
}

module.exports = { evaluate, main };
if (require.main === module) main();
