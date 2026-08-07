#!/usr/bin/env bash
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

# Load specific variables from .env if it exists (safe extraction, no arbitrary code execution).
# A worktree missing its .env symlink resolves through worktree-links.sh, which
# self-heals the link and falls back to the main checkout's .env.
_ENV_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$_ENV_FILE" ] && [ -f "$SCRIPT_DIR/bin/lib/worktree-links.sh" ]; then
  # shellcheck source=bin/lib/worktree-links.sh
  source "$SCRIPT_DIR/bin/lib/worktree-links.sh" 2>/dev/null || true
  _ENV_FILE="$(egregore_env_file "$SCRIPT_DIR" 2>/dev/null || true)"
fi
if [ -n "$_ENV_FILE" ] && [ -f "$_ENV_FILE" ]; then
  EGREGORE_API_URL="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "$_ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)}"
  EGREGORE_API_KEY="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "$_ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)}"
fi

API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG")}"
API_KEY="${EGREGORE_API_KEY:-}"

if [ -z "$API_URL" ]; then
  # === OFFLINE MODE: no api_url configured (OSS/unconfigured) ===
  echo '{"results":[]}'
  exit 0
fi

if [ -z "$API_KEY" ]; then
  # api_url is configured but no key was found — the local-mode gate exited
  # above, so the org expects a live graph. Faking empty results here hides a
  # missing .env (e.g. a worktree without its symlink) from every caller.
  {
    echo "Error: api_url is configured but EGREGORE_API_KEY is empty (looked in: ${_ENV_FILE:-$SCRIPT_DIR/.env})."
    echo "  If this is a worktree, its .env symlink may be missing. Run /env to configure."
  } >&2
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
