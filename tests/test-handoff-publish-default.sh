#!/usr/bin/env bash
# The unauthenticated OSS artifact relay is opt-in; connected publishing stays on.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/shim"
cat > "$TMP/shim/curl" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
printf '%s\n' '{"url":"https://example.invalid/artifact"}'
SHIM
chmod +x "$TMP/shim/curl"

RC=0
OUT=""
ERR=""
CURL_ARGS=""
run_publish() {
  local config="$1"; shift
  local sb="$TMP/case"
  rm -rf "$sb"
  mkdir -p "$sb/bin"
  cp "$ROOT/bin/publish-artifact.sh" "$sb/bin/publish-artifact.sh"
  printf '#!/bin/bash\nexit 0\n' > "$sb/bin/artifact-register.sh"
  printf '#!/bin/bash\nexit 0\n' > "$sb/bin/publish-references.sh"
  chmod +x "$sb/bin/"*.sh
  [ "$config" = "--missing" ] || printf '%s' "$config" > "$sb/egregore.json"
  printf '%s\n' '<html>private findings</html>' > "$sb/doc.html"
  : > "$sb/curl.log"
  RC=0
  OUT=$(env -u EGREGORE_API_KEY -u EGREGORE_API_URL \
    PATH="$TMP/shim:$PATH" CURL_LOG="$sb/curl.log" "$@" \
    bash "$sb/bin/publish-artifact.sh" document "$sb/doc.html" \
      --raw-html --title findings 2>"$sb/err") || RC=$?
  ERR=$(cat "$sb/err")
  CURL_ARGS=$(cat "$sb/curl.log")
}

echo "test-handoff-publish-default"

run_publish '{"mode":"local"}'
check "absent relay setting makes no network call" "" "$CURL_ARGS"
check "absent relay setting exits 4" "4" "$RC"
check "absent relay setting emits no URL" "" "$OUT"
case "$ERR" in
  *"bin/settings.sh relay on"*) ok "skip names the explicit opt-in command" ;;
  *) bad "skip does not explain how to opt in" ;;
esac

run_publish '{"mode":"local","features":{"public_relay":false}}'
check "public_relay:false makes no network call" "" "$CURL_ARGS"
check "public_relay:false exits 4" "4" "$RC"

run_publish '{"mode":"local","features":{"public_relay":true}}'
case "$CURL_ARGS" in
  *"/api/artifacts/share"*) ok "public_relay:true uses the share endpoint" ;;
  *) bad "public_relay:true did not reach the share endpoint" ;;
esac
check "public_relay:true returns a URL" "https://example.invalid/artifact" "$OUT"
check "public_relay:true exits 0" "0" "$RC"

run_publish '{"mode":"local","features":{"public_relay":"true"}}'
check "string true is not consent" "" "$CURL_ARGS"
check "string true exits 4" "4" "$RC"

run_publish '{"mode":"local","features":{"public_relay": tru'
check "malformed config fails closed" "" "$CURL_ARGS"
check "malformed config exits 4" "4" "$RC"

run_publish --missing
check "missing config fails closed" "" "$CURL_ARGS"
check "missing config exits 4" "4" "$RC"

run_publish '[]'
check "non-object config fails closed" "" "$CURL_ARGS"
check "non-object config exits 4" "4" "$RC"

run_publish '{"mode":"connected","api_url":"https://api.example.invalid","features":{"public_relay":false}}' \
  EGREGORE_API_KEY=test-key
case "$CURL_ARGS" in
  *"/api/artifacts/publish"*"Authorization: Bearer test-key"*)
    ok "connected publishing remains authenticated and enabled" ;;
  *) bad "connected publishing route changed" ;;
esac
case "$CURL_ARGS" in
  *"/api/artifacts/share"*) bad "connected publishing touched the public relay" ;;
  *) ok "connected publishing never touches the public relay" ;;
esac

run_publish '{"mode":"connected","api_url":"https://api.example.invalid","features":{"publishing":false,"public_relay":true}}' \
  EGREGORE_API_KEY=test-key
check "hosting off still stops every route" "" "$CURL_ARGS"
check "hosting off retains exit 3" "3" "$RC"

if grep -qE "jq -r '\\.features\\.public_relay // " \
  "$ROOT/bin/publish-artifact.sh" "$ROOT/bin/settings.sh"; then
  bad "public_relay uses jq's false-collapsing // operator"
else
  ok "public_relay requires an explicit JSON true"
fi

SETTINGS="$TMP/settings"
mkdir -p "$SETTINGS/bin"
cp "$ROOT/bin/settings.sh" "$SETTINGS/bin/settings.sh"
printf '%s\n' '{"org_name":"Acme","slug":"acme"}' > "$SETTINGS/egregore.json"
check "relay status defaults off" "false" \
  "$(bash "$SETTINGS/bin/settings.sh" relay status --json | jq -r '.public_relay')"
bash "$SETTINGS/bin/settings.sh" relay on >/dev/null
check "relay on records explicit consent" "true" \
  "$(jq -r '.features.public_relay' "$SETTINGS/egregore.json")"
bash "$SETTINGS/bin/settings.sh" relay off >/dev/null
check "relay off records false" "false" \
  "$(jq -r '.features.public_relay' "$SETTINGS/egregore.json")"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
