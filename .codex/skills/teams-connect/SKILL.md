---
name: teams-connect
description: 'Set up Microsoft Teams as a notification channel for your Egregore — registers an Azure bot, uploads the app, and binds a channel. Use for /teams-connect, ''connect teams'', or ''set up teams notifications''.'
---

<!-- generated-by: bin/codex-sync-skills.sh -->

# Egregore teams-connect Adapter

This adapter runs the canonical Egregore workflow for `teams-connect`. Its one
maintained body is `.claude/skills/teams-connect/SKILL.md`; read that file completely and follow it here.

Use the project shell and filesystem directly. Do not invoke Claude Code
commands. Translate interactive choices to structured Codex question tooling
when it is available; otherwise render compact numbered choices with an
`Other:` option and wait for the user.

1. Read `.claude/skills/teams-connect/SKILL.md` for the workflow details.
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
