#!/bin/bash
# Egregore telemetry — privacy-respecting product analytics.
# Mirrors bin/graph.sh and bin/notify.sh patterns.
#
# Subcommands:
#   emit <type> <json>   Append event to local JSONL buffer (no network)
#   flush                Send buffered events to API and clear buffer
#   status               Show telemetry status (enabled/disabled, buffer size)
#   enable               Enable telemetry
#   disable              Disable telemetry
#   clear                Clear local buffer
#   show [n]             Show last N events from buffer (default 10)
#
# Consent: opt-out via EGREGORE_NO_TELEMETRY=1, DO_NOT_TRACK=1,
#          or .egregore-state.json → "telemetry": false
#
# Never collected: file paths, file contents, code, env var values,
#                  conversation content, command arguments with user content.
# Only collected: command names, timestamps, durations, error codes, branch names.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUFFER_DIR="$HOME/.egregore"
BUFFER_FILE="$BUFFER_DIR/telemetry.jsonl"
STATE_FILE="$SCRIPT_DIR/.egregore-state.json"
CONFIG="$SCRIPT_DIR/egregore.json"
ENV_FILE="$SCRIPT_DIR/.env"
MAX_BUFFER_BYTES=1048576  # 1MB
MAX_EVENTS_AFTER_TRUNCATE=500

# --- Consent check (fast path) ---
_check_consent() {
  # Environment variable opt-outs (fastest check)
  [ "${EGREGORE_NO_TELEMETRY:-}" = "1" ] && return 1
  [ "${DO_NOT_TRACK:-}" = "1" ] && return 1

  # State file opt-out
  if [ -f "$STATE_FILE" ]; then
    local val
    val=$(jq -r '.telemetry // "true"' "$STATE_FILE" 2>/dev/null || echo "true")
    [ "$val" = "false" ] && return 1
  fi

  return 0
}

# --- Debug mode ---
_is_debug() {
  [ "${EGREGORE_TELEMETRY_DEBUG:-}" = "1" ]
}

# --- Resolve identity (from env vars first, fallback to config files) ---
_resolve_user() {
  if [ -n "${EGREGORE_USER:-}" ]; then
    echo "$EGREGORE_USER"
  elif [ -f "$STATE_FILE" ]; then
    jq -r '.github_username // .name // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

_resolve_org() {
  if [ -n "${EGREGORE_ORG:-}" ]; then
    echo "$EGREGORE_ORG"
  elif [ -f "$CONFIG" ]; then
    jq -r '.slug // .github_org // "unknown"' "$CONFIG" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

_resolve_session_id() {
  if [ -n "${EGREGORE_SESSION_ID:-}" ]; then
    echo "$EGREGORE_SESSION_ID"
    return
  fi

  # Fallback: read from file written by session-start.sh
  # (env vars from hooks don't propagate into the Claude Code agent)
  local proj_hash
  proj_hash=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
  local sid_file="$HOME/.egregore/session-${proj_hash}.id"
  if [ -f "$sid_file" ]; then
    cat "$sid_file" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

# --- emit: append event to local JSONL buffer ---
cmd_emit() {
  local event_type="${1:?Usage: telemetry.sh emit <type> <json>}"
  local data="${2:-"{}"}"

  # Consent gate
  if ! _check_consent; then
    return 0
  fi

  # Debug mode: print to stderr instead of writing
  if _is_debug; then
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"ts":"%s","type":"%s","sid":"%s","org":"%s","user":"%s","data":%s}\n' \
      "$ts" "$event_type" "$(_resolve_session_id)" "$(_resolve_org)" "$(_resolve_user)" "$data" >&2
    return 0
  fi

  # Ensure buffer directory exists
  mkdir -p "$BUFFER_DIR"

  # Build event JSON and append (single printf, O(1) append, no network)
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","type":"%s","sid":"%s","org":"%s","user":"%s","data":%s}\n' \
    "$ts" "$event_type" "$(_resolve_session_id)" "$(_resolve_org)" "$(_resolve_user)" "$data" \
    >> "$BUFFER_FILE"

  # Buffer guard: if file exceeds max size, truncate to last N events
  if [ -f "$BUFFER_FILE" ]; then
    local size
    size=$(wc -c < "$BUFFER_FILE" 2>/dev/null | tr -d ' ')
    if [ "$size" -gt "$MAX_BUFFER_BYTES" ] 2>/dev/null; then
      local tmp="$BUFFER_FILE.truncate.$$"
      tail -n "$MAX_EVENTS_AFTER_TRUNCATE" "$BUFFER_FILE" > "$tmp" 2>/dev/null \
        && mv "$tmp" "$BUFFER_FILE" \
        || rm -f "$tmp"
    fi
  fi
}

# --- flush: send buffered events to API ---
cmd_flush() {
  if [ ! -f "$BUFFER_FILE" ] || [ ! -s "$BUFFER_FILE" ]; then
    return 0
  fi

  # Read API config
  local api_url=""
  local api_key=""
  if [ -f "$CONFIG" ]; then
    api_url=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null || true)
  fi
  if [ -f "$ENV_FILE" ]; then
    api_key=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)
  fi

  if [ -z "$api_url" ] || [ -z "$api_key" ]; then
    return 0
  fi

  # Atomic rotate: move buffer to temp file so new events can keep writing
  local flush_file="$BUFFER_FILE.flush.$$"
  mv "$BUFFER_FILE" "$flush_file" 2>/dev/null || return 0

  # POST to API
  local response
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "${api_url}/api/telemetry/ingest" \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/x-ndjson" \
    --data-binary "@$flush_file" \
    --max-time 15 2>/dev/null || echo "000")

  if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null; then
    # Success — remove flush file
    rm -f "$flush_file"
  else
    # Failure — move events back so they aren't lost
    if [ -f "$BUFFER_FILE" ]; then
      # New events were written while we were flushing; prepend old events
      cat "$flush_file" "$BUFFER_FILE" > "$BUFFER_FILE.merge.$$" 2>/dev/null \
        && mv "$BUFFER_FILE.merge.$$" "$BUFFER_FILE" \
        && rm -f "$flush_file" \
        || rm -f "$BUFFER_FILE.merge.$$"
    else
      mv "$flush_file" "$BUFFER_FILE" 2>/dev/null || true
    fi
  fi
}

# --- status: show telemetry status ---
cmd_status() {
  echo "Telemetry status:"
  echo ""

  # Consent
  if _check_consent; then
    echo "  Enabled: yes"
  else
    echo "  Enabled: no"
    if [ "${EGREGORE_NO_TELEMETRY:-}" = "1" ]; then
      echo "  Reason: EGREGORE_NO_TELEMETRY=1"
    elif [ "${DO_NOT_TRACK:-}" = "1" ]; then
      echo "  Reason: DO_NOT_TRACK=1"
    else
      echo "  Reason: telemetry=false in .egregore-state.json"
    fi
  fi

  # Buffer
  if [ -f "$BUFFER_FILE" ]; then
    local count size
    count=$(wc -l < "$BUFFER_FILE" 2>/dev/null | tr -d ' ')
    size=$(wc -c < "$BUFFER_FILE" 2>/dev/null | tr -d ' ')
    echo "  Buffer: $count events ($size bytes)"
    echo "  Path: $BUFFER_FILE"
  else
    echo "  Buffer: empty"
  fi

  echo ""
  echo "  Opt-out: set EGREGORE_NO_TELEMETRY=1 in .env, or run /telemetry off"
}

# --- enable: turn telemetry on ---
cmd_enable() {
  if [ -f "$STATE_FILE" ]; then
    jq '.telemetry = true' "$STATE_FILE" > "$STATE_FILE.tmp" \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
  echo "Telemetry enabled."
}

# --- disable: turn telemetry off ---
cmd_disable() {
  if [ -f "$STATE_FILE" ]; then
    jq '.telemetry = false' "$STATE_FILE" > "$STATE_FILE.tmp" \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    echo '{"telemetry": false}' > "$STATE_FILE"
  fi
  echo "Telemetry disabled."
}

# --- clear: delete local buffer ---
cmd_clear() {
  rm -f "$BUFFER_FILE"
  echo "Telemetry buffer cleared."
}

# --- show: display last N events ---
cmd_show() {
  local n="${1:-10}"
  if [ ! -f "$BUFFER_FILE" ] || [ ! -s "$BUFFER_FILE" ]; then
    echo "No buffered events."
    return 0
  fi
  echo "Last $n events:"
  echo ""
  tail -n "$n" "$BUFFER_FILE" | jq . 2>/dev/null || tail -n "$n" "$BUFFER_FILE"
}

# --- Main dispatch ---
case "${1:-status}" in
  emit)
    shift
    cmd_emit "$@"
    ;;
  flush)
    cmd_flush
    ;;
  status)
    cmd_status
    ;;
  enable)
    cmd_enable
    ;;
  disable)
    cmd_disable
    ;;
  clear)
    cmd_clear
    ;;
  show)
    shift
    cmd_show "${1:-10}"
    ;;
  help|*)
    echo "Usage: telemetry.sh <command>"
    echo ""
    echo "Commands:"
    echo "  emit <type> <json>  Append event to local buffer (no network)"
    echo "  flush               Send buffered events to API"
    echo "  status              Show telemetry status"
    echo "  enable              Enable telemetry"
    echo "  disable             Disable telemetry"
    echo "  clear               Clear local buffer"
    echo "  show [n]            Show last N events (default 10)"
    ;;
esac
