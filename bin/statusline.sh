#!/bin/bash
# Egregore statusline — shows branch + unsaved changes count.
# Runs on every assistant turn. Must be fast (<100ms).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Current branch
BRANCH=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "?")

# Count modified/untracked files (fast — no status porcelain)
CHANGED=$(git -C "$SCRIPT_DIR" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
STAGED=$(git -C "$SCRIPT_DIR" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((CHANGED + STAGED))

# Build output
if [ "$TOTAL" -gt 0 ]; then
  echo "⎇ $BRANCH · $TOTAL unsaved"
else
  echo "⎇ $BRANCH"
fi
