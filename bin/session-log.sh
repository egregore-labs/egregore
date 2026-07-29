#!/usr/bin/env bash
# SessionEnd hook: write a structured session log to memory/sessions/.
# Receives JSON on stdin from Claude Code's SessionEnd hook.
# Runs BEFORE transcript-archive.sh (needs obs buffer + worktree intact).
# Makes sessions visible in local-mode without requiring /handoff or /wrap.
set -euo pipefail

# Suppress all output — hook scripts must not leak to terminal
exec >/dev/null 2>&1

SCRIPT_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR" ]; then
  SCRIPT_DIR="${CLAUDE_PROJECT_DIR:-}"
fi
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR" ]; then
  exit 0
fi

# --- Read hook input from stdin ---
INPUT=$(cat /dev/stdin 2>/dev/null || echo "{}")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Sanitize SESSION_ID
SESSION_ID=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
if [ -z "$SESSION_ID" ] || [ ${#SESSION_ID} -gt 128 ]; then
  exit 0
fi

# --- Gate: memory must exist ---
if [ ! -L "$SCRIPT_DIR/memory" ] && [ ! -d "$SCRIPT_DIR/memory" ]; then
  exit 0
fi

# --- Read identity ---
STATE_FILE="$SCRIPT_DIR/.egregore-state.json"
AUTHOR=""
DISPLAY_NAME=""
if [ -f "$STATE_FILE" ]; then
  AUTHOR=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null || true)
  DISPLAY_NAME=$(jq -r '.display_name // empty' "$STATE_FILE" 2>/dev/null || true)
fi
AUTHOR=$(echo "$AUTHOR" | tr -cd 'a-zA-Z0-9_-')
if [ -z "$AUTHOR" ]; then
  exit 0
fi

# --- Git metadata ---
BRANCH=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "")

# --- Derive topic from branch name ---
TOPIC=""
if [ -n "$BRANCH" ] && [ "$BRANCH" != "develop" ] && [ "$BRANCH" != "main" ]; then
  TOPIC=$(echo "$BRANCH" | sed 's|^dev/[^/]*/||; s|^feature/||; s|^bugfix/||' | tr '-' ' ')
fi
[ -z "$TOPIC" ] && TOPIC="session"

# --- Read baseline (written by session-start.sh) ---
BASELINE_FILE="/tmp/egregore-baseline-${SESSION_ID}.json"
BASELINE_COMMIT=""
BASELINE_STARTED=""
if [ -f "$BASELINE_FILE" ]; then
  BASELINE_COMMIT=$(jq -r '.commit // empty' "$BASELINE_FILE" 2>/dev/null || true)
  BASELINE_STARTED=$(jq -r '.started_at // empty' "$BASELINE_FILE" 2>/dev/null || true)
fi

# --- Extract timestamps from transcript ---
STARTED_AT=""
ENDED_AT=""
if [ -n "$TRANSCRIPT_PATH" ]; then
  TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"
  TRANSCRIPT_PATH=$(realpath "$TRANSCRIPT_PATH" 2>/dev/null || echo "")
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    STARTED_AT=$(head -1 "$TRANSCRIPT_PATH" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null || echo "")
    ENDED_AT=$(tail -1 "$TRANSCRIPT_PATH" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null || echo "")
  fi
fi

# Use baseline start time if transcript didn't provide one
[ -z "$STARTED_AT" ] && STARTED_AT="$BASELINE_STARTED"
# Fallback to now
[ -z "$ENDED_AT" ] && ENDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[ -z "$STARTED_AT" ] && STARTED_AT="$ENDED_AT"

# --- Compute duration ---
DURATION=""
DURATION_MIN=0
if [ -n "$STARTED_AT" ] && [ -n "$ENDED_AT" ]; then
  S_EPOCH=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$STARTED_AT'.replace('Z','+00:00')).timestamp()))" 2>/dev/null || echo "0")
  E_EPOCH=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$ENDED_AT'.replace('Z','+00:00')).timestamp()))" 2>/dev/null || echo "0")
  if [ "$S_EPOCH" -gt 0 ] 2>/dev/null && [ "$E_EPOCH" -gt 0 ] 2>/dev/null; then
    DURATION_MIN=$(( (E_EPOCH - S_EPOCH) / 60 ))
    if [ "$DURATION_MIN" -lt 1 ] 2>/dev/null; then
      DURATION="<1min"
    elif [ "$DURATION_MIN" -lt 60 ] 2>/dev/null; then
      DURATION="${DURATION_MIN}min"
    else
      HOURS=$(( DURATION_MIN / 60 ))
      MINS=$(( DURATION_MIN % 60 ))
      if [ "$MINS" -gt 0 ] 2>/dev/null; then
        DURATION="${HOURS}h ${MINS}min"
      else
        DURATION="${HOURS}h"
      fi
    fi
  fi
fi
[ -z "$DURATION" ] && DURATION="unknown"

# --- Read obs buffer for files touched ---
OBS_BUFFER="/tmp/egregore-obs-${SESSION_ID}.jsonl"
OBS_FILES=""
OBS_COUNT=0
if [ -f "$OBS_BUFFER" ] && [ -s "$OBS_BUFFER" ]; then
  OBS_COUNT=$(wc -l < "$OBS_BUFFER" 2>/dev/null | tr -d ' ')
  OBS_FILES=$(jq -r '.path // empty' "$OBS_BUFFER" 2>/dev/null | grep -v '^$' | grep -v '^unknown$' | sort -u | head -10 || true)
fi

# --- Count commits since baseline ---
COMMIT_COUNT=0
if [ -n "$BASELINE_COMMIT" ] && git -C "$SCRIPT_DIR" rev-parse "$BASELINE_COMMIT" >/dev/null 2>&1; then
  COMMIT_COUNT=$(git -C "$SCRIPT_DIR" rev-list "${BASELINE_COMMIT}..HEAD" --count 2>/dev/null || echo "0")
fi

# --- Empty session guard ---
# Skip if: duration < 2 min AND no commits AND no obs buffer activity
if [ "$DURATION_MIN" -lt 2 ] 2>/dev/null && [ "$COMMIT_COUNT" -eq 0 ] 2>/dev/null && [ "$OBS_COUNT" -eq 0 ] 2>/dev/null; then
  rm -f "$BASELINE_FILE" 2>/dev/null
  exit 0
fi

# --- Deduplication: skip if handoff exists for same author+date ---
TODAY=$(date +%d)
MONTH=$(date +%Y-%m)
if [ -n "$STARTED_AT" ]; then
  MONTH=$(echo "$STARTED_AT" | grep -oE '^[0-9]{4}-[0-9]{2}' || date +%Y-%m)
  TODAY=$(echo "$STARTED_AT" | grep -oE '^[0-9]{4}-[0-9]{2}-([0-9]{2})' | tail -c3 | sed 's/^-//' || date +%d)
fi

AUTHOR_LC=$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]')
DISPLAY_LC=$(echo "$DISPLAY_NAME" | tr '[:upper:]' '[:lower:]')
HANDOFF_DIR="$SCRIPT_DIR/memory/handoffs/$MONTH"
if [ -d "$HANDOFF_DIR" ]; then
  # Check for handoffs by this author today (match by author name or display name in filename)
  EXISTING=$(ls "$HANDOFF_DIR" 2>/dev/null | grep "^${TODAY}-" | grep -i "\-${AUTHOR_LC}\-\|${DISPLAY_LC:+-${DISPLAY_LC}-}" | head -1 || true)
  if [ -n "$EXISTING" ]; then
    rm -f "$BASELINE_FILE" 2>/dev/null
    exit 0
  fi
fi

# --- Build topic slug for filename ---
TOPIC_SLUG=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 40)
[ -z "$TOPIC_SLUG" ] && TOPIC_SLUG="session"

# --- Write session log ---
SESSIONS_DIR="$SCRIPT_DIR/memory/sessions/$MONTH"
mkdir -p "$SESSIONS_DIR" 2>/dev/null || exit 0

SESSION_FILE="$SESSIONS_DIR/${TODAY}-${AUTHOR_LC}-${TOPIC_SLUG}.md"

# Avoid overwriting if file exists (concurrent sessions with same slug)
if [ -f "$SESSION_FILE" ]; then
  SESSION_FILE="$SESSIONS_DIR/${TODAY}-${AUTHOR_LC}-${TOPIC_SLUG}-${SESSION_ID:(-6)}.md"
fi

{
  echo "# Session: $TOPIC"
  echo ""
  echo "**Author**: ${DISPLAY_NAME:-$AUTHOR}"
  echo "**Date**: $STARTED_AT"
  echo "**Branch**: ${BRANCH:-develop}"
  echo "**Duration**: $DURATION"
  echo ""

  if [ -n "$OBS_FILES" ]; then
    echo "## Files"
    echo "$OBS_FILES" | while read -r F; do
      [ -n "$F" ] && echo "- $F"
    done
    echo ""
  fi

  if [ "$COMMIT_COUNT" -gt 0 ] 2>/dev/null; then
    echo "## Commits"
    echo "$COMMIT_COUNT commits on ${BRANCH:-develop}"
    echo ""
  fi
} > "$SESSION_FILE" 2>/dev/null || exit 0

# --- Commit + push memory repo (best-effort, background) ---
(
  cd "$SCRIPT_DIR/memory" 2>/dev/null || exit 0
  git add "sessions/$MONTH/$(basename "$SESSION_FILE")" 2>/dev/null || exit 0
  git commit -m "session: ${DISPLAY_NAME:-$AUTHOR} — $TOPIC" --quiet 2>/dev/null || exit 0
  git -c rebase.empty=drop pull --rebase origin main --quiet 2>/dev/null || true
  git push origin main --quiet 2>/dev/null || true
) &

# --- Clean up baseline ---
rm -f "$BASELINE_FILE" 2>/dev/null

exit 0
