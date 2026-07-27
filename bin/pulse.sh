#!/usr/bin/env bash
set -euo pipefail

# Pulse spirit — post-session synthesis.
# Reads transcript + observation buffer + graph context, calls Sonnet for synthesis,
# writes edges + brief back to graph.
#
# Runs in background from transcript-archive.sh. Must not block session exit.
#
# Usage: bash bin/pulse.sh <session-id> <author-github> <branch> <obs-buffer-path> <transcript-path>

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: pulse.sh <session-id> <author-github> <branch> <obs-buffer> <transcript>"
  echo ""
  echo "Post-session synthesis spirit. Reads transcript + observation buffer"
  echo "+ graph context, calls Sonnet for synthesis, writes CONTINUES/INVOLVES"
  echo "edges and personal brief back to the graph."
  echo ""
  echo "Normally run in background by transcript-archive.sh at session exit."
  exit 0
fi

# Suppress stdout, log errors to .pulse/errors.log
mkdir -p "$(cd "$(dirname "$0")/.." && pwd)/.pulse" 2>/dev/null
exec 2>> "$(cd "$(dirname "$0")/.." && pwd)/.pulse/errors.log"
exec 1>/dev/null

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"
GS="$SCRIPT_DIR/bin/graph.sh"
GB="$SCRIPT_DIR/bin/graph-batch.sh"
WAL="$SCRIPT_DIR/bin/graph-wal.sh"
NOTIFY="$SCRIPT_DIR/bin/notify.sh"
TELEMETRY="$SCRIPT_DIR/bin/telemetry.sh"

# --- Args ---
SESSION_ID="${1:-}"
AUTHOR_GH="${2:-}"
BRANCH="${3:-}"
OBS_BUFFER="${4:-}"
TRANSCRIPT_PATH="${5:-}"

if [ -z "$SESSION_ID" ] || [ -z "$AUTHOR_GH" ]; then
  exit 0
fi

# --- Feature flag ---
PULSE_ENABLED=$(jq -r '.features.pulse // "true"' "$CONFIG" 2>/dev/null || echo "true")
if [ "$PULSE_ENABLED" != "true" ]; then
  exit 0
fi

# --- Check consent (respect telemetry opt-out) ---
STATE_FILE="$SCRIPT_DIR/.egregore-state.json"
if [ -f "$STATE_FILE" ]; then
  TELEMETRY_OPT=$(jq -r '.telemetry // "true"' "$STATE_FILE" 2>/dev/null || echo "true")
  if [ "$TELEMETRY_OPT" = "false" ]; then
    exit 0
  fi
fi

# --- Read config ---
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

ENV_FILE="$SCRIPT_DIR/.env"
API_URL=$(jq -r '.api_url // empty' "$CONFIG")
API_KEY=""
if [ -f "$ENV_FILE" ]; then
  API_KEY=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)
  _url=$(grep '^EGREGORE_API_URL=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)
  [ -n "$_url" ] && API_URL="$_url"
fi

if [ -z "$API_URL" ] || [ -z "$API_KEY" ]; then
  exit 0
fi

START_MS=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo "0")

# Dedup guard — atomic mkdir prevents duplicate runs on hook retries
PULSE_LOCK="/tmp/egregore-pulse-lock-${SESSION_ID}"
mkdir "$PULSE_LOCK" 2>/dev/null || exit 0

# Sweep marker — periodic sweep can detect un-pulsed sessions by absence
PULSE_MARKER="/tmp/egregore-pulsed-${SESSION_ID}"

# --- 1. Read observation buffer ---
OBS_TOOLS='[]'
OBS_PATHS='[]'
OBS_COUNT=0

if [ -n "$OBS_BUFFER" ] && [ -f "$OBS_BUFFER" ] && [ -s "$OBS_BUFFER" ]; then
  OBS_COUNT=$(wc -l < "$OBS_BUFFER" | tr -d ' ')
  OBS_TOOLS=$(awk -F'"tool":"' '{print $2}' "$OBS_BUFFER" | cut -d'"' -f1 | sort -u | jq -R . | jq -s '.' 2>/dev/null || echo '[]')
  OBS_PATHS=$(awk -F'"path":"' '{print $2}' "$OBS_BUFFER" | cut -d'"' -f1 | sort -u | head -30 | jq -R . | jq -s '.' 2>/dev/null || echo '[]')
fi

# Buffer cleanup is handled by transcript-archive.sh — don't delete here

# --- 2. Query graph context (batch: 3 queries in 1 roundtrip) ---
GRAPH_CTX=$(bash "$GB" "$(cat <<BATCHEOF
[
  {"statement": "MATCH (s:Session {id: \$sid})-[:BY]->(p:Person) RETURN s.topic AS topic, s.summary AS summary, p.name AS name, p.github AS github", "parameters": {"sid": "$SESSION_ID"}},
  {"statement": "MATCH (s:Session)-[:BY]->(p:Person {github: \$gh}) WHERE s.id <> \$sid AND s.date >= date() - duration('P7D') RETURN s.id AS id, s.topic AS topic, s.summary AS summary, toString(s.date) AS date ORDER BY s.date DESC LIMIT 5", "parameters": {"gh": "$AUTHOR_GH", "sid": "$SESSION_ID"}},
  {"statement": "MATCH (s:Session)-[:BY]->(p:Person) WHERE p.github <> \$gh AND s.date >= date() - duration('P7D') AND s.topic IS NOT NULL RETURN s.id AS id, s.topic AS topic, p.name AS author, toString(s.date) AS date ORDER BY s.date DESC LIMIT 5", "parameters": {"gh": "$AUTHOR_GH"}},
  {"statement": "MATCH (q:Quest) WHERE q.status IN ['active', 'in-progress'] RETURN q.id AS id, q.title AS title, q.topics AS topics LIMIT 10", "parameters": {}}
]
BATCHEOF
)" 2>/dev/null || echo '{"results":[]}')

# Parse graph context
SESSION_TOPIC=$(echo "$GRAPH_CTX" | jq -r '.results[0].values[0][0] // empty' 2>/dev/null || true)
SESSION_SUMMARY=$(echo "$GRAPH_CTX" | jq -r '.results[0].values[0][1] // empty' 2>/dev/null || true)
AUTHOR_NAME=$(echo "$GRAPH_CTX" | jq -r '.results[0].values[0][2] // empty' 2>/dev/null || true)

# Build related_sessions array
RELATED_SESSIONS=$(echo "$GRAPH_CTX" | jq -c '[.results[1].values[]? | {id: .[0], topic: .[1], summary: .[2], date: .[3]}]' 2>/dev/null || echo '[]')

# Build other_sessions array
OTHER_SESSIONS=$(echo "$GRAPH_CTX" | jq -c '[.results[2].values[]? | {id: .[0], topic: .[1], author: .[2], date: .[3]}]' 2>/dev/null || echo '[]')

# Build active_quests array
ACTIVE_QUESTS=$(echo "$GRAPH_CTX" | jq -c '[.results[3].values[]? | {id: .[0], title: .[1], topics: .[2]}]' 2>/dev/null || echo '[]')

# --- 3. Build payload — Sonnet 4.6 with full transcript context ---

# Read transcript content (the key context for synthesis)
TRANSCRIPT_CONTENT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Read transcript, extract user/assistant messages, cap at ~100K tokens (~400KB text)
  TRANSCRIPT_CONTENT=$(jq -r 'select(.type == "human" or .type == "assistant") | "\(.type): \(.message.content // .content // "" | if type == "array" then map(.text // "") | join(" ") else tostring end)"' "$TRANSCRIPT_PATH" 2>/dev/null | head -c 400000 || true)
fi

# Raw observation lines (buffer is still available — we no longer delete it)
OBS_RAW='[]'
if [ -n "$OBS_BUFFER" ] && [ -f "$OBS_BUFFER" ]; then
  OBS_RAW=$(tail -100 "$OBS_BUFFER" 2>/dev/null | jq -R . | jq -s '.' 2>/dev/null || echo '[]')
fi

PAYLOAD=$(jq -n -c \
  --arg sid "$SESSION_ID" \
  --arg author "$AUTHOR_GH" \
  --arg topic "${SESSION_TOPIC:-}" \
  --arg branch "${BRANCH:-}" \
  --argjson tools_used "$OBS_TOOLS" \
  --argjson files_touched "$OBS_PATHS" \
  --argjson tool_count "${OBS_COUNT:-0}" \
  --argjson related_sessions "$RELATED_SESSIONS" \
  --argjson other_sessions "$OTHER_SESSIONS" \
  --argjson active_quests "$ACTIVE_QUESTS" \
  --argjson obs_raw "$OBS_RAW" \
  --arg transcript "$TRANSCRIPT_CONTENT" \
  '{
    session_id: $sid,
    author: $author,
    topic: $topic,
    branch: $branch,
    tools_used: $tools_used,
    files_touched: $files_touched,
    tool_count: $tool_count,
    related_sessions: $related_sessions,
    other_sessions: $other_sessions,
    active_quests: $active_quests,
    obs_raw: $obs_raw,
    transcript: $transcript
  }')

RESPONSE=$(curl -sf -X POST "${API_URL}/api/spirits/pulse" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --max-time 120 2>/dev/null || echo '{"edges":[],"signals":[],"brief":""}')

# Validate JSON
if ! echo "$RESPONSE" | jq -e '.edges' >/dev/null 2>&1; then
  bash "$TELEMETRY" emit "pulse_error" '{"error":"malformed_response"}' 2>/dev/null &
  exit 0
fi

# --- 3b. Store full response + payload for analysis ---
PULSE_LOG_DIR="$SCRIPT_DIR/.pulse"
mkdir -p "$PULSE_LOG_DIR" 2>/dev/null
jq -n -c --arg sid "$SESSION_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson payload "$PAYLOAD" --argjson response "$RESPONSE" \
  '{session_id: $sid, timestamp: $ts, payload: $payload, response: $response}' \
  >> "$PULSE_LOG_DIR/runs.jsonl" 2>/dev/null

# --- 4. Write edges to graph ---
EDGE_COUNT=0
EDGES=$(echo "$RESPONSE" | jq -c '.edges // []')

for i in $(seq 0 $(($(echo "$EDGES" | jq 'length') - 1)) 2>/dev/null); do
  TYPE=$(echo "$EDGES" | jq -r ".[$i].type" 2>/dev/null)
  TARGET=$(echo "$EDGES" | jq -r ".[$i].target_id" 2>/dev/null)
  CONFIDENCE=$(echo "$EDGES" | jq -r ".[$i].confidence // 0.7" 2>/dev/null)

  [ -z "$TYPE" ] || [ -z "$TARGET" ] && continue

  case "$TYPE" in
    CONTINUES)
      CYPHER="MATCH (s1:Session {id: \$sid}), (s2:Session {id: \$target})
        MERGE (s1)-[r:CONTINUES]->(s2)
        SET r.confidence = toFloat(\$conf), r.createdAt = datetime(), r.createdBy = 'pulse'
        RETURN s1.id, s2.id"
      PARAMS=$(jq -n -c --arg sid "$SESSION_ID" --arg target "$TARGET" --arg conf "$CONFIDENCE" \
        '{sid: $sid, target: $target, conf: $conf}')
      bash "$WAL" append "$CYPHER" "$PARAMS" 2>/dev/null || true
      bash "$GS" query "$CYPHER" "$PARAMS" 2>/dev/null || true
      EDGE_COUNT=$((EDGE_COUNT + 1))
      ;;
    INVOLVES)
      # INVOLVES edges are proposed, not confirmed — surfaced at next session start
      CYPHER="MATCH (s:Session {id: \$sid}), (q:Quest {id: \$target})
        MERGE (s)-[r:INVOLVES]->(q)
        SET r.confidence = toFloat(\$conf), r.createdAt = datetime(), r.createdBy = 'pulse',
            r.proposed = true
        RETURN s.id, q.id"
      PARAMS=$(jq -n -c --arg sid "$SESSION_ID" --arg target "$TARGET" --arg conf "$CONFIDENCE" \
        '{sid: $sid, target: $target, conf: $conf}')
      bash "$WAL" append "$CYPHER" "$PARAMS" 2>/dev/null || true
      bash "$GS" query "$CYPHER" "$PARAMS" 2>/dev/null || true
      EDGE_COUNT=$((EDGE_COUNT + 1))
      ;;
  esac
done

# --- 5. Store brief + recommendations on Person node ---
BRIEF=$(echo "$RESPONSE" | jq -r '.brief // empty' 2>/dev/null)
RECOMMENDATIONS=$(echo "$RESPONSE" | jq -c '.recommendations // []' 2>/dev/null)
if [ -n "$BRIEF" ] && [ "$BRIEF" != "null" ]; then
  BRIEF_CYPHER="MATCH (p:Person {github: \$gh})
    SET p.lastBrief = \$brief, p.lastBriefDate = date(), p.lastBriefSession = \$sid,
        p.lastRecommendations = \$recs
    RETURN p.name"
  BRIEF_PARAMS=$(jq -n -c --arg gh "$AUTHOR_GH" --arg brief "$BRIEF" --arg sid "$SESSION_ID" \
    --argjson recs "$RECOMMENDATIONS" \
    '{gh: $gh, brief: $brief, sid: $sid, recs: $recs}')
  bash "$WAL" append "$BRIEF_CYPHER" "$BRIEF_PARAMS" 2>/dev/null || true
  bash "$GS" query "$BRIEF_CYPHER" "$BRIEF_PARAMS" 2>/dev/null || true
fi

# --- 6. Count signals (notifications disabled for now) ---
SIGNAL_COUNT=$(echo "$RESPONSE" | jq '.signals | length' 2>/dev/null || echo "0")

# --- 7. Telemetry ---
END_MS=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo "0")
DURATION_MS=$((END_MS - START_MS))

bash "$TELEMETRY" emit "pulse" \
  "$(jq -n -c --argjson edges "$EDGE_COUNT" --argjson signals "$SIGNAL_COUNT" --argjson dur "$DURATION_MS" \
    '{edges: $edges, signals: $signals, duration_ms: $dur}')" 2>/dev/null &

# Mark session as pulsed (sweep can detect un-pulsed sessions by absence)
touch "$PULSE_MARKER" 2>/dev/null

exit 0
