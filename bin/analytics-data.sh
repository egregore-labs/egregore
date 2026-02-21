#!/bin/bash
# Fetches org-level analytics data (AM1-AM10) in parallel.
# Usage: bash bin/analytics-data.sh [username]
# Returns a single JSON object with all analytics metrics.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GS="$SCRIPT_DIR/bin/graph.sh"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# --- Detect user ---
ME="${1:-}"
if [ -z "$ME" ]; then
  FULL_NAME=$(git -C "$SCRIPT_DIR" config user.name 2>/dev/null || echo "unknown")
  # Derive short handle from git name (lowercase first word)
  ME=$(echo "$FULL_NAME" | tr '[:upper:]' '[:lower:]' | cut -d' ' -f1)
fi

ORG=$(jq -r '.org_name // "Egregore"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "Egregore")
DATE=$(date '+%b %d')
EMPTY='{"fields":[],"values":[]}'

# --- Fire all 10 analytics queries in parallel ---

# AM1: Session cadence per person (4 weeks)
bash "$GS" query "
MATCH (s:Session)-[:BY]->(p:Person)
WHERE date(s.date) >= date() - duration('P28D')
WITH p.name AS person,
     duration.inDays(date(s.date), date()).days / 7 AS weeksAgo,
     count(s) AS sessions
RETURN person, weeksAgo, sessions
ORDER BY person, weeksAgo" > "$TMPDIR/am1.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/am1.json" &

# AM2: Handoff resolution time distribution
bash "$GS" query "
MATCH (s:Session)-[:HANDED_TO]->(p:Person)
WHERE s.handoffStatus = 'done' AND date(s.date) >= date() - duration('P30D')
WITH p.name AS recipient,
     duration.inDays(date(s.date), date()).days AS daysAgo,
     CASE WHEN s.handoffReadDate IS NOT NULL
       THEN duration.inDays(date(s.date), date(s.handoffReadDate)).days
       ELSE null END AS resolutionDays
WHERE resolutionDays IS NOT NULL
RETURN recipient,
       avg(resolutionDays) AS avgDays,
       min(resolutionDays) AS minDays,
       max(resolutionDays) AS maxDays,
       count(*) AS total
ORDER BY recipient" > "$TMPDIR/am2.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/am2.json" &

# AM3: Quest velocity — artifacts per week per active quest
bash "$GS" query "
MATCH (q:Quest {status: 'active'})
OPTIONAL MATCH (a:Artifact)-[:PART_OF]->(q)
WHERE a.created >= datetime() - duration('P28D')
WITH q.id AS quest, q.title AS title,
     CASE WHEN a IS NOT NULL
       THEN duration.inDays(date(a.created), date()).days / 7
       ELSE null END AS weeksAgo,
     count(a) AS artifacts
RETURN quest, title, weeksAgo, artifacts
ORDER BY quest, weeksAgo" > "$TMPDIR/am3.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/am3.json" &

# AM4: Collaboration density — person pairs sharing quest contributions
bash "$GS" query "
MATCH (a1:Artifact)-[:CONTRIBUTED_BY]->(p1:Person),
      (a2:Artifact)-[:CONTRIBUTED_BY]->(p2:Person),
      (a1)-[:PART_OF]->(q:Quest),
      (a2)-[:PART_OF]->(q)
WHERE p1.name < p2.name
RETURN p1.name AS person1, p2.name AS person2,
       count(DISTINCT q) AS sharedQuests
ORDER BY sharedQuests DESC" > "$TMPDIR/am4.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/am4.json" &

# AM5: Todo health snapshot — status counts per person
bash "$GS" query "
MATCH (t:Todo)-[:BY]->(p:Person)
WHERE t.status IN ['open', 'blocked', 'deferred', 'done']
WITH p.name AS person, t.status AS status, count(t) AS cnt,
     CASE WHEN t.status = 'blocked' AND t.lastTransitionDate <= datetime() - duration('P3D')
       THEN 1 ELSE 0 END AS isStale
RETURN person, status, sum(cnt) AS count, sum(isStale) AS staleCount
ORDER BY person, status" > "$TMPDIR/am5.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/am5.json" &

# AM6: Todo throughput — created vs completed per week per person (28d)
bash "$GS" query "
MATCH (t:Todo)-[:BY]->(p:Person)
WHERE t.created >= datetime() - duration('P28D') OR
      (t.status = 'done' AND t.lastTransitionDate >= datetime() - duration('P28D'))
WITH p.name AS person,
     CASE WHEN t.created >= datetime() - duration('P28D')
       THEN duration.inDays(date(t.created), date()).days / 7
       ELSE null END AS createdWeek,
     CASE WHEN t.status = 'done' AND t.lastTransitionDate >= datetime() - duration('P28D')
       THEN duration.inDays(date(t.lastTransitionDate), date()).days / 7
       ELSE null END AS doneWeek
RETURN person,
       createdWeek, count(CASE WHEN createdWeek IS NOT NULL THEN 1 END) AS created,
       doneWeek, count(CASE WHEN doneWeek IS NOT NULL THEN 1 END) AS completed
ORDER BY person" > "$TMPDIR/am6.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/am6.json" &

# AM7: Knowledge capture ratio — sessions with same-day artifacts / total (28d)
bash "$GS" query "
MATCH (s:Session)-[:BY]->(p:Person)
WHERE date(s.date) >= date() - duration('P28D')
OPTIONAL MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p)
WHERE a.created >= datetime({year: s.date.year, month: s.date.month, day: s.date.day})
  AND a.created < datetime({year: s.date.year, month: s.date.month, day: s.date.day}) + duration('P1D')
WITH p.name AS person, s, count(a) AS artifactCount
WITH person,
     count(s) AS totalSessions,
     count(CASE WHEN artifactCount > 0 THEN 1 END) AS capturedSessions
RETURN person, totalSessions, capturedSessions,
       CASE WHEN totalSessions > 0
         THEN round(toFloat(capturedSessions) / toFloat(totalSessions) * 100) / 100
         ELSE 0.0 END AS ratio
ORDER BY person" > "$TMPDIR/am7.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/am7.json" &

# AM8: Question response time — avg days to answer per person
bash "$GS" query "
MATCH (qs:QuestionSet {status: 'answered'})-[:ASKED_TO]->(p:Person)
WHERE qs.created >= datetime() - duration('P30D')
WITH p.name AS person,
     count(qs) AS answered,
     avg(duration.inDays(date(qs.created), date()).days) AS avgResponseDays
RETURN person, answered, avgResponseDays
ORDER BY person" > "$TMPDIR/am8.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/am8.json" &

# AM9: Check-in frequency — check-ins per person with totals
bash "$GS" query "
MATCH (c:CheckIn)-[:BY]->(p:Person)
WHERE date(c.date) >= date() - duration('P28D')
RETURN p.name AS person, count(c) AS checkIns,
       sum(c.totalItems) AS totalReviewed
ORDER BY person" > "$TMPDIR/am9.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/am9.json" &

# AM10: Issue/todo lifecycle — status distribution, who creates most
bash "$GS" query "
MATCH (t:Todo)-[:BY]->(p:Person)
WITH t.status AS status, p.name AS creator, count(t) AS cnt
RETURN status, creator, cnt
ORDER BY status, cnt DESC" > "$TMPDIR/am10.json" 2>/dev/null || echo "$EMPTY" > "$TMPDIR/am10.json" &

# --- Wait for all parallel jobs ---
wait

# --- Validate JSON files ---
for f in am1 am2 am3 am4 am5 am6 am7 am8 am9 am10; do
  jq . "$TMPDIR/$f.json" >/dev/null 2>&1 || echo "$EMPTY" > "$TMPDIR/$f.json"
done

# --- Assemble single JSON output ---
jq -n \
  --arg me "$ME" \
  --arg org "$ORG" \
  --arg date "$DATE" \
  --slurpfile cadence "$TMPDIR/am1.json" \
  --slurpfile resolution "$TMPDIR/am2.json" \
  --slurpfile quest_velocity "$TMPDIR/am3.json" \
  --slurpfile collaboration_density "$TMPDIR/am4.json" \
  --slurpfile todo_health "$TMPDIR/am5.json" \
  --slurpfile todo_throughput "$TMPDIR/am6.json" \
  --slurpfile capture_ratio "$TMPDIR/am7.json" \
  --slurpfile question_response "$TMPDIR/am8.json" \
  --slurpfile checkin_frequency "$TMPDIR/am9.json" \
  --slurpfile issue_lifecycle "$TMPDIR/am10.json" \
  '{
    me: $me,
    org: $org,
    date: $date,
    cadence: $cadence[0],
    resolution: $resolution[0],
    quest_velocity: $quest_velocity[0],
    collaboration_density: $collaboration_density[0],
    todo_health: $todo_health[0],
    todo_throughput: $todo_throughput[0],
    capture_ratio: $capture_ratio[0],
    question_response: $question_response[0],
    checkin_frequency: $checkin_frequency[0],
    issue_lifecycle: $issue_lifecycle[0]
  }'
