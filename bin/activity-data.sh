#!/bin/bash
# Fetches all activity dashboard data in parallel.
# Usage: bash bin/activity-data.sh [username]
# Returns a single JSON object with all query results.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GS="$SCRIPT_DIR/bin/graph.sh"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# --- Detect user ---
ME="${1:-}"
if [ -z "$ME" ]; then
  FULL_NAME=$(git -C "$SCRIPT_DIR" config user.name 2>/dev/null || echo "unknown")
  # Map git name → short name
  case "$FULL_NAME" in
    "Oguzhan Yayla"|"oz") ME="oz" ;;
    "Cem Dagdelen"|"Cem F"|"cem") ME="cem" ;;
    "Ali"|"ali") ME="ali" ;;
    "Pali"|"pali") ME="pali" ;;
    *) ME=$(echo "$FULL_NAME" | tr '[:upper:]' '[:lower:]' | cut -d' ' -f1) ;;
  esac
fi

ORG=$(jq -r '.org_name // "Egregore"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "Egregore")
DATE=$(date '+%b %d')
EMPTY='{"fields":[],"values":[]}'

# --- Fire all queries in parallel ---

# Q1: My sessions (last 10)
bash "$GS" query "MATCH (s:Session)-[:BY]->(p:Person {name: '$ME'}) OPTIONAL MATCH (s)-[:HANDED_TO]->(target:Person) RETURN s.date AS date, s.topic AS topic, s.id AS id, s.filePath AS filePath, target.name AS handedTo ORDER BY s.date DESC, s.id DESC LIMIT 10" > "$TMPDIR/q1.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/q1.json" &

# Q2: Team sessions (7 days)
bash "$GS" query "MATCH (s:Session)-[:BY]->(p:Person) WHERE p.name <> '$ME' AND s.date >= date() - duration('P7D') RETURN s.date AS date, s.topic AS topic, p.name AS by ORDER BY s.date DESC LIMIT 5" > "$TMPDIR/q2.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/q2.json" &

# Q3: Active quests (scored with personal relevance)
bash "$GS" query "MATCH (q:Quest {status: 'active'}) OPTIONAL MATCH (a:Artifact)-[:PART_OF]->(q) OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(p:Person) WHERE p.name IS NOT NULL AND p.name <> 'external' OPTIONAL MATCH (q)-[:STARTED_BY]->(starter:Person {name: '$ME'}) OPTIONAL MATCH (myArt:Artifact)-[:PART_OF]->(q) WHERE (myArt)-[:CONTRIBUTED_BY]->(:Person {name: '$ME'}) WITH q, count(DISTINCT a) AS artifacts, count(DISTINCT p) AS contributors, CASE WHEN count(a) > 0 THEN duration.inDays(max(a.created), date()).days ELSE duration.inDays(q.started, date()).days END AS daysSince, coalesce(q.priority, 0) AS priority, CASE WHEN starter IS NOT NULL THEN 1 ELSE 0 END AS iStarted, count(DISTINCT myArt) AS myArtifacts WITH q, artifacts, daysSince, round((toFloat(artifacts) + toFloat(contributors)*1.5 + toFloat(priority)*5.0 + 30.0/(1.0+toFloat(daysSince)*0.5) + CASE WHEN iStarted = 1 THEN 15.0 ELSE 0.0 END + toFloat(myArtifacts)*3.0) * 100)/100 AS score ORDER BY score DESC LIMIT 5 RETURN q.id AS quest, q.title AS title, artifacts, daysSince, score" > "$TMPDIR/q3.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/q3.json" &

# Q4: Pending questions for me
bash "$GS" query "MATCH (qs:QuestionSet {status: 'pending'})-[:ASKED_TO]->(p:Person {name: '$ME'}) MATCH (qs)-[:ASKED_BY]->(asker:Person) RETURN qs.id AS setId, qs.topic AS topic, qs.created AS created, asker.name AS from ORDER BY qs.created DESC" > "$TMPDIR/q4.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/q4.json" &

# Q5: Answered questions (7 days)
bash "$GS" query "MATCH (qs:QuestionSet {status: 'answered'})-[:ASKED_BY]->(p:Person {name: '$ME'}) MATCH (qs)-[:ASKED_TO]->(target:Person) WHERE qs.created >= datetime() - duration('P7D') RETURN qs.id AS setId, qs.topic AS topic, target.name AS answeredBy ORDER BY qs.created DESC" > "$TMPDIR/q5.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/q5.json" &

# Q6: Handoffs to me (7 days, exclude done)
bash "$GS" query "MATCH (s:Session)-[:HANDED_TO]->(p:Person {name: '$ME'}) WHERE s.date >= date() - duration('P7D') AND coalesce(s.handoffStatus, 'pending') <> 'done' MATCH (s)-[:BY]->(author:Person) RETURN s.topic AS topic, s.date AS date, author.name AS author, s.filePath AS filePath, s.id AS sessionId, coalesce(s.handoffStatus, 'pending') AS status ORDER BY s.date DESC LIMIT 5" > "$TMPDIR/q6.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/q6.json" &

# Q7: All handoffs (7 days)
bash "$GS" query "MATCH (s:Session)-[:HANDED_TO]->(target:Person) WHERE s.date >= date() - duration('P7D') MATCH (s)-[:BY]->(author:Person) RETURN s.topic AS topic, s.date AS date, author.name AS from, target.name AS to, s.filePath AS filePath ORDER BY s.date DESC LIMIT 5" > "$TMPDIR/q7.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/q7.json" &

# Q_gap: Knowledge gap count (sessions without artifacts)
bash "$GS" query "MATCH (s:Session)-[:BY]->(p:Person {name: '$ME'}) WHERE s.date >= date() - duration('P14D') OPTIONAL MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p) WHERE a.created >= datetime({year: s.date.year, month: s.date.month, day: s.date.day}) AND a.created < datetime({year: s.date.year, month: s.date.month, day: s.date.day}) + duration('P1D') WITH s, count(a) AS artifactCount WHERE artifactCount = 0 RETURN count(s) AS gapCount" > "$TMPDIR/qgap.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/qgap.json" &

# Q_orphans: Orphan artifact count (14 days)
bash "$GS" query "OPTIONAL MATCH (a:Artifact) WHERE a.created >= date() - duration('P14D') AND NOT (a)-[:PART_OF]->(:Quest) RETURN count(a) AS orphanCount" > "$TMPDIR/qorphans.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/qorphans.json" &

# Git sync + PRs + disk cross-reference
(
  # Sync
  git -C "$SCRIPT_DIR" fetch origin --quiet 2>/dev/null || true
  CURRENT=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "unknown")
  if [ "$CURRENT" != "develop" ]; then
    git -C "$SCRIPT_DIR" fetch origin develop:develop --quiet 2>/dev/null || true
  fi
  if [[ "$CURRENT" == dev/* ]]; then
    git -C "$SCRIPT_DIR" rebase develop --quiet 2>/dev/null || git -C "$SCRIPT_DIR" rebase --abort 2>/dev/null || true
  fi

  # Memory sync
  if [ -d "$SCRIPT_DIR/memory/.git" ] || [ -L "$SCRIPT_DIR/memory" ]; then
    git -C "$SCRIPT_DIR/memory" fetch origin main --quiet 2>/dev/null || true
    LOCAL=$(git -C "$SCRIPT_DIR/memory" rev-parse HEAD 2>/dev/null || echo "")
    REMOTE=$(git -C "$SCRIPT_DIR/memory" rev-parse origin/main 2>/dev/null || echo "")
    if [ -n "$LOCAL" ] && [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
      git -C "$SCRIPT_DIR/memory" pull origin main --quiet 2>/dev/null || true
    fi
  fi

  # PRs
  PRS=$(cd "$SCRIPT_DIR" && gh pr list --base develop --state open --json number,title,author 2>/dev/null || echo "[]")
  echo "$PRS" > "$TMPDIR/prs.json"

  # Disk cross-reference
  MONTH=$(date +%Y-%m)
  TODAY=$(date +%d)
  YESTERDAY=$(date -v-1d +%d 2>/dev/null || date -d 'yesterday' +%d 2>/dev/null || echo "00")
  HANDOFFS=$(ls -1 "$SCRIPT_DIR/memory/handoffs/$MONTH/" 2>/dev/null | grep "^${TODAY}-\|^${YESTERDAY}-" 2>/dev/null | head -10 || echo "")
  echo "$HANDOFFS" > "$TMPDIR/disk_handoffs.txt"

  DECISIONS=$(ls -1t "$SCRIPT_DIR/memory/knowledge/decisions/" 2>/dev/null | head -5 || echo "")
  echo "$DECISIONS" > "$TMPDIR/disk_decisions.txt"
) &

# --- Wait for all parallel jobs ---
wait

# --- Validate JSON files ---
for f in q1 q2 q3 q4 q5 q6 q7 qgap qorphans; do
  jq . "$TMPDIR/$f.json" >/dev/null 2>&1 || echo "$EMPTY" > "$TMPDIR/$f.json"
done

# --- Read git/disk results ---
PRS=$(cat "$TMPDIR/prs.json" 2>/dev/null || echo "[]")
echo "$PRS" | jq . >/dev/null 2>&1 || PRS="[]"
DISK_HANDOFFS=$(cat "$TMPDIR/disk_handoffs.txt" 2>/dev/null || echo "")
DISK_DECISIONS=$(cat "$TMPDIR/disk_decisions.txt" 2>/dev/null || echo "")

# --- Assemble single JSON output ---
jq -n \
  --arg me "$ME" \
  --arg org "$ORG" \
  --arg date "$DATE" \
  --slurpfile my_sessions "$TMPDIR/q1.json" \
  --slurpfile team_sessions "$TMPDIR/q2.json" \
  --slurpfile quests "$TMPDIR/q3.json" \
  --slurpfile pending_questions "$TMPDIR/q4.json" \
  --slurpfile answered_questions "$TMPDIR/q5.json" \
  --slurpfile handoffs_to_me "$TMPDIR/q6.json" \
  --slurpfile all_handoffs "$TMPDIR/q7.json" \
  --slurpfile knowledge_gap "$TMPDIR/qgap.json" \
  --slurpfile orphans "$TMPDIR/qorphans.json" \
  --argjson prs "$PRS" \
  --arg disk_handoffs "$DISK_HANDOFFS" \
  --arg disk_decisions "$DISK_DECISIONS" \
  '{
    me: $me,
    org: $org,
    date: $date,
    my_sessions: $my_sessions[0],
    team_sessions: $team_sessions[0],
    quests: $quests[0],
    pending_questions: $pending_questions[0],
    answered_questions: $answered_questions[0],
    handoffs_to_me: $handoffs_to_me[0],
    all_handoffs: $all_handoffs[0],
    knowledge_gap: $knowledge_gap[0],
    orphans: $orphans[0],
    prs: $prs,
    disk: {handoffs: $disk_handoffs, decisions: $disk_decisions}
  }'
