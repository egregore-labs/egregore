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
# Denied paths: shared computation (bin/boundary.sh compute-denied). The main
# repo is passed as the caller-proven same-instance allowance — this worktree
# was just created from it and physically shares its git dir — so it stays
# excluded even on legacy registries whose entries carry no org_id yet.
DENIED_JSON="[]"
REGISTRY="$HOME/.egregore/instances.json"
if [ -f "$REGISTRY" ]; then
  WT_ORG=$(jq -r '.org_id // empty' "$WT_PATH/egregore.json" 2>/dev/null || true)
  DENIED_JSON=$(bash "$REPO_ROOT/bin/boundary.sh" compute-denied \
    "$REGISTRY" "$WT_PATH" "$WT_ORG" "$REPO_ROOT" 2>/dev/null || echo "[]")
  case "$DENIED_JSON" in "["*) ;; *) DENIED_JSON="[]" ;; esac
fi
# Inherit posture, locked, and read roots from the main checkout's boundary
# cache: a worktree that silently dropped them fell back to `standard` and
# stopped honoring `locked: true` (found in the 6b.3 enforcement audit).
MAIN_DIGEST=$(printf '%s' "$REPO_ROOT" | md5 2>/dev/null || printf '%s' "$REPO_ROOT" | md5sum | cut -d' ' -f1)
MAIN_BOUNDARY="/tmp/egregore-boundary-${MAIN_DIGEST}.json"
POSTURE_JSON='{}'
if [ -f "$MAIN_BOUNDARY" ]; then
  POSTURE_JSON=$(jq -c '{posture: (.posture // "standard"), locked: (.locked // false), read_roots: (.read_roots // [])}' "$MAIN_BOUNDARY" 2>/dev/null || echo '{}')
fi
jq -n \
  --arg project_dir "$WT_PATH" \
  --arg memory_dir "$MEMORY_DIR" \
  --argjson managed_repos "$MANAGED_REPOS_JSON" \
  --argjson denied_paths "$DENIED_JSON" \
  --argjson inherited "$POSTURE_JSON" \
  '{project_dir: $project_dir, memory_dir: $memory_dir, managed_repos: $managed_repos, denied_paths: $denied_paths} + $inherited' \
  > "$BOUNDARY_FILE.tmp" 2>/dev/null && mv "$BOUNDARY_FILE.tmp" "$BOUNDARY_FILE" 2>/dev/null || true

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
