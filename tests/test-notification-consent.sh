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
  'argv="$*"' \
  'stdin_headers=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    http*) url="$1"; shift ;;' \
  '    -d) body="$2"; shift 2 ;;' \
  '    -H|--header)' \
  '      if [ "$2" = @- ]; then stdin_headers="$stdin_headers$(cat)"; fi' \
  '      shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'printf "%s\t%s\n" "$url" "$body" >> "$MOCK_CURL_LOG"' \
  '# Argument-vector and stdin evidence for credential-placement assertions.' \
  'if [ -n "${MOCK_CURL_ARGV:-}" ]; then' \
  '  printf "%s\n" "$argv" >> "$MOCK_CURL_ARGV"' \
  'fi' \
  'if [ -n "${MOCK_CURL_STDIN_HEADERS:-}" ] && [ -n "$stdin_headers" ]; then' \
  '  printf "%s\n" "$stdin_headers" >> "$MOCK_CURL_STDIN_HEADERS"' \
  'fi' \
  'case "$url" in' \
  '  */api/auth.test) printf "%s\n" "${MOCK_SLACK_AUTH_RESPONSE:-}" ;;' \
  '  */api/notify/plan)' \
  '    kind="$(printf "%s" "$body" | jq -r .kind)"' \
  '    if [ "$kind" = "send" ]; then' \
  '      printf "%s\n" '"'"'{"status":"planned","org_slug":"acme","org_name":"Acme","channels":["telegram"],"deliveries":[{"channel":"telegram","destination":"alex","kind":"dm"}],"no_fallback":true,"expires_at":4102444800,"plan_token":"signed-plan"}'"'"'' \
  '    else' \
  '      printf "%s\n" '"'"'{"status":"planned","org_slug":"acme","org_name":"Acme","channels":["telegram","teams"],"deliveries":[{"channel":"telegram","destination":"Acme group","kind":"group"},{"channel":"teams","destination":"General","kind":"group"}],"no_fallback":true,"expires_at":4102444800,"plan_token":"signed-plan"}'"'"'' \
  '    fi' \
  '    ;;' \
  '  */api/notify/send|*/api/notify/group|*/api/notify/relay)' \
  '    case "${MOCK_NOTIFY_DISPATCH_RESULT:-sent}" in' \
  '      transport) exit 7 ;;' \
  '      rejected) printf "%s\n" '"'"'{"detail":"notification plan expired"}'"'"' ;;' \
  '      server-error) printf "%s\n" '"'"'{"error":"stubbed"}'"'"' ;;' \
  '      *) printf "%s\n" '"'"'{"status":"sent"}'"'"' ;;' \
  '    esac' \
  '    ;;' \
  '  *) printf "%s\n" '"'"'{"status":"ok"}'"'"' ;;' \
  'esac' > "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

echo "test-notification-consent"

# The shell plan surface accepts a message argument; file-backed planning is
# the Python Runtime CLI. Its existing file reader is dispatch --approval-file.
mkdir -p "$PROJECT/bin/lib" "$PROJECT/tmp"
cp "$ROOT/bin/notify.sh" "$PROJECT/bin/notify.sh"
cp "$ROOT/bin/lib/scratch.sh" "$PROJECT/bin/lib/scratch.sh"
cp -R "$ROOT/egregore_runtime" "$PROJECT/egregore_runtime"
for receipt_kind in scratch document; do
  if [ "$receipt_kind" = scratch ]; then
    input_receipt="$PROJECT/tmp/approval.json"
  else
    input_receipt="$PROJECT/approval.json"
  fi
  plan="$(bash "$PROJECT/bin/notify.sh" plan group "Receipt lifetime: $receipt_kind")"
  plan_id="$(printf '%s' "$plan" | jq -r .plan_id)"
  digest="$(printf '%s' "$plan" | jq -r .digest)"
  bash "$PROJECT/bin/notify.sh" approve "$plan_id" "$digest" \
    APPROVE_EXACT_NOTIFICATION --out "$input_receipt" >/dev/null
  cp "$input_receipt" "$TMP/expected-receipt.json"
  if bash "$PROJECT/bin/notify.sh" dispatch "$plan_id" --approval-file "$input_receipt" \
      > "$TMP/receipt-dispatch.stdout" 2> "$TMP/receipt-dispatch.stderr" &&
     jq -e '.status == "sent"' "$TMP/receipt-dispatch.stdout" >/dev/null; then
    case "$receipt_kind" in
      scratch)
        if [ ! -e "$input_receipt" ]; then
          ok "shell dispatch consumes a validated scratch approval receipt"
        else
          bad "shell dispatch left a scratch approval receipt"
        fi ;;
      document)
        if cmp -s "$input_receipt" "$TMP/expected-receipt.json"; then
          ok "shell dispatch leaves an outside-tmp approval receipt untouched"
        else
          bad "shell dispatch changed an outside-tmp approval receipt"
        fi ;;
    esac
  else
    bad "shell dispatch failed with a $receipt_kind approval receipt"
  fi
done
printf '%s\n' '{invalid json' > "$PROJECT/tmp/invalid-approval.json"
requests_before="$(wc -l < "$LOG" | tr -d ' ')"
if bash "$PROJECT/bin/notify.sh" dispatch unused --approval-file "$PROJECT/tmp/invalid-approval.json" \
    > "$TMP/invalid-scratch.stdout" 2> "$TMP/invalid-scratch.stderr"; then
  bad "shell dispatch accepted invalid scratch approval JSON"
elif [ ! -e "$PROJECT/tmp/invalid-approval.json" ] &&
     [ "$(wc -l < "$LOG" | tr -d ' ')" -eq "$requests_before" ] &&
     [ "$(cat "$TMP/invalid-scratch.stderr")" = 'notify: approval file unreadable or has no approval_token' ]; then
  ok "shell dispatch consumes scratch approval bytes even when token validation fails"
else
  bad "shell dispatch left invalid scratch approval bytes or made a request"
fi

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

# Approval credentials can stay in private adapter-owned files throughout dispatch.
APPROVAL_DIR="$TMP/approvals"
mkdir -p "$APPROVAL_DIR"
APPROVAL_FILE="$APPROVAL_DIR/receipt.json"
printf '%s\n' 'stale receipt' > "$APPROVAL_FILE"
chmod 644 "$APPROVAL_FILE"
PLAN="$(bash "$ROOT/bin/notify.sh" plan group "Approved from a private file")"
PLAN_ID="$(printf '%s' "$PLAN" | jq -r .plan_id)"
DIGEST="$(printf '%s' "$PLAN" | jq -r .digest)"
if APPROVAL="$(bash "$ROOT/bin/notify.sh" approve \
  "$PLAN_ID" "$DIGEST" APPROVE_EXACT_NOTIFICATION --out "$APPROVAL_FILE")"; then
  ok "approve --out writes an approval receipt"
else
  bad "approve --out failed"
fi
case "$(uname -s)" in
  Darwin) APPROVAL_MODE="$(stat -f %Lp "$APPROVAL_FILE" 2>/dev/null)" ;;
  *) APPROVAL_MODE="$(stat -c %a "$APPROVAL_FILE" 2>/dev/null)" ;;
esac
if [ "$APPROVAL_MODE" = 600 ]; then
  ok "approval receipt replaces a public file with private mode 0600"
else
  bad "approval receipt mode is not 0600"
fi
if printf '%s' "$APPROVAL" | jq -e --arg plan_id "$PLAN_ID" \
  '.status == "approved" and .plan_id == $plan_id and (has("approval_token") | not)' \
  >/dev/null && ! grep -q approval_token <<< "$APPROVAL"; then
  ok "approve --out stdout contains only the approved status and plan identity"
else
  bad "approve --out exposed approval_token or omitted the public receipt"
fi
if jq -e --arg plan_id "$PLAN_ID" \
  '.status == "approved" and .plan_id == $plan_id and (.approval_token | type == "string" and length > 0)' \
  "$APPROVAL_FILE" >/dev/null 2>&1; then
  ok "private approval receipt contains the token"
else
  bad "private approval receipt is missing its token"
fi

cp "$APPROVAL_FILE" "$TMP/approval-before.json"
REQUESTS="$(wc -l < "$LOG" | tr -d ' ')"
if bash "$ROOT/bin/notify.sh" dispatch deadbeef --approval-file "$APPROVAL_FILE" \
  >/dev/null 2>&1; then
  bad "unknown plan accepted an approval receipt"
elif cmp -s "$APPROVAL_FILE" "$TMP/approval-before.json" &&
     [ "$(wc -l < "$LOG" | tr -d ' ')" -eq "$REQUESTS" ]; then
  ok "unknown plan preserves an unrelated approval receipt without a request"
else
  bad "unknown plan changed an unrelated approval receipt or made a request"
fi

mkdir "$STATE/$PLAN_ID.json.lock"
if bash "$ROOT/bin/notify.sh" dispatch "$PLAN_ID" --approval-file "$APPROVAL_FILE" \
  >/dev/null 2>&1; then
  bad "locked plan accepted another dispatch"
elif cmp -s "$APPROVAL_FILE" "$TMP/approval-before.json" &&
     [ "$(wc -l < "$LOG" | tr -d ' ')" -eq "$REQUESTS" ]; then
  ok "dispatch lock failure preserves the approval receipt without a request"
else
  bad "dispatch lock failure changed the approval receipt or made a request"
fi
rmdir "$STATE/$PLAN_ID.json.lock"

assert_invalid_approval_file() {
  local label="$1" file="$2" status before_requests expected_error
  expected_error='notify: approval file unreadable or has no approval_token'
  before_requests="$(wc -l < "$LOG" | tr -d ' ')"
  bash "$ROOT/bin/notify.sh" dispatch "$PLAN_ID" --approval-file "$file" \
    > "$TMP/invalid-approval.stdout" 2> "$TMP/invalid-approval.stderr"
  status=$?
  if [ "$status" -eq 1 ] &&
     [ "$(cat "$TMP/invalid-approval.stderr")" = "$expected_error" ] &&
     [ ! -s "$TMP/invalid-approval.stdout" ] &&
     [ "$(wc -l < "$LOG" | tr -d ' ')" -eq "$before_requests" ]; then
    ok "$label approval file fails closed with no request"
  else
    bad "$label approval file did not fail closed before dispatch"
  fi
}

assert_invalid_approval_file "missing" "$APPROVAL_DIR/missing.json"
cp "$APPROVAL_FILE" "$APPROVAL_DIR/unreadable.json"
chmod 000 "$APPROVAL_DIR/unreadable.json"
assert_invalid_approval_file "unreadable" "$APPROVAL_DIR/unreadable.json"
chmod 600 "$APPROVAL_DIR/unreadable.json"
printf '%s\n' '{"status":"approved"}' > "$APPROVAL_DIR/no-token.json"
assert_invalid_approval_file "fieldless" "$APPROVAL_DIR/no-token.json"
printf '%s\n' '{invalid json' > "$APPROVAL_DIR/malformed.json"
assert_invalid_approval_file "malformed" "$APPROVAL_DIR/malformed.json"
printf '%s\n' '{"approval_token":""}' > "$APPROVAL_DIR/empty-token.json"
assert_invalid_approval_file "empty-token" "$APPROVAL_DIR/empty-token.json"
printf '%s\n' '{"approval_token":null}' > "$APPROVAL_DIR/null-token.json"
assert_invalid_approval_file "null-token" "$APPROVAL_DIR/null-token.json"

DISPATCHES="$(grep -cE '/api/notify/(send|group)' "$LOG" || true)"
if bash "$ROOT/bin/notify.sh" dispatch "$PLAN_ID" --approval-file "$APPROVAL_FILE" \
  > "$TMP/file-dispatch.stdout" &&
   jq -e '.status == "sent"' "$TMP/file-dispatch.stdout" >/dev/null &&
   [ "$(grep -cE '/api/notify/(send|group)' "$LOG" || true)" -eq "$((DISPATCHES + 1))" ]; then
  ok "dispatch --approval-file delivers the approved notification exactly once"
else
  bad "dispatch --approval-file did not deliver exactly once"
fi
if cmp -s "$APPROVAL_FILE" "$TMP/approval-before.json"; then
  ok "successful dispatch preserves the completed approval receipt"
else
  bad "successful dispatch changed the completed approval receipt"
fi
if bash "$ROOT/bin/notify.sh" dispatch "$PLAN_ID" --approval-file "$APPROVAL_FILE" \
  >/dev/null 2>&1; then
  bad "file-based approval token was replayable"
elif [ "$(grep -cE '/api/notify/(send|group)' "$LOG" || true)" -eq "$((DISPATCHES + 1))" ]; then
  ok "file-based approval replay makes no second dispatch request"
else
  bad "file-based approval replay made another dispatch request"
fi

for DISPATCH_RESULT in transport server-error rejected; do
  PLAN="$(bash "$ROOT/bin/notify.sh" plan group "Dispatch receipt: $DISPATCH_RESULT")"
  PLAN_ID="$(printf '%s' "$PLAN" | jq -r .plan_id)"
  DIGEST="$(printf '%s' "$PLAN" | jq -r .digest)"
  RECEIPT="$APPROVAL_DIR/$DISPATCH_RESULT.json"
  bash "$ROOT/bin/notify.sh" approve "$PLAN_ID" "$DIGEST" \
    APPROVE_EXACT_NOTIFICATION --out "$RECEIPT" >/dev/null
  cp "$RECEIPT" "$TMP/approval-before.json"
  REQUESTS="$(wc -l < "$LOG" | tr -d ' ')"
  if MOCK_NOTIFY_DISPATCH_RESULT="$DISPATCH_RESULT" \
    bash "$ROOT/bin/notify.sh" dispatch "$PLAN_ID" --approval-file "$RECEIPT" \
    > "$TMP/rejected-dispatch.stdout" 2> "$TMP/rejected-dispatch.stderr"; then
    bad "$DISPATCH_RESULT dispatch unexpectedly succeeded"
  elif [ "$(wc -l < "$LOG" | tr -d ' ')" -ne "$((REQUESTS + 1))" ] ||
       [ -s "$TMP/rejected-dispatch.stdout" ]; then
    bad "$DISPATCH_RESULT dispatch did not fail privately after one request"
  elif [ "$DISPATCH_RESULT" = rejected ]; then
    # The API returns this detail with HTTP 409 after checking the plan token.
    if [ ! -e "$RECEIPT" ]; then
      ok "explicit API plan-token rejection removes the matching approval receipt"
    else
      bad "explicit API plan-token rejection left the matching approval receipt"
    fi
  elif cmp -s "$RECEIPT" "$TMP/approval-before.json"; then
    ok "$DISPATCH_RESULT failure preserves the completed approval receipt"
  else
    bad "$DISPATCH_RESULT failure changed the completed approval receipt"
  fi
done

PLAN="$(bash "$ROOT/bin/notify.sh" plan group "Failed receipt creation")"
PLAN_ID="$(printf '%s' "$PLAN" | jq -r .plan_id)"
DIGEST="$(printf '%s' "$PLAN" | jq -r .digest)"
FAILED_RECEIPT="$APPROVAL_DIR/rejected.json"
printf '%s\n' 'stale receipt' > "$FAILED_RECEIPT"
if bash "$ROOT/bin/notify.sh" approve "$PLAN_ID" wrong \
  APPROVE_EXACT_NOTIFICATION --out "$FAILED_RECEIPT" \
  > "$TMP/failed-approval.stdout" 2>/dev/null; then
  bad "approve --out accepted an invalid digest"
elif [ ! -e "$FAILED_RECEIPT" ] && [ ! -s "$TMP/failed-approval.stdout" ]; then
  ok "failed approval removes a stale receipt and leaves no stdout token"
else
  bad "failed approval left a receipt or stdout content"
fi
if bash "$ROOT/bin/notify.sh" approve "$PLAN_ID" "$DIGEST" \
  APPROVE_EXACT_NOTIFICATION --out "$TMP/absent-directory/receipt.json" \
  > "$TMP/failed-approval.stdout" 2>/dev/null; then
  bad "approve --out created a missing destination directory"
elif [ ! -e "$TMP/absent-directory" ] && [ ! -s "$TMP/failed-approval.stdout" ]; then
  ok "approval output requires an existing directory and leaves no file on failure"
else
  bad "failed receipt creation left an output path or stdout content"
fi

RENAME_BIN="$TMP/rename-bin"
RENAME_DIR="$TMP/rename-output"
mkdir -p "$RENAME_BIN" "$RENAME_DIR"
REAL_MV="$(command -v mv)"
# shellcheck disable=SC2016 # single quotes intentionally write a fake script
printf '%s\n' '#!/usr/bin/env bash' \
  'for source in "$@"; do' \
  '  case "$source" in' \
  '    */.notify-approval.*)' \
  '      : > "$MOCK_RENAME_ATTEMPT"' \
  '      exit 1 ;;' \
  '  esac' \
  'done' \
  'exec "$MOCK_REAL_MV" "$@"' > "$RENAME_BIN/mv"
chmod +x "$RENAME_BIN/mv"
REQUESTS="$(wc -l < "$LOG" | tr -d ' ')"
if PATH="$RENAME_BIN:$PATH" MOCK_REAL_MV="$REAL_MV" \
  MOCK_RENAME_ATTEMPT="$TMP/rename-attempted" \
  bash "$ROOT/bin/notify.sh" approve "$PLAN_ID" "$DIGEST" \
  APPROVE_EXACT_NOTIFICATION --out "$RENAME_DIR/receipt.json" \
  > "$TMP/failed-approval.stdout" 2>/dev/null; then
  bad "approval succeeded despite failed atomic publication"
else
  STATUS=$?
  if [ "$STATUS" -eq 1 ] && [ -e "$TMP/rename-attempted" ] &&
     [ -z "$(find "$RENAME_DIR" -mindepth 1 -print -quit)" ] &&
     [ ! -s "$TMP/failed-approval.stdout" ] &&
     [ "$(wc -l < "$LOG" | tr -d ' ')" -eq "$REQUESTS" ]; then
    ok "failed atomic publication leaves no receipt, staging file, stdout, or request"
  else
    bad "failed atomic publication left output or made a request"
  fi
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
   grep '/api/notify/relay' "$LOG" | grep >/dev/null '"chat_id":"local-group"' &&
   ! grep '/api/notify/relay' "$LOG" | grep >/dev/null 'changed-after-preview'; then
  ok "local relay uses only the destination shown before approval"
else
  bad "local dispatch changed or duplicated the approved destination"
fi

# The Slack credential probe proves a stored token without sending anything.
# The token is never an argument the caller types: the script reads it from
# .env and hands curl the bearer header on stdin.
ARGV_LOG="$TMP/curl-argv.log"
STDIN_HEADERS="$TMP/curl-stdin-headers.log"
export MOCK_CURL_ARGV="$ARGV_LOG"
export MOCK_CURL_STDIN_HEADERS="$STDIN_HEADERS"
unset SLACK_BOT_TOKEN
SLACK_TOKEN_FIXTURE='xoxb-fixture-never-typed'

printf '%s\n' 'EGREGORE_API_URL=https://api.example' > "$PROJECT/.env"
: > "$ARGV_LOG"
STATUS=0
bash "$ROOT/bin/notify.sh" slack-auth-test \
  > "$TMP/slack.stdout" 2> "$TMP/slack.stderr" || STATUS=$?
if [ "$STATUS" -eq 2 ] && [ ! -s "$TMP/slack.stdout" ] && [ ! -s "$ARGV_LOG" ]; then
  ok "slack-auth-test exits 2 without a request when .env has no SLACK_BOT_TOKEN"
else
  bad "slack-auth-test did not fail closed on a missing token"
fi

printf 'SLACK_BOT_TOKEN=%s\n' "$SLACK_TOKEN_FIXTURE" >> "$PROJECT/.env"
: > "$ARGV_LOG"
: > "$STDIN_HEADERS"
export MOCK_SLACK_AUTH_RESPONSE='{"ok":true,"team":"Fixture Workspace","url":"https://fixture.slack.com/","user":"egregore","bot_id":"B1"}'
STATUS=0
bash "$ROOT/bin/notify.sh" slack-auth-test \
  > "$TMP/slack.stdout" 2> "$TMP/slack.stderr" || STATUS=$?
if [ "$STATUS" -eq 0 ] && jq -e \
  '.ok == true and .team == "Fixture Workspace" and .user == "egregore"
   and (has("url") | not) and (has("bot_id") | not)' \
  "$TMP/slack.stdout" >/dev/null 2>&1; then
  ok "slack-auth-test publishes only ok, team, and user from a verified token"
else
  bad "slack-auth-test did not publish the verified workspace identity alone"
fi
if ! grep -qF "$SLACK_TOKEN_FIXTURE" "$TMP/slack.stdout" "$TMP/slack.stderr"; then
  ok "verified slack-auth-test output never contains the bot token"
else
  bad "slack-auth-test leaked the bot token to its output"
fi
if [ "$(awk 'NR == 1 { print $1 }' "$ARGV_LOG")" = "-q" ] &&
   ! grep -qiF 'authorization' "$ARGV_LOG" &&
   ! grep -qF "$SLACK_TOKEN_FIXTURE" "$ARGV_LOG" &&
   grep -qF "Authorization: Bearer $SLACK_TOKEN_FIXTURE" "$STDIN_HEADERS"; then
  ok "slack-auth-test puts -q first and passes the bearer header on curl's stdin"
else
  bad "slack-auth-test placed the bot token or its header in curl's argument vector"
fi

export MOCK_SLACK_AUTH_RESPONSE='{"ok":false,"error":"invalid_auth"}'
STATUS=0
bash "$ROOT/bin/notify.sh" slack-auth-test \
  > "$TMP/slack.stdout" 2> "$TMP/slack.stderr" || STATUS=$?
if [ "$STATUS" -eq 1 ] && [ ! -s "$TMP/slack.stdout" ] &&
   grep -qF 'invalid_auth' "$TMP/slack.stderr" &&
   ! grep -qF "$SLACK_TOKEN_FIXTURE" "$TMP/slack.stderr"; then
  ok "slack-auth-test exits 1 naming invalid_auth and prints no raw response"
else
  bad "slack-auth-test did not report a rejected token as a named failure"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
