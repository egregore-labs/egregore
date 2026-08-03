---
name: handoff
description: Create an internal Egregore team handoff when the user invokes /handoff or $handoff, asks to hand off work, or wants to pass context to a teammate or future self.
---

# Egregore Handoff

Native Codex Egregore skill. This creates an internal team handoff in
`memory/handoffs/`, indexes it, publishes it when possible, and may prepare an
external notification proposal. External runnable packets are emissaries; if the user
asks for one or provides an `egregore.xyz/emissary/e/` link, use the emissary
tooling instead.

`/handoff` is pure addressed capture. Do not triage incoming handoffs here;
route “show/close my handoffs” to `$activity`. Personal session closure without
an addressed recipient belongs to `$wrap`.

## Flow

1. Run `bin/agent.sh sync`.
2. Resolve the author from `.egregore-state.json` `github_username`, then
   `name`, then git config.
3. Parse a short topic and optional recipient from the user request. Match the
   recipient against `memory/people/*.md`; omit the recipient when uncertain.
4. Classify the content before drafting:
   - **Supplied content**: the user pasted substantial prose, supplied a
     document, or approved exact wording. Preserve wording, order, headings,
     lists, code, and links. Add only capture frontmatter with
     `content_mode: supplied`. Do not create a composed JSON or attach session
     artifacts unless the user asks.
   - **Generated content**: the user supplied only a topic or fragmentary
     notes. Draft the canonical markdown record with these sections:
     - `## Briefing`
     - `## Key Decisions`
     - `## Current State`
     - `## Open Threads`
     - `## Next Steps`
     - `## Entry Points`
   Use this metadata contract even when the user supplied only prose:

```markdown
---
capture_schema: egregore-capture/v1
capture_mode: addressed
kind: addressed
from: <author>
addressed_to: <recipient, if any>
date: YYYY-MM-DD
topic: <topic>
intent: <action | feedback | fyi>
content_mode: <supplied | generated>
claim: <one-line claim>
ask: <what the receiver should do>
---
```

5. Build the preview. For supplied content, render the Markdown directly
   through the native handoff renderer and verify fidelity:

```bash
node packages/egregore-artifacts/bin/cli.js handoff "$BODY_FILE" \
  --verify-fidelity
```

   For generated content, compose the HTML view from that record. Markdown is
   canonical; the JSON is
   only a presentation map. Give every JSON section a stable `id` and add a
   top-level `sourceMap` from every authored `##` heading to the section that
   contains its complete text:

```json
{
  "kind": "handoff",
  "kicker": "Handoff",
  "topic": "<topic>",
  "claim": "<one-line claim>",
  "sourceMap": {
    "Briefing": "briefing",
    "Key Decisions": "decisions",
    "Current State": "current-state",
    "Open Threads": "open-threads",
    "Next Steps": "next-steps",
    "Entry Points": "entry-points"
  },
  "sections": [
    {"id":"briefing","label":"Briefing","component":"prose","body":"<complete Briefing text>"}
  ]
}
```

   Pick richer components when they fit, but copy all authored content into
   the mapped destination. Never independently summarize the Markdown into the
   JSON. For command-heavy sections, keep command headings, explanatory text,
   fenced commands, and expected output verbatim.

   Render generated content with semantic coverage enabled:

```bash
node packages/egregore-artifacts/bin/cli.js composed "$COMPOSED_FILE" \
  --source "$BODY_FILE" --verify-fidelity
```

6. Show the actual browser HTML before publishing. This is the approval
   surface—not a list of component names.

   Stop for confirmation after the browser preview. If validation fails, fix
   the mapping/content and render again. Skip confirmation only when the user
   explicitly said to send without preview.

7. After confirmation, run one orchestration command:

```bash
TMPDIR="$(mktemp -d -t codex-handoff-XXXXXX)"
TMPDIR="$TMPDIR" bash bin/capture-run.sh --mode addressed --author "$AUTHOR" \
  --topic "$TOPIC" ${RECIPIENT_ARG} --content-mode "$CONTENT_MODE" \
  ${COMPOSED_ARG} < "$BODY_FILE"
```

Use `COMPOSED_ARG=(--composed "$COMPOSED_FILE")` only for generated content.

Use `--recipient "$RECIPIENT"` only when a clear teammate or future-self
recipient is known. Do not pass `--no-publish` unless the user explicitly
asked for a dry run. The runner may plan a notification, but never dispatches.

8. Read `$TMPDIR/handoff-run-result.json` and render:

```bash
node bin/codex-skill-render.mjs handoff-card "$TMPDIR/handoff-run-result.json"
```

Paste the rendered card exactly in the visible response, preferably in a
`text` fenced block. Do not paraphrase the card into bullets unless the user
asks for a summary.

9. If the result has `notifyStatus: "approval_required"`, follow
   `.claude/context/notification-consent.md`. In a separate checkpoint, show
   the exact organization, recipient/group, every channel/delivery, and exact
   message from `notifyPlan`; offer Send / Edit / Cancel and wait. Only a Send
   response to that preview permits one `approve` + `dispatch`. A local direct
   message never falls back to a group.

10. Fire the detached save helper when appropriate:

```bash
( bash bin/handoff-save-egregore.sh "$AUTHOR" "$TOPIC" >/dev/null 2>&1 & ) >/dev/null 2>&1
```

11. Report the `memory/...` path and hosted link from the result JSON when a
   link exists.

## Rules

- Do not call `egregore-handoff` for project handoffs.
- Do not use Claude Code commands.
- Keep the briefing concise and operational; include exact files, branches,
  commands, open questions, and verification state when relevant.
- Supplied content is authoritative. Do not replace it with a session summary,
  presentation JSON, related artifacts, or repo state.
- The artifact is a view of the handoff, never a summary of it. Publishing
  must fail when any non-empty authored section is unmapped or loses content.
- Structured UX parity is required: the rendered card is the acknowledgment.
  Do not add a preamble such as "Handoff created successfully." Preserve the
  72-column TUI/card shape, status footer, links below the box, and warning
  placement used by the Egregore handoff workflow.
- Creating or approving the handoff is not notification consent. Never approve
  or dispatch from detached work.
