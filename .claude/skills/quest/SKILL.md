---
name: quest
description: "Manage shared open-ended quests through one canonical Markdown lifecycle. Use for /quest, listing or opening quests, starting an exploration, contributing, prioritizing, pausing, or completing a quest."
---

# Quest

Manage collaborative explorations without making a graph or harness prompt an
authority.

## When to invoke

Manage shared open-ended quests through one canonical Markdown lifecycle. Use for /quest, listing or opening quests, starting an exploration, contributing, prioritizing, pausing, or completing a quest.

## Runtime contract

- `memory/quests/<slug>.md` is canonical in Local and Connected modes.
- Resolve identity and permissions through `ActorContext` before reading or
  changing quest state.
- `bin/quest.sh` is the only lifecycle adapter. It authorizes, validates,
  writes canonical Markdown, records Git provenance, refreshes retrieval,
  schedules changed-hash embedding, emits content-free telemetry, and may
  update an optional graph projection downstream.
- A projection failure never rolls back or overrides canonical Markdown/Git.
- `memory/quests/index.md`, dashboards, and graph records are rebuildable
  views, not state the ritual edits.

Arguments: `$ARGUMENTS`.

## Routes

| Input | Runtime action |
|---|---|
| empty | `bash bin/quest.sh list` |
| `all` | `bash bin/quest.sh list --all` |
| `<name>` | resolve one listed slug, then `bash bin/quest.sh show <slug>` |
| `new` | collect the minimum fields, then one `new` call |
| `contribute <name>` | resolve the slug and record one contribution |
| `prioritize <name> <level>` | set `none`, `low`, `medium`, or `high` |
| `pause <name>` | explicitly pause one active quest |
| `complete <name>` | require an outcome, then complete one active quest |

Suppress raw JSON. Render only the fields returned by the adapter.

## List and show

Run one list call and use that snapshot for display and name resolution. Show
active quests first, ordered by priority and recency; show paused separately.
Include title, slug, projects, priority, starter, and canonical path. For a
detail request, call `show` once after resolution and render its question,
threads, contributions, artifacts, entry points, and outcome from the returned
canonical body.

Do not run a graph query to enrich the view. Linked todos and relationships may
appear only when a future Runtime read model returns them with freshness and
provenance.

## Create

Collect:

1. title
2. the open question or goal
3. optional slug, projects, and initial threads

Then make one call:

```bash
bash bin/quest.sh new \
  --title "<title>" \
  --question "<question>" \
  [--slug "<slug>"] \
  [--project "<project>"]... \
  [--thread "<thread>"]...
```

Confirm the stable quest id, canonical path, and writeback status. Do not run a
second Git, index, graph, save, or publish action.

## Update

Resolve a user-supplied name against one list snapshot. If ambiguous, show the
bounded choices. Then mutate by stable slug:

```bash
bash bin/quest.sh contribute "<slug>" "<contribution>"
bash bin/quest.sh prioritize "<slug>" "<none|low|medium|high>"
bash bin/quest.sh pause "<slug>"
bash bin/quest.sh complete "<slug>" --outcome "<outcome>"
```

Only an active quest accepts contributions, pause, or completion. Completion
requires an explicit outcome. Never infer completion from inactivity, age,
closed todos, or graph state.

## Failure behavior

- Authorization denial: return no quest content and perform no write.
- Writeback partial: canonical Markdown/Git wins; surface projection,
  retrieval, or telemetry warnings without retrying the entire write.
- Concurrent edit: stop on the Runtime conflict, re-list, then retry only with
  current user intent.
- Graph/control-plane unavailable: quest lifecycle remains functional.

## Rules

- Markdown/Git is authoritative in every mode.
- One list snapshot per route; one canonical write per transition.
- Never edit quest files or their index directly.
- Never call Git, QMD, Neo4j, Supabase, or notification APIs from this skill.
- Quest participation is not notification consent. Any later notification is
  a separate exact recipient/message approval after canonical writeback.
- Do not include titles, questions, contributions, outcomes, or paths in
  telemetry.

Emit content-free command telemetry only if Runtime writeback did not already
record the operation:

```bash
bash bin/telemetry.sh emit "command" '{"command":"quest","subcommand":"<route>"}' 2>/dev/null &
```
