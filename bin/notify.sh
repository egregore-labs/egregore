#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"

if [ ! -f "$CONFIG" ]; then
  echo "Error: egregore.json not found." >&2
  exit 1
fi

# Source .env if it exists (for local overrides)
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi

# Check if API mode or direct mode
# api_url comes from egregore.json (committed, non-secret)
# api_key comes from .env only (EGREGORE_API_KEY) — never from egregore.json
API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG")}"
API_KEY="${EGREGORE_API_KEY:-}"

if [ -n "$API_URL" ] && [ -n "$API_KEY" ]; then
  # === API MODE: Call Egregore API gateway ===

  send_to_person() {
    local name="$1"
    local message="$2"

    local response
    response=$(curl -s -X POST "${API_URL}/api/notify/send" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg to "$name" --arg message "$message" \
        '{to: $to, message: $message}')" \
      --max-time 10)

    if echo "$response" | jq -e '.status == "sent"' >/dev/null 2>&1; then
      echo "Sent"
      bash "$SCRIPT_DIR/bin/telemetry.sh" emit "notification" \
        '{"type":"send","status":"sent"}' 2>/dev/null &
    else
      local detail
      detail=$(echo "$response" | jq -r '.detail // .status // "unknown error"')
      if echo "$detail" | grep -qi "forbidden\|can't initiate\|bot was blocked"; then
        echo "Failed: DM not available. Tell $name to message the Egregore bot first (/start)."
      else
        echo "Failed: $detail"
      fi
      bash "$SCRIPT_DIR/bin/telemetry.sh" emit "notification" \
        '{"type":"send","status":"failed"}' 2>/dev/null &
    fi
  }

  send_to_group() {
    local message="$1"

    local response
    response=$(curl -s -X POST "${API_URL}/api/notify/group" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg message "$message" '{message: $message}')" \
      --max-time 10)

    if echo "$response" | jq -e '.status == "sent"' >/dev/null 2>&1; then
      echo "Sent"
      bash "$SCRIPT_DIR/bin/telemetry.sh" emit "notification" \
        '{"type":"group","status":"sent"}' 2>/dev/null &
    else
      local detail
      detail=$(echo "$response" | jq -r '.detail // .status // "unknown error"')
      echo "Failed: $detail"
      bash "$SCRIPT_DIR/bin/telemetry.sh" emit "notification" \
        '{"type":"group","status":"failed"}' 2>/dev/null &
    fi
  }

  test_connection() {
    local response
    response=$(curl -s -X GET "${API_URL}/api/notify/test" \
      -H "Authorization: Bearer $API_KEY" \
      --max-time 10)

    if echo "$response" | jq -e '.status == "ok"' >/dev/null 2>&1; then
      echo "Telegram connected via Egregore API"
    else
      echo "Failed to connect" >&2
      echo "$response" >&2
      exit 1
    fi
  }

  case "${1:-help}" in
    send)
      recipient="${2:?Usage: notify.sh send <name> <message>}"
      message="${3:?Usage: notify.sh send <name> <message>}"
      result=$(send_to_person "$recipient" "$message")
      if [[ "$result" == Failed* ]]; then
        send_to_group "@${recipient}: ${message}"
        echo "DM failed, sent to group instead. ${result}"
      else
        echo "$result"
      fi
      ;;
    group)
      message="${2:?Usage: notify.sh group <message>}"
      send_to_group "$message"
      ;;
    file)
      echo "File upload not yet supported via API. Use direct mode." >&2
      exit 1
      ;;
    test)
      test_connection
      ;;
    help|*)
      echo "Usage: notify.sh <command>"
      echo ""
      echo "Commands:"
      echo "  send <name> <message>   Send DM to a person (auto-fallback to group on failure)"
      echo "  group <message>         Send to the group chat"
      echo "  file <path> [caption]   Send a file to the group chat"
      echo "  test                    Test connection"
      ;;
  esac

else
  echo "Error: EGREGORE_API_KEY not set. Add it to .env (get it from your team admin or during setup)." >&2
  exit 1
fi
