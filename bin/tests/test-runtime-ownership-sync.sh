#!/usr/bin/env bash
# Runtime framework ownership vs legacy upstream sync: once an instance's
# activation record says retrieval runtime-qmd, the legacy framework overlay
# must not run — and after rollback it must resume. Uses the same identity
# key as the Python upgrade store; no slugs, paths, or versions hardcoded.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-owned.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FIX="$WORK/instance"; UPROOT="$WORK/upgrade"
mkdir -p "$FIX" "$UPROOT"
printf '{"slug":"fixture","org_name":"Fixture","org_id":"org-fixture-1"}\n' > "$FIX/egregore.json"

owned() {
  (SCRIPT_DIR="$FIX" EGREGORE_UPGRADE_ROOT="$UPROOT" bash -c '
    # shellcheck source=/dev/null
    source "'"$ROOT"'/bin/lib/runtime-owned.sh"
    runtime_owns_framework && echo yes || echo no
  ')
}

KEY=$(printf '%s|%s' "org-fixture-1" "$(cd "$FIX" && pwd -P)" | shasum -a 256 | cut -c1-16)

[ "$(owned)" = "no" ] && pass "no activation record: legacy sync owns the framework" || fail "ownership claimed without a record"

mkdir -p "$UPROOT/$KEY"
printf '{"active_version":"x","retrieval":"runtime-qmd"}\n' > "$UPROOT/$KEY/active.json"
[ "$(owned)" = "yes" ] && pass "runtime-qmd activation record: Runtime owns the framework" || fail "activated instance not recognized"

printf '{"active_version":"x","retrieval":"previous-runtime"}\n' > "$UPROOT/$KEY/active.json"
[ "$(owned)" = "no" ] && pass "after rollback the legacy sync owns the framework again" || fail "rollback did not restore legacy ownership"

mkdir -p "$UPROOT/ffffffffffffffff"
printf '{"active_version":"x","retrieval":"runtime-qmd"}\n' > "$UPROOT/ffffffffffffffff/active.json"
printf '{"active_version":"x","retrieval":"previous-runtime"}\n' > "$UPROOT/$KEY/active.json"
[ "$(owned)" = "no" ] && pass "another instance's activation never claims this one" || fail "cross-instance record leaked ownership"

# The legacy overlay consults the guard BEFORE any upstream checkout.
GUARD_LINE=$(grep -n "runtime_owns_framework" "$ROOT/bin/lib/git-sync.sh" | head -1 | cut -d: -f1)
CHECKOUT_LINE=$(grep -Fn '_checkout_framework_paths .' "$ROOT/bin/lib/git-sync.sh" | head -1 | cut -d: -f1)
[ -n "$GUARD_LINE" ] && [ -n "$CHECKOUT_LINE" ] && [ "$GUARD_LINE" -lt "$CHECKOUT_LINE" ] \
  && pass "framework update checks Runtime ownership before touching any file" \
  || fail "guard missing or ordered after the upstream checkout" "guard=$GUARD_LINE checkout=$CHECKOUT_LINE"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
