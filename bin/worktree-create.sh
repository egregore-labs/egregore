#!/bin/bash
# WorktreeCreate hook — replaces EnterWorktree's default behavior.
# Receives {"name": "<slug>"} on stdin. Must print absolute worktree path to stdout.
# All diagnostic output goes to stderr or /dev/null — stdout is ONLY for the path.
# Must complete in under 2 seconds.

# No set -e — a jq failure must not crash the hook
set -o pipefail

# --- Read input ---
INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')
SLUG=$(echo "$INPUT" | jq -r '.name // empty' 2>/dev/null)

if [ -z "$SLUG" ]; then
  echo "Error: no name provided" >&2
  exit 1
fi

# --- Resolve main repo root ---
# CLAUDE_PROJECT_DIR may point to main repo or a worktree
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if [ -f "$REPO_ROOT/.git" ]; then
  # In a worktree — trace back to main repo
  WT_GITDIR=$(sed 's/^gitdir: //' "$REPO_ROOT/.git" 2>/dev/null)
  REPO_ROOT=$(cd "$WT_GITDIR/../../.." 2>/dev/null && pwd)
fi

# --- Read author ---
STATE_FILE="$REPO_ROOT/.egregore-state.json"
AUTHOR=$(jq -r '.github_username // .display_name // "unknown"' "$STATE_FILE" 2>/dev/null) || AUTHOR="unknown"

# --- Branch and worktree names ---
BRANCH="dev/${AUTHOR}/${SLUG}"
WT_PATH="$REPO_ROOT/.claude/worktrees/${SLUG}"

# --- Ensure origin/develop is available ---
git -C "$REPO_ROOT" fetch origin develop --quiet 2>/dev/null || true

# --- Create branch (idempotent — skip if exists) ---
if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  git -C "$REPO_ROOT" branch "$BRANCH" origin/develop >/dev/null 2>&1 || {
    echo "Error: failed to create branch $BRANCH" >&2
    exit 1
  }
fi

# --- Handle stale worktree at same path ---
if [ -d "$WT_PATH" ]; then
  git -C "$REPO_ROOT" worktree remove "$WT_PATH" --force 2>/dev/null || rm -rf "$WT_PATH" 2>/dev/null
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
fi

# --- Create worktree on our branch ---
mkdir -p "$REPO_ROOT/.claude/worktrees" 2>/dev/null
git -C "$REPO_ROOT" worktree add "$WT_PATH" "$BRANCH" --quiet 2>/dev/null || {
  echo "Error: failed to create worktree at $WT_PATH" >&2
  exit 1
}

# --- Symlinks (same as worktree.sh setup) ---
# Memory — may be a symlink (follow to its target) or a real directory.
MEMORY_TARGET=""
if [ -L "$REPO_ROOT/memory" ]; then
  MEMORY_TARGET=$(realpath "$REPO_ROOT/memory" 2>/dev/null)
elif [ -d "$REPO_ROOT/memory" ]; then
  MEMORY_TARGET="$REPO_ROOT/memory"
fi
if [ -n "$MEMORY_TARGET" ] && [ -d "$MEMORY_TARGET" ]; then
  ln -sfn "$MEMORY_TARGET" "$WT_PATH/memory"
fi

# .env
[ -f "$REPO_ROOT/.env" ] && ln -sfn "$REPO_ROOT/.env" "$WT_PATH/.env"

# .egregore-state.json
[ -f "$REPO_ROOT/.egregore-state.json" ] && ln -sfn "$REPO_ROOT/.egregore-state.json" "$WT_PATH/.egregore-state.json"

# .egregore-session-id
[ -f "$REPO_ROOT/.egregore-session-id" ] && ln -sfn "$REPO_ROOT/.egregore-session-id" "$WT_PATH/.egregore-session-id"

# egregore.json
[ -f "$REPO_ROOT/egregore.json" ] && [ ! -f "$WT_PATH/egregore.json" ] && ln -sfn "$REPO_ROOT/egregore.json" "$WT_PATH/egregore.json"

# --- Compute boundary for worktree (so isolation hook works) ---
# session-start.sh doesn't re-run for worktrees, so we compute it here.
HASH=$(echo -n "$WT_PATH" | md5 2>/dev/null || echo -n "$WT_PATH" | md5sum 2>/dev/null | cut -d' ' -f1)
BOUNDARY_FILE="/tmp/egregore-boundary-${HASH}.json"
MEMORY_DIR=""
[ -L "$WT_PATH/memory" ] && MEMORY_DIR=$(realpath "$WT_PATH/memory" 2>/dev/null || true)
# Managed repos: include main repo (worktree symlinks resolve there) + sibling repos
MANAGED_REPOS_JSON="[\"$REPO_ROOT\""
PARENT_DIR="$(dirname "$REPO_ROOT")"
_repos=$(jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' "$WT_PATH/egregore.json" 2>/dev/null || true)
for _r in $_repos; do
  [[ "$_r" == *".."* ]] && continue
  _resolved=$(realpath "$PARENT_DIR/$_r" 2>/dev/null || true)
  [ -z "$_resolved" ] && continue
  MANAGED_REPOS_JSON="$MANAGED_REPOS_JSON,\"$_resolved\""
done
MANAGED_REPOS_JSON="$MANAGED_REPOS_JSON]"
# Denied paths: other instances, but NOT the main repo (worktree is its child)
DENIED_JSON="[]"
REGISTRY="$HOME/.egregore/instances.json"
if [ -f "$REGISTRY" ]; then
  DENIED_JSON=$(jq --arg self "$REPO_ROOT" --arg wt "$WT_PATH" \
    '[.[] | select(.path != $self and .path != $wt) | .path]' \
    "$REGISTRY" 2>/dev/null || echo "[]")
fi
jq -n \
  --arg project_dir "$WT_PATH" \
  --arg memory_dir "$MEMORY_DIR" \
  --argjson managed_repos "$MANAGED_REPOS_JSON" \
  --argjson denied_paths "$DENIED_JSON" \
  '{project_dir: $project_dir, memory_dir: $memory_dir, managed_repos: $managed_repos, denied_paths: $denied_paths}' \
  > "$BOUNDARY_FILE.tmp" 2>/dev/null && mv "$BOUNDARY_FILE.tmp" "$BOUNDARY_FILE" 2>/dev/null || true

# --- Output the worktree path (ONLY stdout line) ---
echo "$WT_PATH"
