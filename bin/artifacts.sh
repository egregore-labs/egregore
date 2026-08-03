#!/bin/bash
# Intentionally NOT `set -euo pipefail`: this is a grep-heavy find tool where
# no-match (grep exit 1) and empty arrays are normal control flow, not errors.

# artifacts.sh — find something you generated, by NAME or CONTENT, and get its URL.
#
# Every generative surface already records into memory, each in its own home:
#   • hosted artifacts (scroll, /view, /reflect, decision surfaces) → artifacts/
#   • handoffs                                                       → handoffs/
#   • emissaries (outbound pointers)                                 → handoffs/outbound/
#   • decisions / findings / patterns (/reflect, /add)               → knowledge/
# The finder searches ALL of them, so anything you made is retrievable by what's
# IN it, not just the name you gave it. Grep-first, so it works with nothing but
# Claude Code / Codex file ops (OSS):
#
#   artifacts find <query...>   rank matches (title/topic beat a body mention)
#   artifacts list [N]          most recently recorded artifacts
#
# In paid mode (search available) `find` also folds in qmd semantic recall, so
# "the artifact where I laid out our GTM plan" resolves even without the words.
# The graph is the third layer — query it via bin/graph.sh for relationships.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MEM="$SCRIPT_DIR/memory"

# All artifact-bearing memory dirs. index.md files are navigation, not artifacts.
_corpus() {
  find \
    "$MEM/artifacts" \
    "$MEM/handoffs" \
    "$MEM/knowledge/decisions" "$MEM/knowledge/findings" "$MEM/knowledge/patterns" \
    -type f -name '*.md' 2>/dev/null | grep -vE '/index\.md$'
}

_field() { # <file> <key> → frontmatter value
  sed -n "/^---$/,/^---$/p" "$1" 2>/dev/null | grep -i "^$2:" | head -1 | cut -d: -f2- | sed 's/^ *//'
}

_title() { # frontmatter title → first "# " heading → filename
  local t; t="$(_field "$1" title)"
  [ -n "$t" ] || t="$(grep -m1 '^# ' "$1" 2>/dev/null | sed 's/^#* *//')"
  [ -n "$t" ] || t="$(basename "$1" .md)"
  printf '%s' "$t"
}

_url() { # frontmatter url → first hosted link in the body
  local u; u="$(_field "$1" url)"
  [ -n "$u" ] || u="$(grep -oE 'https://egregore\.xyz/[^ )>"]+' "$1" 2>/dev/null | head -1)"
  printf '%s' "$u"
}

_tag() { # short source label from path (falls back to frontmatter type)
  case "$1" in
    */handoffs/outbound/*)   printf 'emissary' ;;
    */handoffs/*)            printf 'handoff' ;;
    */knowledge/decisions/*) printf 'decision' ;;
    */knowledge/findings/*)  printf 'finding' ;;
    */knowledge/patterns/*)  printf 'pattern' ;;
    *) local ty; ty="$(_field "$1" type)"; printf '%s' "${ty:-artifact}" ;;
  esac
}

_rel() { printf 'memory/%s' "${1#"$MEM"/}"; }

# Tokenize a query into significant lowercase words (drop tiny/stopwords).
_words() {
  local stop=" the a an is for and or in of to on with our we my me i where " w
  local -a out=()
  for w in $(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9' ' '); do
    [ ${#w} -ge 3 ] || continue
    case "$stop" in *" $w "*) continue ;; esac
    out+=("$w")
  done
  [ ${#out[@]} -gt 0 ] || out=("$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')")
  printf '%s\n' "${out[@]}"
}

# Date N days before today — portable across BSD (date -v) and GNU (date -d).
_days_ago() { date -v-"${1}"d +%Y-%m-%d 2>/dev/null || date -d "${1} days ago" +%Y-%m-%d 2>/dev/null; }

# Parse a relative-time expression out of a query. Echoes "SINCE|UNTIL|CLEANED":
# SINCE/UNTIL are YYYY-MM-DD bounds (empty = unbounded); CLEANED is the query
# with the temporal phrase removed so "yesterday" can't be matched as a keyword.
# Operates on the lowercased query — the finder lowercases anyway.
_time_window() {
  local lc since="" until="" cleaned n
  lc="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"; cleaned="$lc"
  if [[ "$lc" =~ ([0-9]+)[[:space:]]+(day|days|week|weeks)[[:space:]]+ago ]]; then
    n="${BASH_REMATCH[1]}"; case "${BASH_REMATCH[2]}" in week*) n=$((n * 7)) ;; esac
    since="$(_days_ago "$n")"; cleaned="$(printf '%s' "$lc" | sed -E 's/[0-9]+ +(day|days|week|weeks) +ago//')"
  elif [[ "$lc" =~ (last|past)[[:space:]]+([0-9]+)[[:space:]]+(day|days|week|weeks) ]]; then
    n="${BASH_REMATCH[2]}"; case "${BASH_REMATCH[3]}" in week*) n=$((n * 7)) ;; esac
    since="$(_days_ago "$n")"; cleaned="$(printf '%s' "$lc" | sed -E 's/(last|past) +[0-9]+ +(day|days|week|weeks)//')"
  elif [[ "$lc" == *yesterday* ]]; then
    since="$(_days_ago 1)"; until="$since"; cleaned="${lc//yesterday/}"
  elif [[ "$lc" == *today* ]]; then
    since="$(date +%Y-%m-%d)"; until="$since"; cleaned="${lc//today/}"
  elif [[ "$lc" =~ (this|last|past)[[:space:]]+week ]]; then
    since="$(_days_ago 7)"; cleaned="$(printf '%s' "$lc" | sed -E 's/(this|last|past) +week//')"
  elif [[ "$lc" =~ (this|last|past)[[:space:]]+month ]]; then
    since="$(_days_ago 31)"; cleaned="$(printf '%s' "$lc" | sed -E 's/(this|last|past) +month//')"
  elif [[ "$lc" =~ recent|recently|lately ]]; then
    since="$(_days_ago 14)"; cleaned="$(printf '%s' "$lc" | sed -E 's/recently|recent|lately//')"
  elif [[ "$lc" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    since="${BASH_REMATCH[1]}"; until="$since"; cleaned="${lc//${BASH_REMATCH[1]}/}"
  fi
  printf '%s|%s|%s' "$since" "$until" "$cleaned"
}

# Best-effort YYYY-MM-DD for a memory file: filename prefix, handoff dir/day, or
# frontmatter date:. Lets the grep path honor temporal windows too.
_file_date() {
  local f="$1" d dir base
  d="$(basename "$f" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
  [ -n "$d" ] && { printf '%s' "$d"; return; }
  dir="$(basename "$(dirname "$f")")"; base="$(basename "$f")"
  if [[ "$dir" =~ ^[0-9]{4}-[0-9]{2}$ && "$base" =~ ^([0-9]{2})- ]]; then
    printf '%s-%s' "$dir" "${BASH_REMATCH[1]}"; return
  fi
  sed -n '/^---$/,/^---$/p' "$f" 2>/dev/null | grep -i '^date:' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1
}

# Human label for the active window, appended to the result header.
_window_label() {
  if [ -n "$1" ] && [ "$1" = "$2" ]; then printf ' · on %s' "$1"
  elif [ -n "$1" ] && [ -n "$2" ]; then printf ' · %s..%s' "$1" "$2"
  elif [ -n "$1" ]; then printf ' · since %s' "$1"
  elif [ -n "$2" ]; then printf ' · until %s' "$2"; fi
}

# ── grep path — OSS/local, and the connected-mode fallback ──
_grep_find() {
  local query="$1" since="${2:-}" until="${3:-}"
  [ -d "$MEM" ] || { echo "(no memory linked)"; return 0; }
  local words=(); while IFS= read -r w; do words+=("$w"); done < <(_words "$query")

  echo "⌕ artifacts · grep-rank · \"$query\"$(_window_label "$since" "$until")"
  echo

  # Fast path: ONE grep pass narrows 1000s of files to the handful that match
  # any word — scoring the whole corpus per-word in bash is death by subprocess.
  local pat; pat="$(IFS='|'; printf '%s' "${words[*]}")"
  local -a cands=()
  while IFS= read -r f; do [ -n "$f" ] && cands+=("$f"); done \
    < <(_corpus | tr '\n' '\0' | xargs -0 grep -ilE -- "$pat" 2>/dev/null)

  # Score only the candidates. A word in the title/topics/filename outweighs a
  # passing body mention (8 vs 1), so the doc that's ABOUT the query beats one
  # that merely name-drops it. Header check is a bash builtin (no subprocess);
  # only fall back to a full-file grep for words not in the header.
  local hdr base score matched w fd
  local -a scored=()
  for f in "${cands[@]}"; do
    fd="$(_file_date "$f")"
    # Temporal window: when set, drop out-of-range (and undated) files.
    if [ -n "$since" ] || [ -n "$until" ]; then
      [ -n "$fd" ] || continue
      [ -n "$since" ] && [[ "$fd" < "$since" ]] && continue
      [ -n "$until" ] && [[ "$fd" > "$until" ]] && continue
    fi
    base="${f##*/}"
    hdr="$(sed -n '1,25p' "$f" 2>/dev/null | grep -iE '^title:|^topics:|^# ' ; printf '%s' "$base")"
    hdr="$(printf '%s' "$hdr" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    score=0; matched=0
    for w in "${words[@]}"; do
      if [[ "$hdr" == *"$w"* ]]; then
        score=$((score + 8)); matched=$((matched + 1))
      elif grep -qiF -- "$w" "$f" 2>/dev/null; then
        score=$((score + 1)); matched=$((matched + 1))
      fi
    done
    [ "$matched" -gt 0 ] && scored+=("$matched	$score	${fd:-0000-00-00}	$f")
  done

  if [ ${#scored[@]} -eq 0 ]; then
    echo "  no matches across artifacts / handoffs / knowledge."
  else
    # Rank: words matched, then weighted score, then recency (newest first).
    printf '%s\n' "${scored[@]}" | sort -t"	" -k1,1nr -k2,2nr -k3,3r | head -8 | while IFS="	" read -r matched score fd f; do
      local title url rel tag
      title="$(_title "$f")"; url="$(_url "$f")"; rel="$(_rel "$f")"; tag="$(_tag "$f")"
      printf '  ● [%s] %s\n' "$tag" "$title"
      [ -n "$url" ] && printf '    %s\n' "$url"
      printf '    %s  (%d/%d matched · %s)\n\n' "$rel" "$matched" "${#words[@]}" "$fd"
    done
  fi
}

# ── graph path — paid/connected: relevance + relationships, indexed ──
# Returns 0 only when it surfaced results; a miss or an offline graph returns 1
# so cmd_find falls back to grep (which also covers handoffs/emissaries that live
# as Session nodes, not Artifact nodes).
_graph_find() {
  local query="$1" since="${2:-}" until="${3:-}"
  local words=(); while IFS= read -r w; do words+=("$w"); done < <(_words "$query")
  local words_json; words_json="$(jq -nc '$ARGS.positional' --args "${words[@]}")"

  # A word in the title outweighs topics outweighs a passing excerpt mention —
  # same weighting as the grep path, but scored server-side over indexed nodes.
  # The temporal window filters on a.created; ties break by recency (newest first).
  local cypher='MATCH (a:Artifact)
    WHERE any(w IN $words WHERE toLower(a.title) CONTAINS w
              OR toLower(coalesce(a.excerpt,"")) CONTAINS w
              OR any(t IN coalesce(a.topics,[]) WHERE toLower(t) CONTAINS w))
      AND ($since = "" OR (a.created IS NOT NULL AND a.created >= datetime($since)))
      AND ($until = "" OR (a.created IS NOT NULL AND a.created <= datetime($until + "T23:59:59")))
    WITH a, reduce(s=0, w IN $words | s
         + (CASE WHEN toLower(a.title) CONTAINS w THEN 8 ELSE 0 END)
         + (CASE WHEN any(t IN coalesce(a.topics,[]) WHERE toLower(t) CONTAINS w) THEN 5 ELSE 0 END)
         + (CASE WHEN toLower(coalesce(a.excerpt,"")) CONTAINS w THEN 1 ELSE 0 END)) AS score
    OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(p:Person)
    OPTIONAL MATCH (a)-[:PART_OF]->(q:Quest)
    RETURN a.title AS title, a.url AS url, a.type AS type, score,
           collect(DISTINCT p.name)[0] AS author, collect(DISTINCT q.title)[0] AS quest,
           CASE WHEN a.created IS NOT NULL THEN toString(date(a.created)) ELSE "" END AS created
    ORDER BY score DESC, created DESC LIMIT 8'

  local resp; resp="$(bash "$SCRIPT_DIR/bin/graph.sh" query "$cypher" "$(jq -n --argjson words "$words_json" --arg since "$since" --arg until "$until" '{words: $words, since: $since, until: $until}')" 2>/dev/null)"
  local nrows; nrows="$(printf '%s' "$resp" | jq -r '(.values // []) | length' 2>/dev/null || echo 0)"
  [ "${nrows:-0}" -gt 0 ] || return 1

  echo "⌕ artifacts · graph · \"$query\"$(_window_label "$since" "$until")"
  echo
  # Render each row with jq (null-safe): @tsv + bash read collapses null columns
  # because tab is IFS-whitespace. Cols: 0 title,1 url,2 type,3 score,4 author,5 quest,6 created.
  printf '%s' "$resp" | jq -r '
    .values[] |
    "  ● [" + (.[2] // "artifact") + "] " + (.[0] // "(untitled)")
    + (if (.[1] // "") != "" then "\n    " + .[1] else "" end)
    + "\n    graph · score " + (.[3] | tostring)
    + (if (.[6] // "") != "" then " · " + .[6] else "" end)
    + (if (.[4] // "") != "" then " · by " + .[4] else "" end)
    + (if (.[5] // "") != "" then " · " + .[5] else "" end)
    + "\n"'
  return 0
}

cmd_find() {
  # Explicit date bounds (the agent translates arbitrary phrasing into these).
  local since="" until=""
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 ;;
      --until) until="${2:-}"; shift 2 ;;
      --on)    since="${2:-}"; until="${2:-}"; shift 2 ;;
      *)       rest+=("$1"); shift ;;
    esac
  done
  local query="${rest[*]}"
  [ -n "$query" ] || { echo "usage: artifacts find [--since D|--until D|--on D] <query>" >&2; exit 1; }

  # No explicit flags → parse a relative-time expression from the query itself
  # ("… from yesterday", "last week", "on 2026-07-10"), stripping it from the
  # keyword match so it doesn't become dead search noise.
  if [ -z "$since" ] && [ -z "$until" ]; then
    local win cleaned; win="$(_time_window "$query")"
    since="${win%%|*}"; win="${win#*|}"; until="${win%%|*}"; cleaned="${win#*|}"
    cleaned="$(printf '%s' "$cleaned" | sed 's/^ *//; s/ *$//')"
    [ -n "$cleaned" ] && query="$cleaned"
  fi

  # Paid/connected → graph first (relevance + relationships + created, indexed).
  # If the graph is offline or has no match, fall through to grep, which also
  # covers handoffs/emissaries (Session nodes) and is the whole OSS story.
  # EGREGORE_MODE overrides the egregore.json mode (test/OSS-simulation hook).
  local mode; mode="${EGREGORE_MODE:-$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null)}"
  if [ "$mode" != "local" ]; then
    _graph_find "$query" "$since" "$until" && return 0
  fi
  _grep_find "$query" "$since" "$until"
}

cmd_list() {
  local n="${1:-10}"
  [ -d "$MEM" ] || { echo "(no memory linked)"; return 0; }
  _corpus | xargs ls -t 2>/dev/null | head -"$n" | while read -r f; do
    local title url tag
    title="$(_title "$f")"; url="$(_url "$f")"; tag="$(_tag "$f")"
    printf '  ● [%-8s] %-52s %s\n' "$tag" "${title:0:52}" "$url"
  done
}

case "${1:-find}" in
  find) shift; cmd_find "$@" ;;
  list) shift; cmd_list "$@" ;;
  *) cmd_find "$@" ;;
esac
