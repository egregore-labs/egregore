import { isAbsolute, relative, resolve } from "node:path";

const MUTATING_COMMANDS = /(^|[;&|]\s*)(?:sudo\s+)?(rm|mv|cp|mkdir|rmdir|touch|chmod|chown|install|tee)\b/;
// Global options (-C <path>, -c k=v, --git-dir=…) may sit between `git` and
// the subcommand. The repo convention actively teaches `git -C <abs-path>`,
// so a classifier that only matches bare `git commit` misses the shape the
// model is most likely to emit.
const MUTATING_GIT = /(^|[;&|]\s*)(?:sudo\s+)?git\s+(?:(?:-C|-c|--git-dir|--work-tree)(?:=\S+|\s+\S+)\s+)*(add|commit|push|merge|rebase|cherry-pick|tag|rm|mv|reset|restore|clean)\b/;
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
    rel === ".prime" || rel.startsWith(".prime/") ||
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

// The documented escape hatch must itself be runnable, but ONLY as the whole
// command: an unanchored match lets `git push origin develop && echo 'develop'
// > .egregore-branch-consent` pass the gate in one call, and the block message
// teaches that exact echo string. Canonical form mirrors
// .codex/hooks/branch-guard.js isConsentCommand — anchored, branch escaped,
// optional ./ prefix — and is shared so the three runtimes cannot drift.
export function isConsentCommand(command, branch) {
  if (!branch) return false;
  const escaped = String(branch).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(
    `^\\s*echo\\s+['"]?${escaped}['"]?\\s*>\\s*(?:\\./)?\\.egregore-branch-consent\\s*$`
  ).test(String(command || ""));
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

// ---- IPython code classification (Prime Agent) -----------------------------
// Prime Agent's default tool surface is a persistent IPython kernel: file
// writes and shell escapes arrive as Python code, not bash tool calls. This
// classifier is deliberately static and therefore porous (exec/eval and
// string-built commands pass); the generated runtime spec carries the
// standing-instruction discipline as the backstop, and the adversarial test
// fixtures pin what this actually catches.

// Strip Python string literals so call-name detection ignores docstrings and
// string content. Triple quotes first, then single-line quotes; f-string
// prefixes fall out naturally because only the quoted part is replaced.
function stripPythonStrings(code) {
  return String(code)
    .replace(/[rbuf]{0,2}("""|''')[\s\S]*?\1/gi, '""')
    .replace(/[rbuf]{0,2}"(?:\\.|[^"\\\n])*"/gi, '""')
    .replace(/[rbuf]{0,2}'(?:\\.|[^'\\\n])*'/gi, "''");
}

function pythonShellCommands(code) {
  const shell = [];
  const lines = String(code).split("\n");
  const first = (lines[0] || "").trim();
  if (/^%%(bash|sh|script\s+(ba)?sh)\b/.test(first)) {
    shell.push(lines.slice(1).join("\n"));
    return { shell, rest: "" };
  }
  if (/^%%writefile\b/.test(first)) {
    const target = first.replace(/^%%writefile\s+(-a\s+)?/, "").trim();
    return { shell: [`tee ${target || "unknown-target"}`], rest: "" };
  }
  const rest = [];
  for (const line of lines) {
    const bang = line.match(/^\s*!(.+)$/);
    const sysMagic = line.match(/^\s*%(?:system|sx)\s+(.+)$/);
    if (bang) shell.push(bang[1]);
    else if (sysMagic) shell.push(sysMagic[1]);
    else rest.push(line);
  }
  return { shell, rest: rest.join("\n") };
}

const PY_MUTATING_CALLS =
  /\b(?:os\.(?:remove|unlink|rename|replace|rmdir|removedirs|makedirs|mkdir|symlink|link|chmod|chown|truncate)|shutil\.(?:copy|copy2|copyfile|copytree|move|rmtree|make_archive|unpack_archive))\s*\(/;
const PY_WRITE_METHODS = /\.\s*(?:write_text|write_bytes|unlink|touch|mkdir|rmdir|hardlink_to|symlink_to)\s*\(/;
const PY_OPEN_WRITE =
  /\bopen\s*\(\s*[^,]+,\s*(?:mode\s*=\s*)?['"](?:[wax]|r\+)[rwxab+]*['"]/;
const PY_OPEN_MODE_KWARG = /\bopen\s*\([^)]*mode\s*=\s*['"](?:[wax]|r\+)[rwxab+]*['"]/;

function pythonSubprocessArgv(code) {
  const argvs = [];
  const calls =
    /\b(?:subprocess\.(?:run|call|check_call|check_output|Popen)|os\.system|os\.popen)\s*\(\s*(\[[^\]]*\]|[rbuf]{0,2}["'](?:\\.|[^"'\\\n])*["'])/g;
  let match;
  while ((match = calls.exec(String(code)))) {
    const arg = match[1];
    if (arg.startsWith("[")) {
      const words = [...arg.matchAll(/["']((?:\\.|[^"'\\])*)["']/g)].map((m) => m[1]);
      if (words.length) argvs.push(words.join(" "));
    } else {
      argvs.push(arg.replace(/^[rbuf]{0,2}["']/i, "").replace(/["']$/, ""));
    }
  }
  return argvs;
}

// Classify IPython cell code. Returns true when the code statically performs a
// repo mutation that should meet the protected-branch gate. Mutations that
// target only Egregore runtime state (memory/, dot-dirs, consent files) are
// exempt when the target is statically extractable, mirroring
// mutatesOnlyRuntimeState for bash.
export function isMutatingIpython(code, projectDir) {
  if (!code) return false;
  const { shell, rest } = pythonShellCommands(code);
  for (const cmd of shell) {
    if (isMutatingBash(cmd) && !(projectDir && mutatesOnlyRuntimeState(cmd, projectDir))) return true;
  }
  if (!rest) return false;

  for (const argv of pythonSubprocessArgv(rest)) {
    if (isMutatingBash(argv) && !(projectDir && mutatesOnlyRuntimeState(argv, projectDir))) return true;
  }

  const stripped = stripPythonStrings(rest);
  if (PY_MUTATING_CALLS.test(stripped) || PY_WRITE_METHODS.test(stripped)) {
    // Exempt when every extractable string target is runtime state. The
    // mutated location differs by call: copy/move/rename mutate their LAST
    // argument (the destination); remove/rmtree/mkdir mutate their first.
    if (projectDir) {
      const DEST_LAST = /^(?:copy|copy2|copyfile|copytree|move|rename|replace|symlink|link)$/;
      const targets = [...String(rest).matchAll(
        /\b(?:os|shutil)\.(\w+)\s*\(([^)]*)\)/g
      )].flatMap((m) => {
        const args = [...m[2].matchAll(/["']((?:\\.|[^"'\\])*)["']/g)].map((s) => s[1]);
        if (!args.length) return [];
        return [DEST_LAST.test(m[1]) ? args[args.length - 1] : args[0]];
      });
      const pathTargets = [...String(rest).matchAll(
        /Path\s*\(\s*[rbuf]{0,2}["']((?:\\.|[^"'\\\n])*)["']\s*\)\s*\.\s*(?:write_text|write_bytes|unlink|touch|mkdir|rmdir)/g
      )].map((m) => m[1]);
      const all = [...targets, ...pathTargets];
      if (all.length && all.every((t) => isRuntimeStatePath(t, projectDir))) return false;
    }
    return true;
  }

  if (PY_OPEN_WRITE.test(rest) || PY_OPEN_MODE_KWARG.test(rest)) {
    if (projectDir) {
      const openTargets = [...String(rest).matchAll(
        /\bopen\s*\(\s*[rbuf]{0,2}["']((?:\\.|[^"'\\\n])*)["']\s*,\s*(?:mode\s*=\s*)?["'](?:[wax]|r\+)/g
      )].map((m) => m[1]);
      if (openTargets.length && openTargets.every((t) => isRuntimeStatePath(t, projectDir))) return false;
    }
    return true;
  }

  return false;
}
