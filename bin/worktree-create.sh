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
# Memory
if [ -L "$REPO_ROOT/memory" ]; then
  MEMORY_TARGET=$(realpath "$REPO_ROOT/memory" 2>/dev/null)
  if [ -n "$MEMORY_TARGET" ] && [ -d "$MEMORY_TARGET" ]; then
    ln -sfn "$MEMORY_TARGET" "$WT_PATH/memory"
  fi
fi

# .env
[ -f "$REPO_ROOT/.env" ] && ln -sfn "$REPO_ROOT/.env" "$WT_PATH/.env"

# .egregore-state.json
[ -f "$REPO_ROOT/.egregore-state.json" ] && ln -sfn "$REPO_ROOT/.egregore-state.json" "$WT_PATH/.egregore-state.json"

# .egregore-session-id
[ -f "$REPO_ROOT/.egregore-session-id" ] && ln -sfn "$REPO_ROOT/.egregore-session-id" "$WT_PATH/.egregore-session-id"

# egregore.json
[ -f "$REPO_ROOT/egregore.json" ] && [ ! -f "$WT_PATH/egregore.json" ] && ln -sfn "$REPO_ROOT/egregore.json" "$WT_PATH/egregore.json"

# --- PID tracking (walk up to find Claude Code process) ---
_pid=$$
_cc_pid=""
while [ "$_pid" -gt 1 ] 2>/dev/null; do
  _cmd=$(ps -o comm= -p "$_pid" 2>/dev/null | tr -d ' ')
  case "$_cmd" in
    node|claude) _cc_pid="$_pid"; break ;;
  esac
  _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
done
echo "${_cc_pid:-$$}" > "$WT_PATH/.egregore-worktree-pid"

# --- Output the worktree path (ONLY stdout line) ---
echo "$WT_PATH"
