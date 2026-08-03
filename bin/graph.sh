#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"

if [ ! -f "$CONFIG" ]; then
  echo "Error: egregore.json not found. Run onboarding first." >&2
  exit 1
fi

# --- Local mode gate: bail immediately, no .env sourcing, no network ---
_MODE=$(jq -r '.mode // "connected"' "$CONFIG" 2>/dev/null)
if [ "$_MODE" = "local" ]; then
  case "${1:-}" in
    query)  echo '{"results":[]}';;
    schema) echo '{}';;
    test)   echo '{"status":"offline","reason":"local_mode"}';;
    *)      echo '{"results":[]}';;
  esac
  exit 0
fi

# Load specific variables from .env if it exists (safe extraction, no arbitrary code execution)
if [ -f "$SCRIPT_DIR/.env" ]; then
  EGREGORE_API_URL="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
  EGREGORE_API_KEY="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
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

# --- Optional read-through cache (opt-in via EGREGORE_GRAPH_CACHE_TTL) ---
# Read-only queries can be served from a local cache that bin/attendant.sh
# keeps warm in the background, so callers on the launch path (session-start
# greeting) pay zero network round-trips when warm. TTL in seconds; unset/0
# disables. Mutating queries are never cached.
_CACHE_TTL="${EGREGORE_GRAPH_CACHE_TTL:-0}"
# Key the cache by the MAIN checkout so worktree sessions hit the same warm
# cache the attendant maintains (its replay uses the same derivation).
# Worktrees have .git as a FILE pointing into the main repo's .git/worktrees/.
# api_url + slug are part of the key so entries never cross tenants when the
# same checkout is repointed at a different org/API (cache entries are keyed
# only by query+params below, so the directory must carry the tenant).
_CACHE_ROOT="$SCRIPT_DIR"
if [ -f "$SCRIPT_DIR/.git" ]; then
  _WT_GITDIR=$(sed 's/^gitdir: //' "$SCRIPT_DIR/.git" 2>/dev/null || true)
  if [ -n "$_WT_GITDIR" ]; then
    _CACHE_ROOT=$(cd "$_WT_GITDIR/../../.." 2>/dev/null && pwd || echo "$SCRIPT_DIR")
  fi
fi
# The scope is a non-secret fingerprint of the EFFECTIVE endpoint + credential
# (already resolved above: process env → .env → committed api_url). Committed
# config alone is not enough — an EGREGORE_API_URL/KEY override or a swapped
# .env can point this checkout at a different tenant than egregore.json names,
# and the entry key below carries only query+params. cksum output is a CRC,
# not a reversible or usable credential.
_CACHE_SCOPE=$(echo -n "${API_URL:-}|${API_KEY:-}" | cksum | cut -d' ' -f1)
_CACHE_DIR="$HOME/.egregore/graph-cache/$(echo -n "${_CACHE_ROOT}|${_CACHE_SCOPE}" | cksum | cut -d' ' -f1)"

_cache_key() {
  echo -n "$1|${2:-}" | cksum | cut -d' ' -f1
}

_is_read_query() {
  ! echo "$1" | grep -qiE '\b(MERGE|CREATE|SET|DELETE|DETACH|REMOVE)\b'
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

    local cache_file=""
    if [ "$_CACHE_TTL" != "0" ] && _is_read_query "$cypher"; then
      cache_file="$_CACHE_DIR/$(_cache_key "$cypher" "$params").json"
      if [ -f "$cache_file" ]; then
        local now cts
        now=$(date +%s)
        cts=$(jq -r '.ts // 0' "$cache_file" 2>/dev/null || echo 0)
        if [ $(( now - cts )) -lt "$_CACHE_TTL" ]; then
          jq -c '.result' "$cache_file" 2>/dev/null && return 0
        fi
      fi
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

    # Store for the attendant to keep warm (query+params travel with the result)
    if [ -n "$cache_file" ]; then
      mkdir -p "$_CACHE_DIR" 2>/dev/null
      jq -n --arg q "$cypher" --argjson p "$params" --argjson ts "$(date +%s)" --argjson r "$response" \
        '{query: $q, params: $p, ts: $ts, result: $r}' > "$cache_file" 2>/dev/null || true
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
  # === OFFLINE MODE: No API key — return empty results (OSS/local) ===
  run_query() { echo '{"results":[]}'; }
  get_schema() { echo '{}'; }
  test_connection() { echo '{"status":"offline","reason":"no_api_key"}'; }
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
