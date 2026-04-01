Smart sync of all Egregore repos. Fetches first, only pulls if behind.

## Repos to sync

- `../$MEMORY_DIR` — shared knowledge (derived from `memory_repo` in `egregore.json`)
- Any repos listed in the `repos` array in `egregore.json` (as sibling directories `../{repo}`)
- Current repo (egregore-core)

**Read `egregore.json` first** to get the dynamic list:
```bash
# Memory repo directory
MEMORY_DIR=$(basename "$(jq -r '.memory_repo' egregore.json)" .git)

# Managed repos
REPOS=$(jq -r '.repos[]? // empty' egregore.json)
```

## Execution

For each repo, run these commands:

```bash
# 1. Fetch (always)
git -C /path/to/repo fetch origin --quiet

# 2. Compare local vs remote
LOCAL=$(git -C /path/to/repo rev-parse HEAD)
REMOTE=$(git -C /path/to/repo rev-parse origin/main)

# 3. Only pull if different
if [ "$LOCAL" != "$REMOTE" ]; then
  git -C /path/to/repo pull origin main --quiet
  # Count commits behind
  BEHIND=$(git -C /path/to/repo rev-list HEAD..origin/main --count)
fi
```

**For the current repo (egregore-core)**: sync the `develop` branch instead of main:
```bash
# Update local develop ref without switching branches (safe for concurrent sessions)
git fetch origin develop:develop --quiet
# If on dev/* branch, rebase onto develop
BRANCH=$(git branch --show-current)
if [[ "$BRANCH" == dev/* ]]; then
  git rebase develop --quiet || (git rebase --abort && git merge develop -m "Sync with develop")
fi
```

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
