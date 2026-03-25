Update local Egregore environment — sync framework from upstream and pull repos.

## What to do

1. **Sync framework from upstream** (Curve-Labs/egregore-core)
2. **Run `/pull`** (sync develop + memory)
3. Show what changed

## Step 1: Framework sync

Egregore is a framework — updates come from upstream, not from your own repo's history.

```bash
# Ensure upstream remote exists (no-op if already there)
git remote add upstream https://github.com/Curve-Labs/egregore-core.git 2>/dev/null || true

# Fetch latest upstream
git fetch upstream main --quiet

# Check what would change before applying (two-dot diff — works even without shared git history)
UPSTREAM_DIFF=$(git diff HEAD upstream/main -- bin/ .claude/commands/ CLAUDE.md skills/ 2>/dev/null || true)

# If there are upstream changes, apply them
if [ -n "$UPSTREAM_DIFF" ]; then
  git checkout upstream/main -- bin/ .claude/commands/ CLAUDE.md skills/
  # Show what changed
  git diff --stat HEAD
fi
```

**Framework paths synced:** `bin/`, `.claude/commands/`, `CLAUDE.md`, `skills/`
**Never touched:** `egregore.json`, `.env`, `memory/`, `.egregore-state.json`, `.mcp.json`

If framework files changed, stage and commit them:
```bash
git add bin/ .claude/commands/ CLAUDE.md skills/
git commit -m "Update Egregore framework from upstream"
```

## Step 2: Pull repos

Run `/pull` logic (sync develop, rebase working branch, pull memory).

## Example

```
> /update

Syncing framework from upstream...
  bin/activity-data.sh         | 89 +++++------
  .claude/commands/pull.md     |  4 --
  bin/session-start.sh         | 12 +++---
  3 files changed, 32 insertions(+), 22 deletions(-)
  ✓ Framework updated and committed

Pulling...
  develop        ✓ synced
  memory         ✓ up to date
```

## If framework is already current

```
Syncing framework from upstream...
  ✓ Already up to date
```
