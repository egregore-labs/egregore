# shellcheck shell=bash
# context.sh — Context gathering for session-start.sh
#
# Runs 10 parallel background subshells to gather session context:
#   1. Recent handoffs
#   2. Active quests
#   3. User's last git activity
#   3b. Personal todos from graph
#   4. Team presence (graph + git branches)
#   5. Soul self-summary
#   6. Handoffs addressed to user
#   7. Graph health check
#   8. Telegram health check
#   9. Lifecycle events (merged PRs, implemented handoffs)
#   10. Last Pulse brief
#
# All subshells write to $CTX_DIR (a temp directory).
# Ends with `wait` + reading health results back.
#
# Inputs:  SCRIPT_DIR, AUTHOR, LOCAL_MODE, STATE_FILE, CONFIG, ENV_FILE,
#          HEALTH_GRAPH, HEALTH_TELEGRAM
# Outputs: CTX_DIR (populated), TIME_OF_DAY, HEALTH_GRAPH, HEALTH_TELEGRAM

CTX_DIR=$(mktemp -d)

# Time of day
HOUR=$(date +%H)
if [ "$HOUR" -lt 12 ]; then TIME_OF_DAY="morning"
elif [ "$HOUR" -lt 17 ]; then TIME_OF_DAY="afternoon"
else TIME_OF_DAY="evening"
fi

# 1. Recent handoffs (background)
(
  JSON="[]"
  if [ -d "$SCRIPT_DIR/memory/handoffs" ]; then
    FILES=$(find -L "$SCRIPT_DIR/memory/handoffs" -name '*.md' -not -name 'index*' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -3)
    JSON="["
    FIRST=true
    for F in $FILES; do
      [ -z "$F" ] && continue
      NAME=$(basename "$F" .md)
      PREVIEW=$(head -c 120 "$F" 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g')
      $FIRST || JSON="$JSON,"
      JSON="$JSON{\"name\":\"$NAME\",\"preview\":\"$PREVIEW\"}"
      FIRST=false
    done
    JSON="$JSON]"
  fi
  echo "$JSON" > "$CTX_DIR/handoffs"
) &

# 2. Quests (background)
(
  JSON="[]"
  if [ -d "$SCRIPT_DIR/memory/quests" ]; then
    JSON="["
    FIRST=true
    for F in "$SCRIPT_DIR/memory/quests/"*.md; do
      [ -e "$F" ] || continue
      echo "$F" | grep -q draft && continue
      NAME=$(basename "$F" .md)
      $FIRST || JSON="$JSON,"
      JSON="$JSON\"$NAME\""
      FIRST=false
    done
    JSON="$JSON]"
  fi
  echo "$JSON" > "$CTX_DIR/quests"
) &

# 3. User's last activity (background)
(
  git log --author="$AUTHOR" --format="%ar|%s" -1 2>/dev/null > "$CTX_DIR/activity" || echo "" > "$CTX_DIR/activity"
) &

# 3b. Personal todos from graph (background)
(
  _API_URL=$(jq -r '.api_url // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
  _API_KEY=$(grep '^EGREGORE_API_KEY=' "${ENV_FILE:-$SCRIPT_DIR/.env}" 2>/dev/null | cut -d'=' -f2-)
  if [ -n "$_API_URL" ] && [ -n "$_API_KEY" ]; then
    TODO_RAW=$(bash "$SCRIPT_DIR/bin/graph.sh" query \
      "MATCH (t:Todo)-[:BY]->(p:Person {github: \$me}) WHERE t.status IN ['open', 'blocked'] OPTIONAL MATCH (t)-[:PART_OF]->(q:Quest) RETURN t.text AS text, t.priority AS priority, t.status AS status, t.created AS created, q.id AS quest ORDER BY t.priority DESC, t.created DESC LIMIT 5" \
      "$(jq -n --arg me "$AUTHOR" '{me: $me}')" 2>/dev/null || echo "")
    if [ -n "$TODO_RAW" ]; then
      echo "$TODO_RAW" | jq '[.values[] | {text: .[0], priority: (.[1] // 0), status: .[2], created: .[3], quest: (.[4] // "")}]' 2>/dev/null || echo "[]"
    else
      echo "[]"
    fi
  else
    echo "[]"
  fi
) > "$CTX_DIR/todos" 2>/dev/null &

# 4. Team presence — last seen + active branches (background)
(
  # --- Read config inside subshell ---
  _API_URL=$(jq -r '.api_url // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
  _API_KEY=$(grep '^EGREGORE_API_KEY=' "${ENV_FILE:-$SCRIPT_DIR/.env}" 2>/dev/null | cut -d'=' -f2-)

  # --- Graph: last-seen per person (excluding self) ---
  GRAPH_DATA="[]"
  if [ -n "$_API_URL" ] && [ -n "$_API_KEY" ]; then
    CYPHER="MATCH (s:Session)-[:BY]->(p:Person) WHERE p.github <> \$me RETURN p.name AS name, toString(max(s.startedAt)) AS lastSeen ORDER BY lastSeen DESC"
    GRAPH_RAW=$(bash "$SCRIPT_DIR/bin/graph.sh" query "$CYPHER" "$(jq -n --arg me "$AUTHOR" '{me: $me}')" 2>/dev/null || echo "")
    if [ -n "$GRAPH_RAW" ]; then
      GRAPH_DATA=$(echo "$GRAPH_RAW" | jq '[.values[] | {name: .[0], lastSeen: .[1]}]' 2>/dev/null || echo "[]")
    fi
  fi

  # --- Git: active dev/* branches (excluding self) ---
  SELF_LC=$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]')
  SELF_DISPLAY_LC=""
  if [ -f "$SCRIPT_DIR/.egregore-state.json" ]; then
    SELF_DISPLAY_LC=$(jq -r '.display_name // empty' "$SCRIPT_DIR/.egregore-state.json" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  fi
  BRANCH_DATA=$(git -C "$SCRIPT_DIR" branch -r --format='%(refname:short)' 2>/dev/null | grep "^origin/dev/" | sed 's|^origin/dev/||' || echo "")

  BRANCH_MAP="{}"
  if [ -n "$BRANCH_DATA" ]; then
    BRANCH_MAP=$(echo "$BRANCH_DATA" | while IFS='/' read -r B_AUTHOR B_SLUG_REST || [ -n "$B_AUTHOR" ]; do
      [ -z "$B_AUTHOR" ] && continue
      B_AUTHOR_LC=$(echo "$B_AUTHOR" | tr '[:upper:]' '[:lower:]')
      [ "$B_AUTHOR_LC" = "$SELF_LC" ] && continue
      [ -n "$SELF_DISPLAY_LC" ] && [ "$B_AUTHOR_LC" = "$SELF_DISPLAY_LC" ] && continue
      B_HUMAN=$(echo "$B_SLUG_REST" | tr '-' ' ')
      echo "${B_AUTHOR_LC}|${B_HUMAN}"
    done | jq -Rn '
      [inputs | split("|") | {author: .[0], branch: .[1]}]
      | group_by(.author)
      | map({(.[0].author): [.[] | .branch]})
      | add // {}
    ' 2>/dev/null || echo "{}")
  fi

  # --- Local-mode presence: scan session + wrap files for lastSeen ---
  # When graph has no data, these files provide temporal presence information
  FILE_PRESENCE="{}"
  if [ "$GRAPH_DATA" = "[]" ]; then
    FILE_PRESENCE=$(
      {
        # Scan session logs, wraps, and handoffs (all use **Author**: / **Date**: format)
        for DIR in "$SCRIPT_DIR/memory/sessions" "$SCRIPT_DIR/memory/wraps" "$SCRIPT_DIR/memory/handoffs"; do
          [ -d "$DIR" ] || continue
          find -L "$DIR" -name '*.md' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -20 | while read -r SFILE; do
            [ -z "$SFILE" ] && continue
            S_AUTH=$(grep -m1 '^\*\*Author\*\*:' "$SFILE" 2>/dev/null | sed 's/^\*\*Author\*\*:[[:space:]]*//')
            S_DATE=$(grep -m1 '^\*\*Date\*\*:' "$SFILE" 2>/dev/null | sed 's/^\*\*Date\*\*:[[:space:]]*//')
            [ -z "$S_AUTH" ] && continue
            echo "${S_AUTH}|${S_DATE}"
          done
        done
      } | sort -t'|' -k1,1 -k2,2r | sort -t'|' -k1,1 -u | while IFS='|' read -r FP_NAME FP_DATE; do
        [ -z "$FP_NAME" ] && continue
        FP_LC=$(echo "$FP_NAME" | tr '[:upper:]' '[:lower:]')
        echo "${FP_LC}|${FP_DATE}"
      done | jq -Rn '
        [inputs | split("|") | {(.[0]): .[1]}]
        | add // {}
      ' 2>/dev/null || echo "{}"
    )
  fi

  # --- Relative time + epoch helpers (cross-platform) ---
  NOW_EPOCH=$(date +%s)

  iso_to_epoch() {
    local iso="$1"
    local clean=$(echo "$iso" | sed 's/Z$//; s/+00:00$//; s/\.[0-9]*//')
    # If date-only (no T), append midnight to avoid macOS date -j filling current time
    [[ "$clean" != *T* ]] && clean="${clean}T00:00:00"
    if command -v gdate &>/dev/null; then
      gdate -d "$clean" +%s 2>/dev/null || echo "0"
    else
      date -j -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null || echo "0"
    fi
  }

  epoch_to_relative() {
    local epoch="$1"
    [ "$epoch" = "0" ] && echo "--" && return
    local delta=$(( NOW_EPOCH - epoch ))
    if [ "$delta" -lt 60 ]; then echo "just now"
    elif [ "$delta" -lt 3600 ]; then echo "$(( delta / 60 ))m ago"
    elif [ "$delta" -lt 86400 ]; then echo "$(( delta / 3600 ))h ago"
    elif [ "$delta" -lt 172800 ]; then echo "yesterday"
    else echo "$(( delta / 86400 ))d ago"
    fi
  }

  # --- Merge graph + file presence + branches into presence array ---
  ALL_NAMES=$(echo "$GRAPH_DATA" | jq -r '.[].name' 2>/dev/null || echo "")
  FILE_NAMES=$(echo "$FILE_PRESENCE" | jq -r 'keys[]' 2>/dev/null || echo "")
  BRANCH_NAMES=$(echo "$BRANCH_MAP" | jq -r 'keys[]' 2>/dev/null || echo "")

  UNION_NAMES=$(printf "%s\n%s\n%s" "$ALL_NAMES" "$FILE_NAMES" "$BRANCH_NAMES" | tr '[:upper:]' '[:lower:]' | sort -u | grep -v '^$' | grep -v "^${SELF_LC}$" | grep -v "^${SELF_DISPLAY_LC}$" || echo "")

  if [ -z "$UNION_NAMES" ]; then
    echo "[]" > "$CTX_DIR/team"
    exit 0
  fi

  # --- Build presence JSON ---
  PRESENCE="["
  FIRST=true
  for PNAME in $UNION_NAMES; do
    LAST_SEEN_ISO=$(echo "$GRAPH_DATA" | jq -r --arg n "$PNAME" '.[] | select((.name | ascii_downcase) == $n) | .lastSeen // empty' 2>/dev/null | head -1)
    # Fallback to file-based presence (session/wrap files)
    if [ -z "$LAST_SEEN_ISO" ]; then
      LAST_SEEN_ISO=$(echo "$FILE_PRESENCE" | jq -r --arg n "$PNAME" '.[$n] // empty' 2>/dev/null || true)
    fi
    if [ -n "$LAST_SEEN_ISO" ]; then
      LAST_SEEN_EPOCH=$(iso_to_epoch "$LAST_SEEN_ISO")
      LAST_SEEN_REL=$(epoch_to_relative "$LAST_SEEN_EPOCH")
    else
      LAST_SEEN_EPOCH="0"
      LAST_SEEN_REL="--"
    fi

    BRANCHES_JSON=$(echo "$BRANCH_MAP" | jq --arg n "$PNAME" '.[$n] // []' 2>/dev/null || echo "[]")
    BR_COUNT=$(echo "$BRANCHES_JSON" | jq 'length' 2>/dev/null || echo "0")
    if [ "$BR_COUNT" -gt 2 ]; then
      EXTRA=$((BR_COUNT - 2))
      BRANCHES_JSON=$(echo "$BRANCHES_JSON" | jq --arg e "+${EXTRA} more" '[.[0:2][], $e]' 2>/dev/null || echo "$BRANCHES_JSON")
    fi

    ENTRY=$(jq -n --arg name "$PNAME" --arg seen "$LAST_SEEN_REL" --argjson sort "$LAST_SEEN_EPOCH" --argjson branches "$BRANCHES_JSON" \
      '{name: $name, last_seen: $seen, last_seen_sort: $sort, branches: $branches}')
    $FIRST || PRESENCE="$PRESENCE,"
    PRESENCE="$PRESENCE$ENTRY"
    FIRST=false
  done
  PRESENCE="$PRESENCE]"

  PRESENCE=$(echo "$PRESENCE" | jq 'sort_by(-.last_seen_sort)' 2>/dev/null || echo "$PRESENCE")
  echo "$PRESENCE" > "$CTX_DIR/team"
) &

# 5. Soul self-summary (background)
(
  SUMMARY=""
  if [ -f "$SCRIPT_DIR/egregore.md" ]; then
    SUMMARY=$(sed -n '/^## Self-Summary/,/^##/p' "$SCRIPT_DIR/egregore.md" | sed '1d;/^##/d' | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  fi
  echo "$SUMMARY" > "$CTX_DIR/soul_summary"
) &

# 6. Handoffs addressed to user (background, enriched with author/topic)
(
  JSON="[]"
  RICH="[]"
  if [ -d "$SCRIPT_DIR/memory/handoffs" ]; then
    # Match both github username and display name
    _DISPLAY=$(jq -r '.display_name // empty' "$STATE_FILE" 2>/dev/null)
    _GREP_PAT="to: $AUTHOR\|to:$AUTHOR"
    [ -n "$_DISPLAY" ] && [ "$_DISPLAY" != "$AUTHOR" ] && _GREP_PAT="$_GREP_PAT\|to: $_DISPLAY\|to:$_DISPLAY"
    ADDRESSED=$(grep -rl "$_GREP_PAT" "$SCRIPT_DIR/memory/handoffs/" 2>/dev/null | sort -r | head -5 || true)
    JSON="["
    RICH="["
    FIRST=true
    for AF in $ADDRESSED; do
      [ -z "$AF" ] && continue
      AF_NAME=$(basename "$AF" .md)
      AF_AUTHOR=$(sed -n 's/^\*\*Author\*\*: *//p' "$AF" 2>/dev/null | head -1)
      if [ -z "$AF_AUTHOR" ]; then
        AF_AUTHOR=$(sed -n 's/^From: *//p' "$AF" 2>/dev/null | head -1)
      fi
      AF_TOPIC=$(sed -n 's/^# Handoff: *//p' "$AF" 2>/dev/null | head -1)
      if [ -z "$AF_TOPIC" ]; then
        AF_TOPIC=$(sed -n 's/^# *//p' "$AF" 2>/dev/null | head -1)
      fi
      AF_DATE=$(sed -n 's/^\*\*Date\*\*: *//p' "$AF" 2>/dev/null | head -1)
      if [ -z "$AF_DATE" ]; then
        AF_DATE=$(sed -n 's/^Date: *//p' "$AF" 2>/dev/null | head -1)
      fi
      $FIRST || JSON="$JSON,"
      $FIRST || RICH="$RICH,"
      JSON="$JSON\"$AF_NAME\""
      AF_TOPIC_ESC=$(echo "$AF_TOPIC" | sed 's/"/\\"/g')
      AF_AUTHOR_ESC=$(echo "$AF_AUTHOR" | sed 's/"/\\"/g')
      RICH="$RICH{\"name\":\"$AF_NAME\",\"author\":\"$AF_AUTHOR_ESC\",\"topic\":\"$AF_TOPIC_ESC\",\"date\":\"$AF_DATE\"}"
      FIRST=false
    done
    JSON="$JSON]"
    RICH="$RICH]"
  fi
  echo "$JSON" > "$CTX_DIR/addressed"
  echo "$RICH" > "$CTX_DIR/addressed_rich"
) &

# 7. Graph health (background — zero added latency, runs in parallel)
(
  if [ "$LOCAL_MODE" = "true" ]; then
    echo "skip"
  elif bash "$SCRIPT_DIR/bin/graph.sh" test 2>/dev/null | grep -q "Connected"; then
    echo "ok"
  else
    echo "fail"
  fi
) > "$CTX_DIR/graph_health" 2>/dev/null &

# 8. Telegram health (background)
(
  if [ "$LOCAL_MODE" = "true" ]; then
    echo "skip"
  elif bash "$SCRIPT_DIR/bin/notify.sh" test 2>/dev/null | grep -q "connected"; then
    echo "ok"
  else
    echo "fail"
  fi
) > "$CTX_DIR/telegram_health" 2>/dev/null &

# 9. Lifecycle events: merged PRs + implemented handoffs (background)
(
  GH_USER_LC=""
  if [ -f "$STATE_FILE" ]; then
    GH_USER_LC=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null)
  fi
  DISPLAY_NAME_LC=""
  if [ -f "$STATE_FILE" ]; then
    DISPLAY_NAME_LC=$(jq -r '.display_name // empty' "$STATE_FILE" 2>/dev/null)
  fi
  # Get last session end date (use 7 days ago as fallback)
  LAST_END=$(bash "$SCRIPT_DIR/bin/graph.sh" query "
    MATCH (s:Session)-[:BY]->(p:Person {github: \$gh})
    WHERE s.wrappedAt IS NOT NULL
    RETURN toString(s.wrappedAt) AS t
    ORDER BY s.wrappedAt DESC SKIP 1 LIMIT 1
  " "$(jq -n --arg gh "$GH_USER_LC" '{gh: $gh}')" 2>/dev/null | jq -r '.values[0][0] // empty' 2>/dev/null)
  if [ -z "$LAST_END" ]; then
    LAST_END="$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d 2>/dev/null || echo '2026-03-03')T00:00:00Z"
  fi

  MERGED_JSON="[]"
  if [ -n "$GH_USER_LC" ]; then
    MERGED_JSON=$(bash "$SCRIPT_DIR/bin/graph-op.sh" my-merged-prs "$GH_USER_LC" "$(echo "$LAST_END" | cut -dT -f1)" 2>/dev/null || echo "[]")
  fi

  IMPL_JSON="[]"
  IMPL_NAME="${DISPLAY_NAME_LC:-$GH_USER_LC}"
  if [ -n "$IMPL_NAME" ]; then
    IMPL_JSON=$(bash "$SCRIPT_DIR/bin/graph-op.sh" my-implemented-handoffs "$IMPL_NAME" "$(echo "$LAST_END" | cut -dT -f1)" 2>/dev/null || echo "[]")
  fi

  jq -n --argjson merged "$MERGED_JSON" --argjson impl "$IMPL_JSON" \
    '{merged_prs: $merged, implemented_handoffs: $impl}' 2>/dev/null || echo '{"merged_prs":[],"implemented_handoffs":[]}'
) > "$CTX_DIR/lifecycle" 2>/dev/null &

# 10. Last Pulse brief (background) — gated on feature flag + API key
(
  PULSE_ENABLED=$(jq -r '.features.pulse // "false"' "$CONFIG" 2>/dev/null || echo "false")
  HAS_API_KEY=false
  _env_file="${ENV_FILE:-$SCRIPT_DIR/.env}"
  if [ -f "$_env_file" ]; then
    _key=$(grep '^EGREGORE_API_KEY=' "$_env_file" 2>/dev/null | cut -d'=' -f2- || true)
    [ -n "$_key" ] && HAS_API_KEY=true
  fi

  if [ "$PULSE_ENABLED" = "true" ] && [ "$HAS_API_KEY" = "true" ] && [ -n "$GH_USER_LC" ]; then
    BRIEF_RESULT=$(bash "$SCRIPT_DIR/bin/graph.sh" query "
      MATCH (p:Person {github: \$gh})
      WHERE p.lastBrief IS NOT NULL
        AND p.lastBriefDate >= date() - duration('P7D')
      RETURN p.lastBrief, toString(p.lastBriefDate), p.lastRecommendations
    " "$(jq -n --arg gh "$GH_USER_LC" '{gh: $gh}')" 2>/dev/null || echo '{"values":[]}')
    BRIEF=$(echo "$BRIEF_RESULT" | jq -r '.values[0][0] // empty' 2>/dev/null || true)
    BRIEF_DATE=$(echo "$BRIEF_RESULT" | jq -r '.values[0][1] // empty' 2>/dev/null || true)
    RECS=$(echo "$BRIEF_RESULT" | jq -c '.values[0][2] // []' 2>/dev/null || echo '[]')
    if [ -n "$BRIEF" ]; then
      jq -n --arg brief "$BRIEF" --arg date "$BRIEF_DATE" --argjson recs "$RECS" \
        '{brief: $brief, date: $date, recommendations: $recs}'
    else
      echo '{}'
    fi
  else
    echo '{}'
  fi
) > "$CTX_DIR/pulse_brief" 2>/dev/null &

# Wait for all context gathering + health checks to finish
wait

# --- Read service health results ---
GRAPH_RESULT=$(cat "$CTX_DIR/graph_health" 2>/dev/null || echo "")
if [ -n "$GRAPH_RESULT" ]; then HEALTH_GRAPH="$GRAPH_RESULT"; fi
TELEGRAM_RESULT=$(cat "$CTX_DIR/telegram_health" 2>/dev/null || echo "")
if [ -n "$TELEGRAM_RESULT" ]; then HEALTH_TELEGRAM="$TELEGRAM_RESULT"; fi
