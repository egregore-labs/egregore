#!/bin/bash
# Regression guard for sync-graph.sh's "is this already in the graph?" check.
#
# The bug this catches: id_exists() was `echo "$list" | grep -qxF "$id"` while the
# script runs under `set -o pipefail`. grep -q exits on first match, echo takes
# SIGPIPE writing the rest of a large list, exits 141, and pipefail turns that
# into a failed pipeline — so an id near the TOP of the sorted list reads as
# absent. 229 of 238 handoffs were re-synced on every /save because of it, which
# is what made the graph step take 3-5 minutes and land nothing.
#
# Test 1 is the one that matters: it runs id_exists under the SAME shell options
# as the real script, against a list big enough to keep echo writing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$SCRIPT_DIR/bin/sync-graph.sh"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== sync-graph id_exists tests ==="
echo ""

# Lift id_exists out of the script (sourcing it would run the whole sync).
ID_EXISTS_SRC="$(sed -n '/^id_exists() {/,/^}/p' "$SYNC")"
if [ -z "$ID_EXISTS_SRC" ]; then
  fail "could not extract id_exists() from bin/sync-graph.sh"
  echo ""; echo "  $PASS passed, $FAIL failed"; echo ""
  exit 1
fi

# --- Test 1: matches at any position, under the script's own shell options ---
# The list MUST exceed the OS pipe buffer (64KB on macOS/Linux) or the bug hides:
# if the whole list fits in the buffer, echo finishes its write instantly and
# never takes SIGPIPE. 2000 entries × ~64 chars ≈ 128KB, comfortably over.
PAD="padding-to-push-this-list-past-the-64kb-pipe-buffer"
RESULT="$(
  set -euo pipefail          # exactly what bin/sync-graph.sh sets
  eval "$ID_EXISTS_SRC"
  LIST="$(for i in $(seq -w 1 2000); do echo "2026-01-01-entry-$i-$PAD"; done)"
  set +e
  id_exists "2026-01-01-entry-0001-$PAD" "$LIST"; first=$?
  id_exists "2026-01-01-entry-1000-$PAD" "$LIST"; mid=$?
  id_exists "2026-01-01-entry-2000-$PAD" "$LIST"; last=$?
  id_exists "2026-01-01-entry-9999-$PAD" "$LIST"; absent=$?
  echo "$first $mid $last $absent"
)"

case "$RESULT" in
  "0 0 0 1") pass "finds ids at head/middle/tail, rejects absent (result: $RESULT)" ;;
  141*)      fail "id at the head of the list returned 141 (SIGPIPE) — the pipefail regression is back: already-synced files will be re-sent every run (result: $RESULT)" ;;
  "1 "*)     fail "id at the head of the list read as absent — already-synced files will be re-sent every run (result: $RESULT)" ;;
  *)         fail "unexpected id_exists behaviour (expected '0 0 0 1', got '$RESULT')" ;;
esac

# --- Test 2: the existence check must not depend on a pipeline ---
# Any `| grep -q` reintroduces the SIGPIPE race regardless of how it's written.
if echo "$ID_EXISTS_SRC" | grep -q '|[[:space:]]*grep'; then
  fail "id_exists pipes into grep — pipefail can turn an early match into a false miss"
else
  pass "id_exists resolves in-shell, no pipeline to break"
fi

# --- Test 3: wraps must MERGE the Session before resolving its author ---
# Leading with MATCH (p:Person) yields zero rows for an unknown author, so the
# MERGE silently never runs while the query still reports success.
WRAP_CYPHER="$(sed -n '/CYPHER="MERGE (s:Session/,/RETURN s.id"/p' "$SYNC")"
if [ -n "$WRAP_CYPHER" ] && echo "$WRAP_CYPHER" | grep -q 'OPTIONAL MATCH (p:Person)'; then
  pass "wrap sync MERGEs the Session first, then OPTIONAL MATCHes the author"
elif sed -n '/CYPHER="MATCH (p:Person)/,/RETURN s.id"/p' "$SYNC" | grep -q 'MERGE (s:Session'; then
  fail "wrap sync still leads with MATCH (p:Person) — unknown authors write nothing and report success"
else
  fail "could not locate the wrap sync Cypher — test needs updating"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ]
