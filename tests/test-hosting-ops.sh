#!/usr/bin/env bash
# All transport runs in a fixture checkout. No real credentials or network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
CHECKOUT="$TEST_TMP/checkout"
STUBS="$TEST_TMP/stubs"
RECORD="$TEST_TMP/record"
PASS=0
FAIL=0
RUNS=0
TRACE_MODE=plain
REAL_JQ=$(command -v jq)
mkdir -p "$CHECKOUT/bin/lib" "$CHECKOUT/docker/egregore-template" "$STUBS" "$RECORD" "$TEST_TMP/elsewhere"
cp "$ROOT/bin/hosting-ops.sh" "$ROOT/bin/api-call.sh" "$ROOT/bin/config-get.sh" "$CHECKOUT/bin/"
cp "$ROOT/bin/lib/config.sh" "$CHECKOUT/bin/lib/config.sh"
cp "$ROOT/bin/lib/scratch.sh" "$CHECKOUT/bin/lib/scratch.sh"
cp -R "$ROOT/egregore_runtime" "$CHECKOUT/egregore_runtime"
cp "$ROOT/docker/egregore-template/main.tf" "$CHECKOUT/docker/egregore-template/main.tf"
printf '%s\n' '{"api_url":"https://api.example.test/root/","slug":"fixture"}' > "$CHECKOUT/egregore.json"
printf '%s\n' 'GITHUB_TOKEN=fixture-github-secret' 'EGREGORE_API_KEY=fixture-egregore-secret' > "$CHECKOUT/.env"
printf '%s\n' fixture-vps-password fixture-github-secret fixture-egregore-secret \
  fixture-session-secret fixture-org-api-secret fixture-remote-github-secret > "$TEST_TMP/secrets"

cat > "$STUBS/record" <<'STUB'
# shellcheck shell=bash
tool="${0##*/}"
number=0
[ ! -f "$STUB_RUN/count" ] || read -r number < "$STUB_RUN/count"
number=$((number + 1))
printf '%s\n' "$number" > "$STUB_RUN/count"
record="$STUB_RUN/calls/$number-$tool"
mkdir -p "$record"
printf '%s\n' "$tool" >> "$STUB_RUN/events"
printf '%s\n' "$record" >> "$STUB_RUN/$tool-calls"
printf '%s\0' "$@" > "$record/argv0"
printf '%s\n' "$@" > "$record/argv"
env > "$record/environment"
printf '%s' "${SSHPASS-}" > "$record/SSHPASS"
printf '%s' "${CODER_SESSION_TOKEN-}" > "$record/CODER_SESSION_TOKEN"
printf '%s' "${CODER_URL-}" > "$record/CODER_URL"
printf '%s' "${GIT_DIR-}${GIT_WORK_TREE-}${GIT_INDEX_FILE-}${GIT_OBJECT_DIRECTORY-}${GIT_ALTERNATE_OBJECT_DIRECTORIES-}${GIT_COMMON_DIR-}" > "$record/git-overrides"
STUB

cat > "$STUBS/jq" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$STUBS/record"
original_args=("$@")
null_input=false
saw_filter=false
has_file=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --arg|--argjson|--slurpfile|--rawfile|--argfile) shift 3 ;;
    --indent) shift 2 ;;
    -n|--null-input|-[A-Za-z]*n*) null_input=true; shift ;;
    -*) shift ;;
    *)
      if [ "$saw_filter" = true ]; then has_file=true; else saw_filter=true; fi
      shift
      ;;
  esac
done
# File-input and -n jq calls must leave the caller's stdin for the later SSH.
if [ "$null_input" = true ] || [ "$has_file" = true ]; then
  : > "$record/stdin"
  exec "$REAL_JQ" "${original_args[@]}"
fi
cat > "$record/stdin"
exec "$REAL_JQ" "${original_args[@]}" < "$record/stdin"
STUB

cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$STUBS/record"
cat > "$record/stdin"
method=GET
url=''
output=''
write_out=''
body=''
: > "$record/headers"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -q|-s|-S|-f|-sS|-sf|-fsS|--silent|--show-error|--fail) shift ;;
    --max-time|--connect-timeout) shift 2 ;;
    -X|--request) method="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    -o|--output) output="$2"; shift 2 ;;
    -w|--write-out) write_out="$2"; shift 2 ;;
    -H|--header)
      case "$2" in
        @-) cat "$record/stdin" >> "$record/headers" ;;
        @*) cat "${2#@}" >> "$record/headers" ;;
        *) printf '%s\n' "$2" >> "$record/headers" ;;
      esac
      shift 2
      ;;
    -K|--config)
      config="$2"
      if [ "$config" = - ]; then config="$record/stdin"; else
        mode=$(stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config")
        [ "$mode" = 600 ] || { echo 'curl stub: header config is not private' >&2; exit 90; }
      fi
      while IFS= read -r line; do
        key="${line%%=*}"
        key="${key//[[:space:]]/}"
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value=$(printf '%s' "$value" | "$REAL_JQ" -r .)
        case "$key" in
          header) printf '%s\n' "$value" >> "$record/headers" ;;
          url) url="$value" ;;
          request) method="$value" ;;
          data|data-binary) body="$value" ;;
          *) echo 'curl stub: unexpected config key' >&2; exit 90 ;;
        esac
      done < "$config"
      shift 2
      ;;
    -d|--data|--data-raw|--data-binary|--json)
      method=POST
      case "$2" in
        @-) body=$(cat "$record/stdin") ;;
        @*) body=$(cat "${2#@}") ;;
        *) body="$2" ;;
      esac
      shift 2
      ;;
    http://*|https://*) url="$1"; shift ;;
    *) echo 'curl stub: unexpected argument' >&2; exit 90 ;;
  esac
done
printf '%s' "$method" > "$record/method"
printf '%s' "$url" > "$record/url"
printf '%s' "$body" > "$record/body"
request=0
[ ! -f "$STUB_RUN/curl-count" ] || read -r request < "$STUB_RUN/curl-count"
request=$((request + 1))
printf '%s\n' "$request" > "$STUB_RUN/curl-count"
expected="$STUB_RUN/expected/$request"
if [ ! -d "$expected" ] || ! cmp -s "$record/method" "$expected/method" || ! cmp -s "$record/url" "$expected/url"; then
  printf 'curl stub: unexpected method/url at request %s\n' "$request" >&2
  exit 90
fi
if [ -f "$expected/body" ]; then
  "$REAL_JQ" -Sc . "$record/body" > "$record/body-normalized"
  "$REAL_JQ" -Sc . "$expected/body" > "$expected/body-normalized"
  cmp -s "$record/body-normalized" "$expected/body-normalized" || { echo 'curl stub: unexpected request body' >&2; exit 90; }
elif [ -s "$record/body" ]; then
  echo 'curl stub: unexpected request body' >&2
  exit 90
fi
case "$url" in
  https://api.example.test/root/api/hosting/user/*) grep -Fxq 'Authorization: Bearer fixture-egregore-secret' "$record/headers" ;;
  https://api.example.test/*) grep -Fxq 'Authorization: Bearer fixture-github-secret' "$record/headers" ;;
  http://localhost/api/v2/users/login) [ "${STUB_REMOTE-}" = 1 ] ;;
  http://localhost/api/v2/*)
    [ "${STUB_REMOTE-}" = 1 ]
    grep -Fxq 'Coder-Session-Token: fixture-session-secret' "$record/headers"
    ;;
  *) echo 'curl stub: unexpected host' >&2; exit 90 ;;
esac
: > "$record/valid-request"
if [ -n "$output" ]; then cat "$expected/response" > "$output"; else cat "$expected/response"; fi
if [ -n "$write_out" ]; then
  code=$(cat "$expected/http")
  write_out="${write_out//\%\{http_code\}/$code}"
  printf '%b' "$write_out"
fi
exit 0
STUB

cat > "$STUBS/sshpass" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$STUBS/record"
cat > "$record/stdin"
[ "${1-}" = -e ] || { echo 'sshpass stub: expected -e' >&2; exit 90; }
[ "${SSHPASS-}" = fixture-vps-password ] || { echo 'sshpass stub: missing password environment' >&2; exit 90; }
shift
exec "$@" < "$record/stdin"
STUB

cat > "$STUBS/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$STUBS/record"
cat > "$record/stdin"
[ "${SSHPASS-}" = fixture-vps-password ] || exit 90
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) [ "$2" = StrictHostKeyChecking=no ] || exit 90; shift 2 ;;
    root@192.0.2.10) shift; break ;;
    *) echo 'ssh stub: unexpected connection argument' >&2; exit 90 ;;
  esac
done
printf '%s\0' "$@" > "$record/remote-argv0"
case "${1-}" in
  'cat /opt/egregore/org-config.json') printf '%s\n' '{"egregore_api_key":"fixture-org-api-secret","fork_url":"https://github.com/fixture/framework","memory_url":"https://github.com/fixture/memory"}' ;;
  'cat /opt/egregore/github-token 2>/dev/null'|'cat /opt/egregore/github-token') printf '%s\n' fixture-remote-github-secret ;;
  'mkdir -p /tmp/egregore-template') ;;
  'bash -s'|bash)
    # Execute the stdin script with a stub Coder CLI, so remote argv is audited too.
    env -u SSHPASS TMPDIR="$STUB_RUN" STUB_REMOTE=1 bash < "$record/stdin"
    ;;
  *curl*)
    # SSH does not forward its own password environment to the remote process.
    env -u SSHPASS STUB_REMOTE=1 bash -c "$*" < "$record/stdin"
    ;;
  *) printf '%s\n' 'fixture remote stdout' ;;
esac
STUB

cat > "$STUBS/scp" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$STUBS/record"
cat > "$record/stdin"
[ "${SSHPASS-}" = fixture-vps-password ] || exit 90
STUB

cat > "$STUBS/coder" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$STUBS/record"
cat > "$record/stdin"
[ -z "${CODER_SESSION_TOKEN-}" ] || exit 90
[ "${CODER_URL-}" = http://localhost ] || exit 90
while [ "$#" -gt 0 ]; do
  case "$1" in
    --global-config)
      printf '%s' "$2" > "$record/config-path"
      cat "$2/session" > "$record/session"
      stat -c '%a' "$2/session" > "$record/session-mode" 2>/dev/null || stat -f '%Lp' "$2/session" > "$record/session-mode"
      shift 2
      ;;
    --variables-file)
      cat "$2" > "$record/variables"
      printf '%s' "$2" > "$record/variables-path"
      stat -c '%a' "$2" > "$record/variables-mode" 2>/dev/null || stat -f '%Lp' "$2" > "$record/variables-mode"
      shift 2
      ;;
    *) shift ;;
  esac
done
[ "$(cat "$record/session")" = fixture-session-secret ] || exit 90
if [ "$STUB_PUSH_FAIL" = 1 ]; then printf '%s\n' 'fixture push failed' >&2; exit 7; fi
printf '%s\n' 'fixture push stdout'
STUB

cat > "$STUBS/sleep" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$STUBS/record"
: > "$record/stdin"
STUB
chmod +x "$STUBS/jq" "$STUBS/curl" "$STUBS/sshpass" "$STUBS/ssh" "$STUBS/scp" "$STUBS/coder" "$STUBS/sleep"
export REAL_JQ STUBS TRACE_MODE STUB_RUN='' STUB_PUSH_FAIL=0

ok() { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert() {
  local description="$1"
  shift
  if "$@"; then ok "$description"; else bad "$description"; fi
}
new_case() {
  RUNS=$((RUNS + 1))
  STUB_RUN="$RECORD/$RUNS"
  mkdir -p "$STUB_RUN/calls" "$STUB_RUN/expected"
  EXPECTED=0
  STUB_PUSH_FAIL=0
}
request() {
  EXPECTED=$((EXPECTED + 1))
  local target="$STUB_RUN/expected/$EXPECTED"
  mkdir -p "$target"
  printf '%s' "$1" > "$target/method"
  printf '%s' "$2" > "$target/url"
  printf '%s' "$3" > "$target/response"
  printf '%s' 200 > "$target/http"
  [ "$#" -lt 4 ] || printf '%s' "$4" > "$target/body"
}
status_request() {
  local response='{"ip":"192.0.2.10","coder_ready":true}'
  request GET 'https://api.example.test/root/api/hosting/status/fixture' "${1:-$response}"
}
credentials_request() {
  local response='{"ip":"192.0.2.10","password":"fixture-vps-password","coder_url":"http://192.0.2.10"}'
  request GET 'https://api.example.test/root/api/hosting/credentials/fixture' "${1:-$response}"
}
login_request() {
  local response='{"session_token":"fixture-session-secret"}'
  request POST 'http://localhost/api/v2/users/login' "${1:-$response}" \
    '{"email":"admin@egregore.xyz","password":"fixture-vps-password"}'
}
access_requests() { credentials_request; }
run_call() {
  STATUS=0
  (
    cd "$TEST_TMP/elsewhere" || exit 1
    PATH="$STUBS:$PATH" CONFIG='' ENV_FILE='' HOSTING_OPS_POLL_SECONDS=0 \
      GITHUB_TOKEN=inherited-wrong-token EGREGORE_API_KEY=inherited-wrong-key \
      GIT_DIR=wrong GIT_WORK_TREE=wrong GIT_INDEX_FILE=wrong GIT_OBJECT_DIRECTORY=wrong \
      GIT_ALTERNATE_OBJECT_DIRECTORIES=wrong GIT_COMMON_DIR=wrong \
      bash -c '
        case "$TRACE_MODE" in
          argument) exec bash -xv "$@" ;;
          inherited) exec env SHELLOPTS=xtrace:verbose bash "$@" ;;
          *) exec bash "$@" ;;
        esac
      ' hosting-ops "$CHECKOUT/bin/hosting-ops.sh" "$@"
  ) > "$STUB_RUN/stdout" 2> "$STUB_RUN/stderr" || STATUS=$?
  printf '%s' "$STATUS" > "$STUB_RUN/status"
}
request_count() {
  local actual=0
  [ ! -f "$STUB_RUN/curl-count" ] || read -r actual < "$STUB_RUN/curl-count"
  [ "$actual" -eq "$EXPECTED" ] && [ "$(find "$STUB_RUN/calls" -name valid-request | wc -l | tr -d ' ')" -eq "$EXPECTED" ]
}
result() {
  assert "$1 exits $2" test "$STATUS" -eq "$2"
  assert "$1 performs the exact HTTP sequence and bodies" request_count
}
only_call() {
  [ ! -f "$STUB_RUN/$1-calls" ] || cat "$STUB_RUN/$1-calls"
}
file_equals() { [ "$(cat "$1")" = "$2" ]; }
json_matches() { jq -e "$2" "$1" > /dev/null; }
sleep_intervals() {
  local call
  while IFS= read -r call; do
    file_equals "$call/argv" "$1" || return 1
  done < <(only_call sleep)
}
remote_vector_equals() {
  printf '%s\0' "$2" > "$TEST_TMP/expected-remote"
  cmp -s "$1/remote-argv0" "$TEST_TMP/expected-remote"
}
transport_events() {
  grep -v '^jq$' "$STUB_RUN/events" > "$STUB_RUN/transport-events"
  file_equals "$STUB_RUN/transport-events" "$1"
}
remote_steps() {
  local call command steps=''
  while IFS= read -r call; do
    command=$(tr '\0' ' ' < "$call/remote-argv0")
    case "$command" in
      'mkdir -p /tmp/egregore-template '*) steps+='mkdir' ;;
      *curl*http://localhost/api/v2/users/login*) steps+='login' ;;
      'cat /opt/egregore/org-config.json '*) steps+='config' ;;
      'cat /opt/egregore/github-token 2>/dev/null '*) steps+='token' ;;
      'bash -s '*) steps+='push' ;;
      *) return 1 ;;
    esac
    steps+=$'\n'
  done < <(only_call ssh)
  [ "$steps" = $'mkdir\nlogin\nconfig\ntoken\npush\n' ]
}
remote_request_records() {
  local call command remote_count=0
  while IFS= read -r call; do
    command=$(tr '\0' ' ' < "$call/remote-argv0")
    case "$command" in
      *curl*http://localhost/api/v2/users/login*)
        "$REAL_JQ" -e '.email == "admin@egregore.xyz" and .password == "fixture-vps-password"' "$call/stdin" > /dev/null || return 1
        remote_count=$((remote_count + 1))
        ;;
      *curl*)
        grep -Fq 'http://localhost/api/v2/' "$call/stdin" || return 1
        grep -Fq 'Coder-Session-Token: fixture-session-secret' "$call/stdin" || return 1
        remote_count=$((remote_count + 1))
        ;;
    esac
  done < <(only_call ssh)
  [ "$remote_count" -eq "$1" ]
}

printf 'test-hosting-ops\n'
for command in status enable list; do
  new_case
  case "$command" in
    status) status_request '{"fixture":"status-body"}'; run_call status fixture ;;
    enable) request POST 'https://api.example.test/root/api/hosting/enable/fixture' '{"fixture":"enable-body"}'; run_call enable fixture ;;
    list) request GET 'https://api.example.test/root/api/admin/health' '{"fixture":"list-body"}'; run_call list ;;
  esac
  result "$command" 0
  assert "$command prints the response body" file_equals "$STUB_RUN/stdout" "{\"fixture\":\"$command-body\"}"
done

new_case
request POST 'https://api.example.test/root/api/hosting/enable/fixture' '{"error":"private failure response"}'
printf '%s' 500 > "$STUB_RUN/expected/1/http"
run_call enable fixture
result 'gateway HTTP failure' 1
assert 'gateway failure keeps response body private' test ! -s "$STUB_RUN/stdout"
assert 'gateway failure carries helper error prefix' grep -Fq 'hosting-ops:' "$STUB_RUN/stderr"

new_case
status_request '{"coder_ready":false,"token_stored":false}'
status_request '{"ip":"192.0.2.10","coder_ready":false,"token_stored":false}'
status_request '{"ip":"192.0.2.10","coder_ready":true,"token_stored":true}'
run_call wait-ready fixture
result 'wait-ready succeeds on third poll' 0
assert 'wait-ready prints exactly one progress line per attempt' test "$(grep -c 'check [1-3]/10' "$STUB_RUN/stdout")" -eq 3
assert 'wait-ready shows IP once known' grep -Fq 192.0.2.10 "$STUB_RUN/stdout"
assert 'wait-ready prints token_stored for each status response' test "$(grep -c token_stored "$STUB_RUN/stdout")" -eq 3
assert 'wait-ready reports stored token when ready' grep -Eq 'token_stored[^[:alnum:]]+true' "$STUB_RUN/stdout"
assert 'wait-ready sleeps twice between three attempts' test "$(only_call sleep | wc -l | tr -d ' ')" -eq 2
assert 'wait-ready honors test poll interval override' sleep_intervals 0

new_case
for ((attempt=1; attempt<=10; attempt++)); do status_request '{"ip":"192.0.2.10","coder_ready":false}'; done
run_call wait-ready fixture
result 'wait-ready fails after ten attempts' 1
assert 'wait-ready prints ten progress lines' test "$(grep -c 'check [0-9][0-9]*/10' "$STUB_RUN/stdout")" -eq 10
assert 'wait-ready does not sleep after its final attempt' test "$(only_call sleep | wc -l | tr -d ' ')" -eq 9

new_case
status_request '{"error":"fixture provisioning failure"}'
run_call wait-ready fixture
result 'wait-ready stops on an error body' 1

new_case
access_requests
remote_command='printf "%s\n" "a command with spaces; $(not-expanded)"'
run_call ssh fixture -- "$remote_command" < /dev/null
result 'ssh' 0
assert 'ssh receives one unchanged remote command argument' remote_vector_equals "$(only_call ssh)" "$remote_command"
assert 'ssh password is environment only' file_equals "$(only_call ssh)/SSHPASS" fixture-vps-password
assert 'sshpass password is environment only' file_equals "$(only_call sshpass)/SSHPASS" fixture-vps-password
assert 'credentials GET uses GitHub token only in stdin headers' file_equals "$(only_call curl)/stdin" 'Authorization: Bearer fixture-github-secret'

new_case
access_requests
run_call ssh fixture 'systemctl status coder-auth.service' < /dev/null
result 'ssh optional separator' 0
assert 'ssh without separator preserves command' remote_vector_equals "$(only_call ssh)" 'systemctl status coder-auth.service'

new_case
access_requests
printf '%s' fixture-github-secret | run_call ssh fixture -- "docker login ghcr.io -u 'fixture-user' --password-stdin"
# A pipeline puts run_call in a subshell; its status is also recorded by its output.
assert 'registry login pipeline reaches SSH' test -n "$(only_call ssh)"
assert 'registry login pipeline succeeds' file_equals "$STUB_RUN/status" 0
assert 'registry login pipeline forwards token on stdin' file_equals "$(only_call ssh)/stdin" fixture-github-secret
assert 'registry login pipeline preserves remote command' remote_vector_equals "$(only_call ssh)" "docker login ghcr.io -u 'fixture-user' --password-stdin"
assert 'registry login pipeline performs expected requests' request_count

new_case
access_requests
printf '%s' fixture-upload > "$TEST_TMP/elsewhere/local file.tf"
run_call scp fixture 'local file.tf' '/tmp/remote file.tf' < /dev/null
result 'scp' 0
assert 'scp password is environment only' file_equals "$(only_call scp)/SSHPASS" fixture-vps-password
assert 'scp passes caller-relative file unchanged' grep -Fxq 'local file.tf' "$(only_call scp)/argv"
assert 'scp targets resolved VPS path' grep -Fxq 'root@192.0.2.10:/tmp/remote file.tf' "$(only_call scp)/argv"

for TRACE_MODE in argument inherited; do
  new_case
  access_requests
  login_request
  run_call deploy-template fixture < /dev/null
  result "deploy-template under $TRACE_MODE tracing" 0
  assert "$TRACE_MODE tracing executes actual remote Coder push" test -n "$(only_call coder)"
  assert "$TRACE_MODE tracing was enabled before helper startup" test -s "$STUB_RUN/stderr"
done
TRACE_MODE=plain

for version in fixture-initial descriptive-v2 "literal 'version'; \$(not-expanded)"; do
  new_case
  access_requests
  login_request
  if [ "$version" = fixture-initial ]; then run_call deploy-template fixture < /dev/null
  else run_call deploy-template fixture --name "$version" < /dev/null; fi
  result "deploy-template $version" 0
  assert 'deploy-template prints push stdout and final deployed line only' file_equals "$STUB_RUN/stdout" \
    "fixture push stdout"$'\n'"Template \"Egregore\" deployed: $version"
  coder_call=$(only_call coder)
  assert 'remote Coder reads session token from private config' file_equals "$coder_call/session" fixture-session-secret
  assert 'remote Coder session token is absent from environment' test ! -s "$coder_call/CODER_SESSION_TOKEN"
  assert 'remote Coder session file is private' file_equals "$coder_call/session-mode" 600
  assert 'remote Coder config directory is removed after push' test ! -e "$(cat "$coder_call/config-path")"
  assert 'remote Coder receives the chosen version' grep -Fxq "$version" "$coder_call/argv"
  assert 'remote push preserves template name' grep -Fxq Egregore "$coder_call/argv"
  assert 'remote push remains noninteractive' grep -Fxq -- --yes "$coder_call/argv"
  assert 'remote push receives all six original variable values privately' json_matches "$coder_call/variables" \
    '. == {egregore_api_key:"fixture-org-api-secret",api_url:"https://api.example.test/root/",memory_url:"https://github.com/fixture/memory",fork_url:"https://github.com/fixture/framework",ghcr_token:"not-needed",github_token:"fixture-remote-github-secret"}'
  assert 'remote variables file is private' file_equals "$coder_call/variables-mode" 600
  assert 'remote variables file is removed after push' test ! -e "$(cat "$coder_call/variables-path")"
  assert 'deploy-template preserves mkdir → copy → login → config → token → push order' transport_events \
    $'curl\nsshpass\nssh\nsshpass\nscp\nsshpass\nssh\ncurl\nsshpass\nssh\nsshpass\nssh\nsshpass\nssh\ncoder'
  assert 'deploy-template runs the exact remote steps in order' remote_steps
  assert 'login body reaches localhost over SSH stdin' remote_request_records 1
  script_call=''
  while IFS= read -r ssh_call; do
    if grep -Fq 'templates push' "$ssh_call/stdin"; then script_call="$ssh_call"; fi
  done < <(only_call ssh)
  assert 'deploy-template supplies its remote script on SSH stdin' test -n "$script_call"
  assert 'deploy-template script carries all six variable names' sh -c \
    'for key in egregore_api_key api_url memory_url fork_url ghcr_token github_token; do grep -Fq "$key" "$1" || exit 1; done' sh "$script_call/stdin"
  assert 'deploy-template copies the checkout template' grep -Fxq "$CHECKOUT/docker/egregore-template/main.tf" "$(only_call scp)/argv"
done

new_case
access_requests
login_request
STUB_PUSH_FAIL=1
run_call deploy-template fixture < /dev/null
result 'failed remote push' 1
assert 'failed push stderr passes through' grep -Fxq 'fixture push failed' "$STUB_RUN/stderr"
assert 'failed push never prints deployed' sh -c '! grep -Fq deployed "$1"' sh "$STUB_RUN/stdout"
assert 'failed push removes remote variables file' test ! -e "$(cat "$(only_call coder)/variables-path")"
assert 'failed push removes remote session config' test ! -e "$(cat "$(only_call coder)/config-path")"

new_case
access_requests
login_request '{"error":"reflected fixture-vps-password and fixture-session-secret"}'
run_call deploy-template fixture < /dev/null
result 'login reflected-secret response fails privately' 1
assert 'login failure emits no response body on stdout' test ! -s "$STUB_RUN/stdout"
assert 'login failure uses a fixed bounded error' file_equals "$STUB_RUN/stderr" 'hosting-ops: Coder login failed'

new_case
access_requests
login_request
request GET 'http://localhost/api/v2/workspaces/ws-fixture' '{"template_id":"template-fixture","latest_build":{"status":"running"}}'
request POST 'http://localhost/api/v2/workspaces/ws-fixture/builds' '{"id":"stop-build"}' '{"transition":"stop"}'
request GET 'http://localhost/api/v2/workspaces/ws-fixture' '{"template_id":"template-fixture","latest_build":{"status":"stopping"}}'
request GET 'http://localhost/api/v2/workspaces/ws-fixture' '{"template_id":"template-fixture","latest_build":{"status":"stopped"}}'
request GET 'http://localhost/api/v2/templates/template-fixture' '{"active_version_id":"version-fixture"}'
request POST 'http://localhost/api/v2/workspaces/ws-fixture/builds' '{"id":"start-build"}' '{"transition":"start","template_version_id":"version-fixture"}'
run_call restart-workspace fixture ws-fixture < /dev/null
result 'restart-workspace stop → poll → start' 0
assert 'restart-workspace polls every five seconds' sleep_intervals 5
assert 'restart requests use only localhost curl through SSH stdin' remote_request_records 7

new_case
access_requests
login_request
request GET 'http://localhost/api/v2/workspaces/ws-fixture' '{"template_id":"template-fixture","latest_build":{"status":"running"}}'
request POST 'http://localhost/api/v2/workspaces/ws-fixture/builds' '{}' '{"transition":"stop"}'
for ((attempt=1; attempt<=24; attempt++)); do
  request GET 'http://localhost/api/v2/workspaces/ws-fixture' '{"template_id":"template-fixture","latest_build":{"status":"stopping"}}'
done
run_call restart-workspace fixture ws-fixture < /dev/null
result 'restart-workspace stops after 24 unsuccessful polls' 1
assert 'restart-workspace bounded polling uses 24 sleeps' test "$(only_call sleep | wc -l | tr -d ' ')" -eq 24

members='{"members":[{"github_username":"active-user","status":"active"},{"github_username":"inactive-user","status":"inactive"},{"github_username":"failing-user","status":"active"}]}'
new_case
request GET 'https://api.example.test/root/api/admin/org/fixture' "$members"
request POST 'https://api.example.test/root/api/hosting/user/fixture' '{}' '{"username":"active-user"}'
request POST 'https://api.example.test/root/api/hosting/user/fixture' '{"detail":"fixture user failure"}' '{"username":"failing-user"}'
printf '%s' 400 > "$STUB_RUN/expected/$EXPECTED/http"
run_call users fixture
result 'users sequentially skips inactive and counts a failure' 1
assert 'users prints exact member outcomes and summary' file_equals "$STUB_RUN/stdout" \
  $'✓ active-user — Coder user created (workspace is created on first open)\n✗ failing-user — error: fixture user failure\nDone: 1 created, 1 failed'
while IFS= read -r curl_call; do
  if file_equals "$curl_call/method" POST; then
    assert 'user creation authenticates with the org API key in stdin' grep -Fxq 'Authorization: Bearer fixture-egregore-secret' "$curl_call/stdin"
  fi
done < <(only_call curl)

new_case
request GET 'https://api.example.test/root/api/admin/org/fixture' "$members"
request POST 'https://api.example.test/root/api/hosting/user/fixture' '{}' '{"username":"inactive-user"}'
run_call user fixture inactive-user
result 'user selects the named member independently of active filter' 0
assert 'user prints named member and summary' file_equals "$STUB_RUN/stdout" \
  $'✓ inactive-user — Coder user created (workspace is created on first open)\nDone: 1 created, 0 failed'

new_case
request GET 'https://api.example.test/root/api/admin/org/fixture' '{"members":[{"github_username":"inactive-user","status":"inactive"}]}'
run_call users fixture
result 'users with no active members' 0
assert 'users empty summary' file_equals "$STUB_RUN/stdout" 'Done: 0 created, 0 failed'

new_case
request GET 'https://api.example.test/root/api/admin/org/fixture' \
  '{"members":[{"github_username":"failing-user","status":"active"},{"github_username":"active-user","status":"active"}]}'
request POST 'https://api.example.test/root/api/hosting/user/fixture' '{"detail":"fixture user failure"}' '{"username":"failing-user"}'
printf '%s' 400 > "$STUB_RUN/expected/$EXPECTED/http"
request POST 'https://api.example.test/root/api/hosting/user/fixture' '{}' '{"username":"active-user"}'
run_call users fixture
result 'failed user creation continues next member' 1
assert 'user creation failure preserves progress and totals' file_equals "$STUB_RUN/stdout" \
  $'✗ failing-user — error: fixture user failure\n✓ active-user — Coder user created (workspace is created on first open)\nDone: 1 created, 1 failed'

new_case
request GET 'https://api.example.test/root/api/admin/org/fixture' "$members"
long_detail=$(printf '%0250d' 0)
bounded_detail=$(printf '%0200d' 0)
request POST 'https://api.example.test/root/api/hosting/user/fixture' "{\"detail\":\"$long_detail\"}" '{"username":"inactive-user"}'
printf '%s' 400 > "$STUB_RUN/expected/$EXPECTED/http"
run_call user fixture inactive-user
result 'member creation error detail is bounded' 1
assert 'member error retains exactly the first 200 detail characters' file_equals "$STUB_RUN/stdout" \
  "✗ inactive-user — error: $bounded_detail"$'\nDone: 0 created, 1 failed'

new_case
credentials_request '{"detail":"reflected fixture-vps-password"}'
printf '%s' 404 > "$STUB_RUN/expected/$EXPECTED/http"
run_call ssh fixture -- true < /dev/null
result 'missing hosted VPS' 1
assert 'credentials 404 has a fixed private error' file_equals "$STUB_RUN/stderr" 'hosting-ops: no hosted VPS or missing credentials for fixture'
assert 'credentials 404 emits no response body' test ! -s "$STUB_RUN/stdout"
assert 'credentials 404 never invokes SSH' test -z "$(only_call ssh)"

for missing_field in ip password; do
  new_case
  if [ "$missing_field" = ip ]; then credentials_request '{"password":"fixture-vps-password"}'
  else credentials_request '{"ip":"192.0.2.10"}'; fi
  run_call ssh fixture -- true < /dev/null
  result "credentials without $missing_field" 1
  assert "missing $missing_field has a fixed private error" file_equals "$STUB_RUN/stderr" 'hosting-ops: no hosted VPS or missing credentials for fixture'
  assert "missing $missing_field never invokes SSH" test -z "$(only_call ssh)"
done

new_case
mv "$STUBS/sshpass" "$STUBS/sshpass-disabled"
# Restrict PATH to known fixture commands so an installed host sshpass cannot mask this case.
mkdir -p "$TEST_TMP/no-sshpass"
for dependency in bash dirname pwd jq mkdir mktemp rm grep sed tr cat; do
  dependency_path=$(command -v "$dependency")
  [ ! -f "$dependency_path" ] || ln -s "$dependency_path" "$TEST_TMP/no-sshpass/$dependency"
done
STATUS=0
PATH="$TEST_TMP/no-sshpass" CONFIG='' ENV_FILE='' /bin/bash "$CHECKOUT/bin/hosting-ops.sh" ssh fixture -- true \
  > "$STUB_RUN/stdout" 2> "$STUB_RUN/stderr" || STATUS=$?
mv "$STUBS/sshpass-disabled" "$STUBS/sshpass"
assert 'missing sshpass fails before network' test "$STATUS" -eq 1
assert 'missing sshpass install hint is actionable' grep -Fq 'brew install hudochenkov/sshpass/sshpass' "$STUB_RUN/stderr"
assert 'missing sshpass never makes a request' test ! -f "$STUB_RUN/curl-count"

for usage_case in empty unknown missing-slug ssh-command scp-target workspace-id user-name extra-status bad-option; do
  new_case
  case "$usage_case" in
    empty) run_call ;;
    unknown) run_call unknown ;;
    missing-slug) run_call status ;;
    ssh-command) run_call ssh fixture -- ;;
    scp-target) run_call scp fixture file ;;
    workspace-id) run_call restart-workspace fixture ;;
    user-name) run_call user fixture ;;
    extra-status) run_call status fixture extra ;;
    bad-option) run_call deploy-template fixture --other value ;;
  esac
  result "usage: $usage_case" 2
  assert "usage: $usage_case prints stderr usage" grep -Fq Usage: "$STUB_RUN/stderr"
  assert "usage: $usage_case leaves stdout empty" test ! -s "$STUB_RUN/stdout"
done

# One final audit covers every transport's local argv and the actual remote Coder argv.
argv_leaks=0
output_leaks=0
environment_leaks=0
git_leaks=0
public_http=0
while IFS= read -r vector; do
  if grep -aFq -f "$TEST_TMP/secrets" "$vector"; then argv_leaks=$((argv_leaks + 1)); fi
done < <(find "$RECORD" -type f -name '*argv0')
while IFS= read -r output; do
  if grep -aFq -f "$TEST_TMP/secrets" "$output"; then output_leaks=$((output_leaks + 1)); fi
done < <(find "$RECORD" -type f \( -name stdout -o -name stderr \))
while IFS= read -r environment; do
  case "$environment" in
    *-sshpass/environment|*-ssh/environment|*-scp/environment)
      grep -v '^SSHPASS=' "$environment" > "$TEST_TMP/environment-filtered"
      ;;
    *) cat "$environment" > "$TEST_TMP/environment-filtered" ;;
  esac
  if grep -aFq -f "$TEST_TMP/secrets" "$TEST_TMP/environment-filtered"; then
    environment_leaks=$((environment_leaks + 1))
  fi
done < <(find "$RECORD" -type f -name environment)
while IFS= read -r overrides; do
  [ ! -s "$overrides" ] || git_leaks=$((git_leaks + 1))
done < <(find "$RECORD" -type f -name git-overrides)
while IFS= read -r url; do
  if grep -q '^http://' "$url" && ! grep -q '^http://localhost/' "$url"; then public_http=$((public_http + 1)); fi
done < <(find "$RECORD" -type f -name url)
assert 'all recorded local and remote argument vectors contain no fixture secret' test "$argv_leaks" -eq 0
assert 'all recorded environments contain no fixture secret except SSH transport SSHPASS' test "$environment_leaks" -eq 0
assert 'all operator stdout and stderr contain no fixture secret' test "$output_leaks" -eq 0
assert 'all transport processes discard inherited Git overrides' test "$git_leaks" -eq 0
assert 'no curl request sends plaintext credentials to a public IP' test "$public_http" -eq 0
assert 'jq argument vectors and environments were included in the audit' test "$(find "$RECORD" -type d -name '*-jq' | wc -l | tr -d ' ')" -gt 0
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
