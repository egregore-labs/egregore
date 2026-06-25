#!/usr/bin/env bash
#
# test-handoff-executable-roundtrip.sh
#
# Publishes a kind=executable capsule against the relay, fetches it
# back, and asserts the executable_spec survived the round-trip
# without mutation. Catches:
#
#   - Relay-side validator drift from the Zod schema
#   - Storage / fetch JSON mutations
#   - Field stripping (e.g. an egress sanitizer that goes too far)
#
# Usage:
#   bin/tests/test-handoff-executable-roundtrip.sh                 # against prod Railway API
#   RELAY=http://localhost:8000 bin/tests/test-handoff-executable-roundtrip.sh
#
# Note on URLs: egregore.xyz fronts the rendered HTML pages (served via
# Netlify proxy) but the POST endpoints live on the direct Railway URL.
# We use the Railway URL by default because POSTs + 30x redirects drop
# the request body in Netlify's path.
#
# Requires: curl, python3 (for JSON shape assertions).

set -euo pipefail

RELAY="${RELAY:-https://egregore-production-55f2.up.railway.app}"
NOW="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"
CLIENT_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: executable-handoff round-trip against $RELAY"
echo ""

# ── Build the test capsule ─────────────────────────────────────────────────

PAYLOAD=$(python3 - <<PY
import json
print(json.dumps({
    "identity": {
        "email": "roundtrip-test@egregore.xyz",
        "name":  "Round-Trip Test"
    },
    "artifact": {
        "@context":   "https://egregore.xyz/spec/handoff/v1",
        "version":    "1.0",
        "kind":       "executable",
        "topic":      "round-trip test",
        "claim":      "Smoke test: verifies executable_spec survives publish + fetch.",
        "ask":        "Internal test; ignore.",
        "created_at": "$NOW",
        "updated_at": "$NOW",
        "author": {
            "handle":  "roundtriptest",
            "display": "Round-Trip Test",
            "harness": "test-script"
        },
        "audience": {
            "addressed_to":  [],
            "visible_to":    "public",
            "extendable_by": "anyone"
        },
        "parents": [],
        "body": {
            "prose": "Smoke-test capsule. Safe to ignore.",
            "executable_spec": {
                "intake": [
                    {"id": "name", "prompt": "Your name?", "type": "text"},
                    {"id": "tone", "prompt": "Tone?", "type": "choice", "options": ["minimal", "playful"]}
                ],
                "action": "Build a thing from the answers.",
                "output": {"target": "inline_render"},
                "branding": {
                    "display_name":      "Round-Trip Test",
                    "designer_url":      "https://egregore.xyz",
                    "attribution_style": "footer"
                }
            }
        },
        "references": [],
        "repo_state": [],
        "depth":      "shallow",
        "deep_context": None,
        "receiver_instructions": None,
        "extensions": []
    }
}))
PY
)

# ── POST: publish ──────────────────────────────────────────────────────────

PUBLISH_RESP=$(curl -sS -X POST "$RELAY/api/artifacts/handoff" \
  -H "Content-Type: application/json" \
  -H "X-Egregore-Client: $CLIENT_ID" \
  --data "$PAYLOAD")

if echo "$PUBLISH_RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("url","").startswith("https://egregore.xyz/h/") else 1)' 2>/dev/null; then
  pass "publish accepted executable capsule"
else
  fail "publish failed" "$PUBLISH_RESP"
  echo ""
  echo "$FAIL failed, $PASS passed"
  exit 1
fi

ARTIFACT_ID=$(echo "$PUBLISH_RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or d["url"].rsplit("/", 1)[-1])')
URL=$(echo "$PUBLISH_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
echo "  → published: $URL"

# ── GET: fetch back the canonical JSON ─────────────────────────────────────

FETCHED=$(curl -sS -H "Accept: application/json" "$RELAY/api/artifacts/handoff/$ARTIFACT_ID")

# kind survived
if echo "$FETCHED" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("kind") == "executable" else 1)'; then
  pass "kind=executable survived round-trip"
else
  fail "kind did not survive round-trip"
fi

# executable_spec present
HAS_SPEC=$(echo "$FETCHED" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if isinstance(d.get("body",{}).get("executable_spec"), dict) else "no")')
if [ "$HAS_SPEC" = "yes" ]; then
  pass "body.executable_spec survived round-trip"
else
  fail "body.executable_spec missing on fetch — relay or storage stripped it"
fi

# intake survived with correct length
INTAKE_LEN=$(echo "$FETCHED" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("body",{}).get("executable_spec",{}).get("intake",[])))')
if [ "$INTAKE_LEN" = "2" ]; then
  pass "intake array survived (2 questions)"
else
  fail "intake length wrong — got $INTAKE_LEN, expected 2"
fi

# choice question kept its options
CHOICE_OPTS=$(echo "$FETCHED" | python3 -c '
import json, sys
d = json.load(sys.stdin)
intake = d.get("body",{}).get("executable_spec",{}).get("intake",[])
choices = [q for q in intake if q.get("type") == "choice"]
print(",".join(choices[0].get("options", [])) if choices else "")
')
if [ "$CHOICE_OPTS" = "minimal,playful" ]; then
  pass "choice question options survived"
else
  fail "choice options wrong — got '$CHOICE_OPTS'"
fi

# output target survived
TARGET=$(echo "$FETCHED" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body",{}).get("executable_spec",{}).get("output",{}).get("target",""))')
if [ "$TARGET" = "inline_render" ]; then
  pass "output.target survived (inline_render)"
else
  fail "output.target wrong — got '$TARGET'"
fi

# branding survived
BRAND=$(echo "$FETCHED" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body",{}).get("executable_spec",{}).get("branding",{}).get("display_name",""))')
if [ "$BRAND" = "Round-Trip Test" ]; then
  pass "branding.display_name survived"
else
  fail "branding.display_name wrong — got '$BRAND'"
fi

# action preserved as written
ACTION=$(echo "$FETCHED" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body",{}).get("executable_spec",{}).get("action",""))')
if [ "$ACTION" = "Build a thing from the answers." ]; then
  pass "action string survived verbatim"
else
  fail "action wrong — got '$ACTION'"
fi

# ── Validation gate: invalid output target should be rejected on POST ─────

INVALID_PAYLOAD=$(echo "$PAYLOAD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["artifact"]["body"]["executable_spec"]["output"]["target"] = "egregore_hosted"
print(json.dumps(d))
')

REJECT_RESP=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$RELAY/api/artifacts/handoff" \
  -H "Content-Type: application/json" \
  -H "X-Egregore-Client: $CLIENT_ID" \
  --data "$INVALID_PAYLOAD")

if [ "$REJECT_RESP" = "422" ]; then
  pass "relay rejects egregore_hosted output target (v1 enum is strict)"
elif [ "$REJECT_RESP" = "200" ]; then
  fail "relay validator is OUT OF DATE" "The new _validate_handoff_v1 from this PR is not deployed yet — kind=executable with target=egregore_hosted was accepted (expected 422). Deploy api/main.py changes and re-run."
else
  fail "expected 422 for egregore_hosted target, got $REJECT_RESP"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
