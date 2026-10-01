#!/usr/bin/env bash
set -euo pipefail

# Pin the CI baseline contract and exercise its shell steps with isolated stubs.
# Usage: bash tests/test-suite-baseline-workflow.sh
# Exit 0 = all cases passed, Exit 1 = a case failed

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$SCRIPT_DIR/.github/workflows/ci.yml"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
scratch=$(mktemp -d /tmp/test-suite-baseline-workflow.XXXXXX)
trap 'rm -rf "$scratch"' EXIT

# Job-specific assertions must not be satisfied by an unrelated VM owner.
awk '/^  baseline:$/ { job=1; next }
  job && /^  [^ ]/ { exit }
  job { print }' "$workflow" > "$scratch/baseline"
baseline_has() { grep -Fq -- "$1" "$scratch/baseline"; }
has() { grep -Fq -- "$1" "$workflow"; }
matches() { grep -Eq -- "$1" "$workflow"; }
check() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

echo '=== suite-baseline workflow tests ==='
awk '/^  pull_request:$/ { pr=1; next }
  pr && /^  [^ ]/ { exit }
  pr { print }' "$workflow" > "$scratch/pull-request"
if matches '^  pull_request:$' && ! grep -Eq '^    paths:' "$scratch/pull-request"; then
  pass 'all PRs enter conservative shared planning'
else fail 'all PRs enter conservative shared planning'; fi
check 'planner is a reusable workflow' has 'uses: ./.github/workflows/ci-plan.yml'
check 'baseline waits for its plan' has 'needs: plan'
check 'selected baseline work runs and planner failure reaches the strict guard' has "if: \${{ !cancelled() && (github.event_name != 'pull_request' || !github.event.pull_request.draft) && (needs.plan.result != 'success' || needs.plan.outputs.baseline == 'true') }}"
check 'merge queue candidates run' matches '^  merge_group:$'
if matches '^  push:$'; then
  fail 'merged commits do not repeat PR checks'
else pass 'merged commits do not repeat PR checks'; fi
check 'manual dispatch remains available' matches '^  workflow_dispatch:$'
if grep -Eq '^[[:space:]]*branches(-ignore)?:' "$scratch/pull-request"; then
  fail 'no branch filter excludes pull requests'
else pass 'no branch filter excludes pull requests'; fi
check 'read-only repository permission' matches '^  contents: read$'
# shellcheck disable=SC2016
check 'concurrency separates event, candidate, and full mode' has 'group: ci-${{ github.event_name }}-${{ github.event.pull_request.number || github.ref }}-${{ inputs.mode || '\''affected'\'' }}'
check 'superseded runs are cancelled' has 'cancel-in-progress: true'
check 'baseline job exists' matches '^  baseline:$'
check 'baseline uses Slim' baseline_has 'runs-on: ubuntu-slim'
check 'baseline stays within the fifteen-minute runner limit' baseline_has 'timeout-minutes: 15'
check 'all shards finish independently' has 'fail-fast: false'
# shellcheck disable=SC2016
check 'matrix allocates only the planned shards with a failed-plan fallback' has 'shard: ${{ fromJSON(needs.plan.outputs.baseline_shards || '\''[0]'\'') }}'
# These are GitHub expressions and shell source, intentionally matched literally.
# shellcheck disable=SC2016
check 'job names identify each shard' has 'name: Suite baseline — shard ${{ matrix.shard }}'
check 'checkout uses v4' has 'uses: actions/checkout@v4'
check 'Node setup uses v4' has 'uses: actions/setup-node@v4'
check 'checkout keeps full history for merge-base computation' has 'fetch-depth: 0'
check 'Node version is 22' has 'node-version: 22'
check 'baseline supplies shell, sync and process-inspection tools' baseline_has 'sudo apt-get install -y jq zsh procps lsof rsync util-linux'
# shellcheck disable=SC2016
check 'baseline checks every required tool before testing' baseline_has 'for tool in bash git python3 node jq zsh perl tar pgrep ps lsof rsync shasum setsid; do command -v "$tool"; done'
# shellcheck disable=SC2016
check 'PR base comes from event context' has 'BASE: ${{ github.base_ref }}'
# shellcheck disable=SC2016
check 'merge queue base comes from event context' has 'MERGE_BASE_REF: ${{ github.event.merge_group.base_ref }}'
# shellcheck disable=SC2016
check 'comparison freezes the PR or merge-queue base commit' has 'BASE_SHA: ${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || '\'''\'' }}'
# shellcheck disable=SC2016
check 'base fetch names the remote-tracking destination' has 'git fetch origin "+refs/heads/$BASE:refs/remotes/origin/$BASE"'
# shellcheck disable=SC2016
check 'selected inventory is validated and owned suites are excluded before execution' has 'bash bin/suite-shard.sh --exclude-owned --selected "$RUNNER_TEMP/baseline-selection.json" ${{ matrix.shard }} "$BASELINE_SHARD_COUNT" > selected-suites.txt || exit 2'
# shellcheck disable=SC2016
check 'planner selection is passed as data' has 'BASELINE_SUITES: ${{ needs.plan.outputs.baseline_suites }}'
# shellcheck disable=SC2016
check 'planner shard count is passed as data' has 'BASELINE_SHARD_COUNT: ${{ needs.plan.outputs.baseline_shard_count }}'
# shellcheck disable=SC2016
check 'selected suites use bounded head-first comparison' has 'baseline_args=(--head-first --timeout 300 --keep --base "$BASE_REF")'
# shellcheck disable=SC2016
check 'full runs receive the strict head policy' has 'BASELINE_STRICT: ${{ needs.plan.outputs.baseline_strict }}'
check 'strict head failures cannot pass as pre-existing debt' has 'true) baseline_args+=(--strict-head)'
# shellcheck disable=SC2016
check 'baseline runs with arguments passed without shell evaluation' has 'bash bin/test-baseline.sh "${baseline_args[@]}" - < selected-suites.txt | tee suite-baseline.txt'
# shellcheck disable=SC2016
check 'run directory lives under the runner temp so its logs can be collected' has 'export TMPDIR="$RUNNER_TEMP/suite-baseline"'
# shellcheck disable=SC2016
check 'every head log is copied beside the report' has 'cp "$TMPDIR"/qa-baseline.*/logs/head/*.log suite-logs/'
check 'pipeline failures remain visible' has 'set -o pipefail'
# shellcheck disable=SC2016
check 'runner exit status is captured explicitly' has 'status=${PIPESTATUS[0]}'
# shellcheck disable=SC2016
check 'report reaches the job summary' has '$GITHUB_STEP_SUMMARY'
check 'reports upload after test failure but not planner failure' has "if: \${{ always() && needs.plan.result == 'success' }}"
check 'artifact upload uses v4' has 'uses: actions/upload-artifact@v4'
# shellcheck disable=SC2016
check 'artifact names identify each shard' has 'name: suite-baseline-shard-${{ matrix.shard }}'
check 'artifact contains the report' has 'suite-baseline.txt'
check 'artifact contains the head logs' has 'suite-logs/'
check 'absent report does not fail artifact upload' has 'if-no-files-found: ignore'

# Exercise the actual run blocks under GitHub's bash -e -o pipefail defaults.
extract_step() {
  awk -v step="$1" '
    $0 == "      - name: " step { found=1; next }
    found && /^        run: \|$/ { script=1; next }
    script && /^          / { sub(/^          /, ""); print; next }
    script { exit }
  ' "$workflow"
}
extract_step 'Resolve the base' > "$scratch/resolve.sh"
extract_step 'Compare shell suites' | sed 's/${{ matrix.shard }}/0/g' > "$scratch/compare.sh"
mkdir -p "$scratch/commands" "$scratch/repo/bin/tests" "$scratch/repo/tests"
cat > "$scratch/commands/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FETCH_ARGS"
exit "${FETCH_STATUS:-0}"
EOF
chmod +x "$scratch/commands/git"
resolve_case() {
  local label="$1" pr_base="$2" merge_base="$3" expected="$4"
  local code=0
  : > "$scratch/github-env"
  BASE="$pr_base" MERGE_BASE_REF="$merge_base" GITHUB_ENV="$scratch/github-env" \
    FETCH_ARGS="$scratch/fetch-args" FETCH_STATUS=0 PATH="$scratch/commands:$PATH" \
    bash --noprofile --norc -e -o pipefail "$scratch/resolve.sh" || code=$?
  printf '%s\n' fetch origin "+refs/heads/$expected:refs/remotes/origin/$expected" > "$scratch/expected-fetch"
  if [ "$code" -eq 0 ] && grep -Fxq "BASE=$expected" "$scratch/github-env" \
    && grep -Fxq "BASE_REF=${5:-origin/$expected}" "$scratch/github-env" \
    && cmp -s "$scratch/expected-fetch" "$scratch/fetch-args"; then
    pass "$label"
  else fail "$label"; fi
}
BASE_SHA=1234567890abcdef1234567890abcdef12345678 \
  resolve_case 'PR base commit remains fixed when its branch advances' 'release/next' 'refs/heads/ignored' 'release/next' '1234567890abcdef1234567890abcdef12345678'
resolve_case 'merge queue strips refs/heads/ and retains branch slashes' '' 'refs/heads/release/next' 'release/next'
resolve_case 'manual dispatch defaults to develop' '' '' 'develop'
BASE_SHA=876543210fedcba9876543210fedcba987654321 \
  resolve_case 'merge queue uses its immutable base commit' '' 'refs/heads/develop' 'develop' '876543210fedcba9876543210fedcba987654321'
: > "$scratch/github-env"
code=0
BASE=missing MERGE_BASE_REF='' GITHUB_ENV="$scratch/github-env" \
  FETCH_ARGS="$scratch/fetch-args" FETCH_STATUS=128 PATH="$scratch/commands:$PATH" \
  bash --noprofile --norc -e -o pipefail "$scratch/resolve.sh" || code=$?
if [ "$code" -eq 2 ] && [ ! -s "$scratch/github-env" ]; then
  pass 'unfetchable base exits 2 without exporting a usable base'
else fail 'unfetchable base exits 2 without exporting a usable base'; fi

for invalid_base_sha in '--help' '1234'; do
  : > "$scratch/github-env"
  code=0
  BASE=develop MERGE_BASE_REF='' BASE_SHA="$invalid_base_sha" GITHUB_ENV="$scratch/github-env" \
    FETCH_ARGS="$scratch/fetch-args" FETCH_STATUS=0 PATH="$scratch/commands:$PATH" \
    bash --noprofile --norc -e -o pipefail "$scratch/resolve.sh" || code=$?
  if [ "$code" -eq 2 ] && [ ! -s "$scratch/github-env" ]; then
    pass 'malformed immutable base fails before becoming a comparison ref'
  else fail 'malformed immutable base fails before becoming a comparison ref'; fi
done

# Ownership selection is independently tested; this fixture verifies argument
# forwarding, intact paths, and fail-closed behavior if the selector fails.
cat > "$scratch/repo/bin/suite-shard.sh" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 5 ] && [ "$1" = --exclude-owned ] && [ "$2" = --selected ] && [ "$4" = 0 ] && [ "$5" = 1 ] || exit 99
[ "${SHARD_STATUS:-0}" -eq 0 ] || exit "$SHARD_STATUS"
grep -Fxq '["tests/suite with spaces.sh"]' "$3" || exit 99
printf '%s\n' 'tests/suite with spaces.sh'
EOF
: > "$scratch/repo/tests/suite with spaces.sh"
: > "$scratch/repo/tests/run-all.sh"
printf '%s\n' 'tests/suite with spaces.sh' > "$scratch/expected-suites"
cat > "$scratch/repo/bin/test-baseline.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --head-first ] && [ "$2" = --timeout ] && [ "$3" = 300 ] && [ "$4" = --keep ] && [ "$5" = --base ] && [ "$6" = "$BASE_REF" ] || exit 99
if [ "$BASELINE_STRICT" = true ]; then
  [ "$#" -eq 8 ] && [ "$7" = --strict-head ] && [ "$8" = - ] || exit 99
else
  [ "$#" -eq 7 ] && [ "$7" = - ] || exit 99
fi
cat > "$RECEIVED_SUITES"
cmp -s "$EXPECTED_SUITES" "$RECEIVED_SUITES" || exit 99
# A kept run directory under TMPDIR, as the real runner leaves it.
mkdir -p "$TMPDIR/qa-baseline.mock/logs/head"
printf 'head output\n' > "$TMPDIR/qa-baseline.mock/logs/head/tests__suite with spaces.sh.log"
cat "$MOCK_REPORT"
exit "$MOCK_STATUS"
EOF
compare_case() {
  local label="$1" expected_status="$2" report="$3"
  local code=0
  printf '%s' "$report" > "$scratch/mock-report"
  : > "$scratch/summary"
  rm -rf "$scratch/runner-temp" "$scratch/repo/suite-logs"
  (
    cd "$scratch/repo"
    BASE=develop BASE_REF=origin/develop GITHUB_STEP_SUMMARY="$scratch/summary" RUNNER_TEMP="$scratch/runner-temp" \
      BASELINE_SUITES='["tests/suite with spaces.sh"]' BASELINE_SHARD_COUNT=1 BASELINE_STRICT="${4:-false}" \
      RECEIVED_SUITES="$scratch/received-suites" EXPECTED_SUITES="$scratch/expected-suites" \
      MOCK_REPORT="$scratch/mock-report" MOCK_STATUS="$expected_status" \
      bash --noprofile --norc -e -o pipefail "$scratch/compare.sh"
  ) > "$scratch/stdout" 2> "$scratch/stderr" || code=$?
  {
    printf '## Suite baseline — shard 0 of 1 (base origin/develop)\n\n```text\n'
    cat "$scratch/mock-report"
    printf '\n```\n'
  } > "$scratch/expected-summary"
  if [ "$code" -eq "$expected_status" ] \
    && cmp -s "$scratch/expected-summary" "$scratch/summary" \
    && cmp -s "$scratch/mock-report" "$scratch/repo/suite-baseline.txt" \
    && cmp -s "$scratch/mock-report" "$scratch/stdout" \
    && cmp -s "$scratch/expected-suites" "$scratch/received-suites" \
    && [ "$(cat "$scratch/repo/suite-logs/tests__suite with spaces.sh.log")" = 'head output' ]; then
    pass "$label"
  else
    fail "$label"
    cat "$scratch/stderr" >&2
  fi
}
compare_case 'pre-existing failures pass and spaced suite paths survive stdin' 0 $'pre-existing tests/suite with spaces.sh\n'
compare_case 'regressions fail after writing the summary and report' 1 $'regression tests/suite with spaces.sh\n'
compare_case 'environment exit 2 survives and an empty report still gets a fenced summary' 2 ''
compare_case 'strict full runs forward the flag and preserve a failing head status' 1 $'pre-existing tests/suite with spaces.sh\n' true

code=0
(
  cd "$scratch/repo"
  SHARD_STATUS=2 BASELINE_SUITES='[]' BASELINE_SHARD_COUNT=1 RUNNER_TEMP="$scratch/runner-temp" \
    bash --noprofile --norc -e -o pipefail "$scratch/compare.sh"
) > "$scratch/stdout" 2> "$scratch/stderr" || code=$?
if [ "$code" -eq 2 ]; then pass 'selector failure blocks the workflow'; else fail 'selector failure blocks the workflow'; fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
