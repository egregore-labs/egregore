#!/usr/bin/env bash
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
grep -A3 '^## Optional Knowledge Graph Projection$' "$CLAUDE_MD" | grep 'Connected mode only' >/dev/null \
  && pass "Knowledge Graph marked Connected mode only" \
  || fail "Knowledge Graph not gated"

sed -n '/^## Notifications$/,/^## /p' "$CLAUDE_MD" | grep 'Connected mode only' >/dev/null \
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
grep -q 'Use `bin/graph.sh` for unsupported Neo4j queries' "$CLAUDE_MD" \
  && pass 'graph section still instructs bin/graph.sh usage' \
  || fail 'graph section lost graph.sh instruction'

grep -q '`bin/graph.sh` and `bin/notify.sh` route through the API gateway' "$CLAUDE_MD" \
  && pass 'connected-mode paragraph still routes graph.sh and notify.sh through the gateway' \
  || fail 'connected-mode paragraph lost the gateway routing instruction'

echo ""

# ─── /checkup skill structural invariants ────────────────────────────────

echo ".claude/skills/checkup/SKILL.md"

# Mode detection block must exist and match canonical helper semantics
grep -Fq 'bash bin/config-get.sh mode' "$CHECKUP" \
  && pass "mode detection uses the canonical config reader" \
  || fail "mode detection missing"

grep -Fq 'If it prints `local`, skip Connected' "$CHECKUP" \
  && grep -Fq 'if it prints `connected`, include them after the local checks.' "$CHECKUP" \
  && pass "mode prose gates Connected checks on the printed value" \
  || fail "mode prose does not gate on the printed local/connected value"

# Runtime health must enter through the typed Egregore Runtime surface.
grep -q 'egregore_runtime.harness_cli status --json' "$CHECKUP" \
  && pass "checkup reads typed Runtime health" \
  || fail "checkup bypasses typed Runtime health"

for field in canonical_state_ready runtime_state runtime_pid runtime_endpoint collection index_path; do
  grep -q "$field" "$CHECKUP" \
    && pass "Runtime health includes $field" \
    || fail "Runtime health omits $field"
done

# QMD is owned behind Runtime; no direct lifecycle or status commands belong here.
grep -Eq '^[[:space:]]*(qmd|npx .*qmd)[[:space:]]' "$CHECKUP" \
  && fail "checkup calls QMD directly" \
  || pass "checkup keeps QMD behind Runtime"

grep -q 'bash bin/search.sh start' "$CHECKUP" \
  && pass "checkup repairs through Runtime lifecycle adapter" \
  || fail "checkup missing Runtime lifecycle repair"

# Connected integrations are explicit and do not define canonical readiness.
for marker in 'CONNECTED INTEGRATIONS' 'bash bin/graph-projection.sh verify --enable' 'bash bin/notification.sh status' 'local memory ready'; do
  grep -q "$marker" "$CHECKUP" \
    && pass "connected contract includes $marker" \
    || fail "connected contract missing $marker"
done

grep -q 'Skip this batch completely in local mode' "$CHECKUP" \
  && pass "local mode skips Connected probes" \
  || fail "Connected probes are not explicitly local-gated"

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
