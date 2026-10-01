#!/usr/bin/env bash
set -euo pipefail
# Live: reads this instance's live memory. Opt in with EGREGORE_LIVE_INTEGRATION=1; otherwise report a skip.
if [ "${EGREGORE_LIVE_INTEGRATION:-}" != 1 ]; then echo "SKIP: reads this instance's live memory; set EGREGORE_LIVE_INTEGRATION=1 to run"; exit 0; fi

# Test: Local-mode authority for /todo, /issue, /add skills
# Covers: .claude/skills/todo/SKILL.md, .claude/skills/issue/SKILL.md, .claude/skills/add/SKILL.md

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: local-mode fallback consistency"
echo ""

# ============================================================
# 1. Mode detection pattern consistency
# ============================================================
echo "1. Mode detection pattern"

if grep -q 'jq -r.*\.mode.*egregore\.json' "$SCRIPT_DIR/.claude/skills/add/SKILL.md"; then
  fail "add still branches canonical state by mode" "Add must use one Runtime ingest lifecycle"
else
  pass "add has no mode-specific canonical-state branch"
fi
if grep -q 'jq -r.*\.mode.*egregore\.json' "$SCRIPT_DIR/.claude/skills/issue/SKILL.md"; then
  fail "issue still branches canonical state by mode" "Issue must use one Runtime lifecycle"
else
  pass "issue has no mode-specific canonical-state branch"
fi
if grep -q 'jq -r.*\.mode.*egregore\.json' "$SCRIPT_DIR/.claude/skills/todo/SKILL.md"; then
  fail "todo still branches storage by mode" "Todo must use one canonical Markdown lifecycle"
else
  pass "todo has no mode-specific storage branch"
fi

# ============================================================
# 2. /todo: graph is never the lifecycle authority
# ============================================================
echo ""
echo "2. /todo: Graph-only rule consistency"

TODO_FILE="$SCRIPT_DIR/.claude/skills/todo/SKILL.md"
if grep -Eq '^[[:space:]]*bash[[:space:]]+bin/(graph|graph-op|graph-batch)\.sh' "$TODO_FILE"; then
  fail "todo contains an executable graph command" "Use bin/todo.sh in every mode"
else
  pass "todo has no executable graph lifecycle path"
fi

# ============================================================
# 3. /issue: Path consistency across modes
# ============================================================
echo ""
echo "3. /issue: Path consistency"

ISSUE_FILE="$SCRIPT_DIR/.claude/skills/issue/SKILL.md"

# Check for bare memory/issues/ that is NOT memory/knowledge/issues/
# Use negative lookbehind via grep -P, or simple two-pass approach
BARE_REFS=0
while IFS= read -r line; do
  if ! grep -q "memory/knowledge/issues/" <<< "$line"; then
    BARE_REFS=$((BARE_REFS + 1))
  fi
done < <(grep "memory/issues/" "$ISSUE_FILE" 2>/dev/null || true)
if [ "$BARE_REFS" -eq 0 ]; then
  pass "All issue paths use memory/knowledge/issues/"
else
  fail "Path mismatch: $BARE_REFS reference(s) to memory/issues/ without knowledge/ prefix" \
    "All issue file operations must use memory/knowledge/issues/"
fi

# ============================================================
# 4. /issue: Runtime adapter covers all routes in every mode
# ============================================================
echo ""
echo "4. /issue: Cross-mode Runtime route coverage"

for ROUTE in "create" "list" "show" "close" "search"; do
  if grep -q "bin/issue.sh $ROUTE" "$ISSUE_FILE"; then
    pass "Runtime issue adapter covers $ROUTE"
  else
    fail "Runtime issue adapter missing $ROUTE" \
      "The same bin/issue.sh route must serve Local and Connected modes"
  fi
done

if grep -Eq '^[[:space:]]*bash[[:space:]]+bin/(graph|graph-op|graph-batch)\.sh' "$ISSUE_FILE"; then
  fail "issue contains an executable graph command" "Graph cannot own issue state"
else
  pass "issue has no executable graph lifecycle path"
fi

# ============================================================
# 5. /todo: cross-mode canonical route coverage
# ============================================================
echo ""
echo "5. /todo: Canonical route coverage"

for ROUTE in "Add" "List" "Done" "cancel" "Check-in"; do
  if grep -qi "${ROUTE}" "$TODO_FILE"; then
    pass "Canonical todo flow covers $ROUTE"
  else
    fail "Canonical todo flow missing $ROUTE"
  fi
done

if grep -Fq '| `all` |' "$TODO_FILE"; then
  pass "Canonical todo flow covers all-status route"
else
  fail "Canonical todo flow missing all-status route"
fi

# ============================================================
# 6. /todo: Runtime schema has required fields
# ============================================================
echo ""
echo "6. /todo: Runtime field completeness"

TODO_RUNTIME="$SCRIPT_DIR/egregore_runtime/todos.py"
for FIELD in id text status priority created completed quest source; do
  if grep -Fq "\"$FIELD\"" "$TODO_RUNTIME"; then
    pass "Runtime todo schema includes '$FIELD'"
  else
    fail "Runtime todo schema missing '$FIELD'"
  fi
done

# ============================================================
# 7. /add: graph is never the lifecycle authority
# ============================================================
echo ""
echo "7. /add: Graph-free Runtime adapter"

ADD_FILE="$SCRIPT_DIR/.claude/skills/add/SKILL.md"
if grep -Eq '^[[:space:]]*bash[[:space:]]+bin/(graph|graph-op|graph-batch)\.sh' "$ADD_FILE"; then
  fail "add contains an executable graph command" "Graph cannot own source admission"
else
  pass "add has no executable graph lifecycle path"
fi

# ============================================================
# 8. Quest directory exists
# ============================================================
echo ""
echo "8. Memory directory existence"

if [ -d "$SCRIPT_DIR/memory/quests" ]; then
  QUEST_COUNT=$(find "$SCRIPT_DIR/memory/quests" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  pass "memory/quests/ exists ($QUEST_COUNT files)"
else
  fail "memory/quests/ does not exist" \
    "Local-mode quest matching depends on this directory"
fi

if [ -d "$SCRIPT_DIR/memory/knowledge/issues" ]; then
  pass "memory/knowledge/issues/ exists"
else
  fail "memory/knowledge/issues/ does not exist" \
    "Local-mode issue list/close/search depends on this directory"
fi

if [ -d "$SCRIPT_DIR/memory/artifacts" ]; then
  pass "memory/artifacts/ exists"
else
  fail "memory/artifacts/ does not exist" \
    "Local-mode artifact storage depends on this directory"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "─────────────────────────────"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
