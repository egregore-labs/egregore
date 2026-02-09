Pull latest for current repo and shared memory.

**Note:** `/activity` auto-syncs. Use `/pull` only when you need to sync without viewing activity.

## What to do

1. Sync develop branch with remote
2. If on a `dev/*` working branch, rebase onto develop (fallback: merge)
3. Check memory symlink exists — if not: `ln -s ../curve-labs-memory memory`
4. Pull memory repo via symlink

**Does NOT sync sibling repos.** Use `/sync-repos` for that.

## Execution

```bash
# 1. Fetch and sync develop
git fetch origin --quiet
CURRENT=$(git branch --show-current)
git checkout develop --quiet && git pull origin develop --quiet && git checkout "$CURRENT" --quiet

# 2. If on a working branch, rebase onto develop
if [[ "$CURRENT" == dev/* ]]; then
  git rebase develop --quiet || (git rebase --abort && git merge develop -m "Sync with develop")
fi

# 3. Memory (via symlink)
git -C memory pull origin main --quiet
```

## Output

```
Pulling...
  develop        ↓ 3 commits → synced
  dev/oz/...     ✓ rebased onto develop
  memory         ↓ 2 commits → pulled

For sibling repos (tristero, lace): /sync-repos
```
