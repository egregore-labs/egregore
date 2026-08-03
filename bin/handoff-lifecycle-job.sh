#!/usr/bin/env bash
set -euo pipefail

# Recurring handoff lifecycle runner.
#
# `scan` is read-only. `run` applies only lifecycle-v1, explicitly classified
# handoffs, then creates approval-required notification proposals for eligible
# seven-day nudges. It never dispatches. Legacy unclassified backfill is
# deliberately outside this job.
#
# Usage:
#   bash bin/handoff-lifecycle-job.sh scan
#   bash bin/handoff-lifecycle-job.sh run

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:-scan}"
case "$ACTION" in
  scan|run) ;;
  *) jq -n '{error:"action must be scan or run"}'; exit 2 ;;
esac

MODE="$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo connected)"
if [[ "$MODE" != "connected" ]]; then
  jq -n '{
    schema:"egregore-handoff-lifecycle-job/v1",
    availability:"unavailable_in_this_configuration",
    applied:false
  }'
  exit 0
fi

PLAN="$(bash "$SCRIPT_DIR/bin/handoff-lifecycle.sh" scan --managed-only)"
if [[ "$ACTION" == "scan" ]]; then
  printf '%s\n' "$PLAN" | jq '{
    schema:"egregore-handoff-lifecycle-job/v1",
    mode:"scan",
    applied:false,
    plan:.
  }'
  exit 0
fi

SNAPSHOT="$(printf '%s\n' "$PLAN" | jq -r '.snapshot_id')"
TRANSITIONS="$(bash "$SCRIPT_DIR/bin/handoff-lifecycle.sh" apply \
  --managed-only \
  --snapshot "$SNAPSHOT" \
  --confirm APPLY_SAFE_HANDOFF_LIFECYCLE)"

NUDGE_RESULTS='[]'
while IFS= read -r ITEM; do
  [[ -n "$ITEM" ]] || continue
  SID="$(printf '%s\n' "$ITEM" | jq -r '.id')"
  CLAIM="$(bash "$SCRIPT_DIR/bin/graph-op.sh" claim-handoff-nudge "$SID")"
  if ! printf '%s\n' "$CLAIM" | jq -e '.values[0][0] != null' >/dev/null 2>&1; then
    continue
  fi

  TOPIC="$(printf '%s\n' "$CLAIM" | jq -r '.values[0][1] // "handoff"')"
  RECIPIENTS="$(printf '%s\n' "$CLAIM" | jq -c '.values[0][2] // []')"
  PROPOSALS='[]'
  FAILED=0
  while IFS= read -r RECIPIENT; do
    [[ -n "$RECIPIENT" ]] || continue
    MESSAGE="Handoff waiting for you: ${TOPIC}. Open /activity to read, complete, or expire it."
    NOTIFY_RESULT="$(bash "$SCRIPT_DIR/bin/notify.sh" plan send "$RECIPIENT" "$MESSAGE" 2>/dev/null || echo '{}')"
    if printf '%s\n' "$NOTIFY_RESULT" | jq -e '.status == "approval_required"' >/dev/null 2>&1; then
      PROPOSALS="$(printf '%s\n' "$PROPOSALS" | jq \
        --argjson proposal "$NOTIFY_RESULT" '. + [$proposal]')"
    else
      FAILED=$((FAILED + 1))
    fi
  done < <(printf '%s\n' "$RECIPIENTS" | jq -r '.[]')

  bash "$SCRIPT_DIR/bin/graph-op.sh" release-handoff-nudge "$SID" >/dev/null
  if [[ "$(printf '%s\n' "$PROPOSALS" | jq 'length')" -gt 0 ]]; then
    STATUS="approval_required"
  else
    STATUS="unavailable"
  fi

  NUDGE_RESULTS="$(printf '%s\n' "$NUDGE_RESULTS" | jq \
    --arg id "$SID" \
    --arg topic "$TOPIC" \
    --arg status "$STATUS" \
    --argjson proposals "$PROPOSALS" \
    --argjson failed "$FAILED" \
    '. + [{id:$id,topic:$topic,status:$status,proposals:$proposals,failed:$failed}]')"
done < <(printf '%s\n' "$PLAN" | jq -c '.review_candidates[] | select(.action=="nudge")')

jq -n \
  --argjson transitions "$TRANSITIONS" \
  --argjson nudges "$NUDGE_RESULTS" \
  '{
    schema:"egregore-handoff-lifecycle-job/v1",
    mode:"run",
    applied:true,
    managed_only:true,
    transitions:$transitions.transitions,
    nudges:$nudges
  }'
