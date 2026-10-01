#!/usr/bin/env bash
# Privacy & access + personal boundary settings adapters.
# Verifies: composed privacy snapshot honesty, personal read-root add/remove,
# org locked refusal, foreign-instance refusal, and telemetry --json shape.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-settings-priv.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/instance"; FOREIGN="$WORK/foreign"; HOME_FIX="$WORK/home"
mkdir -p "$FIX/memory" "$FIX/bin/lib" "$FOREIGN/inner" "$HOME_FIX/.egregore" "$WORK/readable"

cp "$ROOT/bin/settings.sh" "$FIX/bin/"
cp "$ROOT/bin/telemetry.sh" "$FIX/bin/"
cp -R "$ROOT/egregore_runtime" "$FIX/egregore_runtime"
printf '{"slug":"acme","org_name":"Acme","org_id":"org-acme-1","admins":["admin-user"],"boundary":{"posture":"standard","read":["~/OrgDocs"]}}\n' > "$FIX/egregore.json"
printf '{"onboarding_complete":true,"github_username":"member-user","display_name":"Member","telemetry":true,"telemetry_noticed":true}\n' > "$FIX/.egregore-state.json"
printf '[{"slug":"acme","name":"Acme","path":"%s"},{"slug":"foreign","name":"Foreign","path":"%s"}]\n' "$FIX" "$FOREIGN" > "$HOME_FIX/.egregore/instances.json"

settings() { (cd "$FIX" && HOME="$HOME_FIX" bash bin/settings.sh "$@"); }

SNAP=$(settings privacy)
echo "$SNAP" | jq -e '.access' >/dev/null 2>&1 && pass "privacy snapshot is valid JSON" || fail "privacy snapshot invalid" "$SNAP"
[ "$(echo "$SNAP" | jq -r '.content_protection.per_document_filesystem_acl')" = "not enabled" ] \
  && pass "per-document filesystem ACL honestly reported not enabled" || fail "ACL honesty line wrong"
[ "$(echo "$SNAP" | jq -r '.boundary.posture')" = "standard" ] && pass "posture surfaced from org config" || fail "posture wrong"
grep -qE "api_key|API_KEY|token|Bearer" <<< "$SNAP" && fail "snapshot leaked credential-shaped content" || pass "no credential-shaped content in snapshot"

settings boundary add "$WORK/readable" >/dev/null 2>&1 \
  && [ "$(jq -r '.read[0]' "$FIX/.egregore-boundary.local.json")" = "$(cd "$WORK/readable" && pwd -P)" ] \
  && pass "personal read root added to the boundary-local file" || fail "personal add failed"
settings boundary add "$WORK/readable" >/dev/null 2>&1 \
  && [ "$(jq '.read | length' "$FIX/.egregore-boundary.local.json")" = "1" ] \
  && pass "re-adding an existing root is a no-op" || fail "duplicate root added"

settings boundary add "$FOREIGN/inner" >/dev/null 2>"$WORK/err"
[ $? -ne 0 ] && grep -q "another Egregore instance" "$WORK/err" \
  && pass "a foreign instance path can never become a personal read root" \
  || fail "foreign instance path accepted" "$(cat "$WORK/err")"

settings boundary remove "$WORK/readable" >/dev/null 2>&1 \
  && [ "$(jq '.read | length' "$FIX/.egregore-boundary.local.json")" = "0" ] \
  && pass "personal read root removed" || fail "remove failed"

# ── boundary posture verb (org-wide, locked-aware) ──────────────────────
PSTAT=$(settings posture status --json)
echo "$PSTAT" | jq -e '.posture == "standard" and .locked == false' >/dev/null \
  && pass "posture status --json reports current posture" || fail "posture status wrong" "$PSTAT"
settings posture strict >/dev/null 2>&1 \
  && [ "$(jq -r '.boundary.posture' "$FIX/egregore.json")" = "strict" ] \
  && pass "posture change writes org boundary posture" || fail "posture change failed"
[ "$(jq -r '.boundary.read[0]' "$FIX/egregore.json")" = "~/OrgDocs" ] \
  && pass "posture change preserves other boundary fields" || fail "boundary read roots lost"
settings posture sideways >/dev/null 2>"$WORK/err" \
  && fail "invalid posture accepted" || pass "invalid posture value refused"
settings posture standard >/dev/null 2>&1

jq '.boundary.locked = true' "$FIX/egregore.json" > "$FIX/egregore.json.tmp" && mv "$FIX/egregore.json.tmp" "$FIX/egregore.json"
settings boundary add "$WORK/readable" >/dev/null 2>"$WORK/err"
[ $? -ne 0 ] && grep -q "locked" "$WORK/err" \
  && pass "locked org policy refuses personal expansion" || fail "locked policy bypassed" "$(cat "$WORK/err")"
SNAP=$(settings privacy)
[ "$(echo "$SNAP" | jq -r '.boundary.locked')" = "true" ] && pass "locked state surfaced" || fail "locked state missing"
settings posture open >/dev/null 2>"$WORK/err"
[ $? -ne 0 ] && grep -q "locked" "$WORK/err" \
  && pass "locked org policy refuses posture change" || fail "locked posture bypassed" "$(cat "$WORK/err")"
[ "$(jq -r '.boundary.posture' "$FIX/egregore.json")" = "standard" ] \
  && pass "posture unchanged after locked refusal" || fail "posture mutated while locked"

TEL=$(cd "$FIX" && HOME="$HOME_FIX" EGREGORE_TELEMETRY_DIR="$WORK/tele" bash bin/telemetry.sh status --json)
echo "$TEL" | jq -e '.enabled == true and .buffered_events == 0 and .notice_shown == true' >/dev/null \
  && pass "telemetry --json reports enabled/buffer/notice truthfully" || fail "telemetry json wrong" "$TEL"
grep -q "$WORK" <<< "$TEL" && fail "telemetry json leaked a filesystem path" || pass "telemetry json carries no internal paths"

(cd "$FIX" && HOME="$HOME_FIX" EGREGORE_TELEMETRY_DIR="$WORK/tele" bash bin/telemetry.sh emit "command" '{"command":"test"}' >/dev/null 2>&1)
printf '{"onboarding_complete":true,"github_username":"member-user","telemetry":false}\n' > "$FIX/.egregore-state.json"
(cd "$FIX" && HOME="$HOME_FIX" EGREGORE_TELEMETRY_DIR="$WORK/tele" bash bin/telemetry.sh emit "command" '{"command":"after-off"}' >/dev/null 2>&1)
COUNT=$(grep -c '^{' "$WORK/tele/telemetry.jsonl" 2>/dev/null || echo 0)
[ "$COUNT" = "1" ] && pass "opt-out takes effect immediately: no event buffered after off" \
  || fail "event buffered while telemetry off" "count=$COUNT"
grep -q "after-off" "$WORK/tele/telemetry.jsonl" 2>/dev/null && fail "off-event content present" || pass "no trace of the suppressed event"

# ── durable people removal (tombstones beat resurrected files) ──────────
jq '.boundary.locked = false' "$FIX/egregore.json" > "$FIX/egregore.json.tmp" && mv "$FIX/egregore.json.tmp" "$FIX/egregore.json"
mkdir -p "$FIX/memory/people"
printf '# Ghost\n' > "$FIX/memory/people/ghost.md"
printf '# Keeper\n' > "$FIX/memory/people/keeper.md"
settings people remove ghost >/dev/null 2>&1
[ "$(jq -r '.people_removed[0]' "$FIX/egregore.json")" = "ghost" ] \
  && pass "removal records a durable tombstone in org config" || fail "no tombstone recorded"
printf '# Ghost returns\n' > "$FIX/memory/people/ghost.md"
LIST=$(settings people list)
grep -q "keeper" <<< "$LIST" && ! grep -q "ghost" <<< "$LIST" \
  && pass "a resurrected person file does not resurface a removed member" \
  || fail "removed member resurfaced" "$LIST"
[ "$(settings privacy | jq -r 'has("access")')" = "true" ] || true
settings people add ghost >/dev/null 2>&1
[ "$(jq -r '.people_removed // [] | length' "$FIX/egregore.json")" = "0" ] \
  && pass "re-adding a member clears the tombstone" || fail "tombstone survived re-add"
LIST=$(settings people list)
grep -q "ghost" <<< "$LIST" && pass "re-added member is listed again" || fail "re-added member missing" "$LIST"

# ── alias witness files collapse to one member ──────────────────────────
printf '# Keeper Alias\n\nPerson-ID: github:1\nAlias-Of: keeper.md\n' > "$FIX/memory/people/keeper-alias.md"
LIST=$(settings people list)
grep -q "keeper" <<< "$LIST" && ! grep -q "keeper-alias" <<< "$LIST" \
  && pass "Alias-Of witness files do not appear as extra members" \
  || fail "alias file listed as a member" "$LIST"

# ── runtime cutover gate silences background graph callers ──────────────
cp "$ROOT/bin/graph.sh" "$FIX/bin/"
cp "$ROOT/bin/graph-op.sh" "$FIX/bin/" 2>/dev/null || true
mkdir -p "$FIX/bin/lib" && cp "$ROOT/bin/lib/config.sh" "$FIX/bin/lib/" 2>/dev/null || true
jq '.mode = "connected" | .api_url = "https://graph.invalid.test" | .features.graph_projection = true' "$FIX/egregore.json" > "$FIX/egregore.json.tmp" && mv "$FIX/egregore.json.tmp" "$FIX/egregore.json"
UPROOT="$WORK/upgrade"; FIXMAIN=$(cd "$FIX" && pwd -P)
KEY=$(printf '%s|%s' "org-acme-1" "$FIXMAIN" | shasum -a 256 | cut -c1-16)
mkdir -p "$UPROOT/$KEY"
printf '{"active_version":"0.21.0-runtime-mvp.1","retrieval":"runtime-qmd"}\n' > "$UPROOT/$KEY/active.json"
CURL_LOG="$WORK/graph-curl.log"; : > "$CURL_LOG"
printf '#!/usr/bin/env bash\necho "curl $*" >> "%s"\necho "{}"\n' "$CURL_LOG" > "$WORK/bin-curl"
mkdir -p "$WORK/shim"; mv "$WORK/bin-curl" "$WORK/shim/curl"; chmod +x "$WORK/shim/curl"
OUT=$(cd "$FIX" && HOME="$HOME_FIX" PATH="$WORK/shim:$PATH" EGREGORE_UPGRADE_ROOT="$UPROOT" bash bin/graph.sh query "RETURN 1" 2>/dev/null)
grep -q "runtime_qmd_active" <<< "$OUT" && [ ! -s "$CURL_LOG" ] \
  && pass "background graph call silenced by the cutover gate (no network)" \
  || fail "cutover gate did not silence graph" "$OUT $(cat "$CURL_LOG")"
(cd "$FIX" && HOME="$HOME_FIX" PATH="$WORK/shim:$PATH" EGREGORE_UPGRADE_ROOT="$UPROOT" EGREGORE_GRAPH_EXPLICIT=1 EGREGORE_API_KEY="test-key" bash bin/graph.sh query "RETURN 1" >/dev/null 2>&1) || true
[ -s "$CURL_LOG" ] \
  && pass "an explicit projection request passes the gate" \
  || fail "explicit graph request was blocked by the gate"

# ── telemetry inspect --json shape ──────────────────────────────────────
printf '{"onboarding_complete":true,"github_username":"member-user","telemetry":true}\n' > "$FIX/.egregore-state.json"
(cd "$FIX" && HOME="$HOME_FIX" EGREGORE_TELEMETRY_DIR="$WORK/tele2" bash bin/telemetry.sh emit "command" '{"command":"probe"}' >/dev/null 2>&1)
INSPECT=$(cd "$FIX" && HOME="$HOME_FIX" EGREGORE_TELEMETRY_DIR="$WORK/tele2" bash bin/telemetry.sh inspect 5 --json)
echo "$INSPECT" | jq -e 'type == "array" and (.[0].metrics.command == "probe") and (.[0] | has("occurred_at"))' >/dev/null \
  && pass "inspect --json returns structured events for the browser" || fail "inspect --json wrong" "$INSPECT"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
