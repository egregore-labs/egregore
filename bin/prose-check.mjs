#!/usr/bin/env node
// Prose rule checker. Contract: docs/specs/prose-rule-v1.md
//
//   prose-check.mjs validate [--rules-dir DIR]
//   prose-check.mjs check --surface <s> [--tier mechanical] [--format text|json|github] [--advisory] <file>... | -
//   prose-check.mjs compose --surface <s> [--tier mechanical|judgment]
//   prose-check.mjs report --surface <s> [--meta key=value ...] <file>...
//   prose-check.mjs list
//
// One rule per file in bin/prose-rules/. A rule's own Fails and Passes
// examples are its test: `validate` runs them through the rule's patterns
// after the same preprocessing `check` applies to a document.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_RULES_DIR = path.join(HERE, "prose-rules");

const SURFACES = ["git", "memory", "harness", "product", "external", "outreach", "character"];
const TIERS = ["mechanical", "judgment"];
const SEVERITIES = ["block", "warn"];
const POSITIONS = ["opening"];
const BODY_WORD_LIMIT = 130;

// ---------------------------------------------------------------- parsing

function unquote(raw) {
  const s = raw.trim();
  if (s.length >= 2 && s.startsWith("'") && s.endsWith("'")) {
    return s.slice(1, -1).replace(/''/g, "'");
  }
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    return s.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  }
  return s;
}

function parseInlineList(raw) {
  const inner = raw.trim().slice(1, -1);
  if (!inner.trim()) return [];
  return inner.split(",").map((s) => unquote(s));
}

// Minimal YAML: scalars, inline lists, and block lists of scalars.
function parseFrontmatter(lines) {
  const data = {};
  let key = null;
  for (const line of lines) {
    if (!line.trim()) continue;
    const item = line.match(/^\s+-\s+(.*)$/);
    if (item && key) {
      if (!Array.isArray(data[key])) data[key] = [];
      data[key].push(unquote(item[1]));
      continue;
    }
    const kv = line.match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
    if (!kv) throw new Error(`unparseable frontmatter line: ${line}`);
    key = kv[1];
    const value = kv[2].trim();
    if (value === "") data[key] = [];
    else if (value.startsWith("[") && value.endsWith("]")) data[key] = parseInlineList(value);
    else data[key] = unquote(value);
  }
  return data;
}

function parseExamples(section) {
  return section
    .split("\n")
    .map((l) => l.match(/^\s*-\s+(.*)$/))
    .filter(Boolean)
    .map((m) => unquote(m[1]))
    .filter((s) => s.length > 0);
}

export function parseRuleFile(file) {
  const text = fs.readFileSync(file, "utf8");
  const m = text.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!m) throw new Error("missing frontmatter block");
  const meta = parseFrontmatter(m[1].split("\n"));
  const rest = m[2];
  const failsAt = rest.search(/^## Fails\s*$/m);
  const passesAt = rest.search(/^## Passes\s*$/m);
  const body = (failsAt >= 0 ? rest.slice(0, failsAt) : rest).trim();
  const fails = failsAt >= 0 ? parseExamples(rest.slice(failsAt, passesAt > failsAt ? passesAt : undefined)) : [];
  const passes = passesAt >= 0 ? parseExamples(rest.slice(passesAt, failsAt > passesAt ? failsAt : undefined)) : [];
  return {
    file,
    basename: path.basename(file, ".md"),
    meta,
    body,
    fails,
    passes,
    hasFails: failsAt >= 0,
    hasPasses: passesAt >= 0,
  };
}

function compileRule(rule) {
  const patterns = Array.isArray(rule.meta.patterns) ? rule.meta.patterns : [];
  rule.regexes = patterns.map((p) => new RegExp(p, "giu"));
  rule.surfaces = rule.meta.surfaces === "all" ? "all" : rule.meta.surfaces;
  return rule;
}

export function loadRules(rulesDir = DEFAULT_RULES_DIR) {
  if (!fs.existsSync(rulesDir)) throw new Error(`rules directory not found: ${rulesDir}`);
  return fs
    .readdirSync(rulesDir)
    .filter((f) => f.endsWith(".md"))
    .sort()
    .map((f) => compileRule(parseRuleFile(path.join(rulesDir, f))));
}

// ---------------------------------------------------------- preprocessing

// Returns an array of lines the same length as the input, with everything
// that is not prose blanked out so line numbers survive.
export function preprocess(text) {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const out = new Array(lines.length).fill("");
  let i = 0;
  // YAML frontmatter at the top.
  if (lines[0] !== undefined && lines[0].trim() === "---") {
    let j = 1;
    while (j < lines.length && lines[j].trim() !== "---") j += 1;
    if (j < lines.length) i = j + 1;
  }
  let fence = null; // { char, length } while inside a fenced block
  let inComment = false;
  for (; i < lines.length; i += 1) {
    let line = lines[i];
    const fenceMark = line.match(/^\s{0,3}(`{3,}|~{3,})/);
    if (fence) {
      // Close only on a fence of the same character, at least as long.
      if (fenceMark && fenceMark[1][0] === fence.char && fenceMark[1].length >= fence.length) fence = null;
      continue;
    }
    const openedInComment = inComment;
    if (inComment) {
      const end = line.indexOf("-->");
      if (end < 0) continue;
      line = line.slice(end + 3);
      inComment = false;
    }
    // A fence must start the line; a line that began inside a comment cannot.
    if (fenceMark && !openedInComment) {
      fence = { char: fenceMark[1][0], length: fenceMark[1].length };
      continue;
    }
    if (/^\s*>/.test(line)) continue;
    // Code spans go first so a backtick-quoted "<!--" cannot open a comment.
    line = line.replace(/`[^`]*`/g, " ");
    for (;;) {
      const start = line.indexOf("<!--");
      if (start < 0) break;
      const end = line.indexOf("-->", start + 4);
      if (end < 0) {
        line = line.slice(0, start);
        inComment = true;
        break;
      }
      line = line.slice(0, start) + " " + line.slice(end + 3);
    }
    line = line
      .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/https?:\/\/\S+/g, " ");
    out[i] = line;
  }
  return out;
}

// Indices of the first prose paragraph: first non-empty, non-heading line
// through the next blank line.
function openingParagraph(lines) {
  const idx = [];
  let start = -1;
  for (let i = 0; i < lines.length; i += 1) {
    const l = lines[i];
    if (!l.trim()) {
      if (start >= 0) break;
      continue;
    }
    if (/^\s*#/.test(l)) {
      if (start >= 0) break;
      continue;
    }
    if (start < 0) start = i;
    idx.push(i);
  }
  return idx;
}

// ------------------------------------------------------------------ check

function applies(rule, surface) {
  if (surface === "all" || rule.surfaces === "all") return true;
  return rule.surfaces.includes(surface);
}

export function findMatches(rule, lines) {
  const findings = [];
  const scope = rule.meta.position === "opening" ? openingParagraph(lines) : lines.map((_, i) => i);
  for (const i of scope) {
    const line = lines[i];
    if (!line) continue;
    for (const re of rule.regexes) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(line)) !== null) {
        findings.push({ line: i + 1, column: m.index + 1, match: m[0] });
        if (m[0].length === 0) re.lastIndex += 1;
      }
    }
  }
  return findings;
}

export function checkText(text, { rules, surface = "all", tier = "mechanical" }) {
  const lines = preprocess(text);
  const findings = [];
  for (const rule of rules) {
    if (rule.meta.tier !== tier) continue;
    if (!applies(rule, surface)) continue;
    for (const hit of findMatches(rule, lines)) {
      findings.push({
        rule: rule.meta.name,
        severity: rule.meta.severity,
        fix: rule.meta.fix,
        ...hit,
      });
    }
  }
  findings.sort((a, b) => a.line - b.line || a.column - b.column);
  return findings;
}

// --------------------------------------------------------------- validate

export function validateRules(rules) {
  const errors = [];
  const names = new Set();
  for (const rule of rules) {
    const where = path.relative(process.cwd(), rule.file);
    const err = (msg) => errors.push(`${where}: ${msg}`);
    const m = rule.meta;
    if (m.name !== rule.basename) err(`name '${m.name}' must equal file basename '${rule.basename}'`);
    if (names.has(m.name)) err(`duplicate rule name '${m.name}'`);
    names.add(m.name);
    if (typeof m.description !== "string" || !m.description.trim()) err("description is required");
    if (!TIERS.includes(m.tier)) err(`tier must be one of ${TIERS.join("|")}`);
    if (!SEVERITIES.includes(m.severity)) err(`severity must be one of ${SEVERITIES.join("|")}`);
    if (typeof m.fix !== "string" || !m.fix.trim()) err("fix is required");
    if (m.surfaces !== "all") {
      if (!Array.isArray(m.surfaces) || m.surfaces.length === 0) err("surfaces must be 'all' or a non-empty list");
      else for (const s of m.surfaces) if (!SURFACES.includes(s)) err(`unknown surface '${s}'`);
    }
    if (m.position !== undefined && !POSITIONS.includes(m.position)) err(`position must be one of ${POSITIONS.join("|")}`);
    if (!rule.body) err("body paragraph is required");
    else {
      if (/^\s*(#|-|\*|\d+\.)\s/m.test(rule.body)) err("body must be a single paragraph: no headings or lists");
      const words = rule.body.split(/\s+/).filter(Boolean).length;
      if (words > BODY_WORD_LIMIT) err(`body is ${words} words; limit is ${BODY_WORD_LIMIT}`);
    }
    if (!rule.hasFails || rule.fails.length === 0) err("## Fails needs at least one item");
    if (!rule.hasPasses || rule.passes.length === 0) err("## Passes needs at least one item");

    if (m.tier === "judgment") {
      if (Array.isArray(m.patterns) && m.patterns.length > 0) err("judgment rules carry no patterns");
      if (m.severity !== "warn") err("judgment rules are warn only");
      continue;
    }
    if (!Array.isArray(m.patterns) || m.patterns.length === 0) {
      err("mechanical rules need at least one pattern");
      continue;
    }
    for (const example of rule.fails) {
      if (findMatches(rule, preprocess(example)).length === 0) err(`Fails item does not match any pattern: "${example}"`);
    }
    for (const example of rule.passes) {
      const hits = findMatches(rule, preprocess(example));
      if (hits.length > 0) err(`Passes item matches pattern ("${hits[0].match}"): "${example}"`);
    }
  }
  return errors;
}

// ---------------------------------------------------------------- compose

export function composeRules(rules, { surface = "all", tier } = {}) {
  const chosen = rules.filter((r) => applies(r, surface) && (!tier || r.meta.tier === tier));
  const out = [];
  out.push(`# Prose rules · surface: ${surface}${tier ? ` · tier: ${tier}` : ""}`);
  out.push(`Source: bin/prose-rules/ · generated by bin/prose-check.mjs compose; point at this, do not copy it.`);
  out.push("");
  for (const r of chosen) {
    out.push(`## ${r.meta.name} (${r.meta.tier}, ${r.meta.severity})`);
    out.push(r.body);
    out.push(`Fails: ${r.fails.map((e) => `"${e}"`).join(" · ")}`);
    out.push(`Passes: ${r.passes.map((e) => `"${e}"`).join(" · ")}`);
    out.push(`Fix: ${r.meta.fix}`);
    out.push("");
  }
  return out.join("\n");
}

// -------------------------------------------------------------------- cli

function parseArgs(argv) {
  const opts = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "-") opts._.push(a);
    else if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (["advisory", "json", "help"].includes(key)) opts[key] = true;
      else if (next !== undefined && !next.startsWith("--")) {
        if (key === "meta") (opts.meta ||= []).push(next);
        else opts[key] = next;
        i += 1;
      } else opts[key] = true;
    } else opts._.push(a);
  }
  return opts;
}

function usage() {
  return [
    "usage:",
    "  prose-check.mjs validate [--rules-dir DIR]",
    "  prose-check.mjs check --surface <s> [--tier mechanical] [--format text|json|github] [--advisory] <file>... | -",
    "  prose-check.mjs compose --surface <s> [--tier mechanical|judgment]",
    "  prose-check.mjs report --surface <s> [--meta key=value ...] <file>...   (advisory comment, exit 0)",
    "  prose-check.mjs list",
    "",
    `surfaces: all ${SURFACES.join(" ")}`,
    "contract: docs/specs/prose-rule-v1.md",
  ].join("\n");
}

class InputError extends Error {}

function readInput(target) {
  try {
    if (target === "-") return { name: "<stdin>", text: fs.readFileSync(0, "utf8") };
    return { name: target, text: fs.readFileSync(target, "utf8") };
  } catch (e) {
    throw new InputError(`cannot read ${target}: ${e.code || e.message}`);
  }
}

// The advisory comment: one sticky block per PR. Marker for upsert, a table
// a reviewer can act on, and a data block a tally can read back.
export const REPORT_MARKER = "<!-- prose-check -->";
export const REPORT_DATA_PREFIX = "<!-- prose-check-data ";

function cell(text) {
  return String(text).replace(/\|/g, "\\|").replace(/\r?\n/g, " ");
}

export function renderReport(inputs, { rules, surface, meta = {} }) {
  const rows = [];
  const byRule = {};
  let blocks = 0;
  let warns = 0;
  for (const { label, text } of inputs) {
    for (const f of checkText(text, { rules, surface })) {
      rows.push({ label, ...f });
      byRule[f.rule] = (byRule[f.rule] || 0) + 1;
      if (f.severity === "block") blocks += 1;
      else warns += 1;
    }
  }
  const data = {
    ...meta,
    surface,
    inputs: inputs.length,
    total: rows.length,
    blocks,
    warns,
    findings: byRule,
  };
  const out = [REPORT_MARKER];
  const scope = `${inputs.length} input${inputs.length === 1 ? "" : "s"} · surface \`${surface}\``;
  if (rows.length === 0) {
    out.push(`✅ prose check: no findings · ${scope}`);
  } else {
    out.push(`### ◦ prose check · ${rows.length} finding${rows.length === 1 ? "" : "s"} (advisory, not gated)`);
    out.push("");
    out.push(`${scope} · ${blocks} would block, ${warns} warn`);
    out.push("");
    out.push("| where | line | rule | match | fix |");
    out.push("|---|---|---|---|---|");
    for (const r of rows.slice(0, 40)) {
      out.push(`| ${cell(r.label)} | ${r.line} | \`${r.rule}\` | ${cell(r.match)} | ${cell(r.fix)} |`);
    }
    if (rows.length > 40) out.push(`| … | | | and ${rows.length - 40} more | |`);
    out.push("");
    out.push("Rules: `bin/prose-rules/` · contract: `docs/specs/prose-rule-v1.md` · locally: `bash bin/node-run.sh bin/prose-check.mjs check --surface git <file>`");
  }
  out.push("");
  out.push(`${REPORT_DATA_PREFIX}${JSON.stringify(data)} -->`);
  return out.join("\n");
}

function formatFindings(findings, format) {
  if (format === "json") return JSON.stringify(findings, null, 2);
  const lines = [];
  for (const f of findings) {
    if (format === "github") {
      const level = f.severity === "block" ? "error" : "warning";
      lines.push(`::${level} file=${f.file},line=${f.line},col=${f.column},title=prose ${f.rule}::"${f.match}" → ${f.fix}`);
    } else {
      lines.push(`${f.file}:${f.line}:${f.column}  ${f.rule} (${f.severity})  "${f.match}"  → ${f.fix}`);
    }
  }
  return lines.join("\n");
}

function main(argv) {
  const cmd = argv[0];
  const opts = parseArgs(argv.slice(1));
  if (!cmd || opts.help || cmd === "--help" || cmd === "-h") {
    console.log(usage());
    return 0;
  }
  const rulesDir = opts["rules-dir"] ? path.resolve(opts["rules-dir"]) : DEFAULT_RULES_DIR;
  let rules;
  try {
    rules = loadRules(rulesDir);
  } catch (e) {
    console.error(`prose-check: ${e.message}`);
    return 2;
  }

  if (cmd === "list") {
    for (const r of rules) {
      const surfaces = r.surfaces === "all" ? "all" : r.surfaces.join(",");
      console.log(`${r.meta.name.padEnd(28)} ${r.meta.tier.padEnd(10)} ${r.meta.severity.padEnd(5)} ${surfaces}`);
    }
    return 0;
  }

  if (cmd === "validate") {
    const errors = validateRules(rules);
    for (const r of rules) {
      const n = r.fails.length + r.passes.length;
      console.log(`  ${errors.some((e) => e.includes(r.basename)) ? "✗" : "✓"} ${r.meta.name} (${r.meta.tier}, ${n} examples)`);
    }
    if (errors.length) {
      console.log("");
      for (const e of errors) console.log(`  ✗ ${e}`);
      console.log(`\nprose-check: ${errors.length} contract failure(s) across ${rules.length} rule(s)`);
      return 1;
    }
    console.log(`\nprose-check: ${rules.length} rules valid`);
    return 0;
  }

  if (cmd === "compose") {
    const surface = opts.surface || "all";
    if (surface !== "all" && !SURFACES.includes(surface)) {
      console.error(`prose-check: unknown surface '${surface}'`);
      return 2;
    }
    if (opts.tier && !TIERS.includes(opts.tier)) {
      console.error(`prose-check: unknown tier '${opts.tier}'`);
      return 2;
    }
    process.stdout.write(composeRules(rules, { surface, tier: opts.tier }));
    return 0;
  }

  if (cmd === "report") {
    const surface = opts.surface || "git";
    if (!SURFACES.includes(surface)) {
      console.error(`prose-check: unknown surface '${surface}'`);
      return 2;
    }
    if (opts._.length === 0) {
      console.error(usage());
      return 2;
    }
    const meta = {};
    for (const kv of opts.meta || []) {
      const eq = kv.indexOf("=");
      if (eq > 0) meta[kv.slice(0, eq)] = kv.slice(eq + 1);
    }
    let inputs;
    try {
      inputs = opts._.map((target) => {
        const { name, text } = readInput(target);
        return { label: target === "-" ? "stdin" : path.basename(name).replace(/\.[^.]+$/, ""), text };
      });
    } catch (e) {
      if (!(e instanceof InputError)) throw e;
      console.error(`prose-check: ${e.message}`);
      return 2;
    }
    process.stdout.write(`${renderReport(inputs, { rules, surface, meta })}\n`);
    return 0;
  }

  if (cmd === "check") {
    const surface = opts.surface || "all";
    if (surface !== "all" && !SURFACES.includes(surface)) {
      console.error(`prose-check: unknown surface '${surface}'`);
      return 2;
    }
    const tier = opts.tier || "mechanical";
    if (tier !== "mechanical") {
      console.error("prose-check: only the mechanical tier runs in check today (contract §Tiers)");
      return 2;
    }
    const format = opts.format || (opts.json ? "json" : "text");
    if (!["text", "json", "github"].includes(format)) {
      console.error(`prose-check: unknown format '${format}'`);
      return 2;
    }
    if (opts._.length === 0) {
      console.error(usage());
      return 2;
    }
    const all = [];
    try {
      for (const target of opts._) {
        const { name, text } = readInput(target);
        for (const f of checkText(text, { rules, surface, tier })) all.push({ file: name, ...f });
      }
    } catch (e) {
      if (!(e instanceof InputError)) throw e;
      console.error(`prose-check: ${e.message}`);
      return 2;
    }
    if (format === "json" || all.length) console.log(formatFindings(all, format));
    const blocks = all.filter((f) => f.severity === "block").length;
    const warns = all.length - blocks;
    if (format !== "json") {
      console.log(`prose-check: ${blocks} block, ${warns} warn · surface ${surface}${opts.advisory ? " · advisory" : ""}`);
    }
    return blocks > 0 && !opts.advisory ? 1 : 0;
  }

  console.error(`prose-check: unknown command '${cmd}'\n\n${usage()}`);
  return 2;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(main(process.argv.slice(2)));
}
