#!/bin/bash
set -euo pipefail

# Granola API client
# Uses WorkOS token from Granola's local auth storage to hit the internal API.
# No enterprise API key needed — uses the same auth as the desktop app.
#
# Token management:
#   Reads access_token from ~/Library/Application Support/Granola/supabase.json
#   Token may expire — if 401, user needs to open Granola app to refresh.
#
# API base: https://api.granola.ai/v1
# All responses are gzip-compressed — use curl --compressed.

GRANOLA_DIR="$HOME/Library/Application Support/Granola"
AUTH_FILE="$GRANOLA_DIR/supabase.json"

# --- Helpers ---

check_auth() {
  if [ ! -f "$AUTH_FILE" ]; then
    echo "Granola auth not found — open Granola app and sign in first." >&2
    exit 1
  fi
}

get_token() {
  jq -r '.workos_tokens' "$AUTH_FILE" | jq -r '.access_token'
}

api_call() {
  local endpoint="$1"
  local data="${2:-"{}"}"
  local token
  token=$(get_token)

  local response
  local http_code
  response=$(curl -s --compressed -w "\n%{http_code}" \
    "https://api.granola.ai/v1/$endpoint" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$data")

  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" = "401" ]; then
    echo "Granola token expired — open Granola app to refresh your session." >&2
    exit 1
  elif [ "$http_code" != "200" ]; then
    echo "Granola API error ($http_code): $body" >&2
    exit 1
  fi

  echo "$body"
}

# --- Subcommands ---

cmd_test() {
  check_auth
  local docs
  docs=$(api_call "get-documents" '{}')
  local count
  count=$(echo "$docs" | jq 'length')
  echo "Granola API connected: $count documents"
}

cmd_list() {
  check_auth

  local exclude=""
  local since=""
  local limit="30"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude)
        exclude="$2"
        shift 2
        ;;
      --since)
        since="$2"
        shift 2
        ;;
      --limit)
        limit="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  local docs
  docs=$(api_call "get-documents" '{}')

  # Filter, format, sort
  local result
  result=$(echo "$docs" | jq --arg exclude "$exclude" --arg since "$since" --argjson limit "$limit" '
    ($exclude | split(",") | map(select(length > 0))) as $excluded |
    [.[] |
      select(.deleted_at == null) |
      select(([.id] | inside($excluded) | not) or ($excluded | length == 0)) |
      {
        id: .id,
        title: (.title // "untitled"),
        date: .created_at,
        attendees: [(.people.attendees // [])[] | {
          name: (.details.person.name.fullName // .email),
          email: (.email // "")
        }]
      }
    ] |
    (if $since != "" then [.[] | select(.date >= $since)] else . end) |
    sort_by(.date) | reverse |
    .[:$limit]
  ')

  echo "$result"
}

cmd_get() {
  check_auth

  local doc_id="${1:-}"
  if [ -z "$doc_id" ]; then
    echo "Usage: granola-api.sh get <doc-id>" >&2
    exit 1
  fi

  # Get document metadata
  local docs
  docs=$(api_call "get-documents" '{}')
  local doc
  doc=$(echo "$docs" | jq --arg id "$doc_id" '[.[] | select(.id == $id)] | .[0] // empty')
  if [ -z "$doc" ] || [ "$doc" = "null" ]; then
    echo "Document not found: $doc_id" >&2
    exit 1
  fi

  # Get transcript
  local transcript
  transcript=$(api_call "get-document-transcript" "{\"document_id\": \"$doc_id\"}")

  # Get panels
  local panels
  panels=$(api_call "get-document-panels" "{\"document_id\": \"$doc_id\"}")

  # Extract panel text from ProseMirror content
  local panel_text=""
  if [ "$(echo "$panels" | jq 'length')" -gt 0 ]; then
    panel_text=$(echo "$panels" | jq -r '.[0].content | [.. | select(.type? == "text") | .text] | join(" ")' 2>/dev/null || echo "")
  fi

  # Build transcript text
  local transcript_text
  transcript_text=$(echo "$transcript" | jq -r '[.[] | .text // ""] | join("\n")' 2>/dev/null || echo "")

  # Build structured transcript
  local transcript_structured
  transcript_structured=$(echo "$transcript" | jq '[.[] | {
    text: (.text // ""),
    source: (.source // "unknown"),
    start: (.start_timestamp // null),
    end: (.end_timestamp // null)
  }]' 2>/dev/null || echo "[]")

  # Build output
  echo "$doc" | jq \
    --arg panel "$panel_text" \
    --arg transcript "$transcript_text" \
    --argjson transcript_structured "$transcript_structured" \
    '{
      id: .id,
      title: .title,
      date: .created_at,
      attendees: [
        ((.people.creator // {}) | {name: (.details.person.name.fullName // .name // "unknown"), email: (.email // "")}),
        ((.people.attendees // [])[] | {name: (.details.person.name.fullName // .email), email: (.email // "")})
      ],
      panel_text: $panel,
      transcript_text: $transcript,
      transcript_structured: $transcript_structured
    }'
}

cmd_search() {
  check_auth

  local query="${1:-}"
  if [ -z "$query" ]; then
    echo "Usage: granola-api.sh search <query>" >&2
    exit 1
  fi

  local docs
  docs=$(api_call "get-documents" '{}')

  echo "$docs" | jq --arg query "$query" '
    [.[] |
      select(.deleted_at == null) |
      select(
        (.title // "" | ascii_downcase | contains($query | ascii_downcase)) or
        ([(.people.attendees // [])[] | (.details.person.name.fullName // .email // "") | ascii_downcase] | any(contains($query | ascii_downcase)))
      ) |
      {
        id: .id,
        title: (.title // "untitled"),
        date: .created_at,
        attendees: [(.people.attendees // [])[] | {
          name: (.details.person.name.fullName // .email),
          email: (.email // "")
        }]
      }
    ] | sort_by(.date) | reverse
  '
}

# --- Main ---

case "${1:-help}" in
  test)
    cmd_test
    ;;
  list)
    shift
    cmd_list "$@"
    ;;
  get)
    shift
    cmd_get "$@"
    ;;
  search)
    shift
    cmd_search "$@"
    ;;
  help|*)
    echo "Usage: granola-api.sh <command>"
    echo ""
    echo "Commands:"
    echo "  test                                   Check API connection"
    echo "  list [--exclude id1,id2] [--since DATE] [--limit N]"
    echo "                                         List meetings as JSON"
    echo "  get <doc-id>                           Full meeting data (metadata + transcript + panels)"
    echo "  search <query>                         Search by title/attendee"
    ;;
esac
