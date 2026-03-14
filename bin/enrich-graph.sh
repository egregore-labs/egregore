#!/bin/bash
set -euo pipefail

# Enrich graph: backfill topics, types, timestamps, resolve ghosts, create RELATES_TO edges.
# Usage: bash bin/enrich-graph.sh [--dry-run]
# Returns: {"topics_backfilled":N,"types_backfilled":N,"timestamps_normalized":N,"ghosts_resolved":N,"edges_created":N}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GS="$SCRIPT_DIR/bin/graph.sh"
GB="$SCRIPT_DIR/bin/graph-batch.sh"
MEMORY="$SCRIPT_DIR/memory"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

TOPICS_BACKFILLED=0
TYPES_BACKFILLED=0
TIMESTAMPS_NORMALIZED=0
GHOSTS_RESOLVED=0
EDGES_CREATED=0

# --- Helper: parse YAML front matter value ---
yaml_val() {
  local file="$1" key="$2"
  sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null | grep -m1 "^${key}:" 2>/dev/null | sed "s/^${key}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | xargs 2>/dev/null || true
}

# --- Helper: parse YAML list (topics: [a, b] or topics:\n- a\n- b) ---
yaml_list() {
  local file="$1" key="$2"
  local raw
  raw="$(yaml_val "$file" "$key")"
  if [ -n "$raw" ] && [[ "$raw" == \[* ]]; then
    # Inline format: [a, b, c]
    echo "$raw" | jq -R 'gsub("^\\[|\\]$"; "") | split(",") | map(gsub("^\\s+|\\s+$"; "") | gsub("^\"|\"$"; ""))' 2>/dev/null || echo "[]"
    return
  fi
  # Try dash-list format
  local items
  items=$(sed -n "/^${key}:/,/^[^ -]/p" "$file" 2>/dev/null | grep '^ *- ' | sed 's/^ *- //' | sed 's/^"//' | sed 's/"$//' | xargs -I{} echo '"{}"' 2>/dev/null | paste -sd',' - 2>/dev/null || true)
  if [ -n "$items" ]; then
    echo "[$items]"
  else
    echo "[]"
  fi
}

# --- Helper: derive topics from title ---
# Lowercase, strip stop words, pair adjacent words with hyphens, max 4 topics
derive_topics_from_title() {
  local title="$1"
  local words
  # Lowercase, remove punctuation, split into words
  words=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]/ /g' | xargs)

  # Strip stop words
  local filtered=()
  for w in $words; do
    case "$w" in
      the|a|an|is|for|and|or|in|of|to|with|from|by|on|at|this|that|it|its|are|was|were|be|been|has|have|had|do|does|did|will|would|could|should|may|might|can|shall) ;;
      *) [ -n "$w" ] && filtered+=("$w") ;;
    esac
  done

  local topics=()
  local len=${#filtered[@]}

  if [ "$len" -eq 0 ]; then
    echo "[]"
    return
  fi

  # Single words become topics, adjacent pairs become hyphenated topics
  if [ "$len" -eq 1 ]; then
    topics+=("${filtered[0]}")
  else
    # Create adjacent pairs
    local i=0
    while [ $i -lt $((len - 1)) ] && [ ${#topics[@]} -lt 4 ]; do
      topics+=("${filtered[$i]}-${filtered[$((i+1))]}")
      i=$((i + 2))
    done
    # If odd number of words, add the last one as a single topic
    if [ $((len % 2)) -eq 1 ] && [ ${#topics[@]} -lt 4 ]; then
      topics+=("${filtered[$((len-1))]}")
    fi
  fi

  # Trim to max 4 and output as JSON array
  local json="["
  local count=0
  for t in "${topics[@]}"; do
    [ $count -ge 4 ] && break
    [ $count -gt 0 ] && json+=","
    json+="\"$t\""
    count=$((count + 1))
  done
  json+="]"
  echo "$json"
}

# ============================================================
# STEP 1: Topic backfill
# ============================================================
echo "Step 1: Topic backfill..."

RESULT=$(bash "$GS" query "
  MATCH (a:Artifact)
  WHERE a.topics IS NULL OR size(a.topics) = 0
  RETURN a.id AS id, a.title AS title, a.filePath AS filePath
  ORDER BY a.id
" '{}' 2>/dev/null) || { echo "  Failed to query artifacts"; RESULT='{"values":[]}'; }

COUNT=$(echo "$RESULT" | jq -r '.values | length' 2>/dev/null || echo "0")
[ "$COUNT" = "null" ] && COUNT=0

echo "  Found $COUNT artifacts without topics."

BATCH_STATEMENTS=()

for i in $(seq 0 $((COUNT - 1))); do
  AID=$(echo "$RESULT" | jq -r ".values[$i][0]" 2>/dev/null)
  TITLE=$(echo "$RESULT" | jq -r ".values[$i][1]" 2>/dev/null)
  FPATH=$(echo "$RESULT" | jq -r ".values[$i][2]" 2>/dev/null)

  [ -z "$AID" ] || [ "$AID" = "null" ] && continue

  TOPICS="[]"

  # Try reading frontmatter topics from file
  if [ -n "$FPATH" ] && [ "$FPATH" != "null" ]; then
    FULL_PATH="$MEMORY/$FPATH"
    if [ -f "$FULL_PATH" ]; then
      TOPICS=$(yaml_list "$FULL_PATH" "topics")
    fi
  fi

  # If still empty, derive from title
  if [ "$TOPICS" = "[]" ] || [ -z "$TOPICS" ]; then
    [ -z "$TITLE" ] || [ "$TITLE" = "null" ] && TITLE="$AID"
    TOPICS=$(derive_topics_from_title "$TITLE")
  fi

  # Skip if we couldn't derive anything
  [ "$TOPICS" = "[]" ] && continue

  if [ "$DRY_RUN" = true ]; then
    printf "  [dry-run] %s → %s\n" "$AID" "$TOPICS"
    TOPICS_BACKFILLED=$((TOPICS_BACKFILLED + 1))
  else
    # Accumulate for batch
    STMT=$(jq -n \
      --arg id "$AID" \
      --argjson topics "$TOPICS" \
      '{statement: "MATCH (a:Artifact {id: $id}) SET a.topics = $topics RETURN a.id", parameters: {id: $id, topics: $topics}}')
    BATCH_STATEMENTS+=("$STMT")

    # Flush every 20
    if [ ${#BATCH_STATEMENTS[@]} -ge 20 ]; then
      BATCH_JSON=$(printf '%s\n' "${BATCH_STATEMENTS[@]}" | jq -s '.')
      bash "$GB" "$BATCH_JSON" >/dev/null 2>&1 && TOPICS_BACKFILLED=$((TOPICS_BACKFILLED + ${#BATCH_STATEMENTS[@]})) || true
      BATCH_STATEMENTS=()
    fi
  fi
done

# Flush remaining batch
if [ "$DRY_RUN" = false ] && [ ${#BATCH_STATEMENTS[@]} -gt 0 ]; then
  BATCH_JSON=$(printf '%s\n' "${BATCH_STATEMENTS[@]}" | jq -s '.')
  bash "$GB" "$BATCH_JSON" >/dev/null 2>&1 && TOPICS_BACKFILLED=$((TOPICS_BACKFILLED + ${#BATCH_STATEMENTS[@]})) || true
  BATCH_STATEMENTS=()
fi

echo "  Topics backfilled: $TOPICS_BACKFILLED"

# ============================================================
# STEP 2: Type backfill
# ============================================================
echo ""
echo "Step 2: Type backfill..."

RESULT=$(bash "$GS" query "
  MATCH (a:Artifact)
  WHERE a.type IS NULL
  RETURN a.id AS id, a.title AS title, a.filePath AS filePath
" '{}' 2>/dev/null) || { echo "  Failed to query artifacts"; RESULT='{"values":[]}'; }

COUNT=$(echo "$RESULT" | jq -r '.values | length' 2>/dev/null || echo "0")
[ "$COUNT" = "null" ] && COUNT=0

echo "  Found $COUNT artifacts without type."

for i in $(seq 0 $((COUNT - 1))); do
  AID=$(echo "$RESULT" | jq -r ".values[$i][0]" 2>/dev/null)
  TITLE=$(echo "$RESULT" | jq -r ".values[$i][1]" 2>/dev/null)
  FPATH=$(echo "$RESULT" | jq -r ".values[$i][2]" 2>/dev/null)

  [ -z "$AID" ] || [ "$AID" = "null" ] && continue

  TYPE="finding"

  # Derive from filePath directory
  if [ -n "$FPATH" ] && [ "$FPATH" != "null" ]; then
    case "$FPATH" in
      *decisions/*) TYPE="decision" ;;
      *findings/*) TYPE="finding" ;;
      *patterns/*) TYPE="pattern" ;;
      *research/*) TYPE="research" ;;
      *handoffs/*) TYPE="handoff" ;;
    esac
  fi

  # Derive from title cues if still default
  if [ "$TYPE" = "finding" ] && [ -n "$TITLE" ] && [ "$TITLE" != "null" ]; then
    LOWER_TITLE=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]')
    case "$LOWER_TITLE" in
      *decision*|*decided*|*choose*|*chose*) TYPE="decision" ;;
      *pattern*) TYPE="pattern" ;;
      *research*) TYPE="research" ;;
    esac
  fi

  if [ "$DRY_RUN" = true ]; then
    printf "  [dry-run] %s → type:%s\n" "$AID" "$TYPE"
    TYPES_BACKFILLED=$((TYPES_BACKFILLED + 1))
  else
    STMT=$(jq -n \
      --arg id "$AID" \
      --arg type "$TYPE" \
      '{statement: "MATCH (a:Artifact {id: $id}) SET a.type = $type RETURN a.id", parameters: {id: $id, type: $type}}')
    BATCH_STATEMENTS+=("$STMT")

    if [ ${#BATCH_STATEMENTS[@]} -ge 20 ]; then
      BATCH_JSON=$(printf '%s\n' "${BATCH_STATEMENTS[@]}" | jq -s '.')
      bash "$GB" "$BATCH_JSON" >/dev/null 2>&1 && TYPES_BACKFILLED=$((TYPES_BACKFILLED + ${#BATCH_STATEMENTS[@]})) || true
      BATCH_STATEMENTS=()
    fi
  fi
done

if [ "$DRY_RUN" = false ] && [ ${#BATCH_STATEMENTS[@]} -gt 0 ]; then
  BATCH_JSON=$(printf '%s\n' "${BATCH_STATEMENTS[@]}" | jq -s '.')
  bash "$GB" "$BATCH_JSON" >/dev/null 2>&1 && TYPES_BACKFILLED=$((TYPES_BACKFILLED + ${#BATCH_STATEMENTS[@]})) || true
  BATCH_STATEMENTS=()
fi

echo "  Types backfilled: $TYPES_BACKFILLED"

# ============================================================
# STEP 3: Timestamp normalization
# ============================================================
echo ""
echo "Step 3: Timestamp normalization..."

RESULT=$(bash "$GS" query "
  MATCH (a:Artifact)
  WHERE a.created IS NULL
  RETURN a.id AS id, a.filePath AS filePath
" '{}' 2>/dev/null) || { echo "  Failed to query artifacts"; RESULT='{"values":[]}'; }

COUNT=$(echo "$RESULT" | jq -r '.values | length' 2>/dev/null || echo "0")
[ "$COUNT" = "null" ] && COUNT=0

echo "  Found $COUNT artifacts without timestamp."

for i in $(seq 0 $((COUNT - 1))); do
  AID=$(echo "$RESULT" | jq -r ".values[$i][0]" 2>/dev/null)
  FPATH=$(echo "$RESULT" | jq -r ".values[$i][1]" 2>/dev/null)

  [ -z "$AID" ] || [ "$AID" = "null" ] && continue

  DATE=""

  # Try extracting date from artifact ID (YYYY-MM-DD prefix)
  DATE=$(echo "$AID" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)

  # Try frontmatter date
  if [ -z "$DATE" ] && [ -n "$FPATH" ] && [ "$FPATH" != "null" ]; then
    FULL_PATH="$MEMORY/$FPATH"
    if [ -f "$FULL_PATH" ]; then
      DATE=$(yaml_val "$FULL_PATH" "date" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    fi
  fi

  # Fallback
  [ -z "$DATE" ] && DATE="2026-01-01"

  if [ "$DRY_RUN" = true ]; then
    printf "  [dry-run] %s → created:%s\n" "$AID" "$DATE"
    TIMESTAMPS_NORMALIZED=$((TIMESTAMPS_NORMALIZED + 1))
  else
    STMT=$(jq -n \
      --arg id "$AID" \
      --arg date "${DATE}T00:00:00" \
      '{statement: "MATCH (a:Artifact {id: $id}) SET a.created = datetime($date) RETURN a.id", parameters: {id: $id, date: $date}}')
    BATCH_STATEMENTS+=("$STMT")

    if [ ${#BATCH_STATEMENTS[@]} -ge 20 ]; then
      BATCH_JSON=$(printf '%s\n' "${BATCH_STATEMENTS[@]}" | jq -s '.')
      bash "$GB" "$BATCH_JSON" >/dev/null 2>&1 && TIMESTAMPS_NORMALIZED=$((TIMESTAMPS_NORMALIZED + ${#BATCH_STATEMENTS[@]})) || true
      BATCH_STATEMENTS=()
    fi
  fi
done

if [ "$DRY_RUN" = false ] && [ ${#BATCH_STATEMENTS[@]} -gt 0 ]; then
  BATCH_JSON=$(printf '%s\n' "${BATCH_STATEMENTS[@]}" | jq -s '.')
  bash "$GB" "$BATCH_JSON" >/dev/null 2>&1 && TIMESTAMPS_NORMALIZED=$((TIMESTAMPS_NORMALIZED + ${#BATCH_STATEMENTS[@]})) || true
  BATCH_STATEMENTS=()
fi

echo "  Timestamps normalized: $TIMESTAMPS_NORMALIZED"

# ============================================================
# STEP 4: Ghost artifact resolution
# ============================================================
echo ""
echo "Step 4: Ghost artifact resolution..."

RESULT=$(bash "$GS" query "
  MATCH (a:Artifact)
  WHERE a.filePath IS NULL AND a.type IS NOT NULL
  RETURN a.id AS id, a.type AS type
" '{}' 2>/dev/null) || { echo "  Failed to query artifacts"; RESULT='{"values":[]}'; }

COUNT=$(echo "$RESULT" | jq -r '.values | length' 2>/dev/null || echo "0")
[ "$COUNT" = "null" ] && COUNT=0

echo "  Found $COUNT ghost artifacts (no filePath)."

for i in $(seq 0 $((COUNT - 1))); do
  AID=$(echo "$RESULT" | jq -r ".values[$i][0]" 2>/dev/null)
  ATYPE=$(echo "$RESULT" | jq -r ".values[$i][1]" 2>/dev/null)

  [ -z "$AID" ] || [ "$AID" = "null" ] && continue

  FOUND_PATH=""

  # Search by convention based on type
  case "$ATYPE" in
    decision)  [ -f "$MEMORY/knowledge/decisions/${AID}.md" ] && FOUND_PATH="knowledge/decisions/${AID}.md" ;;
    finding)   [ -f "$MEMORY/knowledge/findings/${AID}.md" ] && FOUND_PATH="knowledge/findings/${AID}.md" ;;
    pattern)   [ -f "$MEMORY/knowledge/patterns/${AID}.md" ] && FOUND_PATH="knowledge/patterns/${AID}.md" ;;
    research)  [ -f "$MEMORY/knowledge/research/${AID}.md" ] && FOUND_PATH="knowledge/research/${AID}.md" ;;
  esac

  # Broader search if not found by convention
  if [ -z "$FOUND_PATH" ]; then
    SEARCH_RESULT=$(find "$MEMORY" -name "${AID}.md" -not -path '*/\.*' 2>/dev/null | head -1 || true)
    if [ -n "$SEARCH_RESULT" ]; then
      # Convert absolute path to relative path from memory/
      FOUND_PATH="${SEARCH_RESULT#$MEMORY/}"
    fi
  fi

  [ -z "$FOUND_PATH" ] && continue

  if [ "$DRY_RUN" = true ]; then
    printf "  [dry-run] %s → filePath:%s\n" "$AID" "$FOUND_PATH"
    GHOSTS_RESOLVED=$((GHOSTS_RESOLVED + 1))
  else
    STMT=$(jq -n \
      --arg id "$AID" \
      --arg filePath "$FOUND_PATH" \
      '{statement: "MATCH (a:Artifact {id: $id}) SET a.filePath = $filePath RETURN a.id", parameters: {id: $id, filePath: $filePath}}')
    BATCH_STATEMENTS+=("$STMT")

    if [ ${#BATCH_STATEMENTS[@]} -ge 20 ]; then
      BATCH_JSON=$(printf '%s\n' "${BATCH_STATEMENTS[@]}" | jq -s '.')
      bash "$GB" "$BATCH_JSON" >/dev/null 2>&1 && GHOSTS_RESOLVED=$((GHOSTS_RESOLVED + ${#BATCH_STATEMENTS[@]})) || true
      BATCH_STATEMENTS=()
    fi
  fi
done

if [ "$DRY_RUN" = false ] && [ ${#BATCH_STATEMENTS[@]} -gt 0 ]; then
  BATCH_JSON=$(printf '%s\n' "${BATCH_STATEMENTS[@]}" | jq -s '.')
  bash "$GB" "$BATCH_JSON" >/dev/null 2>&1 && GHOSTS_RESOLVED=$((GHOSTS_RESOLVED + ${#BATCH_STATEMENTS[@]})) || true
  BATCH_STATEMENTS=()
fi

echo "  Ghosts resolved: $GHOSTS_RESOLVED"

# ============================================================
# STEP 5: RELATES_TO edge creation (shared topics >= 2)
# ============================================================
echo ""
echo "Step 5: RELATES_TO edge creation..."

if [ "$DRY_RUN" = true ]; then
  # Count how many would be created
  EDGE_RESULT=$(bash "$GS" query "
    MATCH (a:Artifact), (b:Artifact)
    WHERE a.id < b.id
      AND a.topics IS NOT NULL AND size(a.topics) > 0
      AND b.topics IS NOT NULL AND size(b.topics) > 0
      AND size([t IN a.topics WHERE t IN b.topics]) >= 2
      AND NOT (a)-[:RELATES_TO]-(b)
    RETURN count(*) AS would_create
  " '{}' 2>/dev/null) || EDGE_RESULT='{"values":[[0]]}'
  EDGES_CREATED=$(echo "$EDGE_RESULT" | jq -r '.values[0][0] // 0' 2>/dev/null || echo "0")
  echo "  [dry-run] Would create $EDGES_CREATED RELATES_TO edges"
else
  EDGE_RESULT=$(bash "$GS" query "
    MATCH (a:Artifact), (b:Artifact)
    WHERE a.id < b.id
      AND a.topics IS NOT NULL AND size(a.topics) > 0
      AND b.topics IS NOT NULL AND size(b.topics) > 0
      AND size([t IN a.topics WHERE t IN b.topics]) >= 2
      AND NOT (a)-[:RELATES_TO]-(b)
    CREATE (a)-[:RELATES_TO {context: 'topic-derived', updated: datetime()}]->(b)
    RETURN count(*) AS edges_created
  " '{}' 2>/dev/null) || EDGE_RESULT='{"values":[[0]]}'
  EDGES_CREATED=$(echo "$EDGE_RESULT" | jq -r '.values[0][0] // 0' 2>/dev/null || echo "0")
  echo "  Edges created: $EDGES_CREATED"
fi

# ============================================================
# Output
# ============================================================
echo ""
if [ "$DRY_RUN" = true ]; then
  echo "Dry run complete."
fi

echo "{\"topics_backfilled\":${TOPICS_BACKFILLED},\"types_backfilled\":${TYPES_BACKFILLED},\"timestamps_normalized\":${TIMESTAMPS_NORMALIZED},\"ghosts_resolved\":${GHOSTS_RESOLVED},\"edges_created\":${EDGES_CREATED}}"
