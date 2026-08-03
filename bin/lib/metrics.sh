# shellcheck shell=bash
# metrics.sh — Momentum metrics gathering and rendering for startup greetings.
#
# Function-only library. Safe to source from bash or zsh.

_metrics_zero_json() {
  printf '%s\n' '{"source":"local","sessions":{"buckets":[0,0,0,0,0],"week":0,"prev":0,"all":0},"commits":{"buckets":[0,0,0,0,0],"week":0,"prev":0,"authors":0,"all":0},"handoffs":{"buckets":[0,0,0,0,0],"week":0,"prev":0,"avg_resolution_days":null,"all":0},"knowledge":{"buckets":[0,0,0,0,0],"week":0,"prev":0,"all":0},"members":{"active":0,"total":0}}'
}

_num() {
  awk '{n=$1+0; if (n < 0) n=0; printf "%d\n", n}' 2>/dev/null <<EOF
$1
EOF
}

_num_float() {
  awk '{n=$1+0; if (n < 0) n=0; printf "%.1f\n", n}' 2>/dev/null <<EOF
$1
EOF
}

_normalize_buckets() {
  set -- $(printf '%s' "$1")
  printf '%d %d %d %d %d\n' "$(_num "${1:-0}")" "$(_num "${2:-0}")" "$(_num "${3:-0}")" "$(_num "${4:-0}")" "$(_num "${5:-0}")"
}

_buckets_json() {
  set -- $(printf '%s' "$(_normalize_buckets "$1")")
  jq -n --argjson a "$(_num "${1:-0}")" --argjson b "$(_num "${2:-0}")" \
    --argjson c "$(_num "${3:-0}")" --argjson d "$(_num "${4:-0}")" \
    --argjson e "$(_num "${5:-0}")" '[$a,$b,$c,$d,$e]' 2>/dev/null || echo '[0,0,0,0,0]'
}

_bucket_week() {
  set -- $(printf '%s' "$(_normalize_buckets "$1")")
  _num "${5:-0}"
}

_bucket_prev() {
  set -- $(printf '%s' "$(_normalize_buckets "$1")")
  _num "${4:-0}"
}

_spark() {
  local values max out v idx glyph
  values="${1:-0 0 0 0 0}"
  max=0
  set -- $(printf '%s' "$values")
  [ "$#" -eq 0 ] && set -- 0 0 0 0 0
  for v in "$@"; do
    v=$(_num "$v")
    [ "$v" -gt "$max" ] 2>/dev/null && max="$v"
  done
  out=""
  for v in "$@"; do
    v=$(_num "$v")
    if [ "$max" -le 0 ] 2>/dev/null; then
      idx=0
    else
      idx=$(( (v * 7) / max ))
    fi
    # Select glyphs explicitly: substring slicing can split UTF-8 characters
    # under Bash 3.2 or a C locale.
    case "$idx" in
      0) glyph="▁" ;;
      1) glyph="▂" ;;
      2) glyph="▃" ;;
      3) glyph="▄" ;;
      4) glyph="▅" ;;
      5) glyph="▆" ;;
      6) glyph="▇" ;;
      *) glyph="█" ;;
    esac
    out="${out}${glyph}"
  done
  printf '%s\n' "$out"
}

_pct_delta() {
  local cur prev pct
  cur=$(_num "${1:-0}")
  prev=$(_num "${2:-0}")
  [ "$prev" -le 0 ] 2>/dev/null && return 0
  pct=$(( ((cur - prev) * 100) / prev ))
  if [ "$pct" -gt 0 ] 2>/dev/null; then
    printf '↑ %d%%\n' "$pct"
  elif [ "$pct" -lt 0 ] 2>/dev/null; then
    printf '↓ %d%%\n' "$(( -pct ))"
  else
    printf '→ 0%%\n'
  fi
}

_commafy() {
  awk '
    function comma(s, out, sign) {
      s = int(s + 0)
      if (s < 0) { sign = "-"; s = -s } else { sign = "" }
      s = sprintf("%d", s)
      out = ""
      while (length(s) > 3) {
        out = "," substr(s, length(s) - 2, 3) out
        s = substr(s, 1, length(s) - 3)
      }
      return sign s out
    }
    { print comma($1) }
  ' 2>/dev/null <<EOF
${1:-0}
EOF
}

_git_added_buckets() {
  local repo now paths
  repo="$1"
  shift
  now=$(date +%s)
  if [ -d "$repo" ] || [ -f "$repo" ]; then
    git -C "$repo" log --diff-filter=A --since="35 days ago" --format='%ct' -- "$@" 2>/dev/null | \
      awk -v now="$now" '
        BEGIN { for (i=0;i<5;i++) b[i]=0 }
        /^[0-9]+$/ {
          days = int((now - $1) / 86400)
          idx = 4 - int(days / 7)
          if (idx >= 0 && idx < 5) b[idx]++
        }
        END { printf "%d %d %d %d %d\n", b[0], b[1], b[2], b[3], b[4] }
      ' 2>/dev/null || echo "0 0 0 0 0"
  else
    echo "0 0 0 0 0"
  fi
}

_find_count_md() {
  find -L "$@" -name '*.md' ! -name 'index*' 2>/dev/null | wc -l | awk '{print $1+0}' 2>/dev/null || echo 0
}

_metrics_gather() {
  local _root _mem _scratch _API_URL _API_KEY _connected
  _root="${SCRIPT_DIR:-$PWD}"
  _mem="$_root/memory"
  _scratch=$(mktemp -d 2>/dev/null || mktemp -d -t egregore-metrics)
  _API_URL=$(jq -r '.api_url // empty' "$_root/egregore.json" 2>/dev/null || echo "")
  _API_KEY=$(grep '^EGREGORE_API_KEY=' "${ENV_FILE:-$_root/.env}" 2>/dev/null | cut -d'=' -f2- || true)
  _connected=false
  [ -n "$_API_URL" ] && [ -n "$_API_KEY" ] && _connected=true

  (
    if [ "$_connected" = true ]; then
      raw=$(bash "$_root/bin/graph.sh" query "MATCH (s:Session) WHERE date(s.date) >= date() - duration('P35D')
OPTIONAL MATCH (s)-[:BY]->(p:Person)
WITH duration.inDays(date(s.date), date()).days / 7 AS weeksAgo,
     count(s) AS sessions, count(DISTINCT p) AS people
RETURN weeksAgo, sessions, people ORDER BY weeksAgo" 2>/dev/null || echo "")
      printf '%s' "$raw" | jq -r '
        (.values // []) as $v
        | if ($v|length) == 0 then empty else
          reduce $v[] as $r ({b:[0,0,0,0,0], a:0, ok:0};
            ($r[0] // 99 | tonumber? // 99) as $w
            | if $w >= 0 and $w <= 4 then
                .b[4 - $w] = (($r[1] // 0 | tonumber? // 0) | floor)
                | .ok = 1
                | if $w == 0 then .a = (($r[2] // 0 | tonumber? // 0) | floor) else . end
              else . end)
          | "\(.b|join(" "))|\(.a)|\(.ok)"
          end
      ' 2>/dev/null || echo "0 0 0 0 0|0|0"
    else
      echo "0 0 0 0 0|0|0"
    fi
  ) > "$_scratch/graph_sessions" 2>/dev/null &

  (
    if [ "$_connected" = true ]; then
      raw=$(bash "$_root/bin/graph.sh" query "MATCH (s:Session) WITH count(s) AS totalSessions MATCH (p:Person)-[:MEMBER_OF]->(:Org) RETURN totalSessions, count(DISTINCT p) AS members" 2>/dev/null || echo "")
      total=$(printf '%s' "$raw" | jq -r '.values[0][0] // 0' 2>/dev/null || echo 0)
      members=$(printf '%s' "$raw" | jq -r '.values[0][1] // 0' 2>/dev/null || echo 0)
      if [ "$(_num "$members")" -eq 0 ] 2>/dev/null; then
        raw2=$(bash "$_root/bin/graph.sh" query "MATCH (p:Person) RETURN count(p)" 2>/dev/null || echo "")
        members=$(printf '%s' "$raw2" | jq -r '.values[0][0] // 0' 2>/dev/null || echo 0)
      fi
      printf '%s|%s\n' "$(_num "$total")" "$(_num "$members")"
    else
      echo "0|0"
    fi
  ) > "$_scratch/graph_totals" 2>/dev/null &

  (
    if [ "$_connected" = true ]; then
      raw=$(bash "$_root/bin/graph.sh" query "MATCH (s:Session)-[:HANDED_TO]->(:Person)
WHERE s.handoffStatus = 'done' AND date(s.date) >= date() - duration('P30D')
  AND s.handoffReadDate IS NOT NULL
WITH duration.inDays(date(s.date), date(s.handoffReadDate)).days AS d
RETURN avg(d) AS avgDays, count(*) AS n" 2>/dev/null || echo "")
      avg=$(printf '%s' "$raw" | jq -r '.values[0][0] // empty' 2>/dev/null || echo "")
      n=$(printf '%s' "$raw" | jq -r '.values[0][1] // 0' 2>/dev/null || echo 0)
      if [ "$(_num "$n")" -gt 0 ] 2>/dev/null && [ -n "$avg" ]; then _num_float "$avg"; else echo ""; fi
    else
      echo ""
    fi
  ) > "$_scratch/handoff_resolution" 2>/dev/null &

  (
    buckets=$(_git_added_buckets "$_mem" sessions wraps)
    all=$(_find_count_md "$_root/memory/sessions" "$_root/memory/wraps")
    printf '%s|%s\n' "$buckets" "$all"
  ) > "$_scratch/local_sessions" 2>/dev/null &

  (
    now=$(date +%s)
    if [ -d "$_mem" ] || [ -f "$_mem" ]; then
      git -C "$_mem" log --since="35 days ago" --format='%ct|%ae' 2>/dev/null | \
        awk -F'|' -v now="$now" '
          BEGIN { for (i=0;i<5;i++) b[i]=0 }
          {
            days = int((now - $1) / 86400)
            idx = 4 - int(days / 7)
            if (idx >= 0 && idx < 5) {
              b[idx]++
              if (idx == 4 && $2 != "") a[$2]=1
            }
          }
          END {
            n=0; for (k in a) n++
            printf "%d %d %d %d %d|%d\n", b[0], b[1], b[2], b[3], b[4], n
          }
        ' 2>/dev/null || echo "0 0 0 0 0|0"
    else
      echo "0 0 0 0 0|0"
    fi
  ) > "$_scratch/commits" 2>/dev/null &

  (
    if [ -d "$_mem" ] || [ -f "$_mem" ]; then git -C "$_mem" rev-list --count HEAD 2>/dev/null || echo 0; else echo 0; fi
  ) > "$_scratch/commits_all" 2>/dev/null &

  (
    buckets=$(_git_added_buckets "$_mem" handoffs)
    all=$(_find_count_md "$_root/memory/handoffs")
    printf '%s|%s\n' "$buckets" "$all"
  ) > "$_scratch/handoffs" 2>/dev/null &

  (
    buckets=$(_git_added_buckets "$_mem" knowledge/decisions knowledge/findings knowledge/patterns)
    all=$(_find_count_md "$_root/memory/knowledge/decisions" "$_root/memory/knowledge/findings" "$_root/memory/knowledge/patterns")
    printf '%s|%s\n' "$buckets" "$all"
  ) > "$_scratch/knowledge" 2>/dev/null &

  (
    _find_count_md "$_root/memory/people"
  ) > "$_scratch/members_total_local" 2>/dev/null &

  wait

  gs=$(cat "$_scratch/graph_sessions" 2>/dev/null || echo "0 0 0 0 0|0|0")
  gt=$(cat "$_scratch/graph_totals" 2>/dev/null || echo "0|0")
  lsess=$(cat "$_scratch/local_sessions" 2>/dev/null || echo "0 0 0 0 0|0")
  commits=$(cat "$_scratch/commits" 2>/dev/null || echo "0 0 0 0 0|0")
  handoffs=$(cat "$_scratch/handoffs" 2>/dev/null || echo "0 0 0 0 0|0")
  knowledge=$(cat "$_scratch/knowledge" 2>/dev/null || echo "0 0 0 0 0|0")

  graph_valid=$(_num "$(printf '%s' "$gs" | awk -F'|' '{print $3}')")
  if [ "$graph_valid" -gt 0 ] 2>/dev/null; then
    source_name="graph"
    session_buckets=$(_normalize_buckets "$(printf '%s' "$gs" | awk -F'|' '{print $1}')")
    session_all=$(_num "$(printf '%s' "$gt" | awk -F'|' '{print $1}')")
    members_active=$(_num "$(printf '%s' "$gs" | awk -F'|' '{print $2}')")
    members_total=$(_num "$(printf '%s' "$gt" | awk -F'|' '{print $2}')")
    if [ "$session_all" -le 0 ] 2>/dev/null; then
      session_all=$(_num "$(printf '%s' "$lsess" | awk -F'|' '{print $2}')")
    fi
    if [ "$members_total" -le 0 ] 2>/dev/null; then
      members_total=$(_num "$(cat "$_scratch/members_total_local" 2>/dev/null || echo 0)")
    fi
  else
    source_name="local"
    session_buckets=$(_normalize_buckets "$(printf '%s' "$lsess" | awk -F'|' '{print $1}')")
    session_all=$(_num "$(printf '%s' "$lsess" | awk -F'|' '{print $2}')")
    members_active=$(_num "$(printf '%s' "$commits" | awk -F'|' '{print $2}')")
    members_total=$(_num "$(cat "$_scratch/members_total_local" 2>/dev/null || echo 0)")
  fi

  commit_buckets=$(_normalize_buckets "$(printf '%s' "$commits" | awk -F'|' '{print $1}')")
  handoff_buckets=$(_normalize_buckets "$(printf '%s' "$handoffs" | awk -F'|' '{print $1}')")
  knowledge_buckets=$(_normalize_buckets "$(printf '%s' "$knowledge" | awk -F'|' '{print $1}')")
  avg_res=$(cat "$_scratch/handoff_resolution" 2>/dev/null || echo "")

  session_buckets_json=$(_buckets_json "$session_buckets")
  commit_buckets_json=$(_buckets_json "$commit_buckets")
  handoff_buckets_json=$(_buckets_json "$handoff_buckets")
  knowledge_buckets_json=$(_buckets_json "$knowledge_buckets")

  if [ -n "$avg_res" ]; then
    jq -n --arg source "$source_name" \
      --argjson sb "$session_buckets_json" --argjson sw "$(_bucket_week "$session_buckets")" --argjson sp "$(_bucket_prev "$session_buckets")" --argjson sall "$session_all" \
      --argjson cb "$commit_buckets_json" --argjson cw "$(_bucket_week "$commit_buckets")" --argjson cp "$(_bucket_prev "$commit_buckets")" --argjson ca "$(_num "$(printf '%s' "$commits" | awk -F'|' '{print $2}')")" --argjson call "$(_num "$(cat "$_scratch/commits_all" 2>/dev/null || echo 0)")" \
      --argjson hb "$handoff_buckets_json" --argjson hw "$(_bucket_week "$handoff_buckets")" --argjson hp "$(_bucket_prev "$handoff_buckets")" --argjson havg "$avg_res" --argjson hall "$(_num "$(printf '%s' "$handoffs" | awk -F'|' '{print $2}')")" \
      --argjson kb "$knowledge_buckets_json" --argjson kw "$(_bucket_week "$knowledge_buckets")" --argjson kp "$(_bucket_prev "$knowledge_buckets")" --argjson kall "$(_num "$(printf '%s' "$knowledge" | awk -F'|' '{print $2}')")" \
      --argjson ma "$members_active" --argjson mt "$members_total" \
      '{source:$source,sessions:{buckets:$sb,week:$sw,prev:$sp,all:$sall},commits:{buckets:$cb,week:$cw,prev:$cp,authors:$ca,all:$call},handoffs:{buckets:$hb,week:$hw,prev:$hp,avg_resolution_days:$havg,all:$hall},knowledge:{buckets:$kb,week:$kw,prev:$kp,all:$kall},members:{active:$ma,total:$mt}}' 2>/dev/null || _metrics_zero_json
  else
    jq -n --arg source "$source_name" \
      --argjson sb "$session_buckets_json" --argjson sw "$(_bucket_week "$session_buckets")" --argjson sp "$(_bucket_prev "$session_buckets")" --argjson sall "$session_all" \
      --argjson cb "$commit_buckets_json" --argjson cw "$(_bucket_week "$commit_buckets")" --argjson cp "$(_bucket_prev "$commit_buckets")" --argjson ca "$(_num "$(printf '%s' "$commits" | awk -F'|' '{print $2}')")" --argjson call "$(_num "$(cat "$_scratch/commits_all" 2>/dev/null || echo 0)")" \
      --argjson hb "$handoff_buckets_json" --argjson hw "$(_bucket_week "$handoff_buckets")" --argjson hp "$(_bucket_prev "$handoff_buckets")" --argjson hall "$(_num "$(printf '%s' "$handoffs" | awk -F'|' '{print $2}')")" \
      --argjson kb "$knowledge_buckets_json" --argjson kw "$(_bucket_week "$knowledge_buckets")" --argjson kp "$(_bucket_prev "$knowledge_buckets")" --argjson kall "$(_num "$(printf '%s' "$knowledge" | awk -F'|' '{print $2}')")" \
      --argjson ma "$members_active" --argjson mt "$members_total" \
      '{source:$source,sessions:{buckets:$sb,week:$sw,prev:$sp,all:$sall},commits:{buckets:$cb,week:$cw,prev:$cp,authors:$ca,all:$call},handoffs:{buckets:$hb,week:$hw,prev:$hp,avg_resolution_days:null,all:$hall},knowledge:{buckets:$kb,week:$kw,prev:$kp,all:$kall},members:{active:$ma,total:$mt}}' 2>/dev/null || _metrics_zero_json
  fi
  rm -rf "$_scratch" 2>/dev/null || true
}

_metrics_read() {
  local file filter fallback
  file="${CTX_DIR:-}/metrics"
  filter="$1"
  fallback="$2"
  if [ -f "$file" ]; then
    jq -r "$filter" "$file" 2>/dev/null || echo "$fallback"
  else
    echo "$fallback"
  fi
}

_render_momentum_board() {
  local separator line_width header_left header_right pad
  local sb sw sp sall cb cw ca call hb hw havg hall kb kw kall active total
  local sdelta sann cann hann kann know_week
  separator="${SEPARATOR:-  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄}"
  line_width="${LINE_WIDTH:-67}"

  sb=$(_metrics_read '(.sessions.buckets // [0,0,0,0,0]) | .[0:5] | map(. // 0) | join(" ")' "0 0 0 0 0")
  sw=$(_num "$(_metrics_read '.sessions.week // 0' "0")")
  sp=$(_num "$(_metrics_read '.sessions.prev // 0' "0")")
  sall=$(_num "$(_metrics_read '.sessions.all // 0' "0")")
  cb=$(_metrics_read '(.commits.buckets // [0,0,0,0,0]) | .[0:5] | map(. // 0) | join(" ")' "0 0 0 0 0")
  cw=$(_num "$(_metrics_read '.commits.week // 0' "0")")
  ca=$(_num "$(_metrics_read '.commits.authors // 0' "0")")
  call=$(_num "$(_metrics_read '.commits.all // 0' "0")")
  hb=$(_metrics_read '(.handoffs.buckets // [0,0,0,0,0]) | .[0:5] | map(. // 0) | join(" ")' "0 0 0 0 0")
  hw=$(_num "$(_metrics_read '.handoffs.week // 0' "0")")
  havg=$(_metrics_read '.handoffs.avg_resolution_days // empty' "")
  hall=$(_num "$(_metrics_read '.handoffs.all // 0' "0")")
  kb=$(_metrics_read '(.knowledge.buckets // [0,0,0,0,0]) | .[0:5] | map(. // 0) | join(" ")' "0 0 0 0 0")
  kw=$(_num "$(_metrics_read '.knowledge.week // 0' "0")")
  kall=$(_num "$(_metrics_read '.knowledge.all // 0' "0")")
  active=$(_num "$(_metrics_read '.members.active // 0' "0")")
  total=$(_num "$(_metrics_read '.members.total // 0' "0")")

  header_left="  ◦ momentum · this week"
  header_right="${active} of ${total} active"
  pad=$((line_width - ${#header_left} - ${#header_right}))
  [ "$pad" -lt 1 ] && pad=1
  printf "%s%*s%s\n" "$header_left" "$pad" "" "$header_right"

  sdelta=$(_pct_delta "$sw" "$sp")
  sann=""
  [ -n "$sdelta" ] && sann="${sdelta} vs last week"
  cann=""
  if [ "$ca" -gt 0 ] 2>/dev/null; then
    if [ "$ca" -eq 1 ] 2>/dev/null; then cann="1 author"; else cann="${ca} authors"; fi
  fi
  hann=""
  if [ -n "$havg" ]; then hann="$(_num_float "$havg")d avg resolution"; fi
  kann="$(_commafy "$kall") artifacts total"
  know_week="+${kw}"

  printf "  %-11s%5s   5-week %s   %s\n\n" "sessions" "$sw" "$(_spark "$sb")" "$sann"
  printf "  %-11s%5s   5-week %s   %s\n\n" "commits" "$cw" "$(_spark "$cb")" "$cann"
  printf "  %-11s%5s   5-week %s   %s\n\n" "handoffs" "$hw" "$(_spark "$hb")" "$hann"
  printf "  %-11s%5s   5-week %s   %s\n" "knowledge" "$know_week" "$(_spark "$kb")" "$kann"
  echo "$separator"
  printf "  %s sessions · %s commits · %s handoffs all-time\n" "$(_commafy "$sall")" "$(_commafy "$call")" "$(_commafy "$hall")"
}
