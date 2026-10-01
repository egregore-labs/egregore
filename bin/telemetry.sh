#!/usr/bin/env bash
# Local-first Egregore telemetry compatibility/user CLI.
#
# Emission is always a local append. No command uploads automatically.
# Sharing is an explicit two-step operation bound to one disclosed dataset.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${EGREGORE_TELEMETRY_DIR:-}" ]; then
  BUFFER_DIR="$EGREGORE_TELEMETRY_DIR"
else
  if [ -e "$SCRIPT_DIR/memory" ]; then
    INSTANCE_ROOT="$(cd "$SCRIPT_DIR/memory" && pwd -P)"
  else
    INSTANCE_ROOT="$(cd "$SCRIPT_DIR" && pwd -P)"
  fi
  if command -v shasum >/dev/null 2>&1; then
    INSTANCE_NAMESPACE=$(printf '%s' "$INSTANCE_ROOT" | LC_ALL=C LANG=C shasum -a 256 | awk '{print substr($1,1,20)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    INSTANCE_NAMESPACE=$(printf '%s' "$INSTANCE_ROOT" | sha256sum | awk '{print substr($1,1,20)}')
  else
    INSTANCE_NAMESPACE=$(printf '%s' "$INSTANCE_ROOT" | cksum | awk '{print $1}')
  fi
  BUFFER_DIR="$HOME/.egregore/telemetry/$INSTANCE_NAMESPACE"
fi
BUFFER_FILE="$BUFFER_DIR/telemetry.jsonl"
LOCK_DIR="$BUFFER_DIR/telemetry.lock"
SHARE_CONSENT_FILE="$BUFFER_DIR/telemetry-share-consent.json"
# Exact dataset pinned at proposal time. The confirm step sends this snapshot,
# so events emitted between proposal and confirm (attendant, other sessions)
# can never invalidate — or silently join — a disclosed share.
SHARE_STAGED_FILE="$BUFFER_DIR/telemetry.share-staged.jsonl"
STATE_FILE="${EGREGORE_STATE_FILE:-$SCRIPT_DIR/.egregore-state.json}"
CONFIG="${EGREGORE_CONFIG_FILE:-$SCRIPT_DIR/egregore.json}"
ENV_FILE="${EGREGORE_ENV_FILE:-$SCRIPT_DIR/.env}"
MAX_BUFFER_BYTES=1048576
MAX_EVENTS_AFTER_TRUNCATE=500
SHARE_CONSENT_SECONDS=600
SCHEMA_VERSION="egregore.telemetry/v1"
LEGACY_RELAY_URL="https://egregore-production-55f2.up.railway.app/api/telemetry/relay"

ALLOWED_METRICS_JSON='[
  "action","branch","class","command","connector","cost_usd","count",
  "degraded","docs_read","duration_ms","edges","error_code","escalated",
  "failure_code","index_revision","input_tokens","items","kind","latency_ms",
  "lex_fingerprint","message_count","mode","model","opened_count",
  "output_tokens","override","pass","query_type","rank","result",
  "retrieval_type","route_tier","routed","service","signals","source",
  "status","step","stop_reason","subcommand","success","tier","token_count",
  "tokens_in","tokens_out","tool_call_count","transport","type",
  "vec_fingerprint","waves","writeback_result",
  "invocation_id","harness","layer","operation","outcome","exit_status"
]'

_TELEMETRY_LOCK_HELD=0

_lock() {
  local attempts=0
  mkdir -p "$BUFFER_DIR"
  chmod 700 "$BUFFER_DIR"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 50 ]; then
      local holder_pid=""
      holder_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
      if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR" 2>/dev/null
        continue
      fi
      return 1
    fi
    sleep 0.1
  done
  _TELEMETRY_LOCK_HELD=1
  echo $$ > "$LOCK_DIR/pid" 2>/dev/null
}

_unlock() {
  [ "$_TELEMETRY_LOCK_HELD" = 1 ] || return 0
  _TELEMETRY_LOCK_HELD=0
  rm -rf "$LOCK_DIR" 2>/dev/null
}

trap '_unlock' EXIT

_check_consent() {
  _TELEMETRY_DISABLED_REASON=""
  if [ "${EGREGORE_NO_TELEMETRY:-}" = "1" ]; then
    _TELEMETRY_DISABLED_REASON="EGREGORE_NO_TELEMETRY=1"; return 1
  fi
  if [ "${DO_NOT_TRACK:-}" = "1" ]; then
    _TELEMETRY_DISABLED_REASON="DO_NOT_TRACK=1"; return 1
  fi
  if [ -f "$ENV_FILE" ]; then
    local env_key env_value
    while IFS='=' read -r env_key env_value || [ -n "$env_key" ]; do
      [ "$env_key" = "EGREGORE_NO_TELEMETRY" ] || continue
      env_value=$(printf '%s' "$env_value" | tr -d "[:space:]\"'")
      if [ "$env_value" = "1" ]; then
        _TELEMETRY_DISABLED_REASON="EGREGORE_NO_TELEMETRY=1 in .env"; return 1
      fi
    done < "$ENV_FILE"
  fi
  if [ -f "$STATE_FILE" ]; then
    local value="true"
    value=$(jq -r 'if has("telemetry") then .telemetry else true end' "$STATE_FILE" 2>/dev/null || echo "true")
    if [ "$value" = "false" ]; then
      _TELEMETRY_DISABLED_REASON="telemetry=false in .egregore-state.json"; return 1
    fi
  fi
  return 0
}

_is_debug() {
  [ "${EGREGORE_TELEMETRY_DEBUG:-}" = "1" ]
}

_resolve_actor() {
  if [ -n "${EGREGORE_ACTOR_ID:-}" ]; then
    printf '%s\n' "$EGREGORE_ACTOR_ID"
  elif [ -f "$STATE_FILE" ]; then
    local actor=""
    actor=$(jq -r '.actor_id // empty' "$STATE_FILE" 2>/dev/null || true)
    if [ -n "$actor" ]; then
      printf '%s\n' "$actor"
    else
      local legacy=""
      legacy=$(jq -r '.github_username // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
      printf 'legacy:%s\n' "$legacy"
    fi
  else
    printf 'unknown\n'
  fi
}

_resolve_org() {
  if [ -n "${EGREGORE_ORG_ID:-}" ]; then
    printf '%s\n' "$EGREGORE_ORG_ID"
  elif [ -f "$CONFIG" ]; then
    local org=""
    org=$(jq -r '.org_id // empty' "$CONFIG" 2>/dev/null || true)
    if [ -n "$org" ]; then
      printf '%s\n' "$org"
    else
      local legacy=""
      legacy=$(jq -r '.slug // .github_org // "unknown"' "$CONFIG" 2>/dev/null || echo "unknown")
      printf 'legacy-org:%s\n' "$legacy"
    fi
  else
    printf 'unknown\n'
  fi
}

_resolve_org_revision() {
  if [ -n "${EGREGORE_ORG_REVISION:-}" ]; then
    printf '%s\n' "$EGREGORE_ORG_REVISION"
  elif [ -f "$CONFIG" ]; then
    jq -r '.profile.revision // .revision // empty' "$CONFIG" 2>/dev/null || true
  fi
}

_resolve_index_spec_version() {
  if [ -n "${EGREGORE_INDEX_SPEC_VERSION:-}" ]; then
    printf '%s\n' "$EGREGORE_INDEX_SPEC_VERSION"
  elif [ -f "$CONFIG" ]; then
    jq -r '.retrieval.index_spec_version // .index_spec_version // empty' "$CONFIG" 2>/dev/null || true
  fi
}

_resolve_proj_hash() {
  local repo_root=""
  repo_root=$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||') || repo_root="$SCRIPT_DIR"
  echo -n "$repo_root" | md5 2>/dev/null || echo -n "$repo_root" | md5sum 2>/dev/null | cut -d' ' -f1
}

_resolve_session_id() {
  if [ -n "${EGREGORE_SESSION_ID:-}" ]; then
    printf '%s\n' "$EGREGORE_SESSION_ID"
    return
  fi
  local proj_hash=""
  proj_hash=$(_resolve_proj_hash)
  local sid_file="$HOME/.egregore/session-${proj_hash}.id"
  if [ -f "$sid_file" ]; then
    cat "$sid_file" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

_resolve_model() {
  local proj_hash=""
  proj_hash=$(_resolve_proj_hash)
  local model_file="$HOME/.egregore/session-model-${proj_hash}"
  [ -s "$model_file" ] || return 0
  head -n 1 "$model_file"
}

_stamp_model_if_absent() {
  local data="$1"
  if printf '%s' "$data" | jq -e 'has("model")' >/dev/null 2>&1; then
    printf '%s' "$data"
    return
  fi
  local model=""
  model=$(_resolve_model 2>/dev/null || true)
  if [ -n "$model" ]; then
    printf '%s' "$data" | jq -c --arg model "$model" '. + {model:$model}'
  else
    printf '%s' "$data"
  fi
}

_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    LC_ALL=C LANG=C shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | LC_ALL=C LANG=C shasum -a 256 | cut -d' ' -f1
  else
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  fi
}

_random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    local seed=""
    seed="$(date +%s)-$$-${RANDOM:-0}"
    _sha256_text "$seed"
  fi
}

_validate_metrics() {
  local metrics="$1"
  printf '%s' "$metrics" | jq -e --argjson allowed "$ALLOWED_METRICS_JSON" '
    type == "object" and
    ((keys - $allowed) | length == 0) and
    (if has("operation") then (.operation == "search" or .operation == "save") else true end) and
    (if has("layer") then .layer == "operation" else true end) and
    (if has("outcome") then (.outcome == "success" or .outcome == "error" or .outcome == "cancelled") else true end) and
    (if has("harness") then (.harness as $h | ["claude","codex","pi","prime","shell","test","unknown"] | index($h) != null) else true end) and
    (if has("invocation_id") then (.invocation_id | type == "string" and test("^op_[0-9]{10}_[0-9a-f]{32}$")) else true end) and
    (if has("exit_status") then (.exit_status | type == "number" and . == floor and . >= 0 and . < 128) else true end) and
    all(to_entries[];
      (.value == null or
       (.value | type) == "boolean" or
       (.value | type) == "number" or
       ((.value | type) == "string" and (.value | length) > 0 and (.value | length) <= 200 and
        (.value | test("^[A-Za-z0-9_.:+@/\\[\\]-]+$")) and
        (.value | contains("/") | not) and
        ((.key == "lex_fingerprint" or .key == "vec_fingerprint") | not or
          (.value | test("^sha256:[0-9a-f]{6,64}$"))) and
        (.key != "source" or (["framework","org","default","fallback","user","unknown","local","test"] | index(.value)) != null))))
  ' >/dev/null
}

_validate_buffer() {
  local target="${1:-$BUFFER_FILE}"
  [ -s "$target" ] || return 0
  # Slurp and reduce every row: jq -e on a JSONL stream only checks its last result.
  jq -se --arg schema "$SCHEMA_VERSION" --argjson allowed "$ALLOWED_METRICS_JSON" '
    def safe_id:
      type == "string" and length > 0 and length <= 256 and
      test("^[A-Za-z0-9_.:+@/\\[\\]-]+$");
    def safe_metrics:
      type == "object" and
      ((keys - $allowed) | length == 0) and
    (if has("operation") then (.operation == "search" or .operation == "save") else true end) and
    (if has("layer") then .layer == "operation" else true end) and
    (if has("outcome") then (.outcome == "success" or .outcome == "error" or .outcome == "cancelled") else true end) and
    (if has("harness") then (.harness as $h | ["claude","codex","pi","prime","shell","test","unknown"] | index($h) != null) else true end) and
    (if has("invocation_id") then (.invocation_id | type == "string" and test("^op_[0-9]{10}_[0-9a-f]{32}$")) else true end) and
    (if has("exit_status") then (.exit_status | type == "number" and . == floor and . >= 0 and . < 128) else true end) and
      all(to_entries[];
        (.value == null or
         (.value | type) == "boolean" or
         (.value | type) == "number" or
         ((.value | type) == "string" and (.value | length) > 0 and (.value | length) <= 200 and
          (.value | test("^[A-Za-z0-9_.:+@/\\[\\]-]+$")) and
          (.value | contains("/") | not) and
          ((.key == "lex_fingerprint" or .key == "vec_fingerprint") | not or
            (.value | test("^sha256:[0-9a-f]{6,64}$"))) and
          (.key != "source" or (["framework","org","default","fallback","user","unknown","local","test"] | index(.value)) != null))));
    def operation_envelope:
      if .event_type == "operation.start" or .event_type == "operation.result" then
        ["operation", "layer", "invocation_id", "harness"] as $required |
        .artifact_ids == [] and .task_id == null and
        .org_revision == null and .index_spec_version == null and
        (.metrics | ($required - keys | length == 0) and
          (keys - ($required + ["outcome", "duration_ms", "exit_status"]) | length == 0)) and
        (if .event_type == "operation.start" then
          (.metrics | keys - $required | length == 0)
        else
          (.metrics | has("outcome") and has("duration_ms") and
            (.duration_ms | type == "number" and . == floor and . >= 0))
        end)
      else true end;
    all(.[]; if .schema_version == $schema then
      ((keys - ["actor_id","artifact_ids","event_id","event_type",
        "index_spec_version","metrics","occurred_at","org_id","org_revision",
        "schema_version","session_id","shared","task_id"]) | length == 0) and
      (.metrics | safe_metrics) and
      (.event_id | safe_id) and (.event_type | safe_id) and
      (.org_id | safe_id) and (.actor_id | safe_id) and (.session_id | safe_id) and
      (.task_id == null or (.task_id | safe_id)) and
      (.org_revision == null or (.org_revision | safe_id)) and
      (.index_spec_version == null or (.index_spec_version | safe_id)) and
      (.artifact_ids | type == "array" and all(.[]; safe_id)) and operation_envelope
    else
      ((keys - ["data","event_id","org","sid","ts","type","user"]) | length == 0) and
      (.data | safe_metrics) and (.ts | type == "string") and
      (.type | safe_id) and (.sid | safe_id) and (.org | safe_id) and (.user | safe_id) and
      ({event_type: .type, metrics: .data, artifact_ids: []} | operation_envelope)
    end)
  ' "$target" >/dev/null 2>&1
}

cmd_emit() {
  local event_type="${1:?Usage: telemetry.sh emit <type> <json>}"
  local data="${2:-}"
  [ -n "$data" ] || data='{}'
  _check_consent || return 0

  local compact_data=""
  if ! compact_data=$(printf '%s' "$data" | jq -c . 2>/dev/null); then
    echo "Telemetry event rejected: payload must be valid JSON." >&2
    return 0
  fi
  compact_data=$(_stamp_model_if_absent "$compact_data")

  local task_id org_revision index_spec_version artifact_ids metrics
  task_id=$(printf '%s' "$compact_data" | jq -r '.task_id // empty')
  org_revision=$(printf '%s' "$compact_data" | jq -r '.org_revision // empty')
  [ -n "$org_revision" ] || org_revision=$(_resolve_org_revision)
  index_spec_version=$(printf '%s' "$compact_data" | jq -r '.index_spec_version // empty')
  [ -n "$index_spec_version" ] || index_spec_version=$(_resolve_index_spec_version)
  artifact_ids=$(printf '%s' "$compact_data" | jq -c '.artifact_ids // .opened_artifact_ids // []')
  metrics=$(printf '%s' "$compact_data" | jq -c 'del(.task_id,.org_revision,.index_spec_version,.artifact_ids,.opened_artifact_ids)')

  if ! printf '%s' "$artifact_ids" | jq -e 'type == "array" and all(.[]; type == "string" and length > 0 and length <= 256 and test("^[A-Za-z0-9_.:+@/\\[\\]-]+$"))' >/dev/null 2>&1 \
    || ! printf '%s\n%s\n%s\n%s\n' "$event_type" "$task_id" "$org_revision" "$index_spec_version" | awk 'length($0) > 256 { exit 1 } /[^A-Za-z0-9_.:+@\/\[\]-]/ && length($0) > 0 { exit 1 }' \
    || ! _validate_metrics "$metrics"; then
    echo "Telemetry event rejected: only allowlisted, content-free metrics are accepted." >&2
    return 0
  fi

  local ts event_id line
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  event_id="tel_$(_random_token)"
  line=$(jq -cn \
    --arg schema "$SCHEMA_VERSION" \
    --arg event_id "$event_id" \
    --arg event_type "$event_type" \
    --arg occurred_at "$ts" \
    --arg org_id "$(_resolve_org)" \
    --arg actor_id "$(_resolve_actor)" \
    --arg session_id "$(_resolve_session_id)" \
    --arg task_id "$task_id" \
    --arg org_revision "$org_revision" \
    --arg index_spec_version "$index_spec_version" \
    --argjson metrics "$metrics" \
    --argjson artifact_ids "$artifact_ids" \
    '{schema_version:$schema,event_id:$event_id,event_type:$event_type,
      occurred_at:$occurred_at,org_id:$org_id,actor_id:$actor_id,
      session_id:$session_id,task_id:(if $task_id == "" then null else $task_id end),
      org_revision:(if $org_revision == "" then null else $org_revision end),
      index_spec_version:(if $index_spec_version == "" then null else $index_spec_version end),
      metrics:$metrics,artifact_ids:$artifact_ids,shared:false}')

  if _is_debug; then
    printf '%s\n' "$line" >&2
    return 0
  fi

  mkdir -p "$BUFFER_DIR"
  _lock || { printf '%s\n' "$line" >> "$BUFFER_FILE" 2>/dev/null; return 0; }
  printf '%s\n' "$line" >> "$BUFFER_FILE"
  chmod 600 "$BUFFER_FILE"
  local size=0
  size=$(wc -c < "$BUFFER_FILE" 2>/dev/null | tr -d ' ')
  if [ "$size" -gt "$MAX_BUFFER_BYTES" ] 2>/dev/null; then
    local temporary="$BUFFER_FILE.truncate.$$"
    if tail -n "$MAX_EVENTS_AFTER_TRUNCATE" "$BUFFER_FILE" > "$temporary" 2>/dev/null; then
      mv "$temporary" "$BUFFER_FILE"
    else
      rm -f "$temporary"
    fi
  fi
  _unlock
}

cmd_status() {
  local enabled="yes" reason="" count=0 size=0
  if ! _check_consent; then
    enabled="no"
    reason="$_TELEMETRY_DISABLED_REASON"
  fi
  if [ -f "$BUFFER_FILE" ]; then
    count=$(grep -c '^{' "$BUFFER_FILE" 2>/dev/null || true)
    size=$(wc -c < "$BUFFER_FILE" 2>/dev/null | tr -d ' ')
  fi
  if [ "${1:-}" = "--json" ]; then
    # Machine snapshot for the Settings panel. Deliberately excludes buffer
    # paths and raw events — the panel never renders payloads or internal
    # locations.
    local noticed="false" last=""
    [ -f "$STATE_FILE" ] && noticed=$(jq -r 'if .telemetry_noticed == true then "true" else "false" end' "$STATE_FILE" 2>/dev/null || echo false)
    [ -f "$BUFFER_FILE" ] && last=$(tail -1 "$BUFFER_FILE" 2>/dev/null | jq -r '.occurred_at // .ts // empty' 2>/dev/null || true)
    jq -n \
      --arg enabled "$([ "$enabled" = "yes" ] && echo true || echo false)" \
      --arg reason "$reason" \
      --argjson events "${count:-0}" \
      --argjson bytes "${size:-0}" \
      --argjson noticed "$noticed" \
      --arg last "$last" \
      '{
        enabled: ($enabled == "true"),
        reason: (if $reason == "" then null else $reason end),
        buffered_events: $events,
        buffered_bytes: $bytes,
        notice_shown: $noticed,
        last_event_at: (if $last == "" then null else $last end),
        storage: "local buffer only — never shared automatically"
      }'
    return 0
  fi
  echo "Telemetry status:"
  echo ""
  echo "  Enabled: $enabled"
  [ -z "$reason" ] || echo "  Reason: $reason"
  echo "  Storage: local only (never shared automatically)"
  echo "  Buffer: $count events ($size bytes)"
  echo "  Path: $BUFFER_FILE"
  echo ""
  echo "  Inspect: bash bin/telemetry.sh inspect 10"
  echo "  Export:  bash bin/telemetry.sh export <destination.jsonl>"
  echo "  Share:   bash bin/telemetry.sh share (requires a second confirmation step)"
  echo "  Opt out: set EGREGORE_NO_TELEMETRY=1 or run /telemetry off"
}

_set_enabled() {
  local value="$1"
  local temporary="$STATE_FILE.tmp.$$"
  if [ -f "$STATE_FILE" ]; then
    jq --argjson value "$value" '.telemetry = $value' "$STATE_FILE" > "$temporary" \
      && chmod 600 "$temporary" && mv "$temporary" "$STATE_FILE"
  else
    jq -n --argjson value "$value" '{telemetry:$value}' > "$temporary" \
      && chmod 600 "$temporary" && mv "$temporary" "$STATE_FILE"
  fi
}

cmd_enable() {
  _set_enabled true
  echo "Telemetry enabled. Events remain local until an explicit share is confirmed."
}

cmd_disable() {
  _set_enabled false
  echo "Telemetry disabled. Existing local events were not deleted."
}

cmd_clear() {
  if ! _lock; then
    echo "Could not acquire the telemetry lock; nothing was cleared." >&2
    return 1
  fi
  rm -f "$BUFFER_FILE" "$SHARE_CONSENT_FILE" "$SHARE_STAGED_FILE" \
    "$BUFFER_DIR/telemetry-retention.json" "$BUFFER_DIR/operation-observations.json"
  _unlock
  echo "Local telemetry buffer cleared."
}

cmd_inspect() {
  local n="${1:-10}" json=0
  [ "${2:-}" = "--json" ] && json=1
  [ "$n" = "--json" ] && { json=1; n=10; }
  case "$n" in
    ''|*[!0-9]*) echo "inspect limit must be a non-negative integer" >&2; return 2 ;;
  esac
  if [ ! -s "$BUFFER_FILE" ]; then
    [ "$json" -eq 1 ] && echo '[]' || echo "No buffered events."
    return 0
  fi
  if [ "$json" -eq 1 ]; then
    tail -n "$n" "$BUFFER_FILE" | jq -sc 'map({occurred_at, event_type, metrics})' 2>/dev/null || echo '[]'
    return 0
  fi
  echo "Last $n local events:"
  echo ""
  tail -n "$n" "$BUFFER_FILE" | jq -c . 2>/dev/null || tail -n "$n" "$BUFFER_FILE"
}

cmd_export() {
  local destination="${1:?Usage: telemetry.sh export <destination.jsonl>}"
  if ! _validate_buffer; then
    echo "Export blocked: the local buffer contains an invalid or content-bearing event." >&2
    return 2
  fi
  mkdir -p "$(dirname "$destination")"
  if [ -s "$BUFFER_FILE" ]; then
    cp "$BUFFER_FILE" "$destination"
  else
    : > "$destination"
  fi
  echo "Exported local telemetry to $destination"
}

_resolve_share_target() {
  local requested_endpoint="$1"
  local allow_legacy_relay="$2"
  if [ -n "$requested_endpoint" ]; then
    printf '%s\n' "$requested_endpoint"
    return
  fi
  local api_url="" api_key=""
  if [ -f "$CONFIG" ]; then
    api_url=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null || true)
  fi
  if [ -f "$ENV_FILE" ]; then
    api_key=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)
  fi
  if [ -n "$api_url" ] && [ -n "$api_key" ]; then
    printf '%s/api/telemetry/ingest\n' "${api_url%/}"
  elif [ "$allow_legacy_relay" = "true" ]; then
    printf '%s\n' "$LEGACY_RELAY_URL"
  fi
}

cmd_share() {
  local confirmation="" requested_endpoint="" allow_legacy_relay="false" json_output="false"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --confirm)
        confirmation="${2:-}"
        shift 2
        ;;
      --endpoint)
        requested_endpoint="${2:-}"
        shift 2
        ;;
      --legacy-public-relay)
        allow_legacy_relay="true"
        shift
        ;;
      --json)
        json_output="true"
        shift
        ;;
      *)
        echo "Unknown share option: $1" >&2
        return 2
        ;;
    esac
  done

  if [ -n "$confirmation" ] && [ -z "$requested_endpoint" ] && [ -f "$SHARE_CONSENT_FILE" ]; then
    requested_endpoint=$(jq -r '.target // empty' "$SHARE_CONSENT_FILE" 2>/dev/null || true)
  fi

  local endpoint=""
  endpoint=$(_resolve_share_target "$requested_endpoint" "$allow_legacy_relay")
  if [ -z "$endpoint" ]; then
    echo "No shared telemetry sink is configured. Export locally, or name an explicit --endpoint." >&2
    echo "The former public relay remains available only with --legacy-public-relay." >&2
    return 2
  fi
  case "$endpoint" in
    https://*|http://127.0.0.1*|http://localhost*|http://\[::1\]*) ;;
    *) echo "Share endpoint must use https (or loopback http)." >&2; return 2 ;;
  esac
  # Proposal validates the live buffer it is about to stage; confirm validates
  # the staged snapshot it is about to send — never the moving buffer.
  if [ -z "$confirmation" ] && ! _validate_buffer; then
    echo "Share blocked: the local buffer contains an invalid or content-bearing event." >&2
    return 2
  fi
  if [ -n "$confirmation" ] && ! _validate_buffer "$SHARE_STAGED_FILE"; then
    echo "Share blocked: the staged dataset contains an invalid or content-bearing event." >&2
    return 2
  fi

  local count=0 size=0 dataset_sha256=""
  if [ -z "$confirmation" ]; then
    mkdir -p "$BUFFER_DIR"
    if [ -s "$BUFFER_FILE" ]; then
      cp "$BUFFER_FILE" "$SHARE_STAGED_FILE"
    else
      : > "$SHARE_STAGED_FILE"
    fi
    chmod 600 "$SHARE_STAGED_FILE"
    count=$(grep -c '^{' "$SHARE_STAGED_FILE" 2>/dev/null || true)
    size=$(wc -c < "$SHARE_STAGED_FILE" 2>/dev/null | tr -d ' ')
    dataset_sha256=$(_sha256_file "$SHARE_STAGED_FILE")
    local fields="none"
    if [ -s "$SHARE_STAGED_FILE" ]; then
      fields=$(jq -rs '
        [.[].metrics // .[].data // {} | keys[]] | unique |
        if length == 0 then "none" else map("metrics." + .) | join(", ") end
      ' "$SHARE_STAGED_FILE" 2>/dev/null || echo "unable to inspect")
    fi
    local token token_sha256 expires_at
    token=$(_random_token)
    token_sha256=$(_sha256_text "$token")
    expires_at=$(($(date +%s) + SHARE_CONSENT_SECONDS))
    mkdir -p "$BUFFER_DIR"
    jq -n \
      --arg target "$endpoint" \
      --arg dataset_sha256 "$dataset_sha256" \
      --arg token_sha256 "$token_sha256" \
      --argjson expires_at "$expires_at" \
      '{target:$target,dataset_sha256:$dataset_sha256,token_sha256:$token_sha256,expires_at:$expires_at}' \
      > "$SHARE_CONSENT_FILE"
    chmod 600 "$SHARE_CONSENT_FILE"

    if [ "$json_output" = "true" ]; then
      # Machine-readable proposal for thin surfaces (the launcher). Same
      # consent protocol: the token here is the only place it exists, and a
      # send still requires a separate explicit `share --confirm`.
      jq -n \
        --arg target "$endpoint" \
        --argjson events "${count:-0}" \
        --argjson bytes "${size:-0}" \
        --arg dataset_sha256 "$dataset_sha256" \
        --arg metric_fields "$fields" \
        --arg token "$token" \
        --argjson expires_at "$expires_at" \
        '{proposal:true, sent:false, target:$target, events:$events, bytes:$bytes,
          dataset_sha256:$dataset_sha256, metric_fields:$metric_fields,
          excluded:"prompts, content, passages, file paths, arguments, secrets, env values",
          token:$token, expires_at:$expires_at}'
      return 0
    fi

    echo "Telemetry share proposal (nothing sent):"
    echo ""
    echo "  Target: $endpoint"
    echo "  Events: $count"
    echo "  Bytes: $size"
    echo "  Dataset SHA-256: $dataset_sha256"
    echo "  Top-level fields: schema/version, event/task/org/actor/session identifiers, timestamps, artifact ids, shared flag"
    echo "  Metric fields: $fields"
    echo "  Excluded by validation: prompts, content, passages, file paths, arguments, secrets, env values"
    echo ""
    echo "Inspect first: bash bin/telemetry.sh inspect $count"
    echo "Confirm within 10 minutes with this one-time token:"
    echo "  bash bin/telemetry.sh share --confirm '$token'"
    return 0
  fi

  if [ ! -f "$SHARE_CONSENT_FILE" ] || [ ! -f "$SHARE_STAGED_FILE" ]; then
    echo "Share blocked: run share without --confirm to inspect and prepare this dataset first." >&2
    return 2
  fi
  # The staged snapshot is the disclosed dataset: exactly what the proposal
  # named is what ships, and later buffer growth cannot invalidate it.
  count=$(grep -c '^{' "$SHARE_STAGED_FILE" 2>/dev/null || true)
  dataset_sha256=$(_sha256_file "$SHARE_STAGED_FILE")
  local expected_target expected_dataset expected_token expires_at actual_token
  expected_target=$(jq -r '.target // empty' "$SHARE_CONSENT_FILE")
  expected_dataset=$(jq -r '.dataset_sha256 // empty' "$SHARE_CONSENT_FILE")
  expected_token=$(jq -r '.token_sha256 // empty' "$SHARE_CONSENT_FILE")
  expires_at=$(jq -r '.expires_at // 0' "$SHARE_CONSENT_FILE")
  actual_token=$(_sha256_text "$confirmation")
  if [ "$(date +%s)" -gt "$expires_at" ] 2>/dev/null; then
    rm -f "$SHARE_CONSENT_FILE" "$SHARE_STAGED_FILE"
    echo "Share blocked: confirmation expired; prepare a new share." >&2
    return 2
  fi
  if [ "$endpoint" != "$expected_target" ] || [ "$dataset_sha256" != "$expected_dataset" ] || [ "$actual_token" != "$expected_token" ]; then
    echo "Share blocked: target, dataset, or confirmation token changed; prepare a new share." >&2
    return 2
  fi

  local share_file="$BUFFER_DIR/telemetry.share.$$"
  if [ -s "$SHARE_STAGED_FILE" ]; then
    jq -c --arg schema "$SCHEMA_VERSION" '
      if .schema_version == $schema then
        {ts:.occurred_at,type:.event_type,sid:.session_id,org:.org_id,user:.actor_id,
         data:(.metrics + {event_id:.event_id,schema_version:.schema_version,
           artifact_ids:.artifact_ids,task_id:.task_id,org_revision:.org_revision,
           index_spec_version:.index_spec_version,shared:true})}
      else . end
    ' "$SHARE_STAGED_FILE" > "$share_file"
  else
    : > "$share_file"
  fi

  local curl_args=(-s -o /dev/null -w '%{http_code}' -X POST "$endpoint"
    -H "Content-Type: application/x-ndjson" --data-binary "@$share_file" --max-time 15)
  local api_key="" configured_endpoint=""
  configured_endpoint=$(_resolve_share_target "" "false")
  if [ -n "$configured_endpoint" ] && [ "$endpoint" = "$configured_endpoint" ] && [ -f "$ENV_FILE" ]; then
    api_key=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)
  fi
  [ -z "$api_key" ] || curl_args+=(-H "Authorization: Bearer $api_key")
  local http_code="000"
  http_code=$(curl "${curl_args[@]}" 2>/dev/null || echo "000")
  rm -f "$share_file"
  if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null; then
    rm -f "$SHARE_CONSENT_FILE" "$SHARE_STAGED_FILE"
    echo "Shared $count telemetry events with $endpoint. Local events were retained."
  else
    echo "Share failed (HTTP $http_code). Nothing was removed locally." >&2
    return 1
  fi
}

cmd_flush() {
  # Compatibility boundary for old startup/session-end callers. Deliberately
  # does no I/O so an unattended lifecycle hook can never grant share consent.
  echo "Automatic telemetry sharing is disabled; use 'telemetry.sh share' explicitly." >&2
}

cmd_help() {
  echo "Usage: telemetry.sh <command>"
  echo ""
  echo "Commands:"
  echo "  emit <type> <json>       Append a validated event locally (no network)"
  echo "  status                   Show local collection status"
  echo "  inspect [n]              Inspect the last N local events"
  echo "  export <path>            Export the validated local dataset"
  echo "  share [options]          Prepare or confirm an explicit share"
  echo "  enable | disable         Change local collection setting"
  echo "  clear                    Delete the local buffer"
  echo "  flush                    Compatibility no-op; never uploads"
}

case "${1:-status}" in
  emit) shift; cmd_emit "$@" ;;
  status) shift; cmd_status "$@" ;;
  enable|on) cmd_enable ;;
  disable|off) cmd_disable ;;
  clear) cmd_clear ;;
  inspect|show) shift; cmd_inspect "$@" ;;
  export) shift; cmd_export "$@" ;;
  share) shift; cmd_share "$@" ;;
  flush) cmd_flush ;;
  help|-h|--help) cmd_help ;;
  *) cmd_help >&2; exit 2 ;;
esac
