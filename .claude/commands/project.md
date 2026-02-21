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
| backend | Polis | 2 active | 4 (last: today) |
| frontend | Psyche | 1 active | 2 (last: 2 days) |
| infrastructure | Meta | 0 | 1 (last: 3 days) |

To see details: /project backend
```

## Example (show)

```
> /project backend

Project: Backend
─────────────────

Domain: Polis — Coordination mechanisms, governance, emergent ontologies

Active Quests:
  → benchmark-eval (4 artifacts, Alice + Carol)
  → research-agent (1 artifact, Alice)

Recent Artifacts (via quests):
  → 2026-01-27 [finding] HELM adaptable with modifications
  → 2026-01-26 [source] HELM Framework Review
  → 2026-01-26 [thought] Temporal dimension in evaluation

Entry Points:
  - Code: cd ../backend && claude
  - Docs: backend/README.md
  - Recent work: /activity backend
```

## Next

Run `/quest [name]` to dive into a quest, or `cd ../[project] && claude` to work on code.
