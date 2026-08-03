#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPD="$(mktemp -d -t handoff-lifecycle-test-XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT
PASS=0

pass() {
  PASS=$((PASS + 1))
  echo "ok $PASS - $1"
}

fail() {
  echo "not ok $((PASS + 1)) - $1" >&2
  exit 1
}

mkdir -p "$TMPD/bin"
cp "$ROOT/bin/handoff-lifecycle.sh" "$TMPD/bin/handoff-lifecycle.sh"

cat > "$TMPD/egregore.json" <<'JSON'
{"mode":"connected"}
JSON

cat > "$TMPD/bin/graph.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == *"UNWIND \$closeIds"* ]]; then
  echo '{"fields":["closedCount","expiredCount"],"values":[[1,2]]}'
else
  cat <<'JSON'
{"fields":["id","topic","author","recipient","date","status","intent","ageDays","recipientCount","implementationId","implementationStatus"],"values":[
  ["legacy","Old unclassified","cem","oz","2026-06-01","pending","unclassified",40,1,null,null],
  ["fyi","Read this","cem","oz","2026-07-01","pending","fyi",20,1,null,null],
  ["implemented","Do the work","cem","oz","2026-07-20","read","action",3,1,"impl-1","wrapped"],
  ["feedback","Review this","cem","oz","2026-07-14","pending","feedback",9,1,null,null],
  ["multi","Joint decision","cem","oz","2026-07-01","read","action",20,2,"impl-2","wrapped"],
  ["multi","Joint decision","cem","renc","2026-07-01","read","action",20,2,null,null]
]}
JSON
fi
SH
chmod +x "$TMPD/bin/graph.sh" "$TMPD/bin/handoff-lifecycle.sh"

PLAN="$(bash "$TMPD/bin/handoff-lifecycle.sh" scan --days 14)"
if jq -e '
  .schema == "egregore-handoff-lifecycle-plan/v1"
  and .counts.open_rows == 6
  and .counts.unique_handoffs == 5
  and .counts.duplicate_recipient_rows == 1
  and .counts.close == 1
  and .counts.expire == 2
  and .counts.review == 1
  and .counts.nudge == 1
  and .counts.unclassified == 1
' <<<"$PLAN" >/dev/null; then
  pass "scan classifies evidence-backed and review-only transitions"
else
  echo "$PLAN" >&2
  fail "scan classification"
fi

MANAGED="$(bash "$TMPD/bin/handoff-lifecycle.sh" scan --days 14 --managed-only)"
if jq -e '.managed_only == true' <<<"$MANAGED" >/dev/null; then
  pass "managed-only plans are explicit in their output"
else
  fail "managed-only plan marker"
fi

if jq -e '
  [.safe_candidates[] | .reason] | sort
  == ["fyi_age_floor","pending_ttl_elapsed","single_recipient_implemented"]
' <<<"$PLAN" >/dev/null; then
  pass "safe candidates preserve the done versus expired boundary"
else
  fail "safe candidate boundary"
fi

SNAPSHOT="$(jq -r '.snapshot_id' <<<"$PLAN")"
if bash "$TMPD/bin/handoff-lifecycle.sh" apply \
  --snapshot "$SNAPSHOT" --confirm WRONG >/dev/null 2>&1; then
  fail "apply rejects wrong confirmation"
else
  pass "apply rejects wrong confirmation"
fi

APPLIED="$(bash "$TMPD/bin/handoff-lifecycle.sh" apply \
  --snapshot "$SNAPSHOT" --confirm APPLY_SAFE_HANDOFF_LIFECYCLE)"
if jq -e '.applied == true and .transitions == {closed:1,expired:2}' \
  <<<"$APPLIED" >/dev/null; then
  pass "hash-bound apply reports safe transitions"
else
  echo "$APPLIED" >&2
  fail "safe apply"
fi

printf '{"mode":"local"}\n' > "$TMPD/egregore.json"
LOCAL="$(bash "$TMPD/bin/handoff-lifecycle.sh" scan)"
if jq -e '.must_abstain == true' <<<"$LOCAL" >/dev/null; then
  pass "local mode explicitly abstains"
else
  fail "local abstention"
fi

if grep -Fq "MATCH (implementation:Session)-[:IMPLEMENTS]->(s)" "$ROOT/bin/graph-op.sh" &&
   ! awk '/^  resolve-handoffs/,/^    ;;$/' "$ROOT/bin/graph-op.sh" |
     grep -Fq "later.date"; then
  pass "resolver requires explicit implementation lineage"
else
  fail "resolver still accepts unrelated later sessions"
fi

CLAIM_BLOCK="$(awk '/^  claim-handoff/,/^    ;;$/' "$ROOT/bin/graph-op.sh")"
if grep -Fq "MATCH (impl)-[:BY]->(claimant:Person)" <<<"$CLAIM_BLOCK" &&
   grep -Fq "MATCH (ho)-[:HANDED_TO]->(claimant)" <<<"$CLAIM_BLOCK" &&
   grep -Fq "ho.handoffStatus IN ['pending','read','claimed']" <<<"$CLAIM_BLOCK"; then
  pass "claim requires the recipient and cannot regress terminal state"
else
  fail "claim contract permits a non-recipient or terminal handoff"
fi

if grep -Fq 'MATCH (impl:Session {id: $sessionId})-[:IMPLEMENTS]->(ho:Session)' "$ROOT/bin/capture-run.sh" &&
   grep -Fq "MATCH (implementation:Session)-[:IMPLEMENTS]->(s)" "$ROOT/api/services/activity.py" &&
   grep -Fq "MATCH (implementation:Session)-[:IMPLEMENTS]->(s)" "$ROOT/bin/sync-graph.sh" &&
   ! grep -Fq "later.date > s.date" "$ROOT/bin/capture-run.sh" &&
   ! grep -Fq "later.date > s.date" "$ROOT/api/services/activity.py" &&
   ! grep -Fq "later.date > s.date" "$ROOT/bin/sync-graph.sh"; then
  pass "capture, sync, and activity resolvers share the evidence rule"
else
  fail "a secondary resolver still accepts unrelated later sessions"
fi

# shellcheck disable=SC2016 # Literal escaped Cypher parameter in the source.
if grep -Fq 'handoffIntent = \$intent' "$ROOT/bin/index-handoff.sh" &&
   grep -Fq -- '--intent action|feedback|fyi' "$ROOT/bin/agent.sh"; then
  pass "new handoffs persist a lifecycle intent"
else
  fail "intent writer contract"
fi

if grep -Fq 'action: "plan"' "$ROOT/bin/graph-maintenance.sh" &&
   grep -Fq 'handoff-lifecycle.sh" scan' "$ROOT/bin/graph-maintenance.sh"; then
  pass "maintenance plans stale handoffs instead of age-closing them"
else
  fail "maintenance dry-run contract"
fi

echo "1..$PASS"
