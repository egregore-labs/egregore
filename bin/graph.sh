#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"

if [ ! -f "$CONFIG" ]; then
  echo "Error: egregore.json not found. Run onboarding first." >&2
  exit 1
fi

# Source .env if it exists (for local overrides)
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi

# Check if API mode (api_url + api_key set) or direct mode (neo4j_host set)
# api_url comes from egregore.json (committed, non-secret)
# api_key comes from .env only (EGREGORE_API_KEY) — never from egregore.json
API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG")}"
API_KEY="${EGREGORE_API_KEY:-}"

if [ -n "$API_URL" ] && [ -n "$API_KEY" ]; then
  # === API MODE: Call Egregore API gateway ===

  run_query() {
    local cypher="$1"
    local params
    if [ -n "${2:-}" ]; then
      params="$2"
    else
      params="{}"
    fi

    local body
    body=$(jq -n --arg stmt "$cypher" --argjson params "$params" \
      '{statement: $stmt, parameters: $params}')

    local response
    response=$(curl -s -X POST "${API_URL}/api/graph/query" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$body" \
      --max-time 30)

    # Check for HTTP-level errors
    if echo "$response" | jq -e '.detail' >/dev/null 2>&1; then
      echo "API error:" >&2
      echo "$response" | jq '.detail' >&2
      exit 1
    fi

    echo "$response"
  }

  get_schema() {
    local response
    response=$(curl -s -X GET "${API_URL}/api/graph/schema" \
      -H "Authorization: Bearer $API_KEY" \
      --max-time 30)
    echo "$response" | jq .
  }

  test_connection() {
    local response
    response=$(curl -s -X GET "${API_URL}/api/graph/test" \
      -H "Authorization: Bearer $API_KEY" \
      --max-time 10)

    if echo "$response" | jq -e '.status == "ok"' >/dev/null 2>&1; then
      echo "Connected to Egregore API at $API_URL"
    else
      echo "Failed to connect to Egregore API at $API_URL" >&2
      echo "$response" >&2
      exit 1
    fi
  }

else
  # === DIRECT MODE: Call Neo4j directly (dev / legacy) ===
  # Reads from .env or egregore.json (for backwards compat)

  NEO4J_HOST="${NEO4J_HOST:-$(jq -r '.neo4j_host // empty' "$CONFIG")}"
  NEO4J_USER="${NEO4J_USER:-$(jq -r '.neo4j_user // "neo4j"' "$CONFIG")}"
  NEO4J_PASSWORD="${NEO4J_PASSWORD:-$(jq -r '.neo4j_password // empty' "$CONFIG")}"

  if [ -z "$NEO4J_HOST" ] || [ "$NEO4J_HOST" = "null" ]; then
    echo "Error: Neither EGREGORE_API_KEY (for API mode) nor NEO4J_HOST (for direct mode) is set." >&2
    echo "Set EGREGORE_API_KEY in .env for API mode, or NEO4J_HOST + NEO4J_PASSWORD for direct mode." >&2
    exit 1
  fi

  URL="https://${NEO4J_HOST}/db/neo4j/query/v2"
  AUTH=$(printf '%s:%s' "$NEO4J_USER" "$NEO4J_PASSWORD" | base64)

  run_query() {
    local cypher="$1"
    local params
    if [ -n "${2:-}" ]; then
      params="$2"
    else
      params="{}"
    fi

    local body
    body=$(jq -n --arg stmt "$cypher" --argjson params "$params" \
      '{statement: $stmt, parameters: $params}')

    local response
    response=$(curl -s -X POST "$URL" \
      -H "Authorization: Basic $AUTH" \
      -H "Content-Type: application/json" \
      -d "$body" \
      --max-time 30)

    local errors
    errors=$(echo "$response" | jq -r '.errors // empty')
    if [ -n "$errors" ] && [ "$errors" != "null" ] && [ "$errors" != "[]" ]; then
      echo "Neo4j error:" >&2
      echo "$response" | jq '.errors' >&2
      exit 1
    fi

    echo "$response" | jq '.data'
  }

  get_schema() {
    local response
    response=$(curl -s -X POST "$URL" \
      -H "Authorization: Basic $AUTH" \
      -H "Content-Type: application/json" \
      -d '{"statement":"CALL db.schema.visualization()"}' \
      --max-time 30)

    local nodes rels
    nodes=$(echo "$response" | jq -r '[.data.values[0][0][] | {label: .labels[0], properties: .properties.constraints}]')
    rels=$(echo "$response" | jq -r '[.data.values[0][1][] | .type] | unique')

    echo "Node labels:"
    echo "$nodes" | jq -r '.[] | "  - \(.label)"'
    echo ""
    echo "Relationship types:"
    echo "$rels" | jq -r '.[] | "  - \(.)"'
  }

  test_connection() {
    local response
    response=$(curl -s -X POST "$URL" \
      -H "Authorization: Basic $AUTH" \
      -H "Content-Type: application/json" \
      -d '{"statement":"RETURN 1 AS ok"}' \
      --max-time 10)

    if echo "$response" | jq -e '.data.values[0][0] == 1' >/dev/null 2>&1; then
      echo "Connected to Neo4j at $NEO4J_HOST"
    else
      echo "Failed to connect to Neo4j at $NEO4J_HOST" >&2
      echo "$response" >&2
      exit 1
    fi
  }
fi

case "${1:-help}" in
  query)
    shift
    run_query "$@"
    ;;
  schema)
    get_schema
    ;;
  test)
    test_connection
    ;;
  help|*)
    echo "Usage: graph.sh <command>"
    echo ""
    echo "Commands:"
    echo "  query <cypher> [params_json]  Run a Cypher query"
    echo "  schema                        Show graph schema"
    echo "  test                          Test connection"
    ;;
esac
