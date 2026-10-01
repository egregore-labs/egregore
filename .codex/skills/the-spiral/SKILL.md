---
name: the-spiral
description: 'A generative epistemology engine that transforms intuitions into rigorous, communicable output through structured Socratic dialogue. Use this skill whenever someone needs to develop, pressure-test, and articulate a complex thesis — fundraising materials, book proposals, product strategy, research agendas, organizational philosophy, policy design, or any context requiring deep structured thinking. Triggers on: ''let''s think through'', ''help me articulate'', ''pressure test this'', ''develop this thesis'', ''spiral'', ''deep exploration'', ''Socratic'', or any request to go from intuition to rigorous output. Also triggers when a user has a strong conviction but can''t yet articulate it clearly, or when they need to prepare materials that require deep domain understanding (pitch decks, memos, strategy docs, proposals).'
---

<!-- generated-by: bin/codex-sync-skills.sh -->

# Egregore the-spiral Adapter

This adapter runs the canonical Egregore workflow for `the-spiral`. Its one
maintained body is `.claude/skills/the-spiral/SKILL.md`; read that file completely and follow it here.

Use the project shell and filesystem directly. Do not invoke Claude Code
commands. Translate interactive choices to structured Codex question tooling
when it is available; otherwise render compact numbered choices with an
`Other:` option and wait for the user.

1. Read `.claude/skills/the-spiral/SKILL.md` for the workflow details.
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
