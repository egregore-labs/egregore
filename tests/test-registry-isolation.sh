#!/bin/bash
# Guard: no test may write to the developer's real instance registry.
#
# session-start.sh self-registers its instance in $HOME/.egregore/instances.json.
# A test that runs it against a throwaway workspace WITHOUT sandboxing HOME leaks
# an entry into the real registry; the workspace is then deleted on cleanup and
# the launcher lists a permanent ✗ (missing) row. tests/test_multi_repo.sh did
# exactly this, which is where the stray "testorg / TestOrg" rows came from.
#
# Rule enforced here: any test that executes a *session-start.sh must set HOME.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Registry isolation tests ==="
echo ""

# --- Test 1: throwaway-workspace tests that run session-start.sh sandbox HOME ---
# Match execution (bash/sh/source/.) of a session-start script — not greps,
# copies, or reads of its source text, which are safe. The leak only happens
# when the instance lives in a throwaway directory (mktemp, the convention in
# this suite): a real checkout is already registered, so registering it again
# is a no-op, while a temp path is deleted on cleanup and strands the entry.
RUN_RE='^[^#]*(bash|sh|source|\.)[[:space:]]+("?[^"[:space:]]*/)?[a-z-]*session-start\.sh'
HOME_RE='(^|[[:space:]])(export[[:space:]]+)?HOME='

LEAKY=""
RUNNERS=0
CHECKED=0
for f in "$SCRIPT_DIR"/tests/*.sh "$SCRIPT_DIR"/bin/tests/*.sh; do
  [ -f "$f" ] || continue
  grep -Eq "$RUN_RE" "$f" || continue
  RUNNERS=$((RUNNERS + 1))
  grep -q 'mktemp' "$f" || continue
  CHECKED=$((CHECKED + 1))
  grep -Eq "$HOME_RE" "$f" || LEAKY="$LEAKY ${f#$SCRIPT_DIR/}"
done

if [ "$RUNNERS" -eq 0 ]; then
  fail "detector found no tests running session-start.sh — regex is stale"
elif [ -n "$LEAKY" ]; then
  for f in $LEAKY; do
    fail "$f runs session-start.sh in a temp workspace without sandboxing HOME (leaks into ~/.egregore/instances.json)"
  done
else
  pass "all $CHECKED throwaway-workspace test(s) sandbox HOME ($RUNNERS run session-start.sh)"
fi

# --- Test 2: session-start.sh registration is still HOME-relative ---
# If registration ever hardcodes a path outside $HOME, sandboxing stops working.
if grep -q 'REGISTRY_DIR="$HOME/.egregore"' "$SCRIPT_DIR/bin/session-start.sh"; then
  pass "session-start.sh registry path is \$HOME-relative (sandboxable)"
else
  fail "session-start.sh registry path is no longer \$HOME-relative — sandboxing is defeated"
fi

# --- Test 3: worktrees still do not self-register ---
if grep -q 'if \[ "$IS_WORKTREE" = "false" \]' "$SCRIPT_DIR/bin/session-start.sh"; then
  pass "worktrees are excluded from instance registration"
else
  fail "worktree exclusion missing — every worktree would register as an instance"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ]
