#!/usr/bin/env bash
# The telegram health probe and notify.sh test agree on one output contract.
#
# The consent rewrite turned notify.sh test from prose into JSON. The session
# greeting still grepped for the word "connected" in the deleted sentence, so
# every connected instance showed "telegram ✗" while the bot was answering.
# Nothing failed, because no test read both sides of the contract.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "test-telegram-health-probe"

# Every status the probe can see, and how it must classify each one. In
# connected mode notify.sh passes the API response through, so "ok" is the only
# status it does not emit as a literal — the live-shape check below covers it.
for pair in "ok:healthy:api" "configured:healthy:literal" \
            "offline:unhealthy:literal" "empty:unhealthy:literal"; do
  status="${pair%%:*}"
  rest="${pair#*:}"
  want="${rest%%:*}"
  source="${rest#*:}"

  if [ "$source" = "literal" ] &&
     ! grep -q "\"status\":\"$status\"" "$ROOT/bin/notify.sh"; then
    bad "notify.sh no longer emits status \"$status\" — probe contract is stale"
    continue
  fi

  # Classify the way bin/lib/context.sh does, against real notify.sh output.
  if printf '{"status":"%s"}' "$status" \
    | jq -e '.status == "ok" or .status == "configured"' >/dev/null 2>&1; then
    got="healthy"
  else
    got="unhealthy"
  fi

  if [ "$got" = "$want" ]; then
    ok "status \"$status\" classifies as $want"
  else
    bad "status \"$status\" classifies as $got, expected $want"
  fi
done

# The connected-mode probe passes the API response straight through, so the
# live shape must satisfy the same rule.
if printf '{"status":"ok","bot":"Egregore_clbot"}' \
  | jq -e '.status == "ok" or .status == "configured"' >/dev/null 2>&1; then
  ok "live API test response classifies as healthy"
else
  bad "live API test response no longer classifies as healthy"
fi

# No consumer may go back to substring-matching prose that notify.sh
# does not emit.
STALE="$(
  grep -rn 'notify\.sh"\? test' \
    "$ROOT/bin" "$ROOT/.claude/skills" "$ROOT/.codex" "$ROOT/.pi" 2>/dev/null \
    | grep -i 'grep -q "connected"' || true
)"
if [ -z "$STALE" ]; then
  ok "no consumer greps notify.sh test output for prose"
else
  bad "a consumer still greps notify.sh test output for prose"
  printf '%s\n' "$STALE" >&2
fi

# Claude, Codex, and Pi read health through the same probe.
for target in \
  "bin/lib/context.sh" \
  "packages/create-egregore/runtime/codex/bin/lib/context.sh" \
  "packages/create-egregore/runtime/pi/bin/lib/context.sh"; do
  if grep -q 'status == "ok" or .status == "configured"' "$ROOT/$target"; then
    ok "$target classifies telegram health by status field"
  else
    bad "$target is missing the status-field probe"
  fi
done

# /checkup reports the same verdict the greeting does.
if grep -q '`ok` (connected) or `configured` (local)' \
  "$ROOT/.claude/skills/checkup/SKILL.md"; then
  ok "checkup Check 6 reads the status field"
else
  bad "checkup Check 6 no longer matches the probe"
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
