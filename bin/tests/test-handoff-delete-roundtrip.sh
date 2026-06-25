#!/usr/bin/env bash
#
# test-handoff-delete-roundtrip.sh
#
# Publishes a handoff under identity A, then exercises every gate on
# DELETE /api/artifacts/handoff/{id}:
#
#   - Wrong identity (B) cannot delete A's capsule (403)
#   - Right identity (A) can delete (200)
#   - Subsequent fetch returns 404 (capsule is gone)
#   - Subsequent delete returns 404 (idempotent-ish — second attempt
#     hits the missing-row path, not a phantom-success path)
#   - Malformed identity returns 422
#   - Missing identity returns 422
#
# Usage:
#   bin/tests/test-handoff-delete-roundtrip.sh
#   RELAY=http://localhost:8000 bin/tests/test-handoff-delete-roundtrip.sh

set -euo pipefail

RELAY="${RELAY:-https://egregore-production-55f2.up.railway.app}"
NOW="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"
CLIENT_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"

AUTHOR_EMAIL="delete-test-author@egregore.xyz"
OTHER_EMAIL="delete-test-not-author@egregore.xyz"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: DELETE /api/artifacts/handoff/{id} against $RELAY"
echo ""

# ── Publish a capsule under AUTHOR_EMAIL ───────────────────────────────────

PAYLOAD=$(python3 - <<PY
import json
print(json.dumps({
    "identity": {"email": "$AUTHOR_EMAIL", "name": "Delete Test Author"},
    "artifact": {
        "@context": "https://egregore.xyz/spec/handoff/v1",
        "version": "1.0",
        "kind": "notification",
        "topic": "delete roundtrip",
        "claim": "Smoke for DELETE endpoint identity gating.",
        "ask": "Internal test; ignore.",
        "created_at": "$NOW",
        "updated_at": "$NOW",
        "author": {"handle": "deletetest", "display": "Delete Test", "harness": "test-script"},
        "audience": {"addressed_to": [], "visible_to": "public", "extendable_by": "anyone"},
        "body": {"prose": "Capsule for DELETE smoke test."},
        "depth": 0,
        "extensions": []
    }
}))
PY
)

PUBLISH_RESP=$(curl -sS -X POST "$RELAY/api/artifacts/handoff" \
  -H "Content-Type: application/json" \
  -H "X-Egregore-Client: $CLIENT_ID" \
  --data "$PAYLOAD")

ID=$(echo "$PUBLISH_RESP" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("id") or d.get("url","").rsplit("/",1)[-1])
')

if [ -z "$ID" ]; then
  fail "publish failed — cannot continue" "$PUBLISH_RESP"
  echo ""
  echo "$PASS passed, $FAIL failed"
  exit 1
fi
pass "published capsule under $AUTHOR_EMAIL: $ID"

DEL_URL="$RELAY/api/artifacts/handoff/$ID"

# ── Negative: wrong identity returns 403 ───────────────────────────────────

STATUS=$(curl -sS -o /tmp/del_resp.json -w "%{http_code}" -X DELETE "$DEL_URL" \
  -H "Content-Type: application/json" \
  --data "{\"identity\":{\"email\":\"$OTHER_EMAIL\"}}")
if [ "$STATUS" = "403" ]; then
  pass "wrong identity returns 403"
else
  fail "wrong identity: expected 403, got $STATUS" "$(cat /tmp/del_resp.json)"
fi

# Capsule should still be alive after the failed delete
STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "$RELAY/h/$ID")
if [ "$STATUS" = "200" ]; then
  pass "capsule still alive after rejected delete attempt"
else
  fail "capsule unexpectedly gone after 403 (status: $STATUS)"
fi

# ── Negative: malformed identity returns 422 ───────────────────────────────

STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$DEL_URL" \
  -H "Content-Type: application/json" \
  --data '{"identity":{"email":"not-an-email"}}')
if [ "$STATUS" = "422" ]; then
  pass "malformed email returns 422"
else
  fail "malformed email: expected 422, got $STATUS"
fi

# ── Negative: missing identity returns 422 ─────────────────────────────────

STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$DEL_URL" \
  -H "Content-Type: application/json" --data '{}')
if [ "$STATUS" = "422" ]; then
  pass "missing identity returns 422"
else
  fail "missing identity: expected 422, got $STATUS"
fi

# ── Happy path: right identity returns 200 ─────────────────────────────────

STATUS=$(curl -sS -o /tmp/del_resp.json -w "%{http_code}" -X DELETE "$DEL_URL" \
  -H "Content-Type: application/json" \
  --data "{\"identity\":{\"email\":\"$AUTHOR_EMAIL\"}}")
if [ "$STATUS" = "200" ]; then
  pass "right identity returns 200 (deleted)"
else
  fail "right identity: expected 200, got $STATUS" "$(cat /tmp/del_resp.json)"
fi

DELETED_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("deleted",""))' < /tmp/del_resp.json)
if [ "$DELETED_ID" = "$ID" ]; then
  pass "response confirms deleted id matches"
else
  fail "response 'deleted' id mismatch: got '$DELETED_ID', want '$ID'"
fi

# ── Post-delete: fetch returns 404 ─────────────────────────────────────────

STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "$RELAY/h/$ID")
if [ "$STATUS" = "404" ]; then
  pass "GET /h/{id} returns 404 after delete"
else
  fail "post-delete fetch: expected 404, got $STATUS"
fi

# ── Post-delete: second delete returns 404 (idempotent-ish) ────────────────

STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$DEL_URL" \
  -H "Content-Type: application/json" \
  --data "{\"identity\":{\"email\":\"$AUTHOR_EMAIL\"}}")
if [ "$STATUS" = "404" ]; then
  pass "second delete returns 404"
else
  fail "second delete: expected 404, got $STATUS"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
