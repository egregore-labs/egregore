#!/usr/bin/env node
// Side-stripe ratchet.
//
// The highlight recipe retires the coloured stripe down one side of a box, and
// the coloured accent edge along its top or bottom: reading emphasis is a
// marker under words, a margin label or a hanging quote; status is a quiet
// panel with a shaped label; a selected item is weight plus a filled shape.
// The kit classes are in packages/egregore-artifacts/lib/recipe.js. This
// scanner reads the canonical source of every rendered surface and reports
// each stripe form:
//
//   side-border   border-left/right/inline-start/inline-end (or a -width or
//                 -color longhand) 2px or wider, or any width in a colour
//                 that is not a line colour (a tone or accent token, a raw
//                 colour with hue, an unknown expression)
//   edge-border   the same judgement for border-top/bottom/block-start/
//                 block-end: an accent edge along the top or bottom of a box
//   border-width  a four-value border-width that draws only one side at 2px
//                 or wider
//   inset-shadow  box-shadow: inset <N>px 0 or inset 0 <N>px — a bar drawn
//                 with a shadow, judged like a border of width |N|
//   pseudo-bar    a ::before or ::after pinned to the left or right edge, 2-6px
//                 wide and taller than it is wide, with a background
//   inline-style  the camelCase equivalents in JS, JSX and Python strings
//                 (borderLeft, borderBottom, borderInlineStart,
//                 boxShadow: 'inset 3px 0 …' or 'inset 0 -2px …')
//
// Some one-sided lines are structure and pass: a divider at most 1.5px wide
// in a line colour (a hairline under a header, between rows), a glyph drawn
// from two adjacent sides (a tick, an elbow), one arc of a round element (a
// spinner), and a top or bottom hairline on a link, a definition or a form
// field (an underline, not a box edge).
// A timeline rail that connects nodes is structure too, but it passes only
// through an explicit EXEMPTIONS entry with a reason. An exemption that no
// longer matches a finding is itself a finding, so the list cannot outlive the
// rails it covers.
//
// Usage:
//   node bin/tests/side-stripes.mjs [--root DIR]    # the canonical source set
//   node bin/tests/side-stripes.mjs --files F...    # only these files
//   node bin/tests/side-stripes.mjs --list          # the files the scan reads
// Prints one finding per line and a summary; exits 1 above CEILING.
// Test: bin/tests/test-side-stripes.sh.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const CEILING = 0;

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

const CODE_EXT = new Set(['.html', '.css', '.js', '.mjs', '.cjs', '.jsx', '.ts', '.tsx', '.py']);
const FENCE_LANGS = new Set(['css', 'html', 'js', 'mjs', 'jsx', 'javascript', 'ts', 'tsx', 'scss']);

// The canonical source of every rendered surface. `deep` walks the tree;
// otherwise only the directory's own files. `skip` names subtrees (relative to
// `dir`) that are frozen fixtures or not source; `md` also reads fenced code
// blocks in Markdown files (skill-embedded HTML and CSS).
export const SCOPE = [
  { dir: 'packages/egregore-artifacts/lib', deep: true, skip: ['vendor/design-system/fixtures'] },
  { dir: 'packages/design-system', deep: true, skip: ['fixtures/live', 'node_modules'], md: true },
  { dir: '.claude/skills', deep: true, md: true },
  { dir: 'api', ext: ['.py'] },
  { dir: 'bin', ext: ['.html'] },
  { file: 'loom/dashboard/render.mjs' },
  { dir: 'threads/render', ext: ['.py'] },
  { dir: 'site/src', deep: true },
];

// Rails that connect timeline nodes: structure, not emphasis. Each entry names
// the file, a selector fragment and the reason the line stays.
export const EXEMPTIONS = [
  {
    file: 'packages/egregore-artifacts/lib/editorial.js',
    selector: '.chainline',
    reason: 'handoff-v1 extension chain: the rail joins the chain nodes (pinned by surface-structure.test.js)',
  },
  {
    file: 'api/handoff_render.py',
    selector: '.eg-chain',
    reason: 'hosted handoff extension chain: the rail joins the chain nodes',
  },
  {
    file: '.claude/skills/scroll/assets/shell.html',
    selector: '.hflow.future',
    reason: 'scroll history flow: the dashed rail joins the not-yet-reached history nodes',
  },
];

const SIDE = 'left|right|inline-start|inline-end|top|bottom|block-start|block-end';
const EDGES = new Set(['top', 'bottom', 'block-start', 'block-end']);
const CSS_SIDE = new RegExp(`border-(${SIDE})(-width|-color|-style)?\\s*:\\s*([^;{}"'\`\\n]*(?:\\$\\{[^}]*\\}[^;{}"'\`\\n]*)*)`, 'gi');
const CSS_WIDTHS = /border-width\s*:\s*([^;{}"'`\n]*)/gi;
const CSS_SHADOW = /box-shadow\s*:\s*([^;{}"'`\n]*)/gi;
const JS_SIDE = /\bborder(Left|Right|InlineStart|InlineEnd|Top|Bottom|BlockStart|BlockEnd)(Width|Color|Style)?\s*[:=]\s*((?:`[^`]*`|'[^']*'|"[^"]*"|[^,\n}`'"])+)/g;
const JS_SHADOW = /\bboxShadow\s*[:=]\s*(`[^`]*`|'[^']*'|"[^"]*"|[^,\n}]+)/g;

// A line colour: a divider token, a surface token, an ink grey, a gray.
const NEUTRAL_NAME = /line|border|hairline|rule|divider|grid|gr[ae]y|(?:^|-)ink(?:-[a-z]+)?$|^-?-?(?:bg|card|paper|surface|canvas|ground|shadow|black|white|transparent)$/i;
const KEYWORDS = /\b(?:solid|dashed|dotted|double|groove|ridge|inset|outset|none|hidden|!important)\b/gi;

function lengthPx(token) {
  const match = String(token).trim().match(/^(-?[\d.]+)(px|em|rem)?$/i);
  if (match) {
    const n = Math.abs(Number(match[1]));
    return match[2] && match[2].toLowerCase() !== 'px' ? n * 16 : n;
  }
  const keyword = { thin: 1, medium: 3, thick: 5 }[String(token).trim().toLowerCase()];
  return keyword ?? null;
}

function hexChroma(hex) {
  let h = hex.replace('#', '');
  if (h.length === 3 || h.length === 4) h = h.split('').map((c) => c + c).join('');
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
  return (Math.max(r, g, b) - Math.min(r, g, b)) / 255;
}

// True when one colour term is a line colour: a neutral token or identifier,
// a raw colour without hue, or transparent.
function neutralTerm(term) {
  const t = term.trim().replace(/^[`'"]+|[`'"]+$/g, '');
  if (!t) return true;
  const variable = t.match(/^var\(\s*(--[\w-]+)/i);
  if (variable) return NEUTRAL_NAME.test(variable[1].replace(/^--/, ''));
  const expression = t.match(/^\$\{([^}]*)\}?$/);
  if (expression) return /line|border|hairline|rule|divider|gr[ae]y|transparent/i.test(expression[1]);
  if (/^#[0-9a-f]{3,8}$/i.test(t)) return hexChroma(t) < 0.12;
  const rgb = t.match(/^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/i);
  if (rgb) {
    const channels = rgb.slice(1, 4).map(Number);
    return (Math.max(...channels) - Math.min(...channels)) / 255 < 0.12;
  }
  if (/^color-mix\(/i.test(t)) return false;
  return /^(?:transparent|black|white|gr[ae]y|silver|inherit|initial|unset)$/i.test(t);
}

// color-mix() of line colours (an ink at 12% over transparent) is a line
// colour; a mix with any hue in it is not. Each mix becomes one plain term.
function resolveMixes(value) {
  let v = value;
  for (let start = v.search(/color-mix\(/i); start !== -1; start = v.search(/color-mix\(/i)) {
    let end = v.indexOf('(', start);
    for (let depth = 0; end < v.length; end += 1) {
      if (v[end] === '(') depth += 1;
      if (v[end] === ')' && (depth -= 1) === 0) break;
    }
    const args = v.slice(v.indexOf('(', start) + 1, end).split(/,(?![^(]*\))/)
      .map((arg) => arg.trim()).filter((arg) => !/^in\s/i.test(arg))
      .map((arg) => arg.replace(/\s+[\d.]+%$|^[\d.]+%\s+/, '').trim());
    v = `${v.slice(0, start)}${args.every(neutralTerm) ? 'transparent' : 'var(--accent)'}${v.slice(end + 1)}`;
  }
  return v;
}

// Split a declaration value into width and colour: null when it draws no line.
function edgeOf(value, part = '') {
  const v = resolveMixes(value.replace(/\/\*.*?\*\//g, '').trim().replace(/^[`'"]|[`'"]$/g, '').trim());
  if (!v || /^(?:0(?:px)?|none|hidden|initial|unset|inherit|transparent)(?:\s*!important)?$/i.test(v)) return null;
  if (part === '-style') return null;
  const tokens = v.replace(KEYWORDS, ' ').match(/\$\{[^}]*\}?|var\([^)]*\)?|(?:rgba?|hsla?)\([^)]*\)?|#[0-9a-f]{3,8}\b|[^\s]+/gi) || [];
  let width = part === '-color' ? 1 : null;
  const colour = [];
  for (const token of tokens) {
    const px = width === null ? lengthPx(token) : null;
    if (px !== null) width = px;
    else colour.push(token);
  }
  if (width === null) width = part === '-width' ? 0 : 3; // bare `border-left: solid red` draws medium
  if (width === 0) return null;
  return { width, neutral: part === '-width' || colour.every(neutralTerm) };
}

function isStripe(value, part = '') {
  const edge = edgeOf(value, part);
  return Boolean(edge) && (edge.width >= 2 || !edge.neutral);
}

// A JS value may be a ternary of string literals (`active ? '2px solid red'
// : 'none'`): each literal is judged on its own, and any stripe counts.
function isStripeJs(value, part = '') {
  const literals = value.match(/`[^`]*`|'[^']*'|"[^"]*"/g);
  return literals ? literals.some((literal) => isStripe(literal, part)) : isStripe(value, part);
}

// Structure that one edge line can belong to without being a highlight:
//   a round element (border-radius 50%): one arc of a ring or a spinner;
//   a top or bottom hairline on a link, a definition or a form field: an
//   underline, which is text decoration or the field's own edge, not a box's.
const TEXT_LEVEL = new Set(['a', 'dfn', 'abbr', 'input', 'textarea', 'select']);
function roundGlyph(text, index) {
  const open = Math.max(text.lastIndexOf('{', index), index - 400);
  const close = text.indexOf('}', index);
  return /border-?radius\s*:\s*["'`]?50%/i.test(text.slice(open, close < 0 ? index + 400 : close));
}
function textUnderline(selector, value, part) {
  const edge = edgeOf(value, part);
  if (!edge || edge.width >= 2 || !selector) return false;
  return selector.split(',').every((one) => {
    const subject = one.trim().split(/[\s>+~]+/).pop() || '';
    return TEXT_LEVEL.has((subject.match(/^[a-z]+/i) || [''])[0].toLowerCase());
  });
}

function lineOf(text, index) {
  let line = 1;
  for (let i = text.indexOf('\n'); i !== -1 && i < index; i = text.indexOf('\n', i + 1)) line += 1;
  return line;
}

// The rule around a position: the selector before the nearest `{` and the
// declarations up to the next `}`.
function ruleAround(text, index) {
  const open = text.lastIndexOf('{', index);
  const close = text.indexOf('}', index);
  if (open < 0) return { selector: '', body: text.slice(Math.max(0, index - 200), close < 0 ? index + 200 : close) };
  const before = Math.max(text.lastIndexOf('}', open), text.lastIndexOf('\n\n', open), text.lastIndexOf(';', open));
  return {
    selector: text.slice(before + 1, open).replace(/\s+/g, ' ').trim().slice(-120),
    body: text.slice(open + 1, close < 0 ? text.length : close),
  };
}

// Two adjacent sides drawn identically in one rule make a glyph (a tick, an
// elbow connector), not a box edge. A thick side next to a different divider
// is still a stripe.
function drawsGlyph(body, side) {
  const decls = declarations(body);
  const value = (name) => (decls[`border-${name}`] || '').replace(/\s+/g, ' ').trim();
  const own = value(side);
  const adjacent = EDGES.has(side) ? ['left', 'right'] : ['top', 'bottom'];
  return Boolean(own) && adjacent.map(value).includes(own);
}

// An inline style attribute or object, not a stylesheet rule.
function inlineContext(text, index) {
  const lineStart = text.lastIndexOf('\n', index) + 1;
  return /style\s*[=:]\s*(?:\{\s*\{?|["'`])[^>]*$/.test(text.slice(lineStart, index));
}

function shadowBars(value) {
  const bars = [];
  for (const shadow of value.replace(/^[`'"]|[`'"]$/g, '').split(/,(?![^(]*\))/)) {
    if (!/\binset\b/i.test(shadow)) continue;
    // Top-level tokens only, so the numbers inside rgba(…) or var(…) are
    // colour, not lengths.
    const tokens = shadow.match(/[\w-]*\([^()]*(?:\([^()]*\)[^()]*)*\)|[^\s()]+/g) || [];
    const isLength = (token) => /^-?[\d.]+(?:px|em|rem)?$/i.test(token);
    const lengths = tokens.filter(isLength);
    if (lengths.length < 2) continue;
    const [x, y, blur = null] = lengths.map((token) => lengthPx(/\d$/.test(token) ? `${token}px` : token));
    // One offset and no blur: a bar along the left/right (x) or top/bottom (y).
    if ((x === 0) !== (y === 0) && !blur) {
      const colour = tokens.filter((token) => !isLength(token) && !/^inset$/i.test(token)).join(' ');
      bars.push({ width: Math.abs(x || y), colour: colour.trim() });
    }
  }
  return bars;
}

function declarations(body) {
  const decls = {};
  for (const decl of body.split(';')) {
    const at = decl.indexOf(':');
    if (at < 0) continue;
    decls[decl.slice(0, at).trim().toLowerCase()] = decl.slice(at + 1).replace(/!important/i, '').trim();
  }
  return decls;
}

// A ::before/::after pinned to one side (flush, or hanging up to 6px outside
// the edge), 2-6px wide, taller than wide, painted. A rail centred under its
// nodes sits further in and needs no special case.
function pseudoBar(decls) {
  const zero = (value) => value !== undefined && /^(?:0|-[0-6](?:\.\d+)?)(?:px|%)?$/.test(value.trim());
  let left = decls.left;
  let right = decls.right;
  let top = decls.top;
  let bottom = decls.bottom;
  if (decls.inset) {
    const parts = decls.inset.split(/\s+/);
    const [t, r = t, b = t, l = r] = parts;
    top ??= t; right ??= r; bottom ??= b; left ??= l;
  }
  left ??= decls['inset-inline-start'];
  right ??= decls['inset-inline-end'];
  if (!zero(left) && !zero(right)) return false;
  const width = decls.width !== undefined ? lengthPx(decls.width) : null;
  if (width === null || width < 2 || width > 6) return false;
  const paint = decls.background ?? decls['background-color'];
  if (!paint || /^(?:none|transparent)$/i.test(paint)) return false;
  const height = decls.height;
  const tall = (top !== undefined && bottom !== undefined && !/auto/.test(`${top}${bottom}`))
    || (height !== undefined && (/%|vh/.test(height) || (lengthPx(height) ?? 0) >= width * 3));
  return tall;
}

function stripComments(text, ext) {
  // Keep newlines so reported line numbers stay true. A CSS comment is short;
  // the bound keeps a `/*` inside a JS glob string ('**/*.md') from blanking
  // the file up to some distant `*/`.
  const blank = (comment) => (comment.length <= 600 && comment.split('\n').length <= 8 ? comment.replace(/[^\n]/g, ' ') : comment);
  let out = text.replace(/\/\*[\s\S]*?\*\//g, blank);
  if (ext === '.html') out = out.replace(/<!--[\s\S]*?-->/g, (comment) => comment.replace(/[^\n]/g, ' '));
  // Python f-strings double their braces; CSS rules read the same either way.
  if (ext === '.py') out = out.replace(/\{\{/g, ' {').replace(/\}\}/g, '} ');
  return out;
}

// Markdown: only fenced blocks in a code language; other lines blanked.
function fencedCode(text) {
  const lines = text.split('\n');
  let inside = false;
  return lines.map((line) => {
    const fence = line.match(/^\s*(```|~~~)\s*([\w-]*)/);
    if (fence) {
      inside = inside ? false : FENCE_LANGS.has(fence[2].toLowerCase()) || fence[2] === '' ? 'code' : 'other';
      return '';
    }
    return inside === 'code' ? line : '';
  }).join('\n');
}

export function scanText(raw, file) {
  const ext = path.extname(file).toLowerCase();
  const text = stripComments(ext === '.md' ? fencedCode(raw) : raw, ext === '.md' ? '.css' : ext);
  const findings = [];
  const add = (form, index, decl, selector) => {
    findings.push({ file, line: lineOf(text, index), form, selector, text: decl.replace(/\s+/g, ' ').trim().slice(0, 120) });
  };

  for (const match of text.matchAll(CSS_SIDE)) {
    const part = (match[2] || '').toLowerCase();
    if (!isStripe(match[3], part) || roundGlyph(text, match.index)) continue;
    const side = match[1].toLowerCase();
    const form = EDGES.has(side) ? 'edge-border' : 'side-border';
    if (inlineContext(text, match.index)) {
      add(form, match.index, match[0], '[style]');
      continue;
    }
    const { selector, body } = ruleAround(text, match.index);
    if (!match[2] && drawsGlyph(body, side)) continue;
    if (EDGES.has(side) && textUnderline(selector, match[3], part)) continue;
    add(form, match.index, match[0], selector);
  }
  for (const match of text.matchAll(CSS_WIDTHS)) {
    const widths = match[1].trim().split(/\s+/).map(lengthPx);
    if (widths.length !== 4 || widths.some((w) => w === null)) continue;
    const [top, right, bottom, left] = widths;
    const oneSide = (a, b, c, d) => a === 0 && b === 0 && (c >= 2) !== (d >= 2);
    if (oneSide(top, bottom, left, right) || oneSide(left, right, top, bottom)) {
      add('border-width', match.index, match[0], ruleAround(text, match.index).selector);
    }
  }
  for (const match of text.matchAll(CSS_SHADOW)) {
    for (const bar of shadowBars(match[1])) {
      if (isStripe(`${bar.width}px solid ${bar.colour}`)) {
        add('inset-shadow', match.index, match[0], ruleAround(text, match.index).selector);
        break;
      }
    }
  }
  for (const match of text.matchAll(/([^{}]*)\{([^{}]*)\}/g)) {
    const selector = match[1].replace(/\s+/g, ' ').trim();
    if (!/::?(?:before|after)\b/i.test(selector)) continue;
    if (pseudoBar(declarations(match[2]))) {
      add('pseudo-bar', match.index + match[1].length, match[2], selector.slice(-120));
    }
  }
  if (ext !== '.css' && ext !== '.html' && ext !== '.md') {
    for (const match of text.matchAll(JS_SIDE)) {
      if (!isStripeJs(match[3], match[2] ? `-${match[2].toLowerCase()}` : '') || roundGlyph(text, match.index)) continue;
      add('inline-style', match.index, match[0], '[style]');
    }
    for (const match of text.matchAll(JS_SHADOW)) {
      if (shadowBars(match[1]).some((bar) => isStripe(`${bar.width}px solid ${bar.colour}`))) {
        add('inline-style', match.index, match[0], '[style]');
      }
    }
  }
  return findings;
}

function walk(root, entry) {
  const found = [];
  if (entry.file) {
    const file = path.join(root, entry.file);
    return fs.existsSync(file) ? [file] : [];
  }
  const base = path.join(root, entry.dir);
  if (!fs.existsSync(base)) return found;
  const skip = (entry.skip || []).map((part) => path.join(base, part));
  const visit = (directory) => {
    for (const item of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const file = path.join(directory, item.name);
      if (item.name === 'node_modules' || skip.includes(file)) continue;
      if (item.isDirectory()) {
        if (entry.deep) visit(file);
        continue;
      }
      if (!item.isFile()) continue;
      const ext = path.extname(item.name).toLowerCase();
      if (entry.ext ? entry.ext.includes(ext) : CODE_EXT.has(ext) || (entry.md && ext === '.md')) found.push(file);
    }
  };
  visit(base);
  return found;
}

export function defaultFiles(root) {
  return SCOPE.flatMap((entry) => walk(root, entry));
}

export function scanFiles(files, root) {
  return files.flatMap((file) => {
    const relative = path.relative(root, file).split(path.sep).join('/');
    return scanText(fs.readFileSync(file, 'utf8'), relative);
  });
}

// Drop exempted rails; report an exemption whose file is present but that no
// longer matches a finding. A file this instance does not ship is inert.
export function applyExemptions(findings, root) {
  const used = new Set();
  const kept = findings.filter((finding) => {
    const entry = EXEMPTIONS.find((candidate) => candidate.file === finding.file && finding.selector.includes(candidate.selector));
    if (entry) used.add(entry);
    return !entry;
  });
  const stale = EXEMPTIONS.filter((entry) => !used.has(entry) && fs.existsSync(path.join(root, entry.file)))
    .map((entry) => ({ file: entry.file, line: 0, form: 'stale exemption', selector: entry.selector, text: entry.reason }));
  return [...kept, ...stale];
}

function main(argv) {
  let root = REPO_ROOT;
  let files = null;
  let list = false;
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--root') root = path.resolve(argv[(i += 1)]);
    else if (argv[i] === '--list') list = true;
    else if (argv[i] === '--files') {
      files = argv.slice(i + 1).map((file) => path.resolve(file));
      break;
    } else {
      console.error(`side-stripes: unknown argument ${argv[i]}`);
      return 2;
    }
  }
  const scanned = files || defaultFiles(root);
  if (list) {
    for (const file of scanned) console.log(path.relative(root, file).split(path.sep).join('/'));
    return 0;
  }
  const findings = files ? scanFiles(files, process.cwd()) : applyExemptions(scanFiles(scanned, root), root);
  for (const { file, line, form, selector, text } of findings) {
    console.log(`${file}:${line}: ${form}: ${selector ? `${selector} { ${text} }` : text}`);
  }
  console.log(`side-stripes: scanned ${scanned.length} file(s)`);
  console.log(`side-stripes: ${findings.length} finding(s), ceiling ${CEILING}`);
  return findings.length > CEILING ? 1 : 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
