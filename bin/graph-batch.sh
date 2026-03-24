#!/bin/bash
set -euo pipefail

# Execute multiple Cypher queries in a single HTTP call.
# Usage: graph-batch.sh '<json array of {statement, parameters} objects>'
#
# Example:
#   graph-batch.sh '[{"statement":"MATCH (p:Person) RETURN p.name"},{"statement":"MATCH (q:Quest) RETURN q.id"}]'
#
# Returns: {"results": [{...}, {...}]}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"

if [ ! -f "$CONFIG" ]; then
  echo "Error: egregore.json not found. Run onboarding first." >&2
  exit 1
fi

# --- Local mode gate: bail immediately ---
_MODE=$(jq -r '.mode // "connected"' "$CONFIG" 2>/dev/null)
if [ "$_MODE" = "local" ]; then
  echo '{"results":[]}'
  exit 0
fi

# Load specific variables from .env if it exists (safe extraction, no arbitrary code execution)
if [ -f "$SCRIPT_DIR/.env" ]; then
  EGREGORE_API_URL="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
  EGREGORE_API_KEY="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
fi

API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG")}"
API_KEY="${EGREGORE_API_KEY:-}"

if [ -z "$API_URL" ] || [ -z "$API_KEY" ]; then
  # === OFFLINE MODE: No API key — return empty results (OSS/local) ===
  echo '{"results":[]}'
  exit 0
fi

QUERIES_JSON="${1:?Usage: graph-batch.sh '<json array of queries>'}"

# Wrap the array into the batch request format
BODY=$(jq -n --argjson queries "$QUERIES_JSON" '{queries: $queries}')

RESPONSE=$(curl -s -X POST "${API_URL}/api/graph/batch" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  --max-time 60)

# Check for HTTP-level errors
if echo "$RESPONSE" | jq -e '.detail' >/dev/null 2>&1; then
  echo "API error:" >&2
  echo "$RESPONSE" | jq '.detail' >&2
  exit 1
fi

echo "$RESPONSE"
