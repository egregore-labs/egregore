#!/usr/bin/env bash
# Graceful session-end adapter: write a structured session log to memory/sessions/.
# Receives runtime-neutral JSON on stdin from Claude Code or Pi.
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

# --- Deduplication: explicit /handoff or /wrap wins over baseline capture ---
TODAY=$(date +%d)
MONTH=$(date +%Y-%m)
if [ -n "$STARTED_AT" ]; then
  MONTH=$(echo "$STARTED_AT" | grep -oE '^[0-9]{4}-[0-9]{2}' || date +%Y-%m)
  TODAY=$(echo "$STARTED_AT" | grep -oE '^[0-9]{4}-[0-9]{2}-([0-9]{2})' | tail -c3 | sed 's/^-//' || date +%d)
fi

AUTHOR_LC=$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]')
DISPLAY_LC=$(echo "$DISPLAY_NAME" | tr '[:upper:]' '[:lower:]')
AUTHOR_PATTERN="-${AUTHOR_LC}-"
[ -n "$DISPLAY_LC" ] && AUTHOR_PATTERN="${AUTHOR_PATTERN}|-${DISPLAY_LC}-"
for CAPTURE_DIR in \
  "$SCRIPT_DIR/memory/handoffs/$MONTH" \
  "$SCRIPT_DIR/memory/wraps/$MONTH"; do
  [ -d "$CAPTURE_DIR" ] || continue
  # Match the canonical handle or display name in today's filename.
  EXISTING=""
  for CANDIDATE in "$CAPTURE_DIR/${TODAY}-"*.md; do
    [ -e "$CANDIDATE" ] || continue
    CANDIDATE_NAME="$(basename "$CANDIDATE" | tr '[:upper:]' '[:lower:]')"
    if printf '%s\n' "$CANDIDATE_NAME" | grep -Eq -- "$AUTHOR_PATTERN"; then
      EXISTING="$CANDIDATE_NAME"
      break
    fi
  done
  if [ -n "$EXISTING" ]; then
    rm -f "$BASELINE_FILE" 2>/dev/null
    exit 0
  fi
done

# --- Write through the shared capture engine -----------------------------
SUMMARY="${DURATION} session on ${TOPIC}; ${COMMIT_COUNT} commit(s), ${OBS_COUNT} observed action(s)."
{
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
} | bash "$SCRIPT_DIR/bin/capture-run.sh" \
      --mode baseline \
      --author "$AUTHOR" \
      --display-name "$DISPLAY_NAME" \
      --topic "$TOPIC" \
      --summary "$SUMMARY" \
      --session-id "$SESSION_ID" \
      --branch "${BRANCH:-develop}" \
      --date "$STARTED_AT" \
      --duration "$DURATION" \
      --async-push >/dev/null 2>&1 || true

# --- Clean up baseline ---
rm -f "$BASELINE_FILE" 2>/dev/null

exit 0
