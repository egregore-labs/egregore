#!/usr/bin/env bash
# A key retired in the October 2026 security reset renews on its own and the
# greeting says so once; a missing or rejected GitHub sign-in says what to run
# until renewal works. Healthy starts make no network call. Every runtime
# (Claude, Codex, Pi, Prime) reaches the same detection, retry and renderer.
# An egregore.json still naming the retired hosted origin renews through the
# hosted API and never sends the GitHub token or key to the retired host.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; return 0; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
OLD_KEY="ek_acme_retiredretiredretiredretired00"
NEW_KEY="ek_acme_renewedrenewedrenewedrenewed00"

echo "Testing: hosted key renewal after the security reset"
echo ""

# --- fixture: a hosted API stand-in that logs every request -----------------------
mkdir -p "$SCRATCH/stubs" "$SCRATCH/home"
cat > "$SCRATCH/stubs/curl" <<'STUB'
#!/usr/bin/env bash
url="" auth="" write_out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H) case "$2" in "Authorization: Bearer "*) auth="${2#Authorization: Bearer }" ;; esac; shift 2 ;;
    -w|--write-out) write_out="$2"; shift 2 ;;
    -d|--data|--max-time|--connect-timeout|-X) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  https://api.example.test/*) printf '%s\n' "${url#https://api.example.test}" >> "$KEY_TEST_LOG" ;;
  https://api.egregore.xyz/*) printf 'hosted:%s\n' "${url#https://api.egregore.xyz}" >> "$KEY_TEST_LOG" ;;
  *) printf 'elsewhere:%s\n' "$url" >> "$KEY_TEST_LOG"; exit 91 ;;
esac
code=500 body='{"detail":"unexpected"}'
case "$url" in
  */api/org/status|*/api/user/ensure)
    if [ "$auth" = "$KEY_TEST_NEW" ] || [ "${KEY_TEST_OLD_WORKS:-0}" = 1 ]; then
      code=200 body='{"org_id":"org_fixture","slug":"acme","status":"fixture-no-reconcile"}'
    else
      code=401 body="{\"detail\":\"retired\",\"code\":\"${KEY_TEST_CODE-key_retired}\"}"
    fi ;;
  */api/org/acme/key)
    if [ "${KEY_TEST_GITHUB:-ok}" = ok ] && [ "$auth" = gh-fixture-token ]; then
      code=200 body="{\"api_key\":\"${KEY_TEST_ROUTE_KEY:-$KEY_TEST_NEW}\",\"org_slug\":\"acme\",\"renewed\":true}"
    else
      code=401 body='{"detail":"Invalid GitHub token"}'
    fi ;;
esac
printf '%s' "$body"
[ -z "$write_out" ] || printf '\n%s' "$code"
STUB
cat > "$SCRATCH/stubs/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'auth status') exit 0 ;;
  'api user --jq {login,id,name,email}') printf '%s\n' '{"login":"member","id":42,"name":"Member","email":null}' ;;
  *) exit 1 ;;
esac
STUB
chmod 700 "$SCRATCH/stubs/curl" "$SCRATCH/stubs/gh"

INST="$SCRATCH/instance"
reset_instance() {  # reset_instance [env lines...]
  rm -rf "$INST"
  mkdir -p "$INST/bin"
  cp -R "$ROOT/bin/lib" "$INST/bin/"
  cp -R "$ROOT/egregore_runtime" "$INST/"
  cp "$ROOT/bin/runtime-identity.sh" "$ROOT/bin/person.sh" "$ROOT/bin/person.py" "$INST/bin/"
  jq -n --arg url "${KEY_TEST_API_URL:-https://api.example.test}" \
    '{mode:"connected",api_url:$url,slug:"acme",org_name:"Acme",org_id:"org_fixture"}' > "$INST/egregore.json"
  printf '%s\n' '{"github_username":"member","github_id":42,"display_name":"Member","account_id":"acct_fixture","actor_id":"actor_fixture","membership_id":"membership_fixture","onboarding_complete":true}' > "$INST/.egregore-state.json"
  printf '%s\n' "$@" > "$INST/.env"
  : > "$SCRATCH/log"
}

run() {  # run <script> <args...>  (extra environment via KEY_TEST_* exports)
  env -i PATH="$SCRATCH/stubs:$PATH" HOME="$SCRATCH/home" LC_ALL=C PYTHONDONTWRITEBYTECODE=1 \
    EGREGORE_GRAPH_PROJECTION=0 KEY_TEST_LOG="$SCRATCH/log" KEY_TEST_NEW="$NEW_KEY" \
    KEY_TEST_GITHUB="${KEY_TEST_GITHUB:-ok}" KEY_TEST_OLD_WORKS="${KEY_TEST_OLD_WORKS:-0}" \
    ${KEY_TEST_CODE+KEY_TEST_CODE="$KEY_TEST_CODE"} ${KEY_TEST_ROUTE_KEY+KEY_TEST_ROUTE_KEY="$KEY_TEST_ROUTE_KEY"} \
    bash "$INST/bin/$1" "${@:2}" >/dev/null 2>&1
}

notice() { jq -r '.hosted_key_notice.state // "none"' "$INST/.egregore-state.json"; }
key() { grep '^EGREGORE_API_KEY=' "$INST/.env" | cut -d= -f2-; }
calls() { tr '\n' ' ' < "$SCRATCH/log" | sed 's/ $//'; }
footer() {
  env -i PATH="$PATH" HOME="$SCRATCH/home" LOCAL_MODE="${1:-false}" STATE_FILE="$INST/.egregore-state.json" \
    HEALTH_GITHUB=ok HEALTH_GIT=ok HEALTH_RETRIEVAL=ok \
    bash -c 'source "$0"; _render_health_footer' "$ROOT/bin/lib/health-footer.sh"
}
joined() { sed -e 's/^ *//' | tr '\n' ' ' | sed 's/ $//'; }

RENEWED_COPY="↻ Hosted services renewed this organization's key after the October security reset. Your memory, files and history are untouched."
SIGN_IN_COPY="◐ Hosted services need a fresh key after the October security reset. Your memory, files and history are untouched. Run bash bin/github-auth.sh and start a new session — it renews on its own."

# --- healthy starts stay local ---------------------------------------------------------
reset_instance "EGREGORE_API_KEY=$OLD_KEY" "GITHUB_TOKEN=gh-fixture-token"
run runtime-identity.sh ensure
[ -z "$(calls)" ] && pass "a resolved start makes no network call" || fail "healthy start called the network" "$(calls)"

# --- the session's existing identity sync detects the retired key and renews ----------------
run person.sh sync
[ "$(key)" = "$NEW_KEY" ] && pass "person sync's rejected call renews and installs the key" || fail "key not renewed by person sync" "$(calls)"
[ "$(calls)" = "/api/user/ensure /api/org/acme/key /api/org/status" ] \
  && pass "renewal rides the existing call, then verifies once" || fail "unexpected requests" "$(calls)"
[ "$(notice)" = renewed ] && pass "renewal records a one-time notice" || fail "renewed notice missing" "$(notice)"
grep -q "^GITHUB_TOKEN=gh-fixture-token$" "$INST/.env" && pass "other .env entries are preserved" || fail ".env lost the GitHub token"

out="$(footer)"
[ "$(printf '%s\n' "$out" | grep -v '✓' | joined)" = "$RENEWED_COPY" ] \
  && pass "the greeting shows the renewal copy" || fail "renewal copy" "$out"
grep -q '^  ✓ ready' <<< "$out" && pass "a renewed key leaves the card ready" || fail "ready line after renewal" "$out"
out="$(footer)"
[ "$out" = "  ✓ ready" ] && pass "the renewal notice shows once" || fail "renewal notice repeated" "$out"
[ "$(notice)" = none ] && pass "showing the notice clears it" || fail "notice not cleared" "$(notice)"

# --- a missing GitHub sign-in asks for one, each session, without extra calls -----------------
reset_instance "EGREGORE_API_KEY=$OLD_KEY"
run runtime-identity.sh recover key_retired
[ "$(notice)" = needs_sign_in ] && pass "a missing sign-in records the sign-in notice" || fail "missing sign-in notice" "$(notice)"
[ -z "$(calls)" ] && pass "a missing sign-in needs no network call" || fail "missing sign-in called" "$(calls)"
out="$(footer)"
[ "$(printf '%s\n' "$out" | grep -v '✓' | joined)" = "$SIGN_IN_COPY" ] \
  && pass "the greeting names the sign-in command" || fail "sign-in copy" "$out"
grep -q '^  ✓ local checks ready' <<< "$out" \
  && pass "the card says only local checks are ready" || fail "ready line with sign-in notice" "$out"
[ "$(footer)" = "$out" ] && pass "the sign-in notice repeats until fixed" || fail "sign-in notice did not repeat"
grep -q '^ENV_FILE="$SCRIPT_DIR/.env"$' "$ROOT/bin/github-auth.sh" \
  && grep -q 'echo "GITHUB_TOKEN=$access_token"' "$ROOT/bin/github-auth.sh" \
  && pass "the named command refreshes GITHUB_TOKEN in this repo" || fail "bin/github-auth.sh does not refresh GITHUB_TOKEN"

: > "$SCRATCH/log"
run runtime-identity.sh recover key_retired
[ -z "$(calls)" ] && pass "a later rejection in the same state waits for session start" || fail "duplicate recovery" "$(calls)"

# Following the advice: a fresh sign-in, then a new session renews before the greeting.
printf '%s\n' "GITHUB_TOKEN=gh-fixture-token" >> "$INST/.env"
run runtime-identity.sh ensure
[ "$(key)" = "$NEW_KEY" ] && [ "$(notice)" = renewed ] \
  && pass "the next start renews after a fresh sign-in" || fail "start did not renew" "$(notice) $(calls)"
[ "$(calls)" = "/api/org/status /api/org/acme/key /api/org/status" ] \
  && pass "the retry reuses the status probe" || fail "unexpected retry requests" "$(calls)"

# --- a rejected GitHub sign-in is the same remedy ---------------------------------------------
reset_instance "EGREGORE_API_KEY=$OLD_KEY" "GITHUB_TOKEN=gh-expired-token"
KEY_TEST_GITHUB=rejected run person.sh sync
[ "$(notice)" = needs_sign_in ] && [ "$(key)" = "$OLD_KEY" ] \
  && pass "a rejected sign-in records the sign-in notice and keeps the old key" || fail "rejected sign-in" "$(notice) $(key)"

# A key that works again (renewed elsewhere) clears the notice with one probe.
KEY_TEST_OLD_WORKS=1
: > "$SCRATCH/log"
run runtime-identity.sh ensure
[ "$(notice)" = none ] && [ "$(calls)" = "/api/org/status" ] \
  && pass "a working key clears the sign-in notice" || fail "working key" "$(notice) $(calls)"
unset KEY_TEST_OLD_WORKS

# --- other refusals stay quiet -----------------------------------------------------------------
reset_instance "EGREGORE_API_KEY=ek_acme_wrongwrongwrongwrongwrongwr00"
KEY_TEST_CODE="" run runtime-identity.sh recover ""
[ "$(notice)" = none ] && pass "a refusal that is not the reset adds no notice" || fail "unrelated refusal noticed" "$(notice)"
printf '%s\n' '{"hosted_key_notice":{"state":"needs_sign_in"}}' > "$INST/.egregore-state.json"
[ "$(footer true)" = "  ✓ ready" ] && pass "local mode never shows a hosted key notice" || fail "local mode notice" "$(footer true)"

# --- a renewed key is checked before it replaces the saved one ---------------------------------
reset_instance "EGREGORE_API_KEY=$OLD_KEY" "GITHUB_TOKEN=gh-fixture-token"
KEY_TEST_ROUTE_KEY="ek_other_foreignforeignforeignforeign00" run person.sh sync
[ "$(key)" = "$OLD_KEY" ] && pass "a key naming another org is never installed" || fail "foreign key installed" "$(key)"
[ "$(notice)" = renewed ] && fail "foreign key reported as renewed" || pass "a foreign key adds no renewal notice"
reset_instance "EGREGORE_API_KEY=$OLD_KEY" "GITHUB_TOKEN=gh-fixture-token"
KEY_TEST_ROUTE_KEY="ek_acme_doesnotworkdoesnotworkdoesnot00" run person.sh sync
[ "$(key)" = "$OLD_KEY" ] && pass "a key that fails its check is never installed" || fail "unverified key installed" "$(key)"

# --- a saved retired address renews through the hosted API -------------------------------------
# Connected setups before the October reset saved the retired Railway origin;
# that is exactly where the way back has to work.
KEY_TEST_API_URL="https://egregore-production-55f2.up.railway.app/"
reset_instance "EGREGORE_API_KEY=$OLD_KEY" "GITHUB_TOKEN=gh-fixture-token"
run person.sh sync
[ "$(calls)" = "hosted:/api/user/ensure hosted:/api/org/acme/key hosted:/api/org/status" ] \
  && pass "person sync's 401 path renews through the hosted API" || fail "unexpected requests from a retired address" "$(calls)"
[ "$(key)" = "$NEW_KEY" ] && [ "$(notice)" = renewed ] \
  && pass "the way back works from a saved retired address" || fail "no renewal from a retired address" "$(notice) $(calls)"
reset_instance "EGREGORE_API_KEY=$OLD_KEY" "GITHUB_TOKEN=gh-fixture-token"
run runtime-identity.sh recover key_retired
[ "$(calls)" = "hosted:/api/org/acme/key hosted:/api/org/status" ] && [ "$(key)" = "$NEW_KEY" ] \
  && pass "recover asks the hosted API for the key" || fail "recover from a retired address" "$(calls)"
printf '%s\n' '{"hosted_key_notice":{"state":"needs_sign_in"},"account_id":"acct_fixture","actor_id":"actor_fixture","membership_id":"membership_fixture"}' > "$INST/.egregore-state.json"
KEY_TEST_OLD_WORKS=1
: > "$SCRATCH/log"
run runtime-identity.sh ensure
[ "$(calls)" = "hosted:/api/org/status" ] && pass "the start-time retry probes the hosted API" || fail "ensure from a retired address" "$(calls)"
unset KEY_TEST_OLD_WORKS
KEY_TEST_API_URL="https://egregore.example.org"
reset_instance "EGREGORE_API_KEY=$OLD_KEY" "GITHUB_TOKEN=gh-fixture-token"
run runtime-identity.sh recover key_retired
[ "$(calls)" = "elsewhere:https://egregore.example.org/api/org/acme/key" ] \
  && pass "a custom origin is used as saved" || fail "custom origin rewritten" "$(calls)"
# An address that is not plain is refused: no request at all, and the key stays.
odd_sent=""
for KEY_TEST_API_URL in 'https://selfhost.example\@egregore-production-55f2.up.railway.app/' \
  'https://%65gregore-production-55f2.up.railway.app' 'http://egregore-production-55f2.up.railway.ap{p,p}' \
  "$(printf 'https://egregore-produc\302\255tion-55f2.up.railway.app')"; do
  for step in "runtime-identity.sh recover key_retired" "runtime-identity.sh ensure" "person.sh sync"; do
    reset_instance "EGREGORE_API_KEY=$OLD_KEY" "GITHUB_TOKEN=gh-fixture-token"
    # shellcheck disable=SC2086 # the step is a script and its arguments
    run $step
    [ -z "$(calls)" ] && [ "$(key)" = "$OLD_KEY" ] || odd_sent="$odd_sent [$step $KEY_TEST_API_URL: $(calls)]"
  done
done
[ -z "$odd_sent" ] && pass "an address that is not plain sends nothing on recover, ensure or sync" \
  || fail "a refused address sent a request" "$odd_sent"
unset KEY_TEST_API_URL
grep -q 'railway' "$SCRATCH/log" && fail "a request reached the retired host" "$(calls)" \
  || pass "no request reached the retired host"

# --- every runtime reaches the same detection, retry and renderer -------------------------------
for entry in bin/session-start.sh bin/codex-session-start.sh; do
  grep -q 'runtime-identity.sh" ensure' "$ROOT/$entry" && grep -q 'person.sh" sync' "$ROOT/$entry" \
    && pass "$entry retries at start and syncs identity" || fail "$entry misses the retry or the sync"
done
grep -q '_render_health_footer' "$ROOT/bin/lib/greeting.sh" && grep -q '_render_health_footer' "$ROOT/bin/codex-session-start.sh" \
  && pass "Claude and Codex greetings render the shared footer" || fail "a greeting bypasses the shared footer"
for entry in bin/pi-session-start.sh bin/prime-session-start.sh; do
  grep -q 'exec bash "$SCRIPT_DIR/bin/codex-session-start.sh" --card' "$ROOT/$entry" \
    && pass "$entry renders through the Codex card" || fail "$entry has its own card"
done
stale=""
for runtime in claude codex pi prime; do
  for file in bin/runtime-identity.sh bin/person.sh bin/lib/health-footer.sh; do
    packaged="$ROOT/packages/create-egregore/runtime/$runtime/$file"
    [ ! -f "$packaged" ] || cmp -s "$ROOT/$file" "$packaged" || stale="$stale $runtime/$file"
  done
done
[ -z "$stale" ] && pass "packaged runtime copies match their sources" \
  || fail "stale packaged copies; rebuild the runtime bundles" "$stale"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
