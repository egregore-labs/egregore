#!/usr/bin/env bash
set -euo pipefail

# Test: the framework path list is the same everywhere it is spelled out.
#
# Session-start auto-update (bin/lib/git-sync.sh) and /update
# (.claude/skills/update/SKILL.md) each carry their own literal list of the
# paths that are checked out from upstream/main. When the two drift, an
# instance that only ever boots — never runs /update — silently runs an
# older framework on the paths one list forgot. That is how .pi/ and
# .claude/rules/ went missing from booted instances: /update had .pi/,
# session-start did not, and neither had .claude/rules/ although CLAUDE.md
# declares its contents always-loaded.
#
# This test pins every list to the same set and pins that set to the
# surfaces CLAUDE.md names as the framework. Add a path in all three
# places or the test fails on purpose.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GIT_SYNC="$SCRIPT_DIR/bin/lib/git-sync.sh"
UPDATE_SKILL="$SCRIPT_DIR/.claude/skills/update/SKILL.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; return 0; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; return 0; }

# Paths a booted instance must receive from upstream. Order-insensitive.
REQUIRED="bin/ .claude/commands/ .claude/skills/ .claude/hooks/ .claude/context/ .claude/agents/ .claude/rules/ .pi/ loom/ CLAUDE.md skills/"

# Extract the word list from a `for VAR in ...; do` line.
list_from_for() {
  sed -n "s/^[[:space:]]*for [_a-z]* in \(.*\); do[[:space:]]*$/\1/p" "$1"
}

sorted() { tr ' ' '\n' | sed '/^$/d' | sort; }

echo "Testing: framework sync path parity"
echo

# ── Files exist ───────────────────────────────────────────────────

[ -f "$GIT_SYNC" ] && pass "bin/lib/git-sync.sh exists" || fail "bin/lib/git-sync.sh missing"
[ -f "$UPDATE_SKILL" ] && pass "update skill exists" || fail ".claude/skills/update/SKILL.md missing"

# ── Session-start sync list ───────────────────────────────────────

SYNC_LISTS=$(list_from_for "$GIT_SYNC" | grep 'upstream\|bin/' || true)
SYNC_COUNT=$(printf '%s\n' "$SYNC_LISTS" | sed '/^$/d' | wc -l | tr -d ' ')
[ "$SYNC_COUNT" -eq 1 ] \
  && pass "git-sync.sh has exactly one framework path loop" \
  || fail "expected 1 framework path loop in git-sync.sh, found $SYNC_COUNT"

if [ "$(printf '%s' "$SYNC_LISTS" | sorted)" = "$(printf '%s' "$REQUIRED" | sorted)" ]; then
  pass "git-sync.sh checks out every framework path"
else
  fail "git-sync.sh path list drifted" \
    "have: $(printf '%s' "$SYNC_LISTS" | sorted | tr '\n' ' ')
    want: $(printf '%s' "$REQUIRED" | sorted | tr '\n' ' ')"
fi

# Every synced path must also be covered by the change detection and the
# git add that follow the checkout, or a path can be checked out (staged)
# and then never committed.
for _p in .pi/ .claude/ bin/ loom/ CLAUDE.md skills/; do
  grep -q "git status --porcelain .*$_p" "$GIT_SYNC" \
    && pass "change detection covers $_p" \
    || fail "git status --porcelain list is missing $_p"
  grep -qE "git add .*$_p" "$GIT_SYNC" \
    && pass "git add covers $_p" \
    || fail "git add list is missing $_p"
done

# ── /update skill lists (worktree path + normal path) ─────────────

UPDATE_LISTS=$(list_from_for "$UPDATE_SKILL" | grep 'bin/' || true)
UPDATE_COUNT=$(printf '%s\n' "$UPDATE_LISTS" | sed '/^$/d' | wc -l | tr -d ' ')
[ "$UPDATE_COUNT" -ge 1 ] \
  && pass "update skill has $UPDATE_COUNT framework path loop(s)" \
  || fail "no framework path loop found in the update skill"

i=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  i=$((i + 1))
  if [ "$(printf '%s' "$line" | sorted)" = "$(printf '%s' "$REQUIRED" | sorted)" ]; then
    pass "update skill loop $i matches session-start sync"
  else
    fail "update skill loop $i drifted from session-start sync" \
      "have: $(printf '%s' "$line" | sorted | tr '\n' ' ')"
  fi
done <<EOF
$UPDATE_LISTS
EOF

# ── The list matches what CLAUDE.md calls the framework ──────────

for _p in bin/ .claude/skills/ .claude/hooks/ .claude/context/ .claude/agents/ .pi/ loom/ CLAUDE.md skills/; do
  grep -q "\`$_p\`" "$SCRIPT_DIR/CLAUDE.md" \
    && pass "CLAUDE.md names $_p as framework" \
    || fail "CLAUDE.md no longer names $_p as framework — update REQUIRED here"
done

# ── bash 3.2 syntax ───────────────────────────────────────────────

/bin/bash -n "$GIT_SYNC" 2>/dev/null \
  && pass "git-sync.sh bash 3.2 syntax clean" \
  || fail "bash -n rejects git-sync.sh"

# ── Summary ───────────────────────────────────────────────────────

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
