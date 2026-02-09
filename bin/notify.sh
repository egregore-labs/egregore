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
    else
      local detail
      detail=$(echo "$response" | jq -r '.detail // .status // "unknown error"')
      echo "Failed: $detail"
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
    else
      local detail
      detail=$(echo "$response" | jq -r '.detail // .status // "unknown error"')
      echo "Failed: $detail"
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
      send_to_person "$recipient" "$message"
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
      echo "  send <name> <message>   Send to a person (DM or group fallback)"
      echo "  group <message>         Send to the group chat"
      echo "  file <path> [caption]   Send a file to the group chat"
      echo "  test                    Test connection"
      ;;
  esac

else
  # === DIRECT MODE: Call Telegram API directly (legacy / dev) ===

  BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$(jq -r '.telegram_bot_token' "$CONFIG")}"
  CHAT_ID="${TELEGRAM_CHAT_ID:-$(jq -r '.telegram_chat_id' "$CONFIG")}"

  if [ -z "$BOT_TOKEN" ] || [ "$BOT_TOKEN" = "null" ]; then
    echo "Error: TELEGRAM_BOT_TOKEN not set (env var or egregore.json)" >&2
    exit 1
  fi

  send_message() {
    local chat_id="$1"
    local text="$2"

    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg chat_id "$chat_id" --arg text "$text" \
        '{chat_id: $chat_id, text: $text}')" \
      | jq -r 'if .ok then "Sent" else "Failed: " + .description end'
  }

  lookup_telegram_id() {
    local name="$1"
    bash "$SCRIPT_DIR/bin/graph.sh" query \
      "MATCH (p:Person {name: \$name}) RETURN p.telegramId AS tid" \
      "{\"name\": \"$name\"}" \
      | jq -r '.values[0][0] // empty'
  }

  case "${1:-help}" in
    send)
      recipient="${2:?Usage: notify.sh send <name> <message>}"
      message="${3:?Usage: notify.sh send <name> <message>}"

      tid=$(lookup_telegram_id "$recipient")
      if [ -n "$tid" ] && [ "$tid" != "null" ]; then
        send_message "$tid" "$message"
      elif [ -n "$CHAT_ID" ] && [ "$CHAT_ID" != "null" ]; then
        send_message "$CHAT_ID" "@${recipient}: ${message}"
      else
        echo "No Telegram ID for $recipient and no group chat configured" >&2
        exit 1
      fi
      ;;
    group)
      message="${2:?Usage: notify.sh group <message>}"
      if [ -z "$CHAT_ID" ] || [ "$CHAT_ID" = "null" ]; then
        echo "Error: telegram_chat_id not set in egregore.json" >&2
        exit 1
      fi
      send_message "$CHAT_ID" "$message"
      ;;
    file)
      filepath="${2:?Usage: notify.sh file <path> [caption]}"
      caption="${3:-}"
      if [ -z "$CHAT_ID" ] || [ "$CHAT_ID" = "null" ]; then
        echo "Error: telegram_chat_id not set in egregore.json" >&2
        exit 1
      fi
      if [ ! -f "$filepath" ]; then
        echo "Error: file not found: $filepath" >&2
        exit 1
      fi
      curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
        -F "chat_id=$CHAT_ID" \
        -F "document=@$filepath" \
        -F "caption=$caption" \
        \
        | jq -r 'if .ok then "Sent" else "Failed: " + .description end'
      ;;
    test)
      if [ -z "$CHAT_ID" ] || [ "$CHAT_ID" = "null" ]; then
        echo "Error: telegram_chat_id not set" >&2
        exit 1
      fi
      send_message "$CHAT_ID" "Egregore connected"
      ;;
    help|*)
      echo "Usage: notify.sh <command>"
      echo ""
      echo "Commands:"
      echo "  send <name> <message>   Send to a person (DM or group fallback)"
      echo "  group <message>         Send to the group chat"
      echo "  file <path> [caption]   Send a file to the group chat"
      echo "  test                    Test connection"
      ;;
  esac
fi
