#!/usr/bin/env bash
# The nightly reflex against a gh stub that serves canned runs and jobs and
# logs every call, so nothing reaches GitHub: red once is silent, twice names
# the failing jobs, three times proposes an owner; push runs count like the
# nightly dispatch and a superseded (cancelled) run is skipped; a warm cache
# makes no gh call; no gh, a signed-out gh, or no ci.yml is silent.
# Usage: bash tests/test-reflex-nightly.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$REPO_ROOT/bin/reflexes/20-nightly.sh"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-reflex-nightly.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STUB_BIN="$WORK/stub"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub: canned runs and jobs from $GH_STUB_DIR; every call logged.
printf '%s\n' "$*" >> "$GH_STUB_LOG"
if [ -n "${GH_STUB_SIGNED_OUT:-}" ]; then
  echo "To get started with GitHub CLI, please run:  gh auth login" >&2
  exit 4
fi
case "$*" in
  *"/jobs?"*) cat "$GH_STUB_DIR/jobs.json" ;;
  *"/runs?"*) cat "$GH_STUB_DIR/runs.json" ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$STUB_BIN/gh"

ROOT="$WORK/root"
mkdir -p "$ROOT/.github/workflows"
: > "$ROOT/.github/workflows/ci.yml"
CACHE="$ROOT/tmp/reflexes/nightly.json"
cat > "$WORK/jobs.json" <<'EOF'
{"total_count": 4, "jobs": [
  {"name": "plan / plan", "status": "completed", "conclusion": "success"},
  {"name": "Mind fast contracts", "status": "completed", "conclusion": "failure"},
  {"name": "Suite baseline — shard 1", "status": "completed", "conclusion": "cancelled"},
  {"name": "Full CI result — 2918968fe862e3902726bc64cc4140dd2b1dbf0c", "status": "completed", "conclusion": "failure"}
]}
EOF

# runs CONCLUSION...: the develop runs of event $EVENT, latest first; "" is a
# run in progress.
EVENT=workflow_dispatch
runs() {
  printf '%s\n' "$@" | jq -R -s --arg event "$EVENT" '
    split("\n")[:-1] | to_entries
    | {total_count: length,
       workflow_runs: map({id: (1000 - .key), event: $event, head_branch: "develop",
                           status: (if .value == "" then "in_progress" else "completed" end),
                           conclusion: (if .value == "" then null else .value end),
                           created_at: "2026-10-16T02:23:00Z"})}' > "$WORK/runs.json"
}
# probe: run the probe cold or warm as the cache stands; sets OUT, STATUS, LOG.
probe() {
  : > "$WORK/gh.log"
  OUT="$(PATH="$STUB_BIN:$PATH" GH_STUB_DIR="$WORK" GH_STUB_LOG="$WORK/gh.log" EGREGORE_ROOT="$ROOT" \
    bash "$PROBE" 2>"$WORK/stderr")"
  STATUS=$?
  LOG="$(cat "$WORK/gh.log")"
}
calls() { grep -c . "$WORK/gh.log" || true; }
expect_out() {
  if [ "$OUT" = "$2" ] && [ "$STATUS" -eq 0 ]; then pass "$1"; else fail "$1 — exit $STATUS, got '$OUT', wanted '$2'"; fi
}

echo "test-reflex-nightly"

RED2="develop red 2 runs running: Mind fast contracts, Full CI result"
RED3="develop red 3 runs running: Mind fast contracts, Full CI result · propose an owner: /issue"

runs failure success success
rm -f "$CACHE"
probe
expect_out "red once prints nothing" ""
if [ "$(calls)" -eq 1 ] && [ -f "$CACHE" ]; then pass "red once: one request, answer cached"; else fail "red once: $(calls) calls, cache present: $([ -f "$CACHE" ] && echo yes || echo no)"; fi

runs failure failure success
rm -f "$CACHE"
probe
expect_out "red twice names the failing jobs" "$RED2"
case "$LOG" in
  *"actions/runs/1000/jobs?"*) pass "red twice: the jobs come from the latest run" ;;
  *) fail "red twice: no jobs request for run 1000: $LOG" ;;
esac

runs failure failure failure
rm -f "$CACHE"
probe
expect_out "red three nights proposes an owner" "$RED3"

probe
expect_out "a warm cache answers the same" "$RED3"
if [ -z "$LOG" ]; then pass "a warm cache makes no gh call"; else fail "a warm cache called gh: $LOG"; fi

stale="$(jq --argjson at "$(( $(date +%s) - 7 * 3600 ))" '.fetched_at = $at' "$CACHE")"
printf '%s\n' "$stale" > "$CACHE"
runs failure failure success
probe
expect_out "a cache older than six hours is read again" "$RED2"

runs "" failure failure failure
rm -f "$CACHE"
probe
expect_out "a run still in progress is not a verdict" "$RED3"

runs success failure failure
rm -f "$CACHE"
probe
expect_out "green latest prints nothing" ""

# The push run each merge starts counts as a verdict, and the query asks for
# every event on develop rather than the dispatch alone.
EVENT=push
runs failure failure success
rm -f "$CACHE"
probe
EVENT=workflow_dispatch
expect_out "push runs count as verdicts" "$RED2"
case "$LOG" in
  *"event="*) fail "the runs query still filters by event: $LOG" ;;
  *"actions/workflows/ci.yml/runs?branch=develop&per_page=10"*) pass "the runs query reads every event on develop" ;;
  *) fail "unexpected runs query: $LOG" ;;
esac

# A run cancelled because a newer merge superseded it is no verdict: it
# neither counts nor breaks the streak, and the jobs come from the newest
# verdict.
runs cancelled failure failure success
rm -f "$CACHE"
probe
expect_out "a superseded run is skipped" "$RED2"
case "$LOG" in
  *"actions/runs/999/jobs?"*) pass "the jobs come from the newest verdict" ;;
  *) fail "no jobs request for run 999: $LOG" ;;
esac

runs cancelled cancelled failure success
rm -f "$CACHE"
probe
expect_out "red once behind superseded runs prints nothing" ""

# Many failing jobs: the line stays inside the runner's 160 characters and
# keeps the proposal.
jq -n '{total_count: 12, jobs: [range(12) | {name: "A long failing job name number \(.)", status: "completed", conclusion: "failure"}]}' > "$WORK/jobs.json"
runs failure failure failure
rm -f "$CACHE"
probe
case "$OUT" in
  *"more · propose an owner: /issue") if [ "${#OUT}" -le 160 ]; then pass "many failing jobs fit in one line"; else fail "line is ${#OUT} characters"; fi ;;
  *) fail "many failing jobs: '$OUT'" ;;
esac

# No gh on PATH: only the tools the probe needs, linked into one directory.
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for tool in jq date mkdir mktemp mv rm cat dirname; do
  found="$(command -v "$tool")" && ln -sf "$found" "$TOOLS/$tool"
done
rm -f "$CACHE"
OUT="$(PATH="$TOOLS" EGREGORE_ROOT="$ROOT" "$BASH" "$PROBE" 2>&1)"
STATUS=$?
expect_out "no gh prints nothing" ""
if [ ! -f "$CACHE" ]; then pass "no gh writes no cache"; else fail "no gh wrote a cache"; fi

export GH_STUB_SIGNED_OUT=1
probe
unset GH_STUB_SIGNED_OUT
expect_out "a signed-out gh prints nothing" ""
if [ ! -f "$CACHE" ]; then pass "a signed-out gh writes no cache"; else fail "a signed-out gh wrote a cache"; fi

rm -f "$ROOT/.github/workflows/ci.yml"
probe
expect_out "an instance without ci.yml prints nothing" ""
if [ -z "$LOG" ]; then pass "an instance without ci.yml makes no gh call"; else fail "called gh without ci.yml: $LOG"; fi
: > "$ROOT/.github/workflows/ci.yml"

# Under the runner, with the sigil, the environment and the one-second budget.
cat > "$WORK/jobs.json" <<'EOF'
{"total_count": 1, "jobs": [{"name": "Mind fast contracts", "status": "completed", "conclusion": "failure"}]}
EOF
runs failure failure failure
rm -f "$CACHE"
PROBES="$WORK/probes"
mkdir -p "$PROBES"
ln -sf "$PROBE" "$PROBES/20-nightly.sh"
RUNNER_OUT="$(PATH="$STUB_BIN:$PATH" GH_STUB_DIR="$WORK" GH_STUB_LOG="$WORK/gh.log" \
  python3 "$REPO_ROOT/bin/lib/reflexes.py" --root "$ROOT" --dir "$PROBES" 2>&1)"
if [ "$RUNNER_OUT" = "  ◦ develop red 3 runs running: Mind fast contracts · propose an owner: /issue" ]; then
  pass "the runner prints the line on the card"
else
  fail "runner printed '$RUNNER_OUT'"
fi

echo "reflex-nightly: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
