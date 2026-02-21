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

# Source .env if it exists
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi

API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG")}"
API_KEY="${EGREGORE_API_KEY:-}"

if [ -z "$API_URL" ] || [ -z "$API_KEY" ]; then
  echo "Error: API mode required for batch queries. Set EGREGORE_API_KEY in .env." >&2
  exit 1
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
