#!/usr/bin/env bash
# The reflex runner: name order, the sigil, silence on error, empty output,
# chatter and budget overruns, the probe environment, and an absent directory.
# Usage: bash tests/test-reflexes.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$REPO_ROOT/bin/lib/reflexes.py"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/egregore-reflexes.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PROBES="$ROOT/probes"
mkdir -p "$PROBES" "$ROOT/memory"
printf '{"github_username":"tester"}\n' > "$ROOT/.egregore-state.json"

cat > "$PROBES/10-prints.sh" <<'EOF'
echo "first line from ${EGREGORE_AUTHOR} on ${EGREGORE_HARNESS}"
echo "second line"
EOF
cat > "$PROBES/20-errors.sh" <<'EOF'
echo "should not appear"
exit 1
EOF
cat > "$PROBES/30-hangs.sh" <<'EOF'
sleep 5
echo "should not appear either"
EOF
cat > "$PROBES/40-chatty.py" <<'EOF'
import os
print("chatty one in " + os.path.basename(os.environ["EGREGORE_ROOT"]))
print("chatty two")
print("chatty three")
print("chatty four")
EOF
cat > "$PROBES/50-empty.sh" <<'EOF'
printf ''
EOF
cat > "$PROBES/README.md" <<'EOF'
not a probe
EOF
cat > "$PROBES/_draft.sh" <<'EOF'
echo "drafts are skipped"
EOF

ROOT_NAME="$(basename "$ROOT")"
START=$(date +%s)
OUTPUT="$(python3 "$RUNNER" --root "$ROOT" --dir "$PROBES" --memory "$ROOT/memory" --harness codex --budget 0.5 2>"$ROOT/stderr")"
STATUS=$?
END=$(date +%s)
EXPECTED="  ◦ first line from tester on codex
  ◦ second line
  ◦ chatty one in $ROOT_NAME
  ◦ chatty two"

if [ "$STATUS" -eq 0 ]; then pass "runner exits 0 with failing, hanging and chatty probes"; else fail "runner exit $STATUS"; fi
if [ "$OUTPUT" = "$EXPECTED" ]; then
  pass "prints the four expected lines in name order with the sigil, nothing from the others"
else
  fail "unexpected output"
  printf '%s\n' "--- got ---" "$OUTPUT" "--- expected ---" "$EXPECTED"
fi
if [ ! -s "$ROOT/stderr" ]; then pass "quiet on stderr without --debug"; else fail "stderr not empty: $(cat "$ROOT/stderr")"; fi
if [ $((END - START)) -lt 3 ]; then pass "a hanging probe costs its budget, not the card ($((END - START))s)"; else fail "runner took $((END - START))s"; fi

DEBUG="$(python3 "$RUNNER" --root "$ROOT" --dir "$PROBES" --budget 0.5 --debug 2>&1 >/dev/null)"
case "$DEBUG" in
  *"20-errors.sh: silent, exit 1"*) pass "--debug names the failing probe" ;;
  *) fail "--debug did not name the failing probe: $DEBUG" ;;
esac
case "$DEBUG" in
  *"30-hangs.sh: silent, past its budget"*) pass "--debug names the probe past its budget" ;;
  *) fail "--debug did not name the hanging probe: $DEBUG" ;;
esac
case "$DEBUG" in
  *"50-empty.sh: silent, printed nothing"*) pass "--debug names the empty probe" ;;
  *) fail "--debug did not name the empty probe: $DEBUG" ;;
esac

EMPTY_DIR="$ROOT/empty"
mkdir -p "$EMPTY_DIR"
EMPTY_OUT="$(python3 "$RUNNER" --root "$ROOT" --dir "$EMPTY_DIR" 2>&1)"
if [ -z "$EMPTY_OUT" ]; then pass "an empty directory prints nothing"; else fail "empty directory printed: $EMPTY_OUT"; fi
MISSING_OUT="$(python3 "$RUNNER" --root "$ROOT" --dir "$ROOT/does-not-exist" 2>&1)"
MISSING_STATUS=$?
if [ -z "$MISSING_OUT" ] && [ "$MISSING_STATUS" -eq 0 ]; then pass "a missing directory is silent and exits 0"; else fail "missing directory: status $MISSING_STATUS output $MISSING_OUT"; fi

# The total budget stops launching probes.
TOTAL_DIR="$ROOT/total"
mkdir -p "$TOTAL_DIR"
cat > "$TOTAL_DIR/10-slow.sh" <<'EOF'
sleep 0.6
echo "slow one"
EOF
cat > "$TOTAL_DIR/20-slow.sh" <<'EOF'
sleep 0.6
echo "slow two"
EOF
cat > "$TOTAL_DIR/30-fast.sh" <<'EOF'
echo "fast three"
EOF
TOTAL_OUT="$(python3 "$RUNNER" --root "$ROOT" --dir "$TOTAL_DIR" --budget 1 --total 1 --debug 2>"$ROOT/total-stderr")"
case "$TOTAL_OUT" in
  *"slow one"*"slow two"*) : ;;
  *) fail "slow probes within their own budget should print: $TOTAL_OUT" ;;
esac
case "$TOTAL_OUT" in
  *"fast three"*) fail "a probe past the total budget was launched" ;;
  *) pass "the total budget stops launching probes" ;;
esac
case "$(cat "$ROOT/total-stderr")" in
  *"30-fast.sh: skipped, total budget spent"*) pass "--debug names the probe the total budget skipped" ;;
  *) fail "--debug did not name the skipped probe: $(cat "$ROOT/total-stderr")" ;;
esac

# The card cache: within its age limit a card reprints the last one while
# the probes' inputs are unchanged, and runs them again when one moves. The
# nonce file is outside the key, so it shows which card printed.
CACHED="$ROOT/cached"
mkdir -p "$CACHED" "$ROOT/memory/sessions/2026-11"
cat > "$CACHED/10-nonce.sh" <<'EOF'
echo "nonce $(cat "$EGREGORE_ROOT/nonce") for ${EGREGORE_AUTHOR}"
EOF
CARD="$ROOT/.egregore/runtime/reflexes/card-claude.json"
# A probe past its budget keeps no card, so a loaded machine gets five seconds;
# a later --budget overrides it.
card() {
  env -u CODEX_SANDBOX -u APP_SANDBOX_CONTAINER_ID python3 "$RUNNER" --root "$ROOT" --dir "$CACHED" --budget 5 "$@" 2>&1
}
expect() {
  if [ "$1" = "  ◦ nonce $2" ]; then pass "$3"; else fail "$3: printed ${1:-<nothing>}"; fi
}
echo one > "$ROOT/nonce"
card >/dev/null
echo two > "$ROOT/nonce"
expect "$(card)" "one for tester" "a second card reprints the first while its inputs are unchanged"
if [ -f "$CARD" ] && [ ! -e "$ROOT/tmp" ]; then pass "the card is kept in the instance's runtime state"; else fail "no card at $CARD, or a write in tmp/"; fi
printf -- '---\nkind: session-record\n---\n' > "$ROOT/memory/sessions/2026-11/03-tester-session.md"
expect "$(card)" "two for tester" "a new session record runs the probes again"
echo three > "$ROOT/nonce"
printf '# edited\n' >> "$CACHED/10-nonce.sh"
expect "$(card)" "three for tester" "an edited probe runs the probes again"
echo four > "$ROOT/nonce"
printf '{"github_username":"tester","telemetry":{"seen":1}}\n' > "$ROOT/.egregore-state.json"
expect "$(card)" "three for tester" "a state field no probe reads keeps the card"
printf '{"github_username":"renamed"}\n' > "$ROOT/.egregore-state.json"
expect "$(card)" "four for renamed" "a changed name runs the probes again"
echo five > "$ROOT/nonce"
expect "$(card --debug)" "five for renamed" "--debug runs the probes"
expect "$(card)" "four for renamed" "--debug leaves the card as it was"
python3 - "$CARD" <<'EOF'
import json, sys
card = json.load(open(sys.argv[1]))
card["at"] -= 601
json.dump(card, open(sys.argv[1], "w"))
EOF
expect "$(card)" "five for renamed" "a card past its age limit runs the probes again"
echo six > "$ROOT/nonce"
expect "$(CODEX_SANDBOX=workspace-write python3 "$RUNNER" --root "$ROOT" --dir "$CACHED" 2>&1)" "six for renamed" \
  "a sandboxed card runs the probes"
expect "$(card)" "five for renamed" "a sandboxed card keeps no card"
cat > "$CACHED/20-hangs.sh" <<'EOF'
sleep 5
EOF
expect "$(card --budget 0.3)" "six for renamed" "a card with a probe past its budget runs the probes"
echo seven > "$ROOT/nonce"
expect "$(card --budget 0.3)" "seven for renamed" "and keeps no card of it"
rm "$CACHED/20-hangs.sh"
chmod 500 "${CARD%/*}"
if [ ! -w "${CARD%/*}" ]; then
  echo eight > "$ROOT/nonce"
  printf '# edited again\n' >> "$CACHED/10-nonce.sh"
  OUT="$(card)"; STATUS=$?
  if [ "$STATUS" -eq 0 ]; then expect "$OUT" "eight for renamed" "an unwritable cache still prints the card"; else fail "unwritable cache: exit $STATUS"; fi
fi
chmod 700 "${CARD%/*}"

# The wrapper resolves the project root itself. --debug keeps the check from
# leaving a card in this checkout's runtime state.
WRAP="$(bash "$REPO_ROOT/bin/reflexes.sh" --dir "$EMPTY_DIR" --debug 2>&1)"
if [ -z "$WRAP" ]; then pass "bin/reflexes.sh runs the runner against the project root"; else fail "wrapper printed: $WRAP"; fi

echo "reflexes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
