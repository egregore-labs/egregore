#!/bin/bash
# Fixture-driven tests for .claude/hooks/boundary-check.sh — the two-tier
# consentful boundary (decided 2026-07-08, harvest-2026-07-08-boundary-hook-refinement).
#
# Cases live in tests/fixtures/boundary-check-cases.jsonl. Each case supplies the
# cached boundary JSON verbatim (including legacy old-schema shapes), optional
# .egregore-boundary-consent contents, and the hook's stdin; the runner asserts
# the verdict class:
#   allow  — exit 0
#   hard   — exit 2, "another Egregore instance" (no consent path, ever)
#   soft   — exit 2, "Boundary consent needed" (consent flow named on stderr)
#   locked — exit 2, "boundary is locked" (org lock voids consent + bypass)
#
# All fixture paths live under a fake HOME that never exists, so realpath falls
# through to string comparison and the matrix is deterministic on any machine.
# Runs fully isolated — never touches the real project's boundary cache.
# Usage: bash tests/test-boundary-check.sh
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/.claude/hooks/boundary-check.sh"
FIXTURES="$SCRIPT_DIR/tests/fixtures/boundary-check-cases.jsonl"
FAKE_HOME="/Users/egregore-btest-home"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== boundary-check.sh tests ==="
echo ""

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi
if [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not found at $HOOK"
  exit 1
fi
if [ ! -f "$FIXTURES" ]; then
  echo "FAIL: fixtures not found at $FIXTURES"
  exit 1
fi
if [ -e "$FAKE_HOME" ]; then
  echo "SKIP: $FAKE_HOME exists on this machine — fixture paths would resolve"
  exit 0
fi

# The hook keys its boundary cache on CLAUDE_PROJECT_DIR (must exist on disk).
TEST_PROJECT=$(mktemp -d)
HASH=$(echo -n "$TEST_PROJECT" | md5 2>/dev/null || echo -n "$TEST_PROJECT" | md5sum 2>/dev/null | cut -d' ' -f1)
BOUNDARY_FILE="/tmp/egregore-boundary-${HASH}.json"
trap 'rm -rf "$TEST_PROJECT"; rm -f "$BOUNDARY_FILE"' EXIT

run_case() {
  local case_json="$1" name expect contains input rc stderr_out verdict

  name=$(echo "$case_json" | jq -r '.name')
  expect=$(echo "$case_json" | jq -r '.expect')
  contains=$(echo "$case_json" | jq -r '.stderr_contains // empty')
  input=$(echo "$case_json" | jq -c '.input')

  # Install this case's boundary cache + consent file
  echo "$case_json" | jq -c '.boundary' > "$BOUNDARY_FILE"
  rm -f "$TEST_PROJECT/.egregore-boundary-consent"
  if [ "$(echo "$case_json" | jq -r 'has("consent")')" = "true" ]; then
    echo "$case_json" | jq -r '.consent[]' > "$TEST_PROJECT/.egregore-boundary-consent"
  fi

  stderr_out=$(echo "$input" | HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$TEST_PROJECT" bash "$HOOK" 2>&1 >/dev/null)
  rc=$?

  if [ "$rc" -eq 0 ]; then
    verdict="allow"
  elif [ "$rc" -eq 2 ]; then
    case "$stderr_out" in
      *"another Egregore instance"*) verdict="hard" ;;
      *"boundary is locked"*)        verdict="locked" ;;
      *"Boundary consent needed"*)   verdict="soft" ;;
      *)                             verdict="block-unclassified" ;;
    esac
  else
    verdict="exit-$rc"
  fi

  if [ "$verdict" != "$expect" ]; then
    fail "$name — expected $expect, got $verdict (rc=$rc)"
    [ -n "$stderr_out" ] && echo "        stderr: $(echo "$stderr_out" | head -1)"
    return
  fi

  if [ -n "$contains" ]; then
    case "$stderr_out" in
      *"$contains"*) ;;
      *)
        fail "$name — stderr missing \"$contains\""
        echo "        stderr: $(echo "$stderr_out" | head -1)"
        return
        ;;
    esac
  fi

  pass "$name"
}

while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  run_case "$line"
done < "$FIXTURES"

echo ""
echo "boundary-check: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
