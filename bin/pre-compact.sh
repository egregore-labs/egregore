#!/bin/bash
# PreCompact hook — fires before context compaction.
# Re-injects branch state and reminds to save if there are unsaved changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

BRANCH=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "unknown")
CHANGED=$(git -C "$SCRIPT_DIR" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
STAGED=$(git -C "$SCRIPT_DIR" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((CHANGED + STAGED))

# Re-inject state so it survives compaction
echo "CONTEXT_REINJECT:"
echo "  Branch: $BRANCH"
echo "  Develop: $(git -C "$SCRIPT_DIR" rev-parse --short develop 2>/dev/null || echo 'unknown')"

if [ "$TOTAL" -gt 0 ]; then
  echo "  Unsaved changes: $TOTAL files"
  echo ""
  echo "IMPORTANT: Tell the user they have $TOTAL unsaved changes. Suggest running /save before continuing."
fi
