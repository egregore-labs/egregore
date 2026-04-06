Update local Egregore environment — sync framework from upstream and pull repos.

## What to do

1. **Sync framework from upstream** (egregore-labs/egregore)
2. **Run post-update migrations** (`bin/post-update.sh`)
3. **Run `/pull`** (sync develop + memory)
4. Show what changed

## Step 1: Framework sync

Egregore is a framework — updates come from upstream, not from your own repo's history.

This step is intentionally dumb and maximal: pull ALL framework paths, no conditions.
Paths that don't exist upstream are silently skipped by `git checkout`.

```bash
# Ensure upstream remote exists (no-op if already there)
git remote add upstream https://github.com/egregore-labs/egregore.git 2>/dev/null || true

# Fetch latest upstream
git fetch upstream main --quiet

# Sync ALL framework paths — always both commands/ and skills/
FW_PATHS="bin/ .claude/commands/ .claude/skills/ .claude/hooks/ .claude/context/ CLAUDE.md skills/"

# Check what would change before applying
UPSTREAM_DIFF=$(git diff HEAD upstream/main -- $FW_PATHS 2>/dev/null || true)

# If there are upstream changes, apply them (each path individually — some may not exist)
if [ -n "$UPSTREAM_DIFF" ]; then
  for p in $FW_PATHS; do
    git checkout upstream/main -- "$p" 2>/dev/null || true
  done
  # Show what changed
  git diff --stat HEAD
fi
```

**Framework paths synced:** `bin/`, `.claude/commands/`, `.claude/skills/`, `.claude/hooks/`, `.claude/context/`, `CLAUDE.md`, `skills/`
**Never touched:** `egregore.json`, `.env`, `memory/`, `.egregore-state.json`, `.mcp.json`

## Step 2: Post-update migrations

After syncing, run `bin/post-update.sh` if it exists. This script is itself synced from upstream, so it's always current. All migration logic lives here — not in this skill.

```bash
if [ -x bin/post-update.sh ]; then
  bash bin/post-update.sh
fi
```

## Step 3: Commit

If anything changed (framework sync or migrations), stage and commit:

```bash
git add -A .claude/ bin/ CLAUDE.md skills/ 2>/dev/null
if ! git diff --cached --quiet 2>/dev/null; then
  EGREGORE_FRAMEWORK_UPDATE=1 git commit -m "Update Egregore framework from upstream"
fi
```

The `EGREGORE_FRAMEWORK_UPDATE=1` marker tells the branch guard this is safe on develop.

## Step 4: Pull repos

Run `/pull` logic (sync develop, rebase working branch, pull memory).

## Example

```
> /update

Syncing framework from upstream...
  bin/activity-data.sh         | 89 +++++------
  .claude/skills/handoff/      | new
  bin/post-update.sh           | 12 +++---
  3 files changed, 32 insertions(+), 22 deletions(-)

Running post-update migrations...
  ✓ Removed .claude/commands/ (migrated to skills)

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
