Update local Egregore environment — sync framework from upstream and pull repos.

## What to do

1. **Sync framework from upstream** (egregore-labs/egregore)
2. **Run post-update migrations** (`bin/post-update.sh`)
3. **Run `/pull`** (sync develop + memory)
4. Show what changed

## Step 1: Switch to develop first

Framework updates MUST land on develop, never on working branches. If on a working branch, reset any dirty state and switch to develop before touching framework files.

```bash
CURRENT_BRANCH=$(git branch --show-current)
SWITCHED="false"

if [ "$CURRENT_BRANCH" != "develop" ]; then
  # Stash user's uncommitted work (if any) so we can switch branches
  git stash --quiet 2>/dev/null || true
  git checkout develop --quiet 2>/dev/null
  SWITCHED="true"
fi
```

## Step 2: Framework sync (on develop)

Egregore is a framework — updates come from upstream, not from your own repo's history.

Pull ALL framework paths on develop. Paths that don't exist upstream are silently skipped.

```bash
# Ensure upstream remote exists and points to the right URL
git remote add upstream https://github.com/egregore-labs/egregore.git 2>/dev/null \
  || git remote set-url upstream https://github.com/egregore-labs/egregore.git

# Fetch latest upstream
git fetch upstream main --quiet

# Sync ALL framework paths
for p in bin/ .claude/commands/ .claude/skills/ .claude/hooks/ .claude/context/ CLAUDE.md skills/; do
  git checkout upstream/main -- "$p" 2>/dev/null || true
done

# Show what changed (if anything)
git diff --stat HEAD
```

**Framework paths synced:** `bin/`, `.claude/commands/`, `.claude/skills/`, `.claude/hooks/`, `.claude/context/`, `CLAUDE.md`, `skills/`
**Never touched:** `egregore.json`, `.env`, `memory/`, `.egregore-state.json`, `.mcp.json`

## Step 3: Post-update migrations

After syncing, run `bin/post-update.sh` if it exists. This script is itself synced from upstream, so it's always current.

```bash
if [ -x bin/post-update.sh ]; then
  bash bin/post-update.sh
fi
```

## Step 4: Commit and switch back

```bash
git add -A .claude/ bin/ CLAUDE.md skills/ 2>/dev/null
if ! git diff --cached --quiet 2>/dev/null; then
  EGREGORE_FRAMEWORK_UPDATE=1 git commit -m "Update Egregore framework from upstream"
  git push origin develop --quiet 2>/dev/null || true
fi

# Switch back to working branch, rebase, restore user's work
if [ "$SWITCHED" = "true" ]; then
  git checkout "$CURRENT_BRANCH" --quiet 2>/dev/null
  git rebase develop --quiet 2>/dev/null || true
  # Restore user's uncommitted work — stash pop is safe here because:
  # - The stash was taken BEFORE any framework checkout
  # - It contains only the user's work, not framework diffs
  # - Rebase already brought framework changes via develop
  git stash pop --quiet 2>/dev/null || true
fi
```

The `EGREGORE_FRAMEWORK_UPDATE=1` marker tells the branch guard this is safe on develop.

## Step 5: Pull repos

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
