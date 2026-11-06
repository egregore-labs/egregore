#!/usr/bin/env bash
# Hosting preferences are not proof of connected access. Run the real settings
# script in temporary instances; no customer files, credentials, or network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-settings-hosting.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/instance"
mkdir -p "$FIX/bin" "$WORK/shim"
cp "$ROOT/bin/settings.sh" "$FIX/bin/"
mkdir -p "$FIX/bin/lib" && cp "$ROOT/bin/lib/config.sh" "$FIX/bin/lib/config.sh"
cat > "$WORK/shim/curl" <<'SHIM'
#!/usr/bin/env bash
printf 'unexpected network call\n' >> "$HOSTING_TEST_NETWORK_LOG"
exit 99
SHIM
chmod +x "$WORK/shim/curl"

PASS=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null; then
    PASS=$((PASS+1))
    printf '  ✓ %s\n' "$label"
  else
    printf '  ✗ %s\n' "$label" >&2
    exit 1
  fi
}

settings() {
  env -i PATH="$WORK/shim:$PATH" \
    HOSTING_TEST_NETWORK_LOG="$WORK/network.log" \
    HOSTING_TEST_EXEC_LOG="$WORK/env-executed" \
    EGREGORE_API_URL="${TEST_PUBLISH_URL:-}" \
    EGREGORE_API_KEY="${TEST_PUBLISH_KEY:-}" \
    bash "$FIX/bin/settings.sh" "$@"
}

seed() {
  TEST_PUBLISH_URL=""
  TEST_PUBLISH_KEY=""
  printf '%s\n' "$1" > "$FIX/egregore.json"
  rm -f "$FIX/.env"
  if [ "${2+x}" = x ]; then printf '%s\n' "$2" > "$FIX/.env"; fi
}

json_is() { printf '%s' "$SNAP" | jq -e "$1" >/dev/null; }
text_has() { grep -qF -- "$1" <<< "$TEXT"; }
text_omits_relay() { ! grep -Ei 'relay|expir|7 days|seven.day|to publish' <<< "$TEXT"; }
status_is() {
  SNAP=$(settings hosting status --json)
  json_is ".readiness == \"$1\" and .connectivity == \"not_checked\""
}

# Every effective-route fixture checks both read surfaces without touching
# credentials or configuration. Only the fixture's explicit overrides are used.
route_snapshot_is() {
  local expected="$1" saved_env=false
  cp "$FIX/egregore.json" "$WORK/config.before"
  if [ -f "$FIX/.env" ]; then
    cp "$FIX/.env" "$WORK/env.before"
    saved_env=true
  fi
  status_is "$expected" || return 1
  json_is '.connection_configured == false and .public_relay == true and
    keys == ["connection_configured", "connectivity", "domain", "public_relay", "publishing", "readiness", "recovery_command"]' || return 1
  TEXT=$(settings hosting status) || return 1
  case "$expected" in
    setup_incomplete)
      text_has 'Publishing is enabled; connection setup is incomplete.' || return 1
      text_has 'Run: egregore connect acme' || return 1
      text_omits_relay || return 1
      json_is '.recovery_command == "egregore connect acme"' || return 1 ;;
    public_relay)
      text_has 'Anyone with the link can read published artifacts for 7 days.' || return 1
      json_is '.recovery_command == null' || return 1 ;;
    disabled)
      text_has 'Hosting (egregore.xyz): OFF' || return 1
      text_omits_relay || return 1
      json_is '.publishing == false and .recovery_command == null' || return 1 ;;
    *) return 1 ;;
  esac
  DUMP=$(settings dump) || return 1
  jq -en --argjson dump "$DUMP" --argjson status "$SNAP" \
    '$dump.public_relay == true and $dump.hosting == $status.publishing and $dump.hosting_status == $status' >/dev/null || return 1
  cmp -s "$FIX/egregore.json" "$WORK/config.before" || return 1
  if [ "$saved_env" = true ]; then
    cmp -s "$FIX/.env" "$WORK/env.before" || return 1
  else
    test ! -e "$FIX/.env" || return 1
  fi
  ! grep -E 'credential-do-not-print|HOSTING_TEST_EXEC_LOG|env-executed' <<< "$SNAP $TEXT $DUMP" || return 1
  test ! -e "$WORK/env-executed"
}

CONNECTED='{"slug":"acme","mode":"connected","api_url":"https://host.invalid"}'
KEY='EGREGORE_API_KEY=fixture-credential-do-not-print'

seed '{"slug":"acme"}'
check "default publishing preference does not imply configured access" status_is setup_incomplete
check "legacy publishing field and exact recovery command remain available" json_is '.domain == "hosting" and .publishing == true and .connection_configured == false and .public_relay == false and .recovery_command == "egregore connect acme"'
TEXT=$(settings hosting status)
check "plain status names incomplete setup" text_has 'SETUP INCOMPLETE'
check "plain status provides selected-instance recovery" text_has 'Run: egregore connect acme'

seed "$CONNECTED" 'GITHUB_TOKEN=unrelated-fixture-value'
check "connected config without its saved API key stays incomplete" status_is setup_incomplete
for empty_key in 'EGREGORE_API_KEY=' 'EGREGORE_API_KEY=   ' 'EGREGORE_API_KEY=""' "EGREGORE_API_KEY=' '"; do
  seed "$CONNECTED" "$empty_key"
  check "blank or quoted-blank credentials cannot claim configured access" status_is setup_incomplete
done

seed "$CONNECTED" "$KEY"
cp "$FIX/egregore.json" "$WORK/config.before"
cp "$FIX/.env" "$WORK/env.before"
check "saved mode, endpoint, and key report configured access" status_is connected_configured
check "configured access makes no live connectivity claim" json_is '.publishing == true and .connection_configured == true and .recovery_command == null and .connectivity == "not_checked"'
TEXT=$(settings hosting status)
check "plain configured status says connection was not checked" text_has 'Connection not checked.'
DUMP=$(settings dump)
check "dump keeps its preference booleans and shares the same readiness snapshot" \
  jq -en --argjson dump "$DUMP" --argjson status "$SNAP" \
  '$dump.hosting == true and $dump.public_relay == false and $dump.hosting_status == $status'
check "read-only status preserves config bytes" cmp -s "$FIX/egregore.json" "$WORK/config.before"
check "read-only status preserves credential bytes" cmp -s "$FIX/.env" "$WORK/env.before"
check "status and dump never disclose the saved key" bash -c \
  '! printf "%s\n" "$1" "$2" "$3" | grep -qF fixture-credential-do-not-print' \
  _ "$SNAP" "$TEXT" "$DUMP"

seed '{"slug":"acme","api_url":"https://host.invalid"}' "$KEY"
check "legacy endpoint configuration without mode remains supported" status_is connected_configured
for mode in '"local"' '"invalid"' '""' false 1; do
  seed "{\"slug\":\"acme\",\"mode\":$mode,\"api_url\":\"https://host.invalid\"}" "$KEY"
  check "explicit mode $mode cannot claim configured access" status_is setup_incomplete
  seed "{\"slug\":\"acme\",\"mode\":$mode,\"api_url\":\"https://host.invalid\",\"features\":{\"public_relay\":true}}" "$KEY"
  cp "$FIX/egregore.json" "$WORK/config.before"
  cp "$FIX/.env" "$WORK/env.before"
  check "saved credentials with mode $mode take precedence over relay consent" status_is setup_incomplete
  check "conflict preserves preference and recovery fields" json_is '.publishing == true and .connection_configured == false and .public_relay == true and .recovery_command == "egregore connect acme"'
  TEXT=$(settings hosting status)
  check "conflict explains incomplete setup" text_has 'Publishing is enabled; connection setup is incomplete.'
  check "conflict offers recovery" text_has 'Run: egregore connect acme'
  check "conflict makes no relay or expiry promise" text_omits_relay
  DUMP=$(settings dump)
  check "conflict dump keeps preference fields and readiness" \
    jq -en --argjson dump "$DUMP" --argjson status "$SNAP" \
    '$dump.hosting == true and $dump.public_relay == true and $dump.hosting_status == $status'
  check "conflict status preserves config" cmp -s "$FIX/egregore.json" "$WORK/config.before"
  check "conflict status preserves credentials" cmp -s "$FIX/.env" "$WORK/env.before"
done
for endpoint in null '""' '"   "'; do
  seed "{\"slug\":\"acme\",\"mode\":\"connected\",\"api_url\":$endpoint}" "$KEY"
  check "missing or blank endpoint cannot claim configured access" status_is setup_incomplete
done

seed '{"slug":"acme","features":{"public_relay":true}}'
check "explicit relay consent is distinguished from connected access" status_is public_relay
check "relay status does not fabricate connected credentials" json_is '.publishing == true and .connection_configured == false and .public_relay == true and .recovery_command == null'
TEXT=$(settings hosting status)
check "relay status makes its public audience clear" text_has 'Anyone with the link can read published artifacts for 7 days.'
for relay in false '"true"' 1; do
  seed "{\"slug\":\"acme\",\"features\":{\"public_relay\":$relay}}"
  check "relay requires an explicit boolean true" status_is setup_incomplete
done

LOCAL_RELAY='{"slug":"acme","mode":"local","features":{"public_relay":true}}'
SAVED_PAIR=$'EGREGORE_API_URL=https://env-host.invalid\n'"$KEY"
for mode in local invalid; do
  seed "{\"slug\":\"acme\",\"mode\":\"$mode\",\"features\":{\"public_relay\":true}}" "$SAVED_PAIR"
  check "saved env pair with $mode mode and absent JSON URL is incomplete" route_snapshot_is setup_incomplete
  seed "{\"slug\":\"acme\",\"mode\":\"$mode\",\"api_url\":\"\",\"features\":{\"public_relay\":true}}" "$SAVED_PAIR"
  check "saved env pair with $mode mode and empty JSON URL is incomplete" route_snapshot_is setup_incomplete
done

seed "$LOCAL_RELAY" "$KEY"
TEST_PUBLISH_URL='https://inherited-host.invalid'
check "inherited URL combines with the saved key" route_snapshot_is setup_incomplete

seed "$LOCAL_RELAY" 'EGREGORE_API_URL=https://env-host.invalid'
TEST_PUBLISH_KEY='inherited-credential-do-not-print'
check "inherited key combines with the saved URL" route_snapshot_is setup_incomplete

seed "$LOCAL_RELAY"
TEST_PUBLISH_URL='https://inherited-host.invalid'
TEST_PUBLISH_KEY='inherited-credential-do-not-print'
check "inherited pair with no env file selects organisation publishing" route_snapshot_is setup_incomplete

seed '{"slug":"acme","mode":"connected","api_url":"https://host.invalid","features":{"public_relay":true}}'
TEST_PUBLISH_KEY='inherited-credential-do-not-print'
check "inherited key combines with JSON URL without claiming saved configured access" route_snapshot_is setup_incomplete

seed '{"slug":"acme","mode":"local","api_url":"https://host.invalid","features":{"public_relay":true}}' $'EGREGORE_API_URL=\n'"$KEY"
check "empty inherited and saved URL overrides fall back to JSON" route_snapshot_is setup_incomplete

seed "$LOCAL_RELAY" 'EGREGORE_API_KEY='
TEST_PUBLISH_URL='https://inherited-host.invalid'
check "URL without an effective key still permits consented relay" route_snapshot_is public_relay

seed "$LOCAL_RELAY" $'EGREGORE_API_URL=\n'"$KEY"
check "key without an effective URL still permits consented relay" route_snapshot_is public_relay

seed "$LOCAL_RELAY" $'EGREGORE_API_URL=   \nEGREGORE_API_KEY=""'
check "raw whitespace URL and quoted empty saved key cannot promise relay expiry" route_snapshot_is setup_incomplete

seed "$LOCAL_RELAY"
TEST_PUBLISH_URL='""'
TEST_PUBLISH_KEY='   '
check "raw quoted URL and whitespace inherited key cannot promise relay expiry" route_snapshot_is setup_incomplete

seed '{"slug":"acme","mode":"connected","api_url":"   ","features":{"public_relay":true}}' "$KEY"
check "raw whitespace JSON URL selects organisation upload but is not configured access" route_snapshot_is setup_incomplete

seed "$LOCAL_RELAY" $'EGREGORE_API_URL=$(touch "$HOSTING_TEST_EXEC_LOG")\n'"$KEY"
check "env values remain literal and never execute shell expressions" route_snapshot_is setup_incomplete

seed '{"slug":"acme","mode":"local","features":{"publishing":false,"public_relay":true}}' "$SAVED_PAIR"
TEST_PUBLISH_URL='https://inherited-host.invalid'
TEST_PUBLISH_KEY='inherited-credential-do-not-print'
check "hosting off dominates saved and inherited organisation routes" route_snapshot_is disabled

seed '{"slug":"acme","mode":"connected","api_url":"https://host.invalid","features":{"publishing":false,"public_relay":true}}' "$KEY"
check "publishing off takes precedence over every configured route" status_is disabled
check "disabled status preserves both preferences and configured-access facts" json_is '.publishing == false and .public_relay == true and .connection_configured == true and .recovery_command == null'
TEXT=$(settings hosting status)
check "publishing off remains clearly off" text_has 'Hosting (egregore.xyz): OFF'

seed '{"slug":"acme","mode":"connected","api_url":"https://host.invalid","features":{"publishing":false}}'
TEXT=$(settings hosting on)
check "turning publishing on without a key reports incomplete setup" text_has 'SETUP INCOMPLETE'
check "turning publishing on preserves explicit consent boundaries" jq -e \
  '.features.publishing == true and (.features | has("public_relay") | not)' "$FIX/egregore.json"
check "turning publishing on does not create credentials" test ! -e "$FIX/.env"

seed '{"slug":"acme","mode":"local","features":{"publishing":true,"public_relay":true}}' "$KEY"
cp "$FIX/.env" "$WORK/env.before"
TEXT=$(settings hosting off)
check "turning publishing off keeps its existing behavior" text_has 'Hosting (egregore.xyz): OFF'
check "turning publishing off changes only its preference" jq -e \
  '.mode == "local" and .features.publishing == false and .features.public_relay == true' "$FIX/egregore.json"
check "preference changes leave saved credentials untouched" cmp -s "$FIX/.env" "$WORK/env.before"
check "all hosting reads and incomplete/local writes stay offline" test ! -s "$WORK/network.log"

printf '\n%s passed, 0 failed\n' "$PASS"
