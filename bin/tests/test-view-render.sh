#!/usr/bin/env bash
# view-render.sh regression: deterministic mechanics, content-addressed cache,
# --no-open honored on both cold and cached paths, argument validation.
# No model is involved anywhere in this path — that is the point.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# The renderer is a checked-out package; without its installed dependencies
# every render fails for a reason this suite is not about.
if [ ! -d "$ROOT/packages/egregore-artifacts/node_modules/react" ]; then
  echo "SKIP: renderer dependencies not installed; run npm ci --prefix packages/egregore-artifacts"
  exit 0
fi
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-view-render.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
HOME_FIX="$WORK/home"
mkdir -p "$HOME_FIX"
printf '# Render Check\n\nDeterministic body.\n' > "$WORK/doc.md"

run() { (cd "$ROOT" && HOME="$HOME_FIX" bash bin/view-render.sh "$@"); }

out1="$(run document "$WORK/doc.md" -- --no-open 2>&1)"
rc=$?
[ $rc -eq 0 ] && grep -q "render-cache/document-doc-" <<< "$out1" \
  && pass "cold render writes into the content-addressed cache" \
  || fail "cold render failed" "rc=$rc $out1"
grep -q "served from render cache" <<< "$out1" \
  && fail "cold render claimed a cache hit" || pass "cold render is honest about being cold"

out2="$(run document "$WORK/doc.md" -- --no-open 2>&1)"
grep -q "served from render cache" <<< "$out2" \
  && pass "unchanged content is served from the render cache" \
  || fail "second render missed the cache" "$out2"
grep -q "opened in browser" <<< "$out2" \
  && fail "--no-open ignored on the cached path" || pass "--no-open honored on the cached path"

printf '\nChanged.\n' >> "$WORK/doc.md"
out3="$(run document "$WORK/doc.md" -- --no-open 2>&1)"
grep -q "served from render cache" <<< "$out3" \
  && fail "changed content wrongly served from cache" \
  || pass "changed content re-renders (cache keys on bytes)"

count="$(ls "$HOME_FIX/.egregore/runtime/render-cache" | wc -l | tr -d ' ')"
[ "$count" = "2" ] && pass "cache holds one entry per distinct content" \
  || fail "unexpected cache entry count" "count=$count"

run document 2>/dev/null && fail "missing source accepted" || pass "file-backed type without a source is refused"
run 2>/dev/null && fail "missing type accepted" || pass "missing type is refused"

# An absolute path into instance memory must normalize to the canonical
# memory/... form and go through the same boundary staging — same cache key.
MEM_FILE="$(cd "$ROOT" && find memory/handoffs -name "*.md" -type f 2>/dev/null | head -1)"
if [ -n "$MEM_FILE" ]; then
  ABS_FILE="$(cd "$ROOT/memory" && pwd -P)/${MEM_FILE#memory/}"
  canon="$(run handoff "$MEM_FILE" -- --no-open 2>&1 | grep -oE "handoff-[A-Za-z0-9._-]+\.html" | head -1)"
  absol="$(run handoff "$ABS_FILE" -- --no-open 2>&1 | grep -oE "handoff-[A-Za-z0-9._-]+\.html" | head -1)"
  [ -n "$canon" ] && [ "$canon" = "$absol" ] \
    && pass "absolute in-memory path normalizes to canonical boundary staging" \
    || fail "absolute path bypassed canonical staging" "canon=$canon abs=$absol"
else
  pass "absolute-path normalization skipped (no memory handoffs in this checkout)"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
