#!/usr/bin/env bash
set -euo pipefail

# Detached reconciliation worker for explicit captures.
# The foreground path only appends to graph-wal.sh; this worker pays network
# latency and retries queued writes. It may propose completion notifications,
# but detached reconciliation never approves or dispatches them.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo connected)"
[ "$MODE" = "connected" ] || exit 0

SESSION_ID=""
AUTHOR=""
SUMMARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --author) AUTHOR="${2:-}"; shift 2 ;;
    --summary) SUMMARY="${2:-}"; shift 2 ;;
    *) echo "Unknown reconcile option: $1" >&2; exit 1 ;;
  esac
done
[ -n "$SESSION_ID" ] || exit 0

# Applies Session capture first, then the idempotent handoff transition.
bash "$SCRIPT_DIR/bin/graph-wal.sh" drain >/dev/null 2>&1 || exit 0

# Claim completion notifications atomically. A stale claim can be retried;
# successful sends are permanently marked on the IMPLEMENTS relationship.
# shellcheck disable=SC2016 # $name tokens are Cypher parameters.
CLAIM_CYPHER='
  MATCH (impl:Session {id: $sessionId})-[r:IMPLEMENTS]->(ho:Session)-[:BY]->(origin:Person)
  WHERE ho.handoffStatus = "done"
    AND r.completionNotifiedAt IS NULL
    AND r.completionNotifyProposedAt IS NULL
    AND (r.completionNotifyClaimedAt IS NULL
         OR r.completionNotifyClaimedAt < datetime() - duration("PT1H"))
  SET r.completionNotifyClaimedAt = datetime()
  RETURN ho.id AS handoffId, ho.topic AS topic,
         coalesce(origin.github, origin.name) AS recipient'
PARAMS="$(jq -nc --arg sessionId "$SESSION_ID" '{sessionId:$sessionId}')"
CLAIMS="$(bash "$SCRIPT_DIR/bin/graph.sh" query "$CLAIM_CYPHER" "$PARAMS" 2>/dev/null || echo '{}')"

printf '%s' "$CLAIMS" | jq -r '.values[]? | @tsv' 2>/dev/null |
while IFS=$'\t' read -r handoff_id topic recipient; do
  [ -n "$handoff_id" ] && [ -n "$recipient" ] || continue
  message="${AUTHOR:-A teammate} completed your handoff '${topic:-$handoff_id}'"
  [ -n "$SUMMARY" ] && message="${message} — $(printf '%s' "$SUMMARY" | tr '\n' ' ' | cut -c1-180)"

  notify_result="$(bash "$SCRIPT_DIR/bin/notify.sh" plan send "$recipient" "$message" 2>/dev/null || echo '{}')"
  if printf '%s' "$notify_result" | jq -e '.status == "approval_required"' >/dev/null 2>&1; then
    bash "$SCRIPT_DIR/bin/graph.sh" query '
      MATCH (impl:Session {id: $sessionId})-[r:IMPLEMENTS]->(ho:Session {id: $handoffId})
      SET r.completionNotifyProposedAt = datetime(),
          r.completionNotifyClaimedAt = null
      RETURN ho.id AS id
    ' "$(jq -nc --arg sessionId "$SESSION_ID" --arg handoffId "$handoff_id" \
      '{sessionId:$sessionId,handoffId:$handoffId}')" >/dev/null 2>&1 || true
  else
    bash "$SCRIPT_DIR/bin/graph.sh" query '
      MATCH (impl:Session {id: $sessionId})-[r:IMPLEMENTS]->(ho:Session {id: $handoffId})
      SET r.completionNotifyClaimedAt = null,
          r.completionNotifyProposalFailedAt = datetime()
      RETURN ho.id AS id
    ' "$(jq -nc --arg sessionId "$SESSION_ID" --arg handoffId "$handoff_id" \
      '{sessionId:$sessionId,handoffId:$handoffId}')" >/dev/null 2>&1 || true
  fi
done
