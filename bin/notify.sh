#!/usr/bin/env bash
set -euo pipefail

# Human-consented notification transport.
#
# No command in this file can plan and dispatch in one step:
#   1. plan     — resolve exact destinations and persist immutable content
#   2. approve  — record one explicit human approval for that exact digest
#   3. dispatch — consume the one-use approval and send the stored payload
#
# Legacy `send` / `group` commands only create a plan and exit 4. They never
# dispatch. This makes the invariant fail closed for stale skills and jobs.

SCRIPT_DIR="${EGREGORE_NOTIFY_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG="$SCRIPT_DIR/egregore.json"

[ -f "$CONFIG" ] || {
  echo "Error: egregore.json not found." >&2
  exit 1
}

umask 077

MODE="$(jq -r '.mode // "connected"' "$CONFIG" 2>/dev/null || echo connected)"
ORG_SLUG="$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null || true)"
ORG_NAME="$(jq -r '.org_name // .slug // empty' "$CONFIG" 2>/dev/null || true)"
SESSION_ID="$(sed -n '1p' "$SCRIPT_DIR/.egregore-session-id" 2>/dev/null || true)"
SESSION_ID="${SESSION_ID:-no-session}"
PROJECT_HASH="$(printf '%s' "$SCRIPT_DIR" | cksum | awk '{print $1}')"
STATE_DIR="${EGREGORE_NOTIFY_STATE_DIR:-$HOME/.egregore/notifications/$PROJECT_HASH}"
RELAY_URL="${EGREGORE_NOTIFY_RELAY_URL:-https://egregore-production-55f2.up.railway.app}"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

if [ -f "$SCRIPT_DIR/.env" ]; then
  EGREGORE_API_URL="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
  EGREGORE_API_KEY="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
fi
API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)}"
API_KEY="${EGREGORE_API_KEY:-}"

die() {
  echo "Error: $*" >&2
  exit 1
}

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

random_token() {
  openssl rand -hex 16
}

plan_path() {
  local id="$1"
  case "$id" in
    ""|*[!a-f0-9]*) die "invalid notification plan id" ;;
  esac
  printf '%s/%s.json\n' "$STATE_DIR" "$id"
}

read_plan() {
  local id="$1"
  local path
  path="$(plan_path "$id")"
  [ -f "$path" ] || die "notification plan not found: $id"
  jq -e . "$path" >/dev/null 2>&1 || die "notification plan is unreadable: $id"
  printf '%s\n' "$path"
}

canonical_plan() {
  jq -cS '{
    version,
    id,
    session_id,
    mode,
    org_slug,
    org_name,
    kind,
    recipient,
    message,
    channels,
    deliveries,
    no_fallback,
    expires_at,
    server_plan_token
  }' "$1"
}

verify_digest() {
  local path="$1"
  local stored actual
  stored="$(jq -r '.digest' "$path")"
  actual="$(canonical_plan "$path" | hash_text)"
  [ "$stored" = "$actual" ] || die "notification plan changed after preview"
}

verify_live_plan() {
  local path="$1"
  local plan_session plan_mode expires now
  plan_session="$(jq -r '.session_id' "$path")"
  [ "$plan_session" = "$SESSION_ID" ] ||
    die "notification approval belongs to another session"
  plan_mode="$(jq -r '.mode' "$path")"
  [ "$plan_mode" = "$MODE" ] ||
    die "notification configuration changed; prepare it again"
  expires="$(jq -r '.expires_at' "$path")"
  now="$(date +%s)"
  [ "$expires" -ge "$now" ] || die "notification plan expired; prepare it again"
  verify_digest "$path"
}

write_plan() {
  local plan_response="$1"
  local kind="$2"
  local recipient="$3"
  local message="$4"
  local id created expires path tmp
  id="$(random_token | cut -c1-24)"
  created="$(date +%s)"
  expires="$(printf '%s' "$plan_response" | jq -r '.expires_at // empty')"
  expires="${expires:-$((created + 600))}"
  path="$(plan_path "$id")"
  tmp="$path.tmp"

  printf '%s' "$plan_response" | jq \
    --arg id "$id" \
    --arg session "$SESSION_ID" \
    --arg mode "$MODE" \
    --arg slug "$ORG_SLUG" \
    --arg orgName "$ORG_NAME" \
    --arg kind "$kind" \
    --arg recipient "$recipient" \
    --arg message "$message" \
    --argjson created "$created" \
    --argjson expires "$expires" \
    '{
      version: 1,
      id: $id,
      status: "proposed",
      session_id: $session,
      mode: $mode,
      org_slug: (.org_slug // $slug),
      org_name: (.org_name // $orgName),
      kind: $kind,
      recipient: (if $recipient == "" then null else $recipient end),
      message: $message,
      channels: (.channels // []),
      deliveries: (.deliveries // []),
      no_fallback: true,
      created_at: $created,
      expires_at: $expires,
      server_plan_token: (.plan_token // ""),
      digest: ""
    }' > "$tmp"

  local digest
  digest="$(canonical_plan "$tmp" | hash_text)"
  jq --arg digest "$digest" '.digest = $digest' "$tmp" > "$path"
  rm -f "$tmp"
  chmod 600 "$path" 2>/dev/null || true
  jq '{
    status: "approval_required",
    plan_id: .id,
    digest,
    org: .org_name,
    recipient,
    channels,
    deliveries,
    no_fallback,
    message,
    expires_at
  }' "$path"
}

read_local_telegram_config() {
  local field="$1"
  local state_file="$SCRIPT_DIR/.egregore-state.json"
  local value
  value="$(jq -r ".$field // empty" "$state_file" 2>/dev/null || true)"
  [ -n "$value" ] ||
    value="$(jq -r ".$field // empty" "$CONFIG" 2>/dev/null || true)"
  printf '%s\n' "$value"
}

plan_connected() {
  local kind="$1"
  local recipient="$2"
  local message="$3"
  [ -n "$API_URL" ] && [ -n "$API_KEY" ] ||
    die "notification service is not connected"

  local response
  response="$(curl -sS -X POST "${API_URL}/api/notify/plan" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc \
      --arg kind "$kind" \
      --arg to "$recipient" \
      --arg message "$message" \
      '{kind:$kind, message:$message}
       + (if $to == "" then {} else {to:$to} end)')" \
    --max-time 10)" || die "notification planning failed"

  printf '%s' "$response" | jq -e '.status == "planned"' >/dev/null 2>&1 ||
    die "$(printf '%s' "$response" | jq -r '.detail // "notification planning failed"' 2>/dev/null)"
  write_plan "$response" "$kind" "$recipient" "$message"
}

plan_local() {
  local kind="$1"
  local recipient="$2"
  local message="$3"
  if [ "$kind" = "send" ]; then
    die "direct messages are unavailable in local mode; no group fallback was sent"
  fi

  local chat_id group_link destination
  chat_id="$(read_local_telegram_config telegram_chat_id)"
  group_link="$(read_local_telegram_config telegram_group_link)"
  [ -n "$chat_id" ] || [ -n "$group_link" ] ||
    die "no Telegram group is configured"
  destination="${group_link:-$chat_id}"

  local response
  response="$(jq -nc \
    --arg slug "$ORG_SLUG" \
    --arg org "$ORG_NAME" \
    --arg destination "$destination" \
    '{
      status:"planned",
      org_slug:$slug,
      org_name:$org,
      channels:["telegram"],
      deliveries:[{channel:"telegram", destination:$destination, kind:"group"}],
      no_fallback:true
    }')"
  write_plan "$response" "$kind" "$recipient" "$message"
}

plan_notification() {
  local kind="$1"
  local recipient="$2"
  local message="$3"
  [ -n "$message" ] || die "notification message is empty"
  case "$MODE" in
    connected) plan_connected "$kind" "$recipient" "$message" ;;
    local) plan_local "$kind" "$recipient" "$message" ;;
    *) die "notifications are unavailable in this configuration" ;;
  esac
}

approve_plan() {
  local id="$1"
  local supplied_digest="$2"
  local confirmation="$3"
  [ "$confirmation" = "APPROVE_EXACT_NOTIFICATION" ] ||
    die "explicit notification confirmation is required"

  local path status digest token token_hash tmp
  path="$(read_plan "$id")"
  verify_live_plan "$path"
  status="$(jq -r '.status' "$path")"
  [ "$status" = "proposed" ] || die "notification plan is not awaiting approval"
  digest="$(jq -r '.digest' "$path")"
  [ "$supplied_digest" = "$digest" ] ||
    die "approval does not match the previewed notification"

  token="$(random_token)"
  token_hash="$(printf '%s' "$token" | hash_text)"
  tmp="$path.tmp"
  jq \
    --arg tokenHash "$token_hash" \
    --argjson approvedAt "$(date +%s)" \
    '.status = "approved"
     | .approval_token_hash = $tokenHash
     | .approved_at = $approvedAt' "$path" > "$tmp"
  mv "$tmp" "$path"
  jq -nc --arg id "$id" --arg token "$token" \
    '{status:"approved", plan_id:$id, approval_token:$token}'
}

mark_plan() {
  local path="$1"
  local status="$2"
  local detail="${3:-}"
  local tmp="$path.tmp"
  jq \
    --arg status "$status" \
    --arg detail "$detail" \
    --argjson changedAt "$(date +%s)" \
    '.status = $status
     | .status_detail = (if $detail == "" then null else $detail end)
     | .status_changed_at = $changedAt' "$path" > "$tmp"
  mv "$tmp" "$path"
}

dispatch_connected() {
  local path="$1"
  local kind message plan_token response
  kind="$(jq -r '.kind' "$path")"
  message="$(jq -r '.message' "$path")"
  plan_token="$(jq -r '.server_plan_token' "$path")"

  if [ "$kind" = "send" ]; then
    local recipient channel
    recipient="$(jq -r '.recipient' "$path")"
    channel="$(jq -r '.channels[0]' "$path")"
    response="$(curl -sS -X POST "${API_URL}/api/notify/send" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -nc \
        --arg to "$recipient" \
        --arg message "$message" \
        --arg channel "$channel" \
        --arg planToken "$plan_token" \
        '{to:$to,message:$message,channel:$channel,plan_token:$planToken}')" \
      --max-time 10)" || return 1
  else
    local channels
    channels="$(jq -c '.channels' "$path")"
    response="$(curl -sS -X POST "${API_URL}/api/notify/group" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -nc \
        --arg message "$message" \
        --arg planToken "$plan_token" \
        --argjson channels "$channels" \
        '{message:$message,channels:$channels,plan_token:$planToken}')" \
      --max-time 10)" || return 1
  fi

  printf '%s' "$response" | jq -e '.status == "sent"' >/dev/null 2>&1 || {
    printf '%s\n' "$response"
    return 1
  }
  printf '%s\n' "$response"
}

dispatch_local() {
  local path="$1"
  local message destination chat_id group_link plan_slug plan_org response
  message="$(jq -r '.message' "$path")"
  destination="$(jq -r '.deliveries[0].destination' "$path")"
  case "$destination" in
    https://t.me/*)
      chat_id=""
      group_link="$destination"
      ;;
    *)
      chat_id="$destination"
      group_link=""
      ;;
  esac
  plan_slug="$(jq -r '.org_slug' "$path")"
  plan_org="$(jq -r '.org_name' "$path")"
  response="$(curl -sS -X POST "${RELAY_URL}/api/notify/relay" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc \
      --arg chat_id "$chat_id" \
      --arg group_link "$group_link" \
      --arg message "$message" \
      --arg slug "$plan_slug" \
      --arg org_name "$plan_org" \
      '{chat_id:$chat_id,group_link:$group_link,message:$message,slug:$slug,org_name:$org_name}')" \
    --max-time 10)" || return 1
  printf '%s' "$response" | jq -e '.status == "sent"' >/dev/null 2>&1 || {
    printf '%s\n' "$response"
    return 1
  }
  printf '%s\n' "$response"
}

dispatch_plan() {
  local id="$1"
  local approval_token="$2"
  local path status expected_hash actual_hash lock response
  path="$(read_plan "$id")"
  verify_live_plan "$path"
  status="$(jq -r '.status' "$path")"
  [ "$status" = "approved" ] || die "notification plan has not been explicitly approved"
  expected_hash="$(jq -r '.approval_token_hash' "$path")"
  actual_hash="$(printf '%s' "$approval_token" | hash_text)"
  [ "$expected_hash" = "$actual_hash" ] || die "notification approval token is invalid"

  lock="$path.lock"
  mkdir "$lock" 2>/dev/null || die "notification dispatch is already in progress"
  NOTIFY_LOCK="$lock"
  trap '[ -z "${NOTIFY_LOCK:-}" ] || rmdir "$NOTIFY_LOCK" 2>/dev/null || true' EXIT

  # Consume approval before the network call. An uncertain failure requires a
  # new plan rather than risking a duplicate external message.
  mark_plan "$path" "dispatching"
  if [ "$MODE" = "connected" ]; then
    if ! response="$(dispatch_connected "$path")"; then
      mark_plan "$path" "failed" "dispatch failed; prepare and approve a new plan"
      die "notification dispatch failed; no fallback was attempted"
    fi
  else
    if ! response="$(dispatch_local "$path")"; then
      mark_plan "$path" "failed" "dispatch failed; prepare and approve a new plan"
      die "notification dispatch failed; no fallback was attempted"
    fi
  fi

  mark_plan "$path" "sent"
  rmdir "$lock" 2>/dev/null || true
  NOTIFY_LOCK=""
  trap - EXIT
  bash "$SCRIPT_DIR/bin/telemetry.sh" emit "notification" \
    "$(jq -nc --arg kind "$(jq -r '.kind' "$path")" \
      '{type:$kind,status:"sent",consent:"explicit"}')" 2>/dev/null &
  jq -nc \
    --arg id "$id" \
    --argjson result "$response" \
    '{status:"sent",plan_id:$id,result:$result}'
}

show_plan() {
  local path
  path="$(read_plan "$1")"
  jq '{
    status,
    plan_id:.id,
    digest,
    org:.org_name,
    recipient,
    channels,
    deliveries,
    no_fallback,
    message,
    expires_at
  }' "$path"
}

cancel_plan() {
  local path status
  path="$(read_plan "$1")"
  status="$(jq -r '.status' "$path")"
  case "$status" in
    proposed|approved|failed) mark_plan "$path" "cancelled" ;;
    *) die "notification plan cannot be cancelled from status: $status" ;;
  esac
  jq -nc --arg id "$1" '{status:"cancelled",plan_id:$id}'
}

list_pending() {
  local found="false"
  for path in "$STATE_DIR"/*.json; do
    [ -f "$path" ] || continue
    if jq -e '.status == "proposed" or .status == "approved"' "$path" >/dev/null 2>&1; then
      jq -c '{plan_id:.id,status,org:.org_name,recipient,channels,message,expires_at}' "$path"
      found="true"
    fi
  done
  [ "$found" = "true" ] || echo '{"status":"empty"}'
}

test_connection() {
  if [ "$MODE" = "connected" ]; then
    [ -n "$API_URL" ] && [ -n "$API_KEY" ] ||
      die "notification service is not connected"
    curl -sS -X GET "${API_URL}/api/notify/test" \
      -H "Authorization: Bearer $API_KEY" \
      --max-time 10
  elif [ "$MODE" = "local" ]; then
    local group_link
    group_link="$(read_local_telegram_config telegram_group_link)"
    if [ -n "$group_link" ]; then
      echo '{"status":"configured","mode":"local"}'
    else
      echo '{"status":"offline","reason":"no_telegram_group"}'
    fi
  else
    echo '{"status":"offline","reason":"no_api_key"}'
  fi
}

case "${1:-help}" in
  plan)
    case "${2:-}" in
      send)
        [ "$#" -eq 4 ] || die "Usage: notify.sh plan send <recipient> <message>"
        plan_notification "send" "$3" "$4"
        ;;
      group)
        [ "$#" -eq 3 ] || die "Usage: notify.sh plan group <message>"
        plan_notification "group" "" "$3"
        ;;
      *) die "Usage: notify.sh plan send|group ..." ;;
    esac
    ;;
  approve)
    [ "$#" -eq 4 ] || die "Usage: notify.sh approve <plan-id> <digest> APPROVE_EXACT_NOTIFICATION"
    approve_plan "$2" "$3" "$4"
    ;;
  dispatch)
    [ "$#" -eq 3 ] || die "Usage: notify.sh dispatch <plan-id> <approval-token>"
    dispatch_plan "$2" "$3"
    ;;
  show)
    [ "$#" -eq 2 ] || die "Usage: notify.sh show <plan-id>"
    show_plan "$2"
    ;;
  cancel)
    [ "$#" -eq 2 ] || die "Usage: notify.sh cancel <plan-id>"
    cancel_plan "$2"
    ;;
  pending)
    list_pending
    ;;
  send)
    [ "$#" -eq 3 ] || die "Usage: notify.sh send <recipient> <message>"
    plan_notification "send" "$2" "$3"
    echo "Approval required — no notification was sent." >&2
    exit 4
    ;;
  group)
    [ "$#" -eq 2 ] || die "Usage: notify.sh group <message>"
    plan_notification "group" "" "$2"
    echo "Approval required — no notification was sent." >&2
    exit 4
    ;;
  test)
    test_connection
    ;;
  help|*)
    echo "Usage: notify.sh <command>"
    echo ""
    echo "Commands:"
    echo "  plan send <name> <message>  Resolve a DM without sending"
    echo "  plan group <message>        Resolve group channels without sending"
    echo "  approve <id> <digest> APPROVE_EXACT_NOTIFICATION"
    echo "                              Record one exact human approval"
    echo "  dispatch <id> <token>       Consume approval and send stored content"
    echo "  show <id>                   Show exact pending content"
    echo "  cancel <id>                 Cancel a pending plan"
    echo "  pending                     List pending plans"
    echo "  test                        Test configuration without sending"
    ;;
esac
