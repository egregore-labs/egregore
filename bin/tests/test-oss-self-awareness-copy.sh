#!/bin/bash
set -euo pipefail

# Test: /checkup mode gating + CLAUDE.md self-awareness/mode sections
# Covers:
#   - CLAUDE.md: Identity & Upstream section, Config Files gating, Mode rewrite
#   - .claude/skills/checkup/SKILL.md: mode detection, connected-mode guards,
#     local-mode rendering box, auto-fix gating

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CLAUDE_MD="$SCRIPT_DIR/CLAUDE.md"
CHECKUP="$SCRIPT_DIR/.claude/skills/checkup/SKILL.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; return 0; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; return 0; }

echo "Testing: OSS self-awareness + connected-mode copy gating"
echo ""

# ─── CLAUDE.md structural invariants ─────────────────────────────────────

echo "CLAUDE.md"

grep -q '^## Identity & Upstream$' "$CLAUDE_MD" \
  && pass "Identity & Upstream section present" \
  || fail "Identity & Upstream section missing"

grep -q 'egregore-labs/egregore' "$CLAUDE_MD" \
  && pass "upstream repo (egregore-labs/egregore) referenced" \
  || fail "upstream repo missing from CLAUDE.md"

grep -q '/update' "$CLAUDE_MD" && grep -q '/contribute' "$CLAUDE_MD" \
  && pass "both /update and /contribute referenced in disambiguation" \
  || fail "/update or /contribute missing from CLAUDE.md"

# Config Files gating — api_url must be marked connected-mode-only
grep -q 'api_url.* connected' "$CLAUDE_MD" \
  && pass "api_url marked connected-mode in Config Files" \
  || fail "api_url not gated in Config Files"

# .env description must distinguish local vs connected
grep -q 'Local mode:.*GITHUB_TOKEN.*only' "$CLAUDE_MD" \
  && pass ".env local-mode description present" \
  || fail ".env local-mode description missing"

# Knowledge Graph + Notifications must be prefixed connected-mode-only
grep -A2 '^## Knowledge Graph$' "$CLAUDE_MD" | grep -q 'Connected mode only' \
  && pass "Knowledge Graph marked Connected mode only" \
  || fail "Knowledge Graph not gated"

grep -A2 '^## Notifications$' "$CLAUDE_MD" | grep -q 'Connected mode only' \
  && pass "Notifications marked Connected mode only" \
  || fail "Notifications not gated"

# Mode section must contain the hard rules
grep -q 'Never tell the user to "ask their admin"' "$CLAUDE_MD" \
  && pass 'Mode section contains "never tell user to ask admin" rule' \
  || fail 'Mode section missing ask-admin rule'

grep -q 'Never surface `api_url`' "$CLAUDE_MD" \
  && pass 'Mode section contains "never surface api_url" rule' \
  || fail 'Mode section missing api_url rule'

# Regression safety: connected-mode paragraph must still instruct graph/notify usage
grep -q 'Neo4j knowledge graph via `bin/graph.sh`' "$CLAUDE_MD" \
  && pass 'connected-mode paragraph still instructs bin/graph.sh usage' \
  || fail 'connected-mode paragraph lost graph.sh instruction'

grep -q 'Telegram notifications via `bin/notify.sh`' "$CLAUDE_MD" \
  && pass 'connected-mode paragraph still instructs bin/notify.sh usage' \
  || fail 'connected-mode paragraph lost notify.sh instruction'

echo ""

# ─── /checkup skill structural invariants ────────────────────────────────

echo ".claude/skills/checkup/SKILL.md"

# Mode detection block must exist and match canonical helper semantics
grep -q "jq -r '.mode // empty' egregore.json" "$CHECKUP" \
  && pass "mode detection uses jq on egregore.json" \
  || fail "mode detection missing"

grep -q '\[ "$MODE" = "local" \] || \[ -z "$API_URL" \]' "$CHECKUP" \
  && pass "mode detection falls back to local when api_url empty" \
  || fail "mode detection fallback logic missing"

# Each connected-only check must be wrapped in an explicit MODE guard.
# Count the guards — we expect exactly 4 (one per check 3b/4/5/6).
GUARD_COUNT=$(grep -c 'if \[ "\$MODE" = "connected" \]; then' "$CHECKUP")
[ "$GUARD_COUNT" -eq 4 ] \
  && pass "all 4 connected-only checks wrapped in MODE guard ($GUARD_COUNT found)" \
  || fail "expected 4 MODE guards, found $GUARD_COUNT"

# Each connected-only check must also have the plain-language skip instruction
grep -c 'In local mode, skip this check entirely' "$CHECKUP" \
  | grep -q '^4$' \
  && pass "all 4 connected-only checks have skip instruction" \
  || fail "missing skip instruction on one or more checks"

# Check 1 must accept both connected and local pass criteria
grep -q 'Pass (connected mode).*api_url' "$CHECKUP" \
  && pass "Check 1 has connected-mode pass criterion" \
  || fail "Check 1 missing connected-mode pass criterion"

grep -q 'Pass (local mode).*api_url.*not required' "$CHECKUP" \
  && pass "Check 1 has local-mode pass criterion" \
  || fail "Check 1 missing local-mode pass criterion"

# Check 2 must distinguish modes for .env requirements
grep -q 'Pass (local mode).*GITHUB_TOKEN.*EGREGORE_API_KEY.*not required' "$CHECKUP" \
  && pass "Check 2 has local-mode pass criterion (only GITHUB_TOKEN)" \
  || fail "Check 2 missing local-mode pass criterion"

# Auto-fix must mark api-key and graph fixes as connected-only
grep -q 'API key mismatch.*connected mode only' "$CHECKUP" \
  && pass "Auto-fix: API key mismatch marked connected-only" \
  || fail "Auto-fix: API key mismatch not gated"

grep -q 'Graph/Telegram down.*connected mode only' "$CHECKUP" \
  && pass "Auto-fix: Graph/Telegram marked connected-only" \
  || fail "Auto-fix: Graph/Telegram not gated"

# Two rendering boxes must exist (connected + local)
grep -c '^\*\*Connected mode format:\*\*$' "$CHECKUP" | grep -q '^1$' \
  && pass "connected-mode rendering format present" \
  || fail "connected-mode rendering format missing"

grep -c '^\*\*Local mode format:\*\*$' "$CHECKUP" | grep -q '^1$' \
  && pass "local-mode rendering format present" \
  || fail "local-mode rendering format missing"

# Extract connected-mode and local-mode rendering sections.
# Connected section: from "**Connected mode format:**" to "**Local mode format:**"
# Local section: from "**Local mode format:**" to "Symbols:"
CONNECTED_BOX=$(awk '/\*\*Connected mode format:\*\*/{flag=1} /\*\*Local mode format:\*\*/{flag=0} flag' "$CHECKUP")
LOCAL_BOX=$(awk '/\*\*Local mode format:\*\*/{flag=1} /^Symbols:/{flag=0} flag' "$CHECKUP")

# Local-mode box must not contain the SERVICES section
echo "$LOCAL_BOX" | grep -q 'SERVICES' \
  && fail "local-mode rendering still contains SERVICES section" "should be omitted" \
  || pass "local-mode rendering correctly omits SERVICES"

# Local-mode box must not contain the Person row
echo "$LOCAL_BOX" | grep -q 'Person —' \
  && fail "local-mode rendering still contains Person row" "should be omitted" \
  || pass "local-mode rendering correctly omits Person row"

# Connected-mode box MUST still contain SERVICES (regression canary)
echo "$CONNECTED_BOX" | grep -q 'SERVICES' \
  && pass "connected-mode rendering preserves SERVICES section" \
  || fail "connected-mode rendering lost SERVICES section" "REGRESSION"

# Connected-mode box MUST still contain the Person row (regression canary)
echo "$CONNECTED_BOX" | grep -q 'Person —' \
  && pass "connected-mode rendering preserves Person row" \
  || fail "connected-mode rendering lost Person row" "REGRESSION"

# Must not contain "ask team admin" text (that was the reporter bug)
grep -qi 'ask.*team admin' "$CHECKUP" \
  && fail "/checkup still says 'ask team admin'" "reporter bug NOT fixed" \
  || pass "/checkup no longer tells users to ask team admin"

echo ""

# ─── Mode detection logic simulation ─────────────────────────────────────

echo "Mode detection simulation (bash logic from Check 1)"

simulate_detect() {
  local mode="$1"
  local api_url="$2"
  local MODE API_URL
  MODE="$mode"
  API_URL="$api_url"
  if [ "$MODE" = "local" ] || [ -z "$API_URL" ]; then
    echo "local"
  else
    echo "connected"
  fi
}

[ "$(simulate_detect "local" "")" = "local" ] \
  && pass "mode=local, api_url empty → local" \
  || fail "mode=local, api_url empty → wrong output"

[ "$(simulate_detect "local" "https://api.example")" = "local" ] \
  && pass "mode=local, api_url set → local (explicit local wins)" \
  || fail "mode=local, api_url set → wrong output"

[ "$(simulate_detect "" "")" = "local" ] \
  && pass "mode empty, api_url empty → local" \
  || fail "mode empty, api_url empty → wrong output"

[ "$(simulate_detect "connected" "https://api.example")" = "connected" ] \
  && pass "mode=connected, api_url set → connected" \
  || fail "mode=connected, api_url set → wrong output"

[ "$(simulate_detect "connected" "")" = "local" ] \
  && pass "mode=connected but api_url empty → local (safe fallback)" \
  || fail "mode=connected, api_url empty → wrong output"

[ "$(simulate_detect "" "https://api.example")" = "connected" ] \
  && pass "mode empty but api_url set → connected (inferred)" \
  || fail "mode empty, api_url set → wrong output"

echo ""

# ─── JSON validity ───────────────────────────────────────────────────────

echo "Repo config"

jq . "$SCRIPT_DIR/egregore.json" > /dev/null 2>&1 \
  && pass "egregore.json is valid JSON" \
  || fail "egregore.json is invalid JSON"

# Confirm this repo is in connected mode (so regression tests exercise that path)
CURRENT_API_URL=$(jq -r '.api_url // empty' "$SCRIPT_DIR/egregore.json")
[ -n "$CURRENT_API_URL" ] \
  && pass "this repo is in connected mode (regression target)" \
  || fail "this repo is NOT in connected mode — regression coverage gap"

# ─── Summary ─────────────────────────────────────────────────────────────

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
