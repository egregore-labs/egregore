#!/usr/bin/env bash
set -euo pipefail

# Validate, plan, or apply a durable ingestion manifest to the organization graph.
# The planner owns the source-to-graph contract; this wrapper owns mode detection,
# batching, and truthful delivery receipts.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT"
CONFIG="${CONFIG:-$ROOT/egregore.json}"
PLANNER="${EGREGORE_INGEST_GRAPH_PLANNER:-$ROOT/bin/ingest_graph.py}"
GRAPH_BATCH="${EGREGORE_INGEST_GRAPH_BATCH:-$ROOT/bin/graph-batch.sh}"

# shellcheck source=bin/lib/config.sh
source "$ROOT/bin/lib/config.sh"

usage() {
  echo "usage: bash bin/ingest-graph.sh {validate|plan|apply} MANIFEST" >&2
  exit 2
}

mode="${1:-}"
manifest="${2:-}"
[ -n "$mode" ] && [ -n "$manifest" ] || usage

case "$mode" in
  validate|plan)
    exec python3 "$PLANNER" "$mode" "$manifest"
    ;;
  apply) ;;
  *) usage ;;
esac

plan="$(python3 "$PLANNER" plan "$manifest")"
manifest_id="$(printf '%s' "$plan" | jq -r '.manifest_id')"
query_count="$(printf '%s' "$plan" | jq -r '.query_count')"

if [ "$(_detect_mode)" = "local" ]; then
  jq -cn \
    --arg manifest_id "$manifest_id" \
    --argjson queries "$query_count" \
    '{status:"stored",graph:"unavailable-in-local-mode",manifest_id:$manifest_id,queries:$queries,batches:0,failed:0,replayable:true}'
  exit 0
fi

total=0
succeeded=0
failed=0
while IFS= read -r batch; do
  [ -n "$batch" ] || continue
  total=$((total + 1))
  expected="$(printf '%s' "$batch" | jq 'length')"
  if response="$(bash "$GRAPH_BATCH" "$batch" 2>/dev/null)" \
    && actual="$(printf '%s' "$response" | jq -er '.results | length' 2>/dev/null)" \
    && [ "$actual" -eq "$expected" ]; then
    succeeded=$((succeeded + 1))
  else
    failed=$((failed + 1))
  fi
done < <(
  printf '%s' "$plan" |
    jq -c '.queries | map({statement, parameters}) as $all | range(0; length; 20) as $i | $all[$i:$i+20]'
)

if [ "$failed" -gt 0 ]; then
  jq -cn \
    --arg manifest_id "$manifest_id" \
    --argjson queries "$query_count" \
    --argjson batches "$total" \
    --argjson succeeded "$succeeded" \
    --argjson failed "$failed" \
    '{status:"partial",manifest_id:$manifest_id,queries:$queries,batches:$batches,succeeded:$succeeded,failed:$failed,replayable:true}'
  exit 1
fi

jq -cn \
  --arg manifest_id "$manifest_id" \
  --argjson queries "$query_count" \
  --argjson batches "$total" \
  '{status:"projected",manifest_id:$manifest_id,queries:$queries,batches:$batches,failed:0,replayable:true}'
