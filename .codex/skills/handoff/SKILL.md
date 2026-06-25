---
name: handoff
description: Create an internal Egregore team handoff when the user invokes /handoff or $handoff, says they are done, asks to hand off work, or wants to pass context to a teammate or future self.
---

# Egregore Handoff

Native Codex Egregore skill. This creates an internal team handoff in
`memory/handoffs/`, indexes it, publishes it when possible, and notifies through
the Egregore scripts. External runnable packets are emissaries; if the user
asks for one or provides an `egregore.xyz/emissary/e/` link, use the emissary
tooling instead.

## Flow

1. Run `bin/agent.sh sync`.
2. Resolve the author from `.egregore-state.json` `github_username`, then
   `name`, then git config.
3. Parse a short topic and optional recipient from the user request. Match the
   recipient against `memory/people/*.md`; omit the recipient when uncertain.
4. Draft the markdown body with these sections:
   - `## Briefing`
   - `## Key Decisions`
   - `## Current State`
   - `## Open Threads`
   - `## Next Steps`
   - `## Entry Points`
5. Write the body to a temp file, then run one orchestration command:

```bash
TMPDIR="$(mktemp -d -t codex-handoff-XXXXXX)"
TMPDIR="$TMPDIR" bash bin/handoff-run.sh --author "$AUTHOR" --topic "$TOPIC" ${RECIPIENT_ARG} < "$BODY_FILE"
```

Use `--recipient "$RECIPIENT"` only when a clear teammate or future-self
recipient is known. Do not pass `--no-publish` or `--no-notify` unless the user
explicitly asked for a dry run.

6. Read `$TMPDIR/handoff-run-result.json` and render:

```bash
node bin/codex-skill-render.mjs handoff-card "$TMPDIR/handoff-run-result.json"
```

Paste the rendered card exactly in the visible response, preferably in a
`text` fenced block. Do not paraphrase the card into bullets unless the user
asks for a summary.

7. Fire the detached save helper when appropriate:

```bash
( bash bin/handoff-save-egregore.sh "$AUTHOR" "$TOPIC" >/dev/null 2>&1 & ) >/dev/null 2>&1
```

8. Report the `memory/...` path and hosted link from the result JSON when a
   link exists.

## Rules

- Do not call `egregore-handoff` for project handoffs.
- Do not use Claude Code commands.
- Keep the briefing concise and operational; include exact files, branches,
  commands, open questions, and verification state when relevant.
- Structured UX parity is required: the rendered card is the acknowledgment.
  Do not add a preamble such as "Handoff created successfully." Preserve the
  72-column TUI/card shape, status footer, links below the box, and warning
  placement used by the Egregore handoff workflow.
