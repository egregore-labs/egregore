#!/usr/bin/env node
// Derive Pi's project-local system appendix from the generated Codex protocol.
// CLAUDE.md remains canonical: CLAUDE.md -> AGENTS.md -> .pi/APPEND_SYSTEM.md.
// The second hop deliberately reuses the reviewed shell-runtime translation,
// then adapts only the harness surfaces that differ between Codex and Pi.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SOURCE = path.join(ROOT, "AGENTS.md");
const OUTPUT = path.join(ROOT, ".pi", "APPEND_SYSTEM.md");
const MANIFEST = path.join(ROOT, ".pi", "spec-manifest.json");
const CODEX_BEGIN = "<!-- BEGIN GENERATED EGREGORE CODEX SPEC";
const CODEX_END = "<!-- END GENERATED EGREGORE CODEX SPEC -->";

function hash(value) {
  return crypto.createHash("sha256").update(value).digest("hex").slice(0, 12);
}

function extractSpec(source) {
  const begin = source.indexOf(CODEX_BEGIN);
  const contentStart = source.indexOf("\n", begin);
  const end = source.indexOf(CODEX_END, contentStart);
  if (begin < 0 || contentStart < 0 || end < 0) {
    throw new Error("AGENTS.md does not contain the generated Codex spec");
  }
  return source.slice(contentStart + 1, end).trim();
}

function replaceSection(markdown, heading, body) {
  const marker = `## ${heading}`;
  const start = markdown.indexOf(marker);
  if (start < 0) throw new Error(`missing section in AGENTS.md: ${heading}`);
  const rest = markdown.slice(start + marker.length);
  const boundary = rest.search(/\n\n---\n\n## /);
  const end = boundary < 0 ? markdown.length : start + marker.length + boundary;
  return `${markdown.slice(0, start)}${marker}\n\n${body}${markdown.slice(end)}`;
}

// Keep an inherited section and put runtime-specific framing in front of it.
// Command Awareness is the case that matters: the canonical category rows and
// disambiguation map live in CLAUDE.md, and a full replace here silently
// shipped a truncated copy that drifted for months. The Codex spec opens the
// section with its own skills-not-slash-commands paragraph, which is wrong for
// a runtime that does have slash commands, so that one paragraph is dropped.
function prependToSection(markdown, heading, body, dropLeadParagraphStartingWith) {
  const marker = `## ${heading}`;
  const start = markdown.indexOf(marker);
  if (start < 0) throw new Error(`missing section in AGENTS.md: ${heading}`);
  const rest = markdown.slice(start + marker.length);
  const boundary = rest.search(/\n\n---\n\n## /);
  const end = boundary < 0 ? markdown.length : start + marker.length + boundary;
  let inherited = markdown.slice(start + marker.length, end).trim();
  if (dropLeadParagraphStartingWith) {
    if (!inherited.startsWith(dropLeadParagraphStartingWith)) {
      throw new Error(`pi/prime-render-spec: "${heading}" no longer opens with "${dropLeadParagraphStartingWith}" — the Codex wording moved; update this adaptation`);
    }
    inherited = inherited.slice(inherited.indexOf("\n\n") + 2).trim();
  }
  return replaceSection(markdown, heading, `${body}\n\n${inherited}`);
}

const CODEX_COMMAND_LEAD = "Codex reserves leading";

function adapt(sourceSpec) {
  // Anchored replacements: every `from` string MUST exist in the generated
  // Codex spec. A missing anchor once no-opped silently (the tool_call gate
  // wording vanished from this file for a whole PR cycle before a test caught
  // it) — now it fails the render loudly so the anchor gets updated alongside
  // the Codex text that moved.
  const ANCHORED = [
    ["Egregore on Codex", "Egregore on Pi"],
    ["Codex-native", "Pi-native"],
    ["Codex sessions", "Pi sessions"],
    ["On Codex", "On Pi"],
    ["Codex has no", "Pi has no built-in"],
    ["bin/codex-session-start.sh", "bin/pi-session-start.sh"],
    [".codex/hooks/branch-guard.js", ".pi/extensions/egregore.ts"],
    ["PreToolUse hook (launcher `--enable hooks`)", "`tool_call` gate (loaded after Pi project trust)"],
    ["If this Codex build does not support hooks", "If Pi project resources are disabled"],
    ["change permissions in `.claude/settings.json` anytime", "review or disable project resources in `.pi/` anytime"],
  ];
  let text = sourceSpec;
  for (const [from, to] of ANCHORED) {
    if (!text.includes(from)) {
      throw new Error(`pi-render-spec: anchor not found in generated Codex spec: "${from}" — the Codex wording moved; update this replacement`);
    }
    text = text.replaceAll(from, to);
  }
  text = text
    .replace(/`\$([a-z][a-z0-9-]*)/g, "`/$1")
    .replace(/\$([a-z][a-z0-9-]*)/g, "/$1");

  text = replaceSection(text, "Egregore on Pi", `You are Pi running inside Egregore — a shared intelligence layer for organizations using AI coding agents. You operate through Git-based shared memory, project-local Pi resources, Egregore skills, and conventions that accumulate knowledge across sessions and people. You are not a tool. You are a participant.

This appendix is generated from the reviewed shell-runtime translation of \`CLAUDE.md\`, the behavioral source of truth. Pi loads it through \`.pi/APPEND_SYSTEM.md\` after the launcher grants project trust for this run. Egregore workflows are shared from \`.codex/skills/\` using Pi's documented cross-harness skill support and exposed as familiar slash commands by \`.pi/extensions/egregore.ts\`.`);

  text = replaceSection(text, "On Launch — MANDATORY FIRST ACTION", `The project-local Pi extension renders the Egregore startup card (identity, handoffs, team activity) inside Pi via \`bin/pi-session-start.sh\`. This works for direct \`pi\` launches and launcher-managed sessions. Do not rerun startup checks and do not narrate startup. The card ends with **"What are you working on?"** — that question is already on screen; treat the user's first message as the answer to it. To re-show the card outside Pi, run \`bash bin/pi-session-start.sh --card\`.`);

  text = prependToSection(text, "Command Awareness", `Egregore workflows are available as Pi slash commands such as \`/activity\`, \`/handoff\`, \`/save\`, and \`/view\`. They are registered from the shared skill inventory by \`.pi/extensions/egregore.ts\`. Pi also exposes the underlying Agent Skills as \`/skill:name\`, and natural-language requests work normally. \`/save\` is the user-facing abstraction for committing, pushing, opening or reusing pull requests, and syncing memory — never make users manage the git workflow by hand.

Read the selected skill's \`SKILL.md\` completely before acting. Codex wording inside the shared portable skills means the shell-capable runtime adapter; in Pi, run referenced \`bin/\` scripts directly, use ordinary Pi shell/network access, ignore Codex approval-channel wording, and render compact numbered questions when no Pi UI question surface is available.`, CODEX_COMMAND_LEAD);

  return `# Egregore on Pi\n\nThis file is generated by \`bin/pi-render-spec.mjs\`; do not edit it by hand.\n\n${text}\n`;
}

const check = process.argv.includes("--check");
const source = fs.readFileSync(SOURCE, "utf8");
const sourceSpec = extractSpec(source);
const rendered = adapt(sourceSpec);
const manifest = `${JSON.stringify({
  generatedBy: "bin/pi-render-spec.mjs",
  source: "AGENTS.md generated Codex spec",
  sourceHash: hash(sourceSpec),
  outputHash: hash(rendered),
  adaptations: [
    "Pi project trust and APPEND_SYSTEM delivery",
    "Pi tool_call branch gate",
    "Pi slash-command extension over shared portable skills",
    "plain-text question fallback and direct shell/network execution",
  ],
}, null, 2)}\n`;

if (check) {
  const currentOutput = fs.existsSync(OUTPUT) ? fs.readFileSync(OUTPUT, "utf8") : "";
  const currentManifest = fs.existsSync(MANIFEST) ? fs.readFileSync(MANIFEST, "utf8") : "";
  if (currentOutput !== rendered || currentManifest !== manifest) {
    console.error("pi spec out of date — run: node bin/pi-render-spec.mjs");
    process.exit(1);
  }
  console.log("pi spec up to date");
} else {
  fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
  fs.writeFileSync(OUTPUT, rendered);
  fs.writeFileSync(MANIFEST, manifest);
  console.log(`pi spec rendered: .pi/APPEND_SYSTEM.md (${Buffer.byteLength(rendered)} bytes)`);
}
