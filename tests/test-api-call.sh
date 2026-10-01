#!/usr/bin/env bash
# Test HTTP plumbing in an isolated checkout: curl and gh can never reach the
# network, and no test reads credentials from the developer's checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
CHECKOUT="$TEST_TMP/checkout"
RECORD="$TEST_TMP/record"
PASS=0
FAIL=0
RUNS=0
SAFETY_FAILURES=0
mkdir -p "$CHECKOUT/bin/lib" "$TEST_TMP/stubs" "$TEST_TMP/elsewhere" "$RECORD"
cp "$ROOT/bin/api-call.sh" "$ROOT/bin/config-get.sh" "$CHECKOUT/bin/"
cp "$ROOT/bin/lib/config.sh" "$CHECKOUT/bin/lib/config.sh"
cp "$ROOT/bin/lib/scratch.sh" "$CHECKOUT/bin/lib/scratch.sh"
cp -R "$ROOT/egregore_runtime" "$CHECKOUT/egregore_runtime"

cat > "$TEST_TMP/stubs/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$STUB_RECORD/argv"
printf '%s\0' "$@" > "$STUB_RECORD/argv0"
cat > "$STUB_RECORD/stdin"
printf '%s' "${GIT_DIR-}${GIT_WORK_TREE-}${GIT_INDEX_FILE-}${GIT_OBJECT_DIRECTORY-}${GIT_ALTERNATE_OBJECT_DIRECTORIES-}${GIT_COMMON_DIR-}" > "$STUB_RECORD/git-overrides"
[ "${1-}" = -q ] || { printf 'curl stub: -q must be first\n' >&2; exit 90; }
shift
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -sS) shift ;;
    --request|--url|--max-time|--write-out|-H)
      printf '%s' "$2" > "$STUB_RECORD/${1#-}"
      shift 2
      ;;
    --output) output="$2"; printf '%s' "$output" > "$STUB_RECORD/response-file"; shift 2 ;;
    --data-binary)
      printf '%s' "$2" > "$STUB_RECORD/body-argument"
      cat "${2#@}" > "$STUB_RECORD/body"
      shift 2
      ;;
    *) printf 'curl stub: unexpected argument\n' >&2; exit 90 ;;
  esac
done
[ -n "$output" ] || exit 91
if ! stat -c '%a' "$output" > "$STUB_RECORD/response-mode" 2>/dev/null; then
  stat -f '%Lp' "$output" > "$STUB_RECORD/response-mode"
fi
cat "$STUB_RESPONSE" > "$output"
if [ -n "$STUB_SIGNAL" ]; then
  kill -"$STUB_SIGNAL" "$(cat "$STUB_RECORD/helper-pid")"
fi
if [ "$STUB_TRANSPORT_CODE" -ne 0 ]; then
  printf 'curl: (7) fixture connection failed\n' >&2
  exit "$STUB_TRANSPORT_CODE"
fi
printf '%s' "$STUB_HTTP_STATUS"
STUB

cat > "$TEST_TMP/stubs/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$STUB_RECORD/gh-argv"
printf '%s\0' "$@" > "$STUB_RECORD/gh-argv0"
if [ "$#" -ne 2 ] || [ "$1" != auth ] || [ "$2" != token ]; then
  printf 'gh stub: unexpected command\n' >&2
  exit 90
fi
if [ "$STUB_GH_EXIT" -ne 0 ]; then
  printf 'gh: fixture authentication unavailable\n' >&2
  exit "$STUB_GH_EXIT"
fi
printf '%s\n' "$STUB_GH_TOKEN"
STUB
chmod +x "$TEST_TMP/stubs/curl" "$TEST_TMP/stubs/gh"

export STUB_RECORD="$RECORD" STUB_RESPONSE="$TEST_TMP/response"
export STUB_HTTP_STATUS=200 STUB_TRANSPORT_CODE=0 STUB_GH_EXIT=0
export STUB_GH_TOKEN=fixture-gh-fallback-secret
export STUB_SIGNAL='' TRACE_MODE=plain
printf '%s\n' fixture-github-secret fixture-egregore-secret fixture-resend-secret \
  fixture-gh-fallback-secret environment-github-secret environment-egregore-secret \
  environment-resend-secret 'fixture github interior secret' \
  'fixture egregore interior secret' > "$TEST_TMP/secrets"
printf '%s' '{"ok":true}' > "$STUB_RESPONSE"

ok() { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
fixture_config() { printf '%s\n' "$1" > "$CHECKOUT/egregore.json"; }
fixture_env() {
  printf '%s\n' 'GITHUB_TOKEN=fixture-github-secret' \
    'EGREGORE_API_KEY=fixture-egregore-secret' \
    'RESEND_API_KEY=fixture-resend-secret' > "$CHECKOUT/.env"
}
equal_file() {
  printf '%s' "$2" > "$TEST_TMP/expected"
  cmp -s "$1" "$TEST_TMP/expected"
}
assert_file() {
  if equal_file "$2" "$3"; then ok "$1"; else bad "$1"; fi
}
assert_absent() {
  if [ ! -e "$2" ]; then ok "$1"; else bad "$1"; fi
}
assert_private() {
  local mode
  mode=$(stat -c '%a' "$2" 2>/dev/null || stat -f '%Lp' "$2")
  if [ "$mode" = 600 ]; then ok "$1"; else bad "$1 (mode $mode)"; fi
}
vector_matches() {
  local recorded="$1" method="$2" url="$3" body="${4-}" response_file
  response_file=$(cat "$RECORD/response-file")
  printf '%s\0' -q -sS --max-time 60 --request "$method" --url "$url" \
    --output "$response_file" --write-out '%{http_code}' -H '@-' > "$TEST_TMP/expected-argv0"
  if [ -n "$body" ]; then
    printf '%s\0' --data-binary "@$body" >> "$TEST_TMP/expected-argv0"
  fi
  cmp -s "$recorded" "$TEST_TMP/expected-argv0"
}
assert_vector() {
  local description="$1"
  shift
  if vector_matches "$RECORD/argv0" "$@"; then ok "$description"; else bad "$description"; fi
}

run_call() {
  RUNS=$((RUNS + 1))
  rm -f "$RECORD/"*
  STATUS=0
  (
    cd "$TEST_TMP/elsewhere" || exit 1
    PATH="$TEST_TMP/stubs:$PATH" CONFIG='' ENV_FILE='' \
      GITHUB_TOKEN=environment-github-secret EGREGORE_API_KEY=environment-egregore-secret \
      RESEND_API_KEY=environment-resend-secret \
      GIT_DIR="$TEST_TMP/not-a-repo" GIT_WORK_TREE="$TEST_TMP/elsewhere" \
      GIT_INDEX_FILE="$TEST_TMP/not-an-index" GIT_OBJECT_DIRECTORY="$TEST_TMP/not-objects" \
      GIT_ALTERNATE_OBJECT_DIRECTORIES="$TEST_TMP/not-alternates" \
      GIT_COMMON_DIR="$TEST_TMP/not-common" \
      bash -c '
        printf "%s" "$$" > "$STUB_RECORD/helper-pid"
        case "$TRACE_MODE" in
          argument) exec bash -x "$@" ;;
          inherited) exec env SHELLOPTS=xtrace bash "$@" ;;
          *) exec bash "$@" ;;
        esac
      ' api-call "$CHECKOUT/bin/api-call.sh" "$@"
  ) > "$TEST_TMP/stdout" 2> "$TEST_TMP/stderr" || STATUS=$?

  # Keep this invariant on every success and failure, including usage errors.
  if grep -aFq -f "$TEST_TMP/secrets" "$TEST_TMP/stdout" "$TEST_TMP/stderr" \
      "$RECORD/argv0" "$RECORD/gh-argv0" 2>/dev/null; then
    bad "call $RUNS leaked a credential into output or an argument vector"
    SAFETY_FAILURES=$((SAFETY_FAILURES + 1))
  fi
  if [ -f "$RECORD/argv" ]; then
    if ! equal_file "$RECORD/-max-time" 60 \
       || ! equal_file "$RECORD/-write-out" '%{http_code}' \
       || ! equal_file "$RECORD/H" '@-' \
       || ! equal_file "$RECORD/response-mode" $'600\n' \
       || [ -s "$RECORD/git-overrides" ] \
       || grep -Eq '^(-L|--location|--location-trusted|--retry|--retry-.*)$' "$RECORD/argv"; then
      bad "call $RUNS violated transport, stdin-header, or Git-isolation policy"
      SAFETY_FAILURES=$((SAFETY_FAILURES + 1))
    fi
    if [ -f "$RECORD/response-file" ] && [ -e "$(cat "$RECORD/response-file")" ]; then
      bad "call $RUNS left its staged response file behind"
      SAFETY_FAILURES=$((SAFETY_FAILURES + 1))
    fi
  fi
  if [ -d "$CHECKOUT/tmp" ] && [ -n "$(find "$CHECKOUT/tmp" -type f -print)" ]; then
    bad "call $RUNS left a temporary response file behind"
    SAFETY_FAILURES=$((SAFETY_FAILURES + 1))
  fi
}

expect_result() {
  local description="$1" expected_status="$2" expected_stdout="$3" expected_stderr="$4"
  if [ "$STATUS" -eq "$expected_status" ] \
      && equal_file "$TEST_TMP/stdout" "$expected_stdout" \
      && equal_file "$TEST_TMP/stderr" "$expected_stderr"; then
    ok "$description"
  else
    bad "$description (status $STATUS, expected $expected_status; output differs)"
  fi
}
reject() {
  local description="$1" expected_status="$2" expected_error="$3"
  shift 3
  run_call "$@"
  expect_result "$description" "$expected_status" '' "$expected_error"$'\n'
  assert_absent "$description does not invoke curl" "$RECORD/argv"
}

printf 'test-api-call\n'
fixture_config '{"api_url":"https://api.example.test/root/"}'
fixture_env
for auth in github egregore resend; do
  run_call GET '/api/admin/org/example?detail=full&limit=2' --auth "$auth"
  expect_result "$auth reads fixture .env despite inherited credentials and foreign cwd" 0 '{"ok":true}' ''
  assert_file "$auth sends its fixture key only through stdin" "$RECORD/stdin" \
    "Authorization: Bearer fixture-$auth-secret"$'\n'
  assert_file "$auth joins base/path once and preserves query" "$RECORD/-url" \
    'https://api.example.test/root/api/admin/org/example?detail=full&limit=2'
  assert_absent "$auth fixture key avoids gh fallback" "$RECORD/gh-argv"
done
assert_vector 'GET sends exactly the expected complete argument vector' GET \
  'https://api.example.test/root/api/admin/org/example?detail=full&limit=2'
cp "$RECORD/argv0" "$RECORD/mutated-argv0"
printf '%s\0' --url 'https://unexpected.example.test/' >> "$RECORD/mutated-argv0"
if vector_matches "$RECORD/mutated-argv0" GET \
    'https://api.example.test/root/api/admin/org/example?detail=full&limit=2'; then
  bad 'complete vector assertion accepts a repeated --url mutation'
else
  ok 'complete vector assertion rejects a repeated --url mutation'
fi
[ -d "$CHECKOUT/tmp" ] && ok 'missing tmp directory is created' || bad 'missing tmp directory is created'

fixture_config '{"api_url":"https://api.example.test"}'
run_call DELETE '/api/org/example/members/alice?mode=full' --auth github
expect_result 'bodyless DELETE returns response' 0 '{"ok":true}' ''
assert_file 'bodyless DELETE preserves JSON content type' "$RECORD/stdin" \
  $'Authorization: Bearer fixture-github-secret\nContent-Type: application/json\n'
assert_file 'DELETE method is forwarded' "$RECORD/-request" DELETE
assert_file 'base without trailing slash joins correctly' "$RECORD/-url" \
  'https://api.example.test/api/org/example/members/alice?mode=full'
assert_vector 'DELETE sends exactly the expected complete argument vector' DELETE \
  'https://api.example.test/api/org/example/members/alice?mode=full'

fixture_config '{}'
run_call GET 'https://external.example.test/path?x=1'
expect_result 'full HTTPS URL needs neither api_url nor auth' 0 '{"ok":true}' ''
assert_file 'full HTTPS URL is preserved' "$RECORD/-url" 'https://external.example.test/path?x=1'
assert_file 'no auth sends no headers' "$RECORD/stdin" ''
rm "$CHECKOUT/egregore.json" "$CHECKOUT/.env"
run_call GET 'https://external.example.test/path'
expect_result 'full HTTPS URL without auth works with config and .env absent' 0 '{"ok":true}' ''
assert_file 'missing .env does not add an authorization header' "$RECORD/stdin" ''
fixture_env

printf '%s' '{not valid JSON}\n' > "$TEST_TMP/elsewhere/request.json"
run_call POST 'https://external.example.test/body' --auth egregore --json-file request.json
expect_result 'body file is forwarded without JSON validation' 0 '{"ok":true}' ''
assert_file 'outside-tmp request remains untouched after use' "$TEST_TMP/elsewhere/request.json" '{not valid JSON}\n'
assert_file 'POST method is forwarded' "$RECORD/-request" POST
assert_file 'body bytes are passed verbatim' "$RECORD/body" '{not valid JSON}\n'
assert_file 'body is passed by filename' "$RECORD/body-argument" '@request.json'
assert_file 'body request has JSON content type and auth' "$RECORD/stdin" \
  $'Authorization: Bearer fixture-egregore-secret\nContent-Type: application/json\n'
assert_vector 'POST sends exactly the expected complete argument vector including body' POST \
  'https://external.example.test/body' request.json

for scratch_outcome in success http-failure transport-failure; do
  printf '%s' '{"scratch":"request"}' > "$CHECKOUT/tmp/request.json"
  case "$scratch_outcome" in
    success) STUB_HTTP_STATUS=200; STUB_TRANSPORT_CODE=0 ;;
    http-failure) STUB_HTTP_STATUS=500; STUB_TRANSPORT_CODE=0 ;;
    transport-failure) STUB_HTTP_STATUS=200; STUB_TRANSPORT_CODE=7 ;;
  esac
  run_call POST 'https://external.example.test/scratch' --json-file "$CHECKOUT/tmp/request.json"
  assert_file "$scratch_outcome reads scratch request before consuming it" "$RECORD/body" '{"scratch":"request"}'
  assert_absent "$scratch_outcome consumes the scratch request" "$CHECKOUT/tmp/request.json"
  case "$scratch_outcome" in
    success) expect_result 'scratch request succeeds without a cleanup diagnostic' 0 '{"ok":true}' '' ;;
    http-failure) expect_result 'consumption preserves HTTP failure' 1 '' $'api-call: HTTP 500 POST https://external.example.test/scratch\n' ;;
    transport-failure) expect_result 'consumption preserves transport failure' 1 '' $'curl: (7) fixture connection failed\n' ;;
  esac
done
STUB_HTTP_STATUS=200
STUB_TRANSPORT_CODE=0

printf 'first line\nsecond line\n\n' > "$STUB_RESPONSE"
run_call GET 'https://external.example.test/body' --out saved.json
expect_result '--out writes no stdout' 0 '' ''
assert_file '--out preserves response bytes at caller-relative path' "$TEST_TMP/elsewhere/saved.json" \
  $'first line\nsecond line\n\n'
assert_private '--out creates a private response' "$TEST_TMP/elsewhere/saved.json"
chmod 644 "$TEST_TMP/elsewhere/saved.json"
run_call GET 'https://external.example.test/body' --out saved.json
expect_result '--out replaces an existing response successfully' 0 '' ''
assert_file '--out replacement preserves bytes' "$TEST_TMP/elsewhere/saved.json" \
  $'first line\nsecond line\n\n'
assert_private '--out replaces existing 0644 file with private response' "$TEST_TMP/elsewhere/saved.json"
run_call GET 'https://external.example.test/body'
expect_result 'stdout preserves response whitespace' 0 $'first line\nsecond line\n\n' ''
for STUB_HTTP_STATUS in 200 201 204 299; do
  printf '%s' "body-$STUB_HTTP_STATUS" > "$STUB_RESPONSE"
  run_call GET 'https://external.example.test/status'
  expect_result "HTTP $STUB_HTTP_STATUS succeeds" 0 "body-$STUB_HTTP_STATUS" ''
done
STUB_HTTP_STATUS=204
: > "$STUB_RESPONSE"
run_call GET 'https://external.example.test/empty' --out empty.json
expect_result 'empty successful response has no stdout' 0 '' ''
assert_file 'empty successful response still creates --out' "$TEST_TMP/elsewhere/empty.json" ''
assert_private 'empty successful response remains private' "$TEST_TMP/elsewhere/empty.json"

for STUB_HTTP_STATUS in 302 404 500; do
  printf '%s' 'server error must stay private' > "$STUB_RESPONSE"
  run_call GET 'https://external.example.test/status?private=query'
  expect_result "HTTP $STUB_HTTP_STATUS suppresses body and query" 1 '' \
    "api-call: HTTP $STUB_HTTP_STATUS GET https://external.example.test/status"$'\n'
  printf '%s' untouched > "$TEST_TMP/elsewhere/saved.json"
  run_call GET 'https://external.example.test/status?private=query' --out saved.json
  expect_result "HTTP $STUB_HTTP_STATUS with --out suppresses stdout" 1 '' \
    "api-call: HTTP $STUB_HTTP_STATUS GET https://external.example.test/status"$'\n'
  assert_absent "HTTP $STUB_HTTP_STATUS removes existing output" "$TEST_TMP/elsewhere/saved.json"
  run_call GET 'https://external.example.test/status?private=query' --out saved.json
  assert_absent "HTTP $STUB_HTTP_STATUS leaves absent output unwritten" "$TEST_TMP/elsewhere/saved.json"
done

STUB_HTTP_STATUS=400
printf '%s' '{"detail":"fixture-github-secret"}' > "$STUB_RESPONSE"
printf '%s' stale > "$TEST_TMP/elsewhere/error.json"
chmod 644 "$TEST_TMP/elsewhere/error.json"
printf '%s' stale > "$TEST_TMP/elsewhere/saved.json"
run_call POST 'https://external.example.test/member?private=query' --out saved.json --error-out error.json
expect_result '--error-out preserves failure status and suppresses reflected secrets' 1 '' \
  $'api-call: HTTP 400 POST https://external.example.test/member\n'
assert_file '--error-out retains the exact HTTP error body privately' "$TEST_TMP/elsewhere/error.json" \
  '{"detail":"fixture-github-secret"}'
assert_private '--error-out replaces an existing 0644 file with a private response' "$TEST_TMP/elsewhere/error.json"
assert_absent '--error-out preserves failed --out cleanup' "$TEST_TMP/elsewhere/saved.json"
rm "$TEST_TMP/elsewhere/error.json"
run_call POST 'https://external.example.test/member' --error-out error.json
assert_file '--error-out creates an absent error file' "$TEST_TMP/elsewhere/error.json" \
  '{"detail":"fixture-github-secret"}'
assert_private '--error-out creates an absent file privately' "$TEST_TMP/elsewhere/error.json"

STUB_HTTP_STATUS=200
printf '%s' '{"ok":true}' > "$STUB_RESPONSE"
run_call GET 'https://external.example.test/member' --error-out error.json
expect_result '--error-out does not change successful stdout' 0 '{"ok":true}' ''
assert_absent 'successful response clears stale --error-out' "$TEST_TMP/elsewhere/error.json"
STUB_TRANSPORT_CODE=7
printf '%s' stale > "$TEST_TMP/elsewhere/error.json"
run_call GET 'https://external.example.test/failure' --error-out error.json
expect_result '--error-out does not retain a partial transport response' 1 '' \
  $'curl: (7) fixture connection failed\n'
assert_absent 'transport failure clears stale --error-out' "$TEST_TMP/elsewhere/error.json"
for output_mode in stdout existing absent; do
  case "$output_mode" in
    stdout) run_call GET 'https://external.example.test/failure' ;;
    existing)
      printf '%s' untouched > "$TEST_TMP/elsewhere/saved.json"
      run_call GET 'https://external.example.test/failure' --out saved.json
      assert_absent 'transport failure removes existing output' "$TEST_TMP/elsewhere/saved.json"
      ;;
    absent)
      run_call GET 'https://external.example.test/failure' --out saved.json
      assert_absent 'transport failure leaves absent output unwritten' "$TEST_TMP/elsewhere/saved.json"
      ;;
  esac
  expect_result "transport failure ($output_mode) maps curl exit to 1 and preserves curl error" 1 '' \
    $'curl: (7) fixture connection failed\n'
done
STUB_TRANSPORT_CODE=0
printf '%s' '{"ok":true}' > "$STUB_RESPONSE"
STUB_SIGNAL=TERM
printf '%s' stale > "$TEST_TMP/elsewhere/saved.json"
printf '%s' stale > "$TEST_TMP/elsewhere/error.json"
run_call GET 'https://external.example.test/interrupted' --out saved.json --error-out error.json
expect_result 'signal interruption returns failure without a response' 1 '' ''
assert_absent 'signal interruption removes existing output' "$TEST_TMP/elsewhere/saved.json"
assert_absent 'signal interruption clears stale --error-out' "$TEST_TMP/elsewhere/error.json"
printf '%s' '{"scratch":"interrupted"}' > "$CHECKOUT/tmp/interrupted.json"
run_call POST 'https://external.example.test/interrupted' --json-file "$CHECKOUT/tmp/interrupted.json"
expect_result 'interrupted scratch request preserves failure status' 1 '' ''
assert_file 'interrupted request read its scratch body' "$RECORD/body" '{"scratch":"interrupted"}'
assert_absent 'interrupted request consumes its scratch body' "$CHECKOUT/tmp/interrupted.json"
STUB_SIGNAL=''

for TRACE_MODE in argument inherited; do
  for auth in github egregore resend; do
    run_call GET 'https://external.example.test/tracing' --auth "$auth"
    if [ "$STATUS" -eq 0 ] && equal_file "$TEST_TMP/stdout" '{"ok":true}' \
        && [ -s "$TEST_TMP/stderr" ]; then
      ok "$auth succeeds under $TRACE_MODE xtrace without tracing its token"
    else
      bad "$auth fails under $TRACE_MODE xtrace"
    fi
    assert_file "$auth under $TRACE_MODE xtrace still sends fixture credential on stdin" \
      "$RECORD/stdin" "Authorization: Bearer fixture-$auth-secret"$'\n'
  done
done
TRACE_MODE=plain

printf 'GITHUB_TOKEN= \tfixture-github-secret \t\r\nEGREGORE_API_KEY= \tfixture-egregore-secret \t\r\nRESEND_API_KEY= \tfixture- resend- secret \t\r\n' > "$CHECKOUT/.env"
for auth in github egregore resend; do
  run_call GET 'https://external.example.test/env' --auth "$auth"
  expect_result "$auth accepts surrounding whitespace and CRLF" 0 '{"ok":true}' ''
  assert_file "$auth whitespace normalization preserves expected key" "$RECORD/stdin" \
    "Authorization: Bearer fixture-$auth-secret"$'\n'
done
printf '%s\n' 'GITHUB_TOKEN= fixture github interior secret ' \
  'EGREGORE_API_KEY= fixture egregore interior secret ' > "$CHECKOUT/.env"
for auth in github egregore; do
  run_call GET 'https://external.example.test/env' --auth "$auth"
  expect_result "$auth preserves interior whitespace" 0 '{"ok":true}' ''
  assert_file "$auth trims only edges" "$RECORD/stdin" \
    "Authorization: Bearer fixture $auth interior secret"$'\n'
done

for env_state in absent empty whitespace; do
  case "$env_state" in
    absent) rm "$CHECKOUT/.env" ;;
    empty) printf '%s\n' GITHUB_TOKEN= EGREGORE_API_KEY= RESEND_API_KEY= > "$CHECKOUT/.env" ;;
    whitespace) printf 'GITHUB_TOKEN= \t\r\nEGREGORE_API_KEY= \t\r\nRESEND_API_KEY= \t\r\n' > "$CHECKOUT/.env" ;;
  esac
  STUB_GH_TOKEN=$' \tfixture-gh-fallback-secret \r\n'
  run_call GET 'https://external.example.test/env' --auth github
  expect_result "github fallback handles $env_state .env key" 0 '{"ok":true}' ''
  assert_file "github fallback ($env_state) calls gh auth token" "$RECORD/gh-argv" $'auth\ntoken\n'
  assert_file "github fallback ($env_state) stays on stdin" "$RECORD/stdin" \
    $'Authorization: Bearer fixture-gh-fallback-secret\n'
  STUB_GH_EXIT=1
  reject "github missing key ($env_state)" 2 'api-call: GITHUB_TOKEN is not set in .env' \
    GET 'https://external.example.test/env' --auth github
  STUB_GH_EXIT=0
  reject "egregore missing key ($env_state)" 2 'api-call: EGREGORE_API_KEY is not set in .env' \
    GET 'https://external.example.test/env' --auth egregore
  reject "resend missing key ($env_state)" 2 'api-call: RESEND_API_KEY is not set in .env' \
    GET 'https://external.example.test/env' --auth resend
done
STUB_GH_TOKEN=''
reject 'empty successful gh fallback is a missing key' 2 'api-call: GITHUB_TOKEN is not set in .env' \
  GET 'https://external.example.test/env' --auth github
fixture_env

for api_config in '{}' '{"api_url":""}'; do
  fixture_config "$api_config"
  reject 'missing or empty api_url fails before curl' 2 'api-call: api_url is not set' GET '/api/admin/dashboard'
done
reject 'missing JSON file fails before curl' 2 'api-call: JSON file does not exist: missing.json' \
  POST 'https://external.example.test/body' --json-file missing.json
reject 'JSON body must be a file' 2 'api-call: JSON file does not exist: .' \
  POST 'https://external.example.test/body' --json-file .
mkdir "$TEST_TMP/elsewhere/output-directory" "$TEST_TMP/elsewhere/locked-parent"
reject '--out rejects a directory before curl' 2 'api-call: cannot write --out output-directory' \
  GET 'https://external.example.test/body' --out output-directory
reject '--out rejects a missing parent before curl' 2 'api-call: cannot write --out missing-parent/response.json' \
  GET 'https://external.example.test/body' --out missing-parent/response.json
reject '--error-out rejects a directory before curl' 2 'api-call: cannot write --error-out output-directory' \
  GET 'https://external.example.test/body' --error-out output-directory
reject '--error-out rejects a missing parent before curl' 2 'api-call: cannot write --error-out missing-parent/error.json' \
  GET 'https://external.example.test/body' --error-out missing-parent/error.json
chmod 500 "$TEST_TMP/elsewhere/locked-parent"
if [ ! -w "$TEST_TMP/elsewhere/locked-parent" ]; then
  reject '--out rejects an unwritable parent before curl' 2 'api-call: cannot write --out locked-parent/response.json' \
    GET 'https://external.example.test/body' --out locked-parent/response.json
else
  printf '  - unwritable-parent check skipped: current user bypasses directory permissions\n'
fi
chmod 700 "$TEST_TMP/elsewhere/locked-parent"

USAGE=$'Usage: bash bin/api-call.sh <METHOD> <path-or-url> [--auth github|egregore|resend] [--json-file <file>] [--out <file>] [--error-out <file>]\nFailed responses are discarded unless --error-out requests a private HTTP error body.'
reject 'no arguments shows usage' 2 "$USAGE"
reject 'missing target shows usage' 2 "$USAGE" GET
reject 'empty method shows usage' 2 "$USAGE" '' 'https://external.example.test'
reject 'invalid method shows usage' 2 "$USAGE" 'GET;echo' 'https://external.example.test'
reject 'HTTP URL is rejected' 2 "$USAGE" GET 'http://external.example.test'
reject 'relative target is rejected' 2 "$USAGE" GET 'api/dashboard'
reject 'unknown flag shows usage' 2 "$USAGE" GET 'https://external.example.test' --other value
reject 'invalid auth shows usage' 2 "$USAGE" GET 'https://external.example.test' --auth other
reject 'missing option value shows usage' 2 "$USAGE" GET 'https://external.example.test' --auth
reject 'empty option value shows usage' 2 "$USAGE" GET 'https://external.example.test' --out ''
reject 'duplicate auth shows usage' 2 "$USAGE" GET 'https://external.example.test' --auth github --auth egregore
reject 'duplicate body shows usage' 2 "$USAGE" POST 'https://external.example.test' --json-file request.json --json-file request.json
reject 'duplicate output shows usage' 2 "$USAGE" GET 'https://external.example.test' --out a.json --out b.json
reject 'duplicate error output shows usage' 2 "$USAGE" GET 'https://external.example.test' --error-out a.json --error-out b.json
reject 'success and error output cannot share a path' 2 "$USAGE" GET 'https://external.example.test' --out a.json --error-out a.json
reject 'success and error output cannot alias a path' 2 "$USAGE" GET 'https://external.example.test' --out a.json --error-out ./a.json

if [ "$SAFETY_FAILURES" -eq 0 ]; then
  ok "all $RUNS calls keep tokens off argv/output, use safe transport, and clean temporary responses"
fi
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
