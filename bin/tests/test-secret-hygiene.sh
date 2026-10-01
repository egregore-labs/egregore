#!/usr/bin/env bash
# Shared credential-flow regression gate. All fixtures, logs and stubs live in
# mktemp; no developer credentials, HOME, runtime state or network are used.
set +x
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/bin/tests/secret-hygiene.manifest"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/secret-hygiene.XXXXXX")
trap 'rm -rf -- "$SCRATCH"' EXIT
trap 'exit 1' HUP INT TERM
FAIL=0
PROBES=0
COVERED=0
EXEMPT=0
ORIGINAL_PATH="$PATH"

# The synthetic approval token is hex because notify validates plan/token IDs.
# Stub logs live beside the fixture so argv evidence is never mistaken for an
# application-created secret file. Logs are private and deleted by the trap.
cat > "$SCRATCH/canaries" <<'CANARIES'
canary-api-key-7f3a9c
canary-github-token-2b8e1d
canary-slack-token-43e19a
ca7a1234567890abcdef1234567890abcd
CANARIES


bad() {
  printf '%s\n' "$*" | awk 'NR == FNR { secrets[++n] = $0; next }
    { for (i = 1; i <= n; i++) gsub(secrets[i], "[REDACTED]", $0)
      print "FAIL secret-hygiene: " $0 }
  ' "$SCRATCH/canaries" - >&2
  FAIL=$((FAIL + 1))
}
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Enumeration patterns: _load_env_var definitions/calls; anchored grep key
# reads of literal .env or shell aliases; cat, source/dot and input
# redirection of those paths; awk getline from an envfile parameter; calls
# to the credential-reading api-call helper. Join shell continuations first.
# Mere .env comments, existence tests, writes and symlink names are not reads.
# config-get.sh was inspected: it reads JSON only; importing lib/config.sh
# alone does not invoke its credential reader.
credential_reader() {
  awk '
    function env_reference(text, name) {
      if (text ~ /[.]env([^[:alnum:]_]|$)/ ||
          text ~ /\$\{?_?[Ee][Nn][Vv]_[Ff][Ii][Ll][Ee]([^[:alnum:]_]|$)/) return 1
      for (name in aliases)
        if (text ~ ("\\$\\{?" name "([^[:alnum:]_]|$)")) return 1
      return 0
    }
    /^[[:space:]]*#/ { next }
    { line = line $0 }
    /\\$/ { sub(/\\$/, " ", line); next }
    {
      lines[++count] = line
      # Track custom aliases such as credential_file="$ROOT/.env" as well as
      # ENV_FILE aliases inherited by sourced helpers. This is lexical shell
      # inspection, not evaluation of scripts or arbitrary dataflow analysis.
      rest = line
      while (match(rest, /[[:alpha:]_][[:alnum:]_]*=[^;]*[.]env([^[:alnum:]_]|$)/)) {
        assignment = substr(rest, RSTART, RLENGTH)
        sub(/=.*/, "", assignment)
        aliases[assignment] = 1
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (line ~ /[.]env([^[:alnum:]_]|$)/) env_path = 1
      line = ""
    }
    END {
      for (i = 1; i <= count; i++) {
        line = lines[i]
        if (line ~ /_load_env_var[[:space:](]/) found = 1
        if (line ~ /(^|[^[:alnum:]_])grep[[:space:]]/ &&
            line ~ /[[:space:]\047"]\^[^[:space:]\047"]*=/ && env_reference(line)) found = 1
        if (line ~ /(^|[;&()[:space:]])(source|[.])[[:space:]]/ && env_reference(line)) found = 1
        input = line
        sub(/>.*/, "", input)
        if (input ~ /(^|[;&()[:space:]])cat[[:space:]]/ && env_reference(input)) found = 1
        if (line ~ /(^|[^<])<[[:space:]]*[^<]/ && env_reference(line)) found = 1
        if (env_path && line ~ /getline[[:space:]][^;]*<[[:space:]]*[Ee][Nn][Vv][Ff][Ii][Ll][Ee]/) found = 1
        if (line ~ /bash[[:space:]]+[^;&]*bin\/api-call[.]sh/) found = 1
      }
      exit !found
    }
  ' "$1"
}

[ -f "$MANIFEST" ] || { bad 'manifest is absent'; exit 1; }
: > "$SCRATCH/computed"
for path in "$ROOT"/bin/*.sh "$ROOT"/bin/lib/*.sh; do
  [ -f "$path" ] || continue
  case "${path##*/}" in test-*) continue ;; esac
  if credential_reader "$path"; then printf '%s\n' "${path#"$ROOT"/}" >> "$SCRATCH/computed"; fi
done
LC_ALL=C sort -o "$SCRATCH/computed" "$SCRATCH/computed"
: > "$SCRATCH/records"
: > "$SCRATCH/registered"
while IFS= read -r line || [ -n "$line" ]; do
  line=$(trim "${line%%#*}")
  [ -n "$line" ] || continue
  if [ "$(printf '%s\n' "$line" | awk -F '|' '{print NF}')" -ne 5 ]; then
    bad 'manifest record must have five | separated fields'; continue
  fi
  IFS='|' read -r script mode invocation expects notes <<< "$line"
  script=$(trim "$script"); mode=$(trim "$mode"); invocation=$(trim "$invocation")
  expects=$(trim "$expects"); notes=$(trim "$notes")
  if grep -Fxq "$script" "$SCRATCH/registered"; then
    bad "$script has duplicate manifest records; keep exactly one"; continue
  fi
  printf '%s\n' "$script" >> "$SCRATCH/registered"
  if ! grep -Fxq "$script" "$SCRATCH/computed"; then
    bad "$script has a stale manifest entry; remove its manifest line or restore its credential read"
  fi
  case "$mode" in
    covered)
      COVERED=$((COVERED + 1))
      case "$invocation" in tests/*.sh|bin/tests/*.sh) ;; *) bad "$script has an invalid dedicated suite path"; continue ;; esac
      if [ ! -f "$ROOT/$invocation" ] || ! bash -n "$ROOT/$invocation"; then
        bad "$script dedicated suite is missing or fails bash -n: $invocation"
      fi
      ;;
    exempt)
      EXEMPT=$((EXEMPT + 1))
      if ! grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}: [^[:space:]].+' <<< "$notes"; then
        bad "$script exemption needs YYYY-MM-DD: reason"
      fi
      ;;
    probe)
      case "$invocation" in "bash $script "*) ;; *) bad "$script probe must invoke its script with bash" ;; esac
      printf '%s|%s|%s\n' "$script" "$invocation" "$expects" >> "$SCRATCH/records"
      ;;
    *) bad "$script has invalid mode: $mode" ;;
  esac
done < "$MANIFEST"
while IFS= read -r script; do
  if ! grep -Fxq "$script" "$SCRATCH/registered"; then
    bad "$script is missing from the manifest; add a covered/probe/exempt line or remove its credential read"
  fi
done < "$SCRATCH/computed"
printf 'secret-hygiene: %s credential-bearing scripts; %s exempt\n' "$(wc -l < "$SCRATCH/computed" | tr -d ' ')" "$EXEMPT"
[ "$FAIL" -eq 0 ] || exit 1


# Print unexpected stderr without ever disclosing a canary, even on regression.
redact() {
  awk 'NR == FNR { secrets[++n] = $0; next }
    { for (i = 1; i <= n; i++) gsub(secrets[i], "[REDACTED]", $0); print "    " $0 }
  ' "$SCRATCH/canaries" "$1" >&2
}

make_stubs() {
  mkdir -p "$PROBE_DIR/stubs"
  cat > "$PROBE_DIR/stubs/tool" <<'STUB'
#!/usr/bin/env bash
set +x
set -euo pipefail
name=${0##*/}
caller_umask=$(umask)
umask 077
# Each invocation has its own NUL-delimited argv record, including empty args.
record=$(mktemp "$HYGIENE_RECORD/$name.XXXXXX")
printf '%s\0' "$@" > "$record"
case "$name" in
  curl)
    printf '%s\n' "${1-}" >> "$HYGIENE_RECORD/curl-first"
    [ "${1-}" = -q ] || { echo 'curl stub: -q must be first' >&2; exit 90; }
    output=''; write_out=''; url=''; headers=''; fail_http=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output|-o) output="$2"; shift 2 ;;
        --write-out|-w) write_out="$2"; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        --fail) fail_http=true; shift ;;
        --request|-X|--max-time|--data|-d|--data-binary) shift 2 ;;
        -H|--header)
          if [ "$2" = @- ]; then headers="$headers$(cat)"; else headers="$headers $2"; fi
          shift 2 ;;
        http*) url="$1"; shift ;;
        -[!-]*)
          case "${1#-}" in *f*) fail_http=true ;; esac
          shift ;;
        *) shift ;;
      esac
    done
    # Slack is the one third-party destination an org-owned token reaches
    # directly; everything else must stay on the fixture control plane.
    case "$url" in
      https://api.example.test/*|https://slack.com/api/auth.test) ;;
      *) echo 'curl stub: unexpected destination' >&2; exit 91 ;;
    esac
    case "$url" in
      */api/hosting/status/parity) expected=canary-github-token-2b8e1d; body='{"status":"ready"}' ;;
      */api/user/ensure) expected=canary-api-key-7f3a9c; body='{"status":"fixture-no-reconcile"}' ;;
      */api/notify/group) expected=canary-api-key-7f3a9c; body='{"status":"sent"}' ;;
      https://slack.com/api/auth.test) expected=canary-slack-token-43e19a
        body='{"ok":true,"team":"Parity","url":"https://parity.slack.com/","user":"egregore"}' ;;
      *) echo 'curl stub: unexpected credential path' >&2; exit 91 ;;
    esac
    case "$headers" in *"Authorization: Bearer $expected"*) : > "$HYGIENE_RECORD/credential-used" ;;
      *) echo 'curl stub: fixture credential was not used' >&2; exit 92 ;; esac
    code=200
    case "$HYGIENE_FAILURE" in
      transport)
        echo 'curl: (7) fixture connection failed' >&2
        exit 7 ;;
      http)
        if [ "$fail_http" = true ]; then
          echo 'curl: (22) fixture HTTP 500' >&2
          exit 22
        fi
        code=500
        body='{"error":"stubbed"}' ;;
    esac
    # Restore the caller mask only for its response; instrumentation is private.
    if [ -n "$output" ]; then
      umask "$caller_umask"
      printf '%s\n' "$body" > "$output"
      umask 077
      # Observe temporary responses before the script can delete them.
      stat -c '%a' "$output" 2>/dev/null >> "$HYGIENE_RECORD/response-modes" ||
        stat -f '%Lp' "$output" >> "$HYGIENE_RECORD/response-modes"
    fi
    if [ -z "$output" ]; then printf '%s\n' "$body"; fi
    if [ -n "$write_out" ]; then printf '%s' "$code"; fi
    ;;
  gh)
    case "$*" in
      'auth status')
        [ "${GITHUB_TOKEN:-}" = canary-github-token-2b8e1d ] || { echo 'gh stub: fixture token missing' >&2; exit 92; }
        : > "$HYGIENE_RECORD/credential-used"
        [ "$HYGIENE_FAILURE" = 0 ] || exit 1
        ;;
      'api user --jq {login,id,name,email}')
        [ "$HYGIENE_FAILURE" = 0 ] || exit 1
        printf '%s\n' '{"login":"parity","id":7,"name":"Parity","email":"parity@example.test"}' ;;
      *) echo 'gh stub: unexpected command' >&2; exit 91 ;;
    esac
    ;;
  openssl)
    [ "$*" = 'rand -hex 16' ] || exit 91
    [ "$HYGIENE_FAILURE" != approval ] || exit 1
    printf '%s\n' ca7a1234567890abcdef1234567890abcd
    ;;
  ssh|scp) [ "$HYGIENE_FAILURE" = 0 ] || exit 255 ;;
  sshpass) [ "$HYGIENE_FAILURE" = 0 ] || exit 255 ;;
  *) echo 'unexpected network/credential tool blocked by fixture' >&2; exit 93 ;;
esac
STUB
  chmod 700 "$PROBE_DIR/stubs/tool"
  for tool in curl gh ssh scp sshpass openssl git wget nc netcat; do
    cp "$PROBE_DIR/stubs/tool" "$PROBE_DIR/stubs/$tool"
  done
}

make_fixture() {
  rm -rf -- "$PROBE_DIR/fixture" "$PROBE_DIR/record"
  FIXTURE="$PROBE_DIR/fixture"
  CHECKOUT="$FIXTURE/checkout"
  mkdir -p "$CHECKOUT/bin" "$CHECKOUT/tmp" "$FIXTURE/home" "$FIXTURE/tmp" "$PROBE_DIR/record"
  cp -R "$ROOT/bin/lib" "$CHECKOUT/bin/"
  cp -R "$ROOT/egregore_runtime" "$CHECKOUT/"
  cp "$ROOT/$SCRIPT" "$CHECKOUT/$SCRIPT"
  cat > "$CHECKOUT/egregore.json" <<'CONFIG'
{"mode":"connected","api_url":"https://api.example.test","slug":"parity","org_name":"Parity"}
CONFIG
  cat > "$CHECKOUT/.env" <<'ENV'
EGREGORE_API_KEY=canary-api-key-7f3a9c
GITHUB_TOKEN=canary-github-token-2b8e1d
SLACK_BOT_TOKEN=canary-slack-token-43e19a
EGREGORE_API_URL=https://api.example.test
ENV
  printf '%s\n' 'header = "X-Canary: curlrc-leak"' > "$FIXTURE/home/.curlrc"
  case "$SCRIPT" in
    bin/hosting-ops.sh)
      cp "$ROOT/bin/api-call.sh" "$ROOT/bin/config-get.sh" "$CHECKOUT/bin/" ;;
    bin/person.sh)
      # person.py is a stdlib-only local reconciler, not a network entry point.
      # A non-ok fixed API response avoids calling identity_cli afterwards.
      cp "$ROOT/bin/person.py" "$CHECKOUT/bin/"
      printf '%s\n' '{"github_username":"parity","github_id":7,"display_name":"Parity"}' > "$CHECKOUT/.egregore-state.json" ;;
    bin/notify.sh)
      mkdir -p "$CHECKOUT/notifications"
      printf '%s\n' secret-hygiene-session > "$CHECKOUT/.egregore-session-id"
      # Replace background telemetry, which is outside the credential flow.
      printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$CHECKOUT/bin/telemetry.sh"
      cat > "$CHECKOUT/notifications/abcd.json" <<'PLAN'
{"version":1,"id":"abcd","session_id":"secret-hygiene-session","mode":"connected","org_slug":"parity","org_name":"Parity","kind":"group","recipient":null,"message":"Fixture message","channels":["telegram"],"deliveries":[{"channel":"telegram","destination":"fixture","kind":"group"}],"no_fallback":true,"expires_at":4102444800,"server_plan_token":"fixture-plan","status":"proposed"}
PLAN
      NOTIFY_DIGEST=$(jq -cS 'del(.status)' "$CHECKOUT/notifications/abcd.json" | shasum -a 256 | awk '{print $1}')
      jq --arg digest "$NOTIFY_DIGEST" '. + {digest:$digest}' "$CHECKOUT/notifications/abcd.json" > "$PROBE_DIR/plan"
      mv "$PROBE_DIR/plan" "$CHECKOUT/notifications/abcd.json"
      ;;
  esac
}

invoke() {
  local invocation="$1" trace="$2" failure="$3"
  local -a trace_env=()
  case "$trace" in
    inherited) trace_env=(SHELLOPTS=xtrace) ;;
    argument) invocation="${invocation//bash /bash -x }" ;;
  esac
  STATUS=0
  (
    cd "$CHECKOUT"
    # A permissive caller umask is intentional: the script must protect its
    # own writes. env -i excludes developer keys, Git overrides and Python hooks.
    umask 022
    env -i PATH="$PROBE_DIR/stubs:$ORIGINAL_PATH" HOME="$FIXTURE/home" TMPDIR="$FIXTURE/tmp" \
      LC_ALL=C EGREGORE_GRAPH_PROJECTION=0 PYTHONDONTWRITEBYTECODE=1 \
      EGREGORE_NOTIFY_STATE_DIR="$CHECKOUT/notifications" \
      HYGIENE_RECORD="$PROBE_DIR/record" HYGIENE_FAILURE="$failure" \
      NOTIFY_DIGEST="${NOTIFY_DIGEST:-}" ${trace_env[@]+"${trace_env[@]}"} \
      bash -c "$invocation"
  ) > "$PROBE_DIR/stdout" 2> "$PROBE_DIR/stderr" || STATUS=$?
}

inventory() { find "$FIXTURE" -type f -print | LC_ALL=C sort; }
check_files() {
  local label="$1" failure="$2" file mode
  inventory > "$PROBE_DIR/after"
  comm -13 "$PROBE_DIR/before" "$PROBE_DIR/after" > "$PROBE_DIR/new-files"
  while IFS= read -r file; do
    mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")
    case "$mode" in 600|700) ;; *) bad "$SCRIPT $label created ${file#"$FIXTURE"/} with mode $mode" ;; esac
    if [ "$failure" != 0 ] && grep -aFq -f "$SCRATCH/canaries" "$file"; then
      bad "$SCRIPT $label left a new file containing a canary: ${file#"$FIXTURE"/}"
    fi
  done < "$PROBE_DIR/new-files"
}
check_output() {
  if grep -aFq -f "$SCRATCH/canaries" "$PROBE_DIR/stdout" "$PROBE_DIR/stderr"; then
    bad "$SCRIPT $1 leaked a canary to stdout/stderr"
  fi
}
check_curl() {
  if [ -f "$PROBE_DIR/record/curl-first" ]; then
    if grep -vx -- '-q' "$PROBE_DIR/record/curl-first" >/dev/null; then bad "$SCRIPT $1 invoked curl without -q first"; fi
  fi
  if [ -f "$PROBE_DIR/record/response-modes" ] &&
      grep -Ev '^(600|700)$' "$PROBE_DIR/record/response-modes" >/dev/null; then
    bad "$SCRIPT $1 wrote an unsafe temporary response file"
  fi
}

printf 'test-secret-hygiene\n'
while IFS='|' read -r SCRIPT INVOCATION EXPECTS; do
  PROBES=$((PROBES + 1))
  PROBE_DIR="$SCRATCH/probe-$PROBES"
  mkdir -p "$PROBE_DIR"
  make_stubs
  EXPECTED_EXIT=''; OUT='-'
  for expectation in $EXPECTS; do
    case "$expectation" in
      exit=*) EXPECTED_EXIT=${expectation#exit=} ;;
      out=*) OUT=${expectation#out=} ;;
      *) bad "$SCRIPT has invalid expectation: $expectation" ;;
    esac
  done
  case "$EXPECTED_EXIT" in ''|*[!0-9]*) bad "$SCRIPT needs exit=N"; continue ;; esac
  case "$OUT" in ''|/*|..|../*|*/../*|*/..) bad "$SCRIPT output must be relative to the checkout"; continue ;; esac
  before_fail=$FAIL
  curl_seen=false
  for scenario in normal inherited argument http-failure transport-failure; do
    make_fixture
    failure=0
    case "$scenario" in http-failure) failure=http ;; transport-failure) failure=transport ;; esac
    invocation="$INVOCATION"
    failure_out="$OUT"
    if [ "$SCRIPT" = bin/notify.sh ] && [ "$failure" != 0 ]; then
      # A durable approval receipt outside tmp is retained byte-for-byte even
      # after HTTP/transport failure. Scratch consumption has separate tests.
      invoke 'bash bin/notify.sh approve abcd "$NOTIFY_DIGEST" APPROVE_EXACT_NOTIFICATION --out notifications/approval.json' normal 0
      if [ "$STATUS" -ne 0 ]; then bad "$SCRIPT $scenario approval setup failed"; redact "$PROBE_DIR/stderr"; fi
      check_output "$scenario-setup"
      cp "$CHECKOUT/$OUT" "$PROBE_DIR/approval-before"
      invocation='bash bin/notify.sh dispatch abcd --approval-file notifications/approval.json'
      failure_out=-
    fi
    inventory > "$PROBE_DIR/before"
    invoke "$invocation" "$scenario" "$failure"
    check_output "$scenario"
    check_curl "$scenario"
    check_files "$scenario" "$failure"
    if [ -f "$PROBE_DIR/record/curl-first" ]; then curl_seen=true; fi
    if [ "$failure" = 0 ]; then
      if [ "$STATUS" -ne "$EXPECTED_EXIT" ]; then
        bad "$SCRIPT $scenario exited $STATUS; expected $EXPECTED_EXIT"
        redact "$PROBE_DIR/stderr"
      fi
      if [ ! -f "$PROBE_DIR/record/credential-used" ]; then bad "$SCRIPT $scenario did not use its fixture credential"; fi
      if [ "$OUT" != - ] && [ ! -f "$CHECKOUT/$OUT" ]; then bad "$SCRIPT $scenario did not create $OUT"; fi
    elif [ "$failure_out" != - ] && [ -e "$CHECKOUT/$failure_out" ]; then
      bad "$SCRIPT $scenario left output $failure_out"
    fi
    if [ "$failure" != 0 ] && [ ! -f "$PROBE_DIR/record/credential-used" ]; then
      bad "$SCRIPT $scenario did not reach the credentialed tool"
    fi
    if [ "$SCRIPT" = bin/notify.sh ] && [ "$failure" != 0 ]; then
      [ "$STATUS" -ne 0 ] || bad "$SCRIPT $scenario unexpectedly succeeded"
      cmp -s "$PROBE_DIR/approval-before" "$CHECKOUT/$OUT" || bad "$SCRIPT $scenario changed its durable approval receipt"
    fi
  done
  if [ "$SCRIPT" = bin/notify.sh ]; then
    # Both dispatch failure runs reach curl after approving. Separately fail the
    # approval credential generator, including replacement of a stale output.
    make_fixture
    printf '%s\n' 'stale receipt' > "$CHECKOUT/$OUT"
    inventory > "$PROBE_DIR/before"
    invoke "$INVOCATION" normal approval
    [ "$STATUS" -ne 0 ] || bad "$SCRIPT approval accepted a failed token generator"
    [ ! -e "$CHECKOUT/$OUT" ] || bad "$SCRIPT approval failure left output $OUT"
    check_output approval-failure
    check_curl approval-failure
    check_files approval-failure 1
  fi
  if [ "$FAIL" -eq "$before_fail" ]; then
    if [ "$curl_seen" = true ]; then curl_result='-q first'; else curl_result='no curl calls (vacuous)'; fi
    printf 'PASS %s: tracing; curlrc %s; private files; no partial output (HTTP failure + transport failure)\n' "$SCRIPT" "$curl_result"
  fi
done < "$SCRATCH/records"
printf 'secret-hygiene: %s probes; %s covered; %s exempt; %s failures\n' "$PROBES" "$COVERED" "$EXEMPT" "$FAIL"
[ "$FAIL" -eq 0 ]
