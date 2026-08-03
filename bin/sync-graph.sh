#!/usr/bin/env bash
set -euo pipefail

# Sync all missing nodes from memory files into Neo4j.
# Usage: bash bin/sync-graph.sh
# Returns: {"sessions":N,"artifacts":N,"quests":N,"resolved":N}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: sync-graph.sh"
  echo ""
  echo "Sync all missing nodes from memory files into Neo4j."
  echo "Scans handoffs, wraps, knowledge files, and quests,"
  echo "then creates any nodes not already in the graph."
  echo "Also auto-resolves read handoffs."
  echo ""
  echo "Returns: {\"sessions\":N,\"artifacts\":N,\"quests\":N,\"resolved\":N}"
  exit 0
fi

MEMORY="$SCRIPT_DIR/memory"

if [ ! -d "$MEMORY" ] && [ ! -L "$MEMORY" ]; then
  echo '{"error":"memory directory not found"}'
  exit 1
fi

# --- Read config (same boilerplate as graph.sh) ---
CONFIG="$SCRIPT_DIR/egregore.json"
if [ ! -f "$CONFIG" ]; then
  echo '{"error":"egregore.json not found"}'
  exit 1
fi

# Load specific variables from .env if it exists (safe extraction, no arbitrary code execution)
if [ -f "$SCRIPT_DIR/.env" ]; then
  EGREGORE_API_URL="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
  EGREGORE_API_KEY="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
fi

API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG")}"
API_KEY="${EGREGORE_API_KEY:-}"

if [ -z "$API_URL" ] || [ -z "$API_KEY" ]; then
  echo '{"error":"API not configured"}'
  exit 1
fi

# --- Counters ---
SESSIONS=0
ARTIFACTS=0
QUESTS=0
RESOLVED=0
INGEST_MANIFESTS=0

# --- Step 1: Fetch existing IDs from graph ---
EXISTING_JSON=$(bash "$SCRIPT_DIR/bin/graph-batch.sh" '[
  {"statement": "MATCH (s:Session) RETURN collect(s.id) AS ids"},
  {"statement": "MATCH (a:Artifact) RETURN collect(a.id) AS ids"},
  {"statement": "MATCH (q:Quest) RETURN collect(q.id) AS ids"}
]' 2>/dev/null) || {
  echo '{"error":"Failed to fetch existing IDs from graph"}'
  exit 1
}

# Parse into newline-delimited lists for fast lookup
EXISTING_SESSIONS=$(echo "$EXISTING_JSON" | jq -r '.results[0].values[0][0][]? // empty' 2>/dev/null | sort || true)
EXISTING_ARTIFACTS=$(echo "$EXISTING_JSON" | jq -r '.results[1].values[0][0][]? // empty' 2>/dev/null | sort || true)
EXISTING_QUESTS=$(echo "$EXISTING_JSON" | jq -r '.results[2].values[0][0][]? // empty' 2>/dev/null | sort || true)

# Helper: check if ID exists in a newline-delimited list.
#
# Pure bash on purpose. The previous form was `echo "$list" | grep -qxF "$id"`,
# which is broken under this script's `set -o pipefail`: grep -q exits the moment
# it matches, echo takes SIGPIPE writing the rest of the ~80KB list, exits 141,
# and pipefail makes that the pipeline's status — so an id near the TOP of the
# sorted list reads as absent. 229 of 238 handoffs were re-synced on every run
# because of it. Matching in-shell also drops ~1,800 spawned processes per run.
id_exists() {
  case $'\n'"$2"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Helper: parse YAML front matter value
# Handles quoted values with colons, preserves whitespace
yaml_val() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^---$/ { fm++; next }
    fm == 1 && $0 ~ "^"k":" {
      val = $0
      sub("^"k":[ \t]*", "", val)
      # Strip surrounding quotes (single or double)
      if (val ~ /^".*"$/) { val = substr(val, 2, length(val)-2) }
      else if (val ~ /^'"'"'.*'"'"'$/) { val = substr(val, 2, length(val)-2) }
      print val
      exit
    }
    fm >= 2 { exit }
  ' "$file" 2>/dev/null || true
}

# Helper: parse markdown header value (e.g. **Key**: Value)
md_val() {
  local file="$1" key="$2"
  grep -m1 "^\*\*${key}\*\*:" "$file" 2>/dev/null | sed "s/\*\*${key}\*\*:[[:space:]]*//" || true
}

# Helper: get value from either YAML front matter or markdown headers
get_val() {
  local file="$1" yaml_key="$2" md_key="${3:-$2}"
  local val
  val="$(yaml_val "$file" "$yaml_key")"
  [ -z "$val" ] && val="$(md_val "$file" "$md_key")"
  echo "$val"
}

# --- Step 2: Scan handoffs ---
while IFS= read -r -d '' hfile; do
  fname="$(basename "$hfile" .md)"
  dirmonth="$(basename "$(dirname "$hfile")")"
  # Derive sessionId — same logic as index-handoff.sh
  if [[ "$dirmonth" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
    day="${fname%%-*}"
    rest="${fname#*-}"
    sid="${dirmonth}-${day}-${rest}"
  else
    sid="$fname"
  fi

  if ! id_exists "$sid" "$EXISTING_SESSIONS"; then
    # Delegate to index-handoff.sh (single source of truth)
    RESULT=$(bash "$SCRIPT_DIR/bin/index-handoff.sh" "$hfile" 2>/dev/null) || continue
    # Check for error
    if echo "$RESULT" | jq -e '.error' >/dev/null 2>&1; then
      continue
    fi
    SESSIONS=$((SESSIONS + 1))
    R=$(echo "$RESULT" | jq -r '.resolved // 0' 2>/dev/null)
    RESOLVED=$((RESOLVED + R))
  fi
done < <(find "$MEMORY/handoffs" -name '*.md' -not -name 'index.md' -not -name 'index.md.bak' -not -name '.gitkeep' -print0 2>/dev/null)

# --- Step 2b: Scan wraps ---
if [ -d "$MEMORY/wraps" ]; then
  while IFS= read -r -d '' wfile; do
    fname="$(basename "$wfile" .md)"
    dirmonth="$(basename "$(dirname "$wfile")")"
    # Read session ID from wrap file metadata (matches auto-capture ID)
    sid="$(grep -m1 '^\*\*Session\*\*:' "$wfile" 2>/dev/null | sed 's/\*\*Session\*\*:[[:space:]]*//' || true)"
    # Fallback: derive from filename (pre-wrap files without Session metadata)
    if [ -z "$sid" ]; then
      if [[ "$dirmonth" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        day="${fname%%-*}"
        rest="${fname#*-}"
        sid="${dirmonth}-${day}-${rest}"
      else
        sid="$fname"
      fi
    fi

    if ! id_exists "$sid" "$EXISTING_SESSIONS"; then
      # Parse wrap metadata
      W_TOPIC="$(grep -m1 '^# Wrap: ' "$wfile" 2>/dev/null | sed 's/^# Wrap: //' || true)"
      [ -z "$W_TOPIC" ] && W_TOPIC="$fname"

      W_AUTHOR="$(grep -m1 '^\*\*Author\*\*:' "$wfile" 2>/dev/null | sed 's/\*\*Author\*\*:[[:space:]]*//' || true)"
      W_AUTHOR_HANDLE="$(echo "$W_AUTHOR" | awk '{print tolower($1)}')"
      [ -z "$W_AUTHOR_HANDLE" ] && W_AUTHOR_HANDLE="unknown"

      W_DATE="$(grep -m1 '^\*\*Date\*\*:' "$wfile" 2>/dev/null | sed 's/\*\*Date\*\*:[[:space:]]*//' || true)"
      [ -z "$W_DATE" ] && W_DATE="$(echo "$fname" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "")"
      [ -z "$W_DATE" ] && W_DATE="${dirmonth}-${fname%%-*}"

      W_BRANCH="$(grep -m1 '^\*\*Branch\*\*:' "$wfile" 2>/dev/null | sed 's/\*\*Branch\*\*:[[:space:]]*//' || true)"

      W_SUMMARY="$(awk '/^## Summary/{found=1; next} found && /^[^#]/ && !/^[[:space:]]*$/{print; exit}' "$wfile" 2>/dev/null || true)"
      [ -z "$W_SUMMARY" ] && W_SUMMARY="$W_TOPIC"

      REL_PATH="wraps/${dirmonth}/${fname}.md"

      # Person is resolved AFTER the MERGE, not before it. Leading with
      # `MATCH (p:Person)` meant an unresolvable author produced zero rows, so
      # the MERGE never executed — while the query still returned success. Wraps
      # by authors with no Person node (e.g. `codex`) were reported synced on
      # every run and never written. Mirrors the artifacts block below.
      CYPHER="MERGE (s:Session {id: \$sid})
        ON CREATE SET s.date = date(\$date), s.topic = \$topic, s.summary = \$summary,
          s.filePath = \$filePath, s.status = 'wrapped', s.branch = \$branch,
          s.startedAt = datetime(\$date + 'T00:00:00Z')
        WITH s
        OPTIONAL MATCH (p:Person) WHERE \$author <> '' AND (toLower(p.name) = \$author OR p.github = \$author OR \$author IN [x IN coalesce(p.previousNames, []) | toLower(x)])
        FOREACH (_ IN CASE WHEN p IS NOT NULL THEN [1] ELSE [] END | MERGE (s)-[:BY]->(p))
        RETURN s.id"

      PARAMS=$(jq -n \
        --arg sid "$sid" \
        --arg author "$W_AUTHOR_HANDLE" \
        --arg date "${W_DATE:-2026-01-01}" \
        --arg topic "$W_TOPIC" \
        --arg summary "$W_SUMMARY" \
        --arg filePath "$REL_PATH" \
        --arg branch "$W_BRANCH" \
        '{sid: $sid, author: $author, date: $date, topic: $topic, summary: $summary, filePath: $filePath, branch: $branch}')

      bash "$SCRIPT_DIR/bin/graph.sh" query "$CYPHER" "$PARAMS" >/dev/null 2>&1 && SESSIONS=$((SESSIONS + 1)) || true
    fi
  done < <(find "$MEMORY/wraps" -name '*.md' -not -name '.gitkeep' -print0 2>/dev/null)
fi

# --- Step 3: Scan artifacts and knowledge files ---
# Covers: memory/knowledge/decisions/*.md, memory/knowledge/findings/*.md, memory/knowledge/patterns/*.md, memory/knowledge/research/*.md
for dir in "$MEMORY/knowledge/decisions" "$MEMORY/knowledge/findings" "$MEMORY/knowledge/patterns" "$MEMORY/knowledge/research"; do
  [ ! -d "$dir" ] && continue
  CATEGORY="$(basename "$dir")"
  # Singularize: decisions→decision, findings→finding, patterns→pattern
  TYPE="${CATEGORY%s}"

  while IFS= read -r -d '' afile; do
    fname="$(basename "$afile" .md)"
    [ "$fname" = ".gitkeep" ] && continue

    if ! id_exists "$fname" "$EXISTING_ARTIFACTS"; then
      # Parse metadata
      TITLE="$(get_val "$afile" "title" "Title")"
      [ -z "$TITLE" ] && TITLE="$(grep -m1 '^# ' "$afile" 2>/dev/null | sed 's/^# //' || true)"
      [ -z "$TITLE" ] && TITLE="$fname"

      A_AUTHOR="$(get_val "$afile" "author" "Author")"
      A_AUTHOR_HANDLE="$(echo "$A_AUTHOR" | awk '{print tolower($1)}')"

      A_DATE="$(get_val "$afile" "date" "Date")"
      [ -z "$A_DATE" ] && A_DATE="$(echo "$fname" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "")"

      REL_PATH="knowledge/${CATEGORY}/${fname}.md"

      # Parse topics from YAML front matter (list format: [a, b] or - a\n- b)
      TOPICS_JSON="[]"
      TOPICS_RAW="$(yaml_val "$afile" "topics")"
      if [ -n "$TOPICS_RAW" ]; then
        # Handle [a, b] format
        if [[ "$TOPICS_RAW" == \[* ]]; then
          TOPICS_JSON="$(echo "$TOPICS_RAW" | jq -R 'gsub("^\\[|\\]$"; "") | split(",") | map(gsub("^\\s+|\\s+$"; "") | gsub("^\"|\"$"; ""))' 2>/dev/null || echo "[]")"
        fi
      fi

      # Build Cypher
      CYPHER="MERGE (a:Artifact {id: \$id})
ON CREATE SET a.title = \$title, a.type = \$type, a.filePath = \$filePath, a.created = datetime(\$date + 'T00:00:00'), a.topics = \$topics
ON MATCH SET a.title = \$title, a.topics = \$topics"

      # Add author relationship if we have one
      if [ -n "$A_AUTHOR_HANDLE" ] && [ "$A_AUTHOR_HANDLE" != "unknown" ]; then
        CYPHER="${CYPHER}
WITH a
OPTIONAL MATCH (p:Person) WHERE toLower(p.name) = \$author OR p.github = \$author OR \$author IN [x IN coalesce(p.previousNames, []) | toLower(x)]
FOREACH (_ IN CASE WHEN p IS NOT NULL THEN [1] ELSE [] END |
  MERGE (a)-[:CONTRIBUTED_BY]->(p)
)"
      fi

      CYPHER="${CYPHER}
RETURN a.id"

      # Build params
      PARAMS=$(jq -n \
        --arg id "$fname" \
        --arg title "$TITLE" \
        --arg type "$TYPE" \
        --arg filePath "$REL_PATH" \
        --arg date "${A_DATE:-2026-01-01}" \
        --argjson topics "$TOPICS_JSON" \
        --arg author "${A_AUTHOR_HANDLE:-unknown}" \
        '{id: $id, title: $title, type: $type, filePath: $filePath, date: $date, topics: $topics, author: $author}')

      bash "$SCRIPT_DIR/bin/graph.sh" query "$CYPHER" "$PARAMS" >/dev/null 2>&1 && ARTIFACTS=$((ARTIFACTS + 1)) || true
    fi
  done < <(find "$dir" -maxdepth 1 -name '*.md' -not -name '.gitkeep' -print0 2>/dev/null)
done

# --- Step 3b: Scan the hosted-artifact registry (memory/artifacts/) ---
# Published egregore.xyz artifacts (scrolls, /view, /reflect …). Unlike knowledge
# files these carry a `url:` — set a.url + a.excerpt so the connected-mode finder
# (bin/artifacts.sh graph path) can rank + return them by content and by author/
# quest. Recurse (the registry has subdirs). Real-time upserts happen at publish
# via graph-op.sh register-artifact; this loop is the backfill + /save backstop,
# skipping ids already synced. Node id = filename stem, matching register-artifact.
if [ -d "$MEMORY/artifacts" ]; then
  while IFS= read -r -d '' afile; do
    fname="$(basename "$afile" .md)"
    [ "$fname" = ".gitkeep" ] && continue
    id_exists "$fname" "$EXISTING_ARTIFACTS" && continue

    A_TITLE="$(get_val "$afile" "title" "Title")"
    [ -z "$A_TITLE" ] && A_TITLE="$(grep -m1 '^# ' "$afile" 2>/dev/null | sed 's/^# //' || true)"
    [ -z "$A_TITLE" ] && A_TITLE="$fname"
    A_TYPE="$(yaml_val "$afile" "type")"; [ -z "$A_TYPE" ] && A_TYPE="artifact"
    A_URL="$(yaml_val "$afile" "url")"
    A_AUTHOR_HANDLE="$(get_val "$afile" "author" "Author" | awk '{print tolower($1)}')"
    A_DATE="$(get_val "$afile" "date" "Date")"
    [ -z "$A_DATE" ] && A_DATE="$(echo "$fname" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "")"

    TOPICS_JSON="[]"
    TOPICS_RAW="$(yaml_val "$afile" "topics")"
    if [ -n "$TOPICS_RAW" ] && [[ "$TOPICS_RAW" == \[* ]]; then
      TOPICS_JSON="$(echo "$TOPICS_RAW" | jq -R 'gsub("^\\[|\\]$"; "") | split(",") | map(gsub("^\\s+|\\s+$"; "") | gsub("^\"|\"$"; "")) | map(select(length > 0))' 2>/dev/null || echo "[]")"
    fi

    # Excerpt: body sans frontmatter, flattened + capped, for CONTAINS retrieval.
    A_EXCERPT="$(sed -e '/^---$/,/^---$/d' "$afile" 2>/dev/null | tr '\n' ' ' | cut -c1-2000)"
    REL_PATH="artifacts/${afile#"$MEMORY"/artifacts/}"

    CYPHER="MERGE (a:Artifact {id: \$id})
ON CREATE SET a.created = CASE WHEN \$date <> '' THEN datetime(\$date + 'T00:00:00') ELSE datetime() END
SET a.title = \$title, a.type = \$type, a.filePath = \$filePath, a.topics = \$topics,
    a.url = \$url, a.excerpt = \$excerpt, a.published = true
WITH a
OPTIONAL MATCH (p:Person) WHERE \$author <> '' AND (toLower(p.name) = \$author OR p.github = \$author)
FOREACH (_ IN CASE WHEN p IS NOT NULL THEN [1] ELSE [] END | MERGE (a)-[:CONTRIBUTED_BY]->(p))
RETURN a.id"

    PARAMS=$(jq -n \
      --arg id "$fname" --arg title "$A_TITLE" --arg type "$A_TYPE" \
      --arg filePath "$REL_PATH" --arg date "${A_DATE:-}" \
      --argjson topics "$TOPICS_JSON" --arg url "${A_URL:-}" \
      --arg excerpt "$A_EXCERPT" --arg author "${A_AUTHOR_HANDLE:-}" \
      '{id: $id, title: $title, type: $type, filePath: $filePath, date: $date, topics: $topics, url: $url, excerpt: $excerpt, author: $author}')

    bash "$SCRIPT_DIR/bin/graph.sh" query "$CYPHER" "$PARAMS" >/dev/null 2>&1 && ARTIFACTS=$((ARTIFACTS + 1)) || true
  done < <(find "$MEMORY/artifacts" -type f -name '*.md' -not -name '.gitkeep' -print0 2>/dev/null)
fi

# --- Step 4: Scan quests ---
if [ -d "$MEMORY/quests" ]; then
  while IFS= read -r -d '' qfile; do
    fname="$(basename "$qfile" .md)"
    [ "$fname" = "index" ] || [ "$fname" = "_template" ] || [ "$fname" = ".gitkeep" ] && continue

    SLUG="$fname"

    if ! id_exists "$SLUG" "$EXISTING_QUESTS"; then
      Q_TITLE="$(yaml_val "$qfile" "title")"
      [ -z "$Q_TITLE" ] && Q_TITLE="$(grep -m1 '^# ' "$qfile" 2>/dev/null | sed 's/^# //' || true)"
      [ -z "$Q_TITLE" ] && Q_TITLE="$SLUG"

      Q_STATUS="$(yaml_val "$qfile" "status")"
      [ -z "$Q_STATUS" ] && Q_STATUS="active"

      Q_PRIORITY="$(yaml_val "$qfile" "priority")"
      [ -z "$Q_PRIORITY" ] && Q_PRIORITY="0"

      Q_STARTED="$(yaml_val "$qfile" "started")"
      Q_STARTED_BY="$(yaml_val "$qfile" "started_by")"
      Q_STARTED_BY_HANDLE="$(echo "$Q_STARTED_BY" | awk '{print tolower($1)}')"

      CYPHER="MERGE (q:Quest {id: \$id})
ON CREATE SET q.title = \$title, q.status = \$status, q.priority = toInteger(\$priority), q.started = date(\$started)
ON MATCH SET q.title = \$title, q.status = \$status, q.priority = toInteger(\$priority)"

      if [ -n "$Q_STARTED_BY_HANDLE" ]; then
        CYPHER="${CYPHER}
WITH q
OPTIONAL MATCH (p:Person) WHERE toLower(p.name) = \$startedBy
FOREACH (_ IN CASE WHEN p IS NOT NULL THEN [1] ELSE [] END |
  MERGE (q)-[:STARTED_BY]->(p)
)"
      fi

      CYPHER="${CYPHER}
RETURN q.id"

      PARAMS=$(jq -n \
        --arg id "$SLUG" \
        --arg title "$Q_TITLE" \
        --arg status "$Q_STATUS" \
        --arg priority "$Q_PRIORITY" \
        --arg started "${Q_STARTED:-2026-01-01}" \
        --arg startedBy "${Q_STARTED_BY_HANDLE:-unknown}" \
        '{id: $id, title: $title, status: $status, priority: $priority, started: $started, startedBy: $startedBy}')

      bash "$SCRIPT_DIR/bin/graph.sh" query "$CYPHER" "$PARAMS" >/dev/null 2>&1 && QUESTS=$((QUESTS + 1)) || true
    fi
  done < <(find "$MEMORY/quests" -maxdepth 1 -name '*.md' -not -name 'index.md' -not -name '_template.md' -not -name '.gitkeep' -print0 2>/dev/null)
fi

# --- Step 5: Auto-resolve explicit implementation lineage ---
ME=$(git -C "$SCRIPT_DIR" config user.name 2>/dev/null | awk '{print tolower($1)}' || echo "unknown")
RESOLVE_RESULT=$(bash "$SCRIPT_DIR/bin/graph.sh" query \
  "MATCH (s:Session)-[:HANDED_TO]->(p:Person) WHERE toLower(p.name) = \$me AND s.handoffStatus = 'read'
   WITH DISTINCT s, p, size([(s)-[:HANDED_TO]->(:Person) | 1]) AS recipientCount
   WHERE recipientCount = 1
   MATCH (implementation:Session)-[:IMPLEMENTS]->(s)
   MATCH (implementation)-[:BY]->(p)
   WHERE implementation.wrappedAt IS NOT NULL
      OR implementation.status IN ['completed','handed_off','wrapped']
   WITH DISTINCT s
   SET s.handoffStatus = 'done',
       s.handoffDoneAt = coalesce(s.handoffDoneAt, datetime()),
       s.handoffUpdatedAt = datetime(),
       s.handoffLifecycleReason = 'single_recipient_implemented',
       s.handoffLifecycleVersion = 1
   RETURN count(s) AS resolved" \
  "$(jq -n --arg me "$ME" '{me: $me}')" 2>/dev/null) || true

EXTRA_RESOLVED=$(echo "$RESOLVE_RESULT" | jq -r '.values[0][0] // 0' 2>/dev/null || echo "0")
RESOLVED=$((RESOLVED + EXTRA_RESOLVED))

# --- Step 6: Quest topic derivation ---
bash "$SCRIPT_DIR/bin/graph.sh" query \
  "MATCH (q:Quest {status: 'active'})
   OPTIONAL MATCH (a:Artifact)-[:PART_OF]->(q)
   WHERE a.topics IS NOT NULL
   UNWIND a.topics AS topic
   WITH q, collect(DISTINCT topic) AS derivedTopics
   SET q.topics = derivedTopics
   RETURN count(q)" \
  '{}' >/dev/null 2>&1 || true

# --- Step 7: Replay durable ingest projections ---
if [ -d "$MEMORY/ingest" ]; then
  while IFS= read -r -d '' manifest; do
    if bash "$SCRIPT_DIR/bin/ingest-graph.sh" apply "$manifest" >/dev/null 2>&1; then
      INGEST_MANIFESTS=$((INGEST_MANIFESTS + 1))
    fi
  done < <(
    find "$MEMORY/ingest/sources" "$MEMORY/ingest/knowledge" \
      -type f -name '*.json' -print0 2>/dev/null
  )
fi

# --- Output ---
jq -n --argjson sessions "$SESSIONS" --argjson artifacts "$ARTIFACTS" \
  --argjson quests "$QUESTS" --argjson resolved "$RESOLVED" \
  --argjson ingest "$INGEST_MANIFESTS" \
  '{sessions: $sessions, artifacts: $artifacts, quests: $quests, resolved: $resolved, ingest_manifests: $ingest}'
