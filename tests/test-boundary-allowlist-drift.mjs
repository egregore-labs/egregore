#!/usr/bin/env node
// Agent instructions are the inventory, not scripts' private state variables.
// Scan tracked runtime instructions; in bin/, inspect only emitted literals.
// Registry access is a separate read-only exception, never a family.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(import.meta.url);
const { EGREGORE_ALLOWED_FAMILIES } = require(path.join(ROOT, "bin/boundary-guard.cjs"));

// Each { file, family, line, reason } exempts one otherwise-unlisted occurrence.
// Allowed-family descriptions need no exemptions. Exact source lines are kept
// before quote normalization. Repeating an exempt line consumes a second
// occurrence; adjacent operational instructions never inherit its exemption.
const EXEMPTIONS = [];
const INVENTORY_ROOTS = [".claude", ".codex", ".pi", ".prime", "CLAUDE.md", "AGENTS.md", "bin"];
const familyPattern = /(?:~|\$HOME|\$\{HOME\})\/\.egregore\/([^\s/`'"\\),;\]}]+)/g;
const matchesFamily = (pattern, family) => pattern.endsWith("*")
  ? family.startsWith(pattern.slice(0, -1)) : family === pattern;

// Join adjacent shell-quoted fragments without inserting spaces. Preserve
// source offsets so exemptions still bind to the original, unmodified line.
function normalizedLiteral(text, start = 0, end = text.length) {
  let literal = "";
  const offsets = [];
  for (let i = start; i < end; i++) {
    if (text[i] === "\\" && /[\r\n]/.test(text[i + 1] || "")) {
      if (text[i + 1] === "\r" && text[i + 2] === "\n") i++;
      i++;
      continue;
    }
    if (text[i] === "\\" && /['"]/.test(text[i + 1] || "")) { i++; continue; }
    if (/['"]/.test(text[i])) continue;
    literal += text[i];
    offsets.push(i);
  }
  return { literal, offsets };
}

function occurrences(file, text, spans = [[0, text.length]]) {
  const rows = [];
  const lines = text.split(/\r?\n/);
  const lineStarts = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === "\n") lineStarts.push(i + 1);
  for (const [start, end] of spans) {
    const { literal, offsets } = normalizedLiteral(text, start, end);
    for (const match of literal.matchAll(familyPattern)) {
      const family = match[1];
      if (family === "instances.json") continue;
      let low = 0;
      let high = lineStarts.length;
      while (low + 1 < high) {
        const middle = Math.floor((low + high) / 2);
        if (lineStarts[middle] <= offsets[match.index]) low = middle;
        else high = middle;
      }
      rows.push({ file, line: lines[low], lineNumber: low + 1, family });
    }
  }
  return rows;
}

// Mask comments and quoted literals when locating output statements. Retain
// original spans for emitted strings, including multiline strings. Never
// evaluate scripts or follow data flow from their private state variables.
function sourceTokens(text) {
  const mask = text.split("");
  const strings = [];
  const hide = (start, end) => {
    for (let i = start; i < end; i++) if (text[i] !== "\n") mask[i] = " ";
  };
  for (let i = 0; i < text.length;) {
    const start = i;
    if (text[i] === "#" || text.slice(i, i + 2) === "//") {
      while (i < text.length && text[i] !== "\n") i++;
      hide(start, i);
    } else if (text.slice(i, i + 2) === "/*") {
      const close = text.indexOf("*/", i + 2);
      i = close < 0 ? text.length : close + 2;
      hide(start, i);
    } else if ('"\'`'.includes(text[i])) {
      const quote = text[i++];
      while (i < text.length) {
        if (text[i] === "\\" && quote !== "'") i += 2;
        else if (text[i++] === quote) break;
      }
      i = Math.min(i, text.length);
      strings.push([start, i]);
      hide(start, i);
    } else if (text[i] === "\\") i += 2;
    else i++;
  }
  // Quoted object keys are code too: { "message": "..." } has the same
  // output semantics as { message: "..." }.
  for (const [start, end] of strings) {
    if (/^['"]message['"]$/.test(text.slice(start, end)) && /^\s*:/.test(text.slice(end))) {
      for (let i = start + 1; i < end - 1; i++) mask[i] = text[i];
    }
  }
  return { mask: mask.join(""), strings };
}

function shellCommandEnd(text, start) {
  let quote = "";
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (c === "\\" && quote !== "'") { i++; continue; }
    if (quote) { if (c === quote) quote = ""; continue; }
    if ('"\'`'.includes(c)) { quote = c; continue; }
    if (/[\n;|)]/.test(c) || (c === "&" && !/[<>]/.test(text[i - 1] || "") && text[i + 1] !== ">")) return i;
    if (c === "#" && /\s/.test(text[i - 1] || " ")) return i;
  }
  return text.length;
}

function shellWords(text, start, end) {
  const words = [];
  for (let i = start; i < end;) {
    if (/\s/.test(text[i])) { i++; continue; }
    if (text[i] === "\\" && text[i + 1] === "\n") { i += 2; continue; }
    const redirection = text.slice(i, end).match(/^(?:\d*(?:<<-?|[<>]&|>>?|<)|&>>?)/);
    if (redirection) {
      words.push({ operator: redirection[0], start: i, end: i + redirection[0].length });
      i += redirection[0].length;
      continue;
    }
    const begin = i;
    let quote = "";
    for (; i < end; i++) {
      const c = text[i];
      if (c === "\\" && quote !== "'") { i++; continue; }
      if (quote) { if (c === quote) quote = ""; continue; }
      if ('"\'`'.includes(c)) { quote = c; continue; }
      if (/\s|[<>]/.test(c)) break;
    }
    words.push({ start: begin, end: i });
  }
  return words;
}

function shellOutput(text, start, end, command) {
  const words = shellWords(text, start, end);
  const spans = [];
  const heredocs = [];
  // Descriptor duplication snapshots the destination at that point. Thus
  // `2>file >&2` writes to a file, while `>&2 2>file` still prints on the
  // original stderr. Do not let redirection ordering manufacture evidence.
  const descriptors = new Map([[1, "stdout"], [2, "stderr"]]);
  const destination = (value) => {
    if (value === "/dev/stdout") return descriptors.get(1);
    if (value === "/dev/stderr") return descriptors.get(2);
    const descriptor = value.match(/^\/dev\/fd\/(\d+)$/);
    return descriptor ? descriptors.get(Number(descriptor[1])) : "file";
  };
  for (let i = 0; i < words.length; i++) {
    const word = words[i];
    if (!word.operator) { if (command !== "cat") spans.push([word.start, word.end]); continue; }
    const operand = words[++i];
    if (!operand || operand.operator) continue;
    const value = normalizedLiteral(text, operand.start, operand.end).literal;
    const op = word.operator;
    if (/^(?:0)?<<-?$/.test(op)) heredocs.push({ delimiter: value, tabs: op.endsWith("-") });
    const fileRedirect = op.match(/^(\d*)>>?$/);
    const duplicate = op.match(/^(\d*)>&$/);
    if (fileRedirect) descriptors.set(Number(fileRedirect[1] || 1), destination(value));
    else if (/^&>>?$/.test(op)) {
      const target = destination(value);
      descriptors.set(1, target);
      descriptors.set(2, target);
    } else if (duplicate) {
      descriptors.set(Number(duplicate[1] || 1), /^\d+$/.test(value) ? descriptors.get(Number(value)) : "file");
    }
  }
  let after = end;
  const bodies = [];
  if (heredocs.length) {
    // Bodies begin after the complete command line, even for a pipeline.
    const newline = text.indexOf("\n", end);
    after = newline < 0 ? text.length : newline + 1;
    for (const { delimiter, tabs } of heredocs) {
      const begin = after;
      while (after < text.length) {
        const newlineAt = text.indexOf("\n", after);
        const lineEnd = newlineAt < 0 ? text.length : newlineAt;
        const line = text.slice(after, lineEnd).replace(/\r$/, "");
        if ((tabs ? line.replace(/^\t+/, "") : line) === delimiter) {
          bodies.push([begin, after]);
          after = newlineAt < 0 ? text.length : newlineAt + 1;
          break;
        }
        after = newlineAt < 0 ? text.length : newlineAt + 1;
      }
    }
  }
  let storesPrintf = false;
  if (command === "printf") {
    // -v assigns to a shell variable instead of printing. Inspect only the
    // leading options: a later argument containing -v is ordinary output.
    for (const [begin, finish] of spans) {
      const argument = normalizedLiteral(text, begin, finish).literal;
      if (argument === "--" || !argument.startsWith("-") || argument === "-") break;
      if (/^-[A-Za-z]*v/.test(argument)) { storesPrintf = true; break; }
    }
  }
  const visible = !storesPrintf && ["stdout", "stderr"].includes(descriptors.get(1));
  return { spans: visible ? (command === "cat" ? bodies : spans) : [], after };
}

function expressionEnd(mask, start, argumentList) {
  const closing = { "(": ")", "[": "]", "{": "}" };
  const stack = argumentList ? [")"] : [];
  for (let i = start; i < mask.length; i++) {
    const c = mask[i];
    if (closing[c]) stack.push(closing[c]);
    else if (")]}".includes(c)) {
      if (!stack.length || stack.pop() !== c) return i;
      if (argumentList && !stack.length) return i;
    } else if (!stack.length && /[,;]/.test(c)) return i;
  }
  return mask.length;
}

function printedSpans(text) {
  const { mask, strings } = sourceTokens(text);
  const spans = [];
  const sinks = /\b(echo|printf|cat)\b|\b(?:process\.|sys\.)?stderr\.write\s*\(|\bmessage\s*:/g;
  for (let hit; (hit = sinks.exec(mask));) {
    const start = hit.index + hit[0].length;
    if (hit[1]) {
      const end = shellCommandEnd(text, start);
      const output = shellOutput(text, start, end, hit[1]);
      spans.push(...output.spans);
      // Never reinterpret a file-directed cat heredoc's generated contents
      // as output statements, even when that file contains echo commands.
      sinks.lastIndex = Math.max(end, output.after);
      if (output.after > end) {
        // Heredoc prose is not source syntax. An unmatched quote in its body
        // must not hide subsequent statements in the lexical mask.
        spans.push(...printedSpans(text.slice(output.after)).map(([begin, finish]) => [begin + output.after, finish + output.after]));
        return spans;
      }
      continue;
    }
    // Inspect every literal in the value/argument expression, including
    // concatenation and nested calls. Stop before a sibling field or the
    // enclosing delimiter; strings after the sink are not emitted evidence.
    const end = expressionEnd(mask, start, !hit[0].endsWith(":"));
    spans.push(...strings.filter(([begin, finish]) => begin >= start && finish <= end));
    sinks.lastIndex = end;
  }
  return spans;
}

function audit(rows, allowed, exemptions, requireEvidence = true) {
  const errors = [];
  const consumed = new Set();
  for (const row of rows) {
    if (allowed.some((pattern) => matchesFamily(pattern, row.family))) continue;
    const exemption = exemptions.findIndex((e, i) => !consumed.has(i)
      && e.file === row.file && e.family === row.family && e.line === row.line);
    if (exemption >= 0) { consumed.add(exemption); continue; }
    errors.push(`${row.file}:${row.lineNumber}: unlisted family ${row.family}: ${row.line}`);
  }
  exemptions.forEach((entry, i) => {
    if (!entry.reason || !consumed.has(i)) errors.push(`stale or unexplained exemption: ${entry.file}: ${entry.line}`);
  });
  if (requireEvidence) {
    for (const family of allowed) {
      if (!rows.some((row) => matchesFamily(family, row.family))) errors.push(`unused allow-list family: ${family}`);
    }
  }
  return errors;
}

function trackedFiles(root = ROOT, run = spawnSync) {
  const result = run("git", ["ls-files", "-z", "--", ...INVENTORY_ROOTS], { cwd: root });
  assert(!result.error, `cannot inventory tracked instructions: git ls-files failed: ${result.error?.message}`);
  assert.equal(result.status, 0, `cannot inventory tracked instructions: git ls-files exited ${result.status}: ${String(result.stderr || "").trim()}`);
  return String(result.stdout).split("\0").filter(Boolean);
}

function inventory(root = ROOT, run = spawnSync) {
  const rows = [];
  for (const file of trackedFiles(root, run)) {
    if (file === "bin/boundary-guard.cjs" || /(?:^|\/)test-boundary[^/]*\.[^/]+$/.test(file)) continue;
    let absolute = root;
    for (const component of file.split("/")) {
      absolute = path.join(absolute, component);
      assert(!fs.lstatSync(absolute).isSymbolicLink(), `tracked inventory symlink requires an explicit decision: ${file}`);
    }
    const stat = fs.lstatSync(absolute);
    assert(stat.isFile(), `tracked inventory entry is not a regular file: ${file}`);
    const text = fs.readFileSync(absolute, "utf8");
    rows.push(...occurrences(file, text, file.startsWith("bin/") ? printedSpans(text) : undefined));
  }
  return rows;
}

function selfTest() {
  const file = ".claude/fixture.md";
  const description = "Internal storage lives at ~/.egregore/runtime/observe.";
  const exemption = [{ file, family: "runtime", line: description, reason: "Internal storage description." }];
  const check = (text) => audit(occurrences(file, text), [], exemption, false);
  assert.deepEqual(check(description), []);
  assert.match(check(`${description}\nRead ~/.egregore/runtime/observe now.`)[0], /:2: unlisted family runtime/);
  assert.equal(check(`${description}\n${description}`).length, 1, "one exemption cannot cover a duplicated line");
  assert.match(check(`${description}\n${description}`)[0], /:2: unlisted family runtime/);
  const twice = "Internal ~/.egregore/runtime/a and ~/.egregore/runtime/b";
  assert.equal(audit(occurrences(file, twice), [], [{ ...exemption[0], line: twice }], false).length, 1,
    "one exemption cannot cover two occurrences on one line");
  assert.match(check("")[0], /stale/);
  assert.match(audit(occurrences(file, description), ["runtime"], exemption, false)[0], /stale/,
    "allowed families must not carry redundant exemptions");
  assert.match(audit([], ["unused"], [], true)[0], /unused/);
  assert.deepEqual(occurrences(file, '"$HOME"/.egregore/instances.json'), [], "registry is not a family");
  for (const text of [
    'cat "${HOME}"/.egregore/runtime/x',
    'cat "$HOME"/.egregore/"runtime"/x',
    "cat '~'/.egregore/'runtime'/x",
    'cat "${HOME}/.egregore/runtime/x"',
    'cat "$HOME"/.egregore/\\\nruntime/x',
  ]) {
    assert.equal(occurrences(file, text)[0]?.family, "runtime", `quoted path: ${text}`);
    assert.equal(occurrences(file, text)[0]?.line, text.split("\n")[0], "retain the exact original line");
  }
  const printed = (text) => occurrences("bin/fixture.sh", text, printedSpans(text));
  const families = (text) => printed(text).map((row) => row.family);
  const source = [
    '# echo "Read ~/.egregore/commented/x"',
    'STATE="$HOME/.egregore/runtime/private"',
    'echo "Read ~/.egregore/reports/a"',
    'printf "%s\\n" "Read $HOME/.egregore/platform/a"',
    'echo "saved" > "$HOME/.egregore/runtime/private"',
    'process.stderr.write("Read ~/.egregore/context/x\\n");',
    'message: `Read',
    '${HOME}/.egregore/exports/a`,',
  ].join("\n");
  assert.deepEqual(families(source), ["reports", "platform", "context", "exports"]);
  assert.deepEqual(families('process.stderr.write(\n  "Read ~/.egregore/runtime/x"\n);'), ["runtime"]);
  assert.deepEqual(families('sys.stderr.write(\n  "Read ~/.egregore/runtime/x"\n)'), ["runtime"]);
  assert.deepEqual(families('message:\n  "Read ~/.egregore/runtime/x",'), ["runtime"]);
  assert.deepEqual(families('"message":\n  "Read ~/.egregore/runtime/x",'), ["runtime"]);
  assert.deepEqual(families("message: 'Recovery: ' + 'Read ~/.egregore/runtime/state'"), ["runtime"]);
  assert.deepEqual(families([
    "const result = { message: 'Recovery: ' + format({ parts: [",
    "  'Read ~/.egregore/runtime/state', wrap(')},; Read ~/.egregore/mind/state')",
    "] }).text, internal: 'Read ~/.egregore/secret-state/unused' };",
    "const after = 'Read ~/.egregore/also-unused/state';",
  ].join("\n")), ["runtime", "mind"], "message expressions stop at their depth-zero delimiter");
  assert.deepEqual(families("const result = { message: ('Read ~/.egregore/runtime/state') }; const after = 'Read ~/.egregore/unused/state';"),
    ["runtime"], "closing the message object must not capture a later literal");
  assert.deepEqual(families([
    "process.stderr.write(format({ parts: ['Read ~/.egregore/runtime/state',",
    "  join(')},; Read ~/.egregore/mind/state')] }), 'Read ~/.egregore/reports/state');",
    "const after = 'Read ~/.egregore/unused/state';",
  ].join("\n")), ["runtime", "mind", "reports"], "stderr arguments include nested literals but stop at the closing call");
  for (const options of ["-v var", "-q -v var", "-qv var", "-vvar", "-q \\\n  -v var"]) {
    assert.deepEqual(families(`printf ${options} '%s' "$HOME/.egregore/runtime/state"\necho 'Read ~/.egregore/reports/state'`),
      ["reports"], `printf variable assignment is not emitted text: ${options}`);
  }
  assert.deepEqual(families("printf '%s' '-v' 'Read ~/.egregore/runtime/state'"), ["runtime"],
    "-v after the format is an output argument");
  assert.deepEqual(families("printf -- '-v %s' 'Read ~/.egregore/runtime/state'"), ["runtime"],
    "-- ends printf option processing");
  assert.deepEqual(families('printf "%s\\n" \\\n  "Read "$HOME"/.egregore/runtime/x" \\\n  "Read ~/.egregore/mind/x"'), ["runtime", "mind"]);
  assert.deepEqual(families('echo "Read \'~\'/.egregore/runtime/x"'), ["runtime"]);
  assert.deepEqual(families('process.stderr.write(\n  \'cat "${HOME}"/.egregore/runtime/x\'\n);'), ["runtime"]);
  for (const header of ["cat <<EOF", "cat >&2 <<'EOF'", 'cat <<"EOF" 1>&2', "cat <<EOF 2>/tmp/errors"]) {
    assert.deepEqual(families(`${header}\nRead "$HOME"/.egregore/runtime/x\nEOF\n`), ["runtime"], header);
  }
  for (const header of ["cat >&2 2>file <<EOF", "cat 1>&2 2>>file <<EOF"]) {
    assert.deepEqual(families(`${header}\nRead ~/.egregore/runtime/x\nEOF\n`), ["runtime"],
      `duplicated original stderr stays visible: ${header}`);
  }
  assert.deepEqual(families("cat <<-EOF\n\tRead ~/.egregore/runtime/x\n\tEOF\n"), ["runtime"]);
  assert.deepEqual(families("cat <<EOF\nDon't change this description.\nEOF\necho 'Read ~/.egregore/runtime/x'"), ["runtime"],
    "heredoc prose quotes must not hide later output statements");
  for (const header of ["cat <<EOF > file", "cat > file <<'EOF'", "cat <<EOF 1>file", "cat <<EOF &>file",
    "cat 2>file >&2 <<EOF", "cat 2>>file 1>&2 <<EOF", "cat 3>file 1>&3 <<EOF"]) {
    assert.deepEqual(families(`${header}\necho 'Read ~/.egregore/runtime/x'\nEOF\necho 'Read ~/.egregore/reports/x'`),
      ["reports"], `file-directed heredoc must not leak instructions: ${header}`);
  }
  assert.equal(audit(printed('echo \'cat "${HOME}"/.egregore/runtime/x\''), [], [], false).length, 1);
  assert.equal(matchesFamily("loom*", "loom-escalation-test.json"), true);
  assert.equal(matchesFamily("reports", "reports-private"), false);

  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), "egregore-allowlist-drift-"));
  try {
    fs.mkdirSync(path.join(fixture, ".claude"));
    fs.writeFileSync(path.join(fixture, ".claude/tracked.md"), "Read ~/.egregore/reports/x");
    fs.writeFileSync(path.join(fixture, ".claude/untracked.md"), "Read ~/.egregore/runtime/x");
    fs.symlinkSync("missing-external-target", path.join(fixture, ".claude/untracked-link"));
    fs.symlinkSync("missing-external-directory", path.join(fixture, ".claude/linked-directory"));
    const run = (command, args, options) => {
      assert.equal(command, "git");
      assert.deepEqual(args, ["ls-files", "-z", "--", ...INVENTORY_ROOTS]);
      assert.deepEqual(options, { cwd: fixture }, "inventory must invoke git directly without a shell");
      return { status: 0, stdout: Buffer.from(".claude/tracked.md\0"), stderr: Buffer.alloc(0) };
    };
    assert.deepEqual(inventory(fixture, run).map((row) => row.family), ["reports"], "untracked files and symlinks are outside inventory");
    assert.throws(() => inventory(fixture, () => ({ status: 0, stdout: ".claude/untracked-link\0" })), /tracked inventory symlink/);
    assert.throws(() => inventory(fixture, () => ({ status: 0, stdout: ".claude/linked-directory/child.md\0" })), /tracked inventory symlink/);
    assert.throws(() => trackedFiles(fixture, () => ({ error: new Error("ENOENT git"), status: null })), /git ls-files failed.*ENOENT/);
    assert.throws(() => trackedFiles(fixture, () => ({ status: 128, stderr: "not a git repository" })), /git ls-files exited 128.*not a git repository/);
  } finally {
    fs.rmSync(fixture, { recursive: true, force: true });
  }
}

selfTest();
assert(Array.isArray(EGREGORE_ALLOWED_FAMILIES), "guard must export EGREGORE_ALLOWED_FAMILIES");
assert.equal(new Set(EGREGORE_ALLOWED_FAMILIES).size, EGREGORE_ALLOWED_FAMILIES.length, "duplicate allow-list family");
const rows = inventory();
const errors = audit(rows, EGREGORE_ALLOWED_FAMILIES, EXEMPTIONS);
if (errors.length) {
  console.error(errors.join("\n"));
  console.error(`FAIL: boundary allow-list drift (${errors.length} errors)`);
  process.exitCode = 1;
} else {
  console.log(`PASS: boundary allow-list drift (${EGREGORE_ALLOWED_FAMILIES.length} families, ${rows.length} mentions, ${EXEMPTIONS.length} exact-occurrence exemptions; self-tests passed)`);
}
