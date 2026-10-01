#!/usr/bin/env bash
# Control-plane settings sync: a confirmed CLI settings write reaches the
# orgs row immediately (no harness in the loop), session start pulls a
# teammate's write down, a posture relaxation is held for local confirm,
# and a failed push is re-delivered.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-cp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/instance"
CALLS="$WORK/curl.calls"
BODY="$WORK/curl.body"
GET_RESPONSE="$WORK/get-response.json"

mkdir -p "$FIX/bin/lib" "$WORK/shim"
cp "$ROOT/bin/settings.sh" "$FIX/bin/"
cp "$ROOT/bin/lib/settings-drift.sh" "$FIX/bin/lib/"
cp -R "$ROOT/egregore_runtime" "$FIX/egregore_runtime"

# Fake curl: records args + body; GET returns the canned response, PUT a revision.
cat > "$WORK/shim/curl" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
body=""
args=("\$@")
for i in "\${!args[@]}"; do
  [ "\${args[\$i]}" = "--data-binary" ] && body="\${args[\$((i+1))]}"
done
[ -n "\$body" ] && printf '%s' "\$body" > "$BODY"
if printf '%s' "\$*" | grep -q " -X PUT "; then
  printf '{"settings_revision":"rev-put-1"}'
else
  cat "$GET_RESPONSE" 2>/dev/null || printf '{}'
fi
SHIM
chmod +x "$WORK/shim/curl"
export PATH="$WORK/shim:$PATH"

seed() {
  printf '%s\n' "$1" > "$FIX/egregore.json"
  printf '{"github_username":"oz","org_settings_revision":"%s"}\n' "${2:-}" > "$FIX/.egregore-state.json"
  printf 'EGREGORE_API_KEY=test-key\n' > "$FIX/.env"
  : > "$CALLS"; rm -f "$BODY"
}

CONNECTED='{"slug":"acme","org_name":"Acme","mode":"connected","api_url":"https://cp.test","boundary":{"posture":"standard"},"base_branch":"develop","report_key":"not-a-secret-for-cp"}'

# ── 1. a confirmed settings write pushes to the control plane ────────────
seed "$CONNECTED"
(cd "$FIX" && bash bin/settings.sh posture strict >/dev/null 2>&1)
grep -q " -X PUT https://cp.test/api/org/settings" "$CALLS" \
  && pass "settings write PUTs the control plane immediately" || fail "no control-plane PUT" "$(cat "$CALLS" 2>/dev/null)"
jq -e '.settings | keys == ["base_branch","boundary"] or keys == ["boundary","base_branch"]' "$BODY" >/dev/null 2>&1 \
  && pass "payload carries only settings-owned keys" || fail "payload keys wrong" "$(cat "$BODY" 2>/dev/null)"
jq -e '.settings.boundary.posture == "strict" and .updated_by == "oz"' "$BODY" >/dev/null 2>&1 \
  && pass "payload carries the new value and the actor" || fail "payload content wrong" "$(cat "$BODY" 2>/dev/null)"
jq -e '.settings | has("report_key") | not' "$BODY" >/dev/null 2>&1 \
  && pass "non-settings keys never leave the machine" || fail "payload leaked config"
[ "$(jq -r '.org_settings_revision' "$FIX/.egregore-state.json")" = "rev-put-1" ] \
  && pass "applied revision recorded after the push" || fail "revision not recorded"

# ── 2. local mode never calls the network ────────────────────────────────
seed '{"slug":"acme","org_name":"Acme","mode":"local","boundary":{"posture":"standard"}}'
(cd "$FIX" && bash bin/settings.sh posture open >/dev/null 2>&1)
[ ! -s "$CALLS" ] && pass "local mode makes no control-plane call" || fail "local mode called the network" "$(cat "$CALLS")"

drive_pull() {
  (cd "$FIX" && BASE_BRANCH=develop bash -c '
    source bin/lib/settings-drift.sh
    settings_drift_pull
    printf "%s\n%s\n%s\n" "$SETTINGS_CP_SYNCED" "$SETTINGS_POSTURE_HELD" "$SETTINGS_SYNCED_FROM_ORG"
  ')
}

# ── 3. a teammate's write syncs down at session start ────────────────────
seed "$CONNECTED" "rev-old"
printf '{"settings":{"boundary":{"posture":"strict"},"base_branch":"main","people_removed":["ghost"]},"settings_revision":"rev-2"}\n' > "$GET_RESPONSE"
OUT=$(drive_pull)
jq -e '.base_branch == "main" and .boundary.posture == "strict" and .people_removed == ["ghost"]' "$FIX/egregore.json" >/dev/null \
  && pass "server-moved settings applied to the local file" || fail "pull did not apply" "$(cat "$FIX/egregore.json")"
[ "$(jq -r '.org_settings_revision' "$FIX/.egregore-state.json")" = "rev-2" ] \
  && pass "applied revision recorded after the pull" || fail "pull revision not recorded"
[ "$(printf '%s' "$OUT" | sed -n 1p)" = "true" ] && pass "control plane reported in sync" || fail "not marked synced" "$OUT"

# ── 4. a posture relaxation is held for local confirm ────────────────────
seed "$CONNECTED" "rev-old"
printf '{"settings":{"boundary":{"posture":"open"},"base_branch":"main"},"settings_revision":"rev-3"}\n' > "$GET_RESPONSE"
OUT=$(drive_pull)
[ "$(jq -r '.boundary.posture' "$FIX/egregore.json")" = "standard" ] \
  && pass "relaxing posture not auto-applied" || fail "posture relaxed without confirm" "$(cat "$FIX/egregore.json")"
[ "$(jq -r '.base_branch' "$FIX/egregore.json")" = "main" ] \
  && pass "other incoming keys still applied" || fail "other keys lost"
[ "$(printf '%s' "$OUT" | sed -n 2p)" = "open" ] && pass "held posture surfaced for the greeting" || fail "no hold surfaced" "$OUT"
[ "$(jq -r '.org_settings_revision' "$FIX/.egregore-state.json")" = "rev-old" ] \
  && pass "held posture keeps the revision unapplied for retry" || fail "revision consumed despite hold"

# ── 5. an offline write is re-delivered when the server has not moved ────
seed "$CONNECTED" "rev-4"
printf '{"settings":{"boundary":{"posture":"standard"}},"settings_revision":"rev-4"}\n' > "$GET_RESPONSE"
( cd "$FIX" && jq '.boundary.posture = "strict"' egregore.json > e.tmp && mv e.tmp egregore.json )
: > "$CALLS"
OUT=$(drive_pull)
grep -q " -X PUT https://cp.test/api/org/settings" "$CALLS" \
  && pass "failed push re-delivered at session start" || fail "no retry PUT" "$(cat "$CALLS" 2>/dev/null)"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
