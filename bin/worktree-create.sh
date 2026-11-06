#!/usr/bin/env bash
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

# --- Resolve and fetch the configured base branch ---
SCRIPT_DIR="$REPO_ROOT"
CONFIG="$REPO_ROOT/egregore.json"
if [ -f "$REPO_ROOT/bin/lib/config.sh" ]; then
  # shellcheck source=bin/lib/config.sh
  source "$REPO_ROOT/bin/lib/config.sh"
fi
if ! BASE_BRANCH=$(_get_base_branch); then
  echo "Error: could not resolve the configured base branch" >&2
  exit 1
fi
git -C "$REPO_ROOT" fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true

# --- Create branch (idempotent — skip if exists) ---
if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  # A task branch starts at the integration branch but must never track it.
  # Otherwise `git push` can target origin/$BASE_BRANCH (especially when the
  # user's push.default is `upstream`) before the first explicit task push.
  git -C "$REPO_ROOT" branch --no-track "$BRANCH" "origin/$BASE_BRANCH" >/dev/null 2>&1 || {
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

# Installed tools (node_modules, .egregore/tools), so tests and the renderer
# run without an install step. Same helper as worktree.sh setup, loaded from
# this script's own bin/. Its one diagnostic, a link git cannot be made to
# ignore, goes to stderr, keeping stdout the worktree path only.
# shellcheck source=bin/lib/worktree-links.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/worktree-links.sh" && egregore_link_tools "$WT_PATH" "$REPO_ROOT" >&2

# --- Compute boundary for worktree (so isolation hook works) ---
# session-start.sh doesn't re-run for worktrees, so we compute it here through
# the shared computation (bin/boundary-guard.cjs write-cache). It recognizes a
# linked worktree: the main checkout it physically shares a git dir with is the
# caller-proven same instance (excluded from denied paths even on legacy
# registries without org_id) and a managed repo, and posture, lock and read
# roots come from the main checkout's config — a worktree that dropped them
# fell back to `standard` and stopped honoring `locked: true` (6b.3 audit).
bash "$REPO_ROOT/bin/node-run.sh" "$REPO_ROOT/bin/boundary-guard.cjs" write-cache "$WT_PATH" >/dev/null 2>&1 || true

# --- Session topic on the graph (fire-and-forget, detached) ---
# CLAUDE.md used to ask the model to run this after EnterWorktree with a
# "$(cat .egregore-session-id)" substitution; Claude Code's worktree isolation
# refuses that shape, so the write silently never happened. The hook runs
# outside that parser and already knows the slug and branch. Detached so the
# 2-second hook budget is untouched; graph.sh fails soft in local mode.
TOPIC="${SLUG//-/ }"
if [ -x "$WT_PATH/bin/graph-op.sh" ] && [ -e "$WT_PATH/.egregore-session-id" ]; then
  ( nohup bash "$WT_PATH/bin/graph-op.sh" set-current-topic "$TOPIC" "$BRANCH" >/dev/null 2>&1 & ) 2>/dev/null
fi

# --- Output the worktree path (ONLY stdout line) ---
echo "$WT_PATH"
