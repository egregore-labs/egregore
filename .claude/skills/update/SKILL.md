Update local Egregore environment — sync framework from upstream and pull repos.

## What to do

1. **Sync framework from upstream** (egregore-labs/egregore)
2. **Run `/pull`** (sync develop + memory)
3. Show what changed

## Step 1: Framework sync

Egregore is a framework — updates come from upstream, not from your own repo's history.

```bash
# Ensure upstream remote exists (no-op if already there)
git remote add upstream https://github.com/egregore-labs/egregore.git 2>/dev/null || true

# Fetch latest upstream
git fetch upstream main --quiet

# Detect Claude Code version — v2.0+ dropped .claude/commands/ support
CC_VERSION=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
CC_MAJOR=$(echo "$CC_VERSION" | cut -d. -f1)

if [ "${CC_MAJOR:-0}" -ge 2 ]; then
  # CC 2.0+: skills only — commands are dead
  FW_PATHS="bin/ .claude/skills/ .claude/hooks/ .claude/context/ CLAUDE.md skills/"
else
  # Pre-2.0: commands only — skills not supported
  FW_PATHS="bin/ .claude/commands/ .claude/hooks/ .claude/context/ CLAUDE.md skills/"
fi

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

**Framework paths synced (CC 2.0+):** `bin/`, `.claude/skills/`, `.claude/hooks/`, `.claude/context/`, `CLAUDE.md`, `skills/`
**Framework paths synced (pre-2.0):** `bin/`, `.claude/commands/`, `.claude/hooks/`, `.claude/context/`, `CLAUDE.md`, `skills/`
**Never touched:** `egregore.json`, `.env`, `memory/`, `.egregore-state.json`, `.mcp.json`

### Post-sync: commands→skills migration cleanup (CC 2.0+ only)

If CC is 2.0+ and `.claude/commands/` still exists locally, remove it — those files are dead weight (CC no longer reads them):
```bash
if [ "${CC_MAJOR:-0}" -ge 2 ] && [ -d ".claude/commands" ]; then
  git rm -r .claude/commands/ 2>/dev/null || rm -rf .claude/commands/
fi
```

### Post-sync: old CC version notice (pre-2.0 only)

If CC is pre-2.0, show:
```
⚠ Claude Code $CC_VERSION detected — upgrade recommended.
  v2.0+ is required for the latest Egregore skills format.
  Run: npm install -g @anthropic-ai/claude-code@latest
```

If framework files changed, stage and commit directly to develop (no branch needed — framework updates are upstream pulls, not user work):
```bash
git add $FW_PATHS 2>/dev/null
git add .claude/commands/ 2>/dev/null  # stage removal if cleaned up
EGREGORE_FRAMEWORK_UPDATE=1 git commit -m "Update Egregore framework from upstream"
```
The `EGREGORE_FRAMEWORK_UPDATE=1` marker tells the branch guard this is safe on develop.

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
