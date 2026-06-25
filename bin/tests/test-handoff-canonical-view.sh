#!/usr/bin/env bash
#
# test-handoff-canonical-view.sh
#
# Verifies the /h/{id} canonical view path serves executable-aware
# receiver hints + visible banner.
#
# Day 4.1 patched /h/{id}/run/{platform} only — tool-aware harnesses
# (Claude Code, Codex, Cursor) hit that path. But consumer chat
# products (Claude.ai, ChatGPT) just GET /h/{id}, and that path was
# serving generic receiver hints without anti-meta posture. Day 4.2
# closes the gap. This smoke pins it against prod.
#
# Assertions:
#   - GET /h/{id} JSON for executable: _receiver_hints carry anti-meta
#   - GET /h/{id} JSON for non-executable: NO anti-meta clause
#   - GET /h/{id} HTML for executable: visible "Runnable capsule" banner
#     within the first 1KB after <body>
#   - GET /h/{id} HTML for non-executable: NO banner
#   - /api/artifacts/handoff/{id} for executable: same anti-meta hints
#
# Usage:
#   bin/tests/test-handoff-canonical-view.sh
#   RELAY=http://localhost:8000 bin/tests/test-handoff-canonical-view.sh

set -euo pipefail

RELAY="${RELAY:-https://egregore-production-55f2.up.railway.app}"
NOW="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())')"
CLIENT_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: /h/{id} canonical view executable routing against $RELAY"
echo ""

# ── Publish one executable + one non-executable capsule ──────────────────

publish_capsule() {
  local kind="$1"
  local extra_body="$2"
  local payload
  payload=$(python3 - <<PY
import json
extra = $extra_body
body = {"prose": "canonical-view smoke"}
body.update(extra)
print(json.dumps({
    "identity": {"email": "canview-smoke@egregore.xyz", "name": "Canview Smoke"},
    "artifact": {
        "@context": "https://egregore.xyz/spec/handoff/v1",
        "version": "1.0",
        "kind": "$kind",
        "topic": "canonical-view smoke ($kind)",
        "claim": "Day 4.2 smoke.",
        "ask": None,
        "created_at": "$NOW",
        "updated_at": "$NOW",
        "author": {"handle": "canviewsmoke", "display": "Canview Smoke", "harness": "test-script"},
        "audience": {"addressed_to": [], "visible_to": "public", "extendable_by": "anyone"},
        "body": body,
        "depth": 0,
        "extensions": []
    }
}))
PY
)
  curl -sS -X POST "$RELAY/api/artifacts/handoff" \
    -H "Content-Type: application/json" \
    -H "X-Egregore-Client: $CLIENT_ID" \
    --data "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("id") or d.get("url","").rsplit("/",1)[-1])
'
}

EXEC_BODY='{"executable_spec":{"intake":[{"id":"name","prompt":"Your name?","type":"text"}],"action":"Greet the user.","output":{"target":"inline_render"}}}'

EXEC_ID=$(publish_capsule "executable" "$EXEC_BODY")
[ -z "$EXEC_ID" ] && { fail "publish executable failed"; echo ""; echo "$PASS passed, $FAIL failed"; exit 1; }
pass "published executable: $EXEC_ID"

NOTIF_ID=$(publish_capsule "notification" "{}")
[ -z "$NOTIF_ID" ] && { fail "publish notification failed"; echo ""; echo "$PASS passed, $FAIL failed"; exit 1; }
pass "published notification: $NOTIF_ID"

# ── JSON path: /h/{id} with Accept: application/json ─────────────────────

EXEC_JSON=$(curl -sS -H "Accept: application/json" "$RELAY/h/$EXEC_ID")
INSTR=$(echo "$EXEC_JSON" | python3 -c '
import json, sys
print(json.load(sys.stdin).get("_receiver_hints",{}).get("instructions",""))
')
if echo "$INSTR" | grep -q "Skip any introduction"; then
  pass "GET /h/{id} JSON (executable): anti-meta posture present"
else
  fail "GET /h/{id} JSON (executable): anti-meta missing — Day 4.2 regression"
fi

INTENT=$(echo "$EXEC_JSON" | python3 -c '
import json, sys
print(json.load(sys.stdin).get("_receiver_hints",{}).get("intent",""))
')
if [ "$INTENT" = "run" ]; then
  pass "GET /h/{id} JSON (executable): intent=run (routed through executable hints)"
else
  fail "GET /h/{id} JSON (executable): intent='$INTENT' (expected 'run')"
fi

NOTIF_JSON=$(curl -sS -H "Accept: application/json" "$RELAY/h/$NOTIF_ID")
NOTIF_INSTR=$(echo "$NOTIF_JSON" | python3 -c '
import json, sys
print(json.load(sys.stdin).get("_receiver_hints",{}).get("instructions",""))
')
if echo "$NOTIF_INSTR" | grep -q "Skip any introduction"; then
  fail "GET /h/{id} JSON (notification): anti-meta leaked onto non-executable"
else
  pass "GET /h/{id} JSON (notification): no anti-meta leak (correct)"
fi

# ── HTML path: /h/{id} with Accept: text/html ────────────────────────────

EXEC_HTML=$(curl -sS -H "Accept: text/html" "$RELAY/h/$EXEC_ID")
if echo "$EXEC_HTML" | grep -q "Runnable capsule"; then
  pass "GET /h/{id} HTML (executable): visible banner present"
else
  fail "GET /h/{id} HTML (executable): banner missing"
fi
if echo "$EXEC_HTML" | grep -q "data-egregore-banner"; then
  pass "GET /h/{id} HTML (executable): banner has machine-readable marker"
else
  fail "GET /h/{id} HTML (executable): data-egregore-banner attr missing"
fi

# Position check — banner must be in the first 1KB after <body>
POS_OK=$(echo "$EXEC_HTML" | python3 -c '
import sys, re
html = sys.stdin.read()
m = re.search(r"<body\b[^>]*>", html)
if not m:
    print("no")
elif "Runnable capsule" in html[m.end():m.end()+1000]:
    print("yes")
else:
    print("no")
')
if [ "$POS_OK" = "yes" ]; then
  pass "GET /h/{id} HTML (executable): banner is at top of <body>"
else
  fail "GET /h/{id} HTML (executable): banner not near top of <body> — fetchers may truncate"
fi

NOTIF_HTML=$(curl -sS -H "Accept: text/html" "$RELAY/h/$NOTIF_ID")
if echo "$NOTIF_HTML" | grep -q "Runnable capsule"; then
  fail "GET /h/{id} HTML (notification): banner leaked onto non-executable"
else
  pass "GET /h/{id} HTML (notification): no banner (correct)"
fi

# ── /api/artifacts/handoff/{id} (programmatic JSON sibling) ──────────────

API_EXEC_JSON=$(curl -sS "$RELAY/api/artifacts/handoff/$EXEC_ID")
API_INSTR=$(echo "$API_EXEC_JSON" | python3 -c '
import json, sys
print(json.load(sys.stdin).get("_receiver_hints",{}).get("instructions",""))
')
if echo "$API_INSTR" | grep -q "Skip any introduction"; then
  pass "GET /api/artifacts/handoff/{id} (executable): anti-meta present"
else
  fail "GET /api/artifacts/handoff/{id} (executable): anti-meta missing"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
