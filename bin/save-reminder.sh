#!/usr/bin/env bash
# save-reminder.sh — gentle nudge when there are unsaved changes.
# Called by Stop hook. Output is injected into Claude's context.
# Silent when nothing to save. 10-minute cooldown between reminders.

set -euo pipefail
cd "$(dirname "$0")/.." 2>/dev/null || exit 0

# Guard: if working directory was deleted (e.g., worktree removed), exit silently
if ! pwd >/dev/null 2>&1; then
  exit 0
fi

# Stable key per project directory (survives across script invocations)
PROJECT_HASH=$(echo "$PWD" | md5sum 2>/dev/null | cut -c1-8 || md5 -q -s "$PWD" 2>/dev/null | cut -c1-8 || echo "default")
COOLDOWN_FILE="/tmp/.egregore-save-reminder-${PROJECT_HASH}"
COOLDOWN_SECONDS=600  # 10 minutes

# Check cooldown — don't nag
if [ -f "$COOLDOWN_FILE" ]; then
  LAST=$(stat -f %m "$COOLDOWN_FILE" 2>/dev/null || stat -c %Y "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ $((NOW - LAST)) -lt $COOLDOWN_SECONDS ]; then
    exit 0
  fi
fi

# Check for unsaved changes
MEMORY_DIRTY=""
EGREGORE_DIRTY=""

# Memory: uncommitted or unpushed changes
if [ -d memory/.git ]; then
  if [ -n "$(git -C memory status --porcelain 2>/dev/null)" ]; then
    MEMORY_DIRTY="uncommitted"
  elif [ -n "$(git -C memory log origin/main..HEAD --oneline 2>/dev/null)" ]; then
    MEMORY_DIRTY="unpushed"
  fi
fi

# Egregore: uncommitted changes (not untracked — those are normal)
if [ -n "$(git diff --name-only 2>/dev/null)" ]; then
  EGREGORE_DIRTY="yes"
fi

# Nothing to save? Stay silent.
if [ -z "$MEMORY_DIRTY" ] && [ -z "$EGREGORE_DIRTY" ]; then
  exit 0
fi

# Build hint
PARTS=""
if [ -n "$MEMORY_DIRTY" ]; then
  COUNT=$(git -C memory status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  PARTS="$COUNT memory file(s)"
fi
if [ -n "$EGREGORE_DIRTY" ]; then
  COUNT=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  if [ -n "$PARTS" ]; then
    PARTS="$PARTS + $COUNT code file(s)"
  else
    PARTS="$COUNT code file(s)"
  fi
fi

# Touch cooldown file
touch "$COOLDOWN_FILE"

echo "Unsaved changes: $PARTS. /wrap to close session, /save to keep working."
