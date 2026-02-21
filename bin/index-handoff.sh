#!/bin/bash
set -euo pipefail

# Index a single handoff file into the Neo4j graph.
# Usage: bash bin/index-handoff.sh <file-path>
# Returns: {"sessionId":"...","resolved":N} or {"error":"..."}
#
# The file-path should be relative to memory/ (e.g. handoffs/2026-02/14-oz-topic.md)
# or an absolute/relative path that contains "handoffs/" somewhere in it.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Validate input ---
FILE_ARG="${1:?Usage: index-handoff.sh <handoff-file-path>}"

# Resolve to absolute path if needed
if [[ "$FILE_ARG" = /* ]]; then
  FILE_PATH="$FILE_ARG"
elif [[ "$FILE_ARG" = memory/* ]]; then
  FILE_PATH="$SCRIPT_DIR/$FILE_ARG"
else
  FILE_PATH="$SCRIPT_DIR/memory/$FILE_ARG"
fi

if [ ! -f "$FILE_PATH" ]; then
  echo '{"error":"File not found: '"$FILE_ARG"'"}'
  exit 1
fi

# --- Derive filePath (relative to memory/) and sessionId ---
REL_PATH="${FILE_PATH##*/memory/}"
if [[ "$REL_PATH" = "$FILE_PATH" ]]; then
  REL_PATH="handoffs/${FILE_PATH##*handoffs/}"
fi

FILENAME="$(basename "$FILE_PATH" .md)"
DIR_MONTH="$(basename "$(dirname "$FILE_PATH")")"

# sessionId = YYYY-MM-DD-author-topic
# If file is in a YYYY-MM subdirectory, derive from dir + filename
# If file is in root handoffs/ (no month subdir), extract date from filename
if [[ "$DIR_MONTH" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
  DAY="${FILENAME%%-*}"
  REST="${FILENAME#*-}"
  SESSION_ID="${DIR_MONTH}-${DAY}-${REST}"
else
  # Filename starts with YYYY-MM-DD — use it directly
  SESSION_ID="$FILENAME"
  DAY="$(echo "$FILENAME" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
  REST="${FILENAME#*-*-*-}"
  DIR_MONTH="$(echo "$DAY" | grep -oE '^[0-9]{4}-[0-9]{2}' || true)"
fi

# --- Parse handoff metadata from markdown ---
CONTENT="$(cat "$FILE_PATH")"

# Helper: extract from markdown headers, handles both **Key**: Value and **Key:** Value
md_extract() {
  echo "$CONTENT" | grep -m1 "$1" 2>/dev/null | sed "$2" || true
}

# Helper: extract markdown field by name (handles **Key**: and **Key:** patterns)
md_field() {
  local key="$1"
  local val
  # Try **Key**: Value (colon outside bold)
  val="$(echo "$CONTENT" | grep -m1 "^\*\*${key}\*\*:" 2>/dev/null | sed "s/\*\*${key}\*\*:[[:space:]]*//" | tr -d '\n' || true)"
  # Try **Key:** Value (colon inside bold)
  if [ -z "$val" ]; then
    val="$(echo "$CONTENT" | grep -m1 "^\*\*${key}:\*\*" 2>/dev/null | sed "s/\*\*${key}:\*\*[[:space:]]*//" | tr -d '\n' || true)"
  fi
  echo "$val"
}

# Helper: extract from YAML front matter (key: value between --- delimiters)
yaml_extract() {
  local key="$1"
  sed -n '/^---$/,/^---$/p' "$FILE_PATH" 2>/dev/null | grep -m1 "^${key}:" 2>/dev/null | sed "s/^${key}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | xargs 2>/dev/null || true
}

# H1 topic (always from markdown body, not front matter)
TOPIC="$(md_extract '^# ' 's/^# //; s/^Handoff: //')"
# Also check YAML front matter topic
[ -z "$TOPIC" ] && TOPIC="$(yaml_extract 'topic')"
[ -z "$TOPIC" ] && TOPIC="$REST"

# Date: try markdown header, then YAML
DATE="$(md_field 'Date')"
[ -z "$DATE" ] && DATE="$(yaml_extract 'date')"
[ -z "$DATE" ] && DATE="${DIR_MONTH}-${DAY}"

# Author: try markdown header (Author or From), then YAML (author or from)
AUTHOR="$(md_field 'Author')"
[ -z "$AUTHOR" ] && AUTHOR="$(md_field 'From')"
[ -z "$AUTHOR" ] && AUTHOR="$(yaml_extract 'author')"
[ -z "$AUTHOR" ] && AUTHOR="$(yaml_extract 'from')"
# Strip " → recipient" if present (e.g. "cem → oz" → "cem")
AUTHOR_HANDLE="$(echo "$AUTHOR" | sed 's/[[:space:]]*→.*//' | awk '{print tolower($1)}')"
[ -z "$AUTHOR_HANDLE" ] && AUTHOR_HANDLE="unknown"

# Recipients: try markdown header (To or For), then YAML (to or for)
RECIPIENTS_RAW="$(md_field 'To')"
[ -z "$RECIPIENTS_RAW" ] && RECIPIENTS_RAW="$(md_field 'For')"
[ -z "$RECIPIENTS_RAW" ] && RECIPIENTS_RAW="$(yaml_extract 'to')"
[ -z "$RECIPIENTS_RAW" ] && RECIPIENTS_RAW="$(yaml_extract 'for')"
# Also extract from "From: author → recipient" pattern
if [ -z "$RECIPIENTS_RAW" ] && echo "$AUTHOR" | grep -q '→' 2>/dev/null; then
  RECIPIENTS_RAW="$(echo "$AUTHOR" | sed 's/.*→[[:space:]]*//')"
fi

# Project: try markdown header, then YAML
PROJECT="$(md_field 'Project')"
[ -z "$PROJECT" ] && PROJECT="$(yaml_extract 'project')"

# Summary: first non-empty paragraph after ## Session Summary
SUMMARY="$(echo "$CONTENT" | awk '/^## Session Summary/{found=1; next} found && /^[^#]/ && !/^[[:space:]]*$/{print; exit}' || true)"
[ -z "$SUMMARY" ] && SUMMARY="$TOPIC"

# --- Build Cypher queries ---

# Q1: MERGE Session + relationships
HANDED_TO_CYPHER=""
RECIPIENT_PARAMS=""
if [ -n "$RECIPIENTS_RAW" ]; then
  IFS=',' read -ra RECIPS <<< "$RECIPIENTS_RAW"
  for i in "${!RECIPS[@]}"; do
    R="$(echo "${RECIPS[$i]}" | xargs | tr '[:upper:]' '[:lower:]')"
    [ -z "$R" ] && continue
    HANDED_TO_CYPHER="${HANDED_TO_CYPHER}
WITH s
OPTIONAL MATCH (r${i}:Person) WHERE toLower(r${i}.name) = \$recipient${i} OR r${i}.github = \$recipient${i} OR toLower(r${i}.fullName) = \$recipient${i}
FOREACH (_ IN CASE WHEN r${i} IS NOT NULL THEN [1] ELSE [] END |
  MERGE (s)-[:HANDED_TO]->(r${i})
)"
    RECIPIENT_PARAMS="${RECIPIENT_PARAMS}, \"recipient${i}\": \"${R}\""
  done
fi

PROJECT_CYPHER=""
PROJECT_PARAM=""
if [ -n "$PROJECT" ]; then
  PROJECT_CYPHER="
WITH s
OPTIONAL MATCH (proj:Project) WHERE toLower(proj.name) = toLower(\$project)
FOREACH (_ IN CASE WHEN proj IS NOT NULL THEN [1] ELSE [] END |
  MERGE (s)-[:ABOUT]->(proj)
)"
  PROJECT_PARAM=", \"project\": \"${PROJECT}\""
fi

Q1_CYPHER="MATCH (p:Person) WHERE toLower(p.name) = \$author OR p.github = \$author OR toLower(p.fullName) = \$author
MERGE (s:Session {id: \$sessionId})
ON CREATE SET s.date = date(\$date), s.topic = \$topic, s.summary = \$summary, s.filePath = \$filePath, s.handoffStatus = 'pending'
ON MATCH SET s.topic = \$topic, s.summary = \$summary, s.filePath = \$filePath
MERGE (s)-[:BY]->(p)${PROJECT_CYPHER}${HANDED_TO_CYPHER}
RETURN s.id AS sessionId"

Q1_PARAMS="{\"sessionId\": \"${SESSION_ID}\", \"author\": \"${AUTHOR_HANDLE}\", \"date\": \"${DATE}\", \"topic\": $(printf '%s' "$TOPIC" | jq -Rs .), \"summary\": $(printf '%s' "$SUMMARY" | jq -Rs .), \"filePath\": \"${REL_PATH}\"${PROJECT_PARAM}${RECIPIENT_PARAMS}}"

# Q2: Auto-resolve old read handoffs from this author
Q2_CYPHER="MATCH (s:Session)-[:HANDED_TO]->(p:Person) WHERE (toLower(p.name) = \$author OR p.github = \$author OR toLower(p.fullName) = \$author) AND s.handoffStatus = 'read' AND s.id <> \$sessionId
WITH s, p, coalesce(s.handoffReadDate, s.date) AS sinceDate
MATCH (later:Session)-[:BY]->(p)
WHERE later.date > sinceDate
WITH s, count(later) AS laterSessions WHERE laterSessions > 0
SET s.handoffStatus = 'done'
RETURN count(s) AS resolved"

Q2_PARAMS="{\"author\": \"${AUTHOR_HANDLE}\", \"sessionId\": \"${SESSION_ID}\"}"

# --- Build batch request ---
BATCH_JSON=$(jq -n \
  --arg q1 "$Q1_CYPHER" \
  --argjson p1 "$Q1_PARAMS" \
  --arg q2 "$Q2_CYPHER" \
  --argjson p2 "$Q2_PARAMS" \
  '[{statement: $q1, parameters: $p1}, {statement: $q2, parameters: $p2}]')

# --- Execute ---
RESPONSE=$(bash "$SCRIPT_DIR/bin/graph-batch.sh" "$BATCH_JSON" 2>/dev/null) || {
  echo '{"error":"graph-batch.sh failed"}'
  exit 1
}

# --- Mark auto-captured personal Session as handed_off ---
PROJ_HASH=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
CURRENT_SID=$(cat "$HOME/.egregore/session-${PROJ_HASH}.id" 2>/dev/null || echo "")
if [ -n "$CURRENT_SID" ]; then
  bash "$SCRIPT_DIR/bin/graph.sh" query \
    "MATCH (s:Session {id: \$sid}) SET s.status = 'handed_off' RETURN s.id" \
    "{\"sid\":\"$CURRENT_SID\"}" 2>/dev/null || true
fi

# --- Parse response ---
RESOLVED=$(echo "$RESPONSE" | jq -r '.results[1].values[0][0] // 0' 2>/dev/null || echo "0")

echo "{\"sessionId\":\"${SESSION_ID}\",\"resolved\":${RESOLVED}}"
