#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"

if [ ! -f "$CONFIG" ]; then
  echo "Error: egregore.json not found." >&2
  exit 1
fi

# --- Mode detection ---
_MODE=$(jq -r '.mode // "connected"' "$CONFIG" 2>/dev/null)

# Public relay for local mode group messages.
# No API key needed — rate-limited, group messages only.
RELAY_URL="https://egregore-production-55f2.up.railway.app"

# Load specific variables from .env if it exists (safe extraction, no arbitrary code execution)
if [ -f "$SCRIPT_DIR/.env" ]; then
  EGREGORE_API_URL="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
  EGREGORE_API_KEY="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
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

elif [ "$_MODE" = "local" ]; then
  # === LOCAL MODE: Group messages via public relay, DMs not available ===
  # Telegram config: prefer .egregore-state.json (symlinked across worktrees),
  # fall back to egregore.json for backward compatibility.
  STATE_FILE="$SCRIPT_DIR/.egregore-state.json"

  _read_telegram_config() {
    local field="$1"
    local val
    val=$(jq -r ".$field // empty" "$STATE_FILE" 2>/dev/null)
    [ -z "$val" ] && val=$(jq -r ".$field // empty" "$CONFIG" 2>/dev/null)
    echo "$val"
  }

  send_to_person() {
    echo "DMs require managed hosting. Group message sent instead."
    send_to_group "@${1}: ${2}"
  }

  send_to_group() {
    local message="$1"
    local chat_id
    chat_id=$(_read_telegram_config telegram_chat_id)
    local group_link
    group_link=$(_read_telegram_config telegram_group_link)

    if [ -z "$chat_id" ] && [ -z "$group_link" ]; then
      echo '{"status":"offline","reason":"no_telegram_group"}'
      return
    fi

    local slug
    slug=$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)
    local org_name
    org_name=$(jq -r '.org_name // empty' "$CONFIG" 2>/dev/null)

    local response
    response=$(curl -s -X POST "${RELAY_URL}/api/notify/relay" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg chat_id "$chat_id" \
        --arg group_link "$group_link" \
        --arg message "$message" \
        --arg slug "$slug" \
        --arg org_name "$org_name" \
        '{chat_id: $chat_id, group_link: $group_link, message: $message, slug: $slug, org_name: $org_name}')" \
      --max-time 10 2>/dev/null)

    if echo "$response" | jq -e '.status == "sent"' >/dev/null 2>&1; then
      echo "Sent"
    else
      local detail
      detail=$(echo "$response" | jq -r '.detail // .status // "relay unavailable"' 2>/dev/null)
      echo "Failed: $detail"
    fi
  }

  test_connection() {
    local group_link
    group_link=$(_read_telegram_config telegram_group_link)
    if [ -n "$group_link" ]; then
      echo "Telegram group configured (local mode — group messages via relay)"
    else
      echo "No Telegram group configured. Run /telegram-connect."
    fi
  }

else
  # === OFFLINE MODE: No API key, not local — skip notifications ===
  send_to_person() { echo '{"status":"offline","reason":"no_api_key"}'; }
  send_to_group() { echo '{"status":"offline","reason":"no_api_key"}'; }
  test_connection() { echo '{"status":"offline","reason":"no_api_key"}'; }
fi

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
