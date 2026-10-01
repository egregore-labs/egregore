---
name: sync-repos
description: "Smart sync of all Egregore repos (memory + managed repos + current repo) — fetches first, only pulls if behind. Use for /sync-repos or 'sync all repos'."
---

Smart sync of all Egregore repos. Fetches first, only pulls if behind.

## When to invoke

User says: "/sync-repos", "sync all repos", "sync everything", "get every repo up to date"

## Execution boundary

This is deterministic multi-repository sync. Run it inline with bounded
parallel fetches; do not spend a Loom/model-routing call or delegate it to
another agent.

## Repos to sync

- `../{memory_dir}` — shared knowledge (derived from `memory_repo` in `egregore.json`)
- Any repos listed in the `repos` array in `egregore.json` (as sibling directories `../{repo}`)
- Current repo (egregore-core)

**Read `egregore.json` first** to get the dynamic list:
```bash
# Memory repo directory
bash bin/config-get.sh memory_dir

# Managed repos
bash bin/config-get.sh repos
```

Use the first command’s printed value as `{memory_dir}` and each line from the second as a managed `{repo}` name; for each value, quote it in single quotes when you use it in a command, and write any single quote inside the value as `'\''`. If a command prints nothing, it contributes no repo to sync.

## Execution

For each repo, run these commands:

```bash
# 1. Fetch (always)
git -C /path/to/repo fetch origin --quiet

# 2. Compare local vs remote
git -C /path/to/repo rev-parse HEAD
git -C /path/to/repo rev-parse origin/main
```

Use the printed revisions as `{local_sha}` and `{remote_sha}`. If they differ, pull and then count commits behind:

```bash
# 3. Only pull if different
git -C /path/to/repo pull origin main --quiet
# Count commits behind
git -C /path/to/repo rev-list HEAD..origin/main --count
```

Use the printed count as `{behind}` for the output. If the revisions match, report the repo as up to date and skip the pull and count.

**For the current repo (egregore-core)**: sync the `develop` branch instead of main:
```bash
# Update local develop ref without switching branches (safe for concurrent sessions)
git fetch origin develop:develop --quiet
# If on dev/* branch, rebase onto develop
git branch --show-current
```

Use the printed value as `{branch}`. If it starts with `dev/`, rebase onto develop:

```bash
git rebase develop --quiet
```

If the rebase fails, run `git rebase --abort`, then
`git merge develop -m 'Sync with develop'`. Continue to the merge only if the
abort succeeds:

```bash
git rebase --abort
```

```bash
git merge develop -m 'Sync with develop'
```

For any other branch, skip the rebase and merge.

Use absolute paths with `git -C` to avoid permission prompts.

## Output format

```
Syncing Egregore repos...

  {memory-dir}       ↓ 3 commits → pulled
  {repo-1}           ✓ up to date
  {repo-2}           ✓ up to date
  egregore-core      ↓ 1 commit → pulled
```

## Rules

- Use `git -C /absolute/path` — no `cd` commands
- Fetch ALL repos first (parallel if possible), then compare/pull
- Show commit count when pulling
- Skip repos that don't exist (no error)
