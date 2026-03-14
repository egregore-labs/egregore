#!/bin/bash
set -euo pipefail

# Granola local cache reader
# Reads meeting data from Granola's local cache (no auth, no network)
#
# Cache structure (cache-v3.json):
#   { "cache": "<stringified JSON>" }
#   Inner: { "state": { documents, documentLists, documentListsMetadata, documentPanels, transcripts, ... } }
#
# Data model:
#   documents:              { doc_id: { id, title, created_at, people: { creator, attendees }, notes_markdown, ... } }
#   documentLists:          { folder_id: [doc_id, doc_id, ...] }  — folder membership
#   documentListsMetadata:  { folder_id: { id, title, ... } }     — folder metadata
#   documentPanels:         { doc_id: { panel_id: { content: {ProseMirror}, ... } } }
#   transcripts:            { doc_id: [{ text, start_timestamp, end_timestamp, source, ... }] }

CACHE_DIR="$HOME/Library/Application Support/Granola"
# Try newest cache version first, fall back to older
if [ -f "$CACHE_DIR/cache-v4.json" ]; then
  CACHE_FILE="$CACHE_DIR/cache-v4.json"
elif [ -f "$CACHE_DIR/cache-v3.json" ]; then
  CACHE_FILE="$CACHE_DIR/cache-v3.json"
else
  CACHE_FILE="$CACHE_DIR/cache-v4.json"  # will fail with clear error in check_cache
fi

# --- Helpers ---

check_cache() {
  if [ ! -d "$CACHE_DIR" ]; then
    echo "Granola not found — $CACHE_DIR does not exist." >&2
    exit 1
  fi
  if [ ! -f "$CACHE_FILE" ]; then
    echo "Granola cache not found — $CACHE_FILE does not exist." >&2
    exit 1
  fi
}

get_state() {
  # v4: cache.state is a nested object → jq '.cache.state' works directly
  # v3: cache is a stringified JSON string → need jq -r '.cache' | jq '.state'
  if [[ "$CACHE_FILE" == *"cache-v4"* ]]; then
    jq '.cache.state' "$CACHE_FILE"
  else
    jq -r '.cache' "$CACHE_FILE" | jq '.state'
  fi
}

# --- Subcommands ---

cmd_test() {
  check_cache
  local doc_count
  doc_count=$(get_state | jq '.documents | length')
  echo "Granola cache found: $doc_count documents"
}

cmd_folders() {
  check_cache
  local state
  state=$(get_state)

  # documentListsMetadata has folder info, documentLists has doc membership
  echo "$state" | jq '
    .documentLists as $lists |
    [.documentListsMetadata | to_entries[] | .value |
      select(.deleted_at == null) |
      {
        id: .id,
        name: .title,
        doc_count: ($lists[.id] // [] | length)
      }
    ]
  '
}

cmd_list() {
  check_cache

  local folder=""
  local since=""
  local exclude=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --folder)
        folder="$2"
        shift 2
        ;;
      --since)
        since="$2"
        shift 2
        ;;
      --exclude)
        exclude="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  local state
  state=$(get_state)

  local result

  if [ -n "$folder" ]; then
    # Find folder ID by name, then filter docs to that folder's membership list
    result=$(echo "$state" | jq --arg fname "$folder" '
      .documentLists as $lists |
      .documentListsMetadata as $meta |
      .documents as $docs |
      (
        [$meta | to_entries[] | select(.value.title == $fname) | .key] | .[0]
      ) as $folder_id |
      (if $folder_id then $lists[$folder_id] // [] else [] end) as $member_ids |
      [
        $member_ids[] |
        . as $did |
        $docs[$did] // empty |
        select(.deleted_at == null) |
        {
          id: .id,
          title: .title,
          date: .created_at,
          attendees: [(.people.attendees // [])[] | .details.person.name.fullName // .email]
        }
      ]
    ')
  else
    # All non-deleted documents
    result=$(echo "$state" | jq '
      [.documents | to_entries[] | .value |
        select(.deleted_at == null) |
        {
          id: .id,
          title: .title,
          date: .created_at,
          attendees: [(.people.attendees // [])[] | .details.person.name.fullName // .email]
        }
      ]
    ')
  fi

  # Apply --since filter
  if [ -n "$since" ]; then
    result=$(echo "$result" | jq --arg since "$since" '
      [.[] | select(.date >= $since)]
    ')
  fi

  # Apply --exclude filter (comma-separated doc IDs)
  if [ -n "$exclude" ]; then
    result=$(echo "$result" | jq --arg exclude "$exclude" '
      ($exclude | split(",")) as $excluded |
      [.[] | select([.id] | inside($excluded) | not)]
    ')
  fi

  # Sort by date descending
  echo "$result" | jq 'sort_by(.date) | reverse'
}

cmd_get() {
  check_cache

  local doc_id="${1:-}"
  if [ -z "$doc_id" ]; then
    echo "Usage: granola.sh get <doc-id>" >&2
    exit 1
  fi

  local state
  state=$(get_state)

  # Get document
  local doc
  doc=$(echo "$state" | jq --arg id "$doc_id" '.documents[$id] // empty')
  if [ -z "$doc" ] || [ "$doc" = "null" ]; then
    echo "Document not found: $doc_id" >&2
    exit 1
  fi

  # Panel text: prefer notes_markdown on the document (human-curated notes).
  # Fall back to ProseMirror extraction from documentPanels if notes_markdown is empty.
  local panel_text
  panel_text=$(echo "$doc" | jq -r '.notes_markdown // empty')

  if [ -z "$panel_text" ]; then
    # Extract from ProseMirror panels (recursive text node extraction)
    panel_text=$(echo "$state" | jq -r --arg id "$doc_id" '
      .documentPanels[$id] // {} |
      [to_entries[] | .value.content // empty] |
      [.. | select(.type? == "text") | .text] |
      join(" ")
    ' 2>/dev/null || echo "")
  fi

  # Transcript: array of utterance objects → joined text
  local transcript_text
  transcript_text=$(echo "$state" | jq -r --arg id "$doc_id" '
    .transcripts[$id] // [] |
    [.[] | .text // empty] |
    join("\n")
  ' 2>/dev/null || echo "")

  # Transcript structured: preserves utterance metadata (source, timestamps)
  local transcript_structured
  transcript_structured=$(echo "$state" | jq --arg id "$doc_id" '
    .transcripts[$id] // [] |
    [.[] | {
      text: (.text // ""),
      source: (.source // "unknown"),
      start: (.start_timestamp // null),
      end: (.end_timestamp // null)
    }]
  ' 2>/dev/null || echo "[]")

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
  check_cache

  local query="${1:-}"
  if [ -z "$query" ]; then
    echo "Usage: granola.sh search <query> [--folders \"Folder1,Folder2\"]" >&2
    exit 1
  fi
  shift

  local folders=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --folders)
        folders="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  # If no folders specified, read configured folders from state file
  local state_file
  state_file="$(cd "$(dirname "$0")/.." && pwd)/.egregore-state.json"
  if [ -z "$folders" ] && [ -f "$state_file" ]; then
    folders=$(jq -r '.granola_folders // [] | join(",")' "$state_file")
  fi

  local state
  state=$(get_state)

  if [ -n "$folders" ]; then
    # Search within specified folders
    echo "$state" | jq --arg query "$query" --arg folders "$folders" '
      ($folders | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $folder_names |
      .documentLists as $lists |
      .documentListsMetadata as $meta |
      .documents as $docs |

      # Get doc IDs from matching folders
      [
        $meta | to_entries[] |
        select(.value.title as $t | $folder_names | any(. == $t)) |
        .key
      ] as $folder_ids |

      [
        $folder_ids[] |
        . as $fid |
        ($lists[$fid] // [])[] |
        . as $did |
        $docs[$did] // empty |
        select(.deleted_at == null) |
        select(
          (.title // "" | ascii_downcase | contains($query | ascii_downcase)) or
          ([(.people.attendees // [])[] | (.details.person.name.fullName // .email // "") | ascii_downcase] | any(contains($query | ascii_downcase)))
        ) |
        {
          id: .id,
          title: .title,
          date: .created_at,
          attendees: [(.people.attendees // [])[] | .details.person.name.fullName // .email]
        }
      ] | unique_by(.id) | sort_by(.date) | reverse
    '
  else
    # Search all documents
    echo "$state" | jq --arg query "$query" '
      [.documents | to_entries[] | .value |
        select(.deleted_at == null) |
        select(
          (.title // "" | ascii_downcase | contains($query | ascii_downcase)) or
          ([(.people.attendees // [])[] | (.details.person.name.fullName // .email // "") | ascii_downcase] | any(contains($query | ascii_downcase)))
        ) |
        {
          id: .id,
          title: .title,
          date: .created_at,
          attendees: [(.people.attendees // [])[] | .details.person.name.fullName // .email]
        }
      ] | sort_by(.date) | reverse
    '
  fi
}

# --- Main ---

case "${1:-help}" in
  test)
    cmd_test
    ;;
  folders)
    cmd_folders
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
    echo "Usage: granola.sh <command>"
    echo ""
    echo "Commands:"
    echo "  test                                   Check if Granola cache exists"
    echo "  folders                                List folders with doc counts"
    echo "  list [--folder X] [--since DATE] [--exclude id1,id2]"
    echo "                                         List meetings as JSON"
    echo "  get <doc-id>                           Full meeting data"
    echo "  search <query> [--folders X,Y]         Search by title/attendee across folders"
    ;;
esac
