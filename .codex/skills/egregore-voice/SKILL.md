---
name: egregore-voice
description: 'Use when writing any external communication for Egregore — essays, launch posts, website copy, announcements, README prose, social content, or any text that represents Egregore to the world. Triggers on: ''write this for the site'', ''draft the announcement'', ''help me write this essay'', ''landing page copy'', ''external post'', ''blog post'', ''Archive Fever'', ''write in my voice'', or any task producing text that an outside reader will see. Do NOT use for internal docs, CLAUDE.md files, handoffs, code comments, or technical specs — those have their own conventions. This skill prevents vanilla AI slop and ensures all external output reflects the manuscriptic, architecturally precise, philosophically grounded voice of Egregore.'
---

<!-- generated-by: bin/codex-sync-skills.sh -->

# Egregore egregore-voice Adapter

This is fallback coverage for a long-tail Egregore workflow that has not been
ported to a hand-written Codex-native skill yet.

Use the project shell and filesystem directly. Do not invoke Claude Code
commands. Translate interactive choices to structured Codex question tooling
when it is available; otherwise render compact numbered choices with an
`Other:` option and wait for the user.

1. Read `.claude/skills/egregore-voice/SKILL.md` for the workflow details.
2. Run the referenced `bin/` scripts directly from Codex.
3. Treat graph, publish, and notify steps as best-effort unless that workflow
   explicitly says they are required.
4. Keep local-mode behavior filesystem-first and avoid graph or notification
   calls when `egregore.json` declares `"mode": "local"`.
5. Never call the deprecated `egregore-handoff` CLI for Egregore project
   handoffs.
