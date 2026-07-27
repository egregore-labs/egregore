#!/usr/bin/env bash
set -euo pipefail

# Test: session-start.sh auto-heal recovers when state write is dropped.
# Covers: bin/session-start.sh self-heal block (lines 86-105) and the
#         Onboarded: completion witness contract from
#         .claude/skills/onboarding/SKILL.md.
#
# Method: extracts the auto-heal block as a self-contained function and
#         exercises it against simulated dropped-state scenarios in a
#         temp directory. Does NOT run session-start.sh in full (would
#         require live identity, git remote, jq/curl side effects).

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

# --- Self-contained auto-heal function (mirrors session-start.sh:86-105) ---
# DISPLAY_NAME_STATE is normally set by identity.sh before this block runs.
# The test passes it explicitly to mirror the production caller contract.
auto_heal() {
  local SCRIPT_DIR="$1"
  local AUTHOR="$2"
  local DISPLAY_NAME_STATE="${3:-}"
  local STATE_FILE="$SCRIPT_DIR/.egregore-state.json"
  local ONBOARDING_COMPLETE="false"
  [ -f "$STATE_FILE" ] && ONBOARDING_COMPLETE=$(jq -r '.onboarding_complete // false' "$STATE_FILE" 2>/dev/null || echo "true")

  if [ "$ONBOARDING_COMPLETE" != "true" ] && [ -n "$AUTHOR" ]; then
    local PEOPLE_FILE="$SCRIPT_DIR/memory/people/${AUTHOR}.md"
    local WITNESSED="false"
    if [ -f "$PEOPLE_FILE" ]; then
      if grep -q '^Onboarded:' "$PEOPLE_FILE" 2>/dev/null; then
        WITNESSED="true"
      elif head -1 "$PEOPLE_FILE" 2>/dev/null | grep -q '^# '; then
        WITNESSED="true"
      fi
    fi
    if [ "$WITNESSED" != "true" ] && [ -n "$DISPLAY_NAME_STATE" ] && [ -f "$SCRIPT_DIR/egregore.md" ]; then
      sed -n '/^## Members/,/^## /p' "$SCRIPT_DIR/egregore.md" 2>/dev/null \
        | grep -qx "### ${DISPLAY_NAME_STATE}" && WITNESSED="true"
    fi
    if [ "$WITNESSED" = "true" ] && [ -f "$STATE_FILE" ]; then
      jq '.onboarding_complete = true | .onboarding.phase = "complete"' "$STATE_FILE" > "$STATE_FILE.tmp" \
        && mv "$STATE_FILE.tmp" "$STATE_FILE"
      ONBOARDING_COMPLETE="true"
    fi
  fi
  echo "$ONBOARDING_COMPLETE"
}

# Helper: extract display_name from a fixture's state file (mirrors what
# identity.sh would have populated into DISPLAY_NAME_STATE).
state_display_name() {
  jq -r '.display_name // empty' "$1/.egregore-state.json" 2>/dev/null
}

setup_fixture() {
  local DIR="$1"
  rm -rf "$DIR" && mkdir -p "$DIR/memory/people"
  cat > "$DIR/.egregore-state.json" <<'EOF'
{
  "github_username": "testuser",
  "display_name": "Test User",
  "onboarding_complete": false,
  "onboarding": {"phase": "complete"}
}
EOF
}

echo "Testing: session-start.sh auto-heal — Onboarded witness + Members fallback"
echo ""

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Test 1: Primary witness (Onboarded: line in person file) ---
FIX="$TMP/case1"
setup_fixture "$FIX"
cat > "$FIX/memory/people/testuser.md" <<'EOF'
# Test User
GitHub: testuser
Joined: 2026-04-13
Onboarded: 2026-04-13T14:08:02Z
EOF
RESULT=$(auto_heal "$FIX" "testuser" "$(state_display_name "$FIX")")
[ "$RESULT" = "true" ] && pass "primary witness: heals when Onboarded: line present" \
  || fail "primary witness: did not heal" "got '$RESULT'"
HEALED=$(jq -r '.onboarding_complete' "$FIX/.egregore-state.json" 2>/dev/null)
[ "$HEALED" = "true" ] && pass "primary witness: state file rewritten" \
  || fail "primary witness: state still says incomplete" "got '$HEALED'"

# --- Test 2: Invite stub (YAML frontmatter, no H1) — must NOT heal ---
FIX="$TMP/case2"
setup_fixture "$FIX"
cat > "$FIX/memory/people/testuser.md" <<'EOF'
---
name: testuser
github: testuser
invited_by: oz
joined: 2026-04-13
---
EOF
RESULT=$(auto_heal "$FIX" "testuser" "$(state_display_name "$FIX")")
[ "$RESULT" != "true" ] && pass "invite stub: does NOT heal (no Onboarded:, no H1 — only YAML frontmatter)" \
  || fail "invite stub: incorrectly healed" "stub should not be witness"

# --- Test 2b: Back-compat — pre-PR-544 person file with H1 but no Onboarded: ---
FIX="$TMP/case2b"
setup_fixture "$FIX"
cat > "$FIX/memory/people/testuser.md" <<'EOF'
# Test User
GitHub: testuser
Role: engineering
Focus: building
Work style: async
Joined: 2026-03-12
EOF
RESULT=$(auto_heal "$FIX" "testuser" "$(state_display_name "$FIX")")
[ "$RESULT" = "true" ] && pass "back-compat witness: heals pre-PR-544 user (H1 header, no Onboarded:)" \
  || fail "back-compat witness: did not heal existing user" "got '$RESULT'"

# --- Test 2c: Back-compat — rich profile doc format (cem.md style) ---
FIX="$TMP/case2c"
setup_fixture "$FIX"
cat > "$FIX/memory/people/testuser.md" <<'EOF'
# Test User

## Role
**CEO & Founder** at Some Company

## Focus Areas
- Stuff
- Things
EOF
RESULT=$(auto_heal "$FIX" "testuser" "$(state_display_name "$FIX")")
[ "$RESULT" = "true" ] && pass "back-compat witness: heals rich profile doc (no key-value fields at all)" \
  || fail "back-compat witness: did not heal rich profile" "got '$RESULT'"

# --- Test 3: Fallback witness (egregore.md Members section) ---
FIX="$TMP/case3"
setup_fixture "$FIX"
cat > "$FIX/egregore.md" <<'EOF'
# Egregore

## Identity
Some text.

## Members

<!-- Auto-updated as people join via onboarding -->

### Test User
Joined 2026-04-13.

## Collaboration
More text.
EOF
RESULT=$(auto_heal "$FIX" "testuser" "$(state_display_name "$FIX")")
[ "$RESULT" = "true" ] && pass "fallback witness: heals when display_name in Members section" \
  || fail "fallback witness: did not heal" "got '$RESULT'"

# --- Test 4: Display name in OTHER section (false-positive guard) ---
FIX="$TMP/case4"
setup_fixture "$FIX"
cat > "$FIX/egregore.md" <<'EOF'
# Egregore

## Identity
Some text.

## Members

<!-- empty members -->

## Collaboration

### Test User
Some unrelated subsection that happens to share a name.
EOF
RESULT=$(auto_heal "$FIX" "testuser" "$(state_display_name "$FIX")")
[ "$RESULT" != "true" ] && pass "fallback witness: does NOT match ### outside Members section" \
  || fail "fallback witness: false-positive bleed" "matched ### Test User outside Members"

# --- Test 5: Both witnesses absent — does not heal ---
FIX="$TMP/case5"
setup_fixture "$FIX"
RESULT=$(auto_heal "$FIX" "testuser" "$(state_display_name "$FIX")")
[ "$RESULT" != "true" ] && pass "no witness: stays incomplete (force re-onboarding)" \
  || fail "no witness: incorrectly healed" "should require re-onboarding"

# --- Test 6: AUTHOR empty (corrupted identity) ---
FIX="$TMP/case6"
setup_fixture "$FIX"
cat > "$FIX/memory/people/testuser.md" <<'EOF'
# Test User
GitHub: testuser
Onboarded: 2026-04-13T14:08:02Z
EOF
RESULT=$(auto_heal "$FIX" "")
[ "$RESULT" != "true" ] && pass "empty AUTHOR: skips heal (no path to check)" \
  || fail "empty AUTHOR: should not have healed" "got '$RESULT'"

# --- Test 7: State already complete — no-op ---
FIX="$TMP/case7"
mkdir -p "$FIX/memory/people"
cat > "$FIX/.egregore-state.json" <<'EOF'
{"github_username": "testuser", "onboarding_complete": true}
EOF
RESULT=$(auto_heal "$FIX" "testuser" "$(state_display_name "$FIX")")
[ "$RESULT" = "true" ] && pass "already complete: returns true unchanged" \
  || fail "already complete: returned '$RESULT'"

# --- Test 8: display_name missing from state — fallback skipped gracefully ---
FIX="$TMP/case8"
mkdir -p "$FIX/memory/people"
cat > "$FIX/.egregore-state.json" <<'EOF'
{"github_username": "testuser", "onboarding_complete": false}
EOF
cat > "$FIX/egregore.md" <<'EOF'
## Members

### Test User
EOF
RESULT=$(auto_heal "$FIX" "testuser" "$(state_display_name "$FIX")")
[ "$RESULT" != "true" ] && pass "no display_name: fallback safely skipped" \
  || fail "no display_name: fallback incorrectly fired" "got '$RESULT'"

# --- Test 9: Display name with multi-word value (matches verbatim) ---
FIX="$TMP/case9"
setup_fixture "$FIX"
jq '.display_name = "Oz Vurgun"' "$FIX/.egregore-state.json" > "$FIX/.egregore-state.tmp" && mv "$FIX/.egregore-state.tmp" "$FIX/.egregore-state.json"
cat > "$FIX/egregore.md" <<'EOF'
## Members

### Oz Vurgun
Joined.

## Collaboration
EOF
RESULT=$(auto_heal "$FIX" "testuser" "$(state_display_name "$FIX")")
[ "$RESULT" = "true" ] && pass "multi-word display name: matches verbatim" \
  || fail "multi-word display name: did not match" "got '$RESULT'"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
