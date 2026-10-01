#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# Isolated integration tests for base-versus-working-tree suite classification.
# Usage: bash tests/test-test-baseline.sh
# Exit 0 = all cases passed, Exit 1 = a case failed

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; cat "$scratch/stderr" >&2; printf '%s\n' "${OUTPUT:-}" >&2; }
scratch=$(mktemp -d /tmp/test-test-baseline.XXXXXX)
active_pids=()
# shellcheck disable=SC2329
cleanup() {
  for pid in ${active_pids[@]+"${active_pids[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  # A failed timeout assertion must not leave the deliberately stubborn fixture.
  for pid_file in "$scratch/tmp"/timeout-*.pid; do
    [ -f "$pid_file" ] || continue
    kill -KILL "$(cat "$pid_file")" 2>/dev/null || true
  done
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$scratch/home" "$scratch/tmp"
: > "$scratch/stderr"
fixture_env() {
  HOME="$scratch/home" TMPDIR="$scratch/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
      -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u CONFIG -u VOLTA_HOME -u NVM_DIR "$@"
}
fixture_git() { fixture_env git "$@"; }
fixture_run() { local tree="$1"; shift; fixture_env bash "$tree/bin/test-baseline.sh" "$@"; }
baseline() { fixture_run "$scratch/topic" "$@"; }
# Launch env directly so $! identifies the runner, without a function subshell.
start_baseline() {
  local output="$1" errors="$2"
  shift 2
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u CONFIG -u VOLTA_HOME -u NVM_DIR \
    HOME="$scratch/home" TMPDIR="$scratch/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash "$scratch/topic/bin/test-baseline.sh" "$@" > "$output" 2> "$errors" &
  tool_pid=$!
  active_pids+=("$tool_pid")
}
capture() {
  EXIT_CODE=0
  OUTPUT=$("$@" 2> "$scratch/stderr") || EXIT_CODE=$?
}
json_is() { printf '%s\n' "$OUTPUT" | jq -e "$1" >/dev/null; }
text_has() { grep -Fq -- "$1" <<< "$OUTPUT"; }
configure_author() {
  fixture_git -C "$1" config --local user.name 'QA Fixture'
  fixture_git -C "$1" config --local user.email 'qa@example.invalid'
  fixture_git -C "$1" config --local core.hooksPath /dev/null
  fixture_git -C "$1" config --local commit.gpgsign false
}
no_scratch() {
  local path
  for path in "$scratch/tmp"/qa-baseline.*; do [ ! -e "$path" ] || return 1; done
}
tree_count() { fixture_git -C "$scratch/topic" worktree list | awk 'END {print NR}'; }
remove_kept() {
  fixture_git -C "$scratch/topic" worktree remove --force "$1/base"
  rm -rf "$1"
}
invalid() {
  local label="$1" message="$2"; shift 2
  capture baseline "$@"
  if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && grep -Fq -- "$message" "$scratch/stderr" && no_scratch; then
    pass "$label"
  else fail "$label"; fi
}
wait_for_file() {
  local attempt
  for ((attempt=0; attempt<100; attempt++)); do
    [ ! -f "$1" ] || return 0
    kill -0 "$tool_pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}
wait_for_runner() {
  local attempt
  for ((attempt=0; attempt<100; attempt++)); do
    kill -0 "$tool_pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}
fixture_process_running() {
  local state
  state=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  # Orphaned zombies can wait for init on Linux; they cannot keep running.
  case "$state" in ''|*Z*) return 1 ;; esac
  return 0
}

echo '=== test-baseline.sh tests ==='
fixture_git init --bare --initial-branch=main "$scratch/origin.git" >/dev/null
fixture_git clone "$scratch/origin.git" "$scratch/topic" >/dev/null 2>&1
configure_author "$scratch/topic"
mkdir -p "$scratch/topic/bin/lib" "$scratch/topic/tests"
cp "$SCRIPT_DIR/bin/test-baseline.sh" "$SCRIPT_DIR/bin/base-branch.sh" \
  "$SCRIPT_DIR/bin/node-run.sh" "$scratch/topic/bin/"
cp "$SCRIPT_DIR/bin/lib/config.sh" "$SCRIPT_DIR/bin/lib/repo-paths.sh" "$scratch/topic/bin/lib/"
printf '%s\n' '{"mode":"local","base_branch":"main"}' > "$scratch/topic/egregore.json"
printf '%s\n' base > "$scratch/topic/marker.txt"
printf '%s\n' 'echo ok' > "$scratch/topic/tests/test-clean.sh"
printf '%s\n' 'echo "FAIL: old"' 'exit 1' > "$scratch/topic/tests/test-red.sh"
printf '%s\n' 'echo "FAIL: fixme"' 'exit 1' > "$scratch/topic/tests/test-fixme.sh"
printf '%s\n' 'exit 0' > "$scratch/topic/tests/test-break.sh"
printf '%s\n' 'echo "FAIL: a"' 'exit 1' > "$scratch/topic/tests/test-red2.sh"
# shellcheck disable=SC2016
printf '%s\n' 'echo "FAIL: $(cat marker.txt)"' 'exit 1' > "$scratch/topic/tests/test-where.sh"
cat > "$scratch/topic/tests/test-noise.sh" <<'EOF'
printf '\033[31mFAIL: color\033[0m\n'
printf 'FAIL: %s\n' "$(mktemp -d)"
printf 'FAIL: %s/tests/probe.sh\n' "$PWD"
printf 'FAIL: no trailing newline'
exit 1
EOF
printf '%s\n' 'echo written > tests/written-here.txt' > "$scratch/topic/tests/test-writer.sh"
printf '%s\n' 'sleep 30' > "$scratch/topic/tests/test-slow.sh"
printf '%s\n' 'process.exit(0)' > "$scratch/topic/tests/test-node.mjs"
printf '%s\n' 'def test_ok(): pass' > "$scratch/topic/tests/test_py.py"
printf '%s\n' '@test "x" { true; }' > "$scratch/topic/tests/test-bats.bats"
printf '%s\n' 'exit 0' > "$scratch/topic/tests/suite with spaces.sh"
ln -s test-clean.sh "$scratch/topic/tests/test-link.sh"
printf '%s\n' 'printf "not ok 1 - EOF"' 'exit 1' > "$scratch/topic/tests/test-eof.sh"
printf '%s\n' 'exit 3' > "$scratch/topic/tests/test-silent.sh"
printf '%s\n' 'echo "FAIL: x"' 'exit 1' > "$scratch/topic/tests/test-exit-change.sh"
printf '%s\n' 'echo "FAIL: x"' 'exit 1' > "$scratch/topic/tests/test-exit-only.sh"
printf '%s\n' 'echo "ERROR: boom"' 'exit 1' > "$scratch/topic/tests/test-error-old.sh"
printf '%s\n' 'echo "FAIL: x"' 'exit 1' > "$scratch/topic/tests/test-error-extra.sh"
printf '%s\n' 'echo "PASS: handles FAIL lines"' 'echo "FAIL: same"' 'exit 1' > "$scratch/topic/tests/test-success-noise.sh"
# shellcheck disable=SC2016
printf '%s\n' 'read -r line || true; echo "got:$line"' > "$scratch/topic/tests/test-stdin.sh"
printf '%s\n' 'test -f local-only' > "$scratch/topic/tests/test-local.sh"
printf '%s\n' 'echo "SKIP: needs the live relay"' 'exit 0' > "$scratch/topic/tests/test-live.sh"
printf '%s\n' 'echo "SKIP: declined but still red"' 'exit 1' > "$scratch/topic/tests/test-live-red.sh"
printf '%s\n' 'echo "SKIP: optional probe"' 'echo "PASS: real test executed"' > "$scratch/topic/tests/test-partial-skip.sh"
printf '%s\n' 'echo "SKIP: optional probe"' 'echo "ordinary output"' > "$scratch/topic/tests/test-skip-output.sh"
printf '%s\n' 'echo "SKIP: first unavailable service"' 'echo' 'echo "SKIP: second unavailable service"' > "$scratch/topic/tests/test-all-skip.sh"
cat > "$scratch/topic/tests/test-head-only.sh" <<'EOF'
if [ "$(cat marker.txt)" = base ]; then
  echo forbidden > "$TMPDIR/head-first-base-ran"
fi
echo PASS: head-only
EOF
cat > "$scratch/topic/tests/test-timeout.sh" <<'EOF'
side=$(cat marker.txt)
echo "$side" >> "$TMPDIR/timeout-order"
if [ "$side" != "$QA_TIMEOUT_SIDE" ]; then
  echo 'FAIL: compare timeout'
  exit 1
fi
trap '' TERM
echo "$$" > "$TMPDIR/timeout-suite.pid"
bash -c '
  trap "" TERM
  echo "$$" > "$TMPDIR/timeout-child.pid"
  sleep 30 &
  echo "$!" > "$TMPDIR/timeout-grandchild.pid"
  wait
' &
wait
EOF
cat > "$scratch/topic/tests/test-timeout-detached.sh" <<'EOF'
cleanup_child() {
  trap - TERM
  # Make the grace observable: an immediate KILL cannot finish this handler.
  sleep 0.1
  kill -KILL -- "-$child_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true
  echo cleaned > "$TMPDIR/timeout-detached-cleaned"
  exit 0
}
echo "$$" > "$TMPDIR/timeout-detached-suite.pid"
ps -o pgid= -p "$$" > "$TMPDIR/timeout-detached-suite.pgid"
set -m
bash -c '
  trap "" TERM
  echo "$$" > "$TMPDIR/timeout-detached-child.pid"
  ps -o pgid= -p "$$" > "$TMPDIR/timeout-detached-child.pgid"
  sleep 30 &
  echo "$!" > "$TMPDIR/timeout-detached-grandchild.pid"
  ps -o pgid= -p "$!" > "$TMPDIR/timeout-detached-grandchild.pgid"
  wait
' &
child_pid=$!
set +m
trap cleanup_child TERM
wait "$child_pid"
exit 99
EOF
cat > "$scratch/topic/tests/test-progress.sh" <<'EOF'
echo ready > "$TMPDIR/progress-ready"
for ((attempt=0; attempt<100; attempt++)); do
  if [ -f "$TMPDIR/progress-release" ]; then
    echo 'PASS: released'
    exit 0
  fi
  sleep 0.1
done
echo 'FAIL: progress fixture was not released'
exit 1
EOF
cat > "$scratch/topic/tests/test-checkout.sh" <<'EOF'
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
test "$(git rev-parse --show-toplevel)" = "$(pwd -P)"
if [ "$(cat marker.txt)" = base ]; then
  test -z "$(git symbolic-ref --quiet --short HEAD || true)"
  test -z "$(git status --porcelain)"
fi
EOF
fixture_git -C "$scratch/topic" add .
fixture_git -C "$scratch/topic" commit -qm 'Fixture baseline'
fixture_git -C "$scratch/topic" push -u origin main >/dev/null 2>&1
fixture_git -C "$scratch/topic" switch -c topic >/dev/null 2>&1
printf '%s\n' 'exit 0' > "$scratch/topic/tests/test-fixme.sh"
printf '%s\n' 'echo "FAIL: broke"' 'exit 1' > "$scratch/topic/tests/test-break.sh"
printf '%s\n' 'echo "FAIL: a"' 'echo "FAIL: b"' 'exit 1' > "$scratch/topic/tests/test-red2.sh"
printf '%s\n' head > "$scratch/topic/marker.txt"
printf '%s\n' 'exit 0' > "$scratch/topic/tests/test-new.sh"
printf '%s\n' 'echo "FAIL: fresh"' 'exit 1' > "$scratch/topic/tests/test-new-bad.sh"
printf '%s\n' 'echo "ERROR collecting tests/x.py"' 'exit 2' > "$scratch/topic/tests/test-exit-change.sh"
printf '%s\n' 'echo "FAIL: x"' 'exit 2' > "$scratch/topic/tests/test-exit-only.sh"
printf '%s\n' 'echo "FAIL: x"' 'echo "ERROR: extra"' 'exit 1' > "$scratch/topic/tests/test-error-extra.sh"
cat > "$scratch/topic/tests/test-success-noise.sh" <<'EOF'
echo 'PASS: rejects ERROR response'
echo 'ok 2 - ERROR path'
echo '✓ handles FAIL text'
printf '  \033[32mPASS: colored ERROR response\033[0m\n'
printf '\t\033[32mok 4 - ERROR response\033[0m\n'
printf '  \033[32m✓ handles FAIL response\033[0m\n'
echo 'PASS handles ERROR response'
echo 'PASS: handles FAIL lines'
echo 'FAIL: same'
exit 1
EOF
fixture_git -C "$scratch/topic" add .
fixture_git -C "$scratch/topic" commit -qm 'Fixture topic'
base_oid=$(fixture_git -C "$scratch/topic" rev-parse origin/main)
all_suites=(tests/test-clean.sh tests/test-red.sh tests/test-fixme.sh tests/test-break.sh
  tests/test-red2.sh tests/test-where.sh tests/test-noise.sh tests/test-writer.sh
  tests/test-new.sh tests/test-new-bad.sh tests/test-node.mjs)
statuses=(clean pre-existing fixed regression regression regression pre-existing clean new regression clean)
subset=(tests/test-clean.sh tests/test-red.sh tests/test-fixme.sh)
expected_statuses='["clean","pre-existing","fixed","regression","regression","regression","pre-existing","clean","new","regression","clean"]'

# 1–3. All transitions, nested failures, normalized logs, and the exact report.
cp "$scratch/topic/.git/index" "$scratch/index.before"
capture baseline "${all_suites[@]}"
if [ "$EXIT_CODE" -eq 1 ] && text_has 'QA baseline' && text_has 'Base: origin/main (' \
   && text_has 'Head: topic + working tree' && text_has 'Suites (11):' \
   && text_has 'Summary: 4 regression, 2 pre-existing, 1 fixed, 3 clean, 1 new, 0 skipped' \
   && text_has '    + FAIL: b' && text_has '    head log (last 20 lines):'; then
  pass 'full text report and regression exit code'
else fail 'full text report and regression exit code'; fi
for ((i=0; i<${#all_suites[@]}; i++)); do
  expected_line=$(printf '  %-12s %s  base ' "${statuses[$i]}" "${all_suites[$i]}")
  if text_has "$expected_line"; then pass "text classification ${all_suites[$i]}"
  else fail "text classification ${all_suites[$i]}"; fi
done
if no_scratch && [ "$(tree_count)" -eq 1 ] && cmp -s "$scratch/index.before" "$scratch/topic/.git/index"; then
  pass 'cleanup removes scratch and registration without changing the head index'
else fail 'cleanup and head index'; fi
capture baseline "${subset[@]}"
if [ "$EXIT_CODE" -eq 0 ] && text_has 'Summary: 0 regression, 1 pre-existing, 1 fixed, 1 clean, 0 new, 0 skipped'; then
  pass 'pre-existing failures and fixes do not fail the gate'
else fail 'non-regression subset'; fi
capture baseline --json "${all_suites[@]}"
if [ "$EXIT_CODE" -eq 1 ] && json_is "(.suites | map(.status)) == $expected_statuses" \
   && json_is ".base.oid == \"$base_oid\"" \
   && json_is '.summary == {regression:4,pre_existing:2,fixed:1,clean:3,new:1,skipped:0,passed:0,blocked:0}
     and .head == {ref:"topic",working_tree:true} and .logs == null and .base.tree == null
     and all(.suites[]; .head.seconds | type == "number" and floor == . and . >= 0)
     and all(.suites[] | select(.base != null); .base.seconds | type == "number" and floor == . and . >= 0)
     and .suites[5].new_failure_lines == ["FAIL: head"] and .suites[6].new_failure_lines == []
     and .suites[4].note == "new failures inside a red suite"
     and .suites[9].note == "new suite, failing at head"
     and .suites[8].base == null and .suites[9].base == null
     and .suites[10].runner == "node" and .suites[0].runner == "bash"'; then
  pass 'JSON schema, all statuses, notes, duration, absent base, and normalized failure evidence'
else fail 'full JSON report'; fi

# Head-first runs passing suites once, while failures retain the full comparison.
capture baseline --head-first --json tests/test-head-only.sh tests/test-fixme.sh tests/test-new.sh
if [ "$EXIT_CODE" -eq 0 ] && [ ! -e "$scratch/tmp/head-first-base-ran" ] \
   && json_is 'all(.suites[]; .status == "passed" and .base == null and .head.exit == 0 and .head.timed_out == false)
     and .summary.passed == 3 and .summary.regression == 0 and .summary.blocked == 0'; then
  pass 'head-first passes existing, formerly red, and new suites without executing base'
else fail 'head-first passing suite base execution'; fi
capture baseline --head-first --json tests/test-red.sh tests/test-break.sh tests/test-red2.sh tests/test-exit-only.sh tests/test-new-bad.sh
if [ "$EXIT_CODE" -eq 1 ] && json_is '(.suites | map(.status)) == ["pre-existing","regression","regression","regression","regression"]
  and .suites[0].base.exit == 1 and .suites[0].new_failure_lines == []
  and .suites[1].base.exit == 0
  and .suites[2].new_failure_lines == ["FAIL: b"]
  and .suites[3].note == "exit code changed 1 → 2"
  and .suites[4].base == null and .suites[4].new_failure_lines == ["FAIL: fresh"]
  and .summary.blocked == 0'; then
  pass 'head-first compares unchanged failures, new failure lines, changed exits, and new red suites'
else fail 'head-first failure comparison'; fi

# Strict gates retain comparison evidence but require every selected head to pass.
for strict_order in full head-first; do
  strict_args=(--strict-head --json)
  if [ "$strict_order" = head-first ]; then strict_args+=(--head-first); fi
  capture baseline "${strict_args[@]}" tests/test-clean.sh tests/test-fixme.sh tests/test-new.sh tests/test-partial-skip.sh
  strict_statuses='["clean","fixed","new","clean"]'
  if [ "$strict_order" = head-first ]; then strict_statuses='["passed","passed","passed","passed"]'; fi
  if [ "$EXIT_CODE" -eq 0 ] && json_is "(.suites | map(.status)) == $strict_statuses" \
     && json_is 'all(.suites[]; .head.exit == 0 and .head.timed_out == false)' \
     && [ ! -e "$scratch/tmp/head-first-base-ran" ]; then
    pass "strict $strict_order accepts passing heads including fixes, new suites, and partial skips"
  else fail "strict $strict_order passing heads"; fi
  capture baseline "${strict_args[@]}" tests/test-clean.sh tests/test-red.sh
  if [ "$EXIT_CODE" -eq 1 ] && json_is '.suites[1].status == "pre-existing"
    and .suites[1].base.exit == 1 and .suites[1].head.exit == 1
    and .suites[1].new_failure_lines == [] and .summary.pre_existing == 1 and .summary.regression == 0'; then
    pass "strict $strict_order rejects unchanged head failure without changing its classification"
  else fail "strict $strict_order pre-existing failure"; fi
  capture baseline "${strict_args[@]}" tests/test-break.sh tests/test-new-bad.sh
  if [ "$EXIT_CODE" -eq 1 ] && json_is 'all(.suites[]; .status == "regression" and .head.exit == 1)
    and .suites[0].new_failure_lines == ["FAIL: broke"] and .suites[1].base == null'; then
    pass "strict $strict_order retains existing and new regression evidence"
  else fail "strict $strict_order regression evidence"; fi
  capture baseline "${strict_args[@]}" tests/test-live.sh tests/test-all-skip.sh
  if [ "$EXIT_CODE" -eq 0 ] && json_is 'all(.suites[]; .status == "skipped" and .head.exit == 0)
    and .suites[0].note == "needs the live relay" and .summary.skipped == 2'; then
    pass "strict $strict_order retains successful intentional skips as reported coverage gaps"
  else fail "strict $strict_order intentional skip"; fi
  capture baseline "${strict_args[@]}" tests/test-live.sh tests/test-red.sh
  if [ "$EXIT_CODE" -eq 1 ] && json_is '(.suites | map(.status)) == ["skipped","pre-existing"]
    and .suites[0].head.exit == 0 and .suites[0].note == "needs the live relay"
    and .suites[1].head.exit == 1'; then
    pass "strict $strict_order retains intentional skips while rejecting completed failures"
  else fail "strict $strict_order intentional skip with failure"; fi
done

# F5. Changed failing exit codes and ERROR lines must not hide behind old failures.
capture baseline --json tests/test-exit-change.sh tests/test-exit-only.sh tests/test-error-old.sh tests/test-error-extra.sh tests/test-silent.sh
if [ "$EXIT_CODE" -eq 1 ] && json_is '(.suites | map(.status)) == ["regression","regression","pre-existing","regression","pre-existing"]
  and .suites[0].note == "exit code changed 1 → 2"
  and .suites[0].new_failure_lines == ["ERROR collecting tests/x.py"]
  and .suites[1].note == "exit code changed 1 → 2" and .suites[1].new_failure_lines == []
  and .suites[2].new_failure_lines == []
  and .suites[3].note == "new failures inside a red suite" and .suites[3].new_failure_lines == ["ERROR: extra"]'; then
  pass 'changed failing exit codes and new ERROR lines are regressions; unchanged red suites remain pre-existing'
else fail 'changed exit codes and ERROR classification'; fi

# G3. Passing records may mention failure words, but cannot create regressions.
capture baseline --json tests/test-success-noise.sh
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "pre-existing" and .suites[0].new_failure_lines == []'; then
  pass 'passing records mentioning failure words are excluded after ANSI stripping'
else fail 'success records treated as failures'; fi
printf '%s\n' 'echo "not ok 3 - ERROR path"' 'echo "FAIL: same"' 'exit 1' > "$scratch/topic/tests/test-success-noise.sh"
capture baseline --json tests/test-success-noise.sh
if [ "$EXIT_CODE" -eq 1 ] && json_is '.suites[0].status == "regression"
  and .suites[0].new_failure_lines == ["not ok 3 - ERROR path"]'; then
  pass 'TAP not ok remains failure evidence'
else fail 'TAP failure excluded as success'; fi
printf '%s\n' 'echo "PASSING ERROR detail"' 'echo "ok 2oops ERROR detail"' 'echo "FAIL: same"' 'exit 1' \
  > "$scratch/topic/tests/test-success-noise.sh"
capture baseline --json tests/test-success-noise.sh
if [ "$EXIT_CODE" -eq 1 ] && json_is '.suites[0].status == "regression"
  and .suites[0].new_failure_lines == ["PASSING ERROR detail","ok 2oops ERROR detail"]'; then
  pass 'success markers require PASS and TAP number word boundaries'
else fail 'success marker word boundaries'; fi

# 4–6. Stdin preserves order and EOF; all invalid arguments fail before scratch.
printf '\n# comment\ntests/test-red.sh\r\ntests/test-clean.sh\ntests/test-fixme.sh' > "$scratch/input"
capture baseline --json tests/test-clean.sh - tests/test-red.sh < "$scratch/input"
if [ "$EXIT_CODE" -eq 0 ] && json_is '(.suites | length) == 3
  and (.suites | map(.status)) == ["clean","pre-existing","fixed"]'; then
  pass 'mixed stdin and explicit suites trim CRLF and deduplicate in order'
else fail 'stdin selection'; fi
printf '%s\n' 'not a suite' > "$scratch/topic/tests/note.txt"
printf '%s\n' 'exit 99' > "$scratch/outside.sh"
chmod 000 "$scratch/outside.sh"
ln -s "$scratch/outside.sh" "$scratch/topic/tests/outside.sh"
ln -s "$scratch" "$scratch/topic/external"
ln -s nowhere.sh "$scratch/topic/tests/dangling.sh"
invalid 'missing suite' 'test-baseline: suite tests/missing.sh not found' tests/missing.sh
invalid 'absolute suite path' 'outside repository' "$scratch/topic/tests/test-clean.sh"
invalid 'parent traversal' 'outside repository' ../x.sh
invalid 'embedded parent traversal' 'outside repository' tests/../tests/test-clean.sh
invalid 'unsupported suite type' 'test-baseline: unsupported suite type tests/note.txt' tests/test-clean.sh tests/note.txt
invalid 'external symlink suite' 'outside repository' tests/outside.sh
invalid 'external symlink directory' 'outside repository' external/outside.sh
invalid 'dangling internal symlink' 'test-baseline: suite tests/dangling.sh not found' tests/dangling.sh
chmod 644 "$scratch/outside.sh"
# F1. The kernel resolves jump before ..; lexical normalization would escape.
mkdir -p "$scratch/external/subdir"
printf 'printf ran > "%s/external/ran"\nexit 99\n' "$scratch" > "$scratch/external/outside.sh"
ln -s "$scratch/external/subdir" "$scratch/topic/tests/jump"
ln -s jump/../outside.sh "$scratch/topic/tests/run.sh"
capture baseline tests/run.sh
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && no_scratch \
   && grep -Fq 'outside repository' "$scratch/stderr" && [ ! -e "$scratch/external/ran" ]; then
  pass 'symlink followed by parent traversal cannot execute outside the repository'
else fail 'symlink plus parent traversal escape'; fi
invalid 'missing explicit base' 'test-baseline: base nope not found' --base nope tests/test-clean.sh
invalid 'no suites' 'Usage:'
invalid 'empty stdin' 'Usage:' - < /dev/null
invalid 'unknown option' 'Usage:' --unknown tests/test-clean.sh
invalid 'base without value' 'Usage:' --base
invalid 'base option as value' 'Usage:' --base --json tests/test-clean.sh
invalid 'head-first still requires an available base ref' 'test-baseline: base nope not found' --head-first --base nope tests/test-clean.sh
invalid 'timeout without value' 'Usage:' --timeout
invalid 'timeout option as value' 'timeout must be a positive integer' --timeout --json tests/test-clean.sh
for invalid_timeout in '' 0 01 -1 1.5 abc; do
  invalid "invalid timeout '$invalid_timeout'" 'timeout must be a positive integer' --timeout "$invalid_timeout" tests/test-clean.sh
done
printf '%s\n' '{"base_branch":"nowhere"}' > "$scratch/config.json"
capture fixture_env env CONFIG="$scratch/config.json" bash "$scratch/topic/bin/test-baseline.sh" tests/test-clean.sh
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && no_scratch \
   && grep -Fq 'base-branch: cannot resolve origin/nowhere or nowhere' "$scratch/stderr"; then
  pass 'default base failure propagates the resolver message'
else fail 'default base failure'; fi

# 8. TERM must interrupt wait promptly, including suites that ignore TERM forever.
for interrupt_suite in tests/test-slow.sh tests/test-hung.sh; do
  # shellcheck disable=SC2016
  printf '%s\n' 'trap "" TERM' 'echo "$$" > "$TMPDIR/hung.pid"' 'while :; do sleep 30; done' > "$scratch/topic/tests/test-hung.sh"
  start_baseline "$scratch/interrupt.out" "$scratch/interrupt.err" "$interrupt_suite"
  sleep 2
  started=$SECONDS
  kill -TERM "$tool_pid"
  interrupt_code=0
  wait "$tool_pid" || interrupt_code=$?
  active_pids=()
  if [ "$interrupt_code" -eq 143 ] && [ "$((SECONDS - started))" -lt 10 ] && no_scratch && [ "$(tree_count)" -eq 1 ]; then
    pass "prompt interrupt cleanup for $interrupt_suite"
  else fail "interrupt cleanup for $interrupt_suite"; fi
done
if [ -f "$scratch/tmp/hung.pid" ] && ! kill -0 "$(cat "$scratch/tmp/hung.pid")" 2>/dev/null; then
  pass 'interrupt kills the suite process even when TERM is ignored'
else fail 'hung suite survived cleanup'; fi

# A timeout blocks evidence, rather than classifying an interrupted suite as red.
# The fixture ignores TERM and has a child plus grandchild in the suite group.
for timeout_side in head base; do
  rm -f "$scratch/tmp"/timeout-*.pid "$scratch/tmp/timeout-order"
  QA_TIMEOUT_SIDE="$timeout_side" start_baseline "$scratch/timeout.json" "$scratch/timeout.err" \
    --head-first --timeout 1 --json tests/test-timeout.sh tests/test-clean.sh
  timely=true
  if ! wait_for_runner; then
    timely=false
    kill -TERM "$tool_pid" 2>/dev/null || true
    kill -KILL "$tool_pid" 2>/dev/null || true
  fi
  timeout_code=0
  wait "$tool_pid" || timeout_code=$?
  active_pids=()
  OUTPUT=$(cat "$scratch/timeout.json")
  cp "$scratch/timeout.err" "$scratch/stderr"
  descendants_stopped=true
  for generation in suite child grandchild; do
    pid_file="$scratch/tmp/timeout-$generation.pid"
    if [ ! -s "$pid_file" ]; then
      descendants_stopped=false
    else
      fixture_pid=$(cat "$pid_file")
      if fixture_process_running "$fixture_pid"; then descendants_stopped=false; fi
      kill -KILL "$fixture_pid" 2>/dev/null || true
    fi
  done
  if $timely && [ "$timeout_code" -eq 2 ] && $descendants_stopped \
     && no_scratch && [ "$(tree_count)" -eq 1 ] \
     && json_is ".suites[0].status == \"blocked\" and .suites[0].$timeout_side.timed_out == true
       and .suites[1].status == \"passed\" and .summary.blocked == 1
       and .summary.regression == 0 and .summary.pre_existing == 0"; then
    pass "$timeout_side timeout blocks comparison and kills its whole process group"
  else fail "$timeout_side timeout status or descendant cleanup"; fi
  if [ "$timeout_side" = head ]; then
    if json_is '.suites[0].base == null' && [ "$(cat "$scratch/tmp/timeout-order")" = head ]; then
      pass 'head timeout never executes the base suite'
    else fail 'base ran after head timeout'; fi
  elif json_is '.suites[0].head.exit == 1 and .suites[0].head.timed_out == false' \
       && [ "$(cat "$scratch/tmp/timeout-order")" = "$(printf 'head\nbase')" ]; then
    pass 'base timeout follows a completed failing head'
  else fail 'base timeout lost the completed head result'; fi
  rm -f "$scratch/tmp"/timeout-*.pid
done
# Suites can deliberately create their own child groups and clean them in TERM
# handlers. The timeout grace must let that cleanup finish without passing them.
start_baseline "$scratch/detached.json" "$scratch/detached.err" \
  --head-first --timeout 1 --json tests/test-timeout-detached.sh
timely=true
if ! wait_for_runner; then
  timely=false
  kill -TERM "$tool_pid" 2>/dev/null || true
  kill -KILL "$tool_pid" 2>/dev/null || true
fi
detached_code=0
wait "$tool_pid" || detached_code=$?
active_pids=()
OUTPUT=$(cat "$scratch/detached.json")
cp "$scratch/detached.err" "$scratch/stderr"
detached_stopped=true
for generation in suite child grandchild; do
  pid_file="$scratch/tmp/timeout-detached-$generation.pid"
  if [ ! -s "$pid_file" ]; then
    detached_stopped=false
  else
    fixture_pid=$(cat "$pid_file")
    if fixture_process_running "$fixture_pid"; then detached_stopped=false; fi
    kill -KILL "$fixture_pid" 2>/dev/null || true
  fi
done
separate_group=false
if [ -s "$scratch/tmp/timeout-detached-suite.pgid" ] \
   && [ -s "$scratch/tmp/timeout-detached-child.pgid" ] \
   && [ -s "$scratch/tmp/timeout-detached-grandchild.pgid" ]; then
  suite_group=$(awk '{print $1}' "$scratch/tmp/timeout-detached-suite.pgid")
  child_group=$(awk '{print $1}' "$scratch/tmp/timeout-detached-child.pgid")
  grandchild_group=$(awk '{print $1}' "$scratch/tmp/timeout-detached-grandchild.pgid")
  if [ "$suite_group" != "$child_group" ] && [ "$child_group" = "$grandchild_group" ] \
     && [ "$child_group" = "$(cat "$scratch/tmp/timeout-detached-child.pid")" ]; then
    separate_group=true
  fi
fi
if $timely && $separate_group && $detached_stopped && [ "$detached_code" -eq 2 ] \
   && [ -f "$scratch/tmp/timeout-detached-cleaned" ] && no_scratch && [ "$(tree_count)" -eq 1 ] \
   && json_is '.suites[0].status == "blocked" and .suites[0].head.timed_out == true
     and .suites[0].base == null and .summary.blocked == 1 and .summary.passed == 0
     and .summary.regression == 0 and .summary.pre_existing == 0'; then
  pass 'timeout grace lets a TERM handler clean its separate child group without treating exit 0 as passed'
else fail 'timeout grace, detached descendants, or successful TERM handler classification'; fi
rm -f "$scratch/tmp"/timeout-detached-*.pid
capture baseline --head-first --timeout 2 --json tests/test-clean.sh
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "passed" and .suites[0].head.timed_out == false'; then
  pass 'positive timeout accepts a suite that finishes within its budget'
else fail 'positive timeout handling'; fi
capture baseline --strict-head --head-first --timeout 1 --json tests/test-slow.sh tests/test-clean.sh
if [ "$EXIT_CODE" -eq 2 ] && json_is '.suites[0].status == "blocked" and .suites[0].head.timed_out == true
  and .suites[0].head.exit == 124 and .suites[0].base == null and .suites[1].status == "passed"'; then
  pass 'strict head timeout remains blocked and still reports later suites'
else fail 'strict head timeout'; fi
printf '%s\n' 'exit 124' > "$scratch/topic/tests/test-natural-124.sh"
capture baseline --strict-head --head-first --timeout 2 --json tests/test-natural-124.sh
if [ "$EXIT_CODE" -eq 1 ] && json_is '.suites[0].status == "regression" and .suites[0].head.exit == 124
  and .suites[0].head.timed_out == false'; then
  pass 'strict completed exit 124 is a failure rather than a watchdog timeout'
else fail 'strict natural exit 124'; fi

# Observe the report before releasing the final suite. JSON must stay parseable,
# while text-mode users can already see completed suite rows and live progress.
for progress_mode in json text; do
  rm -f "$scratch/tmp/progress-ready" "$scratch/tmp/progress-release"
  progress_args=(--head-first)
  if [ "$progress_mode" = json ]; then progress_args+=(--json); fi
  start_baseline "$scratch/progress.out" "$scratch/progress.err" "${progress_args[@]}" \
    tests/test-clean.sh tests/test-progress.sh
  streaming=false
  if wait_for_file "$scratch/tmp/progress-ready"; then
    if grep -Fq 'tests/test-progress.sh' "$scratch/progress.err" \
       && grep -Fq head "$scratch/progress.err"; then
      if [ "$progress_mode" = json ] && [ ! -s "$scratch/progress.out" ]; then
        streaming=true
      elif [ "$progress_mode" = text ] \
           && grep -Eq '^  passed +tests/test-clean.sh ' "$scratch/progress.out"; then
        streaming=true
      fi
    fi
  fi
  : > "$scratch/tmp/progress-release"
  progress_code=0
  wait "$tool_pid" || progress_code=$?
  active_pids=()
  OUTPUT=$(cat "$scratch/progress.out")
  cp "$scratch/progress.err" "$scratch/stderr"
  valid_report=true
  if [ "$progress_mode" = json ]; then
    json_is '(.suites | length) == 2 and all(.suites[]; .status == "passed")' || valid_report=false
    printf '%s\n' "$OUTPUT" | jq -se 'length == 1' >/dev/null || valid_report=false
  else
    text_has 'Summary:' || valid_report=false
  fi
  if $streaming && $valid_report && [ "$progress_code" -eq 0 ] && no_scratch; then
    pass "$progress_mode report streams progress on stderr and keeps stdout in its promised format"
  else fail "$progress_mode live output contract"; fi
done

# 9–12. Kept logs, cwd writes, inherited Git overrides, and uncommitted head edits.
capture baseline --keep tests/test-clean.sh
kept=$(printf '%s\n' "$OUTPUT" | awk '/^Kept: / {sub(/^Kept: /, ""); print}')
if [ "$EXIT_CODE" -eq 0 ] && [ -d "$kept/base" ] && [ -d "$kept/logs" ] && [ "$(tree_count)" -eq 2 ] \
   && text_has "Remove with: git worktree remove --force $kept/base" \
   && [ -f "$kept/logs/base/tests__test-clean.sh.log" ]; then
  pass 'keep text includes the checkout, logs, and removal command'
else fail 'keep text'; fi
remove_kept "$kept"
if [ "$(tree_count)" -eq 1 ] && no_scratch; then pass 'kept worktree is removable'; else fail 'kept removal'; fi
# F3. Children cannot consume either a terminal or the caller's input file.
printf '%s\n' should-not-be-read > "$scratch/suite-input"
capture baseline --keep tests/test-stdin.sh < "$scratch/suite-input"
kept=$(printf '%s\n' "$OUTPUT" | awk '/^Kept: / {sub(/^Kept: /, ""); print}')
if [ "$EXIT_CODE" -eq 0 ] && grep -Fxq 'got:' "$kept/logs/head/tests__test-stdin.sh.log" \
   && grep -Fxq 'got:' "$kept/logs/base/tests__test-stdin.sh.log" \
   && ! grep -Fq 'should-not-be-read' "$kept/logs/head/tests__test-stdin.sh.log"; then
  pass 'suite stdin is disconnected on both sides'
else fail 'suite inherited caller stdin'; fi
remove_kept "$kept"
capture env HOME="$scratch/home" TMPDIR="$scratch/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent \
  GIT_OBJECT_DIRECTORY=/nonexistent GIT_ALTERNATE_OBJECT_DIRECTORIES=/nonexistent GIT_COMMON_DIR=/nonexistent \
  bash "$scratch/topic/bin/test-baseline.sh" --base origin/main "${subset[@]}"
if [ "$EXIT_CODE" -eq 0 ] && text_has 'Summary: 0 regression, 1 pre-existing, 1 fixed, 1 clean, 0 new, 0 skipped'; then
  pass 'all six inherited Git overrides are ignored'
else fail 'inherited Git overrides'; fi
rm -f "$scratch/topic/tests/written-here.txt"
capture baseline --keep --json tests/test-writer.sh
kept=$(printf '%s\n' "$OUTPUT" | jq -r '.base.tree | sub("/base$"; "")')
if [ "$EXIT_CODE" -eq 0 ] && [ -f "$scratch/topic/tests/written-here.txt" ] \
   && [ -f "$kept/base/tests/written-here.txt" ] && json_is '.logs == (.base.tree | sub("/base$"; "/logs"))'; then
  pass 'base and head suites write into their respective trees; JSON retains paths'
else fail 'suite cwd and keep JSON'; fi
remove_kept "$kept"
printf '%s\n' 'exit 1' > "$scratch/topic/tests/test-clean.sh"
capture baseline --json tests/test-clean.sh
if [ "$EXIT_CODE" -eq 1 ] && json_is '.suites[0].status == "regression" and .suites[0].new_failure_lines == []'; then
  pass 'uncommitted head failure is a regression even without failure lines'
else fail 'uncommitted head'; fi
printf '%s\n' 'echo ok' > "$scratch/topic/tests/test-clean.sh"

# 13. Host-independent runner absence, adapter fallback, and optional real pytest.
mkdir -p "$scratch/path" "$scratch/no-pytest" "$scratch/failures"
for tool in bash env dirname git jq mktemp mkdir rm readlink grep sort comm tail awk cat; do
  ln -s "$(command -v "$tool")" "$scratch/path/$tool"
done
for spec in 'tests/test_py.py:no pytest' 'tests/test-bats.bats:no bats'; do
  capture fixture_env env PATH="$scratch/path" bash "$scratch/topic/bin/test-baseline.sh" --json "${spec%%:*}"
  if [ "$EXIT_CODE" -eq 0 ] && json_is ".suites[0].status == \"skipped\" and .suites[0].note == \"${spec#*:}\"
    and .suites[0].base == null and .suites[0].head == null and .summary.skipped == 1"; then
    pass "missing runner ${spec#*:}"
  else fail "missing runner ${spec#*:}"; fi
  capture fixture_env env PATH="$scratch/path" bash "$scratch/topic/bin/test-baseline.sh" --head-first --json "${spec%%:*}"
  if [ "$EXIT_CODE" -eq 0 ] && json_is ".suites[0].status == \"skipped\" and .suites[0].note == \"${spec#*:}\"
    and .suites[0].base == null and .suites[0].head == null and .summary.blocked == 0"; then
    pass "head-first missing runner ${spec#*:} remains skipped"
  else fail "head-first missing runner ${spec#*:}"; fi
done
for strict_order in full head-first; do
  strict_args=(--strict-head --json)
  if [ "$strict_order" = head-first ]; then strict_args+=(--head-first); fi
  capture fixture_env env PATH="$scratch/path" bash "$scratch/topic/bin/test-baseline.sh" \
    "${strict_args[@]}" tests/test_py.py tests/test-bats.bats
  if [ "$EXIT_CODE" -eq 2 ] && json_is 'all(.suites[]; .status == "skipped" and .head == null and .base == null)
    and .summary.skipped == 2'; then
    pass "strict $strict_order rejects unexecuted heads with unavailable runners"
  else fail "strict $strict_order unavailable runners"; fi
done
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/bash' 'echo probe >> "$TMPDIR/python-probes"' 'exit 1' > "$scratch/no-pytest/python3"
chmod +x "$scratch/no-pytest/python3"
cp "$scratch/topic/tests/test_py.py" "$scratch/topic/tests/test_more.py"
capture fixture_env env PATH="$scratch/no-pytest:$scratch/path" bash "$scratch/topic/bin/test-baseline.sh" \
  --json tests/test_py.py tests/test_more.py
if [ "$EXIT_CODE" -eq 0 ] && json_is 'all(.suites[]; .status == "skipped" and .note == "no pytest")' \
   && [ "$(awk 'END {print NR}' "$scratch/tmp/python-probes")" -eq 1 ]; then
  pass 'pytest import failure is probed once across suites'
else fail 'pytest import failure and probe count'; fi
if command -v python3 >/dev/null 2>&1 && python3 -c 'import pytest' >/dev/null 2>&1; then
  capture baseline --json tests/test_py.py
  if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "clean" and .suites[0].runner == "pytest"'; then
    pass 'available pytest runs both trees'
  else fail 'available pytest'; fi
else echo '  SKIP: real pytest is unavailable (missing-runner contract tested)'; fi
capture baseline --json tests/test-node.mjs
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "clean"'; then pass 'real node adapter'; else fail 'real node adapter'; fi
# A failing head adapter with no node on PATH must skip both suite sides.
cp "$scratch/topic/bin/node-run.sh" "$scratch/adapter.saved"
printf '%s\n' 'exit 126' > "$scratch/topic/bin/node-run.sh"
capture fixture_env env PATH="$scratch/path" bash "$scratch/topic/bin/test-baseline.sh" --json tests/test-node.mjs
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "skipped" and .suites[0].note == "no Node"
  and .suites[0].base == null and .suites[0].head == null'; then
  pass 'unavailable node skips both sides'
else fail 'missing node'; fi
capture fixture_env env PATH="$scratch/path" bash "$scratch/topic/bin/test-baseline.sh" --head-first --json tests/test-node.mjs
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "skipped" and .suites[0].note == "no Node"
  and .suites[0].base == null and .suites[0].head == null and .summary.blocked == 0'; then
  pass 'head-first unavailable node remains skipped'
else fail 'head-first missing node'; fi
capture fixture_env env PATH="$scratch/path" bash "$scratch/topic/bin/test-baseline.sh" --strict-head --head-first --json tests/test-node.mjs
if [ "$EXIT_CODE" -eq 2 ] && json_is '.suites[0].status == "skipped" and .suites[0].note == "no Node"
  and .suites[0].head == null and .summary.skipped == 1'; then
  pass 'strict unavailable Node cannot pass without head execution'
else fail 'strict missing Node'; fi
capture baseline --json tests/test-node.mjs
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "clean"'; then pass 'failed adapter falls back to node'; else fail 'node fallback'; fi
rm "$scratch/topic/bin/node-run.sh"
capture baseline --json tests/test-node.mjs
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "clean"'; then pass 'absent adapter uses node'; else fail 'absent adapter fallback'; fi
cp "$scratch/adapter.saved" "$scratch/topic/bin/node-run.sh"

# Only a failing head needs the base interpreter. Make that absence independent
# of the host's installed node binary without altering the main baseline ref.
fixture_git -C "$scratch/topic" worktree add -b no-node-base "$scratch/no-node-base" origin/main >/dev/null 2>&1
printf '%s\n' 'exit 126' > "$scratch/no-node-base/bin/node-run.sh"
fixture_git -C "$scratch/no-node-base" add bin/node-run.sh
fixture_git -C "$scratch/no-node-base" commit -qm 'Fixture without base node adapter'
fixture_git -C "$scratch/topic" worktree remove --force "$scratch/no-node-base"
cat > "$scratch/topic/bin/node-run.sh" <<'EOF'
if [ "${1:-}" = --version ]; then echo v22.0.0; exit 0; fi
echo 'FAIL: head adapter fixture'
exit "${QA_NODE_EXIT:-0}"
EOF
capture fixture_env env PATH="$scratch/path" QA_NODE_EXIT=0 bash "$scratch/topic/bin/test-baseline.sh" \
  --head-first --base no-node-base --json tests/test-node.mjs
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "passed" and .suites[0].base == null
  and .suites[0].head.exit == 0 and .summary.blocked == 0'; then
  pass 'a passing head does not require the unavailable base interpreter'
else fail 'passing head unnecessarily requires base dependency'; fi
capture fixture_env env PATH="$scratch/path" QA_NODE_EXIT=1 bash "$scratch/topic/bin/test-baseline.sh" \
  --head-first --base no-node-base --json tests/test-node.mjs
if [ "$EXIT_CODE" -eq 2 ] && json_is '.suites[0].status == "blocked" and .suites[0].base == null
  and .suites[0].head.exit == 1 and .summary.blocked == 1
  and .summary.regression == 0 and .summary.pre_existing == 0'; then
  pass 'missing base interpreter blocks the comparison of a failing head'
else fail 'missing base comparison dependency'; fi
capture fixture_env env PATH="$scratch/path" QA_NODE_EXIT=1 bash "$scratch/topic/bin/test-baseline.sh" \
  --strict-head --head-first --base no-node-base --json tests/test-node.mjs
if [ "$EXIT_CODE" -eq 2 ] && json_is '.suites[0].status == "blocked" and .suites[0].base == null
  and .suites[0].head.exit == 1 and .summary.blocked == 1'; then
  pass 'strict missing base interpreter keeps blocked precedence over a completed failing head'
else fail 'strict missing base comparison dependency'; fi
cp "$scratch/adapter.saved" "$scratch/topic/bin/node-run.sh"

# 14–15. No origin, clean same-commit checkout, and detached head.
fixture_git clone "$scratch/origin.git" "$scratch/main" >/dev/null 2>&1
capture fixture_run "$scratch/main" tests/test-clean.sh tests/test-red.sh
if [ "$EXIT_CODE" -eq 0 ] && text_has 'Summary: 0 regression, 1 pre-existing, 0 fixed, 1 clean, 0 new, 0 skipped'; then
  pass 'same commit and clean head retain pre-existing failures'
else fail 'same commit'; fi
for strict_order in full head-first; do
  strict_args=(--strict-head --keep --json)
  if [ "$strict_order" = head-first ]; then strict_args+=(--head-first); fi
  capture fixture_run "$scratch/main" "${strict_args[@]}" tests/test-red.sh
  kept=$(printf '%s\n' "$OUTPUT" | jq -r '.base.tree | sub("/base$"; "")')
  if [ "$EXIT_CODE" -eq 1 ] && json_is '.suites[0].status == "pre-existing"
    and .suites[0].head.exit == 1 and .suites[0].base.exit == 1 and .suites[0].new_failure_lines == []' \
     && grep -Fxq 'FAIL: old' "$kept/logs/head/tests__test-red.sh.log" \
     && grep -Fxq 'FAIL: old' "$kept/logs/base/tests__test-red.sh.log"; then
    pass "strict $strict_order rejects failure at identical base/head commits and retains both logs"
  else fail "strict $strict_order same-commit failure"; fi
  fixture_git -C "$scratch/main" worktree remove --force "$kept/base"
  rm -rf "$kept"
done
fixture_git -C "$scratch/main" remote remove origin
capture fixture_run "$scratch/main" tests/test-clean.sh
if [ "$EXIT_CODE" -eq 0 ] && text_has 'Base: main ('; then pass 'local main works without origin'; else fail 'no origin'; fi
fixture_git -C "$scratch/main" switch --detach >/dev/null 2>&1
capture fixture_run "$scratch/main" --json tests/test-clean.sh
if [ "$EXIT_CODE" -eq 0 ] && json_is '.head.ref == "HEAD" and .suites[0].status == "clean"'; then pass 'detached head'; else fail 'detached head'; fi

# Extra boundaries: spaces, internal symlinks, EOF logs, and checkout cleanliness.
capture baseline --json 'tests/suite with spaces.sh' tests/test-link.sh tests/test-eof.sh tests/test-silent.sh tests/test-checkout.sh
if [ "$EXIT_CODE" -eq 0 ] && json_is '(.suites | map(.status)) == ["clean","clean","pre-existing","pre-existing","clean"]'; then
  pass 'spaces, internal symlinks, EOF and silent logs, real clean detached base'
else fail 'suite and checkout boundaries'; fi
printf '%s\n' local > "$scratch/topic/local-only"
capture baseline --json tests/test-local.sh
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "fixed"'; then
  pass 'untracked local dependencies read as fixed'
else fail 'clean base local dependency'; fi
printf '%s\n' 'printf "Traceback: new EOF"' 'exit 1' > "$scratch/topic/tests/test-eof.sh"
capture baseline --json tests/test-eof.sh
if [ "$EXIT_CODE" -eq 1 ] && json_is '.suites[0].new_failure_lines == ["Traceback: new EOF"]'; then
  pass 'new failure without a trailing newline survives the diff'
else fail 'new EOF failure'; fi

# Scratch and worktree failures never produce a partial report or leave a tree.
printf '%s\n' '#!/bin/bash' 'echo "fixture mktemp failure" >&2' 'exit 1' > "$scratch/failures/mktemp"
chmod +x "$scratch/failures/mktemp"
capture fixture_env env PATH="$scratch/failures:$PATH" bash "$scratch/topic/bin/test-baseline.sh" tests/test-clean.sh
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && no_scratch \
   && grep -Fq 'test-baseline: cannot create scratch directory' "$scratch/stderr"; then
  pass 'mktemp failure exits 2 with empty stdout'
else fail 'mktemp failure'; fi
rm "$scratch/failures/mktemp"
cat > "$scratch/failures/git" <<'EOF'
#!/bin/bash
if [ "${3:-}" = worktree ] && [ "${4:-}" = add ]; then
  echo 'fixture worktree failure' >&2
  exit 1
fi
exec "$QA_REAL_GIT" "$@"
EOF
chmod +x "$scratch/failures/git"
capture fixture_env env PATH="$scratch/failures:$PATH" QA_REAL_GIT="$(command -v git)" \
  bash "$scratch/topic/bin/test-baseline.sh" tests/test-clean.sh
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && no_scratch && [ "$(tree_count)" -eq 1 ] \
   && grep -Fxq 'test-baseline: cannot create the base worktree:' "$scratch/stderr" \
   && grep -Fxq 'fixture worktree failure' "$scratch/stderr"; then
  pass 'worktree creation failure preserves Git stderr and removes scratch'
else fail 'worktree creation failure'; fi
rm "$scratch/failures/git"
# F4. ERR must propagate through failure_lines and its sorting pipeline.
printf '%s\n' '#!/bin/bash' 'exit 1' > "$scratch/failures/sort"
chmod +x "$scratch/failures/sort"
capture fixture_env env PATH="$scratch/failures:$PATH" bash "$scratch/topic/bin/test-baseline.sh" --json tests/test-clean.sh
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && no_scratch && [ "$(tree_count)" -eq 1 ] \
   && grep -E '^test-baseline: environment command failed \(line [0-9]+\)$' "$scratch/stderr" >/dev/null; then
  pass 'function pipeline failure exits 2 with a message and cleanup'
else fail 'ERR inheritance inside functions'; fi
rm "$scratch/failures/sort"
mkdir -p "$scratch/topic/unsafe-tmp"
capture fixture_env env TMPDIR="$scratch/topic/unsafe-tmp" bash "$scratch/topic/bin/test-baseline.sh" tests/test-clean.sh
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] \
   && [ -z "$(ls -A "$scratch/topic/unsafe-tmp")" ] && grep -Fq 'scratch directory is inside repository' "$scratch/stderr"; then
  pass 'TMPDIR inside the checkout is rejected without writes'
else fail 'internal scratch protection'; fi
# A scratch root outside the system temp roots (a user's own TMPDIR, or a CI
# runner's) must not leak its random run paths into the failure evidence.
alt_tmp=$(mktemp -d "$SCRIPT_DIR/tmp/qa-baseline-alt.XXXXXX")
capture fixture_env env TMPDIR="$alt_tmp" bash "$scratch/topic/bin/test-baseline.sh" --json tests/test-noise.sh
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suites[0].status == "pre-existing" and .suites[0].new_failure_lines == []' \
   && [ -z "$(find "$alt_tmp" -maxdepth 1 -name 'qa-baseline.*')" ]; then
  pass 'a TMPDIR outside the system temp roots is normalized like /tmp'
else fail 'custom TMPDIR normalization'; fi
rm -rf "$alt_tmp"

# A suite whose nonblank output is entirely SKIP declined to run; a red suite
# or a suite with any actual execution output retains its ordinary result.
capture baseline --json tests/test-live.sh tests/test-live-red.sh
if [ "$EXIT_CODE" -eq 0 ] \
   && json_is '(.suites | map(.status)) == ["skipped","pre-existing"]
     and .suites[0].note == "needs the live relay" and .suites[0].head.exit == 0
     and .summary.skipped == 1 and .summary.pre_existing == 1'; then
  pass 'a SKIP: opener with exit 0 reports as skipped with its reason'
else fail 'SKIP: opener classification'; fi
capture baseline tests/test-live.sh
if [ "$EXIT_CODE" -eq 0 ] && text_has '  skipped      tests/test-live.sh  needs the live relay'; then
  pass 'skipped suites show their reason in the text report'
else fail 'skipped text report'; fi
capture baseline --json tests/test-partial-skip.sh tests/test-skip-output.sh tests/test-all-skip.sh
if [ "$EXIT_CODE" -eq 0 ] && json_is '(.suites | map(.status)) == ["clean","clean","skipped"]
  and .suites[2].note == "first unavailable service"'; then
  pass 'only all-SKIP output declines the suite; blank lines are harmless'
else fail 'partial SKIP mistaken for whole-suite skip'; fi
capture baseline --head-first --json tests/test-live.sh tests/test-partial-skip.sh tests/test-skip-output.sh tests/test-all-skip.sh tests/test-live-red.sh
if [ "$EXIT_CODE" -eq 0 ] && json_is '(.suites | map(.status)) == ["skipped","passed","passed","skipped","pre-existing"]
  and all(.suites[:4][]; .base == null)
  and .suites[0].note == "needs the live relay" and .suites[4].base.exit == 1'; then
  pass 'head-first distinguishes a wholly skipped suite from partial skips and red SKIP output'
else fail 'head-first SKIP output contract'; fi

# F6. A linked checkout shares Git metadata outside its own working tree.
fixture_git -C "$scratch/topic" worktree add --detach "$scratch/linked" topic >/dev/null 2>&1
linked_git_dir=$(fixture_git -C "$scratch/linked" rev-parse --path-format=absolute --git-dir)
for git_temp in "$scratch/topic/.git" "$scratch/topic/.git/objects" "$linked_git_dir"; do
  capture fixture_env env TMPDIR="$git_temp" bash "$scratch/linked/bin/test-baseline.sh" tests/test-clean.sh
  scratch_created=false
  for entry in "$git_temp"/qa-baseline.*; do [ ! -e "$entry" ] || scratch_created=true; done
  if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && ! $scratch_created \
     && grep -Fq 'scratch directory is inside repository' "$scratch/stderr"; then
    pass "linked worktree rejects scratch in Git metadata: ${git_temp##*/}"
  else fail 'linked worktree Git scratch protection'; fi
done
fixture_git -C "$scratch/topic" worktree remove --force "$scratch/linked"
if [ "$(tree_count)" -eq 1 ]; then pass 'linked metadata fixture removed'; else fail 'linked metadata cleanup'; fi

# F2. An unavailable unrelated checkout retains its registration after a run.
fixture_git -C "$scratch/topic" worktree add --detach "$scratch/unmounted" HEAD >/dev/null 2>&1
mv "$scratch/unmounted" "$scratch/parked"
capture baseline tests/test-clean.sh
if [ "$EXIT_CODE" -eq 0 ] && no_scratch && [ "$(tree_count)" -eq 2 ] \
   && [ -d "$scratch/topic/.git/worktrees/unmounted" ]; then
  pass 'unavailable unrelated worktree registration is preserved'
else fail 'unrelated worktree pruned'; fi
mv "$scratch/parked" "$scratch/unmounted"
fixture_git -C "$scratch/topic" worktree remove --force "$scratch/unmounted"

# Two simultaneous runs own different scratch directories and registrations.
start_baseline "$scratch/one.json" "$scratch/one.err" --keep --json tests/test-clean.sh
first_pid=$tool_pid
start_baseline "$scratch/two.json" "$scratch/two.err" --keep --json tests/test-red.sh
second_pid=$tool_pid
first_code=0; second_code=0
wait "$first_pid" || first_code=$?
wait "$second_pid" || second_code=$?
active_pids=()
first_tree=$(jq -r '.base.tree' "$scratch/one.json")
second_tree=$(jq -r '.base.tree' "$scratch/two.json")
if [ "$first_code" -eq 0 ] && [ "$second_code" -eq 0 ] && [ "$first_tree" != "$second_tree" ] \
   && [ -d "$first_tree" ] && [ -d "$second_tree" ] && [ "$(tree_count)" -eq 3 ] \
   && jq -e '.suites[0].status == "clean"' "$scratch/one.json" >/dev/null \
   && jq -e '.suites[0].status == "pre-existing"' "$scratch/two.json" >/dev/null; then
  pass 'concurrent runs have independent trees, logs, and results'
else
  fail 'concurrent baseline runs'
  printf '  concurrent exits: first=%s second=%s\n' "$first_code" "$second_code" >&2
  for concurrent_run in one two; do
    printf '  %s runner stderr:\n' "$concurrent_run" >&2
    cat "$scratch/$concurrent_run.err" >&2
    printf '  %s runner stdout:\n' "$concurrent_run" >&2
    cat "$scratch/$concurrent_run.json" >&2
  done
fi
# A failed worker may have emitted no report. Preserve the original failure
# instead of masking it with an attempted worktree removal at /base.
if [ -n "$first_tree" ] && [ -d "$first_tree" ]; then remove_kept "${first_tree%/base}"; fi
if [ -n "$second_tree" ] && [ -d "$second_tree" ]; then remove_kept "${second_tree%/base}"; fi
if no_scratch && [ "$(tree_count)" -eq 1 ]; then pass 'all fixture worktrees cleaned'; else fail 'final cleanup'; fi

printf '\n=== Results: %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
