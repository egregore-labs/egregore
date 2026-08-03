#!/usr/bin/env bash
# Notification dispatch is a separate, exact, one-use human consent action.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

PROJECT="$TMP/project"
STATE="$TMP/state"
FAKE_BIN="$TMP/bin"
LOG="$TMP/curl.log"
mkdir -p "$PROJECT" "$STATE" "$FAKE_BIN"
printf '%s\n' session-notify-test > "$PROJECT/.egregore-session-id"
printf '%s\n' \
  '{"mode":"connected","slug":"acme","org_name":"Acme","api_url":"https://api.example"}' \
  > "$PROJECT/egregore.json"

apply_env() {
  export EGREGORE_NOTIFY_PROJECT_DIR="$PROJECT"
  export EGREGORE_NOTIFY_STATE_DIR="$STATE"
  export EGREGORE_API_URL="https://api.example"
  export EGREGORE_API_KEY="ek_acme_test"
  export MOCK_CURL_LOG="$LOG"
  export PATH="$FAKE_BIN:$ORIGINAL_PATH"
}

ORIGINAL_PATH="$PATH"
apply_env

# shellcheck disable=SC2016 # single quotes intentionally write a fake script
printf '%s\n' '#!/usr/bin/env bash' \
  'url=""' \
  'body="{}"' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    http*) url="$1"; shift ;;' \
  '    -d) body="$2"; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'printf "%s\t%s\n" "$url" "$body" >> "$MOCK_CURL_LOG"' \
  'case "$url" in' \
  '  */api/notify/plan)' \
  '    kind="$(printf "%s" "$body" | jq -r .kind)"' \
  '    if [ "$kind" = "send" ]; then' \
  '      printf "%s\n" '"'"'{"status":"planned","org_slug":"acme","org_name":"Acme","channels":["telegram"],"deliveries":[{"channel":"telegram","destination":"alex","kind":"dm"}],"no_fallback":true,"expires_at":4102444800,"plan_token":"signed-plan"}'"'"'' \
  '    else' \
  '      printf "%s\n" '"'"'{"status":"planned","org_slug":"acme","org_name":"Acme","channels":["telegram","teams"],"deliveries":[{"channel":"telegram","destination":"Acme group","kind":"group"},{"channel":"teams","destination":"General","kind":"group"}],"no_fallback":true,"expires_at":4102444800,"plan_token":"signed-plan"}'"'"'' \
  '    fi' \
  '    ;;' \
  '  */api/notify/send|*/api/notify/group|*/api/notify/relay)' \
  '    printf "%s\n" '"'"'{"status":"sent"}'"'"'' \
  '    ;;' \
  '  *) printf "%s\n" '"'"'{"status":"ok"}'"'"' ;;' \
  'esac' > "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

echo "test-notification-consent"

: > "$LOG"
PLAN="$(bash "$ROOT/bin/notify.sh" plan send alex "Exact security warning")"
PLAN_ID="$(printf '%s' "$PLAN" | jq -r .plan_id)"
DIGEST="$(printf '%s' "$PLAN" | jq -r .digest)"
if [ "$(grep -c '/api/notify/plan' "$LOG")" -eq 1 ] &&
   ! grep -qE '/api/notify/(send|group)' "$LOG"; then
  ok "planning resolves destinations without dispatching"
else
  bad "planning performed an external dispatch"
fi
if [ "$(printf '%s' "$PLAN" | jq -r '.recipient')" = "alex" ] &&
   [ "$(printf '%s' "$PLAN" | jq -r '.channels | join(",")')" = "telegram" ] &&
   [ "$(printf '%s' "$PLAN" | jq -r '.message')" = "Exact security warning" ]; then
  ok "preview includes exact recipient, channels, and message"
else
  bad "preview omitted exact delivery details"
fi

if bash "$ROOT/bin/notify.sh" approve "$PLAN_ID" wrong APPROVE_EXACT_NOTIFICATION \
  >/dev/null 2>&1; then
  bad "approval accepted a digest other than the preview"
else
  ok "approval is bound to the preview digest"
fi
if bash "$ROOT/bin/notify.sh" dispatch "$PLAN_ID" made-up-token >/dev/null 2>&1; then
  bad "dispatch succeeded without approval"
else
  ok "dispatch without approval fails closed"
fi
if grep -qE '/api/notify/(send|group)' "$LOG"; then
  bad "failed approval reached a dispatch endpoint"
else
  ok "failed approval makes no dispatch request"
fi

APPROVAL="$(bash "$ROOT/bin/notify.sh" approve \
  "$PLAN_ID" "$DIGEST" APPROVE_EXACT_NOTIFICATION)"
TOKEN="$(printf '%s' "$APPROVAL" | jq -r .approval_token)"
PLAN_FILE="$STATE/$PLAN_ID.json"
jq '.message = "mutated after approval"' "$PLAN_FILE" > "$PLAN_FILE.tmp"
mv "$PLAN_FILE.tmp" "$PLAN_FILE"
if bash "$ROOT/bin/notify.sh" dispatch "$PLAN_ID" "$TOKEN" >/dev/null 2>&1; then
  bad "dispatch accepted content mutated after approval"
else
  ok "content mutation invalidates approval"
fi
if grep -qE '/api/notify/(send|group)' "$LOG"; then
  bad "mutated content reached a dispatch endpoint"
else
  ok "mutated content is stopped before network dispatch"
fi

PLAN="$(bash "$ROOT/bin/notify.sh" plan group "Approved once")"
PLAN_ID="$(printf '%s' "$PLAN" | jq -r .plan_id)"
DIGEST="$(printf '%s' "$PLAN" | jq -r .digest)"
APPROVAL="$(bash "$ROOT/bin/notify.sh" approve \
  "$PLAN_ID" "$DIGEST" APPROVE_EXACT_NOTIFICATION)"
TOKEN="$(printf '%s' "$APPROVAL" | jq -r .approval_token)"
if bash "$ROOT/bin/notify.sh" dispatch "$PLAN_ID" "$TOKEN" >/dev/null; then
  ok "one exact approved group notification dispatches"
else
  bad "approved notification did not dispatch"
fi
DISPATCHES="$(grep -cE '/api/notify/(send|group)' "$LOG" || true)"
if bash "$ROOT/bin/notify.sh" dispatch "$PLAN_ID" "$TOKEN" >/dev/null 2>&1; then
  bad "approval token was replayable"
else
  ok "approval is single use"
fi
if [ "$(grep -cE '/api/notify/(send|group)' "$LOG" || true)" -eq "$DISPATCHES" ]; then
  ok "replay makes no second dispatch request"
else
  bad "replay reached the dispatch endpoint twice"
fi

: > "$LOG"
if bash "$ROOT/bin/notify.sh" send alex "Legacy call" >/dev/null 2>&1; then
  bad "legacy send reported success"
else
  STATUS=$?
  if [ "$STATUS" -eq 4 ] && ! grep -q '/api/notify/send' "$LOG"; then
    ok "legacy send creates a proposal and cannot dispatch"
  else
    bad "legacy send did not fail closed"
  fi
fi

PLAN="$(bash "$ROOT/bin/notify.sh" plan send alex "Expires")"
PLAN_ID="$(printf '%s' "$PLAN" | jq -r .plan_id)"
PLAN_FILE="$STATE/$PLAN_ID.json"
jq '.expires_at = 1' "$PLAN_FILE" > "$PLAN_FILE.tmp"
mv "$PLAN_FILE.tmp" "$PLAN_FILE"
if bash "$ROOT/bin/notify.sh" approve \
  "$PLAN_ID" "$(printf '%s' "$PLAN" | jq -r .digest)" \
  APPROVE_EXACT_NOTIFICATION >/dev/null 2>&1; then
  bad "expired proposal was approvable"
else
  ok "expired proposals require a new preview"
fi

printf '%s\n' \
  '{"mode":"local","slug":"acme","org_name":"Acme","telegram_chat_id":"local-group"}' \
  > "$PROJECT/egregore.json"
: > "$LOG"
if bash "$ROOT/bin/notify.sh" plan send alex "Private message" >/dev/null 2>&1; then
  bad "local direct message silently fell back to the group"
else
  ok "local direct message has no group fallback"
fi
if [ ! -s "$LOG" ]; then
  ok "failed local DM makes no network request"
else
  bad "failed local DM made a network request"
fi

PLAN="$(bash "$ROOT/bin/notify.sh" plan group "Local approved once")"
if [ ! -s "$LOG" ]; then
  ok "local group planning makes no network request"
else
  bad "local group planning contacted the relay"
fi
PLAN_ID="$(printf '%s' "$PLAN" | jq -r .plan_id)"
DIGEST="$(printf '%s' "$PLAN" | jq -r .digest)"
APPROVAL="$(bash "$ROOT/bin/notify.sh" approve \
  "$PLAN_ID" "$DIGEST" APPROVE_EXACT_NOTIFICATION)"
TOKEN="$(printf '%s' "$APPROVAL" | jq -r .approval_token)"
printf '%s\n' \
  '{"mode":"local","slug":"acme","org_name":"Acme","telegram_chat_id":"changed-after-preview"}' \
  > "$PROJECT/egregore.json"
bash "$ROOT/bin/notify.sh" dispatch "$PLAN_ID" "$TOKEN" >/dev/null
if [ "$(grep -c '/api/notify/relay' "$LOG" || true)" -eq 1 ] &&
   grep '/api/notify/relay' "$LOG" | grep -q '"chat_id":"local-group"' &&
   ! grep '/api/notify/relay' "$LOG" | grep -q 'changed-after-preview'; then
  ok "local relay uses only the destination shown before approval"
else
  bad "local dispatch changed or duplicated the approved destination"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
