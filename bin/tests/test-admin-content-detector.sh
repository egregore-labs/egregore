#!/usr/bin/env bash
# The admin-content detector hook prompts only for this project's own memory:
# a sensitive Markdown file under memory/ (through the symlink or its target)
# gets the hint; the same words under any other "/memory/" path, such as a
# harness's notes in the home directory, under memory/knowledge/canvas/, in a
# file that already carries an admin decision, or in a non-Markdown file, get
# nothing. The hook never exits non-zero.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.claude/hooks/admin-content-detector.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-admin-detector.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/project"
STORE="$WORK/org-memory"            # the memory repository the symlink points at
mkdir -p "$FIX/bin/lib" "$STORE/notes" "$STORE/knowledge/canvas" \
         "$WORK/home/.claude/projects/some-project/memory"
cp "$ROOT/bin/lib/permissions.sh" "$FIX/bin/lib/"
ln -s "$STORE" "$FIX/memory"

printf -- '---\ntopic: fundraising notes\n---\n\nThe seed round and the cap table.\n' > "$STORE/notes/fundraise.md"
printf -- '---\ntopic: canvas\n---\n\nInvestor and valuation topics on the canvas.\n' > "$STORE/knowledge/canvas/plan.md"
printf -- '---\ntopic: decided\nadmin: false\n---\n\nSalary bands, reviewed and public.\n' > "$STORE/notes/decided.md"
printf -- '---\ntopic: fundraising notes\n---\n\nThe seed round and the cap table.\n' > "$STORE/notes/fundraise.txt"
printf -- '---\nname: self-audit-map\n---\n\nAn item raised again after a raise; investor conversations.\n' \
  > "$WORK/home/.claude/projects/some-project/memory/self-audit-map.md"

# run TOOL PATH → stdout of the hook; the exit code lands in $STATUS.
run() {
  local input
  input=$(printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2")
  OUT=$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$FIX" HOME="$WORK/home" bash "$HOOK" 2>"$WORK/err.txt")
  STATUS=$?
}

run Edit "$FIX/memory/notes/fundraise.md"
if [ "$STATUS" -eq 0 ] && grep -q 'admin-content-detector: memory/notes/fundraise.md' <<< "$OUT"; then
  pass "a sensitive file under the project's memory symlink gets the hint"
else fail "no hint for a sensitive memory file" "status $STATUS: $OUT $(cat "$WORK/err.txt")"; fi

run Write "memory/notes/fundraise.md"
if [ "$STATUS" -eq 0 ] && grep -q 'Call AskUserQuestion now' <<< "$OUT"; then
  pass "a relative memory path resolves against the project and gets the hint"
else fail "relative path got no hint" "status $STATUS: $OUT"; fi

run Edit "$STORE/notes/fundraise.md"
if [ "$STATUS" -eq 0 ] && grep -q 'admin-content-detector' <<< "$OUT"; then
  pass "the symlink's physical target counts as the same memory"
else fail "physical memory path got no hint" "status $STATUS: $OUT"; fi

run Edit "$WORK/home/.claude/projects/some-project/memory/self-audit-map.md"
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "a /memory/ path outside the project is not organisational memory: silent"
else fail "an outside /memory/ path was flagged" "status $STATUS: $OUT"; fi

run Edit "$FIX/memory/knowledge/canvas/plan.md"
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "canvas files stay exempt through the resolved path"
else fail "a canvas file was flagged" "status $STATUS: $OUT"; fi

run Edit "$FIX/memory/notes/decided.md"
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "an explicit admin decision is not asked again"
else fail "a decided file was flagged" "status $STATUS: $OUT"; fi

run Edit "$FIX/memory/notes/fundraise.txt"
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "a non-Markdown file is out of scope"
else fail "a .txt file was flagged" "status $STATUS: $OUT"; fi

run Read "$FIX/memory/notes/fundraise.md"
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "only Edit and Write fire the hook"
else fail "a Read fired the hook" "status $STATUS: $OUT"; fi

run Edit "$FIX/memory/notes/missing.md"
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "a missing file is silent"
else fail "a missing file produced output or a non-zero exit" "status $STATUS: $OUT"; fi

rm "$FIX/memory"
run Edit "$STORE/notes/fundraise.md"
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "a project without a memory directory is silent"
else fail "no memory directory still produced output" "status $STATUS: $OUT"; fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
