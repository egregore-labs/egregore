import { isAbsolute, relative, resolve } from "node:path";

const MUTATING_COMMANDS = /(^|[;&|]\s*)(?:sudo\s+)?(rm|mv|cp|mkdir|rmdir|touch|chmod|chown|install|tee)\b/;
const MUTATING_GIT = /(^|[;&|]\s*)(?:sudo\s+)?git\s+(add|commit|push|merge|rebase|cherry-pick|tag|rm|mv)\b/;
const MUTATING_PACKAGES = /(^|[;&|]\s*)(?:sudo\s+)?(npm|pnpm|yarn|bun)\s+(install|add|remove|uninstall|update)\b/;

// A `>` only acts as a shell redirect when it sits OUTSIDE quotes. Quoted
// `>` shows up constantly in read-only commands — Cypher comparisons
// (`WHERE x >= y`), JS/Python formatters (`f"{a} -> {b}"`), jq filters —
// so the redirect test runs on a quote-stripped copy of the command.
// Quoted segments collapse to a placeholder char so a redirect with a
// quoted TARGET (`echo hi > "/tmp/x"`) is still detected.
function stripQuotedSegments(command) {
  let out = "";
  let quote = null;
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote) {
      if (quote === '"' && ch === "\\") i++; // skip escaped char inside double quotes
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; out += "x"; continue; }
    out += ch;
  }
  return out;
}

function maskQuotedOperators(command) {
  let out = "";
  let quote = null;
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote) {
      if (quote === '"' && ch === "\\" && i + 1 < command.length) {
        out += ch + command[++i];
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
  for (let i = 0; i < command.length; i++) {
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
  for (let i = 0; i < segment.length; i++) {
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
    if (ch === "\\" && i + 1 < segment.length) current += segment[++i];
    else current += ch;
  }
  if (current) words.push(current);
  return words;
}

export function isRuntimeStatePath(target, projectDir) {
  if (!target || /[$`*?{}]/.test(target)) return false;
  const absolute = isAbsolute(target) ? resolve(target) : resolve(projectDir, target);
  const rel = relative(resolve(projectDir), absolute);
  if (rel.startsWith("..") || isAbsolute(rel)) return true;
  if (rel === ".claude/worktrees" || rel.startsWith(".claude/worktrees/")) return false;
  return rel === "memory" || rel.startsWith("memory/") ||
    rel === ".claude" || rel.startsWith(".claude/") ||
    rel === ".codex" || rel.startsWith(".codex/") ||
    rel === ".pi" || rel.startsWith(".pi/") ||
    rel === ".egregore-state.json" ||
    rel === ".egregore-branch-consent" ||
    rel === ".env";
}

export function mutatesOnlyRuntimeState(command, projectDir) {
  if (!isMutatingBash(command)) return false;
  const visible = stripQuotedSegments(String(command));
  if (MUTATING_GIT.test(visible) || MUTATING_PACKAGES.test(visible) ||
      /\bsed\s+[^\n]*\s-i(?:\s|$)/.test(visible)) return false;

  let foundTarget = false;
  const pathCommands = new Set(["rm", "mv", "cp", "mkdir", "rmdir", "touch", "chmod", "chown", "install", "tee"]);
  for (const segment of shellSegments(String(command))) {
    const words = shellWords(segment);
    while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0])) words.shift();
    while (words[0] === "sudo" || words[0] === "command" || words[0] === "env") words.shift();
    if (!words.length) continue;
    const name = words.shift().split("/").pop();
    if (!pathCommands.has(name)) continue;

    const args = words.filter((word) => !word.startsWith("-"));
    let targets = args;
    if (name === "cp" || name === "install") targets = args.length ? [args[args.length - 1]] : [];
    if (name === "chmod" || name === "chown") targets = args.slice(1);
    if (!targets.length || targets.some((target) => !isRuntimeStatePath(target, projectDir))) return false;
    foundTarget = true;
  }

  const redirectSource = maskQuotedOperators(String(command));
  const redirects = /(?:^|[\s;|&])(?:\d*)>>?\s*([^&\s;|]+)/g;
  let redirect;
  while ((redirect = redirects.exec(redirectSource))) {
    const target = String(redirect[1] || "").replace(/^["']|["']$/g, "");
    if (!target || target === "/dev/null") continue;
    if (!isRuntimeStatePath(target, projectDir)) return false;
    foundTarget = true;
  }

  const tees = /\|\s*tee\s+(?:-a\s+)?([^&\s;|]+)/g;
  let tee;
  while ((tee = tees.exec(redirectSource))) {
    const target = String(tee[1] || "").replace(/^["']|["']$/g, "");
    if (!isRuntimeStatePath(target, projectDir)) return false;
    foundTarget = true;
  }

  return foundTarget;
}

export function isMutatingBash(command) {
  if (!command) return false;
  const meaningfulRedirects = stripQuotedSegments(String(command))
    .replace(/(?:^|\s)\d*>>?\s*\/dev\/null\b/g, " ")
    .replace(/(?:^|\s)\d*>\s*&\d+\b/g, " ");
  return MUTATING_COMMANDS.test(command) ||
    MUTATING_GIT.test(command) ||
    MUTATING_PACKAGES.test(command) ||
    /(^|[^<])>>?\s*[^&]/.test(meaningfulRedirects) ||
    /\bsed\s+[^\n]*\s-i(?:\s|$)/.test(command);
}
