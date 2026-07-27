#!/usr/bin/env bash
# SessionEnd hook: archive session transcript.
# Receives JSON on stdin from Claude Code's SessionEnd hook.
# Works for all orgs:
#   - Always uploads to API (Supabase Storage for customers, Neo4j index for all)
#   - Optionally git-pushes to egregore-transcripts if the repo exists locally (CL)
# All output suppressed — hook scripts must not leak secrets or paths.
set -euo pipefail

# Suppress all output — nothing should reach the user's terminal
exec >/dev/null 2>&1

SCRIPT_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR" ]; then
  # Worktree directory may have been deleted — try CLAUDE_PROJECT_DIR
  SCRIPT_DIR="${CLAUDE_PROJECT_DIR:-}"
fi
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR" ]; then
  exit 0  # No valid project dir — skip archival silently
fi

# --- Read hook input from stdin ---
INPUT=$(cat /dev/stdin 2>/dev/null || echo "{}")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)

if [ -z "$SESSION_ID" ] || [ -z "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# Sanitize SESSION_ID: allow only alphanumeric, hyphens, underscores (UUID format)
SESSION_ID=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
if [ -z "$SESSION_ID" ] || [ ${#SESSION_ID} -gt 128 ]; then
  exit 0
fi

# Expand ~ safely and resolve to absolute path
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"
TRANSCRIPT_PATH=$(realpath "$TRANSCRIPT_PATH" 2>/dev/null || echo "")

# Validate: must exist and be under ~/.claude/ (prevent arbitrary file reads)
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi
case "$TRANSCRIPT_PATH" in
  "$HOME/.claude/"*) ;; # valid
  *) exit 0 ;;          # reject anything outside ~/.claude/
esac

# --- Check user consent ---
# Transcript sharing is OFF by default (opt-in). Users must explicitly
# set transcript_sharing: true in .egregore-state.json to enable.
STATE_FILE="$SCRIPT_DIR/.egregore-state.json"
if [ -f "$STATE_FILE" ]; then
  USER_CONSENT=$(jq -r '.transcript_sharing // "false"' "$STATE_FILE" 2>/dev/null || echo "false")
  if [ "$USER_CONSENT" != "true" ]; then
    exit 0
  fi
else
  exit 0
fi

# --- Read config ---
CONFIG="$SCRIPT_DIR/egregore.json"
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

GITHUB_ORG=$(jq -r '.github_org // empty' "$CONFIG" 2>/dev/null || true)
SLUG=$(echo "$GITHUB_ORG" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
if [ -z "$SLUG" ] || [ ${#SLUG} -gt 64 ]; then
  exit 0
fi

# --- Extract metadata (no secrets, sanitized) ---
AUTHOR=""
if [ -f "$STATE_FILE" ]; then
  AUTHOR=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null || true)
  AUTHOR=$(echo "$AUTHOR" | tr -cd 'a-zA-Z0-9_-')
fi

BRANCH=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "")
STARTED_AT=$(head -1 "$TRANSCRIPT_PATH" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null || echo "")
ENDED_AT=$(tail -1 "$TRANSCRIPT_PATH" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null || echo "")
MESSAGE_COUNT=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
SIZE_BYTES=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')

# --- Drain observation buffer → ActivitySummary node via WAL ---
OBS_BUFFER="/tmp/egregore-obs-${SESSION_ID}.jsonl"
if [ -f "$OBS_BUFFER" ] && [ -s "$OBS_BUFFER" ]; then
  OBS_COUNT=$(wc -l < "$OBS_BUFFER" 2>/dev/null | tr -d ' ')
  OBS_TOOLS=$(jq -r '.tool // empty' "$OBS_BUFFER" 2>/dev/null | sort -u | paste -sd',' -)
  OBS_PATHS=$(jq -r '.path // empty' "$OBS_BUFFER" 2>/dev/null | sort -u | head -50 | paste -sd',' -)

  # Build arrays as JSON strings for Cypher
  OBS_TOOLS_JSON=$(echo "$OBS_TOOLS" | tr ',' '\n' | jq -R . | jq -s '.' 2>/dev/null || echo '[]')
  OBS_PATHS_JSON=$(echo "$OBS_PATHS" | tr ',' '\n' | jq -R . | jq -s '.' 2>/dev/null || echo '[]')

  ACTIVITY_CYPHER="MATCH (s:Session {id: \$sid})
    MERGE (a:ActivitySummary {session: \$sid})
    SET a.tools = \$tools, a.paths = \$paths, a.count = \$count, a.createdAt = datetime()
    MERGE (s)-[:HAS_ACTIVITY]->(a)"
  ACTIVITY_PARAMS=$(jq -n -c \
    --arg sid "$SESSION_ID" \
    --argjson tools "$OBS_TOOLS_JSON" \
    --argjson paths "$OBS_PATHS_JSON" \
    --argjson count "${OBS_COUNT:-0}" \
    '{sid: $sid, tools: $tools, paths: $paths, count: $count}')

  bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$ACTIVITY_CYPHER" "$ACTIVITY_PARAMS" 2>/dev/null || true

  # --- Pulse: copy buffer for post-session synthesis before cleanup ---
  PULSE_BUFFER="/tmp/egregore-pulse-${SESSION_ID}.jsonl"
  cp "$OBS_BUFFER" "$PULSE_BUFFER" 2>/dev/null || true

  # Clean up buffer and compact sequence counter
  rm -f "$OBS_BUFFER"
  rm -f "/tmp/egregore-compact-seq-${SESSION_ID}" 2>/dev/null

  # --- Launch Pulse synthesis (background, non-blocking) ---
  bash "$SCRIPT_DIR/bin/pulse.sh" \
    "$SESSION_ID" "$AUTHOR" "$BRANCH" "$PULSE_BUFFER" "$TRANSCRIPT_PATH" \
    &
fi

# --- Emit session_end telemetry + flush buffer (background, non-blocking) ---
(
  # Calculate duration from transcript timestamps
  DURATION_MS=0
  if [ -n "$STARTED_AT" ] && [ -n "$ENDED_AT" ]; then
    # Parse ISO timestamps to epoch seconds (macOS + Linux compatible)
    START_EPOCH=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$STARTED_AT'.replace('Z','+00:00')).timestamp() * 1000))" 2>/dev/null || echo "0")
    END_EPOCH=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$ENDED_AT'.replace('Z','+00:00')).timestamp() * 1000))" 2>/dev/null || echo "0")
    if [ "$START_EPOCH" -gt 0 ] 2>/dev/null && [ "$END_EPOCH" -gt 0 ] 2>/dev/null; then
      DURATION_MS=$((END_EPOCH - START_EPOCH))
    fi
  fi

  # Set identity env vars for telemetry
  export EGREGORE_USER="$AUTHOR"
  export EGREGORE_SESSION_ID="$SESSION_ID"

  bash "$SCRIPT_DIR/bin/telemetry.sh" emit "session_end" \
    "$(jq -n --argjson duration "$DURATION_MS" --argjson messages "${MESSAGE_COUNT:-0}" \
      '{duration_ms: $duration, message_count: $messages}')" 2>/dev/null || true

  bash "$SCRIPT_DIR/bin/telemetry.sh" flush 2>/dev/null || true

  # Drain graph WAL on session end
  bash "$SCRIPT_DIR/bin/graph-wal.sh" drain 2>/dev/null || true
) &

# --- Worktree cleanup on session end ---
# Always clean up worktrees when the session ends. There is no mechanism
# to resume a worktree, so keeping them is pointless.

# 1. Process any explicit cleanup markers (written by /wrap)
for MARKER_FILE in "$HOME/.egregore"/worktree-cleanup-*.marker; do
  [ -f "$MARKER_FILE" ] || continue
  WT_CLEANUP_PATH=$(cat "$MARKER_FILE" 2>/dev/null)
  if [ -n "$WT_CLEANUP_PATH" ] && [ -d "$WT_CLEANUP_PATH" ]; then
    bash "$SCRIPT_DIR/bin/worktree.sh" cleanup "$WT_CLEANUP_PATH" 2>/dev/null || true
  fi
  rm -f "$MARKER_FILE" 2>/dev/null || true
done

# 2. If this session was running in a worktree, clean it up too
if [ -f "$SCRIPT_DIR/.git" ] 2>/dev/null; then
  # .git as a FILE (not directory) means this is a worktree
  bash "$SCRIPT_DIR/bin/worktree.sh" cleanup "$SCRIPT_DIR" 2>/dev/null || true
fi

# --- Gzip to temp file ---
TMP_FILE="/tmp/egregore-transcript-${SESSION_ID}.jsonl.gz"
gzip -c "$TRANSCRIPT_PATH" > "$TMP_FILE" 2>/dev/null || exit 0

# --- Background: API upload + optional git ---
(
  ENV_FILE="$SCRIPT_DIR/.env"
  API_URL=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null || true)
  API_KEY=""
  if [ -f "$ENV_FILE" ]; then
    API_KEY=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)
  fi

  API_OK=false

  # Always try API upload (stores in Supabase for customers, indexes in Neo4j for all)
  if [ -n "$API_URL" ] && [ -n "$API_KEY" ]; then
    if curl -sf -X POST "${API_URL}/api/transcript/upload" \
      -H "Authorization: Bearer ${API_KEY}" \
      -F "file=@${TMP_FILE}" \
      -F "session_id=${SESSION_ID}" \
      -F "author=${AUTHOR}" \
      -F "branch=${BRANCH}" \
      -F "started_at=${STARTED_AT}" \
      -F "ended_at=${ENDED_AT}" \
      -F "message_count=${MESSAGE_COUNT}" \
      -F "size_bytes=${SIZE_BYTES}" \
      --max-time 30 2>/dev/null; then
      API_OK=true
    fi
  fi

  # Optional: git push to transcripts repo if it exists locally
  TRANSCRIPTS_DIR=$(jq -r '.transcripts_dir // empty' "$CONFIG" 2>/dev/null || true)
  [ -z "$TRANSCRIPTS_DIR" ] && TRANSCRIPTS_DIR="$SCRIPT_DIR/../egregore-transcripts"
  if [ -d "$TRANSCRIPTS_DIR/.git" ]; then
    if [ -n "$STARTED_AT" ]; then
      MONTH=$(echo "$STARTED_AT" | grep -oE '^[0-9]{4}-[0-9]{2}' || date -u +%Y-%m)
    else
      MONTH=$(date -u +%Y-%m)
    fi

    DEST_DIR="$TRANSCRIPTS_DIR/transcripts/$SLUG/$MONTH"
    DEST_FILE="$DEST_DIR/${SESSION_ID}.jsonl.gz"

    if [ ! -f "$DEST_FILE" ]; then
      mkdir -p "$DEST_DIR"
      cp "$TMP_FILE" "$DEST_FILE" 2>/dev/null || true

      cd "$TRANSCRIPTS_DIR"
      git add "transcripts/$SLUG/$MONTH/${SESSION_ID}.jsonl.gz" 2>/dev/null || true
      git commit -m "Archive session $SESSION_ID" \
        --author="${AUTHOR:-egregore} <${AUTHOR:-egregore}@users.noreply.github.com>" \
        2>/dev/null || true
      git push origin main 2>/dev/null || {
        echo "$SESSION_ID" >> "$SCRIPT_DIR/.transcript-retry-queue"
      }
    fi
  fi

  # Queue for retry if API failed and no git repo either
  if [ "$API_OK" = "false" ] && [ ! -d "$TRANSCRIPTS_DIR/.git" ]; then
    echo "$SESSION_ID" >> "$SCRIPT_DIR/.transcript-retry-queue"
  fi

  # Clean up temp file
  rm -f "$TMP_FILE"
) &

exit 0
