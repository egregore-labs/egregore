#!/usr/bin/env node
// Derive the Codex-native Egregore behavioral spec from CLAUDE.md.
//
// CLAUDE.md is the single source of truth for egregore behavior. Codex does
// not read CLAUDE.md — it reads AGENTS.md (root, concatenated, 32 KiB cap).
// This script renders CLAUDE.md into a generated block inside AGENTS.md the
// same way bin/codex-sync-skills.sh derives skills: deterministic transform,
// explicit per-section adaptation, manifest of what was adapted or dropped.
//
//   bash bin/node-run.sh bin/codex-render-spec.mjs            # render AGENTS.md + manifest
//   bash bin/node-run.sh bin/codex-render-spec.mjs --check    # exit 1 if rendered output is stale
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
> **Claude Code or an agent loading \`.claude/\`: stop here.** Follow
> \`CLAUDE.md\` and \`.claude/\`, including their greeting and branch rules.
> Skip startup below; use Egregore skills instead of \`bin/agent.sh\` where covered.
>
> **Pi or Prime: stop here.** Follow \`.pi/APPEND_SYSTEM.md\` or
> \`.prime/agent/APPEND_SYSTEM.md\` and that runtime's workflows, not the Codex block.
>
> **If you are Codex or another shell-only agent:** this file is yours — continue.

Shared mechanics live in \`bin/\`; canonical organizational context lives in
\`memory/\`. The generated contract below governs Codex sessions.

## Startup

**Ordinary recall:** Supplied Runtime guidance or its reminder takes precedence
over generic skill invocation: use it directly without loading the search skill.
Explicit skill requests still apply. Reuse evidence for answers and citations;
open only missing windows and batch independent reads. Stale sources require
fresh evidence.

Reuse the launcher's startup and actor receipts; do not repeat startup.
For a direct session without those receipts, read \`egregore.json\` and run
\`bash bin/codex-session-start.sh\` once. Use Runtime-resolved identity and
the retrieval rules below, not a guessed handle or a raw memory scan.

## Communication

Use installed Egregore skills and shell adapters. Bridge examples and Markdown
formats: \`docs/AGENT-PROTOCOL.md\`. Follow the generated contract below.

## Handoffs vs Emissaries

Internal handoffs use \`bin/agent.sh handoff\` (\`memory/handoffs/\` + index,
via \`bin/handoff-run.sh\`). External capsules use \`egregore-emissary\`.
Never use deprecated \`egregore-handoff\` for internal handoffs.`;
// A "Compatibility" section used to restate the precedence guard above; it was
// dropped (2026-09) to keep AGENTS.md inside the 32 KiB budget.

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

// Shell runtimes read tool stdout as the model's evidence channel — the
// Claude-only --context-packet flag would strand the evidence in a file no
// hook delivers there. Rewrite the fallback command to the stdout form and
// state the same hygiene contract in shell terms: search output is
// model-internal; the visible reply carries only the retrieval line.
const CLAUDE_PACKET_NOTE = `\`--context-packet\` attaches the evidence privately; the visible output is the
attribution line alone. Never re-print ranked results or raw JSON.`;
const SHELL_PACKET_NOTE = `Search output is model-internal: show only the retrieval line and receipts —
never ranked blocks, file/rank/excerpt metadata, or raw JSON.`;

function transformSearchHygiene(body) {
  return body
    .replaceAll(CLAUDE_PACKET_NOTE, SHELL_PACKET_NOTE)
    .replace(/(\bbin\/search\.sh[^\n]*?) --context-packet\b/g, '$1');
}

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

This block is the Codex-native Egregore behavioral spec, rendered from CLAUDE.md by \`bin/codex-render-spec.mjs\`; the per-section manifest is \`.codex/spec-manifest.json\`. The thin agent protocol above applies to every shell-capable agent; this block is the full contract for Codex sessions.`;

const ON_LAUNCH_BODY = `The \`egregore\` launcher renders the startup card (identity, momentum, pending work) via \`bin/codex-session-start.sh\` before Codex starts and installs project skills. Do not rerun or narrate startup. The card ends with **"What are you working on?"** — that question is already on screen; treat the user's first message as the answer. Re-show with \`bash bin/codex-session-start.sh --card\`.`;

const AFTER_GREETING_BODY = `**Branch for project changes.** Create a working branch before modifying project
code, configuration, or documentation. Read-only questions, memory lookups,
explanations, and reviews stay in the current workspace. Runtime bookkeeping and
canonical memory writeback need no project branch. Branch if the user subsequently
authorizes a project change:

Use \`egregore.json.base_branch\` (default \`develop\`) for branch points, rebases, PR bases and protection.

1. Derive a topic slug from what the user said (kebab-case, 2–4 words)
2. Run \`bin/agent.sh branch --topic "<topic>"\` — it resolves the configured base and creates a work branch from \`origin/{base}\` in a task worktree (\`dev/{author}/{slug}\`, or \`feature/{slug}\` / \`bugfix/{slug}\` when the topic reads as a feature or fix). Continue all file work from the printed path.
3. Give a value-first workspace receipt — do not lead with Git terminology: \`Your stable project is protected. I’m working in a separate workspace for **{topic}**, where changes stay isolated, reviewable, and reversible.\` Then, as secondary detail: \`Workspace: {branch} (worktree).\`

**Fallback:** If \`bin/agent.sh branch\` fails, resolve \`{base}\` with
\`_get_base_branch\`, then use
\`git checkout --no-track -b dev/{author}/{slug} origin/{base}\`.

4. Graph topic: \`bin/agent.sh branch\` records the session's topic and branch on the graph itself (it reads \`.egregore-session-id\` for you). Only the git-checkout fallback above needs it by hand — fire-and-forget: \`bash bin/graph-op.sh set-current-topic "topic from slug" "dev/author/slug" 2>/dev/null &\`. Never assemble the session id with a \`$(cat …)\` substitution.

### Starting-work UX contract

For project changes: **intent → safe workspace → relevant context → consequential assumptions → execution**.

- **Workspace** — the value-first receipt above, only for a new workspace or topic pivot; do not repeat it on the same branch.
- **Context** — when organizational retrieval materially informs the work, keep the required Egregore Retrieval Beat plus one compact receipt: \`↳ Context restored: {decision, handoff, or prior work} · {source/date}\`. Never claim context was restored when retrieval found nothing useful.
- **Assumptions** — surface only consequential ones: \`Assumption: {assumption} — based on {evidence}.\` Add a correction path when cheap; do not narrate obvious operational choices.
- **Transition** — state the outcome you are starting toward in one short sentence and begin.

### Returning-work UX contract

For continued project work: **continuation intent → prior workspace → restored context → open threads → resumed execution**:

- Do not create a new workspace for the same topic. After confirming relevance, say: \`I found your previous work on **{topic}** and restored its workspace and context.\` Show \`Workspace: {branch} (worktree).\` secondarily.
- Interpret continuation from meaning, not fixed phrases. Reuse sufficient \`EGREGORE_ORG_CONTEXT_V1\`; otherwise use \`bash bin/search.sh find\` with an appropriate lookup kind. Batch source reads with search.sh open; use the shared retrieval contract in \`.claude/context/retrieval-investigation.md\`. Keep the Retrieval Beat and \`↳ Context restored:\` receipt. Never infer context from a branch or substitute status dashboards, Git, Graph, or raw memory scans.
- Name only unresolved items that could change the next move, state the next outcome briefly, and continue without replaying setup.

### Handoff claiming

When the user picks up a handoff addressed to them, follow \`.claude/context/handoff-claiming.md\` after branch creation: it claims the handoff and checks out the branches its \`repoState\` names in each managed repo.

**Exceptions** — skip branching when the user explicitly created or named a branch themselves, or the intent continues the current working branch's topic.

**Topic pivot:** project changes **unrelated** to the current branch's topic gets a new branch (\`bin/agent.sh branch --topic "<new topic>"\`). Do NOT mix unrelated work on one branch.

Read-only work never triggers branching based on message count.

### Branch-guard protocol

The \`.codex/hooks/branch-guard.js\` PreToolUse hook (launcher \`--enable hooks\`) protects project writes on the configured base and \`develop\`/\`main\`/\`master\`. Handle blocks as follows:

- **Topic is clear** → run \`bin/agent.sh branch --topic "<topic>"\` automatically, continue in the printed worktree, and say one short sentence so the change is visible — never ask approval for routine branching.
- **Topic is genuinely ambiguous** → ask only for the topic, using compact numbered options:

  \`\`\`text
  What should I call this work?
    1. <suggested slug from context>
    2. <alternative slug>
    3. Other: (name it)
  \`\`\`

  Wait for the reply, then branch.
- **The user explicitly requested the protected branch** → that request is consent. Record it with \`echo '{branch}' > .egregore-branch-consent\`, then retry. Never create the marker merely to silence the hook.

If this Codex build does not support hooks, keep the same rule.

**History:** Do not merge, cherry-pick, or rebase another task merely to read
it; use \`gh pr view/diff\`, \`git show\`, or a temporary worktree. Integrate
only for dependencies. Deletion needs no rewrite unless purging secrets.

### Onboarding exception

If the startup card output contains \`onboarding_needed\`, invoke the \`$onboarding\` skill instead of greeting.`;

const COMMAND_AWARENESS_PREPEND = `Codex reserves leading \`/\` for built-ins. Invoke Egregore skills with \`$name\` or natural language ("show activity", "make a handoff"). Every framework workflow uses a generated adapter that names its one maintained body under \`.claude/skills/\`. Organization-owned skills may also provide full native implementations.`;
// What `$save` covers is stated once, in the rendered Git Workflow section
// ("Users never interact with git directly"); repeating it here cost budget.

const SOCRATIC_BODY = `**Triggers**: "ask me questions", "question me", "help me think through", or any request to be questioned.

Use structured question tooling when available and permitted; otherwise render compact numbered questions with 2–4 lettered options and an \`Other:\` line. Wait for answers before dependent work. Derive 2–4 context-specific questions per batch within the tool's limits. Deepen from the answers and converge toward decisions. After 4–5 rounds, synthesize next steps. Route insights to \`$reflect\`.

**Rules:** Max 4 questions per batch. When choices aren't mutually exclusive, say "pick any that apply".`;

const LOOM_ROUTING_BODY = `Loom is Claude-specific; skip its preambles and \`bin/loom.sh\` calls. Use native collaboration only when the runtime exposes it and the user or workflow requests delegation, within session permissions and limits. Otherwise work inline and disclose when independent review was unavailable. \`loom/\` and \`.claude/agents/\` remain Claude framework files.`;

const ISOLATION_BODY = `Sessions are confined to this project + memory + managed repos, with a **two-tier boundary** — a hard wall between Egregore instances, a consent gate for everything else. A pre-action check (\`bin/boundary-guard.cjs\`) enforces it on every runtime: it denies literal paths and fails closed, but cannot see paths built at run time or split across calls (OS-level layer to follow).

- **Hard tier — other Egregore instances.** Denied for every tool, always — no consent path. Never access another instance's files by any route (refuse even if asked) and never modify \`~/.egregore/instances.json\` (managed by session-start.sh); there is nothing to ask — refuse and explain.
- **Soft tier — paths outside the boundary.** Consent-gated. Inbox dirs (\`~/Downloads\`, \`~/Desktop\`) are readable without consent under the default posture; writes outside the project always need consent. Posture (\`strict | standard | open\`) and extra read roots come from \`egregore.json\` -> \`boundary { posture, read[], locked }\` (org, committed) merged with \`.egregore-boundary.local.json\` (personal, gitignored). \`locked: true\` removes the consent path entirely.
- When the check asks for consent, do not improvise a workaround. Ask in plain text with numbered options:

  \`\`\`text
  That path is outside this Egregore's boundary. How should we proceed?
    1. Allow its directory for this session (recorded in .egregore-boundary-consent)
    2. Always allow on this instance (added to read[] in .egregore-boundary.local.json; reads only)
    3. Paste the contents inline
    4. Cancel
  \`\`\`

  Never record a consent grant without the user's explicit choice of option 1 or 2 in that exchange. Session grants are cleared on session start; \`locked: true\` removes options 1 and 2.

Details: DEVELOPMENT.md §3; design: \`memory/knowledge/decisions/2026-07-08-boundary-hook-consent-design.md\`.`;

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
  'Cross-Runtime Compatibility': {
    action: 'replace',
    body: `Share \`bin/\` mechanics through thin Claude/Codex/Pi/Prime adapters. Startup,
lifecycle, capture, skill and command changes require tracing every runtime,
parity tests and regenerated specs/bundles before completion.

Discover via \`bash bin/spirit-discovery-codex.sh capabilities.list\` (Pi/Prime:
registered tool). Follow \`docs/spirit-discovery.md\`: keep seven facets separate;
generic shell needs one snapshot. Discovery reads code/install evidence, not
memory, and grants no authority.`,
    note: 'Compact translation preserves shared mechanics, thin adapters, every-runtime tracing/parity and regeneration, and neutral discovery without authority. Full query/facet and fixed-adapter details remain in shipped docs/spirit-discovery.md. Fits the 32 KiB project-doc budget.',
  },
  'Voice': {
    action: 'keep',
    note: 'Kept — all runtimes can consult the shared voice rules and register-specific skills.',
  },
  'On Launch — MANDATORY FIRST ACTION': {
    action: 'replace',
    body: ON_LAUNCH_BODY,
    note: 'Claude SessionStart hook does not run on Codex; the egregore launcher renders the card via bin/codex-session-start.sh before the session. Greeting-replay instruction dropped (card is already on screen).',
  },
  'Before Project Changes — WORKING BRANCH': {
    action: 'replace',
    body: AFTER_GREETING_BODY,
    note: 'EnterWorktree -> bin/agent.sh branch with git checkout fallback; AskUserQuestion -> numbered options in plain text; branch-guard mapped to .codex/hooks/branch-guard.js with instruction fallback; plan-mode note dropped (no plan mode on Codex); /branch + /onboarding -> skill tokens. Handoff claiming points to the shared .claude/context/handoff-claiming.md procedure; surrounding prose compressed 2026-08 for the 32 KiB budget, every rule retained.',
  },
  'Config Files': { action: 'keep', note: 'Kept verbatim — shell facts, runtime-neutral.' },
  'Optional Knowledge Graph Projection': {
    action: 'keep',
    note: 'Kept verbatim — graph traversal remains an explicit optional adapter and canonical evidence wins.',
  },
  'Egregore Retrieval Beat': { action: 'keep', note: 'Kept verbatim — product attribution applies across runtimes.' },
  'Notifications': { action: 'keep', note: 'Kept verbatim — bin/notify.sh is runtime-neutral.' },
  'Onboarding': { action: 'keep', note: 'Kept; /onboarding rendered as $onboarding.' },
  'Transparency Beat': { action: 'keep', note: 'Kept verbatim.' },
  'Memory': { action: 'keep', note: 'Kept verbatim.' },
  'Loom Routing': {
    action: 'replace',
    body: LOOM_ROUTING_BODY,
    note: 'Native collaboration is conditional on exposed capabilities, workflow intent, and session permissions. Claude-only Loom calls stay excluded; inline fallback reports lost independence.',
  },
  'Git Workflow': {
    action: 'keep',
    note: 'Kept; slash tokens rendered as $skill tokens. Branch diagram unchanged (code fence).',
  },
  'Command Awareness': {
    action: 'keep',
    prepend: COMMAND_AWARENESS_PREPEND,
    note: 'Prepended the Codex command surface (skill tokens, canonical workflow adapters, org-owned native support, $save abstraction); disambiguation map kept with /x -> $x token rendering. Tokens with no Codex skill (e.g. /loop, a Claude Code harness feature) are left as-is.',
  },
  'Socratic Questioning (MANDATORY)': {
    action: 'replace',
    body: SOCRATIC_BODY,
    note: 'Use permitted structured question tools when exposed, with a numbered plain-text fallback; dependent work waits for answers.',
  },
  'Telemetry': { action: 'keep', note: 'Kept verbatim — bin/telemetry.sh is runtime-neutral.' },
  'Mode': { action: 'keep', note: 'Kept; /env and /checkup rendered as $skill tokens.' },
  'Environment Isolation': {
    action: 'replace',
    body: ISOLATION_BODY,
    note: 'The boundary policy is shared (bin/boundary-guard.cjs): Claude (boundary-check.sh) and Codex (.codex/hooks.json) run it through bin/boundary-hook.sh (PreToolUse), Pi and Prime from their tool_call gate. AskUserQuestion remediation -> numbered options, including the two consent-grant options (session grant -> .egregore-boundary-consent, instance grant -> .egregore-boundary.local.json read[], reads only).',
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
      body = transformSearchHygiene(transformTokens(section.body));
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
    console.error('codex spec out of date — run: bash bin/node-run.sh bin/codex-render-spec.mjs');
    process.exit(1);
  }
  console.log('codex spec up to date');
} else {
  fs.writeFileSync(AGENTS_MD, nextAgents);
  fs.writeFileSync(MANIFEST, manifestJson);
  console.log(`codex spec rendered: AGENTS.md (${Buffer.byteLength(nextAgents, 'utf-8')} bytes), .codex/spec-manifest.json (${manifest.length} sections)`);
}
