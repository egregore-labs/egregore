#!/usr/bin/env node
// Derive the Codex-native Egregore behavioral spec from CLAUDE.md.
//
// CLAUDE.md is the single source of truth for egregore behavior. Codex does
// not read CLAUDE.md — it reads AGENTS.md (root, concatenated, 32 KiB cap).
// This script renders CLAUDE.md into a generated block inside AGENTS.md the
// same way bin/codex-sync-skills.sh derives skills: deterministic transform,
// explicit per-section adaptation, manifest of what was adapted or dropped.
//
//   node bin/codex-render-spec.mjs            # render AGENTS.md + manifest
//   node bin/codex-render-spec.mjs --check    # exit 1 if rendered output is stale
//
// Adaptation rules (the DECIDED option-b translations):
//   EnterWorktree            -> bin/agent.sh branch / git checkout fallback
//   AskUserQuestion          -> numbered options in plain text
//   hook-dependent behavior  -> .codex/hooks equivalent where it exists,
//                               stated as an instruction where it doesn't
//   Claude-only mechanics    -> dropped explicitly (recorded in the manifest)
//   /command tokens          -> $skill tokens when a Codex skill of that name exists
//
// Manifest: .codex/spec-manifest.json — one entry per CLAUDE.md section with
// action (keep|replace), the source section hash, and a note explaining the
// translation. `replace` sections embed hand-authored Codex-native bodies;
// when the source section changes, the recorded hash goes stale and --check
// fails, forcing a review of the translation.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLAUDE_MD = path.join(ROOT, 'CLAUDE.md');
const AGENTS_MD = path.join(ROOT, 'AGENTS.md');
const MANIFEST = path.join(ROOT, '.codex', 'spec-manifest.json');

const BEGIN = '<!-- BEGIN GENERATED EGREGORE CODEX SPEC — derived from CLAUDE.md by bin/codex-render-spec.mjs; do not edit by hand -->';
const END = '<!-- END GENERATED EGREGORE CODEX SPEC -->';

// Hand-authored top of AGENTS.md, owned by this script so it can never be lost
// on regeneration. Opens with the runtime-precedence guard: Claude Code reads
// CLAUDE.md (and now loads root AGENTS.md automatically), so the first thing it
// must see here is an instruction to defer. Codex / shell-only agents read past
// the guard into the thin protocol and the generated spec below.
const AGENTS_PREAMBLE = `# Egregore Agent Protocol

> **Runtime precedence — read this first.**
>
> **If you are Claude Code** (or any agent that loads \`.claude/\`): **stop here.**
> Your authoritative instructions are \`CLAUDE.md\` and \`.claude/\`. Follow the
> SessionStart greeting and the branch-on-first-message rule there. Do **not**
> follow the startup steps below and do **not** use \`bin/agent.sh\` for work an
> Egregore skill already covers. This file exists only for runtimes that cannot
> read \`CLAUDE.md\`.
>
> **If you are Codex or another shell-only agent:** this file is yours — continue.

Egregore is no longer only a Claude Code workspace. Claude Code remains the
first-class integrated runtime through \`.claude/\` and \`CLAUDE.md\`; any other
agent that can run shell commands in this checkout participates through the
portable memory protocol below.

## Startup

1. Read \`egregore.json\` for the instance name, GitHub owner, and managed repos.
2. Run \`bin/agent.sh sync\` to pull the latest shared memory.
3. Read \`memory/people/\` to learn collaborator handles.
4. Run \`bin/agent.sh activity --for <your-handle>\` to inspect handoffs and
   pending questions addressed to you.

## Communication

Use the runtime-neutral bridge instead of Claude Code slash commands:

\`\`\`bash
bin/agent.sh handoff --from alice --to bob --topic "auth review" \\
  --body "Implemented the OAuth callback parser. Bob should review error cases."

bin/agent.sh ask --from bob --to alice --topic "auth review" \\
  --question "Should invalid state redirect to login or return 400?"

bin/agent.sh answer --from alice \\
  --question memory/knowledge/questions/2026-04-26-bob-to-alice-auth-review.md \\
  --body "Return 400 in the API path; redirect only in browser routes."
\`\`\`

Each command writes to the existing Git-backed \`memory/\` repository and pushes
when the memory repo has an \`origin\` remote. Agents that cannot run shell may
write the same markdown files directly, following \`docs/AGENT-PROTOCOL.md\`.

## Compatibility

Claude Code users continue using \`/handoff\`, \`/activity\`, \`/ask\`, \`/save\`, and
other skills — driven by \`CLAUDE.md\`, not this file. Non-Claude agents use
\`bin/agent.sh\` and the file protocol, with the full Codex behavioral spec in the
generated block below. Both paths converge on the same \`memory/\` files.`;

function sha(text) {
  return crypto.createHash('sha256').update(text).digest('hex').slice(0, 12);
}

// ── fence-aware section splitter ────────────────────────────────────────
// Splits markdown into the intro (before the first H2) and one chunk per H2.
// `## ` lines inside ``` fences do not start sections.
function splitSections(markdown) {
  const lines = markdown.split('\n');
  const sections = [];
  let current = { heading: '(intro)', body: [] };
  let inFence = false;
  for (const line of lines) {
    if (/^```/.test(line.trim())) inFence = !inFence;
    if (!inFence && /^## /.test(line)) {
      sections.push(current);
      current = { heading: line.replace(/^## /, '').trim(), body: [] };
      continue;
    }
    current.body.push(line);
  }
  sections.push(current);
  return sections.map((s) => ({ heading: s.heading, body: s.body.join('\n').replace(/^\n+/, '').replace(/\n+$/, '') }));
}

// ── /command -> $skill token transform (outside code fences) ────────────
// Deterministic: every backticked /token becomes a $skill token except a
// static denylist of Claude Code harness features that are not Egregore
// skills on any runtime. Consulting the local .codex/skills directory here
// would make the rendered output depend on which instance ran the render
// (public checkouts carry fewer skills than the source repo).
const NON_SKILL_TOKENS = new Set(['loop', 'fast', 'config', 'clear', 'help']);

function transformTokens(body) {
  const lines = body.split('\n');
  let inFence = false;
  const out = lines.map((line) => {
    if (/^```/.test(line.trim())) {
      inFence = !inFence;
      return line;
    }
    if (inFence) return line;
    return line.replace(/`\/([a-z][a-z0-9-]*)((?: [^`]*)?)`/g, (match, name, args) =>
      NON_SKILL_TOKENS.has(name) ? match : `\`$${name}${args}\``
    );
  });
  return out.join('\n');
}

// ── hand-authored Codex-native section bodies ────────────────────────────
// Each is the option-b translation of the matching CLAUDE.md section. The
// manifest records the source hash so drift is caught by --check.

const INTRO_BODY = `You are a collaborator inside Egregore — a shared intelligence layer for organizations using AI coding agents. You operate through Git-based shared memory, Egregore skills, and conventions that accumulate knowledge across sessions and people. You are not a tool. You are a participant.

This block is the Codex-native Egregore behavioral spec, rendered from CLAUDE.md (the source of truth for egregore behavior) by \`bin/codex-render-spec.mjs\`. The per-section adaptation manifest is \`.codex/spec-manifest.json\`. The thin agent protocol above this block applies to every shell-capable agent; this block is the full behavioral contract for Codex sessions.`;

const ON_LAUNCH_BODY = `The \`egregore\` launcher renders the Egregore startup card (identity, handoffs, team activity) via \`bin/codex-session-start.sh\` before Codex starts, and installs project skills. Do not rerun startup checks and do not narrate startup. The card ends with **"What are you working on?"** — that question is already on screen; treat the user's first message as the answer to it. To re-show the card, run \`bash bin/codex-session-start.sh --card\`.`;

const AFTER_GREETING_BODY = `**Mandatory behavioral rule.** When the user describes work, your **first action** — before reading files, exploring code, or anything else — is to get onto a working branch:

1. Derive a topic slug from what the user said (kebab-case, 2–4 words)
2. Run \`bin/agent.sh branch --topic "<topic>"\` — it creates a work branch from \`origin/develop\` in a task worktree (\`dev/{author}/{slug}\`, or \`feature/{slug}\` / \`bugfix/{slug}\` when the topic reads as a feature or fix) and prints the worktree path. Continue all file work from that printed path.
3. Confirm: \`On {branch} (worktree).\`

**Fallback:** If \`bin/agent.sh branch\` fails, use \`git checkout -b dev/{author}/{slug} origin/develop\`.

4. Update graph (fire-and-forget): \`bash bin/graph-op.sh set-topic "$(cat .egregore-session-id 2>/dev/null)" "topic from slug" "dev/author/slug" 2>/dev/null &\`

### Handoff claiming

If \`addressed_to_user\` handoffs exist and the user is picking one up, create the IMPLEMENTS link after branch creation:
\`\`\`bash
bash bin/graph-op.sh claim-handoff "$SESSION_ID" "$HANDOFF_SESSION_ID" 2>/dev/null &
\`\`\`

**Auto-checkout repos from handoff**: After claiming, check the \`addressed_rich\` context for \`repoState\`. If the handoff includes repo state (non-empty \`repoState\` array), check out the handoff's branches in each managed repo:

\`\`\`bash
PARENT_DIR="$(cd .. && pwd)"
# For each entry in repoState:
REPO_DIR="$PARENT_DIR/$REPO_NAME"
if [ -d "$REPO_DIR/.git" ] || [ -f "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch origin "$BRANCH" --quiet 2>/dev/null
  git -C "$REPO_DIR" checkout "$BRANCH" 2>/dev/null || \\
    git -C "$REPO_DIR" checkout -b "$BRANCH" "origin/$BRANCH" 2>/dev/null
fi
\`\`\`

Report results: \`✓ Checked out {branch} in {repo1}, {repo2}\`. If a branch no longer exists (PR was merged): \`◐ {repo}: PR #{N} merged — on {base}\`. If \`repoState\` is absent or empty, skip auto-checkout silently.

**Exceptions** — skip branching when:
- The user explicitly created or named a branch themselves
- Already on a working branch AND the user's intent continues the current branch's topic

**Topic pivot while on a working branch:** If the user describes work **unrelated** to the current branch's topic, treat it as a new topic and create a new branch (\`bin/agent.sh branch --topic "<new topic>"\`). Do NOT mix unrelated work on one branch.

If on develop after two messages, create a branch immediately from whatever context you have.

### Branch-guard protocol

The \`.codex/hooks/branch-guard.js\` PreToolUse hook (enabled by the launcher via \`--enable hooks\`) protects project writes on \`develop\`/\`main\`/\`master\`. Its block message is operational guidance, not a reason to interrupt the user with routine Git choices:

- **Topic is clear** (the user said "fix X", "add Y feature") → run \`bin/agent.sh branch --topic "<topic>"\` automatically, continue in the printed worktree, and say one short sentence so the branch change is visible. Do not ask the user to approve routine branching.
- **Topic is genuinely ambiguous** → ask only for the topic, using compact numbered options:

  \`\`\`text
  What should I call this work?
    1. <suggested slug from context>
    2. <alternative slug>
    3. Other: (name it)
  \`\`\`

  Wait for the reply, then branch.
- **The user explicitly requested the protected branch** → that request is consent. Record it with \`echo '{branch}' > .egregore-branch-consent\`, then retry. Never create the marker merely to silence the hook.

Memory, managed-repo, and runtime-state writes should bypass the project guard. If one triggers it, correct the operation target/context instead of asking for protected-branch consent.

If this Codex build does not support hooks, follow the same discipline as a standing instruction: never write or commit on develop/main/master.

### Onboarding exception

If the startup card output contains \`onboarding_needed\`, invoke the \`$onboarding\` skill instead of greeting.`;

const COMMAND_AWARENESS_PREPEND = `Codex reserves leading \`/\` for built-ins, so Egregore workflows are **skills**, not slash commands. Invoke them with the matching \`$name\` skill token or from natural language intent ("show activity", "make a handoff"). Hand-written native Codex skills: \`$activity\`, \`$handoff\`, \`$wrap\`, \`$announce\`, \`$harvest\`, \`$the-spiral\`, \`$dashboard\`, \`$deep-reflect\`, \`$quest\`, \`$invite\`, \`$ask\`, \`$save\`, \`$view\`, and \`$scroll\`. Every other workflow has a generated adapter skill of the same name. \`$save\` is the user-facing abstraction for committing, pushing, opening or reusing pull requests, and syncing memory — never make users manage the git workflow by hand.`;

const SOCRATIC_BODY = `**Triggers**: "ask me questions", "question me", "help me think through", or any request to be questioned.

Codex has no structured question tool — render each batch as compact numbered questions in plain text, each with 2–4 lettered options plus an \`Other:\` line, then STOP and wait for the user's answers. Derive 2–4 context-specific questions per batch. Iteratively deepen based on answers. Converge toward decisions. After 4–5 rounds, synthesize and propose next steps. Route insights to \`$reflect\`.

**Rules:** Max 4 questions per batch. When choices aren't mutually exclusive, say "pick any that apply".`;

const ISOLATION_BODY = `Sessions are confined to this project + memory + managed repos. On Codex this boundary is a standing instruction, not an enforced hook — hold it yourself.

- **Never modify \`~/.egregore/instances.json\`** — managed by session-start.sh
- **Never access another instance's files** — refuse even if asked
- When a request points outside the boundary, do not improvise a workaround. Ask in plain text with numbered options:

  \`\`\`text
  That path is outside this Egregore's boundary. How should we proceed?
    1. Paste the contents inline
    2. Move the file into the repo and point me at the new path
    3. Cancel
  \`\`\`

See DEVELOPMENT.md §3 for boundary details.`;

// ── per-section rules ────────────────────────────────────────────────────
const RULES = {
  '(intro)': {
    action: 'replace',
    body: INTRO_BODY,
    note: 'Reframed for Codex: names AGENTS.md as the delivery surface and the manifest; "organizations using Claude Code" generalized.',
  },
  'Identity & Upstream': {
    action: 'keep',
    note: 'Kept; /update, /contribute, /save tokens rendered as $skill tokens.',
  },
  'On Launch — MANDATORY FIRST ACTION': {
    action: 'replace',
    body: ON_LAUNCH_BODY,
    note: 'Claude SessionStart hook does not run on Codex; the egregore launcher renders the card via bin/codex-session-start.sh before the session. Greeting-replay instruction dropped (card is already on screen).',
  },
  'After Greeting — BRANCH ON FIRST RESPONSE': {
    action: 'replace',
    body: AFTER_GREETING_BODY,
    note: 'EnterWorktree -> bin/agent.sh branch with git checkout fallback; AskUserQuestion -> numbered options in plain text; branch-guard mapped to .codex/hooks/branch-guard.js with instruction fallback; plan-mode note dropped (no plan mode on Codex); /branch + /onboarding -> skill tokens. Handoff claiming and repoState auto-checkout kept verbatim (pure git).',
  },
  'Config Files': { action: 'keep', note: 'Kept verbatim — shell facts, runtime-neutral.' },
  'Knowledge Graph': { action: 'keep', note: 'Kept verbatim — bin/graph.sh is runtime-neutral.' },
  'Notifications': { action: 'keep', note: 'Kept verbatim — bin/notify.sh is runtime-neutral.' },
  'Onboarding': { action: 'keep', note: 'Kept; /onboarding rendered as $onboarding.' },
  'Transparency Beat': { action: 'keep', note: 'Kept verbatim.' },
  'Memory': { action: 'keep', note: 'Kept verbatim.' },
  'Git Workflow': {
    action: 'keep',
    note: 'Kept; slash tokens rendered as $skill tokens. Branch diagram unchanged (code fence).',
  },
  'Working Conventions': { action: 'keep', note: 'Kept verbatim.' },
  'Command Awareness': {
    action: 'keep',
    prepend: COMMAND_AWARENESS_PREPEND,
    note: 'Prepended the Codex command surface (skill tokens, native vs adapter split, $save abstraction); disambiguation map kept with /x -> $x token rendering. Tokens with no Codex skill (e.g. /loop, a Claude Code harness feature) are left as-is.',
  },
  'Socratic Questioning (MANDATORY)': {
    action: 'replace',
    body: SOCRATIC_BODY,
    note: 'AskUserQuestion -> numbered plain-text question batches with explicit stop-and-wait; multiSelect -> "pick any that apply".',
  },
  'Telemetry': { action: 'keep', note: 'Kept verbatim — bin/telemetry.sh is runtime-neutral.' },
  'Mode': { action: 'keep', note: 'Kept; /env and /checkup rendered as $skill tokens.' },
  'Environment Isolation': {
    action: 'replace',
    body: ISOLATION_BODY,
    note: 'boundary-check is a Claude PreToolUse hook with no .codex equivalent — behavior stated as a standing instruction; AskUserQuestion remediation -> numbered options.',
  },
};

// ── render ───────────────────────────────────────────────────────────────
function render() {
  const claudeMd = fs.readFileSync(CLAUDE_MD, 'utf-8');
  const sections = splitSections(claudeMd);

  const manifest = [];
  const parts = [];

  for (const section of sections) {
    const rule = RULES[section.heading];
    if (!rule) {
      console.error(`codex-render-spec: no rule for CLAUDE.md section "${section.heading}" — add one to RULES in bin/codex-render-spec.mjs`);
      process.exit(1);
    }
    const sourceHash = sha(section.body);
    manifest.push({ section: section.heading, action: rule.action, sourceHash, note: rule.note });

    const heading = section.heading === '(intro)' ? '## Egregore on Codex' : `## ${section.heading}`;
    let body;
    if (rule.action === 'replace') {
      body = rule.body;
    } else {
      body = transformTokens(section.body);
      if (rule.prepend) body = `${rule.prepend}\n\n${body}`;
    }
    parts.push(`${heading}\n\n${body}`);
  }

  for (const heading of Object.keys(RULES)) {
    if (!sections.some((s) => s.heading === heading)) {
      console.error(`codex-render-spec: RULES contains "${heading}" but CLAUDE.md has no such section — remove or update the rule`);
      process.exit(1);
    }
  }

  const block = `${BEGIN}\n\n${parts.join('\n\n---\n\n')}\n\n${END}`;
  return { block, manifest };
}

// AGENTS.md is fully owned by this script: the guard preamble plus the generated
// spec block. Reconstructing it deterministically (rather than splicing into the
// existing file) guarantees the runtime-precedence guard is always present and
// correct — it cannot be stripped by an upstream sync or a hand edit.
function assembleAgentsMd(block) {
  return `${AGENTS_PREAMBLE.trim()}\n\n${block}\n`;
}

const check = process.argv.includes('--check');
const { block, manifest } = render();
const manifestJson = `${JSON.stringify({ generatedBy: 'bin/codex-render-spec.mjs', source: 'CLAUDE.md', sections: manifest }, null, 2)}\n`;

const currentAgents = fs.existsSync(AGENTS_MD) ? fs.readFileSync(AGENTS_MD, 'utf-8') : '';
const nextAgents = assembleAgentsMd(block);

const CODEX_DOC_BUDGET = 32 * 1024;
if (Buffer.byteLength(nextAgents, 'utf-8') > CODEX_DOC_BUDGET) {
  console.error(`codex-render-spec: AGENTS.md would be ${Buffer.byteLength(nextAgents, 'utf-8')} bytes — over Codex's ${CODEX_DOC_BUDGET}-byte project-doc budget. Trim CLAUDE.md or tighten translations.`);
  process.exit(1);
}

if (check) {
  const currentManifest = fs.existsSync(MANIFEST) ? fs.readFileSync(MANIFEST, 'utf-8') : '';
  const stale = nextAgents !== currentAgents || manifestJson !== currentManifest;
  if (stale) {
    console.error('codex spec out of date — run: node bin/codex-render-spec.mjs');
    process.exit(1);
  }
  console.log('codex spec up to date');
} else {
  fs.writeFileSync(AGENTS_MD, nextAgents);
  fs.writeFileSync(MANIFEST, manifestJson);
  console.log(`codex spec rendered: AGENTS.md (${Buffer.byteLength(nextAgents, 'utf-8')} bytes), .codex/spec-manifest.json (${manifest.length} sections)`);
}
