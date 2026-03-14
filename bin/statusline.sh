#!/bin/bash
# Egregore statusline — shows branch + unsaved changes count + worktree indicator.
# Runs on every assistant turn. Must be fast (<100ms).
set -euo pipefail

# pwd is the session working directory (worktree-aware), CLAUDE_PROJECT_DIR
# always points to the main repo. Use pwd.
REPO_DIR="$(pwd)"

# Current branch
BRANCH=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo "?")

# Detect worktree: if git-common-dir is outside the toplevel, we're in a worktree
WORKTREE=""
TOPLEVEL=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null || true)
COMMON=$(git -C "$REPO_DIR" rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$TOPLEVEL" ] && [ -n "$COMMON" ]; then
  # COMMON may be relative to REPO_DIR, resolve it
  COMMON_ABS=$(cd "$REPO_DIR" && cd "$COMMON" 2>/dev/null && pwd)
  if [[ "$COMMON_ABS" != "$TOPLEVEL"* ]]; then
    WORKTREE=$(basename "$TOPLEVEL")
  fi
fi

# Count modified/untracked files (fast — no status porcelain)
CHANGED=$(git -C "$REPO_DIR" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
STAGED=$(git -C "$REPO_DIR" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((CHANGED + STAGED))

# Build output
OUT="⎇ $BRANCH"
[ -n "$WORKTREE" ] && OUT="$OUT · ⧉ $WORKTREE"
[ "$TOTAL" -gt 0 ] && OUT="$OUT · $TOTAL unsaved"
echo "$OUT"
