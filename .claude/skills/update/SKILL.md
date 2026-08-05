Update local Egregore environment — sync framework from upstream and pull repos.

## What to do

1. **Sync framework from upstream** (egregore-labs/egregore)
2. **Run post-update migrations** (`bin/post-update.sh`)
3. **Run `/pull`** (sync base branch + memory)
4. Show what changed

## Step 1: Detect environment

Detect the base branch and whether we're in a worktree. Framework updates MUST land on the base branch, never on working branches.

```bash
# Detect base branch: develop if it exists, otherwise main
BASE_BRANCH="main"
git show-ref --verify --quiet refs/heads/develop 2>/dev/null && BASE_BRANCH="develop"

CURRENT_BRANCH=$(git branch --show-current)

# Detect worktree: .git is a file (not a directory) in worktrees
IN_WORKTREE="false"
if [ -f .git ]; then
  IN_WORKTREE="true"
  WT_GITDIR=$(sed 's/^gitdir: //' .git)
  MAIN_DIR=$(cd "$WT_GITDIR/../../.." && pwd)
fi
```

## Step 2: Sync framework to base branch

Egregore is a framework — updates come from upstream, not from your own repo's history.

**Freeze lever — check FIRST, before touching any remote:**

```bash
UPSTREAM_URL=$(jq -r '.upstream_url // empty' egregore.json 2>/dev/null)
```

If `UPSTREAM_URL` is `"none"`, this instance **does not pull framework from
upstream** — it is either the framework source of truth (framework changes are
authored here and flow OUT via `/sync-public`) or deliberately frozen. **Skip
Step 2 entirely** — do NOT add an upstream remote, do NOT checkout any path.
Tell the user: `⛔ upstream_url is "none" — this instance never pulls framework
from upstream. Skipping framework sync; running migrations + /pull only.` Then
continue with Step 3. A wholesale upstream checkout on a source-of-truth
instance reverts downstream work (the 578deee incident: 23 files, −1131 lines).

**In a worktree:** The base branch is checked out in the main repo. Use `git -C` to update it there — `git checkout $BASE_BRANCH` would fail since git won't let two worktrees share a branch.

**Not in a worktree:** Switch to the base branch directly.

```bash
# Ensure upstream remote exists (honor a custom upstream_url when set)
UPSTREAM="${UPSTREAM_URL:-https://github.com/egregore-labs/egregore.git}"
if [ "$IN_WORKTREE" = "true" ]; then
  git -C "$MAIN_DIR" remote add upstream "$UPSTREAM" 2>/dev/null \
    || git -C "$MAIN_DIR" remote set-url upstream "$UPSTREAM"
  git -C "$MAIN_DIR" fetch upstream main --quiet
else
  git remote add upstream "$UPSTREAM" 2>/dev/null \
    || git remote set-url upstream "$UPSTREAM"
  git fetch upstream main --quiet
fi
```

### Worktree path

```bash
if [ "$IN_WORKTREE" = "true" ]; then
  # Sync framework in main repo (on base branch)
  for p in bin/ .claude/commands/ .claude/skills/ .claude/hooks/ .claude/context/ .claude/agents/ .pi/ loom/ CLAUDE.md skills/; do
    git -C "$MAIN_DIR" checkout upstream/main -- "$p" 2>/dev/null || true
  done

  # Regenerate AGENTS.md. It is GENERATED from CLAUDE.md by
  # bin/codex-render-spec.mjs and is deliberately NOT in the path loop above —
  # so without this step downstream workspaces never receive AGENTS.md framework
  # changes (e.g. the Claude-Code runtime-precedence guard). Regenerate from the
  # freshly-synced CLAUDE.md + script; fall back to the prebuilt upstream copy if
  # node is unavailable or the render fails.
  if command -v node >/dev/null 2>&1 && [ -f "$MAIN_DIR/bin/codex-render-spec.mjs" ]; then
    node "$MAIN_DIR/bin/codex-render-spec.mjs" 2>/dev/null \
      || git -C "$MAIN_DIR" checkout upstream/main -- AGENTS.md .codex/spec-manifest.json 2>/dev/null || true
    [ -f "$MAIN_DIR/bin/pi-render-spec.mjs" ] && node "$MAIN_DIR/bin/pi-render-spec.mjs" 2>/dev/null || true
  else
    git -C "$MAIN_DIR" checkout upstream/main -- AGENTS.md .codex/spec-manifest.json 2>/dev/null || true
  fi

  # Restore org-owned skills (egregore.json → owned_skills[]) before committing.
  # On a name collision the org's committed version wins; the script reports it.
  (cd "$MAIN_DIR" && bash bin/restore-owned-skills.sh) || true

  # Show what changed
  git -C "$MAIN_DIR" diff --stat HEAD

  # Commit on base branch in main repo
  git -C "$MAIN_DIR" add -A .claude/ .pi/ bin/ loom/ CLAUDE.md skills/ AGENTS.md .codex/spec-manifest.json 2>/dev/null
  if ! git -C "$MAIN_DIR" diff --cached --quiet 2>/dev/null; then
    EGREGORE_FRAMEWORK_UPDATE=1 git -C "$MAIN_DIR" commit -m "Update Egregore framework from upstream"
    git -C "$MAIN_DIR" push origin "$BASE_BRANCH" --quiet 2>/dev/null || true
  fi

  # Rebase worktree branch onto updated base
  git stash --quiet 2>/dev/null || true
  git fetch origin "$BASE_BRANCH" --quiet
  if ! git rebase "origin/$BASE_BRANCH" --quiet 2>/dev/null; then
    git rebase --abort 2>/dev/null || true
    echo "⚠ Rebase had conflicts — aborted. Run: git rebase origin/$BASE_BRANCH and resolve manually."
  fi
  git stash pop --quiet 2>/dev/null || true
fi
```

### Non-worktree path

```bash
if [ "$IN_WORKTREE" = "false" ]; then
  SWITCHED="false"

  if [ "$CURRENT_BRANCH" != "$BASE_BRANCH" ]; then
    git stash --quiet 2>/dev/null || true
    git checkout "$BASE_BRANCH" --quiet 2>/dev/null
    SWITCHED="true"
  fi

  # Sync ALL framework paths
  for p in bin/ .claude/commands/ .claude/skills/ .claude/hooks/ .claude/context/ .claude/agents/ .pi/ loom/ CLAUDE.md skills/; do
    git checkout upstream/main -- "$p" 2>/dev/null || true
  done

  # Regenerate AGENTS.md from the freshly-synced CLAUDE.md (it is generated by
  # bin/codex-render-spec.mjs and not in the path loop above). Fall back to the
  # prebuilt upstream copy if node is unavailable or the render fails.
  if command -v node >/dev/null 2>&1 && [ -f bin/codex-render-spec.mjs ]; then
    node bin/codex-render-spec.mjs 2>/dev/null \
      || git checkout upstream/main -- AGENTS.md .codex/spec-manifest.json 2>/dev/null || true
    [ -f bin/pi-render-spec.mjs ] && node bin/pi-render-spec.mjs 2>/dev/null || true
  else
    git checkout upstream/main -- AGENTS.md .codex/spec-manifest.json 2>/dev/null || true
  fi

  # Restore org-owned skills (egregore.json → owned_skills[]) before committing.
  # On a name collision the org's committed version wins; the script reports it.
  bash bin/restore-owned-skills.sh || true

  # Show what changed
  git diff --stat HEAD
fi
```

**Framework paths synced:** `bin/`, `.claude/commands/`, `.claude/skills/`, `.claude/hooks/`, `.claude/context/`, `.claude/agents/`, `.pi/`, `loom/`, `CLAUDE.md`, `skills/`
**Regenerated:** `AGENTS.md` + `.codex/spec-manifest.json` via `bin/codex-render-spec.mjs`, then `.pi/APPEND_SYSTEM.md` + `.pi/spec-manifest.json` via `bin/pi-render-spec.mjs`, so both derived harnesses stay aligned with `CLAUDE.md`.
**Never touched:** `egregore.json`, `.env`, `memory/`, `.egregore-state.json`, `.mcp.json`
**Org-owned skills:** names in `egregore.json` → `owned_skills[]` are restored from the org's committed state after the overlay (`bin/restore-owned-skills.sh`) — upstream never overwrites them; collisions are reported instead.

## Step 3: Post-update migrations

After syncing, run `bin/post-update.sh` if it exists. In worktrees, run from `$MAIN_DIR` to ensure the updated version executes even if the rebase didn't complete.

```bash
if [ "$IN_WORKTREE" = "true" ]; then
  [ -x "$MAIN_DIR/bin/post-update.sh" ] && bash "$MAIN_DIR/bin/post-update.sh"
else
  [ -x bin/post-update.sh ] && bash bin/post-update.sh
fi
```

## Step 4: Commit and switch back (non-worktree only)

Worktree path already committed in Step 2. This handles the non-worktree case:

```bash
if [ "$IN_WORKTREE" = "false" ]; then
  git add -A .claude/ .pi/ bin/ loom/ CLAUDE.md skills/ AGENTS.md .codex/spec-manifest.json 2>/dev/null
  if ! git diff --cached --quiet 2>/dev/null; then
    EGREGORE_FRAMEWORK_UPDATE=1 git commit -m "Update Egregore framework from upstream"
    git push origin "$BASE_BRANCH" --quiet 2>/dev/null || true
  fi

  # Switch back to working branch, rebase, restore user's work
  if [ "$SWITCHED" = "true" ]; then
    git checkout "$CURRENT_BRANCH" --quiet 2>/dev/null
    if ! git rebase "$BASE_BRANCH" --quiet 2>/dev/null; then
      git rebase --abort 2>/dev/null || true
      echo "⚠ Rebase had conflicts — aborted. Run: git rebase $BASE_BRANCH and resolve manually."
    fi
    git stash pop --quiet 2>/dev/null || true
  fi
fi
```

The `EGREGORE_FRAMEWORK_UPDATE=1` marker tells the branch guard this is safe on the base branch.

## Step 5: Pull repos

Run `/pull` logic (sync base branch, rebase working branch, pull memory).

## Example (on main, no worktree)

```
> /update

Syncing framework from upstream...
  bin/activity-data.sh         | 89 +++++------
  .claude/skills/handoff/      | new
  bin/post-update.sh           | 12 +++---
  3 files changed, 32 insertions(+), 22 deletions(-)

Running post-update migrations...
  ✓ Removed .claude/commands/ (migrated to skills)

  ✓ Framework updated and committed to main

Pulling...
  main           ✓ synced
  memory         ✓ up to date
```

## Example (on working branch in worktree)

```
> /update

Syncing framework in main repo (on develop)...
  bin/notify.sh                | 12 +++---
  .claude/skills/update/       | modified
  2 files changed, 18 insertions(+), 6 deletions(-)

  ✓ Framework updated and committed to develop
  ✓ Rebased working branch onto develop

Pulling...
  develop        ✓ synced
  memory         ✓ up to date
```

## If framework is already current

```
Syncing framework from upstream...
  ✓ Already up to date
```
