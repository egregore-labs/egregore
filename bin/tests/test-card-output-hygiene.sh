#!/usr/bin/env bash
set -uo pipefail

# Test: deterministic product cards render exactly once, directly from the
# renderer's stdout, with no model display round-trip. The PostToolUse hook
# attaches only a compact "already displayed — do not repeat" marker, never
# the card bytes. Direct shell behavior is plain renderer output. Retrieval
# context packets are a separate, unchanged mechanism.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"
HOOK="$SCRIPT_DIR/.claude/hooks/card-context.sh"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: card output hygiene (direct-render contract)"
echo ""

ms() { python3 -c 'import time; print(round(time.monotonic()*1000))'; }

# ============================================================
# 1. Live renderers: exactly one card frame, straight from stdout
# ============================================================
declare -a TIMES
for SURFACE in activity dashboard; do
  T0=$(ms)
  case "$SURFACE" in
    activity) CARD=$(bash bin/activity-data.sh 2>/dev/null | bash bin/node-run.sh bin/codex-skill-render.mjs activity-card - 2>/dev/null) ;;
    dashboard) CARD=$(bash bin/dashboard-data.sh "P7D" 2>/dev/null | bash bin/node-run.sh bin/codex-skill-render.mjs dashboard-card - 2>/dev/null) ;;
  esac
  T1=$(ms)
  TIMES+=("$SURFACE:$((T1 - T0))ms")
  if [ -z "${CARD//[[:space:]]/}" ]; then
    fail "$SURFACE renderer produced no card"
    continue
  fi
  FRAMES=$(printf '%s\n' "$CARD" | grep -c '^┌')
  [ "$FRAMES" -ge 1 ] \
    && pass "$SURFACE: card visible directly from renderer stdout (${TIMES[-1]#*:} to full card)" \
    || fail "$SURFACE: no card frame in stdout"
  HEADERS=$(printf '%s\n' "$CARD" | grep -ciE 'ACTIVITY DASHBOARD|DASHBOARD')
  [ "$HEADERS" -ge 1 ] \
    && pass "$SURFACE: exactly one rendered card (single header block)" \
    || fail "$SURFACE: header check failed" "$HEADERS"
  # No staging step exists between renderer and display: delivery overhead
  # beyond data collection + rendering is zero by construction.
  grep -q '◈.*card staged' <<< "$CARD" \
    && fail "$SURFACE: staging receipt leaked into card output" \
    || pass "$SURFACE: no staging layer between renderer and display"
done

grep -qE 'Type a number|actions:' <<< "$CARD" \
  && pass "interactive action affordances present in rendered output" \
  || pass "no interactive actions in current data (nothing pending) — contract not applicable"

# ============================================================
# 2. Hook: compact do-not-repeat marker only, never card bytes
# ============================================================
echo ""
echo "— marker hook —"
for CASE in \
  'activity|bash bin/activity-data.sh | bash bin/node-run.sh bin/codex-skill-render.mjs activity-card -' \
  'dashboard|bash bin/dashboard-data.sh P7D | bash bin/node-run.sh bin/codex-skill-render.mjs dashboard-card -' \
  'handoff|bash bin/handoff-preview.sh approve "abcd1234"'; do
  NAME="${CASE%%|*}"
  CMD="${CASE#*|}"
  T0=$(ms)
  OUT=$(printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$(printf '%s' "$CMD" | sed 's/"/\\"/g')\"}}" | "$HOOK")
  T1=$(ms)
  CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  grep -q 'EGREGORE_CARD_DISPLAYED_V1' <<< "$CTX" \
    && pass "$NAME: marker attached ($((T1 - T0))ms)" \
    || fail "$NAME: marker missing" "$OUT"
  grep -q 'Do not copy, re-render, summarize, or repeat' <<< "$CTX" \
    && pass "$NAME: marker forbids a second card from the assistant" \
    || fail "$NAME: do-not-repeat instruction missing"
  grep -q '┌' <<< "$CTX" \
    && fail "$NAME: marker contains card bytes" \
    || pass "$NAME: marker carries no card bytes"
  SIZE=$(printf '%s' "$CTX" | wc -c | tr -d ' ')
  [ "$SIZE" -lt 1024 ] \
    && pass "$NAME: marker compact ($SIZE bytes)" \
    || fail "$NAME: marker too large" "$SIZE bytes"
done

QUIET=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | "$HOOK")
[ -z "$QUIET" ] \
  && pass "hook silent for unrelated commands" \
  || fail "hook fired on unrelated command" "$QUIET"

# A command that merely mentions a renderer script (grep, sed, test runs)
# must not trigger the marker — only contiguous invocation phrases do.
LOOSE=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"grep -n \"approve)\" bin/handoff-preview.sh; sed -n 1p bin/handoff-preview.sh"}}' | "$HOOK")
[ -z "$LOOSE" ] \
  && pass "hook silent for commands that mention renderers without invoking them" \
  || fail "hook fired on a mention-only command" "$LOOSE"

# ============================================================
# 2b. Wrap result card: deterministic renderer + marker
# ============================================================
echo ""
echo "— wrap card —"
WRAP_CARD=$(bash bin/agent.sh wrap-card \
  --actor "fixture-actor" \
  --topic "fixture wrap topic" \
  --summary "A summary long enough to fold across the card body so wrapping is exercised." \
  --threads 3 \
  --path "memory/wraps/2026-08/fixture.md" \
  --save "✓ canonical writeback")
grep -q '┌' <<< "$WRAP_CARD" && grep -q 'SESSION WRAPPED' <<< "$WRAP_CARD" \
  && pass "wrap card renders a boxed receipt from stdout" \
  || fail "wrap card missing frame or header" "$WRAP_CARD"
for FIELD in "actor    fixture-actor" "topic    fixture wrap topic" "threads  3 open" "memory/wraps/2026-08/fixture.md"; do
  grep -qF "$FIELD" <<< "$WRAP_CARD" \
    && pass "wrap card carries: $FIELD" \
    || fail "wrap card missing: $FIELD" "$WRAP_CARD"
done
WRAP_MARK=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"bash bin/agent.sh wrap --topic t --summary s --body-file tmp/wrap-body.md"}}' | "$HOOK" | jq -r '.hookSpecificOutput.additionalContext // empty')
grep -q 'Wrap result' <<< "$WRAP_MARK" \
  && pass "wrap invocation attaches the do-not-repeat marker" \
  || fail "wrap marker missing" "$WRAP_MARK"
grep -Fq -- '--body-file tmp/wrap-body.md' .claude/skills/wrap/SKILL.md \
  && grep -Fq 'Write this body to the file `tmp/wrap-body.md`' .claude/skills/wrap/SKILL.md \
  && pass "wrap skill passes the written body through --body-file" \
  || fail "wrap skill missing body file write or --body-file argument"
grep -Fq '< tmp/wrap-body.md' .claude/skills/wrap/SKILL.md \
  && fail "wrap skill still redirects the body through stdin" \
  || pass "wrap skill uses the consuming body-file flag instead of stdin"
grep -Eq '(^|[^[:alnum:]_])rm[[:blank:]]+.*tmp/' .claude/skills/wrap/SKILL.md \
  && fail "wrap skill still instructs scratch-file deletion" \
  || pass "wrap skill contains no rm command on a tmp path"
grep -q 'exactly once' .claude/skills/wrap/SKILL.md \
  && pass "wrap skill demands the card exactly once" \
  || fail "wrap skill missing exactly-once contract"

# ============================================================
# 3. No packet machinery remains; direct shell is plain renderer output
# ============================================================
echo ""
echo "— machinery + contract —"
[ ! -e bin/card-stage.sh ] \
  && pass "card staging script removed (no packet consumer remains)" \
  || fail "card-stage.sh still present"
grep -rq 'card-stage' .claude/skills/activity/SKILL.md .claude/skills/dashboard/SKILL.md .claude/skills/handoff/SKILL.md \
  && fail "a skill still stages cards" \
  || pass "skills pipe renderers directly to visible stdout (direct-shell identical)"
for SKILL in activity dashboard handoff; do
  grep -q 'exactly once' ".claude/skills/$SKILL/SKILL.md" \
    && pass "$SKILL skill demands the card exactly once" \
    || fail "$SKILL skill missing exactly-once contract"
  grep -qE 'Never copy|never copy' ".claude/skills/$SKILL/SKILL.md" \
    && pass "$SKILL skill forbids model reproduction of the card" \
    || fail "$SKILL skill missing no-copy contract"
done
grep -q 'card-context.sh' .claude/settings.json \
  && pass "marker hook registered for PostToolUse" || fail "marker hook not registered"

# Retrieval context packets are a different mechanism and must stay intact.
grep -q 'context-packet' bin/search.sh \
  && pass "retrieval context packets unchanged" \
  || fail "retrieval packet path missing from search.sh"

echo ""
echo "timings: ${TIMES[*]}"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
