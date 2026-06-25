#!/usr/bin/env bash
#
# test-handoff-run-platform.sh
#
# Publishes a kind=executable capsule, then fetches it via every
# /h/{id}/run/{platform} endpoint and asserts the per-platform
# _receiver_hints carry the right tuning + audience clause.
#
# Catches:
#   - Platform set drift (new platform added to spec but not route)
#   - Receiver-hint regressions (e.g. claude-ai losing the artefact-panel
#     mention; chatgpt losing canvas)
#   - Audience-aware mismatch clause silently dropped
#   - Non-executable capsules accidentally being served by the run route
#
# Usage:
#   bin/tests/test-handoff-run-platform.sh
#   RELAY=http://localhost:8000 bin/tests/test-handoff-run-platform.sh
#
# Requires: curl, python3.

set -euo pipefail

RELAY="${RELAY:-https://egregore-production-55f2.up.railway.app}"
NOW="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"
CLIENT_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: /h/{id}/run/{platform} against $RELAY"
echo ""

# ── Build a public-template executable capsule (no addressee) ──────────────

PUBLIC_PAYLOAD=$(python3 - <<PY
import json
print(json.dumps({
    "identity": {"email": "run-test@egregore.xyz", "name": "Run Test"},
    "artifact": {
        "@context": "https://egregore.xyz/spec/handoff/v1",
        "version": "1.0",
        "kind": "executable",
        "topic": "run-endpoint test (public)",
        "claim": "Smoke: /run/{platform} returns platform-tuned hints.",
        "ask": "Internal test; ignore.",
        "created_at": "$NOW",
        "updated_at": "$NOW",
        "author": {
            "handle": "runtest",
            "display": "Run Test",
            "harness": "test-script"
        },
        "audience": {
            "addressed_to": [],
            "visible_to": "public",
            "extendable_by": "anyone"
        },
        "body": {
            "prose": "Run-endpoint smoke capsule.",
            "executable_spec": {
                "intake": [{
                    "id": "name", "prompt": "Your name?", "type": "text"
                }],
                "action": "Greet the user.",
                "output": {"target": "inline_render"}
            }
        },
        "depth": 0,
        "extensions": []
    }
}))
PY
)

PUBLISH_RESP=$(curl -sS -X POST "$RELAY/api/artifacts/handoff" \
  -H "Content-Type: application/json" \
  -H "X-Egregore-Client: $CLIENT_ID" \
  --data "$PUBLIC_PAYLOAD")

PUBLIC_ID=$(echo "$PUBLISH_RESP" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("id") or d.get("url","").rsplit("/",1)[-1])
')

if [ -z "$PUBLIC_ID" ]; then
  fail "publish failed for public capsule" "$PUBLISH_RESP"
  echo ""
  echo "$PASS passed, $FAIL failed"
  exit 1
fi
pass "published public-template executable capsule: $PUBLIC_ID"

# ── Per-platform assertions (public template) ──────────────────────────────

check_platform() {
  local platform="$1"
  local must_contain="$2"
  local artifact_id="$3"
  local audience_phrase="$4"

  local resp
  resp=$(curl -sS "$RELAY/h/$artifact_id/run/$platform")

  local hd
  hd=$(echo "$resp" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("_receiver_hints",{}).get("harness_detected",""))
')
  if [ "$hd" != "$platform" ]; then
    fail "$platform: harness_detected wrong (got '$hd')"
    return
  fi

  local intent
  intent=$(echo "$resp" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("_receiver_hints",{}).get("intent",""))
')
  if [ "$intent" != "run" ]; then
    fail "$platform: intent missing or wrong (got '$intent')"
    return
  fi

  local instr
  instr=$(echo "$resp" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("_receiver_hints",{}).get("instructions",""))
')

  if ! echo "$instr" | grep -q "$must_contain"; then
    fail "$platform: instructions missing tuned phrase ('$must_contain')"
    return
  fi

  if ! echo "$instr" | grep -q "$audience_phrase"; then
    fail "$platform: audience clause missing ('$audience_phrase')"
    return
  fi

  pass "$platform: hints carry '$must_contain' + correct audience clause"
}

check_platform "claude-code" "AskUserQuestion"     "$PUBLIC_ID" "public template"
check_platform "claude-ai"   "artefact"            "$PUBLIC_ID" "public template"
check_platform "chatgpt"     "canvas"              "$PUBLIC_ID" "public template"
check_platform "codex"       "tool-use"            "$PUBLIC_ID" "public template"
check_platform "cursor"      "tool-use"            "$PUBLIC_ID" "public template"
check_platform "generic"     "plain-text"          "$PUBLIC_ID" "public template"

# Day 4.1 — every platform carries the anti-meta-question posture.
# Caught in oz's manual 5-utterance test: receivers were asking
# "is this real or testing?" before running intake, breaking the
# product/co-design asymmetry.
check_anti_meta() {
  local platform="$1"
  local artifact_id="$2"
  local instr
  instr=$(curl -sS "$RELAY/h/$artifact_id/run/$platform" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("_receiver_hints",{}).get("instructions",""))
')
  # Day 4.5: friendly-outcome receiver-hint clause must be present
  # (A/B-validated winner). Day 4.1/4.4 wording (verbatim, Quality bar,
  # Run it autonomously) was rewritten because it tied for last in the
  # A/B — must NOT be present.
  if ! echo "$instr" | grep -q "Skip any introduction"; then
    fail "$platform: missing Day-4.5 marker 'Skip any introduction'"
    return
  fi
  if ! echo "$instr" | grep -q "first intake question, nothing else"; then
    fail "$platform: missing 'first intake question, nothing else' guidance"
    return
  fi
  if ! echo "$instr" | grep -q "implement them, don'''t recite them"; then
    fail "$platform: missing 'implement them, don'''t recite them' clause"
    return
  fi
  for banned in "EXECUTE THE SPEC VERBATIM" "Run it autonomously" "Quality bar" "Posture:"; do
    if echo "$instr" | grep -q "$banned"; then
      fail "$platform: banned phrase '$banned' reintroduced — A/B-validated Day 4.5 wording is target"
      return
    fi
  done
  pass "$platform: carries Day-4.5 wording, no banned wording"
}

for p in claude-code claude-ai chatgpt codex cursor generic; do
  check_anti_meta "$p" "$PUBLIC_ID"
done

# ── Personal capsule: addressed_to non-empty triggers mismatch clause ─────

PERSONAL_PAYLOAD=$(echo "$PUBLIC_PAYLOAD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["artifact"]["topic"] = "run-endpoint test (personal)"
d["artifact"]["audience"]["addressed_to"] = [
    {"email": "addressee@example.com", "display": "Addressed Person"}
]
print(json.dumps(d))
')

PUBLISH_RESP=$(curl -sS -X POST "$RELAY/api/artifacts/handoff" \
  -H "Content-Type: application/json" \
  -H "X-Egregore-Client: $CLIENT_ID" \
  --data "$PERSONAL_PAYLOAD")

PERSONAL_ID=$(echo "$PUBLISH_RESP" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("id") or d.get("url","").rsplit("/",1)[-1])
')

if [ -z "$PERSONAL_ID" ]; then
  fail "publish failed for personal capsule" "$PUBLISH_RESP"
else
  pass "published personal executable capsule: $PERSONAL_ID"
  check_platform "claude-code" "AskUserQuestion" "$PERSONAL_ID" "mismatch"
fi

# ── Negative paths ────────────────────────────────────────────────────────

UNKNOWN_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "$RELAY/h/$PUBLIC_ID/run/notaplatform")
if [ "$UNKNOWN_STATUS" = "404" ]; then
  pass "unknown platform returns 404"
else
  fail "unknown platform: expected 404, got $UNKNOWN_STATUS"
fi

MISSING_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "$RELAY/h/this-id-does-not-exist/run/claude-code")
if [ "$MISSING_STATUS" = "404" ]; then
  pass "missing artifact returns 404"
else
  fail "missing artifact: expected 404, got $MISSING_STATUS"
fi

# Non-executable kind: publish a notification + verify /run rejects it
NONEXEC_PAYLOAD=$(python3 - <<PY
import json
print(json.dumps({
    "identity": {"email": "run-test@egregore.xyz", "name": "Run Test"},
    "artifact": {
        "@context": "https://egregore.xyz/spec/handoff/v1",
        "version": "1.0",
        "kind": "notification",
        "topic": "run-endpoint test (non-executable)",
        "claim": "This is not executable.",
        "ask": "Should not be servable via /run.",
        "created_at": "$NOW",
        "updated_at": "$NOW",
        "author": {"handle": "runtest", "display": "Run Test", "harness": "test-script"},
        "audience": {"addressed_to": [], "visible_to": "public", "extendable_by": "anyone"},
        "body": {"prose": "Non-executable capsule."},
        "depth": 0,
        "extensions": []
    }
}))
PY
)

NONEXEC_RESP=$(curl -sS -X POST "$RELAY/api/artifacts/handoff" \
  -H "Content-Type: application/json" \
  -H "X-Egregore-Client: $CLIENT_ID" \
  --data "$NONEXEC_PAYLOAD")

NONEXEC_ID=$(echo "$NONEXEC_RESP" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("id") or d.get("url","").rsplit("/",1)[-1])
')

if [ -n "$NONEXEC_ID" ]; then
  WRONG_KIND_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "$RELAY/h/$NONEXEC_ID/run/claude-code")
  if [ "$WRONG_KIND_STATUS" = "422" ]; then
    pass "non-executable capsule returns 422 from /run/"
  else
    fail "non-executable capsule: expected 422, got $WRONG_KIND_STATUS"
  fi
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
