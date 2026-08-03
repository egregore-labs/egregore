#!/usr/bin/env bash
set -euo pipefail

# Index a single handoff file into the Neo4j graph.
# Usage: bash bin/index-handoff.sh <file-path>
# Returns: {"sessionId":"...","resolved":0} or {"error":"..."}.
# `resolved` remains for compatibility; lifecycle reconciliation is queued by
# capture-run.sh after indexing.
#
# The file-path should be relative to memory/ (e.g. handoffs/2026-02/14-oz-topic.md)
# or an absolute/relative path that contains "handoffs/" somewhere in it.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: index-handoff.sh <handoff-file-path>"
  echo ""
  echo "Index a single handoff file into the Neo4j graph."
  echo "Parses metadata (author, date, topic, recipients) from"
  echo "markdown headers or YAML front matter, creates Session"
  echo "and relationship nodes. Lifecycle completion is queued separately."
  echo ""
  echo "Returns: {\"sessionId\":\"...\",\"resolved\":N}"
  exit 0
fi

# --- Local mode gate: bail immediately ---
_MODE=$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
if [ "$_MODE" = "local" ]; then
  echo '{"sessionId":"","resolved":0,"mode":"local"}'
  exit 0
fi

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

# Recipients: try markdown header, then canonical/legacy YAML names.
RECIPIENTS_RAW="$(md_field 'To')"
[ -z "$RECIPIENTS_RAW" ] && RECIPIENTS_RAW="$(md_field 'For')"
[ -z "$RECIPIENTS_RAW" ] && RECIPIENTS_RAW="$(yaml_extract 'to')"
[ -z "$RECIPIENTS_RAW" ] && RECIPIENTS_RAW="$(yaml_extract 'for')"
[ -z "$RECIPIENTS_RAW" ] && RECIPIENTS_RAW="$(yaml_extract 'addressed_to')"
# Also extract from "From: author → recipient" pattern
if [ -z "$RECIPIENTS_RAW" ] && echo "$AUTHOR" | grep -q '→' 2>/dev/null; then
  RECIPIENTS_RAW="$(echo "$AUTHOR" | sed 's/.*→[[:space:]]*//')"
fi

# Project: try markdown header, then YAML
PROJECT="$(md_field 'Project')"
[ -z "$PROJECT" ] && PROJECT="$(yaml_extract 'project')"

# Handoff kind: used by readers to distinguish automatic captures from manual handoffs.
KIND="$(md_field 'Kind')"
[ -z "$KIND" ] && KIND="$(yaml_extract 'kind')"

# Lifecycle intent determines which automatic transitions are safe.
INTENT="$(md_field 'Intent')"
[ -z "$INTENT" ] && INTENT="$(yaml_extract 'intent')"
INTENT="$(printf '%s' "${INTENT:-unclassified}" | tr '[:upper:]' '[:lower:]')"
case "$INTENT" in
  action|feedback|fyi|unclassified) ;;
  *) INTENT="unclassified" ;;
esac

# Summary: 5-level precedence chain
# 1. Frontmatter summary field
SUMMARY="$(yaml_extract 'summary')"
# 2. First non-empty paragraph after ## Briefing
[ -z "$SUMMARY" ] && SUMMARY="$(echo "$CONTENT" | awk '/^## Briefing/{found=1; next} found && /^#/{exit} found && /^[^#]/ && !/^[[:space:]]*$/{print; exit}' || true)"
# 3. First non-empty paragraph after ## Session Summary (legacy)
[ -z "$SUMMARY" ] && SUMMARY="$(echo "$CONTENT" | awk '/^## Session Summary/{found=1; next} found && /^#/{exit} found && /^[^#]/ && !/^[[:space:]]*$/{print; exit}' || true)"
# 4. First non-heading, non-metadata, non-empty line in body
[ -z "$SUMMARY" ] && SUMMARY="$(echo "$CONTENT" | awk '!/^[[:space:]]*$/ && !/^#/ && !/^\*\*/ && !/^---/ && !/^\|/ && !/^- /{print; exit}' || true)"
# 5. Topic fallback
[ -z "$SUMMARY" ] && SUMMARY="$TOPIC"

# Repo State: parse markdown table after "## Repo State"
# Extracts repo, branch, PR number, and base branch from each table row
REPO_STATE_JSON="[]"
REPO_TABLE=$(echo "$CONTENT" | awk '/^## Repo State/{found=1; next} found && /^#/{exit} found && /^\|[^-]/ && !/^\| Repo/{print}' || true)
if [ -n "$REPO_TABLE" ]; then
  REPO_STATE_JSON=$(echo "$REPO_TABLE" | while IFS='|' read -r _ R_REPO R_BRANCH R_PR R_BASE _; do
    R_REPO=$(echo "$R_REPO" | xargs 2>/dev/null || true)
    R_BRANCH=$(echo "$R_BRANCH" | xargs 2>/dev/null || true)
    R_PR=$(echo "$R_PR" | xargs 2>/dev/null | sed 's/^#//' | sed 's/—//' || true)
    R_BASE=$(echo "$R_BASE" | xargs 2>/dev/null || true)
    [ -z "$R_REPO" ] && continue
    if [ -n "$R_PR" ] && [ "$R_PR" -eq "$R_PR" ] 2>/dev/null; then
      jq -n --arg repo "$R_REPO" --arg branch "$R_BRANCH" --argjson pr "$R_PR" --arg base "$R_BASE" \
        '{repo:$repo, branch:$branch, pr:$pr, base:$base}'
    else
      jq -n --arg repo "$R_REPO" --arg branch "$R_BRANCH" --arg base "$R_BASE" \
        '{repo:$repo, branch:$branch, pr:null, base:$base}'
    fi
  done | jq -s '.' 2>/dev/null || echo "[]")
fi

# --- Build Cypher queries ---

# Q1: MERGE Session + relationships
HANDED_TO_CYPHER=""
_RECIP_ARGS=()
if [ -n "$RECIPIENTS_RAW" ]; then
  IFS=',' read -ra RECIPS <<< "$RECIPIENTS_RAW"
  for i in "${!RECIPS[@]}"; do
    R="$(echo "${RECIPS[$i]}" | xargs | tr '[:upper:]' '[:lower:]')"
    [ -z "$R" ] && continue
    HANDED_TO_CYPHER="${HANDED_TO_CYPHER}
WITH s
OPTIONAL MATCH (r${i}:Person) WHERE toLower(r${i}.name) = \$recipient${i} OR toLower(r${i}.github) = \$recipient${i} OR toLower(r${i}.fullName) = \$recipient${i} OR \$recipient${i} IN [x IN coalesce(r${i}.previousNames, []) | toLower(x)] OR \$recipient${i} IN [x IN coalesce(r${i}.githubAliases, []) | toLower(x)] OR \$recipient${i} IN [x IN coalesce(r${i}.emails, []) | toLower(x)]
FOREACH (_ IN CASE WHEN r${i} IS NOT NULL THEN [1] ELSE [] END |
  MERGE (s)-[:HANDED_TO]->(r${i})
)"
    _RECIP_ARGS+=("--arg" "recipient${i}" "$R")
  done
fi

PROJECT_CYPHER=""
_PROJECT_ARGS=()
if [ -n "$PROJECT" ]; then
  PROJECT_CYPHER="
WITH s
OPTIONAL MATCH (proj:Project) WHERE toLower(proj.name) = toLower(\$project)
FOREACH (_ IN CASE WHEN proj IS NOT NULL THEN [1] ELSE [] END |
  MERGE (s)-[:ABOUT]->(proj)
)"
  _PROJECT_ARGS=("--arg" "project" "$PROJECT")
fi

Q1_CYPHER="MATCH (p:Person) WHERE toLower(p.name) = \$author OR toLower(p.github) = \$author OR toLower(p.fullName) = \$author OR \$author IN [x IN coalesce(p.previousNames, []) | toLower(x)] OR \$author IN [x IN coalesce(p.githubAliases, []) | toLower(x)] OR \$author IN [x IN coalesce(p.emails, []) | toLower(x)]
MERGE (s:Session {id: \$sessionId})
ON CREATE SET s.date = date(\$date), s.topic = \$topic, s.summary = \$summary, s.filePath = \$filePath, s.author = \$author, s.handoffKind = CASE WHEN \$kind = '' THEN null ELSE \$kind END, s.handoffStatus = 'pending', s.handoffIntent = \$intent, s.handoffLifecycleVersion = 1, s.repoState = \$repoState, s.startedAt = datetime(\$date + 'T00:00:00Z')
ON MATCH SET s.topic = \$topic, s.summary = \$summary, s.filePath = \$filePath, s.author = \$author, s.handoffKind = CASE WHEN \$kind = '' THEN null ELSE \$kind END, s.handoffIntent = CASE WHEN \$intent = 'unclassified' THEN coalesce(s.handoffIntent, 'unclassified') ELSE \$intent END, s.handoffLifecycleVersion = 1, s.repoState = \$repoState
WITH s, p
MERGE (s)-[:BY]->(p)${PROJECT_CYPHER}${HANDED_TO_CYPHER}
RETURN s.id AS sessionId"

Q1_PARAMS=$(jq -n \
  --arg sessionId "$SESSION_ID" \
  --arg author "$AUTHOR_HANDLE" \
  --arg date "$DATE" \
  --arg topic "$TOPIC" \
  --arg summary "$SUMMARY" \
  --arg filePath "$REL_PATH" \
  --arg kind "$KIND" \
  --arg intent "$INTENT" \
  --arg repoState "$REPO_STATE_JSON" \
  "${_PROJECT_ARGS[@]:+${_PROJECT_ARGS[@]}}" \
  "${_RECIP_ARGS[@]:+${_RECIP_ARGS[@]}}" \
  '$ARGS.named')

# Q2: Preserve the stable three-result batch shape without mutating lifecycle.
# Completion used to run inside this foreground indexing request. It now enters
# through capture-run.sh's local WAL queue and is reconciled off the caller's
# critical path.
Q2_CYPHER="MATCH (s:Session {id: \$sessionId})
RETURN 0 AS resolved"

Q2_PARAMS=$(jq -n --arg sessionId "$SESSION_ID" '{sessionId: $sessionId}')

# Q3: Capture the handoff's knowledge-graph neighborhood for artifact rendering.
# Only the "graph-only" relations — things not already visible in the markdown
# header. Author/recipients/project live in the metadata row above the graph,
# so including them would be noise.
Q3_CYPHER="MATCH (s:Session {id: \$sessionId})
OPTIONAL MATCH (s)-[:IMPLEMENTS]->(prior:Session)
OPTIONAL MATCH (prior)-[:BY]->(priorAuthor:Person)
OPTIONAL MATCH (later:Session)-[:IMPLEMENTS]->(s)
OPTIONAL MATCH (later)-[:BY]->(laterAuthor:Person)
OPTIONAL MATCH (s)-[:CONTINUES]->(cont:Session)
OPTIONAL MATCH (cont)-[:BY]->(contAuthor:Person)
OPTIONAL MATCH (s)-[:ADVANCED|INVOLVES]->(quest:Quest)
OPTIONAL MATCH (s)-[:HAS_ACTIVITY]->(art:Artifact)
OPTIONAL MATCH (s)-[:PRODUCED]->(pr:PR)
RETURN
  collect(DISTINCT {id: prior.id, topic: prior.topic, author: priorAuthor.name}) AS implementsHandoff,
  collect(DISTINCT {id: later.id, topic: later.topic, author: laterAuthor.name}) AS implementedBy,
  collect(DISTINCT {id: cont.id, topic: cont.topic, author: contAuthor.name}) AS continues,
  collect(DISTINCT {id: quest.id, title: quest.title}) AS quests,
  collect(DISTINCT {id: art.id, title: art.title, type: art.type, path: art.path}) AS artifacts,
  collect(DISTINCT {id: pr.id, number: pr.number, title: pr.title, repo: pr.repo}) AS prs"

Q3_PARAMS=$(jq -n --arg sessionId "$SESSION_ID" '{sessionId: $sessionId}')

# --- Build batch request ---
BATCH_JSON=$(jq -n \
  --arg q1 "$Q1_CYPHER" \
  --argjson p1 "$Q1_PARAMS" \
  --arg q2 "$Q2_CYPHER" \
  --argjson p2 "$Q2_PARAMS" \
  --arg q3 "$Q3_CYPHER" \
  --argjson p3 "$Q3_PARAMS" \
  '[{statement: $q1, parameters: $p1}, {statement: $q2, parameters: $p2}, {statement: $q3, parameters: $p3}]')

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
    "$(jq -n --arg sid "$CURRENT_SID" '{sid: $sid}')" >/dev/null 2>&1 || true
fi

# --- Parse response ---
RESOLVED=$(echo "$RESPONSE" | jq -r '.results[1].values[0][0] // 0' 2>/dev/null || echo "0")

# Parse Q3 neighborhood into a subgraph object. Collect() entries that didn't
# match anything come back as {name: null, ...} — filter those out.
EMPTY_SG='{"implementsHandoff":[],"implementedBy":[],"continues":[],"quests":[],"artifacts":[],"prs":[]}'
SUBGRAPH_JSON=$(echo "$RESPONSE" | jq -c '
  (.results[2] // null) as $r
  | if $r == null or (($r.values // []) | length) == 0 then
      {implementsHandoff:[], implementedBy:[], continues:[], quests:[], artifacts:[], prs:[]}
    else
      ($r.fields // []) as $f
      | ($r.values[0] // []) as $v
      | reduce range(0; ($f | length)) as $i ({}; .[$f[$i]] = $v[$i])
      | {
          implementsHandoff: ((.implementsHandoff // []) | map(select(.id != null))),
          implementedBy:     ((.implementedBy // []) | map(select(.id != null))),
          continues:         ((.continues // []) | map(select(.id != null))),
          quests:            ((.quests // []) | map(select(.id != null))),
          artifacts:         ((.artifacts // []) | map(select(.id != null or .path != null))),
          prs:               ((.prs // []) | map(select(.number != null or .id != null)))
        }
    end
' 2>/dev/null || echo "$EMPTY_SG")
[ -z "$SUBGRAPH_JSON" ] && SUBGRAPH_JSON="$EMPTY_SG"

jq -n --arg sessionId "$SESSION_ID" --argjson resolved "$RESOLVED" --argjson subgraph "$SUBGRAPH_JSON" \
  '{sessionId: $sessionId, resolved: $resolved, subgraph: $subgraph}'
