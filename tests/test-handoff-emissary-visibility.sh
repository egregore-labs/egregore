#!/usr/bin/env bash
# /handoff must not turn internal team context into a public emissary.
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
SB="$TMP/instance"
mkdir -p "$SB/bin" "$SB/memory/handoffs" "$TMP/home/.egregore" "$TMP/shim" "$TMP/results"
cp "$ROOT/bin/handoff-run.sh" "$SB/bin/handoff-run.sh"
printf '%s\n' '# Handoffs' > "$SB/memory/handoffs/index.md"
printf '%s\n' '{"mode":"local"}' > "$SB/egregore.json"
printf '%s\n' '{"auth_token":"test-token"}' > "$TMP/home/.egregore/emissary-config.json"

cat > "$SB/bin/repo-state.sh" <<'SHIM'
#!/bin/bash
exit 0
SHIM
cat > "$SB/bin/publish-artifact.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$PUBLISH_LOG"
exit 4
SHIM
cat > "$TMP/shim/npx" <<'SHIM'
#!/bin/bash
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then out="${2:-}"; shift 2; else shift; fi
done
[ -n "$out" ] || exit 1
printf '%s\n' '<html>private handoff</html>' > "$out"
SHIM
cat > "$TMP/shim/curl" <<'SHIM'
#!/bin/bash
payload=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-d" ]; then payload="${2:-}"; shift 2; else shift; fi
done
printf '%s' "$payload" > "$EMISSARY_PAYLOAD_LOG"
printf '%s\n' '{"url":"https://egregore.xyz/emissary/e/private-test"}'
SHIM
chmod +x "$SB/bin/"*.sh "$TMP/shim/"*

run_handoff() {
  local topic="$1"; shift
  : > "$TMP/payload.json"
  : > "$TMP/publish.log"
  rm -f "$TMP/results/handoff-run-result.json"
  HOME="$TMP/home" \
    TMPDIR="$TMP/results" \
    PATH="$TMP/shim:$PATH" \
    EGREGORE_USE_PUBLISHED=1 \
    EMISSARY_PAYLOAD_LOG="$TMP/payload.json" \
    PUBLISH_LOG="$TMP/publish.log" \
    bash "$SB/bin/handoff-run.sh" \
      --author alice --topic "$topic" --no-push --no-notify "$@" <<'BODY'
# Handoff
**Author**: alice

## Briefing
Private findings for the intended teammate.
BODY
}

echo "test-handoff-emissary-visibility"

ADDRESSED_OUT=$(run_handoff "addressed privacy" --recipient Bob)
if jq -e '.audience.visible_to | type == "array"' "$TMP/payload.json" >/dev/null 2>&1; then
  ok "addressed handoff uses a restricted visibility array"
else
  bad "addressed handoff did not create a directed emissary payload"
fi
check "addressed_to names the recipient" "bob" \
  "$(jq -r '.audience.addressed_to[0].handle // empty' "$TMP/payload.json")"
check "visible_to names the same recipient" "bob" \
  "$(jq -r '.audience.visible_to[0].handle // empty' "$TMP/payload.json")"
check "extendable_by names the same recipient" "bob" \
  "$(jq -r '.audience.extendable_by[0].handle // empty' "$TMP/payload.json")"
check "addressed handoff never sets public visibility" "false" \
  "$(jq -r '.audience.visible_to == "public"' "$TMP/payload.json")"
check "successful directed emissary does not use fallback publisher" "" \
  "$(cat "$TMP/publish.log")"
check "directed emissary result is published" "published" \
  "$(jq -r '.publishStatus' "$TMP/results/handoff-run-result.json")"
case "$ADDRESSED_OUT" in
  *published*) ok "directed publish remains visible in the status line" ;;
  *) bad "directed publish status line omitted published" ;;
esac

SELF_OUT=$(run_handoff "recipientless privacy")
check "recipient-less handoff does not call the emissary API" "" \
  "$(cat "$TMP/payload.json")"
if [ -s "$TMP/publish.log" ]; then
  ok "recipient-less handoff uses the normal publisher"
else
  bad "recipient-less handoff bypassed both publishing policies"
fi
check "relay-off fallback is reported" "relay-off" \
  "$(jq -r '.publishStatus' "$TMP/results/handoff-run-result.json")"
check "relay-off fallback has no public URL" "" \
  "$(jq -r '.artifactUrl' "$TMP/results/handoff-run-result.json")"
case "$SELF_OUT" in
  *"not published"*) ok "recipient-less skip is visible in the status line" ;;
  *) bad "recipient-less skip was silent" ;;
esac

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
