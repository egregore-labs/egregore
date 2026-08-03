---
name: reflect
description: 'Fallback Codex adapter for the Egregore reflect workflow.'
---

<!-- generated-by: bin/codex-sync-skills.sh -->

# Egregore reflect Adapter

This is fallback coverage for a long-tail Egregore workflow that has not been
ported to a hand-written Codex-native skill yet.

Use the project shell and filesystem directly. Do not invoke Claude Code
commands. Translate interactive choices to structured Codex question tooling
when it is available; otherwise render compact numbered choices with an
`Other:` option and wait for the user.

## Structured UX parity

This workflow has a Claude skill with user-visible structured output. After
reading `.claude/skills/reflect/SKILL.md`, reproduce the same visible UX in Codex:

- Preserve TUI boxes, markdown tables, rich cards, browser artifact rendering,
  exact confirmation blocks, and "no preamble" rules from the source skill.
- Use the source skill's frame width, section order, labels, status footer,
  and examples as the contract for the final response.
- Never replace a required box/table/card/artifact view with a prose summary
  unless the user explicitly asks for a summary.
- When the source says to output a TUI box directly, paste that box as the
  visible response, preferably in a `text` fenced block.
- Never show raw JSON, raw command output, or unformatted script output when
  the source skill requires formatted status or rendered output.

1. Read `.claude/skills/reflect/SKILL.md` for the workflow details.
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
