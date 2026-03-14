#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"

if [ ! -f "$CONFIG" ]; then
  echo "Error: egregore.json not found." >&2
  exit 1
fi

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi

API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG")}"
API_KEY="${EGREGORE_API_KEY:-}"
GS="$SCRIPT_DIR/bin/graph.sh"

if [ -z "$API_URL" ] || [ -z "$API_KEY" ]; then
  echo "Error: EGREGORE_API_KEY and api_url required. Add API key to .env." >&2
  exit 1
fi

# --- Priority-weighted selection query ---
SELECTION_QUERY='
MATCH (a:Artifact)
WHERE a.summary IS NULL AND a.filePath IS NOT NULL
OPTIONAL MATCH (a)-[:PART_OF]->(q:Quest)<-[:ADVANCED]-(s:Session)
WHERE s.date >= date() - duration('\''P14D'\'')
WITH a,
  CASE WHEN NOT (a)-[:PART_OF]->(:Quest) AND NOT (a)-[:RELATES_TO]-(:Artifact) THEN 1.0 ELSE 0.0 END AS isolation,
  toFloat(CASE WHEN count(s) > 10 THEN 10 ELSE count(s) END) / 10.0 AS recency
WITH a, (isolation * 0.4 + recency * 0.6) AS priority
RETURN a.id AS id, a.title AS title, a.filePath AS filePath, a.type AS type, round(priority * 100) / 100.0 AS priority
ORDER BY priority DESC
LIMIT 20'

SELECTION_QUERY_FORCE='
MATCH (a:Artifact)
WHERE a.filePath IS NOT NULL
OPTIONAL MATCH (a)-[:PART_OF]->(q:Quest)<-[:ADVANCED]-(s:Session)
WHERE s.date >= date() - duration('\''P14D'\'')
WITH a,
  CASE WHEN NOT (a)-[:PART_OF]->(:Quest) AND NOT (a)-[:RELATES_TO]-(:Artifact) THEN 1.0 ELSE 0.0 END AS isolation,
  toFloat(CASE WHEN count(s) > 10 THEN 10 ELSE count(s) END) / 10.0 AS recency
WITH a, (isolation * 0.4 + recency * 0.6) AS priority
RETURN a.id AS id, a.title AS title, a.filePath AS filePath, a.type AS type, round(priority * 100) / 100.0 AS priority
ORDER BY priority DESC
LIMIT 20'

# --- Helpers ---

_parse_artifacts() {
  local result="$1"
  echo "$result" | jq -c '.values[]' 2>/dev/null
}

_resolve_path() {
  local file_path="$1"
  if [[ "$file_path" == memory/* ]]; then
    echo "$SCRIPT_DIR/$file_path"
  else
    echo "$SCRIPT_DIR/memory/$file_path"
  fi
}

# --- Subcommands ---

cmd_status() {
  local result
  result=$(bash "$GS" query "MATCH (a:Artifact) WHERE a.summary IS NULL AND a.filePath IS NOT NULL RETURN count(a) AS unsummarized")
  local count
  count=$(echo "$result" | jq -r '.values[0][0] // 0' 2>/dev/null)
  echo "Unsummarized artifacts: $count"
}

cmd_dry_run() {
  local result
  result=$(bash "$GS" query "$SELECTION_QUERY")

  local rows
  rows=$(_parse_artifacts "$result")

  if [ -z "$rows" ]; then
    echo "No unsummarized artifacts found."
    return 0
  fi

  printf "%-40s %-12s %8s\n" "TITLE" "TYPE" "PRIORITY"
  printf "%-40s %-12s %8s\n" "----------------------------------------" "------------" "--------"

  echo "$rows" | while IFS= read -r row; do
    local title type priority
    title=$(echo "$row" | jq -r '.[1] // "untitled"')
    type=$(echo "$row" | jq -r '.[3] // "unknown"')
    priority=$(echo "$row" | jq -r '.[4] // 0')

    # Truncate title to 40 chars
    if [ ${#title} -gt 40 ]; then
      title="${title:0:37}..."
    fi

    printf "%-40s %-12s %8s\n" "$title" "$type" "$priority"
  done
}

cmd_run() {
  local force=false
  local max_cost=0.10

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=true; shift ;;
      --max-cost) max_cost="$2"; shift 2 ;;
      *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
  done

  local query="$SELECTION_QUERY"
  if [ "$force" = true ]; then
    query="$SELECTION_QUERY_FORCE"
  fi

  local result
  result=$(bash "$GS" query "$query")

  local rows
  rows=$(_parse_artifacts "$result")

  if [ -z "$rows" ]; then
    echo "No artifacts to process."
    return 0
  fi

  local total
  total=$(echo "$rows" | wc -l | tr -d ' ')
  local cumulative_cost=0
  local count=0
  local cost_per_artifact=0.003

  echo "$rows" | while IFS= read -r row; do
    local id title file_path type priority
    id=$(echo "$row" | jq -r '.[0]')
    title=$(echo "$row" | jq -r '.[1] // "untitled"')
    file_path=$(echo "$row" | jq -r '.[2]')
    type=$(echo "$row" | jq -r '.[3] // "unknown"')
    priority=$(echo "$row" | jq -r '.[4] // 0')

    count=$((count + 1))

    # Check budget
    cumulative_cost=$(echo "$cumulative_cost + $cost_per_artifact" | bc)
    local over_budget
    over_budget=$(echo "$cumulative_cost > $max_cost" | bc)
    if [ "$over_budget" -eq 1 ]; then
      echo "Budget cap reached (\$${max_cost}). Processed $((count - 1))/${total} artifacts."
      break
    fi

    # Resolve file path
    local full_path
    full_path=$(_resolve_path "$file_path")

    if [ ! -f "$full_path" ]; then
      echo "[${count}/${total}] Skipped: \"${title}\" (file not found: ${file_path})" >&2
      continue
    fi

    # Read file content
    local content
    content=$(cat "$full_path")

    # Call scribe API
    local response
    response=$(curl -s -X POST "${API_URL}/api/spirits/scribe" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg title "$title" --arg content "$content" --arg type "$type" \
        '{title: $title, content: $content, type: $type}')" \
      --max-time 60)

    # Extract summary
    local summary
    summary=$(echo "$response" | jq -r '.summary // empty')

    if [ -z "$summary" ]; then
      echo "[${count}/${total}] Failed: \"${title}\" (no summary in response)" >&2
      if echo "$response" | jq -e '.detail' >/dev/null 2>&1; then
        echo "  API error: $(echo "$response" | jq -r '.detail')" >&2
      fi
      continue
    fi

    # Write summary back to Neo4j
    bash "$GS" query \
      'MATCH (a:Artifact {id: $id}) SET a.summary = $summary, a.summarizedAt = datetime(), a.summarizedBy = "scribe"' \
      "$(jq -n --arg id "$id" --arg summary "$summary" '{id: $id, summary: $summary}')" >/dev/null

    echo "[${count}/${total}] Summarized: \"${title}\" (priority: ${priority})"
  done
}

cmd_help() {
  echo "Usage: graph-scribe.sh <command>"
  echo ""
  echo "Scribe spirit — summarizes unsummarized artifacts via the Egregore API."
  echo ""
  echo "Commands:"
  echo "  status              Count unsummarized artifacts"
  echo "  dry-run             List artifacts that would be processed with priority scores"
  echo "  run [flags]         Process artifacts"
  echo "    --force           Re-summarize even if summary exists"
  echo "    --max-cost FLOAT  Budget cap in dollars (default: 0.10)"
  echo "  help                Show this help"
}

# --- Dispatch ---

case "${1:-help}" in
  status)
    cmd_status
    ;;
  dry-run)
    shift
    cmd_dry_run
    ;;
  run)
    shift
    cmd_run "$@"
    ;;
  help|*)
    cmd_help
    ;;
esac
