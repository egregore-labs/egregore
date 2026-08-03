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

function adapt(sourceSpec) {
  let text = sourceSpec
    .replaceAll("Egregore on Codex", "Egregore on Pi")
    .replaceAll("Codex-native", "Pi-native")
    .replaceAll("Codex sessions", "Pi sessions")
    .replaceAll("On Codex", "On Pi")
    .replaceAll("from Codex", "from Pi")
    .replaceAll("inside Codex", "inside Pi")
    .replaceAll("Codex has no", "Pi has no built-in")
    .replaceAll("normal sandboxed Codex shell", "the Pi shell")
    .replaceAll("Codex graph network access", "Pi graph network access")
    .replaceAll("structured Codex question tooling", "Pi UI question tooling")
    .replaceAll("structured Codex", "structured Pi")
    .replaceAll("bin/codex-session-start.sh", "bin/pi-session-start.sh")
    .replaceAll(".codex/hooks/branch-guard.js", ".pi/extensions/egregore.ts")
    .replaceAll("PreToolUse hook (enabled by the launcher via `--enable hooks`)", "`tool_call` gate (loaded after Pi project trust)")
    .replaceAll("If this Codex build does not support hooks", "If Pi project resources are disabled")
    .replaceAll("change permissions in `.claude/settings.json` anytime", "review or disable project resources in `.pi/` anytime")
    .replace(/`\$([a-z][a-z0-9-]*)/g, "`/$1")
    .replace(/\$([a-z][a-z0-9-]*)/g, "/$1");

  text = replaceSection(text, "Egregore on Pi", `You are Pi running inside Egregore — a shared intelligence layer for organizations using AI coding agents. You operate through Git-based shared memory, project-local Pi resources, Egregore skills, and conventions that accumulate knowledge across sessions and people. You are not a tool. You are a participant.

This appendix is generated from the reviewed shell-runtime translation of \`CLAUDE.md\`, the behavioral source of truth. Pi loads it through \`.pi/APPEND_SYSTEM.md\` after the launcher grants project trust for this run. Egregore workflows are shared from \`.codex/skills/\` using Pi's documented cross-harness skill support and exposed as familiar slash commands by \`.pi/extensions/egregore.ts\`.`);

  text = replaceSection(text, "On Launch — MANDATORY FIRST ACTION", `The project-local Pi extension renders the Egregore startup card (identity, handoffs, team activity) inside Pi via \`bin/pi-session-start.sh\`. This works for direct \`pi\` launches and launcher-managed sessions. Do not rerun startup checks and do not narrate startup. The card ends with **"What are you working on?"** — that question is already on screen; treat the user's first message as the answer to it. To re-show the card outside Pi, run \`bash bin/pi-session-start.sh --card\`.`);

  text = replaceSection(text, "Command Awareness", `Egregore workflows are available as Pi slash commands such as \`/activity\`, \`/handoff\`, \`/save\`, and \`/view\`. They are registered from the shared skill inventory by \`.pi/extensions/egregore.ts\`. Pi also exposes the underlying Agent Skills as \`/skill:name\`, and natural-language requests work normally. \`/save\` is the user-facing abstraction for committing, pushing, opening or reusing pull requests, and syncing memory — never make users manage the git workflow by hand.

Invoke commands from user intent — don't wait for the slash. Read the selected skill's \`SKILL.md\` completely before acting. Codex wording inside the shared portable skills means the shell-capable runtime adapter; in Pi, run referenced \`bin/\` scripts directly, use ordinary Pi shell/network access, ignore Codex approval-channel wording, and render compact numbered questions when no Pi UI question surface is available.

**Core loop** — \`/activity\` \`/dashboard\` \`/handoff\` \`/wrap\` \`/save\` \`/reflect\` \`/todo\`
**Knowledge** — \`/search\` \`/deep-reflect\` \`/archive\` \`/note\` \`/add\` \`/meeting\` \`/ingest\` \`/scroll\`
**Identity** — \`/me\`
**Coordination** — \`/ask\` \`/quest\` \`/issue\` \`/invite\` \`/delete-user\` \`/announce\`
**Git** — \`/branch\` \`/commit\` \`/push\` \`/pr\` \`/save\` \`/review-pr\` \`/contribute\`
**Infra** — \`/setup\` \`/update\` \`/pull\` \`/env\` \`/infra\` \`/sync-repos\` \`/release\` \`/checkup\``);

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
