#!/usr/bin/env bash
# bin/qa-gate.sh: the one-command framework gate. Runs the gate against a
# throwaway checkout so every step's pass, fail, and skip path is exercised
# without touching this repository or any live service.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/bin/qa-gate.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export QA_GATE_LOGS="$TMP/logs"

PASS=0
FAIL=0
check() {
  if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL: $2"; fi
}

# --- fixture: a small checkout with only the files the steps read ---
FIX="$TMP/fixture"
mkdir -p "$FIX/bin/lib" "$FIX/tmp"
cp "$GATE" "$FIX/bin/qa-gate.sh"
printf '#!/usr/bin/env bash\necho fine\n' > "$FIX/bin/good.sh"
printf '#!/usr/bin/env bash\necho fine\n' > "$FIX/bin/lib/helper.sh"
printf '%s\n' '{"mode":"local","github_org":"Fixture-Corp"}' > "$FIX/egregore.json"
git -C "$FIX" init -q -b develop
git -C "$FIX" -c user.name=t -c user.email=t@example.test add -A
git -C "$FIX" -c user.name=t -c user.email=t@example.test commit -qm init

echo "--- --list prints the steps in gate order"
expected="syntax oss-strings env-source json-literal local-mode static secret-hygiene audit validate codex-sync migration package-tests diff-check"
actual=$(bash "$GATE" --list | tr '\n' ' ' | sed 's/ $//')
[ "$actual" = "$expected" ]; check $? "list: got '$actual'"

echo "--- unknown step and unknown option exit 2"
bash "$GATE" --only nonesuch >/dev/null 2>&1; [ $? -eq 2 ]; check $? "unknown step should exit 2"
bash "$GATE" --frobnicate >/dev/null 2>&1; [ $? -eq 2 ]; check $? "unknown option should exit 2"

echo "--- a clean fixture passes the checks it can run and skips the rest"
out=$(bash "$FIX/bin/qa-gate.sh" 2>&1); rc=$?
[ $rc -eq 0 ]; check $? "clean fixture should exit 0: $out"
grep -q '^✓ syntax' <<< "$out"; check $? "syntax should pass"
grep -q '^✓ oss-strings' <<< "$out"; check $? "oss-strings should pass"
grep -q '^✓ local-mode' <<< "$out"; check $? "local-mode is vacuous without the scripts"
grep -q '^– static skipped' <<< "$out"; check $? "static skips without test-changes.sh"
grep -q '^– audit skipped' <<< "$out"; check $? "audit skips without the engine"
grep -q '^– package-tests skipped' <<< "$out"; check $? "package tests skip without the package"
grep -q '^✓ diff-check' <<< "$out"; check $? "diff-check should pass on a clean tree"
grep -q 'qa-gate: .* 0 failed' <<< "$out"; check $? "summary should report 0 failed"

echo "--- a syntax error is named and fails the gate"
printf '#!/usr/bin/env bash\nif [ x; then\n' > "$FIX/bin/broken.sh"
out=$(bash "$FIX/bin/qa-gate.sh" --only syntax 2>&1); rc=$?
[ $rc -eq 1 ]; check $? "syntax failure should exit 1"
grep -q 'bin/broken.sh' <<< "$out"; check $? "the broken file should be named: $out"
rm -f "$FIX/bin/broken.sh"

echo "--- the org name from egregore.json is caught in any spelling, but not in a test file"
printf '#!/usr/bin/env bash\necho FixtureCorp\n' > "$FIX/bin/org.sh"
printf '#!/usr/bin/env bash\necho fixture-corp\n' > "$FIX/bin/test-org.sh"
out=$(bash "$FIX/bin/qa-gate.sh" --only oss-strings 2>&1); rc=$?
[ $rc -eq 1 ]; check $? "internal reference should exit 1"
grep -q 'org.sh' <<< "$out"; check $? "the offending script should be named"
grep -qv 'test-org.sh' <<< "$out"; check $? "test files are outside the check"
rm -f "$FIX/bin/org.sh" "$FIX/bin/test-org.sh"
mv "$FIX/egregore.json" "$FIX/egregore.json.off"
out=$(bash "$FIX/bin/qa-gate.sh" --only oss-strings 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q '^– oss-strings skipped' <<< "$out"; check $? "no egregore.json means skipped, not failed: $out"
mv "$FIX/egregore.json.off" "$FIX/egregore.json"

echo "--- unsafe .env sourcing and manual JSON are caught"
printf '#!/usr/bin/env bash\nsource .env\n' > "$FIX/bin/leak.sh"
out=$(bash "$FIX/bin/qa-gate.sh" --only env-source 2>&1); rc=$?
[ $rc -eq 1 ] && grep -q 'leak.sh' <<< "$out"; check $? "env sourcing should fail naming leak.sh: $out"
rm -f "$FIX/bin/leak.sh"
printf '#!/usr/bin/env bash\nJ="{\\"a\\":1}"\n' > "$FIX/bin/json.sh"
out=$(bash "$FIX/bin/qa-gate.sh" --only json-literal 2>&1); rc=$?
[ $rc -eq 1 ] && grep -q 'json.sh' <<< "$out"; check $? "manual JSON should fail naming json.sh: $out"
rm -f "$FIX/bin/json.sh"

echo "--- a graph script without local-mode handling fails"
printf '#!/usr/bin/env bash\ncurl example\n' > "$FIX/bin/graph.sh"
out=$(bash "$FIX/bin/qa-gate.sh" --only local-mode 2>&1); rc=$?
[ $rc -eq 1 ] && grep -q 'graph.sh' <<< "$out"; check $? "local-mode should fail naming graph.sh"
rm -f "$FIX/bin/graph.sh"

echo "--- trailing whitespace fails diff-check; other steps still run and the summary counts"
printf 'x \n' > "$FIX/bin/good.sh"
out=$(bash "$FIX/bin/qa-gate.sh" --only syntax,diff-check 2>&1); rc=$?
[ $rc -eq 1 ]; check $? "diff-check failure should exit 1"
grep -q '^✓ syntax' <<< "$out"; check $? "syntax still runs after a failure is queued"
grep -q '^✗ diff-check' <<< "$out"; check $? "diff-check should be marked failed"
grep -q 'qa-gate: 1 ok · 1 failed' <<< "$out"; check $? "summary should count 1 ok, 1 failed: $out"
[ -f "$QA_GATE_LOGS/diff-check.log" ]; check $? "a log per step should exist"
git -C "$FIX" checkout -q -- bin/good.sh

echo "--- --skip removes a step; --only and --skip compose"
out=$(bash "$FIX/bin/qa-gate.sh" --only syntax,diff-check --skip diff-check 2>&1); rc=$?
[ $rc -eq 0 ] && ! grep -q 'diff-check' <<< "$out"; check $? "skipped step must not appear: $out"

echo "--- --scope forwards arguments to test-changes.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$(dirname "$0")/../tmp/scope.txt"\n' > "$FIX/bin/test-changes.sh"
bash "$FIX/bin/qa-gate.sh" --only static --scope --all extra >/dev/null 2>&1
[ "$(cat "$FIX/tmp/scope.txt" | tr '\n' ' ')" = "--all extra " ]; check $? "scope args should reach test-changes.sh: $(cat "$FIX/tmp/scope.txt" 2>/dev/null)"
rm -f "$FIX/bin/test-changes.sh"

echo "--- package tests retain all files, bounded concurrency and failure status"
mkdir -p "$FIX/packages/create-egregore/test"
touch "$FIX/packages/create-egregore/test/first.js" "$FIX/packages/create-egregore/test/second.js"
cat > "$FIX/bin/node-run.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/../tmp/node-args.txt"
exit "${QA_FIXTURE_NODE_EXIT:-0}"
EOF
out=$(bash "$FIX/bin/qa-gate.sh" --only package-tests 2>&1); rc=$?
[ $rc -eq 0 ]; check $? "package success must pass: $out"
expected_args=$'--test\n--test-concurrency=1\npackages/create-egregore/test/first.js\npackages/create-egregore/test/second.js'
[ "$(cat "$FIX/tmp/node-args.txt")" = "$expected_args" ]; check $? "portable runner receives both test files with bounded concurrency"
out=$(QA_FIXTURE_NODE_EXIT=7 bash "$FIX/bin/qa-gate.sh" --only package-tests 2>&1); rc=$?
[ $rc -eq 1 ] && grep -q '^✗ package-tests' <<< "$out"; check $? "package failure must fail the gate: $out"

echo
echo "qa-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
