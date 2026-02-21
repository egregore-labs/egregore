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

# api_url comes from egregore.json (committed, non-secret)
# api_key comes from .env only (EGREGORE_API_KEY) — never from egregore.json
API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG")}"
API_KEY="${EGREGORE_API_KEY:-}"

# --- Millisecond timer (macOS + Linux compatible) ---
_millis() {
  if command -v gdate &>/dev/null; then
    gdate +%s%3N
  else
    # macOS date doesn't support %N — use python3 fallback
    python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null || echo "0"
  fi
}

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

    local start_ms
    start_ms=$(_millis)

    local response
    response=$(curl -s -X POST "${API_URL}/api/graph/query" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$body" \
      --max-time 30)

    local end_ms
    end_ms=$(_millis)
    local latency_ms=$(( end_ms - start_ms ))

    # Check for HTTP-level errors
    if echo "$response" | jq -e '.detail' >/dev/null 2>&1; then
      echo "API error:" >&2
      echo "$response" | jq '.detail' >&2
      bash "$SCRIPT_DIR/bin/telemetry.sh" emit "error" \
        "$(jq -n --arg source "graph" --arg error_code "api_error" --argjson latency "$latency_ms" \
          '{source: $source, error_code: $error_code, latency_ms: $latency}')" 2>/dev/null &
      exit 1
    fi

    # Emit latency telemetry (fire-and-forget)
    bash "$SCRIPT_DIR/bin/telemetry.sh" emit "graph_query" \
      "$(jq -n --argjson latency "$latency_ms" '{latency_ms: $latency}')" 2>/dev/null &

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
  echo "Error: EGREGORE_API_KEY not set. Add it to .env (get it from your team admin or during setup)." >&2
  exit 1
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
