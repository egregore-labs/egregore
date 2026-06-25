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

function findProjectDir(input) {
  // Tool payload cwd is the operation location. Codex launchers may keep
  // EGREGORE_CODEX_PROJECT_DIR pointed at the main checkout even after the
  // model continues in a task worktree, so using the env var first can make
  // legitimate worktree writes look like writes on protected develop.
  const cwd = input.cwd || process.cwd() || process.env.EGREGORE_CODEX_PROJECT_DIR;
  const top = run("git", ["-C", cwd, "rev-parse", "--show-toplevel"], cwd);
  if (top) return realish(top);

  const envDir = process.env.EGREGORE_CODEX_PROJECT_DIR || "";
  if (envDir) {
    const envTop = run("git", ["-C", envDir, "rev-parse", "--show-toplevel"], envDir);
    return realish(envTop || envDir);
  }

  return realish(cwd);
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

  for (const file of [".egregore-state.json", ".env"]) {
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
  return (
    /\bbin\/agent\.sh\s+branch\b/.test(command) ||
    /\bgit\s+(checkout|switch)\s+(-b|-c)\b/.test(command) ||
    /\bgit\s+branch\s+(dev|feature|bugfix)\//.test(command) ||
    /\bgit\s+worktree\s+add\b/.test(command) ||
    /\bbin\/worktree\.sh\s+setup\b/.test(command)
  );
}

function stagedOnlyFrameworkPaths(projectDir) {
  const files = run("git", ["-C", projectDir, "diff", "--cached", "--name-only"], projectDir)
    .split(/\r?\n/)
    .filter(Boolean);
  return files.length > 0 && files.every((file) => /^(bin\/|\.claude\/|\.codex\/|CLAUDE\.md$|AGENTS\.md$|skills\/)/.test(file));
}

function redirectLooksMutating(command, projectDir, memoryDir) {
  const redirectPatterns = [
    /(?:^|[\s;|&])(?:\d*)>>?\s*([^&\s;|]+)/g,
    /\|\s*tee\s+(?:-a\s+)?([^&\s;|]+)/g,
  ];

  for (const pattern of redirectPatterns) {
    let match;
    while ((match = pattern.exec(command))) {
      const target = String(match[1] || "").replace(/^["']|["']$/g, "");
      if (!target || target === "/dev/null" || target.startsWith("$")) continue;
      if (!isExemptPath(target, projectDir, memoryDir)) return true;
    }
  }
  return false;
}

function shellLooksMutating(command, projectDir, memoryDir) {
  if (!command.trim()) return false;
  if (isBranchSetupCommand(command)) return false;

  const mutatingPatterns = [
    /\bgit\s+(add|commit|push|rm|mv|reset|restore|checkout\s+--|clean|rebase|merge|cherry-pick)\b/,
    /\b(apply_patch|touch|mkdir|rm|mv|cp|chmod|chown|ln)\b/,
    /\b(sed|perl)\b[^;&|]*\s-i(\s|$)/,
    /\b(npm|pnpm|yarn|bun)\s+(install|add|remove|update|dedupe|ci)\b/,
    /\b(go\s+mod\s+tidy|cargo\s+(fmt|fix|update)|rustfmt|prettier\s+--write|eslint\s+--fix)\b/,
  ];

  if (/\bgit\s+commit\b/.test(command) && stagedOnlyFrameworkPaths(projectDir)) return false;
  return mutatingPatterns.some((pattern) => pattern.test(command)) || redirectLooksMutating(command, projectDir, memoryDir);
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
  const projectDir = findProjectDir(input);
  const branch = currentBranch(projectDir);
  if (!isProtectedBranch(branch)) return;

  const toolName = input.tool_name || "";
  const toolInput = input.tool_input || {};
  const memoryDir = realish(path.join(projectDir, "memory"));
  const author = currentAuthor(projectDir);
  const reason = [
    `Protected branch (${branch}).`,
    "Create an Egregore work branch before writing:",
    `  bin/agent.sh branch --topic "<work topic>"`,
    "Then continue from the printed worktree: path.",
    `Default branch prefix for this user: dev/${author}/...`,
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
    if (commandTargetsOtherRepo(command, projectDir, memoryDir)) return;
    if (shellLooksMutating(command, projectDir, memoryDir)) deny(reason);
  }
}

main();
