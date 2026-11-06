#!/usr/bin/env bash
# The merge gate against a gh stub that serves canned JSON and logs every
# call, so nothing reaches GitHub: green merges; pending, red without a
# receipt, a receipt that misses a check, and a wrong base refuse; a full
# receipt is posted before the merge; --dry-run never posts or merges; a
# managed repo merges into its own integration branch. Each merge and each
# refusal of red checks without a receipt appends one line to the gate
# ledger of a fixture checkout, with the head's CI attempts and flakes.
# Usage: bash tests/test-merge-gate.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-merge-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# The gate runs from a fixture checkout whose bin is this one, with its own
# memory repository, state, session id and HOME: no case writes this
# checkout's memory, and no harness session leaks into a ledger line.
unset EGREGORE_MEMORY_DIR EGREGORE_NATIVE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
PROJECT="$WORK/project"
MEMORY="$WORK/memory"
LEDGER="$MEMORY/sessions/gate.jsonl"
mkdir -p "$PROJECT" "$MEMORY/sessions" "$WORK/home"
ln -s "$REPO_ROOT/bin" "$PROJECT/bin"
ln -s "$MEMORY" "$PROJECT/memory"
jq -n '{github_username: "tester", display_name: "Tester", actor_id: "fixture-actor"}' > "$PROJECT/.egregore-state.json"
printf '%s\n' 20261016T120712-tester-4242 > "$PROJECT/.egregore-session-id"
memory_git() { HOME="$WORK/home" git -C "$MEMORY" "$@"; }
memory_git init -q 2>/dev/null
memory_git config user.name Fixture
memory_git config user.email fixture@example.invalid
printf 'fixture\n' > "$MEMORY/seed"
memory_git add seed
memory_git commit -qm 'fixture seed'
printf '%s\n' '{"features":{"session_records":{"enabled":true}}}' > "$PROJECT/egregore.json"
GATE="$PROJECT/bin/merge-gate.sh"
STUB_BIN="$WORK/stub"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub: canned JSON per subcommand from $GH_STUB_DIR; every call logged.
printf '%s\n' "$*" >> "$GH_STUB_LOG"
case "$1 ${2:-}" in
  "api "*)
    # The actions API: the head's runs and the jobs of every attempt of one,
    # each from a file in the case; NAME.fail beside it fails that call.
    case "$2" in
      */actions/runs\?head_sha=*) name=api-runs empty='{"total_count":0,"workflow_runs":[]}' ;;
      */actions/runs/*/jobs\?filter=all*) name=api-jobs empty='{"total_count":0,"jobs":[]}' ;;
      *) echo "gh stub: unexpected call: $*" >&2; exit 64 ;;
    esac
    if [ -f "$GH_STUB_DIR/$name.fail" ]; then echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
    if [ -f "$GH_STUB_DIR/$name.json" ]; then cat "$GH_STUB_DIR/$name.json"; else printf '%s\n' "$empty"; fi ;;
  "pr view")
    if [[ "$*" == *"--json baseRefOid"* ]]; then
      if [ -f "$GH_STUB_DIR/advance-base" ] && [ -f "$GH_STUB_DIR/base-read" ]; then
        printf '%s\n' '{"baseRefOid":"ffffffffffffffffffffffffffffffffffffffff"}'
        exit 0
      fi
      touch "$GH_STUB_DIR/base-read"
    fi
    cat "$GH_STUB_DIR/pr.json" ;;

  "pr checks")
    if [ -f "$GH_STUB_DIR/checks.json" ]; then cat "$GH_STUB_DIR/checks.json"; exit 0; fi
    echo "no checks reported on the 'dev/tester/topic' branch" >&2
    exit 1 ;;
  "pr comment")
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--body-file" ]; then cp "$2" "$GH_STUB_DIR/comment.md"; fi
      shift
    done
    echo "https://github.com/example/instance/pull/101#issuecomment-1" ;;
  "pr merge") exit "${GH_STUB_MERGE_STATUS:-0}" ;;
  "run list") if [ -f "$GH_STUB_DIR/runs.json" ]; then cat "$GH_STUB_DIR/runs.json"; else echo '[]'; fi ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$STUB_BIN/gh"

# bin/agent.sh reads the checkout's own egregore.json; every other case reads
# a fixture with one managed repo through CONFIG, as base-branch.sh does.
REAL_BASE="$(bash "$REPO_ROOT/bin/base-branch.sh")" || { echo "cannot resolve the integration branch"; exit 1; }
REAL_REPO="$(bash "$REPO_ROOT/bin/config-get.sh" repo 2>/dev/null)" || REAL_REPO=example/instance
BASE=develop
OTHER=main
jq -n '{github_org: "example", repo_name: "instance", base_branch: "develop",
        repos: [{name: "site", description: "Managed fixture repo", base_branch: "main"}]}' > "$WORK/egregore.json"
export CONFIG="$WORK/egregore.json"
SHA=0123456789abcdef0123456789abcdef01234567
SHORT=01234567
URL=https://github.com/example/instance/pull/101
RUN=https://github.com/example/instance/actions/runs/7

# new_case NAME [BASE] [DRAFT] [URL]: a fixture directory with the PR, no checks yet.
new_case() {
  local dir="$WORK/$1" url="${4:-$URL}"
  mkdir -p "$dir"
  jq -n --arg base "${2:-$BASE}" --argjson draft "${3:-false}" --arg sha "$SHA" --arg url "$url" \
    '{number: ($url | split("/") | last | tonumber), url: $url, state: "OPEN", isDraft: $draft,
      mergeable: "MERGEABLE", baseRefName: $base, headRefName: "dev/tester/topic", headRefOid: $sha, baseRefOid: $sha}' > "$dir/pr.json"
  CASE="$dir"
}
# checks STATE|NAME...: the checks gh pr checks serves, linked to run 7 job N.
checks() {
  printf '%s\n' "$@" | jq -R -s --arg run "$RUN" '
    split("\n") | map(select(length > 0)) | to_entries
    | map((.value | split("|")) as $field
          | {name: $field[1], state: $field[0], link: ($run + "/job/" + ((.key + 1) | tostring))})' \
    > "$CASE/checks.json"
}
# runs ID:ATTEMPT[:PATH]...: the head's workflow runs the actions API serves.
runs() {
  printf '%s\n' "$@" | jq -R -s --arg sha "$SHA" '
    split("\n") | map(select(length > 0) | split(":")
      | {id: (.[0] | tonumber), run_attempt: (.[1] | tonumber), path: (.[2] // ".github/workflows/ci.yml"),
         head_sha: $sha, status: "completed"})
    | {total_count: length, workflow_runs: .}' > "$CASE/api-runs.json"
}
# ci_jobs ATTEMPT:CONCLUSION|JOB...: the run's jobs across its attempts (api-jobs).
ci_jobs() {
  printf '%s\n' "$@" | jq -R -s '
    split("\n") | map(select(length > 0) | split("|") | (.[0] | split(":")) as $run
      | {name: .[1], conclusion: $run[1], run_attempt: ($run[0] | tonumber), status: "completed"})
    | {total_count: length, jobs: .}' > "$CASE/api-jobs.json"
}
# The gate ledger: its line count, and a jq filter over its newest line
# (object keys sorted, so a comparison does not hang on their order).
ledger_lines() { if [ -f "$LEDGER" ]; then awk 'END { print NR }' "$LEDGER"; else echo 0; fi; }
newest() { tail -n 1 "$LEDGER" | jq -cS "$1"; }
# The JSON after "ledger: would append " in the gate's output.
preview() { printf '%s\n' "$OUT" | sed -n 's/^ledger: would append //p' | jq -cS "$1"; }
# line N TEXT: the Nth line of TEXT.
line() { printf '%s\n' "$2" | sed -n "$1p"; }
# gate ARGS...: run the gate in the current case; sets OUT, ERR, STATUS, LOG
# and ADDED, the lines it added to the ledger. The gate runs in a Codex
# thread unless NO_SESSION is set: then no harness session variable is set.
gate() {
  : > "$CASE/gh.log"
  local before
  before="$(ledger_lines)"
  if [ -n "${NO_SESSION:-}" ]; then
    OUT="$(cd "$CASE" && env -u EGREGORE_NATIVE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID \
      HOME="$WORK/home" PATH="$STUB_BIN:$PATH" GH_STUB_DIR="$CASE" GH_STUB_LOG="$CASE/gh.log" \
      bash "$GATE" "$@" 2>"$CASE/stderr")"
  else
    OUT="$(cd "$CASE" && HOME="$WORK/home" CODEX_THREAD_ID="${CODEX_THREAD_ID:-fixture-thread}" PATH="$STUB_BIN:$PATH" GH_STUB_DIR="$CASE" GH_STUB_LOG="$CASE/gh.log" \
      bash "$GATE" "$@" 2>"$CASE/stderr")"
  fi
  STATUS=$?
  ERR="$(cat "$CASE/stderr")"
  LOG="$(cat "$CASE/gh.log")"
  ADDED=$(( $(ledger_lines) - before ))
}
expect_added() {
  if [ "$ADDED" -eq "$1" ]; then pass "$2"; else fail "$2 (added $ADDED)"; tail -n 2 "$LEDGER" 2>/dev/null; fi
}
expect_line() {
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1"; printf '  --- wanted: %s\n  --- got:    %s\n' "$2" "$3"; fi
}
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
expect_status() {
  if [ "$STATUS" -eq "$1" ]; then pass "$2"; else fail "$2 (exit $STATUS)"; printf '%s\n' "$OUT" "$ERR"; fi
}
expect_in() {
  if has "$2" "$3"; then pass "$1"; else fail "$1"; printf '  --- wanted: %s\n  --- in:\n%s\n' "$2" "$3"; fi
}
expect_not_in() {
  if has "$2" "$3"; then fail "$1"; printf '  --- unwanted: %s\n  --- in:\n%s\n' "$2" "$3"; else pass "$1"; fi
}

echo "test-merge-gate"

# --- Green merges -----------------------------------------------------------
new_case green
checks "SUCCESS|plan / plan" "SUCCESS|shellcheck" "SUCCESS|test"
# One ci.yml run in its first attempt; another workflow's third attempt does not count.
runs "7:1" "8:3:.github/workflows/pr-format.yml"
gate 101
expect_status 0 "green: exits 0"
expect_line "green: prints the merge line first" "merged $SHA into $BASE: all 3 checks green" "$(line 1 "$OUT")"
expect_in "green: merges the classified head with a merge commit" "pr merge $URL --merge --match-head-commit $SHA" "$LOG"
expect_not_in "green: posts no comment" "pr comment" "$LOG"
expect_line "green: then says the ledger took one line, and nothing else" "ledger: gate.jsonl +1" "$(printf '%s\n' "$OUT" | sed -n '2,$p')"
expect_in "green: reads the head's CI runs through the actions API" \
  "api repos/example/instance/actions/runs?head_sha=$SHA&per_page=20 --hostname github.com" "$LOG"
expect_not_in "green: one attempt reads no jobs" "/jobs" "$LOG"
expect_added 1 "green: the ledger takes one line"
expect_line "green: the line holds the decision, one attempt, no flake or recovery, the author and the session" \
  "$(jq -ncS --arg sha "$SHA" '{kind: "merge", pr: 101, head: $sha, base: "develop", repo: "example/instance",
     checks: {green: 3, neutral: 0, red: 0}, attempts: 1, flaked: [], recovered: [], receipt: false, by: "fixture-actor",
     session: "fixture-thread"}')" "$(newest 'del(.at)')"
expect_line "green: the fields come in the schema's order" \
  '["at","kind","pr","head","base","repo","checks","attempts","flaked","recovered","receipt","by","session"]' \
  "$(newest 'keys_unsorted')"
expect_line "green: at is the UTC time, to the second" true \
  "$(newest '.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+]00:00$")')"
expect_line "green: .gitattributes merges the ledger as a union" "gate.jsonl merge=union" \
  "$(grep -xF 'gate.jsonl merge=union' "$MEMORY/sessions/.gitattributes" 2>/dev/null)"
expect_line "green: the line is committed in memory" "chore(sessions): record gate verdict for #101" \
  "$(memory_git log -1 --format=%s)"
expect_line "green: the commit holds the ledger and its merge rule" "sessions/.gitattributes sessions/gate.jsonl" \
  "$(memory_git show --name-only --format= HEAD | sort | tr '\n' ' ' | sed 's/ $//')"
expect_line "green: nothing is left uncommitted" "" "$(memory_git status --porcelain -- sessions)"
FIRST_LINE="$(sed -n 1p "$LEDGER")"

new_case neutral
checks "SUCCESS|plan / plan" "SKIPPED|Full CI result" "NEUTRAL|advisory" "SUCCESS|test"
gate "$URL"
expect_status 0 "skipped and neutral checks merge, by URL"
expect_in "neutral checks are counted apart" "merged $SHA into $BASE: all 2 checks green, 2 neutral" "$OUT"
expect_added 1 "a second merge appends a second line"
expect_line "a second merge leaves the first line as written" "$FIRST_LINE" "$(sed -n 1p "$LEDGER")"
expect_line "neutral checks are counted in the line" '{"green":2,"neutral":2,"red":0}' "$(newest '.checks')"
expect_line "no CI run on the head: no attempts, nothing flaked or recovered" '[false,[],[]]' \
  "$(newest '[has("attempts"), .flaked, .recovered]')"

# --- The head's CI attempts and flakes ---------------------------------------
# Run 77 is the head's latest ci.yml run, in attempt 2, and one listing holds
# the jobs of both attempts. In attempt 1 one job failed and the aggregate
# failed with it, and one job was cancelled: the failed job flaked, the
# cancelled one recovered, and the job that passed in attempt 1 was never run
# again. Run 70 is older and another workflow's higher attempt does not count.
new_case flaked
checks "SUCCESS|plan / plan" "SUCCESS|Mind fast contracts" "SUCCESS|test"
runs "70:1" "77:2" "78:5:.github/workflows/pr-format.yml"
ci_jobs "1:success|plan / plan" "1:failure|Mind fast contracts" "1:cancelled|test" "1:failure|Full CI result — $SHA" \
  "2:success|Mind fast contracts" "2:success|test" "2:success|Full CI result — $SHA"
export CLAUDE_CODE_SESSION_ID=claude-fixture-session
gate 101
unset CLAUDE_CODE_SESSION_ID
expect_status 0 "a re-run head merges"
expect_line "a re-run head: the ledger line names the attempts, the job that flaked and the job that recovered" \
  "ledger: gate.jsonl +1 · attempts 2, flaked: Mind fast contracts; recovered: test" "$(line 2 "$OUT")"
expect_line "a re-run head: flaked names the failed job and recovered the cancelled one, neither the aggregate" \
  '{"attempts":2,"flaked":["Mind fast contracts"],"recovered":["test"]}' "$(newest '{attempts, flaked, recovered}')"
expect_in "a re-run head: reads the jobs of every attempt of the latest ci.yml run in one listing" \
  "api repos/example/instance/actions/runs/77/jobs?filter=all&per_page=100 --paginate --hostname github.com" "$LOG"
expect_not_in "a re-run head: never reads the other workflow's jobs" "runs/78/" "$LOG"
expect_not_in "a re-run head: never reads one attempt apart" "/attempts/" "$LOG"
expect_line "a re-run head: the harness session id names the session, not the checkout's file" \
  '"claude-fixture-session"' "$(newest '.session')"

# The shape of #2018: a job killed by its own time limit is cancelled, twice,
# and passes in attempt 3; it recovered, for a cause the listing does not
# hold. A job green in attempt 1 that failed in attempt 2 and passed in 3
# flaked, so every earlier attempt counts; a job cancelled in attempt 1 and
# failed in attempt 2 is a proven flake, never also recovered; the aggregate
# is neither.
new_case recovered
checks "SUCCESS|plan / plan" "SUCCESS|Mind fast contracts" "SUCCESS|test" "SUCCESS|Suite baseline — shard 1"
runs "80:3"
ci_jobs "1:success|plan / plan" "1:cancelled|Mind fast contracts" "1:success|test" \
  "1:cancelled|Suite baseline — shard 1" "1:cancelled|Full CI result — $SHA" \
  "2:cancelled|Mind fast contracts" "2:failure|test" "2:failure|Suite baseline — shard 1" "2:failure|Full CI result — $SHA" \
  "3:success|Mind fast contracts" "3:success|test" "3:success|Suite baseline — shard 1" "3:success|Full CI result — $SHA"
gate 101
expect_status 0 "a thrice-run head merges"
expect_line "a thrice-run head: the ledger line tells the proven flakes from the recovery" \
  "ledger: gate.jsonl +1 · attempts 3, flaked: Suite baseline — shard 1, test; recovered: Mind fast contracts" \
  "$(line 2 "$OUT")"
expect_line "a thrice-run head: a failure in any earlier attempt flaked, a cancel alone recovered, never both" \
  '{"attempts":3,"flaked":["Suite baseline — shard 1","test"],"recovered":["Mind fast contracts"]}' \
  "$(newest '{attempts, flaked, recovered}')"

new_case runs-unread
checks "SUCCESS|plan / plan" "SUCCESS|test"
touch "$CASE/api-runs.fail"
gate 101
expect_status 0 "runs that cannot be read: the merge still exits 0"
expect_line "runs that cannot be read: the ledger line says nothing of attempts" "ledger: gate.jsonl +1" "$(line 2 "$OUT")"
expect_line "runs that cannot be read: no attempts, nothing flaked or recovered" '[false,[],[]]' \
  "$(newest '[has("attempts"), .flaked, .recovered]')"

new_case jobs-unread
checks "SUCCESS|plan / plan" "SUCCESS|test"
runs "7:2"
touch "$CASE/api-jobs.fail"
gate 101
expect_status 0 "jobs that cannot be read: the merge still exits 0"
expect_line "jobs that cannot be read: attempts unknown, nothing flaked or recovered" '[false,[],[]]' \
  "$(newest '[has("attempts"), .flaked, .recovered]')"
expect_line "jobs that cannot be read: the output claims no attempts" "ledger: gate.jsonl +1" "$(line 2 "$OUT")"

new_case runs-garbled
checks "SUCCESS|plan / plan" "SUCCESS|test"
printf 'not json\n' > "$CASE/api-runs.json"
gate 101
expect_status 0 "an unreadable runs answer: the merge still exits 0"
expect_line "an unreadable runs answer: no attempts" false "$(newest 'has("attempts")')"

# --- A decision made outside a harness session ------------------------------
# None of the three session variables is set, though the checkout's session
# file is there: the decision is still recorded, with no session, so its line
# joins no record.
new_case no-session
checks "SUCCESS|plan / plan" "SUCCESS|test"
runs "7:1"
NO_SESSION=1
gate 101
expect_status 0 "outside a harness session: the merge exits 0"
expect_line "outside a harness session: the gate says the ledger took one line" "ledger: gate.jsonl +1" "$(line 2 "$OUT")"
expect_added 1 "outside a harness session: the merge is recorded"
expect_line "outside a harness session: the line carries no session" \
  '["at","kind","pr","head","base","repo","checks","attempts","flaked","recovered","receipt","by"]' "$(newest 'keys_unsorted')"
expect_line "outside a harness session: the line still names who merged" '"fixture-actor"' "$(newest '.by')"
new_case no-session-red
checks "SUCCESS|plan / plan" "FAILURE|lint"
gate 101
unset NO_SESSION
expect_status 2 "outside a harness session: a red refusal still exits 2"
expect_line "outside a harness session: the refusal's ledger line follows it on stderr" "ledger: gate.jsonl +1" \
  "$(printf '%s\n' "$ERR" | tail -n 1)"
expect_line "outside a harness session: the refusal is recorded without a session" '["refuse",false]' \
  "$(newest '[.kind, has("session")]')"

# --- Pending refuses ----------------------------------------------------------
new_case pending
checks "SUCCESS|plan / plan" "IN_PROGRESS|Suite baseline — shard 0" "QUEUED|test" "FAILURE|lint"
gate 101
expect_status 3 "pending: exits 3, even beside a red check"
expect_in "pending: names the running check" "Suite baseline — shard 0 (in_progress)" "$ERR"
expect_in "pending: names the queued check" "test (queued)" "$ERR"
expect_in "pending: counts the red check so far" "2 checks of 4 still pending on $SHORT, 1 red check so far" "$ERR"
expect_not_in "pending: never merges or posts" "pr merge" "$LOG"
expect_not_in "pending: never posts" "pr comment" "$LOG"
expect_added 0 "pending: a hold is not recorded"
expect_not_in "pending: a hold says nothing of the ledger" "ledger:" "$OUT$ERR"

new_case run-going
checks "SUCCESS|plan / plan" "SUCCESS|pr-format"
jq -n --arg run "$RUN" '[{workflowName: "PR Format", status: "completed", url: "https://github.com/example/instance/actions/runs/8"},
                         {workflowName: "CI", status: "in_progress", url: $run}]' > "$CASE/runs.json"
gate 101
expect_status 3 "a workflow run still going holds the merge, though every check so far is green"
expect_in "a workflow run still going: names the run" "CI run (in_progress)  $RUN" "$ERR"
expect_in "a workflow run still going: reads the runs of the head commit" "run list --repo github.com/example/instance --commit $SHA" "$LOG"
expect_not_in "a workflow run still going: never merges" "pr merge" "$LOG"

new_case unreported
gate 101
expect_status 3 "no checks reported yet: exits 3"
expect_in "no checks reported yet: says so" "no checks have reported on $SHORT yet" "$ERR"
expect_not_in "no checks reported yet: never merges" "pr merge" "$LOG"

# --- Red without a receipt refuses -------------------------------------------
new_case red
checks "SUCCESS|plan / plan" "FAILURE|Mind fast contracts" "SUCCESS|test"
runs "7:1"
export CODEX_THREAD_ID=codex-fixture-thread
gate 101
unset CODEX_THREAD_ID
expect_status 2 "red without a receipt: exits 2"
expect_in "red without a receipt: names the job and its link" "Mind fast contracts (failure)  $RUN/job/2" "$ERR"
expect_in "red without a receipt: says how to proceed" "--receipt FILE" "$ERR"
expect_not_in "red without a receipt: never merges" "pr merge" "$LOG"
expect_not_in "red without a receipt: never posts" "pr comment" "$LOG"
expect_line "red without a receipt: nothing on stdout, as before" "" "$OUT"
expect_line "red without a receipt: the refusal still comes first" \
  "merge-gate: refused #101: 1 red check on $SHORT and no receipt" "$(line 1 "$ERR")"
expect_line "red without a receipt: the ledger line follows it on stderr" "ledger: gate.jsonl +1" \
  "$(printf '%s\n' "$ERR" | tail -n 1)"
expect_added 1 "red without a receipt: the refusal is recorded"
expect_line "red without a receipt: a refuse line, its counts, no receipt, the harness session" \
  '{"attempts":1,"checks":{"green":2,"neutral":0,"red":1},"flaked":[],"kind":"refuse","receipt":false,"session":"codex-fixture-thread"}' \
  "$(newest '{kind, checks, attempts, flaked, receipt, session}')"

# --- A receipt that names every red check posts, then merges -----------------
new_case receipt
checks "SUCCESS|plan / plan" "FAILURE|Mind fast contracts" "CANCELLED|Suite baseline — shard 2" "SUCCESS|test"
cat > "$CASE/receipt.md" <<'EOF'
## Merge receipt

CI run 7 on 01234567: two jobs green. Mind fast contracts fails only its latency
reading on the shared runner; issue 1971 tracks it, and this change touches no Mind code.
- Suite baseline — shard 2: cancelled by the runner and green on the previous head.
EOF
# Attempt 2 passed a job that timed out in attempt 1; the red job failed both
# times and the cancelled one was cancelled both times, so nothing recovered.
runs "7:2"
ci_jobs "1:success|plan / plan" "1:failure|Mind fast contracts" "1:timed_out|Suite baseline — shard 1" \
  "1:cancelled|Suite baseline — shard 2" "1:failure|Full CI result — $SHA" \
  "2:failure|Mind fast contracts" "2:success|Suite baseline — shard 1" \
  "2:cancelled|Suite baseline — shard 2" "2:failure|Full CI result — $SHA"
gate 101 --receipt receipt.md
expect_status 0 "full receipt: exits 0"
expect_in "full receipt: prints where the receipt went" "receipt: $URL#issuecomment-1" "$OUT"
expect_in "full receipt: prints the merge line" "merged $SHA into $BASE: 2 green, 2 red under receipt" "$OUT"
expect_line "full receipt: the ledger line comes last and names the timed-out job" \
  "ledger: gate.jsonl +1 · attempts 2, flaked: Suite baseline — shard 1" "$(line 3 "$OUT")"
expect_added 1 "full receipt: the merge is recorded"
expect_line "full receipt: the line says a receipt was posted, what flaked and that nothing recovered" \
  '{"attempts":2,"checks":{"green":2,"neutral":0,"red":2},"flaked":["Suite baseline — shard 1"],"kind":"merge","receipt":true,"recovered":[]}' \
  "$(newest '{kind, checks, attempts, flaked, recovered, receipt}')"
comment_line="$(grep -n '^pr comment' "$CASE/gh.log" | cut -d: -f1)"
merge_line="$(grep -n '^pr merge' "$CASE/gh.log" | cut -d: -f1)"
if [ -n "$comment_line" ] && [ -n "$merge_line" ] && [ "$comment_line" -lt "$merge_line" ]; then
  pass "full receipt: the comment is posted before the merge"
else
  fail "full receipt: comment line '$comment_line', merge line '$merge_line'"
fi
COMMENT="$(cat "$CASE/comment.md" 2>/dev/null)"
if [ "$(head -n 1 "$CASE/comment.md" 2>/dev/null)" = "## Merge receipt" ]; then pass "comment: headed Merge receipt"; else fail "comment: first line '$(head -n 1 "$CASE/comment.md" 2>/dev/null)'"; fi
if [ "$(grep -c 'Merge receipt' "$CASE/comment.md")" -eq 1 ]; then pass "comment: the receipt's own heading is not repeated"; else fail "comment: heading repeated"; fi
expect_in "comment: carries the receipt text" "issue 1971 tracks it" "$COMMENT"
expect_in "comment: links the commit" "[\`$SHORT\`](https://github.com/example/instance/commit/$SHA)" "$COMMENT"
expect_in "comment: links each red job" "- red · Mind fast contracts (failure) · $RUN/job/2" "$COMMENT"
expect_in "comment: links the cancelled job" "- red · Suite baseline — shard 2 (cancelled) · $RUN/job/3" "$COMMENT"
expect_in "comment: appends the run link" "- run · $RUN" "$COMMENT"

# --- A receipt that misses a red check refuses, naming it --------------------
new_case missing
checks "SUCCESS|plan / plan" "FAILURE|Mind fast contracts" "CANCELLED|Suite baseline — shard 2"
printf '%s\n' "Mind fast contracts fails only its latency reading on the shared runner." > "$CASE/receipt.md"
gate 101 --receipt "$CASE/receipt.md"
expect_status 2 "receipt missing a job: exits 2"
expect_in "receipt missing a job: names it" "missing  Suite baseline — shard 2 (cancelled)" "$ERR"
expect_not_in "receipt missing a job: does not blame the named one" "missing  Mind fast contracts" "$ERR"
expect_not_in "receipt missing a job: never posts" "pr comment" "$LOG"
expect_not_in "receipt missing a job: never merges" "pr merge" "$LOG"
expect_added 0 "receipt missing a job: a receipt that misses one is not recorded"

new_case reasonless
checks "FAILURE|Mind fast contracts" "CANCELLED|Suite baseline — shard 2"
printf '%s\n' "- Mind fast contracts" "- Suite baseline — shard 2: cancelled by the runner, green on the head before." > "$CASE/receipt.md"
gate 101 --receipt "$CASE/receipt.md"
expect_status 2 "a job named without a reason: exits 2"
expect_in "a job named without a reason: names it" "missing  Mind fast contracts (failure)" "$ERR"

new_case shared-line
checks "FAILURE|lint" "FAILURE|Mind fast contracts"
printf '%s\n' "- lint, Mind fast contracts: flaky" > "$CASE/receipt.md"
gate 101 --receipt "$CASE/receipt.md"
expect_status 2 "check names do not count as the reason"
expect_in "check names do not count as the reason: lint is missing" "missing  lint (failure)" "$ERR"
expect_in "check names do not count as the reason: the other is missing" "missing  Mind fast contracts (failure)" "$ERR"

new_case longer
checks "FAILURE|lint" "SUCCESS|lint docs"
printf '%s\n' "- lint docs: green, and the docs linter reads nothing this change touches." > "$CASE/receipt.md"
gate 101 --receipt "$CASE/receipt.md"
expect_status 2 "a longer check name does not stand in for a red one"
expect_in "a longer check name: the red one is named missing" "missing  lint (failure)" "$ERR"

# --- The base must be the integration branch --------------------------------
new_case base "$OTHER"
checks "SUCCESS|plan / plan"
gate 101
expect_status 4 "a PR into $OTHER: exits 4"
expect_in "a PR into $OTHER: says why" "its base is $OTHER, not the integration branch $BASE" "$ERR"
if [ "$LOG" = "pr view 101 --repo example/instance --json number,url,state,isDraft,mergeable,baseRefName,headRefName,headRefOid" ]; then
  pass "a PR into $OTHER: a number is read in this repository, and nothing past the PR"
else
  fail "a PR into $OTHER: gh calls were: $LOG"
fi

# --- A managed repo merges into its own integration branch ------------------
SITE_URL=https://github.com/Example/Site/pull/7
new_case managed main false "$SITE_URL"
checks "SUCCESS|build" "SUCCESS|pr-format"
gate "$SITE_URL"
expect_status 0 "a managed-repo PR into its own integration branch merges"
expect_in "a managed-repo PR: merges into that repo's base" "merged $SHA into main: all 2 checks green" "$OUT"
expect_in "a managed-repo PR: merges that PR" "pr merge $SITE_URL --merge --match-head-commit $SHA" "$LOG"

new_case managed-other "$BASE" false "$SITE_URL"
checks "SUCCESS|build"
gate "$SITE_URL"
expect_status 4 "a managed-repo PR into another branch: exits 4"
expect_in "a managed-repo PR into another branch: says why" "its base is $BASE, not main, the integration branch of Example/Site" "$ERR"
expect_not_in "a managed-repo PR into another branch: never merges" "pr merge" "$LOG"

# This checkout's own site entry: its PRs target main, as /launch-site opens them.
REAL_CONFIG="$REPO_ROOT/egregore.json"
REAL_ORG="$(jq -r '.github_org // empty' "$REAL_CONFIG" 2>/dev/null)"
if [ -n "$REAL_ORG" ] && jq -e '.repos[]? | select(type == "object" and .name == "egregore-site")' "$REAL_CONFIG" >/dev/null 2>&1; then
  REAL_SITE_URL="https://github.com/$REAL_ORG/egregore-site/pull/141"
  new_case real-site main false "$REAL_SITE_URL"
  checks "SUCCESS|build" "SUCCESS|deploy-preview"
  export CONFIG="$REAL_CONFIG"
  gate "$REAL_SITE_URL"
  export CONFIG="$WORK/egregore.json"
  expect_status 0 "a site PR into main merges under this checkout's egregore.json"
  expect_in "a site PR: merges into main" "merged $SHA into main: all 2 checks green" "$OUT"
else
  echo "  SKIP: this checkout's egregore.json has no egregore-site entry"
fi

new_case foreign "$BASE" false https://github.com/elsewhere/thing/pull/3
checks "SUCCESS|build"
gate https://github.com/elsewhere/thing/pull/3
expect_status 4 "a PR outside this repository and its managed repos: exits 4"
expect_in "a PR outside: says why" "neither this instance's repository (example/instance) nor a managed repo" "$ERR"

new_case draft "$BASE" true
checks "SUCCESS|plan / plan"
gate 101
expect_status 1 "a draft PR: exits 1"
expect_in "a draft PR: says so" "is a draft" "$ERR"

# --- --dry-run never posts or merges -----------------------------------------
MEMORY_HEAD="$(memory_git rev-parse HEAD)"
new_case dry-receipt
checks "SUCCESS|plan / plan" "FAILURE|Mind fast contracts"
printf '%s\n' "Mind fast contracts fails only its latency reading on the shared runner." > "$CASE/receipt.md"
gate 101 --receipt "$CASE/receipt.md" --dry-run
expect_status 0 "dry run with a full receipt: exits 0"
expect_in "dry run: prints the classification" "  red      Mind fast contracts (failure)  $RUN/job/2" "$OUT"
expect_in "dry run: prints the counts" "checks: 1 green, 0 neutral, 0 pending, 1 red" "$OUT"
expect_in "dry run: prints the decision" "decision: merge, 1 green, 1 red under receipt; the receipt is posted on #101 first (exit 0)" "$OUT"
expect_not_in "dry run: never posts" "pr comment" "$LOG"
expect_not_in "dry run: never merges" "pr merge" "$LOG"
expect_in "dry run with a receipt: the ledger line follows the decision" "first (exit 0)
ledger: would append {" "$OUT"
expect_line "dry run with a receipt: would append a merge under a receipt" '{"kind":"merge","receipt":true}' \
  "$(preview '{kind, receipt}')"

new_case dry-red
checks "SUCCESS|plan / plan" "FAILURE|Mind fast contracts"
gate 101 --dry-run
expect_status 2 "dry run of a red PR: exits with the refusal code"
expect_in "dry run of a red PR: prints the refusal" "decision: refuse, 1 red check on $SHORT and no receipt (exit 2)" "$OUT"
expect_not_in "dry run of a red PR: never merges" "pr merge" "$LOG"
expect_line "dry run of a red PR: would append a refusal, on stdout" '{"checks":{"green":1,"neutral":0,"red":1},"kind":"refuse"}' \
  "$(preview '{kind, checks}')"

new_case dry-green
checks "SUCCESS|plan / plan" "SUCCESS|test"
gate 101 --dry-run
expect_status 0 "dry run of a green PR: exits 0"
expect_in "dry run of a green PR: prints the decision" "decision: merge, all 2 checks green (exit 0)" "$OUT"
expect_not_in "dry run of a green PR: never merges" "pr merge" "$LOG"
expect_line "dry run of a green PR: the ledger line is the last" "ledger: would append" \
  "$(printf '%s\n' "$OUT" | tail -n 1 | cut -c1-20)"
expect_line "dry runs write no ledger line" "$MEMORY_HEAD $(ledger_lines)" "$(memory_git rev-parse HEAD) $(ledger_lines)"

# The preview is the line the merge then appends, but for its time.
new_case dry-then-real
checks "SUCCESS|plan / plan" "SUCCESS|Mind fast contracts"
runs "9:2"
ci_jobs "1:success|plan / plan" "1:failure|Mind fast contracts" "2:success|Mind fast contracts"
export EGREGORE_NATIVE_SESSION_ID=native-fixture-session
gate 101 --dry-run
DRY="$(preview 'del(.at)')"
expect_added 0 "a dry run before a merge writes nothing"
gate 101
unset EGREGORE_NATIVE_SESSION_ID
expect_added 1 "the merge after it appends one line"
expect_line "the dry run printed the very line the merge appended" "$DRY" "$(newest 'del(.at)')"
expect_line "the preview names the author and the native session" '{"by":"fixture-actor","session":"native-fixture-session"}' \
  "$(printf '%s\n' "$DRY" | jq -cS '{by, session}')"

# --- A failed merge after the receipt says so -------------------------------
new_case merge-fails
checks "FAILURE|Mind fast contracts"
printf '%s\n' "Mind fast contracts fails only its latency reading on the shared runner." > "$CASE/receipt.md"
export GH_STUB_MERGE_STATUS=1
gate 101 --receipt "$CASE/receipt.md"
unset GH_STUB_MERGE_STATUS
expect_status 1 "a merge gh refuses: exits 1"
expect_in "a merge gh refuses: says the receipt is already posted" "the receipt is posted, but gh could not merge #101" "$ERR"
expect_added 0 "a merge gh refuses: nothing merged, so nothing is recorded"
expect_not_in "a merge gh refuses: says nothing of the ledger" "ledger:" "$OUT$ERR"

# --- A ledger that cannot be written never changes the decision -------------
mkdir -p "$WORK/bare-memory"
export EGREGORE_MEMORY_DIR="$WORK/bare-memory"
new_case no-sessions
checks "SUCCESS|plan / plan" "SUCCESS|test"
gate 101
expect_status 0 "a memory without session records: the merge still exits 0"
expect_line "a memory without session records: says the line was not written, and why" \
  "ledger: not written (this egregore has no session records; nothing was written)" "$(line 2 "$OUT")"
new_case no-sessions-red
checks "SUCCESS|plan / plan" "FAILURE|lint"
gate 101
unset EGREGORE_MEMORY_DIR
expect_status 2 "a refusal over a memory without session records: still exits 2"
expect_line "a refusal over a memory without session records: says so on stderr" \
  "ledger: not written (this egregore has no session records; nothing was written)" "$(printf '%s\n' "$ERR" | tail -n 1)"
expect_added 0 "a memory without session records: this checkout's ledger is untouched"
expect_line "a memory without session records: nothing is created in it" "" "$(ls -A "$WORK/bare-memory")"

cp "$PROJECT/.egregore-state.json" "$WORK/state.json"
jq 'del(.actor_id)' "$WORK/state.json" > "$PROJECT/.egregore-state.json"
new_case no-author
checks "SUCCESS|plan / plan" "SUCCESS|test"
gate 101
cp "$WORK/state.json" "$PROJECT/.egregore-state.json"
expect_status 0 "no GitHub username: the merge still exits 0"
expect_line "no GitHub username: says why the line was not written" \
  "ledger: not written (Runtime actor identity is unavailable; nothing was written)" "$(line 2 "$OUT")"
expect_added 0 "no GitHub username: nothing is written"

# A ledger whose last line lacks its newline gets one before the new line.
new_case no-newline
checks "SUCCESS|plan / plan" "SUCCESS|test"
printf '%s' "$(cat "$LEDGER")" > "$WORK/ledger.trimmed"
cp "$WORK/ledger.trimmed" "$LEDGER"
BEFORE="$(cat "$LEDGER")"
COUNT_BEFORE="$(ledger_lines)"
gate 101
expect_added 1 "a ledger not ending in a newline: the new line is a line of its own"
expect_line "a ledger not ending in a newline: the lines before stay as written" "$BEFORE" "$(head -n "$COUNT_BEFORE" "$LEDGER")"
expect_line "every line of the ledger is one JSON object" '["object"]' \
  "$(jq -R -s -c 'split("\n") | map(select(length > 0) | (fromjson? // "unreadable") | type) | unique' "$LEDGER")"
expect_line "the ledger is committed after every write" "" "$(memory_git status --porcelain -- sessions)"

# --- Every harness uses the same door ---------------------------------------
# bin/agent.sh points CONFIG back at the checkout, so this PR is in its repository.
new_case door "$REAL_BASE" false "https://github.com/$REAL_REPO/pull/101"
checks "SUCCESS|plan / plan" "SUCCESS|test"
: > "$CASE/gh.log"
DOOR="$(cd "$CASE" && PATH="$STUB_BIN:$PATH" GH_STUB_DIR="$CASE" GH_STUB_LOG="$CASE/gh.log" \
  bash "$REPO_ROOT/bin/agent.sh" merge 101 --dry-run 2>&1)"
expect_in "bin/agent.sh merge reaches the gate" "decision: merge, all 2 checks green (exit 0)" "$DOOR"
expect_in "bin/agent.sh lists the merge command" "merge <pr> [--receipt FILE] [--dry-run]" "$(bash "$REPO_ROOT/bin/agent.sh" --help)"
expect_in "the portable protocol names the merge door" "10. Run \`bin/agent.sh merge <pr>\`" "$(bash "$REPO_ROOT/bin/agent.sh" protocol)"
expect_in "the gate prints its usage" "Exit 4 = the base is not the integration branch" "$(bash "$GATE" --help)"
expect_in "the gate's usage names its ledger" "memory/sessions/gate.jsonl" "$(bash "$GATE" --help)"


# --- SHA-bound local evidence uses the real validator; gh stays stubbed. -----
LOCAL_CODE="$WORK/local-code"
mkdir -p "$LOCAL_CODE"
git -C "$LOCAL_CODE" init -q
git -C "$LOCAL_CODE" config user.name Fixture
git -C "$LOCAL_CODE" config user.email fixture@example.invalid
printf 'fixture\n' > "$LOCAL_CODE/source"
git -C "$LOCAL_CODE" add source
git -C "$LOCAL_CODE" commit -qm 'fixture source'
SHA="$(git -C "$LOCAL_CODE" rev-parse HEAD)"
local_evidence() {
  printf 'fixture suite passed\n' > "$CASE/passed.log"
  jq -n --arg log "$CASE/passed.log" '[{suite:"focused",command:"fixture focused test",exit_code:0,log:$log}]' > "$CASE/results.json"
  local args=()
  [ ! -f "$CASE/reasons.json" ] || args+=(--failed-checks "$CASE/reasons.json")
  python3 "$REPO_ROOT/bin/lib/local_ci_receipt.py" generate --output "$CASE/local.json" \
    --checkout "$LOCAL_CODE" --repo example/instance --pr 101 --head "$SHA" --base "$BASE" --base-sha "$SHA" \
    --records "$CASE/results.json" --required-suite focused --unavailable-reason 'GitHub Actions credits exhausted' \
    ${args[@]+"${args[@]}"} >/dev/null || { fail 'local receipt fixture generation'; return 1; }
}
new_case local-no-checks
local_evidence
gate 101 --local-receipt "$CASE/local.json"
expect_status 0 'verified local evidence can cover unavailable hosted checks'
expect_in 'local evidence is posted before merge' 'Local CI receipt' "$(cat "$CASE/comment.md")"
expect_in 'local evidence merges only the classified head' "--match-head-commit $SHA" "$LOG"
expect_line 'local evidence is marked as a receipt in ledger' true "$(newest .receipt)"
new_case local-pending
checks 'IN_PROGRESS|test'
local_evidence
gate 101 --local-receipt "$CASE/local.json"
expect_status 3 'local evidence never waives pending checks'
expect_not_in 'pending local case never merges' 'pr merge' "$LOG"
new_case local-red-missing
checks 'FAILURE|test'
local_evidence
gate 101 --local-receipt "$CASE/local.json"
expect_status 2 'local evidence still names every hosted red check'
new_case local-red-covered
checks 'FAILURE|test'
printf '%s\n' '[{"name":"test","reason":"hosted credits exhausted; affected local suite passed"}]' > "$CASE/reasons.json"
local_evidence
gate 101 --local-receipt "$CASE/local.json"
expect_status 0 'named red check and validated local proof can merge'
new_case local-tampered
local_evidence
printf 'changed\n' > "$CASE/local.json.logs/001.log"
gate 101 --local-receipt "$CASE/local.json"
expect_status 1 'tampered retained evidence is refused'
expect_not_in 'tampered evidence never posts' 'pr comment' "$LOG"
new_case local-base-changed
local_evidence
touch "$CASE/advance-base"
gate 101 --local-receipt "$CASE/local.json"
expect_status 1 'base advancement after evidence validation prevents merge'
expect_in 'base race reports need to refresh evidence' 'integration base changed' "$ERR"
expect_not_in 'base race never calls merge' 'pr merge' "$LOG"
new_case local-dry
local_evidence
gate 101 --local-receipt "$CASE/local.json" --dry-run
expect_status 0 'local evidence dry run validates without mutation'
expect_not_in 'local dry run never posts' 'pr comment' "$LOG"
expect_not_in 'local dry run never merges' 'pr merge' "$LOG"
expect_added 0 'local dry run never writes ledger'

echo "merge-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
