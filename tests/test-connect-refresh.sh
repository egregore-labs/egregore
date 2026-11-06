#!/usr/bin/env bash
# connect-refresh.sh runs whichever create-egregore npx has cached. That may be
# a release from before the October 2026 security reset, which sends the org
# key to the saved address exactly as written. The refresh must run only for
# an address that needs no resolving: never for the retired origin, never for
# an address the resolver refuses, and always quietly when it skips.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t egregore-connect-refresh-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ✓ $1"; PASS=$((PASS + 1))
  else
    echo "  ✗ $1 — expected '$2', got '$3'" >&2; FAIL=$((FAIL + 1))
  fi
}

echo "test-connect-refresh"

# npx is a shim that records each call; nothing reaches the network.
SHIM="$TMP/shim"
mkdir -p "$SHIM"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$NPX_CALLS"\n' > "$SHIM/npx"
chmod +x "$SHIM/npx"

case_index=0
# refresh <config-json>: run connect-refresh.sh in a fresh instance; sets
# CALLS (the npx calls) and QUIET ("quiet" when it printed nothing).
refresh() {
  case_index=$((case_index + 1))
  local dir="$TMP/instance-$case_index"
  mkdir -p "$dir/bin/lib"
  cp "$ROOT/bin/connect-refresh.sh" "$dir/bin/connect-refresh.sh"
  cp "$ROOT/bin/lib/config.sh" "$dir/bin/lib/config.sh"
  printf '%s\n' "$1" > "$dir/egregore.json"
  : > "$dir/npx.calls"
  (NPX_CALLS="$dir/npx.calls" PATH="$SHIM:$PATH" bash "$dir/bin/connect-refresh.sh") > "$dir/out" 2>&1
  STATUS=$?
  CALLS="$(cat "$dir/npx.calls")"
  QUIET="$([ -s "$dir/out" ] || echo quiet)"
}
connected() { jq -cn --arg url "$1" '{mode: "connected", api_url: $url, slug: "acme"}'; }

RETIRED="https://egregore-production-55f2.up.railway.app"
for saved in "$RETIRED" "$RETIRED/" "https://EGREGORE-PRODUCTION-55F2.UP.RAILWAY.APP" \
    "https://selfhost.example\\@egregore-production-55f2.up.railway.app" \
    "https://selfhost.example%5C@egregore-production-55f2.up.railway.app/" \
    "http://egregore-production-55f2.up.railway.ap{p,p}" \
    "https://bücher.example"; do
  refresh "$(connected "$saved")"
  check "$saved: the cached package never runs" "" "$CALLS"
  check "$saved: the refresh skips quietly" "quiet" "$QUIET"
  check "$saved: the refresh exits 0" "0" "$STATUS"
done

for saved in "https://egregore.example.org" "https://egregore.example.org/" "https://api.egregore.xyz" "http://127.0.0.1:8765"; do
  refresh "$(connected "$saved")"
  check "$saved: the refresh runs" "--yes --prefer-offline create-egregore --refresh-connect" "$CALLS"
  check "$saved: the refresh exits 0" "0" "$STATUS"
done

refresh '{"mode":"local","slug":"acme"}'
check "a Local instance never runs the refresh" "" "$CALLS"
check "a Local instance skips quietly" "quiet" "$QUIET"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
