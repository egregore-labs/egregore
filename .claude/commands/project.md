Show project status — linked quests, recent artifacts, entry points.

Arguments: $ARGUMENTS (Optional: project name)

## Usage

- `/project` — List all projects
- `/project [name]` — Show project details

## Example (list)

```
> /project

Projects
────────

| Project | Domain | Quests | Recent Artifacts |
|---------|--------|--------|------------------|
| tristero | Polis | 2 active | 4 (last: today) |
| lace | Psyche | 1 active | 2 (last: 2 days) |
| infrastructure | Meta | 0 | 1 (last: 3 days) |

To see details: /project tristero
```

## Example (show)

```
> /project tristero

Project: Tristero
─────────────────

Domain: Polis — Coordination mechanisms, governance, emergent ontologies

Active Quests:
  → benchmark-eval (4 artifacts, Oz + Ali)
  → research-agent (1 artifact, Oz)

Recent Artifacts (via quests):
  → 2026-01-27 [finding] HELM adaptable with modifications
  → 2026-01-26 [source] HELM Framework Review
  → 2026-01-26 [thought] Temporal dimension in evaluation

Entry Points:
  - Code: cd ../tristero && claude
  - Docs: tristero/README.md
  - Recent work: /activity tristero
```

## Next

Run `/quest [name]` to dive into a quest, or `cd ../[project] && claude` to work on code.
