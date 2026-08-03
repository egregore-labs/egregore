#!/bin/bash
set -euo pipefail

# Deterministic handoff lifecycle reconciliation.
#
# `scan` is read-only and produces a versioned, hash-bound plan. `apply` can
# execute only high-confidence transitions from an unchanged plan:
#   - read/claimed -> done when one recipient has a completed IMPLEMENTS session
#   - open FYI -> expired after the configured age floor
#   - untouched pending -> expired after the configured lifecycle TTL
#
# Age never marks a handoff done. Read/claimed action and feedback handoffs
# without implementation evidence stay open for human review.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GS="$SCRIPT_DIR/bin/graph.sh"
ACTION="${1:-scan}"
shift || true

usage() {
  cat <<'EOF'
Usage:
  handoff-lifecycle.sh scan [--days N] [--user HANDLE] [--managed-only]
  handoff-lifecycle.sh apply --snapshot SHA256 --confirm APPLY_SAFE_HANDOFF_LIFECYCLE
                             [--days N] [--user HANDLE] [--managed-only]

scan is read-only. apply fails closed when the graph changed after the scan.
--managed-only limits the plan to lifecycle-v1 handoffs with explicit intent;
it is the safe boundary for unattended recurring execution.
EOF
}

if [[ "$ACTION" == "--help" || "$ACTION" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "$ACTION" != "scan" && "$ACTION" != "apply" ]]; then
  echo '{"error":"action must be scan or apply"}'
  exit 2
fi

DAYS=14
USER_REF=""
EXPECTED_SNAPSHOT=""
CONFIRM=""
MANAGED_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="${2:?missing days}"; shift 2 ;;
    --user) USER_REF="${2:?missing user}"; shift 2 ;;
    --managed-only) MANAGED_ONLY=true; shift ;;
    --snapshot) EXPECTED_SNAPSHOT="${2:?missing snapshot}"; shift 2 ;;
    --confirm) CONFIRM="${2:?missing confirmation}"; shift 2 ;;
    *) echo '{"error":"unknown option","option":"'"$1"'"}'; exit 2 ;;
  esac
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [[ "$DAYS" -lt 1 || "$DAYS" -gt 365 ]]; then
  echo '{"error":"days must be between 1 and 365"}'
  exit 2
fi

MODE="$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo connected)"
if [[ "$MODE" == "local" ]]; then
  echo '{"schema":"egregore-handoff-lifecycle-plan/v1","availability":"unavailable_in_this_configuration","must_abstain":true}'
  exit 0
fi

build_plan() {
  local raw rows snapshot
  raw="$(bash "$GS" query "
    MATCH (s:Session)-[:HANDED_TO]->(recipient:Person)
    WHERE (\$user = ''
           OR toLower(recipient.name) = toLower(\$user)
           OR toLower(coalesce(recipient.github, '')) = toLower(\$user))
      AND coalesce(s.handoffStatus, 'pending') IN ['pending','read','claimed']
      AND (NOT \$managedOnly
           OR (coalesce(s.handoffLifecycleVersion, 0) >= 1
               AND coalesce(s.handoffIntent, 'unclassified') IN ['action','feedback','fyi']))
    WITH DISTINCT s, recipient
    OPTIONAL MATCH (s)-[:BY]->(author:Person)
    WITH s, recipient, author,
         size([(s)-[:HANDED_TO]->(:Person) | 1]) AS recipientCount
    OPTIONAL MATCH (impl:Session)-[:IMPLEMENTS]->(s)
    OPTIONAL MATCH (impl)-[:BY]->(implAuthor:Person)
    WITH s, recipient, author, recipientCount,
         head([candidate IN collect(DISTINCT
           CASE
             WHEN implAuthor = recipient
              AND (impl.wrappedAt IS NOT NULL
                   OR impl.status IN ['completed','handed_off','wrapped'])
             THEN {id: impl.id, status: impl.status}
             ELSE null
           END) WHERE candidate IS NOT NULL]) AS implementation
    WITH s, recipient, author, recipientCount, implementation,
         CASE WHEN s.date IS NULL THEN null
              ELSE duration.inDays(date(s.date), date()).days END AS ageDays
    RETURN s.id AS id,
           s.topic AS topic,
           coalesce(author.name, s.author, 'unknown') AS author,
           recipient.name AS recipient,
           toString(s.date) AS date,
           coalesce(s.handoffStatus, 'pending') AS status,
           coalesce(s.handoffIntent, 'unclassified') AS intent,
           ageDays,
           recipientCount,
           implementation.id AS implementationId,
           implementation.status AS implementationStatus,
           s.handoffLifecycleVersion AS lifecycleVersion,
           toString(s.handoffNudgedAt) AS nudgedAt
    ORDER BY s.date DESC, recipient.name
  " "$(jq -n --arg user "$USER_REF" --argjson managedOnly "$MANAGED_ONLY" \
    '{user:$user,managedOnly:$managedOnly}')")"

  if ! rows="$(printf '%s' "$raw" | jq -c '
    (.values // []) | map({
      id:.[0], topic:.[1], author:.[2], recipient:.[3], date:.[4],
      status:.[5], intent:.[6], age_days:.[7], recipient_count:.[8],
      implementation_id:.[9], implementation_status:.[10],
      lifecycle_version:.[11], nudged_at:.[12]
    }) | sort_by(.id, .recipient)
  ' 2>/dev/null)"; then
    echo '{"error":"invalid graph response"}'
    return 1
  fi

  snapshot="$(printf '%s' "$rows" | openssl dgst -sha256 | awk '{print $NF}')"
  jq -n \
    --arg snapshot "$snapshot" \
    --arg user "$USER_REF" \
    --argjson days "$DAYS" \
    --argjson managed_only "$MANAGED_ONLY" \
    --argjson rows "$rows" '
    def recommendation:
      if ((.status == "read" or .status == "claimed")
          and .recipient_count == 1
          and .implementation_id != null)
      then {action:"close", reason:"single_recipient_implemented", confidence:"high"}
      elif (.intent == "fyi" and (.age_days // 0) >= $days)
      then {action:"expire", reason:"fyi_age_floor", confidence:"high"}
      elif (.status == "pending" and (.age_days // 0) >= $days)
      then {action:"expire", reason:"pending_ttl_elapsed", confidence:"policy"}
      elif ((.age_days // 0) >= $days)
      then {action:"review", reason:
              (if .intent == "unclassified"
               then "stale_unclassified"
               else "stale_requires_human" end),
            confidence:"none"}
      elif ((.age_days // 0) >= 7 and .recipient_count > 1)
      then {action:"review", reason:"multi_recipient_requires_human", confidence:"none"}
      elif ((.age_days // 0) >= 7 and .nudged_at == null)
      then {action:"nudge", reason:"open_seven_days", confidence:"none"}
      elif ((.age_days // 0) >= 7)
      then {action:"keep", reason:"awaiting_after_nudge", confidence:"none"}
      else {action:"keep", reason:"recent_open", confidence:"none"}
      end;
    ($rows | map(. + recommendation)) as $items
    | {
        schema:"egregore-handoff-lifecycle-plan/v1",
        snapshot_id:$snapshot,
        subject:(if $user == "" then "all" else $user end),
        threshold_days:$days,
        managed_only:$managed_only,
        state_scope:"session",
        state_scope_warning:"Status is stored on Session, so automatic close requires exactly one recipient.",
        counts:{
          open_rows:($items|length),
          unique_handoffs:([$items[].id]|unique|length),
          duplicate_recipient_rows:(($items|length)-([$items[].id]|unique|length)),
          close:([$items[]|select(.action=="close")]|unique_by(.id)|length),
          expire:([$items[]|select(.action=="expire")]|unique_by(.id)|length),
          review:([$items[]|select(.action=="review")]|unique_by(.id)|length),
          nudge:([$items[]|select(.action=="nudge")]|unique_by(.id)|length),
          keep:([$items[]|select(.action=="keep")]|unique_by(.id)|length),
          unclassified:([$items[]|select(.intent=="unclassified")]|unique_by(.id)|length)
        },
        safe_candidates:([$items[]|select(.action=="close" or .action=="expire")]|unique_by(.id)),
        review_candidates:([$items[]|select(.action=="review" or .action=="nudge")]|unique_by(.id)),
        items:$items,
        apply_contract:{
          requires_snapshot:true,
          confirmation:"APPLY_SAFE_HANDOFF_LIFECYCLE",
          age_alone_never_marks_done:true,
          pending_ttl_may_expire_unacknowledged_work:true
        }
      }
  '
}

PLAN="$(build_plan)"
if [[ "$ACTION" == "scan" ]]; then
  printf '%s\n' "$PLAN"
  exit 0
fi

if [[ -z "$EXPECTED_SNAPSHOT" || "$CONFIRM" != "APPLY_SAFE_HANDOFF_LIFECYCLE" ]]; then
  printf '%s\n' "$PLAN" | jq '. + {
    applied:false,
    error:"apply requires the current --snapshot and --confirm APPLY_SAFE_HANDOFF_LIFECYCLE"
  }'
  exit 3
fi

CURRENT_SNAPSHOT="$(printf '%s' "$PLAN" | jq -r '.snapshot_id')"
if [[ "$CURRENT_SNAPSHOT" != "$EXPECTED_SNAPSHOT" ]]; then
  printf '%s\n' "$PLAN" | jq --arg expected "$EXPECTED_SNAPSHOT" '. + {
    applied:false,
    error:"snapshot_changed",
    expected_snapshot:$expected
  }'
  exit 4
fi

CLOSE_IDS="$(printf '%s' "$PLAN" | jq -c '[.safe_candidates[]|select(.action=="close")|.id]|unique')"
EXPIRE_IDS="$(printf '%s' "$PLAN" | jq -c '[.safe_candidates[]|select(.action=="expire")|.id]|unique')"

if [[ "$CLOSE_IDS" == "[]" && "$EXPIRE_IDS" == "[]" ]]; then
  printf '%s\n' "$PLAN" | jq '. + {applied:true,transitions:{closed:0,expired:0}}'
  exit 0
fi

RESULT="$(bash "$GS" query "
  UNWIND \$closeIds AS closeId
  MATCH (closed:Session {id: closeId})
  WHERE coalesce(closed.handoffStatus, 'pending') IN ['read','claimed']
  SET closed.handoffStatus = 'done',
      closed.handoffDoneAt = coalesce(closed.handoffDoneAt, datetime()),
      closed.handoffUpdatedAt = datetime(),
      closed.handoffLifecycleReason = 'single_recipient_implemented',
      closed.handoffLifecycleVersion = 1
  WITH count(closed) AS closedCount
  CALL {
    WITH \$expireIds AS expireIds
    UNWIND expireIds AS expireId
    MATCH (expired:Session {id: expireId})
    WHERE coalesce(expired.handoffStatus, 'pending') IN ['pending','read','claimed']
      AND (expired.handoffIntent = 'fyi'
           OR coalesce(expired.handoffStatus, 'pending') = 'pending')
    SET expired.handoffStatus = 'expired',
        expired.handoffExpiredAt = coalesce(expired.handoffExpiredAt, datetime()),
        expired.handoffUpdatedAt = datetime(),
        expired.handoffLifecycleReason =
          CASE WHEN expired.handoffIntent = 'fyi'
               THEN 'fyi_age_floor'
               ELSE 'pending_ttl_elapsed' END,
        expired.handoffLifecycleVersion = 1
    RETURN count(expired) AS expiredCount
  }
  RETURN closedCount, expiredCount
" "$(jq -n --argjson closeIds "$CLOSE_IDS" --argjson expireIds "$EXPIRE_IDS" \
  '{closeIds:$closeIds,expireIds:$expireIds}')")"

printf '%s\n' "$PLAN" | jq --argjson result "$RESULT" '. + {
  applied:true,
  transitions:{
    closed:($result.values[0][0] // 0),
    expired:($result.values[0][1] // 0)
  }
}'
