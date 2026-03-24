#!/bin/bash
set -euo pipefail
# backfill-session-topics.sh — Fill in topics for sessions that never got one.
#
# Usage: bash bin/backfill-session-topics.sh [--dry-run]
#
# Strategy:
#   1. Sessions with a real branch (not develop/main) → derive topic from branch name
#   2. Sessions stuck on develop with null topic → find the nearest topic'd session
#      from the same author on the same date, adopt its topic
#   3. Remaining → skip (no data to derive from)

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: backfill-session-topics.sh [--dry-run]"
  echo ""
  echo "Fill in topics for sessions that never got one."
  echo "  Pass 1: Derive topic from branch name (dev/author/slug)"
  echo "  Pass 2: Match to nearby topic'd session by author + date"
  echo ""
  echo "Options:"
  echo "  --dry-run  Show what would change without modifying the graph"
  exit 0
fi

GS="$SCRIPT_DIR/bin/graph.sh"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

UPDATED=0
SKIPPED=0

# --- Pass 1: Sessions with real branches (not develop/main/master) ---

echo "Pass 1: Sessions with branches to derive from..."

RESULT=$(bash "$GS" query "
  MATCH (s:Session)
  WHERE s.topic IS NULL
    AND s.branch IS NOT NULL
    AND NOT s.branch IN ['develop', 'main', 'master', 'worktree']
  RETURN s.id AS id, s.branch AS branch
  ORDER BY s.date DESC
" '{}' 2>/dev/null)

COUNT=$(echo "$RESULT" | jq -r '.values | length' 2>/dev/null || echo "0")
[ "$COUNT" = "null" ] && COUNT=0

if [ "$COUNT" -gt 0 ]; then
  echo "  Found $COUNT sessions with branches."
  for i in $(seq 0 $((COUNT - 1))); do
    SID=$(echo "$RESULT" | jq -r ".values[$i][0]" 2>/dev/null)
    BRANCH=$(echo "$RESULT" | jq -r ".values[$i][1]" 2>/dev/null)

    [ -z "$SID" ] || [ "$SID" = "null" ] && { SKIPPED=$((SKIPPED + 1)); continue; }

    TOPIC=$(echo "$BRANCH" | sed -E 's|^(dev|feature|bugfix|hotfix)/[^/]+/||; s|^(dev|feature|bugfix|hotfix)/||; s|-| |g')
    [ -z "$TOPIC" ] && { SKIPPED=$((SKIPPED + 1)); continue; }

    if [ "$DRY_RUN" = true ]; then
      printf "  [dry-run] %s → \"%s\" (from branch)\n" "$SID" "$TOPIC"
    else
      bash "$GS" query "MATCH (s:Session {id: \$sid}) SET s.topic = \$topic RETURN s.id" \
        "$(jq -n --arg sid "$SID" --arg topic "$TOPIC" '{sid: $sid, topic: $topic}')" >/dev/null 2>&1 && {
        printf "  ✓ %s → \"%s\"\n" "$SID" "$TOPIC"
        UPDATED=$((UPDATED + 1))
      } || {
        printf "  ✗ %s (failed)\n" "$SID"
        SKIPPED=$((SKIPPED + 1))
      }
    fi
  done
else
  echo "  None found."
fi

# --- Pass 2: Sessions on develop — match to nearby topic'd sessions ---

echo ""
echo "Pass 2: Sessions on develop — matching to nearby sessions by author+date..."

# For each untitled session, find the closest topic'd session from the same author on the same date.
# Use a single Cypher query that does the matching in-graph.
RESULT=$(bash "$GS" query "
  MATCH (untitled:Session)-[:BY]->(p:Person)
  WHERE untitled.topic IS NULL
    AND (untitled.branch = 'develop' OR untitled.branch IS NULL)
  WITH untitled, p
  OPTIONAL MATCH (titled:Session)-[:BY]->(p)
  WHERE titled.topic IS NOT NULL
    AND titled.date = untitled.date
    AND titled.id <> untitled.id
  WITH untitled, p,
    head(collect(titled.topic)) AS nearestTopic
  WHERE nearestTopic IS NOT NULL
  RETURN untitled.id AS id, nearestTopic AS topic, p.name AS author
  ORDER BY untitled.date DESC
" '{}' 2>/dev/null)

COUNT=$(echo "$RESULT" | jq -r '.values | length' 2>/dev/null || echo "0")
[ "$COUNT" = "null" ] && COUNT=0

if [ "$COUNT" -gt 0 ]; then
  echo "  Found $COUNT sessions matchable to nearby topics."
  for i in $(seq 0 $((COUNT - 1))); do
    SID=$(echo "$RESULT" | jq -r ".values[$i][0]" 2>/dev/null)
    TOPIC=$(echo "$RESULT" | jq -r ".values[$i][1]" 2>/dev/null)
    AUTHOR=$(echo "$RESULT" | jq -r ".values[$i][2]" 2>/dev/null)

    [ -z "$SID" ] || [ "$SID" = "null" ] && { SKIPPED=$((SKIPPED + 1)); continue; }
    [ -z "$TOPIC" ] || [ "$TOPIC" = "null" ] && { SKIPPED=$((SKIPPED + 1)); continue; }

    if [ "$DRY_RUN" = true ]; then
      printf "  [dry-run] %s (%s) → \"%s\" (from same-day session)\n" "$SID" "$AUTHOR" "$TOPIC"
    else
      bash "$GS" query "MATCH (s:Session {id: \$sid}) SET s.topic = \$topic RETURN s.id" \
        "$(jq -n --arg sid "$SID" --arg topic "$TOPIC" '{sid: $sid, topic: $topic}')" >/dev/null 2>&1 && {
        printf "  ✓ %s (%s) → \"%s\"\n" "$SID" "$AUTHOR" "$TOPIC"
        UPDATED=$((UPDATED + 1))
      } || {
        printf "  ✗ %s (failed)\n" "$SID"
        SKIPPED=$((SKIPPED + 1))
      }
    fi
  done
else
  echo "  None matchable."
fi

# --- Summary ---

# Count remaining untitled
REMAINING=$(bash "$GS" query "MATCH (s:Session) WHERE s.topic IS NULL RETURN count(s) AS cnt" '{}' 2>/dev/null | jq -r '.values[0][0]' 2>/dev/null || echo "?")

echo ""
if [ "$DRY_RUN" = true ]; then
  echo "Dry run complete. Would update sessions in passes above."
else
  echo "Done. $UPDATED updated, $SKIPPED skipped, $REMAINING still untitled."
fi
