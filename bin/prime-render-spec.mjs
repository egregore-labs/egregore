#!/usr/bin/env node
// Derive Prime Agent's project-local system appendix from the generated Codex
// protocol. CLAUDE.md remains canonical:
// CLAUDE.md -> AGENTS.md -> .prime/agent/APPEND_SYSTEM.md.
// The second hop deliberately reuses the reviewed shell-runtime translation,
// then adapts only the harness surfaces that differ between Codex and Prime.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SOURCE = path.join(ROOT, "AGENTS.md");
const OUTPUT = path.join(ROOT, ".prime", "agent", "APPEND_SYSTEM.md");
const MANIFEST = path.join(ROOT, ".prime", "agent", "spec-manifest.json");
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
      throw new Error(`prime-render-spec: "${heading}" no longer opens with "${dropLeadParagraphStartingWith}" — the Codex wording moved; update this adaptation`);
    }
    inherited = inherited.slice(inherited.indexOf("\n\n") + 2).trim();
  }
  return replaceSection(markdown, heading, `${body}\n\n${inherited}`);
}

const CODEX_COMMAND_LEAD = "Codex reserves leading";

function adapt(sourceSpec) {
  // Anchored replacements: every `from` string MUST exist in the generated
  // Codex spec — a missing anchor no-ops silently and drops Prime-specific
  // wording (see the tool_call gate incident). Fail the render loudly instead.
  const ANCHORED = [
    ["Egregore on Codex", "Egregore on Prime Agent"],
    ["Codex-native", "Prime-native"],
    ["Codex sessions", "Prime Agent sessions"],
    ["On Codex", "On Prime Agent"],
    ["Codex has no", "Prime Agent has no built-in"],
    ["bin/codex-session-start.sh", "bin/prime-session-start.sh"],
    [".codex/hooks/branch-guard.js", ".prime/agent/extensions/egregore.ts"],
    ["PreToolUse hook (launcher `--enable hooks`)", "`tool_call` gate (loaded from the project-local extension)"],
    ["If this Codex build does not support hooks", "If Prime Agent project extensions are disabled"],
    ["change permissions in `.claude/settings.json` anytime", "review or disable project resources in `.prime/agent/` anytime"],
  ];
  let text = sourceSpec;
  for (const [from, to] of ANCHORED) {
    if (!text.includes(from)) {
      throw new Error(`prime-render-spec: anchor not found in generated Codex spec: "${from}" — the Codex wording moved; update this replacement`);
    }
    text = text.replaceAll(from, to);
  }
  text = text
    .replace(/`\$([a-z][a-z0-9-]*)/g, "`/$1")
    .replace(/\$([a-z][a-z0-9-]*)/g, "/$1");

  text = replaceSection(text, "Egregore on Prime Agent", `You are Prime Agent running inside Egregore — a shared intelligence layer for organizations using AI coding agents. You operate through Git-based shared memory, project-local Prime Agent resources, Egregore skills, and conventions that accumulate knowledge across sessions and people. You are not a tool. You are a participant.

This appendix is generated from the reviewed shell-runtime translation of \`CLAUDE.md\`, the behavioral source of truth. Prime Agent loads it through \`.prime/agent/APPEND_SYSTEM.md\`. Egregore workflows are shared from \`.codex/skills/\` through the Agent Skills standard (via \`.agents/skills\` and project settings) and exposed as familiar slash commands by \`.prime/agent/extensions/egregore.ts\`.

Your subagent mechanism (\`rlm(...)\`) spawns Prime Agent child sessions, not Egregore Loom lanes. Ignore Loom routing preambles inside shared skills: run those workflows inline.`);

  text = replaceSection(text, "On Launch — MANDATORY FIRST ACTION", `The project-local Prime Agent extension renders the Egregore startup card (identity, handoffs, team activity) inside the session via \`bin/prime-session-start.sh\`. This works for direct \`prime-agent\` launches and launcher-managed sessions. Do not rerun startup checks and do not narrate startup. The card ends with **"What are you working on?"** — that question is already on screen; treat the user's first message as the answer to it. To re-show the card outside Prime Agent, run \`bash bin/prime-session-start.sh --card\`.`);

  text = prependToSection(text, "Command Awareness", `Egregore workflows are available as Prime Agent slash commands such as \`/activity\`, \`/handoff\`, \`/save\`, and \`/view\`. They are registered from the shared skill inventory by \`.prime/agent/extensions/egregore.ts\`; the duplicate \`/skill:name\` listings are disabled so each workflow appears once. Natural-language requests work normally — and are the route for any workflow whose name collides with a Prime Agent built-in: **say "update egregore" rather than typing \`/update\`**, which is Prime Agent's own self-updater. \`/save\` is the user-facing abstraction for committing, pushing, opening or reusing pull requests, and syncing memory — never make users manage the git workflow by hand.

Read the selected skill's \`SKILL.md\` completely before acting. Codex wording inside the shared portable skills means the shell-capable runtime adapter; in Prime Agent, run referenced \`bin/\` scripts through the IPython kernel (or the bash tool when active), use ordinary shell/network access, ignore Codex approval-channel wording, and render compact numbered questions when no UI question surface is available.

The \`egregore\` Python-backed skill exposes the mechanics as kernel functions — \`import egregore\`, then \`egregore.search(query)\`, \`egregore.activity()\`, \`egregore.handoff(to, topic, body)\`, \`egregore.save(message, topic)\`, \`egregore.branch(topic)\`, \`egregore.notify_plan(recipient, message)\`. Prefer these over re-deriving \`bin/\` CLI usage by reading scripts. \`notify_plan\` is proposal-only: approval and dispatch always pass through the explicit human Send / Edit / Cancel checkpoint.

"Get the latest changes" inside a session means \`/reload\` — it re-reads instructions, context files, skills, and extensions from disk. Never \`git pull\`, \`git reset\`, or \`git checkout\` the working branch to pick up updates. When pivoting topics inside a worktree that carries unmerged branch work, create the new branch from the current HEAD, not \`origin/{base}\` — branching from the configured base in such a worktree removes the unmerged files from disk.

Kernel shell escapes can be time-capped by the harness. Egregore \`bin/\` scripts that sync git state or query the connected graph legitimately run 10–120 seconds: run them with a generous timeout (a \`%%bash\` cell, or the longest limit the harness exposes). If a command dies suspiciously fast (~5s) with partial output, treat it as a timeout — rerun once with a longer limit or render the workflow's designed one-line fallback. Never debug data plumbing inside a product workflow. Connected mode works normally here: graph reads and \`bin/search.sh\` enrichment use the instance's configured credentials, and when graph data is degraded say so in one plain line rather than narrating connectivity theories.`, CODEX_COMMAND_LEAD);

  return `# Egregore on Prime Agent\n\nThis file is generated by \`bin/prime-render-spec.mjs\`; do not edit it by hand.\n\n${text}\n`;
}

const check = process.argv.includes("--check");
const source = fs.readFileSync(SOURCE, "utf8");
const sourceSpec = extractSpec(source);
const rendered = adapt(sourceSpec);
const manifest = `${JSON.stringify({
  generatedBy: "bin/prime-render-spec.mjs",
  source: "AGENTS.md generated Codex spec",
  sourceHash: hash(sourceSpec),
  outputHash: hash(rendered),
  adaptations: [
    "Prime Agent APPEND_SYSTEM delivery from .prime/agent/",
    "Prime Agent tool_call branch gate incl. ipython classification",
    "Prime Agent slash-command extension over shared portable skills",
    "rlm() subagents are not Loom lanes; Loom preambles run inline",
  ],
}, null, 2)}\n`;

if (check) {
  const currentOutput = fs.existsSync(OUTPUT) ? fs.readFileSync(OUTPUT, "utf8") : "";
  const currentManifest = fs.existsSync(MANIFEST) ? fs.readFileSync(MANIFEST, "utf8") : "";
  if (currentOutput !== rendered || currentManifest !== manifest) {
    console.error("prime spec out of date — run: node bin/prime-render-spec.mjs");
    process.exit(1);
  }
  console.log("prime spec up to date");
} else {
  fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
  fs.writeFileSync(OUTPUT, rendered);
  fs.writeFileSync(MANIFEST, manifest);
  console.log(`prime spec rendered: .prime/agent/APPEND_SYSTEM.md (${Buffer.byteLength(rendered)} bytes)`);
}
