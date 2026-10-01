---
name: handoff
description: "Create an internal Egregore team handoff to a teammate or future self. Use when the user says /handoff, asks to pass work or context, or wants an operational continuation record. Route external or executable capsules to /emissary, pending-work triage to /activity, and personal closure to /wrap."
---

# Internal team handoff

Create one typed handoff in `memory/handoffs/`. Canonical Markdown and Git
provenance are authoritative. Runtime owns authorization, stable identity,
persistence, provenance, retrieval refresh, background embedding, and
content-free telemetry.

Use this only for internal handoffs. Route external capsules to `/emissary`,
pending-work triage to `/activity`, and personal closure to `/wrap`.

## When to invoke

Create an internal Egregore team handoff to a teammate or future self. Use when the user says /handoff, asks to pass work or context, or wants an operational continuation record. Route external or executable capsules to /emissary, pending-work triage to /activity, and personal closure to /wrap.

## Bounded capture

A handoff records known context; it is not a research, audit, planning, or
verification ritual.

- Use the user's prompt, current conversation, and attached
  `EGREGORE_ORG_CONTEXT_V1`. When that context is attached, do not repeat
  organizational retrieval.
- If no organizational context is attached and the requested handoff
  semantically depends on prior organizational work that is absent from the
  conversation, follow the actor context's one Runtime/QMD recall instruction.
  This is the only allowed retrieval: use its returned evidence without a
  second query or opening more sources.
- Do not otherwise search, inspect Git, read repository files, query
  migration/skill manifests, run status/tests, or spawn agents to improve the
  handoff.
- Include branches, files, decisions, tests, and remaining work only when
  already known from those inputs. Label uncertainty briefly; if the handoff
  cannot be drafted responsibly, ask one focused question instead of exploring.
- “To myself” resolves to `Actor display name` in the attached
  `EGREGORE_ACTOR_CONTEXT_V1`. Never infer it from the OS username, Git, or
  GitHub. If that block is unavailable, ask for the handle rather than
  guessing. Do not perform a people-directory lookup. Ask once only for a
  genuinely ambiguous teammate.
- Infer `intent`: `action`, `feedback`, or `fyi`.

Before approval, use at most one optional Runtime/QMD recall command, followed
by the preview command below.
After approval, use exactly one shell command: writeback plus card rendering.
Do not perform notification or publication work unless separately requested.

## Canonical Markdown

Use this envelope:

```markdown
---
capture_schema: egregore-capture/v1
capture_mode: addressed
kind: addressed
from: <actor handle>
addressed_to: <recipient, if known>
date: YYYY-MM-DD
topic: <topic>
intent: <action | feedback | fyi>
content_mode: <supplied | generated>
claim: <one-line current state>
ask: <what the receiver should do>
---

<canonical handoff body>
```

Preserve supplied wording, order, headings, lists, code, and links. For
generated content, use only the useful subset of Briefing, Current State, Open
Threads, and Next Steps. Keep it operational and concise.

## Staircase (staging)

A second face for addressed handoffs exists: the staircase, a
progressive-disclosure page the receiver walks one step at a time and closes
with a readback (docs/specs/handoff-staircase.md). It is in staging and does
not change this skill. When the user asks for a staircase and this instance
has the staging command (.claude/skills/handoff-staircase/SKILL.md, Codex: the
handoff-staircase adapter; internal to Curve Labs while in staging), route to
it: it reuses this preview and approval bridge with a composed spec and adds
one feedback question at the end. Without it, say the staircase is not
installed here and continue with this skill. When its feedback
promotes it, the staircase becomes the default here and that command retires.

## One-command preview

Write the exact canonical Markdown to
`tmp/handoff-body.md`, then pass it once to the private preview bridge. It stores
the approved bytes in an OS-private, short-lived record and returns an opaque
`HANDOFF_PREVIEW_TOKEN`. Retain that token for the approval turn. Do not create
other checkout or draft files yourself. The bridge renders with `--verify-fidelity`.
If the renderer reports that its local dependencies are missing, stop and
report that prerequisite. Never install packages or repeat the full preview
command inside the handoff workflow.

Write this body:

```markdown
<exact canonical Markdown>
```

Use `{author}`, `{recipient}`, `{topic}`, `{intent}`, and `{content-mode}` from
the `from`, `addressed_to`, `topic`, `intent`, and `content_mode` fields in
`tmp/handoff-body.md`, respectively; write any single quote inside a value as
`'\''`.

```bash
bash bin/handoff-preview.sh preview \
  --author '{author}' --recipient '{recipient}' --topic '{topic}' \
  --intent '{intent}' --content-mode '{content-mode}' < tmp/handoff-body.md
```

Show the browser preview and wait for approval unless explicitly waived.
Preview is not canonical writeback. Preview approval is not sharing consent.

## One-command approval

After approval, submit only the opaque token returned by preview. Never replay,
regenerate, or include the canonical Markdown in the approval command. The
bridge consumes the exact previewed bytes, performs one Runtime transaction,
and renders the deterministic result card in the same invocation:

```bash
bash bin/handoff-preview.sh approve "<HANDOFF_PREVIEW_TOKEN>"
```

The token is private, expires after six hours, and is consumed after a
successful canonical write. Do not add a cleanup trap or recursive deletion to
the approved command; the bridge manages only its exact private records.

Omit `--recipient` from the preview command only for an unaddressed
continuation. Runtime performs authorize → canonical persist → Git provenance
→ retrieval update → background embed → telemetry. The result card is the
command's stdout and is already fully visible there, canonical `memory/...`
path included — it must appear exactly once in the conversation. Never copy,
re-render, summarize, or repeat it in your reply. Do not print raw JSON.
Do not run a second save or manage Git, QMD, graph, publication, or
notification.

If writeback fails, report the concise error and stop. External sharing is a
separate `SHARE` action requiring an explicit user request and exact
destination/payload approval.
