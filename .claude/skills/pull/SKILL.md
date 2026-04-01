Pull latest for current repo and shared memory.

**Note:** `/activity` auto-syncs. Use `/pull` only when you need to sync without viewing activity.

## What to do

1. Sync develop branch with remote
2. If on a `dev/*` working branch, rebase onto develop (fallback: merge)
3. Check memory symlink exists — if not, derive directory from `egregore.json` and create symlink
4. Pull memory repo via symlink

## Execution

```bash
# 1. Update local develop ref without switching branches (safe for concurrent sessions)
git fetch origin develop:develop --quiet

# 2. If on a working branch, rebase onto develop
CURRENT=$(git branch --show-current)
if [[ "$CURRENT" == dev/* ]]; then
  git rebase develop --quiet || (git rebase --abort && git merge develop -m "Sync with develop")
fi

# 3. Memory — derive directory from egregore.json, never hardcode
MEMORY_DIR=$(basename "$(jq -r '.memory_repo' egregore.json)" .git)
if [ ! -L memory ]; then
  ln -s "../$MEMORY_DIR" memory
fi

# 4. Pull memory and capture what arrived
MEMORY_BEFORE=$(git -C memory rev-parse HEAD 2>/dev/null)
git -C memory pull origin main --quiet
MEMORY_AFTER=$(git -C memory rev-parse HEAD 2>/dev/null)

# 5. Show what arrived in memory (new/changed files since last pull)
if [ "$MEMORY_BEFORE" != "$MEMORY_AFTER" ]; then
  MEMORY_FILES=$(git -C memory diff --name-only "$MEMORY_BEFORE" "$MEMORY_AFTER")
  MEMORY_COUNT=$(echo "$MEMORY_FILES" | wc -l | tr -d ' ')
fi
```

## Output

Show what arrived — don't leave the user wondering if things synced:

```
Pulling...
  develop        ↓ 3 commits → synced
  dev/oz/...     ✓ rebased onto develop
  memory         ↓ 2 commits — 4 files updated
                   handoffs/2026-02/12-renckorzay-giza-docs.md (new)
                   handoffs/index.md
                   artifacts/giza-architecture.md (new)
                   artifacts/giza-api-spec.md (new)
```

If memory is already up to date:
```
  memory         ✓ up to date
```

