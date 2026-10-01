#!/bin/bash
# The greeting notice ledger: standing state folds after first sight, open
# items say since when, tips expire, and every runtime shares one ledger.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; return 0; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; return 0; }

echo "Testing: greeting notice ledger"
echo ""

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LEDGER="$TMP/notices.json"

# One "session": source the lib against the ledger, run the given notice
# script body, flush. Runs in the named shell so bash and zsh are both covered.
session() {
  local shell="$1" body="$2"
  printf 'source "%s/bin/lib/notices.sh"\n_notice_init\n%s\n_notice_flush\n' "$ROOT" "$body" > "$TMP/session.sh"
  EGREGORE_NOTICE_LEDGER="$LEDGER" "$shell" "$TMP/session.sh" 2>&1
}

STANDING='_notice loom-doctor standing "loom: haiku remapped → sonnet-5" "brief-v1" "  ⚠ loom: haiku remapped → sonnet-5 (env)"
_notice board-link standing "board" "https://x/board" "  ◆ https://x/board (board)"'

for shell in bash zsh; do
  command -v "$shell" >/dev/null 2>&1 || { pass "$shell not installed, skipped"; continue; }
  rm -f "$LEDGER"

  # --- standing: full first, folded after -------------------------------------------
  out="$(session "$shell" "$STANDING")"
  expected="  ⚠ loom: haiku remapped → sonnet-5 (env)
  ◆ https://x/board (board)"
  [ "$out" = "$expected" ] && pass "[$shell] standing notices print in full on first sight" || fail "[$shell] first sight" "$out"

  out="$(session "$shell" "$STANDING")"
  [ "$out" = "  ◦ unchanged: loom: haiku remapped → sonnet-5 · board" ] \
    && pass "[$shell] unchanged standing notices fold into one line" || fail "[$shell] fold" "$out"

  # --- standing: a changed signature re-renders in full, the other stays folded -----------
  out="$(session "$shell" '_notice loom-doctor standing "loom: haiku remapped → opus" "brief-v2" "  ⚠ loom: haiku remapped → opus (env)"
_notice board-link standing "board" "https://x/board" "  ◆ https://x/board (board)"')"
  expected="  ⚠ loom: haiku remapped → opus (env)
  ◦ unchanged: board"
  [ "$out" = "$expected" ] && pass "[$shell] a changed standing notice prints in full again" || fail "[$shell] change re-renders" "$out"

  # --- open: always printed, says since when once it is older than today ---------------------
  rm -f "$LEDGER"
  out="$(session "$shell" '_notice handoffs-for-you open "handoffs" "[a,b]" "  ◇ 2 handoffs for you"')"
  [ "$out" = "  ◇ 2 handoffs for you" ] && pass "[$shell] open item prints plain on first sight" || fail "[$shell] open first" "$out"
  out="$(session "$shell" '_notice handoffs-for-you open "handoffs" "[a,b]" "  ◇ 2 handoffs for you"')"
  [ "$out" = "  ◇ 2 handoffs for you" ] && pass "[$shell] open item unchanged the same day stays plain" || fail "[$shell] open same day" "$out"
  # Age the ledger: pretend the signature was first shown on an earlier date.
  jq '.["handoffs-for-you"].first = "2026-09-03"' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
  out="$(session "$shell" '_notice handoffs-for-you open "handoffs" "[a,b]" "  ◇ 2 handoffs for you"')"
  [ "$out" = "  ◇ 2 handoffs for you · since Sep 3" ] && pass "[$shell] open item unchanged since an earlier day says since when" || fail "[$shell] open since" "$out"
  out="$(session "$shell" '_notice handoffs-for-you open "handoffs" "[a,b,c]" "  ◇ 3 handoffs for you"')"
  [ "$out" = "  ◇ 3 handoffs for you" ] && pass "[$shell] a changed open item drops the since and restarts its clock" || fail "[$shell] open change" "$out"
  first="$(jq -r '.["handoffs-for-you"].first' "$LEDGER")"
  [ "$first" = "$(date +%Y-%m-%d)" ] && pass "[$shell] the clock restarted today" || fail "[$shell] clock restart" "$first"

  # --- tip: at most NOTICE_TIP_MAX showings -------------------------------------------------
  rm -f "$LEDGER"
  shown=0
  for _ in 1 2 3 4 5; do
    out="$(session "$shell" '_notice tutorial-tip tip "tutorial" "tutorial" "  Tip: Run /tutorial"')"
    [ -n "$out" ] && shown=$((shown + 1))
  done
  [ "$shown" -eq 3 ] && pass "[$shell] a tip shows three times, then retires" || fail "[$shell] tip cap" "shown $shown times"

  # --- ledger off: everything prints, nothing is written --------------------------------------
  rm -f "$LEDGER"
  out="$(EGREGORE_NOTICE_LEDGER=off "$shell" -c 'source "$0/bin/lib/notices.sh"; _notice_init; _notice x standing "x" "s" "  line"; _notice x standing "x" "s" "  line"; _notice_flush' "$ROOT")"
  expected="  line
  line"
  [ "$out" = "$expected" ] && [ ! -f "$LEDGER" ] && pass "[$shell] ledger off prints everything and records nothing" || fail "[$shell] ledger off" "$out"
done

# --- pinned links render through the same helper ---------------------------------------------
rm -f "$LEDGER"
out="$(session bash '_notice_pinned_links "[\"https://a\", {\"label\": \"Team task board\", \"url\": \"https://b\"}, {\"url\": \"https://c\"}]"')"
expected="  ◆ https://a
  ◆ Team task board: https://b
  ◆ https://c"
[ "$out" = "$expected" ] && pass "pinned links render as before on first sight" || fail "pinned links first" "$out"
out="$(session bash '_notice_pinned_links "[\"https://a\", {\"label\": \"Team task board\", \"url\": \"https://b\"}, {\"url\": \"https://c\"}]"')"
[ "$out" = "  ◦ unchanged: https://a · Team task board · https://c" ] && pass "pinned links fold under their labels" || fail "pinned links fold" "$out"

# --- corrupt ledger is ignored, not fatal ----------------------------------------------------------
printf 'not json' > "$LEDGER"
out="$(session bash '_notice x standing "x" "s" "  line"')"
[ "$out" = "  line" ] && jq -e '.x.shown == 1' "$LEDGER" >/dev/null && pass "a corrupt ledger is replaced, not fatal" || fail "corrupt ledger" "$out"

# --- cross-runtime parity ------------------------------------------------------------------------------
for entry in bin/lib/greeting.sh bin/codex-session-start.sh; do
  grep -q '_notice_init' "$ROOT/$entry" && grep -q '_notice_flush' "$ROOT/$entry" \
    && pass "$entry initializes and flushes the ledger" || fail "$entry ledger wiring"
  grep -q '_notice handoffs-for-you open' "$ROOT/$entry" \
    && pass "$entry registers handoffs as an open notice" || fail "$entry handoffs notice"
  grep -q '_notice_pinned_links' "$ROOT/$entry" \
    && pass "$entry renders pinned links through the shared helper" || fail "$entry pinned links"
done
grep -q '_notice loom-doctor standing' "$ROOT/bin/lib/greeting.sh" \
  && pass "loom drift is a standing notice" || fail "loom drift notice"
grep -q '_notice tutorial-tip tip' "$ROOT/bin/lib/greeting.sh" \
  && pass "the tutorial tip is a tip notice" || fail "tutorial tip notice"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
