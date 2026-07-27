#!/usr/bin/env bash
# Graph Write-Ahead Log — resilient graph writes with local buffer.
# Mirrors bin/telemetry.sh architecture.
#
# Subcommands:
#   append <cypher> <params_json>   Append entry to local JSONL buffer (no network)
#   drain                           Execute pending entries via graph-batch.sh
#   status                          Show pending count + file size as JSON
#
# Storage: ~/.egregore/graph-wal.jsonl
# Buffer guard: 2MB max, auto-truncate to last 200 entries if exceeded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: graph-wal.sh <command>"
  echo ""
  echo "Graph Write-Ahead Log — resilient graph writes with local buffer."
  echo ""
  echo "Commands:"
  echo "  append <cypher> <params>  Append entry to WAL (no network)"
  echo "  drain                     Execute pending entries via graph-batch"
  echo "  status                    Show pending count + file size (JSON)"
  exit 0
fi

WAL_DIR="$HOME/.egregore"
# WAL file is per-instance to prevent cross-org data leakage on multi-instance machines
PROJ_HASH=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
WAL_FILE="$WAL_DIR/graph-wal-${PROJ_HASH}.jsonl"
MAX_BUFFER_BYTES=2097152  # 2MB
MAX_ENTRIES_AFTER_TRUNCATE=200
LOCK_DIR="$WAL_DIR/graph-wal-${PROJ_HASH}.lock"

# --- Cross-platform file locking via mkdir (atomic on all POSIX systems) ---
_lock() {
  local attempts=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 50 ]; then
      # Stale lock — check if holder PID is alive
      local holder_pid
      holder_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
      if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR" 2>/dev/null
        continue
      fi
      echo "graph-wal: lock timeout after 5s" >&2
      return 1
    fi
    sleep 0.1
  done
  echo $$ > "$LOCK_DIR/pid" 2>/dev/null
}

_unlock() {
  rm -rf "$LOCK_DIR" 2>/dev/null
}

trap '_unlock' EXIT

# --- Resolve session ID (same pattern as telemetry.sh) ---
_resolve_session_id() {
  if [ -n "${EGREGORE_SESSION_ID:-}" ]; then
    echo "$EGREGORE_SESSION_ID"
    return
  fi
  local proj_hash
  proj_hash=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
  local sid_file="$WAL_DIR/session-${proj_hash}.id"
  if [ -f "$sid_file" ]; then
    cat "$sid_file" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

# --- append: O(1) local write, no network ---
cmd_append() {
  local cypher="${1:?Usage: graph-wal.sh append <cypher> <params_json>}"
  local params="${2:-"{}"}"

  mkdir -p "$WAL_DIR"

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local sid
  sid=$(_resolve_session_id)

  # Build JSON line
  local line
  line=$(jq -n -c \
    --arg ts "$ts" \
    --arg sid "$sid" \
    --arg cypher "$cypher" \
    --argjson params "$params" \
    '{ts: $ts, sid: $sid, cypher: $cypher, params: $params}')

  # Append under lock — if lock fails, append anyway (durability > mutual exclusion)
  local _locked=true
  _lock || _locked=false
  echo "$line" >> "$WAL_FILE"

  # Buffer guard: truncate to last N entries if file exceeds max size
  # Only safe under lock — tail+mv is not atomic and races with concurrent writers
  if [ "$_locked" = "true" ] && [ -f "$WAL_FILE" ]; then
    local size
    size=$(wc -c < "$WAL_FILE" 2>/dev/null | tr -d ' ')
    if [ "$size" -gt "$MAX_BUFFER_BYTES" ] 2>/dev/null; then
      local total_entries
      total_entries=$(wc -l < "$WAL_FILE" 2>/dev/null | tr -d ' ')
      local dropped=$((total_entries - MAX_ENTRIES_AFTER_TRUNCATE))
      if [ "$dropped" -gt 0 ]; then
        echo "graph-wal: buffer exceeded ${MAX_BUFFER_BYTES} bytes. Dropping $dropped oldest entries (keeping $MAX_ENTRIES_AFTER_TRUNCATE)." >&2
      fi
      local tmp="$WAL_FILE.truncate.$$"
      tail -n "$MAX_ENTRIES_AFTER_TRUNCATE" "$WAL_FILE" > "$tmp" 2>/dev/null \
        && mv "$tmp" "$WAL_FILE" \
        || rm -f "$tmp"
    fi
  fi
  [ "$_locked" = "true" ] && _unlock
}

# --- drain: execute pending entries via graph-batch.sh ---
cmd_drain() {
  if [ ! -f "$WAL_FILE" ] || [ ! -s "$WAL_FILE" ]; then
    return 0
  fi

  # Atomic rotate under lock: move to temp file so new appends don't conflict
  _lock || return 0
  local drain_file="$WAL_FILE.drain.$$"
  mv "$WAL_FILE" "$drain_file" 2>/dev/null || { _unlock; return 0; }
  _unlock

  local total
  total=$(wc -l < "$drain_file" 2>/dev/null | tr -d ' ')
  local batch_size=20
  local offset=0
  local all_ok=true

  while [ "$offset" -lt "$total" ]; do
    # Extract batch of entries (offset+1 through offset+batch_size)
    local batch_lines
    batch_lines=$(tail -n "+$((offset + 1))" "$drain_file" | head -n "$batch_size")

    # Build batch JSON array: [{statement, parameters}, ...]
    local batch_json
    batch_json=$(echo "$batch_lines" | jq -s '[.[] | {statement: .cypher, parameters: .params}]' 2>/dev/null)

    if [ -z "$batch_json" ] || [ "$batch_json" = "[]" ]; then
      offset=$((offset + batch_size))
      continue
    fi

    # Execute via graph-batch.sh
    if bash "$SCRIPT_DIR/bin/graph-batch.sh" "$batch_json" >/dev/null 2>&1; then
      offset=$((offset + batch_size))
    else
      all_ok=false
      break
    fi
  done

  if [ "$all_ok" = "true" ]; then
    # All batches succeeded — remove drain file
    rm -f "$drain_file"
  else
    # Failure — merge unprocessed entries back
    # Extract remaining entries (from offset+1 to end)
    local remaining
    remaining=$(tail -n "+$((offset + 1))" "$drain_file" 2>/dev/null)

    if [ -n "$remaining" ]; then
      _lock || { echo "$remaining" > "$WAL_FILE" 2>/dev/null; rm -f "$drain_file"; return 1; }
      if [ -f "$WAL_FILE" ]; then
        # New entries were written while draining; prepend remaining
        local merge_file="$WAL_FILE.merge.$$"
        { echo "$remaining"; cat "$WAL_FILE"; } > "$merge_file" 2>/dev/null \
          && mv "$merge_file" "$WAL_FILE" \
          && rm -f "$drain_file" \
          || rm -f "$merge_file"
      else
        echo "$remaining" > "$WAL_FILE"
        rm -f "$drain_file"
      fi
      _unlock
    else
      rm -f "$drain_file"
    fi
  fi
}

# --- status: pending count + file size as JSON ---
cmd_status() {
  if [ -f "$WAL_FILE" ] && [ -s "$WAL_FILE" ]; then
    local count size
    count=$(wc -l < "$WAL_FILE" 2>/dev/null | tr -d ' ')
    size=$(wc -c < "$WAL_FILE" 2>/dev/null | tr -d ' ')
    jq -n --argjson pending "$count" --argjson bytes "$size" '{pending: $pending, bytes: $bytes}'
  else
    echo '{"pending":0,"bytes":0}'
  fi
}

# --- Main dispatch ---
case "${1:-status}" in
  append)
    shift
    cmd_append "$@"
    ;;
  drain)
    cmd_drain
    ;;
  status)
    cmd_status
    ;;
  *)
    echo "Usage: graph-wal.sh <command>"
    echo ""
    echo "Commands:"
    echo "  append <cypher> <params>  Append entry to WAL (no network)"
    echo "  drain                     Execute pending entries"
    echo "  status                    Show pending count + file size"
    ;;
esac
