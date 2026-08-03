#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPD="$(mktemp -d -t handoff-activity-lifecycle-XXXXXX)"
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
cp "$ROOT/bin/activity-action.sh" "$TMPD/bin/activity-action.sh"
printf '{"mode":"connected"}\n' > "$TMPD/egregore.json"
printf '{"github_username":"oz"}\n' > "$TMPD/.egregore-state.json"

cat > "$TMPD/bin/graph-op.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ACTION_LOG"
case "$1" in
  mark-done) echo '{"fields":["id","topic","status"],"values":[["h1","Lifecycle work","done"]]}' ;;
  mark-expired) echo '{"fields":["id","topic","status"],"values":[["h1","Lifecycle work","expired"]]}' ;;
  reopen-handoff) echo '{"fields":["id","topic","status"],"values":[["h1","Lifecycle work","pending"]]}' ;;
  mark-read) echo '{"fields":["id","topic","status"],"values":[["h1","Lifecycle work","read"]]}' ;;
  *) echo '{"fields":[],"values":[]}' ;;
esac
SH

export ACTION_LOG="$TMPD/action.log"
DONE="$(bash "$TMPD/bin/activity-action.sh" "done" h1)"
if jq -e '.applied and .status == "done" and .user == "oz"' <<<"$DONE" >/dev/null &&
   grep -Fq 'mark-done h1 oz' "$ACTION_LOG"; then
  pass "activity done is recipient-scoped"
else
  fail "activity done contract"
fi

EXPIRED="$(bash "$TMPD/bin/activity-action.sh" expire h1)"
REOPENED="$(bash "$TMPD/bin/activity-action.sh" reopen h1)"
if jq -e '.status == "expired"' <<<"$EXPIRED" >/dev/null &&
   jq -e '.status == "pending"' <<<"$REOPENED" >/dev/null; then
  pass "activity exposes explicit expire and reopen transitions"
else
  fail "expire/reopen contract"
fi

printf '{"mode":"local"}\n' > "$TMPD/egregore.json"
LOCAL="$(bash "$TMPD/bin/activity-action.sh" "done" h1)"
if jq -e '.applied == false and .availability == "unavailable_in_this_configuration"' \
  <<<"$LOCAL" >/dev/null; then
  pass "local activity actions abstain"
else
  fail "local activity action boundary"
fi

# Recurring runner fixture.
cp "$ROOT/bin/handoff-lifecycle-job.sh" "$TMPD/bin/handoff-lifecycle-job.sh"
printf '{"mode":"connected"}\n' > "$TMPD/egregore.json"
cat > "$TMPD/bin/handoff-lifecycle.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JOB_LOG"
if [[ "$1" == "scan" ]]; then
  cat <<'JSON'
{"snapshot_id":"snap-managed","review_candidates":[{"id":"n1","action":"nudge"}]}
JSON
else
  echo '{"transitions":{"closed":1,"expired":2}}'
fi
SH
cat > "$TMPD/bin/graph-op.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JOB_LOG"
case "$1" in
  claim-handoff-nudge)
    echo '{"fields":["id","topic","recipients"],"values":[["n1","Review lifecycle",["oz"]]]}'
    ;;
  mark-handoff-nudged|release-handoff-nudge)
    echo '{"fields":["id","status"],"values":[["n1","sent"]]}'
    ;;
  *) echo '{"fields":[],"values":[]}' ;;
esac
SH
cat > "$TMPD/bin/notify.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JOB_LOG"
cat <<'JSON'
{"status":"approval_required","plan_id":"plan-n1","digest":"digest-n1","org":"Curve Labs","recipient":"oz","channels":["telegram"],"deliveries":[{"channel":"telegram","destination":"oz","kind":"dm"}],"no_fallback":true,"message":"Review lifecycle needs your attention.","expires_at":4102444800}
JSON
SH

export JOB_LOG="$TMPD/job.log"
JOB="$(bash "$TMPD/bin/handoff-lifecycle-job.sh" run)"
if jq -e '
  .applied
  and .managed_only
  and .transitions == {closed:1,expired:2}
  and .nudges[0].status == "approval_required"
  and (.nudges[0].proposals | length) == 1
  and .nudges[0].proposals[0].recipient == "oz"
' <<<"$JOB" >/dev/null &&
   grep -Fq 'scan --managed-only' "$JOB_LOG" &&
   grep -Fq 'apply --managed-only --snapshot snap-managed' "$JOB_LOG" &&
   grep -Fq 'plan send oz' "$JOB_LOG" &&
   grep -Fq 'release-handoff-nudge n1' "$JOB_LOG" &&
   ! grep -Fq 'mark-handoff-nudged n1' "$JOB_LOG"; then
  pass "recurring job applies managed plans and returns an approval-required proposal without dispatch"
else
  cat "$JOB_LOG" >&2
  echo "$JOB" >&2
  fail "recurring lifecycle job"
fi

ACTIVITY='{"org":"Curve Labs","date":"Jul 23","me":"oz","graph_status":"connected","handoffs_to_me":[{"author":"cem","topic":"Review lifecycle","sessionId":"h1","status":"pending","intent":"feedback","ageDays":9},{"author":"cem","topic":"Old FYI","sessionId":"h2","status":"expired","intent":"fyi","ageDays":15}]}'
RENDERED="$(printf '%s\n' "$ACTIVITY" | node "$ROOT/bin/codex-skill-render.mjs" activity-card -)"
if grep -Fq '[1] ● ⇌ cem: Review lifecycle' <<<"$RENDERED" &&
   grep -Fq '9d · feedback' <<<"$RENDERED" &&
   grep -Fq '[2] × ⇌ cem: Old FYI' <<<"$RENDERED" &&
   grep -Fq 'Handoff actions: done N · expire N · reopen N' <<<"$RENDERED" &&
   grep -Fq 'Type a number to act, or keep working.' <<<"$RENDERED"; then
  pass "activity card renders status, age, intent, and one-tap actions"
else
  echo "$RENDERED" >&2
  fail "activity lifecycle rendering"
fi

if grep -Fq "coalesce(s.handoffLifecycleVersion, 0) >= 1" "$ROOT/bin/graph-op.sh" &&
   grep -Fq "coalesce(s.handoffIntent, 'unclassified') IN ['action','feedback','fyi']" \
     "$ROOT/bin/graph-op.sh" &&
   grep -Fq '_handoff_lifecycle' "$ROOT/bin/attendant.sh"; then
  pass "scheduler and atomic nudge claim exclude legacy handoffs"
else
  fail "legacy automation boundary"
fi

if grep -Fq "lifecycleStatus IN ['pending', 'read', 'claimed']" \
     "$ROOT/api/services/activity.py" &&
   grep -Fq "duration.inDays(handoffDate, date()).days AS ageDays" \
     "$ROOT/api/services/activity.py"; then
  pass "activity API returns stale open handoffs with lifecycle metadata"
else
  fail "activity API lifecycle query"
fi

echo "1..$PASS"
