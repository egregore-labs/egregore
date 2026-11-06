#!/usr/bin/env node
// Brown palette guidance ratchet.
//
// The retired brown palette (a warm-brown #1D1611 ground, a terracotta
// #D4875A accent, cream and parchment grounds, brass accents) must not come
// back as guidance in always-loaded instructions or in skill text: every
// color comes from the design system registry
// (packages/design-system/themes/registry.json, default pair sovereign).
//
// A line is a finding when it carries a retired hex value, or when it uses a
// brown palette term that is neither forbidden nor describing a registered
// pair. A term is forbidden when a negation governs it: "no", "not", "never"
// and the like, followed only by articles, list joiners and other palette
// terms up to the term ("no brown, cream or terracotta grounds"); a negation
// elsewhere in the sentence does not count. A term describes a registered
// pair when it sits in a parenthetical that names a pair or theme or directly
// follows one ("`meridian` (vellum / nocturne, brass-decided)"), or within
// two words of that name ("the meridian pair's brass accent"). A name counts
// only on its own, not inside `voice-bedrock`, `.ledger` or `bedrock.md`. CSS
// custom property names such as `--terracotta` or `--brass` are token names,
// not guidance, and are ignored.
// EXEMPTIONS names the remaining lines by file and text, each with a reason;
// an exemption whose file no longer carries its text is itself a finding, so
// the list cannot outlive the lines it covers.
//
// Usage:
//   node bin/tests/palette-guidance.mjs [--root DIR]    # the default file set
//   node bin/tests/palette-guidance.mjs --files F...    # only these files
// Prints one finding per line and a summary; exits 1 above CEILING.
// Test: bin/tests/test-palette-guidance.sh.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const CEILING = 0;

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
// The source registry, then the copy vendored into egregore-artifacts (the
// public repository ships the renderer but not the private design package).
const REGISTRY_CANDIDATES = [
  'packages/design-system/themes/registry.json',
  'packages/egregore-artifacts/lib/vendor/design-system/themes/registry.json',
].map((file) => path.join(REPO_ROOT, file));

export function registryPath() {
  return REGISTRY_CANDIDATES.find((file) => fs.existsSync(file)) || null;
}

// Always-loaded instructions for each harness, plus the rule files.
const ALWAYS_LOADED = ['CLAUDE.md', 'AGENTS.md', '.pi/APPEND_SYSTEM.md', '.prime/agent/APPEND_SYSTEM.md'];
const RULE_DIRS = ['.claude/rules'];
// Skill bodies for each harness, plus the design system's own skills.
const SKILL_TREES = ['.claude/skills', '.codex/skills', '.prime/agent/skills', 'packages/design-system'];

const RETIRED_HEX = /#(?:1d1611|d4875a)\b/i;
const TERMS = [
  ['warm-brown', /\bwarm[- ]brown\b/gi],
  ['brown-black', /\bbrown[- ]black\b/gi],
  ['warm palette', /\bwarm palette\b/gi],
  ['terracotta', /\bterracotta\b/gi],
  ['parchment', /\bparchment\b/gi],
  ['cream', /\bcream\b/gi],
  ['brass', /\bbrass\b/gi],
  ['brown', /\bbrown\b/gi],
];
const NEGATION = /\b(?:no|not|never|avoid|without|forbids?|forbidden|bans?|banned|retired?|drops?|instead of|rather than)\b/gi;
// What may sit between a negation and the term it governs, once other palette
// terms are blanked out: articles, list joiners and markdown emphasis.
const NEGATION_GAP = /^(?:[\s,/+&:*_`"'’]|\b(?:a|an|the|any|or|and|nor)\b)*$/i;
// What may sit between a pair name and a term within the two-word window: no
// clause punctuation, at most one other word, a possessive allowed.
const CLAUSE_BREAK = /[,;:()[\]|·—–]/;
const CUSTOM_PROPERTY = /--[a-z0-9-]+/gi;

export const EXEMPTIONS = [
  {
    file: '.claude/skills/press/SKILL.md',
    text: 'in the Egregore brand (cream + terracotta',
    reason: '/press ships its own publication stylesheet (assets/style.css), which follows the egregore.xyz web brand; moving /press onto the registry is separate work',
  },
  {
    file: '.claude/skills/create-video/SKILL.md',
    text: 'Available backgrounds: 1 (terracotta desert)',
    reason: 'names of background image assets, not a palette',
  },
];

// Every registered pair id and theme id.
export function registeredNames() {
  const registry = JSON.parse(fs.readFileSync(registryPath(), 'utf8'));
  const names = new Set();
  for (const [id, pair] of Object.entries(registry.pairs)) {
    names.add(id);
    names.add(pair.light);
    names.add(pair.dark);
  }
  return [...names];
}

// A registered name standing on its own, not part of a longer hyphenated,
// dotted or file name such as voice-bedrock, .ledger or bedrock.md. With
// `trailing`, the name must end the text, allowing only closing markdown.
function namePattern(names, { global = false, trailing = false } = {}) {
  if (names.length === 0) return /(?!)/g;
  const tail = trailing ? '[`*_]*\\s*$' : '(?![\\w-]|\\.\\w)';
  return new RegExp(`(?<![\\w.-])(?:${names.join('|')})${tail}`, global ? 'gi' : 'i');
}

function sentences(line) {
  return line.split(/(?<=[.;!?])\s+/);
}

// Palette term spans in a sentence. Where terms overlap the longest wins, so
// `warm-brown` is one span, not also the `brown` inside it.
function termSpans(sentence) {
  const spans = [];
  for (const [term, pattern] of TERMS) {
    for (const match of sentence.matchAll(pattern)) {
      spans.push({ term, start: match.index, end: match.index + match[0].length });
    }
  }
  spans.sort((a, b) => a.start - b.start || b.end - a.end);
  return spans.filter((span, i) => !spans.slice(0, i).some((other) => other.end >= span.end));
}

// True when the nearest negation before the span governs it: only articles,
// list joiners and other palette terms (blanked out) sit between them.
function negated(sentence, blanked, span) {
  let governing = null;
  for (const match of sentence.matchAll(NEGATION)) {
    if (match.index + match[0].length <= span.start) governing = match;
  }
  if (!governing) return false;
  return NEGATION_GAP.test(blanked.slice(governing.index + governing[0].length, span.start));
}

// The innermost parenthetical around a position, as its inside text and the
// text before its opening parenthesis; an unclosed one runs to the end.
function enclosingParenthetical(sentence, index) {
  let open = -1;
  for (let i = index - 1, depth = 0; i >= 0; i -= 1) {
    if (sentence[i] === ')') depth += 1;
    else if (sentence[i] === '(') {
      if (depth === 0) {
        open = i;
        break;
      }
      depth -= 1;
    }
  }
  if (open < 0) return null;
  let close = sentence.length;
  for (let i = index, depth = 0; i < sentence.length; i += 1) {
    if (sentence[i] === '(') depth += 1;
    else if (sentence[i] === ')') {
      if (depth === 0) {
        close = i;
        break;
      }
      depth -= 1;
    }
  }
  return { inside: sentence.slice(open + 1, close), before: sentence.slice(0, open) };
}

// True when the span describes a registered pair: it sits in a parenthetical
// that names a pair or theme or directly follows one, or a name stands within
// two words of it with no clause punctuation between.
function describesPair(sentence, span, names) {
  const group = enclosingParenthetical(sentence, span.start);
  if (group && (namePattern(names).test(group.inside) || namePattern(names, { trailing: true }).test(group.before))) {
    return true;
  }
  for (const match of sentence.matchAll(namePattern(names, { global: true }))) {
    const end = match.index + match[0].length;
    let between = null;
    if (end <= span.start) between = sentence.slice(end, span.start);
    else if (match.index >= span.end) between = sentence.slice(span.end, match.index);
    if (between === null || CLAUSE_BREAK.test(between)) continue;
    const words = between.replace(/['’]s\b/g, ' ').replace(/[`*_"'’]/g, ' ').split(/\s+/).filter(Boolean);
    if (words.length <= 1) return true;
  }
  return false;
}

// The first finding on one line, or null. Within a sentence, terms are
// reported in TERMS order.
export function scanLine(line, names = registeredNames()) {
  const hex = line.match(RETIRED_HEX);
  if (hex) return hex[0];
  for (const sentence of sentences(line.replace(CUSTOM_PROPERTY, ' '))) {
    const spans = termSpans(sentence);
    let blanked = sentence;
    for (const { start, end } of spans) blanked = blanked.slice(0, start) + ' '.repeat(end - start) + blanked.slice(end);
    for (const [term] of TERMS) {
      for (const span of spans.filter((candidate) => candidate.term === term)) {
        if (!negated(sentence, blanked, span) && !describesPair(sentence, span, names)) return term;
      }
    }
  }
  return null;
}

export function scanText(text, file, names = registeredNames()) {
  const exempt = EXEMPTIONS.filter((entry) => entry.file === file);
  const findings = [];
  text.replace(/\r\n?/g, '\n').split('\n').forEach((line, index) => {
    const term = scanLine(line, names);
    if (!term) return;
    if (exempt.some((entry) => line.includes(entry.text))) return;
    findings.push({ file, line: index + 1, term, text: line.trim() });
  });
  return findings;
}

function skillFiles(root, tree) {
  const found = [];
  const walk = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.name === 'node_modules') continue;
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) walk(file);
      else if (entry.isFile() && entry.name === 'SKILL.md') found.push(file);
    }
  };
  const base = path.join(root, tree);
  if (fs.existsSync(base)) walk(base);
  return found;
}

export function defaultFiles(root) {
  const files = ALWAYS_LOADED.map((file) => path.join(root, file)).filter((file) => fs.existsSync(file));
  for (const directory of RULE_DIRS) {
    const base = path.join(root, directory);
    if (!fs.existsSync(base)) continue;
    for (const name of fs.readdirSync(base).sort()) if (name.endsWith('.md')) files.push(path.join(base, name));
  }
  for (const tree of SKILL_TREES) files.push(...skillFiles(root, tree).sort());
  return files;
}

export function scanFiles(files, root) {
  const names = registeredNames();
  return files.flatMap((file) => {
    const relative = path.relative(root, file).split(path.sep).join('/');
    return scanText(fs.readFileSync(file, 'utf8'), relative, names);
  });
}

// An exemption whose file is present but no longer carries its text. A file
// this instance does not ship (both exempted skills are internal) is inert.
export function staleExemptions(root) {
  return EXEMPTIONS.filter((entry) => {
    const file = path.join(root, entry.file);
    return fs.existsSync(file) && !fs.readFileSync(file, 'utf8').includes(entry.text);
  }).map((entry) => ({ file: entry.file, line: 0, term: 'stale exemption', text: entry.text }));
}

function main(argv) {
  let root = REPO_ROOT;
  let files = null;
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--root') root = path.resolve(argv[(i += 1)]);
    else if (argv[i] === '--files') files = argv.slice(i + 1).map((file) => path.resolve(file));
    else if (!files) {
      console.error(`palette-guidance: unknown argument ${argv[i]}`);
      return 2;
    }
    if (files) break;
  }
  if (!registryPath()) {
    console.log('palette-guidance: skipped, no design system registry in this instance');
    return 0;
  }
  const findings = files
    ? scanFiles(files, process.cwd())
    : [...scanFiles(defaultFiles(root), root), ...staleExemptions(root)];
  for (const { file, line, term, text } of findings) {
    console.log(`${file}:${line}: ${term}: ${text.slice(0, 160)}`);
  }
  console.log(`palette-guidance: ${findings.length} finding(s), ceiling ${CEILING}`);
  return findings.length > CEILING ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
