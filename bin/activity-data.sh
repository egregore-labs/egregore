#!/bin/bash
# Fetches all activity dashboard data: single API call + parallel git/disk ops.
# Usage: bash bin/activity-data.sh [username]
# Returns a single JSON object with all query results.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# --- Read config ---
API_URL=$(jq -r '.api_url // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
API_KEY=$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2-)
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

EMPTY='{"fields":[],"values":[]}'

# --- Fire API call + git/disk ops in parallel ---

# Graph data: single API call (all queries run server-side)
(
  GRAPH_STATUS="offline"
  GRAPH_REASON=""
  if [ -z "$API_URL" ] || [ -z "$API_KEY" ]; then
    GRAPH_REASON="missing_config"
  else
    # Store HTTP status code alongside response body
    HTTP_CODE=$(curl -s -o "$TMPDIR/activity_raw.json" -w "%{http_code}" \
      "${API_URL}/api/activity/dashboard?github_username=$(printf '%s' "$GH_USER" | jq -sRr @uri)" \
      -H "Authorization: Bearer $API_KEY" \
      --connect-timeout 5 --max-time 15 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "000" ]; then
      GRAPH_REASON="unreachable"
    elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
      GRAPH_REASON="auth_error"
    elif [ "$HTTP_CODE" -ge 500 ] 2>/dev/null; then
      GRAPH_REASON="server_error"
    elif [ -s "$TMPDIR/activity_raw.json" ] && jq -e '.me' "$TMPDIR/activity_raw.json" >/dev/null 2>&1; then
      cp "$TMPDIR/activity_raw.json" "$TMPDIR/activity.json"
      GRAPH_STATUS="connected"
    else
      GRAPH_REASON="invalid_response"
    fi
  fi

  # If not connected, write status-only response
  if [ "$GRAPH_STATUS" != "connected" ]; then
    jq -n --arg status "$GRAPH_STATUS" --arg reason "$GRAPH_REASON" \
      '{graph_status: $status, graph_reason: $reason}' > "$TMPDIR/activity.json"
  else
    # Inject graph_status into successful response
    jq --arg status "$GRAPH_STATUS" '. + {graph_status: $status}' \
      "$TMPDIR/activity.json" > "$TMPDIR/activity_merged.json" \
      && mv "$TMPDIR/activity_merged.json" "$TMPDIR/activity.json"
  fi
) &
API_PID=$!

# Git/disk: runs in parallel (stays client-side)
(
  # Sync
  git -C "$SCRIPT_DIR" fetch origin --quiet 2>/dev/null || true
  CURRENT=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "unknown")
  if [ "$CURRENT" != "develop" ]; then
    git -C "$SCRIPT_DIR" fetch origin develop:develop --quiet 2>/dev/null || true
  fi
  if [[ "$CURRENT" == dev/* ]]; then
    git -C "$SCRIPT_DIR" rebase develop --quiet >/dev/null 2>&1 || git -C "$SCRIPT_DIR" rebase --abort >/dev/null 2>&1 || true
  fi

  # Memory sync
  if [ -d "$SCRIPT_DIR/memory/.git" ] || [ -L "$SCRIPT_DIR/memory" ]; then
    git -C "$SCRIPT_DIR/memory" fetch origin main --quiet 2>/dev/null || true
    LOCAL=$(git -C "$SCRIPT_DIR/memory" rev-parse HEAD 2>/dev/null || echo "")
    REMOTE=$(git -C "$SCRIPT_DIR/memory" rev-parse origin/main 2>/dev/null || echo "")
    if [ -n "$LOCAL" ] && [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
      git -C "$SCRIPT_DIR/memory" pull origin main --quiet 2>/dev/null || true
    fi
  fi

  # PRs
  PRS=$(cd "$SCRIPT_DIR" && gh pr list --base develop --state open --json number,title,author 2>/dev/null || echo "[]")
  echo "$PRS" > "$TMPDIR/prs.json"

  # Disk cross-reference
  MONTH=$(date +%Y-%m)
  TODAY=$(date +%d)
  YESTERDAY=$(date -v-1d +%d 2>/dev/null || date -d 'yesterday' +%d 2>/dev/null || echo "00")
  HANDOFFS=$(ls -1 "$SCRIPT_DIR/memory/handoffs/$MONTH/" 2>/dev/null | grep "^${TODAY}-\|^${YESTERDAY}-" 2>/dev/null | head -10 || echo "")
  echo "$HANDOFFS" > "$TMPDIR/disk_handoffs.txt"

  DECISIONS=$(ls -1t "$SCRIPT_DIR/memory/knowledge/decisions/" 2>/dev/null | head -5 || echo "")
  echo "$DECISIONS" > "$TMPDIR/disk_decisions.txt"
) &
GIT_PID=$!

# --- Wait for both ---
wait $API_PID $GIT_PID

# --- Read results ---
PRS=$(cat "$TMPDIR/prs.json" 2>/dev/null || echo "[]")
echo "$PRS" | jq . >/dev/null 2>&1 || PRS="[]"
DISK_HANDOFFS=$(cat "$TMPDIR/disk_handoffs.txt" 2>/dev/null || echo "")
DISK_DECISIONS=$(cat "$TMPDIR/disk_decisions.txt" 2>/dev/null || echo "")

# --- Merge server response + local git/disk data ---
jq -n \
  --arg org "$ORG" \
  --arg date "$DATE" \
  --slurpfile activity "$TMPDIR/activity.json" \
  --argjson prs "$PRS" \
  --arg disk_handoffs "$DISK_HANDOFFS" \
  --arg disk_decisions "$DISK_DECISIONS" \
  '$activity[0] + {
    org: $org,
    date: $date,
    prs: $prs,
    disk: {handoffs: $disk_handoffs, decisions: $disk_decisions}
  }'
