#!/usr/bin/env bash
# The cost reflex: seven days of the current person's session records, priced
# by harness and unpriced apart; a record priced at list counts under Codex;
# older records, other people and an empty memory print nothing; 150 records
# stay inside the runner's one-second budget.
# Usage: bash tests/test-reflex-cost.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$REPO_ROOT/bin/reflexes/30-cost.py"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/egregore-reflex-cost.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
FIXTURE="$ROOT/make.py"
cat > "$FIXTURE" <<'EOF'
import datetime, json, pathlib, sys
memory, case = pathlib.Path(sys.argv[1]), sys.argv[2]
today = datetime.date.today()
count = 0
def record(days_ago, author, cost, source, harness=None, tokens=None, name=None):
    global count
    count += 1
    day = today - datetime.timedelta(days=days_ago)
    folder = memory / "sessions" / day.strftime("%Y-%m")
    folder.mkdir(parents=True, exist_ok=True)
    fields = [("kind", "session-record"), ("from", json.dumps(author)), ("date", json.dumps(day.isoformat())),
              ("session", json.dumps("fixture-%d" % count)), ("detail", "outline"), ("status", "final"),
              ("record_revision", "1"), ("cost_usd", json.dumps(cost)), ("cost_source", source),
              ("duration", json.dumps("1h"))]
    if harness:
        fields.append(("harness", json.dumps(harness)))
    lines = ["---"] + [key + ": " + value for key, value in fields] + ["---", "", "# Session: fixture", "",
             "## Summary", "", "1h on fixture; 0 commits, 0 files, 0 recalls (0 failed)", "", "## Cost",
             "- total: $%.2f (%s)" % (cost, source)]
    if tokens is not None:
        lines.append("- tokens: %d input (%d cached), 1000 output; cost not derived (no price for codex-auto-review)"
                     % (tokens, tokens // 2))
    lines.append("- model calls: 3")
    stem = name or "%s-%s-topic-%d" % (day.strftime("%d"), author, count)
    (folder / (stem + ".md")).write_text("\n".join(lines) + "\n")
if case == "window":
    record(0, "tester", 12.5, "estimate")
    record(6, "tester", 7.5, "ledger")
    record(7, "tester", 100.0, "estimate")
    record(30, "tester", 100.0, "estimate")
elif case == "split":
    record(0, "tester", 120.4, "estimate")
    record(1, "tester", 30.1, "list price", harness="codex")
    record(2, "tester", 0.0, "unavailable", harness="codex", tokens=17478720)
    record(3, "tester", 0.0, "unavailable", harness="codex", tokens=2021280)
elif case == "list":
    # A held stub keeps no harness key; list price alone says Codex.
    record(0, "tester", 41.0, "list price", name=today.strftime("%d") + "-tester-held-a1b2c3d4")
    record(1, "tester", 9.0, "estimate")
elif case == "others":
    record(0, "someone", 500.0, "estimate")
    record(1, "tester-two", 300.0, "estimate")
    record(2, "someone", 0.0, "unavailable", harness="codex", tokens=9000000)
elif case == "mixed":
    record(0, "tester", 5.0, "estimate")
    record(0, "someone", 500.0, "estimate")
    record(1, "tester-two", 300.0, "estimate")
elif case == "unpriced":
    record(0, "tester", 0.0, "unavailable", harness="codex")
elif case == "zero":
    record(0, "tester", 0.0, "estimate")
elif case == "strange":
    # A label the probe does not know, and a cost that is not a number.
    record(0, "tester", 3.0, "estimate", harness="Some Topic Text")
    record(1, "tester", float("inf"), "ledger")
elif case == "many":
    # 150 records over 75 days; the window holds 14 of them.
    for days_ago in range(75):
        record(days_ago, "tester", 1.0, "estimate")
        record(days_ago, "tester", 0.0, "unavailable", harness="codex", tokens=1000000)
EOF

run_case() {
  local name="$1" author="$2"
  rm -rf "$ROOT/memory"
  mkdir -p "$ROOT/memory"
  python3 "$FIXTURE" "$ROOT/memory" "$name"
  EGREGORE_MEMORY="$ROOT/memory" EGREGORE_AUTHOR="$author" EGREGORE_ROOT="$ROOT" python3 "$PROBE"
}

expect() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label: got '$got', want '$want'"; fi
}

expect "the window holds today and the six days before it" "$(run_case window tester)" \
  "7 days: \$20.00 priced (Claude \$20.00)"
expect "priced by harness, unpriced apart with their input tokens" "$(run_case split tester)" \
  "7 days: \$150.50 priced (Claude \$120.40, Codex \$30.10) · 2 unpriced sessions, 19.5M input tokens"
expect "a session priced at list counts under Codex" "$(run_case list tester)" \
  "7 days: \$50.00 priced (Claude \$9.00, Codex \$41.00)"
expect "other people's records print nothing" "$(run_case others tester)" ""
expect "other people and a longer name sharing the prefix are left out" "$(run_case mixed Tester)" \
  "7 days: \$5.00 priced (Claude \$5.00)"
expect "an unpriced session without a token line is still counted" "$(run_case unpriced tester)" \
  "7 days: 1 unpriced session"
expect "records that add up to nothing print nothing" "$(run_case zero tester)" ""
expect "an unknown harness prints as Other and a non-finite cost as nothing" "$(run_case strange tester)" \
  "7 days: \$3.00 priced (Other \$3.00)"
expect "no author prints nothing" "$(run_case split '')" ""

rm -rf "$ROOT/memory"
mkdir -p "$ROOT/memory"
OUT="$(EGREGORE_MEMORY="$ROOT/memory" EGREGORE_AUTHOR=tester python3 "$PROBE")"
STATUS=$?
if [ -z "$OUT" ] && [ "$STATUS" -eq 0 ]; then pass "an empty memory is silent"; else fail "empty memory: status $STATUS output $OUT"; fi
OUT="$(EGREGORE_MEMORY="$ROOT/none" EGREGORE_AUTHOR=tester python3 "$PROBE")"
STATUS=$?
if [ -z "$OUT" ] && [ "$STATUS" -eq 0 ]; then pass "a missing memory directory is silent"; else fail "missing memory: status $STATUS output $OUT"; fi

rm -rf "$ROOT/memory"
mkdir -p "$ROOT/memory"
python3 "$FIXTURE" "$ROOT/memory" many
COUNT="$(find "$ROOT/memory/sessions" -name '*.md' | wc -l | tr -d ' ')"
TIMING="$(EGREGORE_MEMORY="$ROOT/memory" EGREGORE_AUTHOR=tester python3 - "$PROBE" <<'EOF'
import subprocess, sys, time
start = time.monotonic()
result = subprocess.run([sys.executable, sys.argv[1]], capture_output=True, text=True, timeout=10)
elapsed = time.monotonic() - start
print("%.3f %s" % (elapsed, result.stdout.strip()))
EOF
)"
SECONDS_TAKEN="${TIMING%% *}"
LINE="${TIMING#* }"
expect "150 records: only the window's files are read" "$COUNT $LINE" \
  "150 7 days: \$7.00 priced (Claude \$7.00) · 7 unpriced sessions, 7M input tokens"
if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)" "$SECONDS_TAKEN"; then
  pass "150 records finish inside the one-second budget (${SECONDS_TAKEN}s)"
else
  fail "150 records took ${SECONDS_TAKEN}s"
fi

echo "reflex cost: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
