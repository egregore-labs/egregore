---
name: dark-mode
description: 'Use when generating or modifying any visual output that renders in a browser or artifact viewer: HTML pages, CSS, React SSR components, Egregore artifacts, markdown renderers, web components, design-system tokens, Tailwind themes, or standalone demos. Triggers on requests involving dark mode, theme toggles, color systems, card surfaces, browser rendering, or visual polish. The load-bearing lesson: if React SSR emits an inline hex color through `style={}`, CSS dark-mode overrides cannot reach it, so every theme-sensitive color must be emitted as `var(--token)` rather than a resolved hex. Do not use for TUI output, plain markdown files, or non-visual code.'
---

<!-- generated-by: bin/codex-sync-skills.sh -->

# Egregore dark-mode Adapter

This is fallback coverage for a long-tail Egregore workflow that has not been
ported to a hand-written Codex-native skill yet.

Use the project shell and filesystem directly. Do not invoke Claude Code
commands. Translate interactive choices to structured Codex question tooling
when it is available; otherwise render compact numbered choices with an
`Other:` option and wait for the user.

1. Read `.claude/skills/dark-mode/SKILL.md` for the workflow details.
2. Run the referenced `bin/` scripts directly from Codex.
3. Treat graph, publish, and notify steps as best-effort unless that workflow
   explicitly says they are required.
4. Keep local-mode behavior filesystem-first and avoid graph or notification
   calls when `egregore.json` declares `"mode": "local"`.
5. Never call the deprecated `egregore-handoff` CLI for Egregore project
   handoffs.
