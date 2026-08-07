# shellcheck shell=bash
# context.sh — Context gathering for session-start.sh
#
# Runs 11 parallel background subshells to gather session context:
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
#   11. Momentum metrics
#
# All subshells write to $CTX_DIR (a temp directory).
# Ends with `wait` + reading health results back.
#
# Inputs:  SCRIPT_DIR, AUTHOR, LOCAL_MODE, STATE_FILE, CONFIG, ENV_FILE,
#          HEALTH_GRAPH, HEALTH_TELEGRAM
# Outputs: CTX_DIR (populated), TIME_OF_DAY, HEALTH_GRAPH, HEALTH_TELEGRAM

CTX_DIR=$(mktemp -d)

source "$SCRIPT_DIR/bin/lib/handoff-meta.sh" >/dev/null 2>/dev/null || true

# Time of day
HOUR=$(date +%H)
if [ "$HOUR" -lt 12 ]; then TIME_OF_DAY="morning"
elif [ "$HOUR" -lt 17 ]; then TIME_OF_DAY="afternoon"
else TIME_OF_DAY="evening"
fi

# --- Attendant-baked seed ---------------------------------------------------
# bin/attendant.sh pre-bakes a context snapshot tar every warm cycle
# (_prebake_context). When the bake is fresh and its provenance matches, reuse
# its purely graph-bound results — todos, lifecycle, pulse, service health —
# and run every collector with local git/file inputs live below (handoffs,
# quests, activity, soul, addressed, questions, team presence, metrics), so
# everything file/git-derived reflects this instant. Purely graph-derived
# fields are then at most one warm cycle stale, and the boot path pays
# near-zero blocking graph round-trips (live collectors ride the warm cache).
#
# The seed is trusted only when ALL of these hold — otherwise fall back to a
# full live gather:
#   - the tar extracts cleanly (atomic rename on the writer side means we see
#     a whole bake or none, never a half-written directory)
#   - .baked-author matches this session's author (shared machines)
#   - .baked-local-mode matches this session's mode (a connected bake must
#     not leak graph data into a session that switched to local)
#   - .baked-config matches this checkout's egregore.json (org/API repoint,
#     or a worktree branch carrying a different config)
#   - .baked-scope matches the EFFECTIVE endpoint/credential fingerprint
#     (EGREGORE_API_URL/KEY overrides can point at a different tenant than
#     the committed config names)
#   - .baked-schema matches this checkout's context.sh revision (a bake from
#     another collector schema may be missing or misformatting files)
#   - .baked-ts is numeric, not in the future, and younger than 15min
#   - every seeded collector's file actually landed in CTX_DIR (a partial
#     copy must not suppress live collectors)
CTX_SEED_USED="false"
if [ -n "${CTX_SEED_TAR:-}" ] && [ -f "${CTX_SEED_TAR:-}" ]; then
  _SEED_TMP=$(mktemp -d)
  if tar -xf "$CTX_SEED_TAR" -C "$_SEED_TMP" 2>/dev/null; then
    _SEED_TS=$(cat "$_SEED_TMP/.baked-ts" 2>/dev/null || echo 0)
    case "$_SEED_TS" in ''|*[!0-9]*) _SEED_TS=0 ;; esac
    _SEED_AUTHOR=$(cat "$_SEED_TMP/.baked-author" 2>/dev/null || echo "")
    _SEED_MODE=$(cat "$_SEED_TMP/.baked-local-mode" 2>/dev/null || echo "")
    _SEED_CONFIG=$(cat "$_SEED_TMP/.baked-config" 2>/dev/null || echo "")
    _SEED_SCOPE=$(cat "$_SEED_TMP/.baked-scope" 2>/dev/null || echo "")
    _SEED_SCHEMA=$(cat "$_SEED_TMP/.baked-schema" 2>/dev/null || echo "")
    _NOW_CONFIG=$(cksum "${CONFIG:-$SCRIPT_DIR/egregore.json}" 2>/dev/null | cut -d' ' -f1)
    _NOW_SCHEMA=$(cksum "$SCRIPT_DIR/bin/lib/context.sh" 2>/dev/null | cut -d' ' -f1)
    # Effective endpoint/credential, mirroring bin/graph.sh's resolution order
    # (process env → .env → committed api_url).
    _NOW_URL="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "${ENV_FILE:-$SCRIPT_DIR/.env}" 2>/dev/null | cut -d'=' -f2- || true)}"
    _NOW_KEY="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "${ENV_FILE:-$SCRIPT_DIR/.env}" 2>/dev/null | cut -d'=' -f2- || true)}"
    [ -n "$_NOW_URL" ] || _NOW_URL=$(jq -r '.api_url // empty' "${CONFIG:-$SCRIPT_DIR/egregore.json}" 2>/dev/null)
    _NOW_SCOPE=$(echo -n "${_NOW_URL}|${_NOW_KEY}" | cksum | cut -d' ' -f1)
    _SEED_AGE=$(( $(date +%s) - _SEED_TS ))
    if [ -n "$_SEED_AUTHOR" ] && [ "$_SEED_AUTHOR" = "$AUTHOR" ] \
      && [ "$_SEED_MODE" = "${LOCAL_MODE:-false}" ] \
      && [ -n "$_SEED_CONFIG" ] && [ "$_SEED_CONFIG" = "$_NOW_CONFIG" ] \
      && [ -n "$_SEED_SCOPE" ] && [ "$_SEED_SCOPE" = "$_NOW_SCOPE" ] \
      && [ -n "$_SEED_SCHEMA" ] && [ "$_SEED_SCHEMA" = "$_NOW_SCHEMA" ] \
      && [ "$_SEED_AGE" -ge 0 ] && [ "$_SEED_AGE" -lt 900 ]; then
      if cp "$_SEED_TMP"/* "$CTX_DIR/" 2>/dev/null; then
        # Completeness: every collector this seed replaces must be present.
        CTX_SEED_USED="true"
        for _SEED_REQ in todos lifecycle pulse_brief graph_health telegram_health; do
          [ -f "$CTX_DIR/$_SEED_REQ" ] || { CTX_SEED_USED="false"; break; }
        done
      fi
    fi
  fi
  rm -rf "$_SEED_TMP"
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
      case "$F" in *draft*) continue ;; esac
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

# 3b. Personal todos from graph (background; seeded)
[ "$CTX_SEED_USED" != "true" ] && (
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
# Always live, even when seeded: its branch/file inputs are local and cheap
# (single awk/jq passes), and stale "last seen 2m ago" lines are the most
# user-visible form of drift. The one graph query inside rides the warm cache.
(
  # --- Read config inside subshell ---
  _API_URL=$(jq -r '.api_url // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
  _API_KEY=$(grep '^EGREGORE_API_KEY=' "${ENV_FILE:-$SCRIPT_DIR/.env}" 2>/dev/null | cut -d'=' -f2-)

  # --- Graph: last-seen per person (excluding self) ---
  GRAPH_DATA="[]"
  if [ -n "$_API_URL" ] && [ -n "$_API_KEY" ]; then
    # String-compare the temporals: `datetime(s.date)` is an invalid cast when
    # s.date is a Date (Neo.ClientError.Statement.TypeError), which made this
    # query fail silently on every boot — GRAPH_DATA stayed empty, the greeting
    # fell back to git/file presence, and the FILE_PRESENCE scan below ran in
    # connected mode too. ISO-8601 strings order lexicographically, so max()
    # over toString() is correct across DateTime, Date, and legacy string rows.
    CYPHER="MATCH (s:Session)-[:BY]->(p:Person) WHERE p.github <> \$me RETURN p.name AS name, max(coalesce(toString(s.startedAt), toString(s.date))) AS lastSeen ORDER BY lastSeen DESC"
    GRAPH_RAW=$(bash "$SCRIPT_DIR/bin/graph.sh" query "$CYPHER" "$(jq -n --arg me "$AUTHOR" '{me: $me}')" 2>/dev/null || echo "")
    if [ -n "$GRAPH_RAW" ]; then
      GRAPH_DATA=$(echo "$GRAPH_RAW" | jq '[.values[] | {name: .[0], lastSeen: .[1]}]' 2>/dev/null || echo "[]")
    fi
  fi

  # --- Git: branch tip commit dates per person (primary recency signal) ---
  # git for-each-ref is fast and gives the actual last commit date per branch.
  # Single awk pass — the previous per-branch cut+tr loop spawned 3 processes
  # per ref, and busy orgs carry hundreds of origin/dev/* refs. Refs arrive
  # sorted by -committerdate, so the first epoch per author is their newest.
  GIT_COMMIT_DATA="{}"
  GIT_REF_DATA=$(git -C "$SCRIPT_DIR" for-each-ref --sort=-committerdate \
    --format='%(refname:short)|%(committerdate:unix)' refs/remotes/origin/dev/ 2>/dev/null || echo "")
  if [ -n "$GIT_REF_DATA" ]; then
    GIT_COMMIT_DATA=$(printf '%s\n' "$GIT_REF_DATA" | awk -F'|' '
      {
        p = $1; sub(/^origin\/dev\//, "", p)
        split(p, seg, "/"); a = tolower(seg[1])
        if (a != "" && !(a in best)) best[a] = $2
      }
      END { for (a in best) printf "%s|%s\n", a, best[a] }
    ' 2>/dev/null | jq -Rn '
      [inputs | split("|") | {(.[0]): .[1]}]
      | add // {}
    ' 2>/dev/null || echo "{}")
    [ -z "$GIT_COMMIT_DATA" ] && GIT_COMMIT_DATA="{}"
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
    # Single awk pass — the previous per-branch echo+tr loop spawned 2-4
    # processes per branch over hundreds of refs.
    BRANCH_MAP=$(printf '%s\n' "$BRANCH_DATA" | awk -v self="$SELF_LC" -v selfd="$SELF_DISPLAY_LC" '
      {
        if (split($0, seg, "/") < 2) next
        a = tolower(seg[1])
        if (a == "" || a == self || (selfd != "" && a == selfd)) next
        h = $0; sub(/^[^\/]*\//, "", h); gsub(/-/, " ", h)
        printf "%s|%s\n", a, h
      }
    ' 2>/dev/null | jq -Rn '
      [inputs | split("|") | {author: .[0], branch: (.[1:] | join("|"))}]
      | group_by(.author)
      | map({(.[0].author): [.[] | .branch]})
      | add // {}
    ' 2>/dev/null || echo "{}")
    [ -z "$BRANCH_MAP" ] && BRANCH_MAP="{}"
  fi

  # --- Local-mode presence: scan session + wrap files for lastSeen ---
  # When graph has no data, these files provide temporal presence information.
  # Single awk pass over all candidate files — the previous per-file
  # grep+sed loop spawned 2-3 processes per file (~60 files) on every boot.
  FILE_PRESENCE="{}"
  if [ "$GRAPH_DATA" = "[]" ]; then
    FP_FILES=$(for DIR in "$SCRIPT_DIR/memory/sessions" "$SCRIPT_DIR/memory/wraps" "$SCRIPT_DIR/memory/handoffs"; do
      [ -d "$DIR" ] || continue
      find -L "$DIR" -name '*.md' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -20
    done)
    if [ -n "$FP_FILES" ]; then
      FILE_PRESENCE=$(printf '%s\n' "$FP_FILES" | tr '\n' '\0' | xargs -0 awk '
        function flush() { if (a != "") printf "%s|%s\n", a, d }
        FNR == 1 { if (NR != 1) flush(); a=""; d="" }
        a == "" && /^\*\*Author\*\*:/ { s = $0; sub(/^\*\*Author\*\*:[ \t]*/, "", s); a = s }
        d == "" && /^\*\*Date\*\*:/   { s = $0; sub(/^\*\*Date\*\*:[ \t]*/, "", s); d = s }
        END { flush() }
      ' 2>/dev/null \
        | sort -t'|' -k1,1 -k2,2r | sort -t'|' -k1,1 -u \
        | awk -F'|' '{ print tolower($1) "|" $2 }' \
        | jq -Rn '
          [inputs | split("|") | {(.[0]): .[1]}]
          | add // {}
        ' 2>/dev/null || echo "{}")
      [ -z "$FILE_PRESENCE" ] && FILE_PRESENCE="{}"
    fi
  fi

  # --- "Working on": latest session/handoff/wrap topic per person (file-based) ---
  # Gives every team surface (greeting "around", dashboard) something legible in
  # local mode, where git branches are usually empty for teammates.
  # Single awk pass — the previous per-file grep+sed loop spawned ~6 processes
  # per file over ~90 files on every boot.
  _WM_TAB=$(printf '\t')
  WM_FILES=$(for DIR in "$SCRIPT_DIR/memory/sessions" "$SCRIPT_DIR/memory/handoffs" "$SCRIPT_DIR/memory/wraps"; do
    [ -d "$DIR" ] || continue
    find -L "$DIR" -name '*.md' -not -name 'index*' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -30
  done)
  WORK_MAP="{}"
  if [ -n "$WM_FILES" ]; then
    WORK_MAP=$(printf '%s\n' "$WM_FILES" | tr '\n' '\0' | xargs -0 awk '
      function flush() { if (a != "" && t != "") printf "%s\t%s\t%s\n", a, d, t }
      FNR == 1 { if (NR != 1) flush(); a=""; d=""; t="" }
      a == "" && /^\*\*Author\*\*:/ { s = $0; sub(/^\*\*Author\*\*:[ \t]*/, "", s); a = s }
      d == "" && /^\*\*Date\*\*:/   { s = $0; sub(/^\*\*Date\*\*:[ \t]*/, "", s); d = s }
      t == "" && /^# / {
        s = $0; sub(/^#[ \t]*/, "", s)
        sub(/^Session:[ \t]*/, "", s); sub(/^Handoff:[ \t]*/, "", s); sub(/^Wrap:[ \t]*/, "", s)
        t = s
      }
      END { flush() }
    ' 2>/dev/null \
      | sort -t"$_WM_TAB" -k1,1 -k2,2r | sort -t"$_WM_TAB" -k1,1 -u \
      | awk -F"$_WM_TAB" '{ print tolower($1) "\t" $3 }' \
      | jq -Rn '[inputs | split("\t") | select(length >= 2) | {(.[0]): (.[1] // "")}] | add // {}' 2>/dev/null || echo "{}")
    [ -z "$WORK_MAP" ] && WORK_MAP="{}"
  fi

  # --- Merge git commits + graph + file presence + branches into presence array ---
  # One jq pass. The previous version looped over the name union in bash,
  # spawning ~8 jq/date processes per teammate — at 16+ teammates that was the
  # single largest block of session-start's boot time (~5s). All epoch parsing,
  # relative-time formatting, merging, and sorting now happens inside jq.
  # Git commit date is authoritative (actual work shipped); graph/file presence
  # are fallbacks only (session opens ≠ real activity).
  NOW_EPOCH=$(date +%s)
  PRESENCE=$(jq -nc \
    --argjson graph "$GRAPH_DATA" \
    --argjson git "$GIT_COMMIT_DATA" \
    --argjson branches "$BRANCH_MAP" \
    --argjson files "$FILE_PRESENCE" \
    --argjson work "$WORK_MAP" \
    --arg now "$NOW_EPOCH" --arg self "$SELF_LC" --arg selfdisp "$SELF_DISPLAY_LC" '
    def iso2e:
      if . == null or . == "" then 0
      else (sub("Z$"; "") | sub("\\+00:00$"; "") | sub("\\.[0-9]+"; "")
            | (if test("T") then . else . + "T00:00:00" end)
            | (try (strptime("%Y-%m-%dT%H:%M:%S") | mktime) catch 0))
      end;
    def day: (try strflocaltime("%Y-%m-%d") catch (gmtime | strftime("%Y-%m-%d")));
    def rel($nowe): . as $e |
      if $e <= 0 then "--"
      else ($nowe - $e) as $d |
        if $d < 60 then "just now"
        elif $d < 3600 then "\($d / 60 | floor)m ago"
        elif $d < 86400 then "\($d / 3600 | floor)h ago"
        elif ($e | day) == ($nowe | day) then "today"
        else
          ((try (($nowe | day | strptime("%Y-%m-%d") | mktime)
               - ($e | day | strptime("%Y-%m-%d") | mktime)) catch $d) / 86400
           | floor | if . < 1 then 1 else . end) as $days |
          if $days == 1 then "yesterday" else "\($days)d ago" end
        end
      end;
    ($now | tonumber) as $nowe |
    ($graph
      | map({key: ((.name // "") | ascii_downcase), value: (.lastSeen // "")})
      | group_by(.key)
      | map({key: .[0].key, value: (map(.value) | max)})
      | from_entries) as $g |
    ([($g, $files, $branches, $git) | keys[]] | map(ascii_downcase) | unique
      | map(select(. != "" and . != $self and . != $selfdisp))) as $names |
    [ $names[] | . as $n |
      (($git[$n] // "0") | (try tonumber catch 0)) as $ge |
      (if $ge > 0 then $ge
       else ((($g[$n] // "") | iso2e) as $gge |
             if $gge > 0 then $gge else (($files[$n] // "") | iso2e) end)
       end) as $epoch |
      ($branches[$n] // []) as $b |
      { name: $n,
        last_seen: ($epoch | rel($nowe)),
        last_seen_sort: $epoch,
        branches: (if ($b | length) > 2 then ($b[0:2] + ["+\(($b | length) - 2) more"]) else $b end),
        working_on: ($work[$n] // "") }
    ] | sort_by(-.last_seen_sort)
  ' 2>/dev/null || echo "[]")
  echo "${PRESENCE:-[]}" > "$CTX_DIR/team"
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
    # One definition everywhere: in connected mode the list comes from the
    # graph's open-handoffs named read (open = pending/unread/read/claimed,
    # matched by name/github/aliases) — the same definition the dashboard
    # uses. The file grep below stays as the local-mode/offline fallback.
    ADDRESSED=""
    if [ "${LOCAL_MODE:-false}" != "true" ]; then
      _GRAPH_LIST=$(bash "$SCRIPT_DIR/bin/graph-op.sh" open-handoffs "$AUTHOR" 5 2>/dev/null || true)
      if echo "$_GRAPH_LIST" | jq -e '.values | length > 0' >/dev/null 2>&1; then
        ADDRESSED=$(echo "$_GRAPH_LIST" | jq -r '.values[][0]' 2>/dev/null | awk '!seen[$0]++' | while IFS= read -r _SID; do
          # Two on-disk layouts: dated subdirs (YYYY-MM/DD-slug.md, the id's
          # own shape) and flat files at the handoffs root. Probe both, else
          # a graph-listed handoff silently vanishes from the greeting.
          _MONTH="${_SID:0:7}"
          _REST="${_SID:8}"
          _F="$SCRIPT_DIR/memory/handoffs/$_MONTH/$_REST.md"
          if [ -f "$_F" ]; then
            echo "$_F"
          elif [ -f "$SCRIPT_DIR/memory/handoffs/$_SID.md" ]; then
            echo "$SCRIPT_DIR/memory/handoffs/$_SID.md"
          fi
        done | head -5)
      fi
    fi
    # Match github username, display name, github_name first word, and people-file name
    # Handoff files may use "to: name", "**To**: name", or "To: name"
    _DISPLAY=$(jq -r '.display_name // empty' "$STATE_FILE" 2>/dev/null)
    _GH_NAME=$(jq -r '.github_name // empty' "$STATE_FILE" 2>/dev/null)
    _FIRST_NAME=$(echo "$_GH_NAME" | awk '{print $1}')
    # Also check people file: memory/people/{author}.md has "# Name" on first line
    _PEOPLE_NAME=""
    _PEOPLE_FILE="$SCRIPT_DIR/memory/people/$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]').md"
    [ -f "$_PEOPLE_FILE" ] && _PEOPLE_NAME=$(sed -n 's/^# *//p' "$_PEOPLE_FILE" 2>/dev/null | head -1)
    _GREP_PAT="[Tt]o[*]*: *$AUTHOR\|[Tt]o[*]*:$AUTHOR"
    for _VARIANT in "$_DISPLAY" "$_FIRST_NAME" "$_PEOPLE_NAME"; do
      [ -z "$_VARIANT" ] && continue
      [ "$_VARIANT" = "$AUTHOR" ] && continue
      # Skip if already in pattern (avoid duplicates)
      echo "$_GREP_PAT" | grep -qF "$_VARIANT" && continue
      _GREP_PAT="$_GREP_PAT\|[Tt]o[*]*: *$_VARIANT\|[Tt]o[*]*:$_VARIANT"
    done
    if [ -z "$ADDRESSED" ]; then
      ADDRESSED=$(grep -rli "$_GREP_PAT" "$SCRIPT_DIR/memory/handoffs/" 2>/dev/null | sort -r | head -5 || true)
    fi
    JSON="["
    RICH="["
    FIRST=true
    for AF in $ADDRESSED; do
      [ -z "$AF" ] && continue
      AF_NAME=$(basename "$AF" .md)
      AF_AUTHOR=$(eg_handoff_author "$AF")
      AF_TOPIC=$(eg_handoff_topic "$AF")
      AF_DATE=$(eg_handoff_date "$AF")
      # Extract repo state table if present
      AF_REPO_STATE="[]"
      AF_REPO_TABLE=$(awk '/^## Repo State/{found=1; next} found && /^#/{exit} found && /^\|[^-]/ && !/^\| Repo/{print}' "$AF" 2>/dev/null || true)
      if [ -n "$AF_REPO_TABLE" ]; then
        AF_REPO_STATE=$(echo "$AF_REPO_TABLE" | while IFS='|' read -r _ R_REPO R_BRANCH R_PR R_BASE _; do
          R_REPO=$(echo "$R_REPO" | xargs 2>/dev/null || true)
          R_BRANCH=$(echo "$R_BRANCH" | xargs 2>/dev/null || true)
          R_PR=$(echo "$R_PR" | xargs 2>/dev/null | sed 's/^#//' | sed 's/—//' || true)
          R_BASE=$(echo "$R_BASE" | xargs 2>/dev/null || true)
          [ -z "$R_REPO" ] && continue
          if [ -n "$R_PR" ] && [ "$R_PR" -eq "$R_PR" ] 2>/dev/null; then
            printf '{"repo":"%s","branch":"%s","pr":%s,"base":"%s"}\n' "$R_REPO" "$R_BRANCH" "$R_PR" "$R_BASE"
          else
            printf '{"repo":"%s","branch":"%s","pr":null,"base":"%s"}\n' "$R_REPO" "$R_BRANCH" "$R_BASE"
          fi
        done | jq -sc '.' 2>/dev/null || echo "[]")
      fi
      $FIRST || JSON="$JSON,"
      $FIRST || RICH="$RICH,"
      JSON="$JSON\"$AF_NAME\""
      AF_ENTRY=$(jq -cn \
        --arg name "$AF_NAME" \
        --arg author "$AF_AUTHOR" \
        --arg topic "$AF_TOPIC" \
        --arg date "$AF_DATE" \
        --argjson repoState "$AF_REPO_STATE" \
        '{name:$name, author:$author, topic:$topic, date:$date, repoState:$repoState}' 2>/dev/null || echo "{}")
      RICH="$RICH$AF_ENTRY"
      FIRST=false
    done
    JSON="$JSON]"
    RICH="$RICH]"
  fi
  echo "$JSON" > "$CTX_DIR/addressed"
  echo "$RICH" > "$CTX_DIR/addressed_rich"
) &

# 6.5. Pending questions addressed to user (background)
(
  PENDING_JSON="[]"
  QDIR="$SCRIPT_DIR/memory/knowledge/questions"
  if [ -d "$QDIR" ]; then
    # Match against the same identity variants used for handoffs (display name,
    # github first-name, people-file name) so "to: oz" matches author "oguzhan".
    _DISPLAY_Q=$(jq -r '.display_name // empty' "$STATE_FILE" 2>/dev/null)
    _GH_NAME_Q=$(jq -r '.github_name // empty' "$STATE_FILE" 2>/dev/null)
    _FIRST_NAME_Q=$(echo "$_GH_NAME_Q" | awk '{print tolower($1)}')
    _PEOPLE_FILE_Q="$SCRIPT_DIR/memory/people/$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]').md"
    _PEOPLE_NAME_Q=""
    [ -f "$_PEOPLE_FILE_Q" ] && _PEOPLE_NAME_Q=$(sed -n 's/^# *//p' "$_PEOPLE_FILE_Q" 2>/dev/null | head -1 | awk '{print tolower($1)}')

    LINES=""
    for QF in "$QDIR"/*.md; do
      [ -f "$QF" ] || continue
      Q_TO=$(sed -n 's/^to:[[:space:]]*//p' "$QF" 2>/dev/null | head -1 | tr -d '"' | tr '[:upper:]' '[:lower:]' | awk '{print $1}')
      [ -z "$Q_TO" ] && continue
      _MATCH="false"
      for _V in "$AUTHOR" "$_DISPLAY_Q" "$_FIRST_NAME_Q" "$_PEOPLE_NAME_Q"; do
        [ -z "$_V" ] && continue
        _V_LC=$(echo "$_V" | tr '[:upper:]' '[:lower:]')
        [ "$Q_TO" = "$_V_LC" ] && _MATCH="true" && break
      done
      [ "$_MATCH" = "true" ] || continue
      Q_STATUS=$(sed -n 's/^status:[[:space:]]*//p' "$QF" 2>/dev/null | head -1 | tr -d '"')
      [ "$Q_STATUS" = "pending" ] || continue
      Q_FROM=$(sed -n 's/^from:[[:space:]]*//p' "$QF" 2>/dev/null | head -1 | tr -d '"')
      Q_TOPIC=$(sed -n 's/^topic:[[:space:]]*//p' "$QF" 2>/dev/null | head -1 | tr -d '"')
      Q_HID=$(sed -n 's/^harvest_id:[[:space:]]*//p' "$QF" 2>/dev/null | head -1 | tr -d '"')
      Q_REL="${QF#$SCRIPT_DIR/}"
      LINE=$(jq -nc \
        --arg from "$Q_FROM" \
        --arg topic "$Q_TOPIC" \
        --arg hid "$Q_HID" \
        --arg file "$Q_REL" \
        '{from:$from, topic:$topic, harvest_id:$hid, file:$file}' 2>/dev/null)
      [ -n "$LINE" ] && LINES="$LINES$LINE
"
    done
    if [ -n "$LINES" ]; then
      PENDING_JSON=$(echo "$LINES" | jq -sc '.' 2>/dev/null || echo "[]")
    fi
  fi
  echo "$PENDING_JSON" > "$CTX_DIR/pending_questions"
) &

# 7. Graph health (background — zero added latency, runs in parallel; seeded)
[ "$CTX_SEED_USED" != "true" ] && (
  if [ "$LOCAL_MODE" = "true" ]; then
    echo "skip"
  elif bash "$SCRIPT_DIR/bin/graph.sh" test 2>/dev/null | grep -q "Connected"; then
    echo "ok"
  else
    echo "fail"
  fi
) > "$CTX_DIR/graph_health" 2>/dev/null &

# 8. Telegram health (background)
# notify.sh test emits JSON, not prose: {"status":"ok"} connected,
# {"status":"configured"} local, {"status":"offline"} otherwise. Match the
# status field — an earlier grep for the word "connected" read a human sentence
# that the consent rewrite removed, so the footer showed telegram ✗ while the
# bot was answering.
[ "$CTX_SEED_USED" != "true" ] && (
  if [ "$LOCAL_MODE" = "true" ]; then
    echo "skip"
  elif bash "$SCRIPT_DIR/bin/notify.sh" test 2>/dev/null \
    | jq -e '.status == "ok" or .status == "configured"' >/dev/null 2>&1; then
    echo "ok"
  else
    echo "fail"
  fi
) > "$CTX_DIR/telegram_health" 2>/dev/null &

# 9. Lifecycle events: merged PRs + implemented handoffs (background; seeded)
[ "$CTX_SEED_USED" != "true" ] && (
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

# 10. Last Pulse brief (background) — gated on feature flag + API key; seeded
[ "$CTX_SEED_USED" != "true" ] && (
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

# 11. Momentum metrics (background)
# Always live, even when seeded: _metrics_gather mixes graph reads (which ride
# the warm cache) with local git/file scans — sessions, commits, handoffs,
# knowledge — whose freshness the greeting should reflect this instant.
(
  source "$SCRIPT_DIR/bin/lib/metrics.sh"
  _metrics_gather
) > "$CTX_DIR/metrics" 2>/dev/null &

# Wait for all context gathering + health checks to finish
wait

# --- Read service health results ---
GRAPH_RESULT=$(cat "$CTX_DIR/graph_health" 2>/dev/null || echo "")
if [ -n "$GRAPH_RESULT" ]; then HEALTH_GRAPH="$GRAPH_RESULT"; fi
TELEGRAM_RESULT=$(cat "$CTX_DIR/telegram_health" 2>/dev/null || echo "")
if [ -n "$TELEGRAM_RESULT" ]; then HEALTH_TELEGRAM="$TELEGRAM_RESULT"; fi
