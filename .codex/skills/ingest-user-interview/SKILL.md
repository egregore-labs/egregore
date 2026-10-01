---
name: ingest-user-interview
description: 'Analyze a user interview from Granola, pasted text, or a file into an evidence-backed briefing, journey insights, product findings, patterns, and actions. Use for /ingest user-interview, onboarding interviews, research calls, or requests to process user feedback.'
---

<!-- generated-by: bin/codex-sync-skills.sh -->

# Egregore ingest-user-interview Adapter

This adapter runs the canonical Egregore workflow for `ingest-user-interview`. Its one
maintained body is `.claude/skills/ingest-user-interview/SKILL.md`; read that file completely and follow it here.

Use the project shell and filesystem directly. Do not invoke Claude Code
commands. Translate interactive choices to structured Codex question tooling
when it is available; otherwise render compact numbered choices with an
`Other:` option and wait for the user.

## Structured UX parity

This workflow has a Claude skill with user-visible structured output. After
reading `.claude/skills/ingest-user-interview/SKILL.md`, reproduce the same visible UX in Codex:

- Preserve TUI boxes, markdown tables, rich cards, browser artifact rendering,
  exact confirmation blocks, and "no preamble" rules from the source skill.
- Use the source skill's frame width, section order, labels, status footer,
  and examples as the contract for the final response.
- Never replace a required box/table/card/artifact view with a prose summary
  unless the user explicitly asks for a summary.
- When the source says to output a TUI box directly, paste that box as the
  visible response, preferably in a `text` fenced block.
- If the canonical body says the command's stdout is the card and must not
  be repeated, that rule assumes a host that displays command output in full;
  in Codex, paste the card once as the visible response in a `text` fenced
  block and do not print it a second time.
- Never show raw JSON, raw command output, or unformatted script output when
  the source skill requires formatted status or rendered output.

1. Read `.claude/skills/ingest-user-interview/SKILL.md` for the workflow details.
2. Run the referenced `bin/` scripts directly from Codex.
3. Treat graph and publish steps as best-effort unless that workflow explicitly
   says they are required.
4. For every external notification, follow
   `.claude/context/notification-consent.md`: plan without sending, then show
   a separate exact Send / Edit / Cancel checkpoint. Never infer notification
   consent from the workflow request or a batch approval.
5. Keep local-mode behavior filesystem-first and avoid graph or notification
   calls when `egregore.json` declares `"mode": "local"`.
6. Never call the deprecated `egregore-handoff` CLI for Egregore project
   handoffs.
