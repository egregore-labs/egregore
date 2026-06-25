#!/usr/bin/env bash
#
# test-mcp-register-roundtrip.sh
#
# Exercises the MCP token-URL identity endpoints end to end against a
# live relay:
#
#   1. POST /api/mcp/register       — mints a token from {email, name}
#   2. GET  /api/mcp/u/<token>      — resolves token to {email, name}
#   3. GET  /api/mcp/u/<bad-token>  — returns 404
#   4. GET  /api/mcp/handoffs       — token-gated list (empty for fresh user)
#   5. POST /api/mcp/register       — rejects invalid email (422)
#
# Usage:
#   bin/tests/test-mcp-register-roundtrip.sh             # against prod
#   RELAY=http://localhost:8000 bin/tests/test-mcp-register-roundtrip.sh
#
# Requires: curl, python3.

set -euo pipefail

RELAY="${RELAY:-https://egregore-production-55f2.up.railway.app}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: MCP token-URL identity endpoints against $RELAY"
echo ""

UNIQUE="$(openssl rand -hex 4)"
TEST_EMAIL="mcp-test-${UNIQUE}@egregore.xyz"
TEST_NAME="MCP Test ${UNIQUE}"

# ── 1. Register ────────────────────────────────────────────────────────────

REG_BODY="{\"email\":\"${TEST_EMAIL}\",\"name\":\"${TEST_NAME}\"}"
REG_RESP=$(curl -sS -X POST "$RELAY/api/mcp/register" \
  -H "Content-Type: application/json" \
  --data "$REG_BODY")

# Parse out the token and mcp_url
TOKEN=$(echo "$REG_RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token",""))' 2>/dev/null || echo "")
MCP_URL=$(echo "$REG_RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("mcp_url",""))' 2>/dev/null || echo "")

if [ -n "$TOKEN" ] && [ -n "$MCP_URL" ]; then
  pass "POST /api/mcp/register returned token + mcp_url"
  echo "    token: ${TOKEN:0:8}…  mcp_url: $MCP_URL"
else
  fail "register failed" "$REG_RESP"
  echo ""
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

# ── 2. Resolve the token ──────────────────────────────────────────────────

RES_RESP=$(curl -sS "$RELAY/api/mcp/u/$TOKEN")
RES_EMAIL=$(echo "$RES_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("email",""))' 2>/dev/null || echo "")
RES_NAME=$(echo "$RES_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || echo "")

if [ "$RES_EMAIL" = "$TEST_EMAIL" ] && [ "$RES_NAME" = "$TEST_NAME" ]; then
  pass "GET /api/mcp/u/<token> resolves to the registered identity"
else
  fail "resolve mismatch" "got email='$RES_EMAIL' name='$RES_NAME' (expected '$TEST_EMAIL' / '$TEST_NAME')"
fi

# ── 3. Unknown token returns 404 ──────────────────────────────────────────

BAD_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "$RELAY/api/mcp/u/this-token-does-not-exist-abc123")
if [ "$BAD_STATUS" = "404" ]; then
  pass "GET /api/mcp/u/<bad-token> returns 404"
else
  fail "expected 404 for unknown token, got $BAD_STATUS"
fi

# ── 4. List handoffs — should be empty for fresh user ─────────────────────

LIST_RESP=$(curl -sS "$RELAY/api/mcp/handoffs?token=$TOKEN&limit=10")
LIST_COUNT=$(echo "$LIST_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count","?"))' 2>/dev/null || echo "?")

if [ "$LIST_COUNT" = "0" ]; then
  pass "GET /api/mcp/handoffs returns empty list for fresh user"
else
  fail "expected count=0 for new user, got $LIST_COUNT" "$LIST_RESP"
fi

LIST_BAD_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" "$RELAY/api/mcp/handoffs?token=this-token-does-not-exist")
if [ "$LIST_BAD_STATUS" = "404" ]; then
  pass "GET /api/mcp/handoffs?token=<bad> returns 404"
else
  fail "expected 404 for unknown token on /handoffs, got $LIST_BAD_STATUS"
fi

# ── 5. Invalid email rejected on registration ─────────────────────────────

BAD_REG_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$RELAY/api/mcp/register" \
  -H "Content-Type: application/json" \
  --data '{"email":"not-an-email","name":"Test"}')
if [ "$BAD_REG_STATUS" = "422" ]; then
  pass "POST /api/mcp/register rejects invalid email with 422"
else
  fail "expected 422 for invalid email, got $BAD_REG_STATUS"
fi

EMPTY_REG_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$RELAY/api/mcp/register" \
  -H "Content-Type: application/json" \
  --data '{"email":"","name":""}')
if [ "$EMPTY_REG_STATUS" = "422" ]; then
  pass "POST /api/mcp/register rejects empty email + name with 422"
else
  fail "expected 422 for empty fields, got $EMPTY_REG_STATUS"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
