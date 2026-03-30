#!/bin/bash
# Fetches personal dashboard data: single API call + parallel git ops.
# Usage: bash bin/dashboard-data.sh [username] [time_range]
# Returns a single JSON object with all query results.
#
# time_range: P1D (today), P7D (week, default), P30D (month), P365D (all)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# --- Read config ---
API_URL=$(jq -r '.api_url // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
API_KEY=$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)
ORG=$(jq -r '.org_name // "Egregore"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "Egregore")
DATE=$(date '+%b %d')

# --- Detect user ---
GH_USER="${1:-}"
if [ -z "$GH_USER" ]; then
  STATE_FILE="$SCRIPT_DIR/.egregore-state.json"
  if [ -f "$STATE_FILE" ]; then
    GH_USER=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null)
  fi
  if [ -z "$GH_USER" ]; then
    GH_USER=$(git -C "$SCRIPT_DIR" config user.name 2>/dev/null || echo "unknown")
  fi
fi

# --- Time range (default P7D) ---
TIME_RANGE="${2:-P7D}"

# --- Read current session ID (client-side fallback for WAL-not-yet-drained) ---
PROJ_HASH=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
SESSION_ID=$(cat "$HOME/.egregore/session-${PROJ_HASH}.id" 2>/dev/null || echo "")

# --- Fire API call + git ops in parallel ---

# Graph data: single API call (all queries run server-side)
(
  GRAPH_STATUS="offline"
  GRAPH_REASON=""
  if [ -z "$API_URL" ] || [ -z "$API_KEY" ]; then
    GRAPH_REASON="missing_config"
  else
    HTTP_CODE=$(curl -s -o "$TMPDIR/dashboard_raw.json" -w "%{http_code}" \
      "${API_URL}/api/personal/dashboard?github_username=$(printf '%s' "$GH_USER" | jq -sRr @uri)&time_range=$(printf '%s' "$TIME_RANGE" | jq -sRr @uri)&session_id=$(printf '%s' "$SESSION_ID" | jq -sRr @uri)" \
      -H "Authorization: Bearer $API_KEY" \
      --connect-timeout 5 --max-time 15 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "000" ]; then
      GRAPH_REASON="unreachable"
    elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
      GRAPH_REASON="auth_error"
    elif [ "$HTTP_CODE" -ge 500 ] 2>/dev/null; then
      GRAPH_REASON="server_error"
    elif [ -s "$TMPDIR/dashboard_raw.json" ] && jq -e '.me' "$TMPDIR/dashboard_raw.json" >/dev/null 2>&1; then
      cp "$TMPDIR/dashboard_raw.json" "$TMPDIR/dashboard.json"
      GRAPH_STATUS="connected"
    else
      GRAPH_REASON="invalid_response"
    fi
  fi

  # If not connected, write status-only response
  if [ "$GRAPH_STATUS" != "connected" ]; then
    jq -n --arg status "$GRAPH_STATUS" --arg reason "$GRAPH_REASON" \
      '{graph_status: $status, graph_reason: $reason}' > "$TMPDIR/dashboard.json"
  else
    jq --arg status "$GRAPH_STATUS" '. + {graph_status: $status}' \
      "$TMPDIR/dashboard.json" > "$TMPDIR/dashboard_merged.json" \
      && mv "$TMPDIR/dashboard_merged.json" "$TMPDIR/dashboard.json"
  fi
) &
API_PID=$!

# Git: branch + dirty status (parallel, stays client-side)
(
  CURRENT=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "unknown")
  DIRTY="false"
  if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null | head -1)" ]; then
    DIRTY="true"
  fi
  jq -n --arg branch "$CURRENT" --argjson dirty "$DIRTY" \
    '{branch: $branch, dirty: $dirty}' > "$TMPDIR/git.json"
) &
GIT_PID=$!

# Local sessions: parse memory files when graph is offline (parallel)
(
  GH_LC=$(echo "$GH_USER" | tr '[:upper:]' '[:lower:]')
  DISPLAY_LC=""
  if [ -f "$SCRIPT_DIR/.egregore-state.json" ]; then
    DISPLAY_LC=$(jq -r '.display_name // empty' "$SCRIPT_DIR/.egregore-state.json" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  fi

  # Compute cutoff date from time range
  case "$TIME_RANGE" in
    P1D)   CUTOFF=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d '1 day ago' +%Y-%m-%d 2>/dev/null || echo "2000-01-01") ;;
    P7D)   CUTOFF=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d 2>/dev/null || echo "2000-01-01") ;;
    P30D)  CUTOFF=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d 2>/dev/null || echo "2000-01-01") ;;
    P365D) CUTOFF="2000-01-01" ;;
    *)     CUTOFF=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d 2>/dev/null || echo "2000-01-01") ;;
  esac

  # Scan sessions, wraps, and handoffs for this user
  for DIR in "$SCRIPT_DIR/memory/sessions" "$SCRIPT_DIR/memory/wraps" "$SCRIPT_DIR/memory/handoffs"; do
    [ -d "$DIR" ] || continue
    TYPE=$(basename "$DIR")
    find -L "$DIR" -name '*.md' -not -name 'index*' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -20 | while read -r MFILE; do
      [ -z "$MFILE" ] && continue
      M_AUTH=$(head -10 "$MFILE" 2>/dev/null | grep -m1 '^\*\*Author\*\*:' | sed 's/^\*\*Author\*\*:[[:space:]]*//' || true)
      [ -z "$M_AUTH" ] && continue
      M_AUTH_LC=$(echo "$M_AUTH" | tr '[:upper:]' '[:lower:]')
      # Filter to this user only
      [ "$M_AUTH_LC" != "$GH_LC" ] && { [ -z "$DISPLAY_LC" ] || [ "$M_AUTH_LC" != "$DISPLAY_LC" ]; } && continue
      M_DATE=$(head -10 "$MFILE" 2>/dev/null | grep -m1 '^\*\*Date\*\*:' | sed 's/^\*\*Date\*\*:[[:space:]]*//' || true)
      M_DAY="${M_DATE%%T*}"
      [ -n "$M_DAY" ] && [ "$M_DAY" \< "$CUTOFF" ] && continue
      M_BRANCH=$(head -10 "$MFILE" 2>/dev/null | grep -m1 '^\*\*Branch\*\*:' | sed 's/^\*\*Branch\*\*:[[:space:]]*//' || true)
      M_DURATION=$(head -10 "$MFILE" 2>/dev/null | grep -m1 '^\*\*Duration\*\*:' | sed 's/^\*\*Duration\*\*:[[:space:]]*//' || true)
      M_TOPIC=$(head -3 "$MFILE" 2>/dev/null | grep -m1 '^# ' | sed 's/^# [^:]*:[[:space:]]*//' || true)
      echo "${M_DATE}|${M_TOPIC}|${M_BRANCH}|${M_DURATION}|${TYPE}"
    done
  done | jq -Rn '
    [inputs | split("|") |
      {date: .[0], topic: .[1], branch: .[2], duration: .[3], type: .[4]}
    ] | sort_by(.date) | reverse | {
      sessions: .,
      session_count: length
    }
  ' 2>/dev/null > "$TMPDIR/local_sessions.json" || echo '{"sessions":[],"session_count":0}' > "$TMPDIR/local_sessions.json"
) &
LOCAL_PID=$!

# --- Wait for all ---
wait $API_PID $GIT_PID $LOCAL_PID 2>/dev/null || true

# --- Read results ---
GIT_INFO=$(cat "$TMPDIR/git.json" 2>/dev/null || echo '{"branch":"unknown","dirty":false}')
BRANCH=$(echo "$GIT_INFO" | jq -r '.branch' 2>/dev/null || echo "unknown")
LOCAL_SESSIONS=$(cat "$TMPDIR/local_sessions.json" 2>/dev/null || echo '{"sessions":[],"session_count":0}')
echo "$LOCAL_SESSIONS" | jq . >/dev/null 2>&1 || LOCAL_SESSIONS='{"sessions":[],"session_count":0}'

# --- Client-side current session fallback ---
# If the graph returned no current_session (WAL hasn't drained yet),
# inject one from the local session ID file so the TUI always renders it.
DASHBOARD=$(cat "$TMPDIR/dashboard.json" 2>/dev/null || echo '{"graph_status":"offline"}')
CS_ID=$(echo "$DASHBOARD" | jq -r '.current_session.id // empty' 2>/dev/null)
if [ -z "$CS_ID" ] && [ -n "$SESSION_ID" ]; then
  DASHBOARD=$(echo "$DASHBOARD" | jq \
    --arg sid "$SESSION_ID" \
    --arg branch "$BRANCH" \
    '.current_session = {id: $sid, status: "active", topic: null, branch: $branch}' 2>/dev/null || echo "$DASHBOARD")
fi

# --- Derive time range label ---
case "$TIME_RANGE" in
  P1D)   RANGE_LABEL="today" ;;
  P7D)   RANGE_LABEL="last 7 days" ;;
  P30D)  RANGE_LABEL="last 30 days" ;;
  P365D) RANGE_LABEL="all time" ;;
  *)     RANGE_LABEL="last 7 days" ;;
esac

# --- Merge server response + local data ---
echo "$DASHBOARD" | jq \
  --arg org "$ORG" \
  --arg date "$DATE" \
  --arg range_label "$RANGE_LABEL" \
  --argjson git "$GIT_INFO" \
  --argjson local_sessions "$LOCAL_SESSIONS" \
  '. + {org: $org, date: $date, range_label: $range_label, git: $git, local_sessions: $local_sessions}'
