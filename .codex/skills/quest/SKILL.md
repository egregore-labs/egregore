---
name: quest
description: Manage Egregore quests from Codex when the user invokes /quest or $quest, or asks to manage quests, using memory-first files and optional connected-mode graph updates.
---

# Egregore Quest

Native Codex Egregore skill. Quests are shared, open-ended explorations stored
under `memory/quests/`.

## Flow

1. Run `bin/agent.sh sync`.
2. Detect mode from `egregore.json` `mode`, defaulting to `connected`.
3. Dispatch from the user request:
   - no argument: list active and paused quests from `memory/quests/*.md`.
   - name or slug: show quest details from the markdown file.
   - `new`: create a quest.
   - `contribute`: append a contribution entry.
   - `prioritize`: set `priority` to `0`, `1`, `2`, or `3`.
   - `pause`: set `status: paused`.
   - `complete`: set `status: completed` and record an outcome.
4. Filesystem writes are canonical. Quest files use frontmatter:

```yaml
---
title: Example Quest
slug: example-quest
status: active
projects: []
started: YYYY-MM-DD
started_by: handle
priority: 0
completed:
---
```

5. Update `memory/quests/index.md` after create, status changes, and priority
   changes.
6. Commit and push memory immediately:

```bash
git -C memory add quests
git -C memory commit -m "quest: $SLUG $ACTION" --quiet
git -C memory push origin main --quiet
```

7. In connected mode only, mirror changes best-effort with `bin/graph.sh`.
   For each named person, follow `.claude/context/notification-consent.md`:
   create a direct-message plan, then show a separate exact Send / Edit /
   Cancel checkpoint. Selecting quest participants is not notification
   consent, and approvals cannot be batched across recipients. If planning or
   dispatch fails, report that the quest was saved to memory and continue.

## Interaction

Use structured Codex question tooling when available for new quest fields and
status confirmations. Otherwise ask one short numbered question at a time with
an `Other:` option.

## Output

Structured UX parity is required:

- `/quest` list mode renders the active quest table:
  `| Quest | Project | Artifacts | Contributors |`, followed by paused quest
  state and entry-point hints.
- `/quest <name>` detail mode renders the same sectioned view as Egregore:
  title rule, status, projects, started metadata, question, threads,
  artifacts, todos when available, contributors, and entry points.
- Create/update routes use compact structured confirmations with the quest
  file path and memory push state. Do not substitute a loose prose summary.
- In local mode, omit graph/notification wording while preserving the same
  list/detail layout.

## Rules

- Do not use graph or notification calls in local mode.
- Do not let graph failure block a filesystem quest update.
- Do not use Claude Code commands.
