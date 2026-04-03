#!/bin/bash
# Tests for ## Repo State parsing in index-handoff.sh and context.sh
# Verifies: table extraction, edge cases, JSON output validity
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ERRORS=""

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; ERRORS="$ERRORS\n  - $1"; }

# Shared awk pattern (same as in index-handoff.sh and context.sh)
AWK_PATTERN='/^## Repo State/{found=1; next} found && /^#/{exit} found && /^\|[^-]/ && !/^\| Repo/{print}'

# Helper: run the full jq parsing pipeline (index-handoff.sh style)
parse_repo_state() {
  local file="$1"
  local content
  content=$(cat "$file")
  local table
  table=$(echo "$content" | awk "$AWK_PATTERN" || true)
  if [ -z "$table" ]; then
    echo "[]"
    return
  fi
  echo "$table" | while IFS='|' read -r _ R_REPO R_BRANCH R_PR R_BASE _; do
    R_REPO=$(echo "$R_REPO" | xargs 2>/dev/null || true)
    R_BRANCH=$(echo "$R_BRANCH" | xargs 2>/dev/null || true)
    R_PR=$(echo "$R_PR" | xargs 2>/dev/null | sed 's/^#//' | sed 's/—//' || true)
    R_BASE=$(echo "$R_BASE" | xargs 2>/dev/null || true)
    [ -z "$R_REPO" ] && continue
    if [ -n "$R_PR" ] && [ "$R_PR" -eq "$R_PR" ] 2>/dev/null; then
      jq -n --arg repo "$R_REPO" --arg branch "$R_BRANCH" --argjson pr "$R_PR" --arg base "$R_BASE" \
        '{repo:$repo, branch:$branch, pr:$pr, base:$base}'
    else
      jq -n --arg repo "$R_REPO" --arg branch "$R_BRANCH" --arg base "$R_BASE" \
        '{repo:$repo, branch:$branch, pr:null, base:$base}'
    fi
  done | jq -s '.' 2>/dev/null || echo "[]"
}

# Helper: run the printf parsing pipeline (context.sh style)
parse_repo_state_printf() {
  local file="$1"
  local table
  table=$(awk "$AWK_PATTERN" "$file" 2>/dev/null || true)
  if [ -z "$table" ]; then
    echo "[]"
    return
  fi
  echo "$table" | while IFS='|' read -r _ R_REPO R_BRANCH R_PR R_BASE _; do
    R_REPO=$(echo "$R_REPO" | xargs 2>/dev/null || true)
    R_BRANCH=$(echo "$R_BRANCH" | xargs 2>/dev/null || true)
    R_PR=$(echo "$R_PR" | xargs 2>/dev/null | sed 's/^#//' | sed 's/—//' || true)
    R_BASE=$(echo "$R_BASE" | xargs 2>/dev/null || true)
    [ -z "$R_REPO" ] && continue
    if [ -n "$R_PR" ] && [ "$R_PR" -eq "$R_PR" ] 2>/dev/null; then
      printf '{"repo":"%s","branch":"%s","pr":%s,"base":"%s"}\n' "$R_REPO" "$R_BRANCH" "$R_PR" "$R_BASE"
    else
      printf '{"repo":"%s","branch":"%s","pr":null,"base":"%s"}\n' "$R_REPO" "$R_BRANCH" "$R_BASE"
    fi
  done | jq -sc '.' 2>/dev/null || echo "[]"
}

# --- Setup temp dir ---
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

echo "=== Repo State parsing tests ==="

# --- Test 1: Standard two-repo table ---
cat > "$TEST_DIR/standard.md" << 'EOF'
# Handoff: Auth flow

**Date**: 2026-04-03
**Author**: Oz
**To**: Cem

## Entry Points

- Reading: bin/auth.sh

## Repo State

| Repo | Branch | PR | Base |
|------|--------|----|------|
| my-project | dev/oz/auth-flow | #435 | develop |
| my-site | dev/oz/auth-flow | — | main |
EOF

RESULT=$(parse_repo_state "$TEST_DIR/standard.md")
COUNT=$(echo "$RESULT" | jq 'length')
REPO1=$(echo "$RESULT" | jq -r '.[0].repo')
PR1=$(echo "$RESULT" | jq '.[0].pr')
PR2=$(echo "$RESULT" | jq '.[1].pr')
BRANCH2=$(echo "$RESULT" | jq -r '.[1].branch')

[ "$COUNT" -eq 2 ] && pass "standard: 2 repos found" || fail "standard: expected 2, got $COUNT"
[ "$REPO1" = "my-project" ] && pass "standard: first repo name" || fail "standard: repo=$REPO1"
[ "$PR1" = "435" ] && pass "standard: PR number parsed" || fail "standard: pr=$PR1"
[ "$PR2" = "null" ] && pass "standard: em-dash → null" || fail "standard: pr2=$PR2"
[ "$BRANCH2" = "dev/oz/auth-flow" ] && pass "standard: branch with slashes" || fail "standard: branch=$BRANCH2"

# --- Test 2: No Repo State section (backward compat) ---
cat > "$TEST_DIR/old-format.md" << 'EOF'
# Handoff: Legacy

**Date**: 2026-03-01
**Author**: Alice

## Briefing
Old handoff.
EOF

RESULT=$(parse_repo_state "$TEST_DIR/old-format.md")
COUNT=$(echo "$RESULT" | jq 'length')
[ "$COUNT" -eq 0 ] && pass "backward-compat: empty array for old format" || fail "backward-compat: got $COUNT items"

# --- Test 3: Single repo ---
cat > "$TEST_DIR/single.md" << 'EOF'
# Handoff: Single

## Repo State

| Repo | Branch | PR | Base |
|------|--------|----|------|
| egregore | dev/oz/fix | — | develop |
EOF

RESULT=$(parse_repo_state "$TEST_DIR/single.md")
COUNT=$(echo "$RESULT" | jq 'length')
[ "$COUNT" -eq 1 ] && pass "single-repo: 1 repo found" || fail "single-repo: got $COUNT"

# --- Test 4: Section after Repo State ---
cat > "$TEST_DIR/middle.md" << 'EOF'
# Handoff: Middle

## Repo State

| Repo | Branch | PR | Base |
|------|--------|----|------|
| core | dev/oz/x | #10 | develop |

## Some Other Section

This should NOT appear.

| Not | A | Table |
EOF

RESULT=$(parse_repo_state "$TEST_DIR/middle.md")
COUNT=$(echo "$RESULT" | jq 'length')
[ "$COUNT" -eq 1 ] && pass "section-boundary: stops at next heading" || fail "section-boundary: got $COUNT"

# --- Test 5: Empty table (header + separator only) ---
cat > "$TEST_DIR/empty-table.md" << 'EOF'
# Handoff: Empty

## Repo State

| Repo | Branch | PR | Base |
|------|--------|----|------|

## Next
EOF

RESULT=$(parse_repo_state "$TEST_DIR/empty-table.md")
COUNT=$(echo "$RESULT" | jq 'length')
[ "$COUNT" -eq 0 ] && pass "empty-table: no data rows" || fail "empty-table: got $COUNT"

# --- Test 6: Three repos ---
cat > "$TEST_DIR/three.md" << 'EOF'
# Handoff: Multi

## Repo State

| Repo | Branch | PR | Base |
|------|--------|----|------|
| repo-a | dev/oz/feature | #1 | develop |
| repo-b | dev/oz/feature | #2 | main |
| repo-c | dev/oz/feature | — | develop |
EOF

RESULT=$(parse_repo_state "$TEST_DIR/three.md")
COUNT=$(echo "$RESULT" | jq 'length')
[ "$COUNT" -eq 3 ] && pass "three-repos: all 3 found" || fail "three-repos: got $COUNT"

# --- Test 7: context.sh printf pipeline produces same output ---
RESULT_JQ=$(parse_repo_state "$TEST_DIR/standard.md" | jq -Sc '.')
RESULT_PRINTF=$(parse_repo_state_printf "$TEST_DIR/standard.md" | jq -Sc '.')
if [ "$RESULT_JQ" = "$RESULT_PRINTF" ]; then
  pass "pipelines-match: jq and printf produce identical output"
else
  fail "pipelines-match: outputs differ"
  echo "    jq:     $RESULT_JQ"
  echo "    printf: $RESULT_PRINTF"
fi

# --- Test 8: Valid JSON embedding in addressed_rich format ---
AF_REPO_STATE=$(parse_repo_state_printf "$TEST_DIR/standard.md")
RICH="{\"name\":\"test\",\"author\":\"Oz\",\"topic\":\"Auth\",\"date\":\"2026-04-03\",\"repoState\":$AF_REPO_STATE}"
echo "[$RICH]" | jq . > /dev/null 2>&1 && pass "json-embed: valid addressed_rich JSON" || fail "json-embed: invalid JSON"

# --- Test 9: Repo State at end of file (no trailing newline) ---
printf '# Handoff: EOF\n\n## Repo State\n\n| Repo | Branch | PR | Base |\n|------|--------|----|------|\n| eof-repo | dev/x/y | #7 | main |' > "$TEST_DIR/no-newline.md"
RESULT=$(parse_repo_state "$TEST_DIR/no-newline.md")
COUNT=$(echo "$RESULT" | jq 'length')
[ "$COUNT" -eq 1 ] && pass "no-trailing-newline: parsed correctly" || fail "no-trailing-newline: got $COUNT"

# --- Test 10: Script syntax checks ---
bash -n "$SCRIPT_DIR/bin/index-handoff.sh" 2>/dev/null && pass "syntax: index-handoff.sh" || fail "syntax: index-handoff.sh"
bash -n "$SCRIPT_DIR/bin/lib/context.sh" 2>/dev/null && pass "syntax: context.sh" || fail "syntax: context.sh"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failures:$ERRORS"
  exit 1
fi
echo '{"passed":'"$PASS"',"failed":'"$FAIL"'}'
