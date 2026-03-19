#!/bin/bash
# WorktreeRemove hook — handles cleanup when a worktree is removed.
# Receives {"worktree_path": "<path>"} on stdin. Best-effort, always exit 0.

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')
WT_PATH=$(echo "$INPUT" | jq -r '.worktree_path // empty' 2>/dev/null)

if [ -z "$WT_PATH" ] || [ ! -d "$WT_PATH" ]; then
  exit 0
fi

# --- Resolve main repo for git operations ---
REPO_ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$REPO_ROOT" ] || [ -f "$REPO_ROOT/.git" ]; then
  # In a worktree or no CLAUDE_PROJECT_DIR — trace from the worktree path
  if [ -f "$WT_PATH/.git" ]; then
    WT_GITDIR=$(sed 's/^gitdir: //' "$WT_PATH/.git" 2>/dev/null)
    REPO_ROOT=$(cd "$WT_GITDIR/../../.." 2>/dev/null && pwd) || REPO_ROOT=""
  fi
fi

# --- Remove from instance registry ---
REGISTRY="$HOME/.egregore/instances.json"
if [ -f "$REGISTRY" ]; then
  RESOLVED_WT=$(realpath "$WT_PATH" 2>/dev/null || echo "$WT_PATH")
  UPDATED=$(jq --arg p "$RESOLVED_WT" '[.[] | select(.path != $p)]' "$REGISTRY" 2>/dev/null)
  if [ -n "$UPDATED" ]; then
    echo "$UPDATED" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
  fi
fi

# --- Remove worktree ---
if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/.git" ]; then
  git -C "$REPO_ROOT" worktree remove "$WT_PATH" --force 2>/dev/null || true
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
else
  # Fallback: just remove the directory
  rm -rf "$WT_PATH" 2>/dev/null || true
fi

# --- Clean up stale marker files ---
for MARKER_FILE in "$HOME/.egregore"/worktree-cleanup-*.marker; do
  [ -f "$MARKER_FILE" ] || continue
  MARKER_PATH=$(cat "$MARKER_FILE" 2>/dev/null)
  if [ "$MARKER_PATH" = "$WT_PATH" ] || [ ! -d "$MARKER_PATH" ]; then
    rm -f "$MARKER_FILE" 2>/dev/null || true
  fi
done

exit 0
