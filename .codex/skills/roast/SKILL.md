---
name: roast
description: 'Perform a sharp, context-aware comedic roast as Egregore''s court jester. Use when the user invokes /roast or $roast, says "roast me," "roast us," "roast someone," "roast this," "roast this project/session/idea," or asks to make fun of a target using its actual history, shared memory, artifacts, activity, or current context.'
---

<!-- generated-by: bin/codex-sync-skills.sh -->

# Egregore roast Adapter

This is fallback coverage for a long-tail Egregore workflow that has not been
ported to a hand-written Codex-native skill yet.

Use the project shell and filesystem directly. Do not invoke Claude Code
commands. Translate interactive choices to structured Codex question tooling
when it is available; otherwise render compact numbered choices with an
`Other:` option and wait for the user.

1. Read `.claude/skills/roast/SKILL.md` for the workflow details.
2. Run the referenced `bin/` scripts directly from Codex.
3. Treat graph, publish, and notify steps as best-effort unless that workflow
   explicitly says they are required.
4. Keep local-mode behavior filesystem-first and avoid graph or notification
   calls when `egregore.json` declares `"mode": "local"`.
5. Never call the deprecated `egregore-handoff` CLI for Egregore project
   handoffs.
