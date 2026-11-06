#!/usr/bin/env bash
# The shells reflex: sums yesterday's worktree-guard refusals for the current
# person; three or more prints the line; other days, other people and fewer
# refusals print nothing.
# Usage: bash tests/test-reflex-shells.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$REPO_ROOT/bin/reflexes/40-shells.py"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/egregore-reflex-shells.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
FIXTURE="$ROOT/make.py"
cat > "$FIXTURE" <<'EOF'
import datetime, pathlib, sys
memory, case = pathlib.Path(sys.argv[1]), sys.argv[2]
today = datetime.date.today()
yesterday = today - datetime.timedelta(days=1)
def record(day, author, slug, refusals):
    folder = memory / "sessions" / day.strftime("%Y-%m")
    folder.mkdir(parents=True, exist_ok=True)
    text = ("---\nkind: session-record\nfrom: " + author + "\ndate: " + day.isoformat()
            + "\n---\n# Session: " + slug + "\n\n## Friction\n- tool errors: 0\n- worktree-guard refusals: "
            + str(refusals) + "\n- recall failures: 0\n")
    (folder / (day.strftime("%d-") + author + "-" + slug + ".md")).write_text(text)
if case == "three":
    record(yesterday, "tester", "one", 2)
    record(yesterday, "tester", "two", 1)
elif case == "two":
    record(yesterday, "tester", "one", 2)
elif case == "others":
    record(yesterday, "someone", "one", 9)
    record(today, "tester", "today", 9)
    record(yesterday - datetime.timedelta(days=1), "tester", "older", 9)
elif case == "unowned":
    record(yesterday, "tester", "one", 4)
EOF

run_case() {
  local name="$1" author="$2"
  rm -rf "$ROOT/memory"
  mkdir -p "$ROOT/memory"
  python3 "$FIXTURE" "$ROOT/memory" "$name"
  EGREGORE_MEMORY="$ROOT/memory" EGREGORE_AUTHOR="$author" EGREGORE_ROOT="$ROOT" python3 "$PROBE"
}

OUT="$(run_case three tester)"
case "$OUT" in
  "3 refused shell commands yesterday across 2 sessions · plain forms: .claude/context/plain-shell.md") pass "three refusals across two records print the line" ;;
  *) fail "three refusals: got '$OUT'" ;;
esac
OUT="$(run_case two tester)"
if [ -z "$OUT" ]; then pass "two refusals print nothing"; else fail "two refusals printed: $OUT"; fi
OUT="$(run_case others tester)"
if [ -z "$OUT" ]; then pass "other people's and other days' records are ignored"; else fail "others printed: $OUT"; fi
OUT="$(run_case unowned '')"
case "$OUT" in
  "4 refused shell commands yesterday across 1 session · plain forms: .claude/context/plain-shell.md") pass "without an author every record of the day counts" ;;
  *) fail "unowned: got '$OUT'" ;;
esac
OUT="$(EGREGORE_MEMORY="$ROOT/none" EGREGORE_AUTHOR=tester python3 "$PROBE")"
STATUS=$?
if [ -z "$OUT" ] && [ "$STATUS" -eq 0 ]; then pass "a missing memory directory is silent"; else fail "missing memory: status $STATUS output $OUT"; fi

echo "reflex shells: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
