#!/usr/bin/env bash
# Live MCP identity smoke: this creates a user on the explicitly selected relay.
# Ordinary CI uses the offline endpoint and shell contract tests instead.
# Usage:
#   EGREGORE_MCP_LIVE_SMOKE=1 RELAY=http://localhost:8000 \
#     bash bin/tests/test-mcp-register-roundtrip.sh
# Requires curl and Python 3 only when opted in. No automatic request retries.

# A connector URL is a bearer credential; suppress tracing before handling it.
set +x
set -euo pipefail

if [ "${EGREGORE_MCP_LIVE_SMOKE:-}" != 1 ]; then
  echo 'SKIP: live MCP smoke requires EGREGORE_MCP_LIVE_SMOKE=1 and an explicit RELAY'
  exit 0
fi

stop() { echo "FAIL: $1" >&2; exit 1; }
[ -n "${RELAY:-}" ] || stop 'set RELAY explicitly for the opted-in live MCP smoke'
command -v python3 >/dev/null || stop 'Python 3 is required for the live MCP smoke'
command -v curl >/dev/null || stop 'curl is required for the live MCP smoke'

# Do not print the relay: an invalid URL may itself contain credentials.
if ! python3 -I - "$RELAY" 2>/dev/null <<'PY'
import sys
from urllib.parse import urlsplit
value = sys.argv[1]
url = urlsplit(value)
assert url.scheme in {'http', 'https'} and url.hostname and url.port != 0
assert not url.username and not url.password and not url.query and not url.fragment
assert not any(char.isspace() or ord(char) < 32 or ord(char) == 127 for char in value)
PY
then
  stop 'RELAY must be an HTTP(S) URL without credentials, a query or a fragment'
fi
RELAY="${RELAY%/}"
umask 077
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
RESPONSE="$SCRATCH/response.json"
PASS=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }

request() {
  local expected="$1" label="$2" endpoint="$3" status
  shift 3
  # --disable must be first: user curl configuration must not add tracing,
  # redirects, retries or other destinations. Bodies and curl errors stay private.
  if ! status=$(curl --disable --silent --globoff --connect-timeout 5 --max-time 15 \
      --max-filesize 65536 --proto '=http,https' --retry 0 \
      --output "$RESPONSE" --write-out '%{http_code}' \
      "$@" "$RELAY$endpoint" 2>/dev/null); then
    stop "$label request failed or timed out"
  fi
  case "$status" in
    [0-9][0-9][0-9]) ;;
    *) stop "$label returned an invalid HTTP status" ;;
  esac
  [ "$status" = "$expected" ] || stop "$label returned HTTP $status; expected $expected"
}

UNIQUE="$(python3 -I -c 'import secrets; print(secrets.token_hex(8))')"
TEST_EMAIL="mcp-test-${UNIQUE}@example.com"
TEST_NAME="MCP Test ${UNIQUE}"
REG_BODY="{\"email\":\"${TEST_EMAIL}\",\"name\":\"${TEST_NAME}\"}"

request 200 'register' '/api/mcp/register' -X POST \
  -H 'Content-Type: application/json' --data "$REG_BODY"
if ! TOKEN=$(python3 -I - "$RESPONSE" 2>/dev/null <<'PY'
import json, re, sys
from urllib.parse import urlsplit
with open(sys.argv[1]) as stream:
    data = json.load(stream)
token = data['token']
assert isinstance(token, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,64}', token)
url = urlsplit(data['mcp_url'])
assert url.scheme in {'http', 'https'} and url.hostname
assert not url.username and not url.password and not url.query and not url.fragment
assert url.path == '/mcp/u/' + token
print(token)
PY
); then
  stop 'register returned an invalid token or connector URL'
fi
pass 'register returned a token and matching connector URL'

request 200 'resolve' "/api/mcp/u/$TOKEN"
if ! python3 -I - "$RESPONSE" "$TEST_EMAIL" "$TEST_NAME" 2>/dev/null <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    data = json.load(stream)
assert data['email'] == sys.argv[2] and data['name'] == sys.argv[3]
PY
then
  stop 'resolve did not return the registered identity'
fi
pass 'resolve returned the registered identity'

request 404 'unknown-token resolution' '/api/mcp/u/this-token-does-not-exist-abc123'
pass 'unknown token returns 404'

request 200 'handoff list' "/api/mcp/handoffs?token=$TOKEN&limit=10"
if ! python3 -I - "$RESPONSE" 2>/dev/null <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    data = json.load(stream)
assert type(data['count']) is int and data['count'] == 0 and data['handoffs'] == []
PY
then
  stop 'handoff list was not empty for the new identity'
fi
pass 'new identity has an empty handoff list'

request 404 'unknown-token handoff list' '/api/mcp/handoffs?token=this-token-does-not-exist'
pass 'unknown token cannot list handoffs'

request 422 'invalid-email registration' '/api/mcp/register' -X POST \
  -H 'Content-Type: application/json' --data '{"email":"not-an-email","name":"Test"}'
pass 'invalid email returns 422'

request 422 'empty registration' '/api/mcp/register' -X POST \
  -H 'Content-Type: application/json' --data '{"email":"","name":""}'
pass 'empty identity returns 422'
echo "$PASS passed, 0 failed"
