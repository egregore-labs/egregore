#!/usr/bin/env bash
# Compatibility shell for Egregore's Local Retriever.
# Usage:
#   bash bin/search.sh find "terms" [--kind keyword|semantic|hybrid|filename|literal|dates] [--recent-days N]
#   bash bin/search.sh investigate '{"operation":"discover","kind":"keyword","query":"terms"}' [--context-packet]
#   bash bin/search.sh query "text" [-n N] [--fast|--semantic|--hybrid] [--recent-days N] [--min-evidence N] [--compact] [--context-packet] [--enrich] [--all] [--new-search]
#   bash bin/search.sh reindex [--embed]
#   bash bin/search.sh install
#   bash bin/search.sh status
#   bash bin/search.sh start
#   bash bin/search.sh stop
#   bash bin/search.sh open memory/path/to/source.md
#
# The shell owns the established user-facing output. Retrieval infrastructure
# is isolated behind the Egregore Retriever adapter.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MEM_PATH="$(readlink -f "$SCRIPT_DIR/memory" 2>/dev/null || true)"

_runtime() {
  EGREGORE_ROOT="$SCRIPT_DIR" \
    PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m egregore_runtime.harness_cli "$@"
}

# Explicit index provisioning/rebuild remains a maintenance compatibility
# surface. Normal harness query/open/lifecycle traffic never enters this
# implementation-specific bridge.
_maintenance_runtime() {
  EGREGORE_ROOT="$SCRIPT_DIR" \
    PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m egregore_runtime.adapters.qmd_cli "$@"
}

_now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf("%d\n", time() * 1000)'
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

_elapsed_s() {
  # One-decimal seconds since a _now_ms() timestamp.
  awk -v ms="$(( $(_now_ms) - $1 ))" 'BEGIN { printf "%.1f", ms / 1000 }'
}

_result_paths() {
  local line path canonical_prefix
  canonical_prefix="**file:** \`memory/"
  while IFS= read -r line || [ -n "$line" ]; do
    path=""
    if [[ "$line" == *"$canonical_prefix"* ]]; then
      path="${line#*"$canonical_prefix"}"
    fi
    path="${path%%\`*}"
    case "$path" in
      *.md*) printf '%s\n' "${path%%.md*}.md" ;;
    esac
  done | sort -u
}

# Legacy explicit graph annotation remains available while the graph is moved
# behind its projection boundary. It is intentionally never selected by the
# default Local retrieval path.
#
# An instance whose Runtime MVP upgrade has been activated retrieves through
# Runtime/QMD exclusively: even the explicit --enrich flag makes zero graph
# calls there. The dormant graph configuration is preserved untouched for
# rollback only.
_upgrade_instance_key() {
  # Mirrors egregore_runtime.upgrade.instance_key: stable org identity
  # composed with the main installation path. No org_id → fail closed.
  local org main gitdir
  org=$(jq -r '.org_id // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
  [ -n "$org" ] || return 1
  main="$SCRIPT_DIR"
  if [ -f "$SCRIPT_DIR/.git" ]; then
    gitdir=$(sed -n 's/^gitdir: //p' "$SCRIPT_DIR/.git" 2>/dev/null)
    case "$gitdir" in
      */.git/worktrees/*) main="${gitdir%/.git/worktrees/*}" ;;
    esac
  fi
  main=$(cd "$main" 2>/dev/null && pwd -P) || return 1
  printf '%s|%s' "$org" "$main" | shasum -a 256 2>/dev/null | cut -c1-16
}

_upgraded_runtime_active() {
  local key record
  key=$(_upgrade_instance_key) || return 1
  [ -n "$key" ] || return 1
  record="${EGREGORE_UPGRADE_ROOT:-$HOME/.egregore/runtime/upgrade}/${key}/active.json"
  [ -f "$record" ] || return 1
  [ "$(jq -r '.retrieval // empty' "$record" 2>/dev/null)" = "runtime-qmd" ]
}

_enrich() {
  local results paths params out
  results=$(cat)
  echo "$results"
  if _upgraded_runtime_active; then
    echo "↳ optional hosted enrichment: not used by this Runtime version"
    return 0
  fi
  paths=$(printf '%s\n' "$results" | _result_paths)
  [ -z "$paths" ] && return 0
  params=$(printf '%s\n' "$paths" | jq -R . | jq -sc '{paths: .}')
  out=$(bash "$SCRIPT_DIR/bin/graph.sh" query "UNWIND \$paths AS fp
    OPTIONAL MATCH (s:Session {filePath: fp})
    OPTIONAL MATCH (a:Artifact {filePath: fp})
    WITH fp, s, a WHERE s IS NOT NULL OR a IS NOT NULL
    RETURN fp,
      CASE WHEN s IS NOT NULL THEN coalesce(s.handoffStatus, s.status) ELSE null END AS sessionStatus,
      s.handedTo AS handedTo, a.type AS artifactType,
      CASE WHEN a IS NOT NULL THEN [q IN [(a)-[:PART_OF]->(qq:Quest) | qq.id] | q][0] ELSE null END AS quest" \
    "$params" 2>/dev/null)
  echo "$out" | jq -r '.values[]? | @tsv' 2>/dev/null | while IFS=$'\t' read -r fp sstat sto atype quest; do
    local ann=""
    [ -n "$sstat" ] && [ "$sstat" != "null" ] && ann="status: $sstat"
    [ -n "$sto" ] && [ "$sto" != "null" ] && ann="$ann${ann:+ · }to: $sto"
    [ -n "$atype" ] && [ "$atype" != "null" ] && ann="$ann${ann:+ · }artifact: $atype"
    [ -n "$quest" ] && [ "$quest" != "null" ] && ann="$ann${ann:+ · }quest: $quest"
    [ -n "$ann" ] && echo "↳ relationships · $fp — $ann"
  done
}

_banner_and_emit() {
  local label="$1" t0="$2" emit="$3" out="$4" hide_results="${5:-0}"
  local hits dur product surface plural="" gap actual required
  if [[ "$out" == EGREGORE_OBSERVE_CONTEXT_REUSED* ]]; then
    printf '⌕ Egregore · using context already compiled for this prompt · 0s\n\n'
    [ "$hide_results" = 1 ] || printf '%s\n' "$out" | tail -n +2
    return 0
  fi
  gap=$(printf '%s\n' "$out" | head -n 1)
  if [[ "$gap" == EGREGORE_EVIDENCE_GAP* ]]; then
    actual="${gap#*actual=}"
    actual="${actual%% *}"
    required="${gap#*required=}"
    required="${required%% *}"
    dur=$(_elapsed_s "$t0")
    printf '⌕ Egregore · searching your organization’s memory · %s · evidence gap · %s/%s sources · %ss\n\n' \
      "$label" "$actual" "$required" "$dur"
    [ "$hide_results" = 1 ] || printf '%s\n' "$out" | tail -n +2
    return 0
  fi
  hits=$(printf '%s\n' "$out" | _result_paths | wc -l | tr -d ' ')
  dur=$(_elapsed_s "$t0")
  product="Egregore"
  surface="searching your organization’s memory"
  if [ "$emit" = "_enrich" ] && [ "$hits" -gt 0 ]; then
    product="Egregore Connect"
    surface="${surface} and relationships"
  fi
  [ "$hits" != "1" ] && plural="s"
  local line="⌕ ${product} · ${surface} · ${label} · ${hits} hit${plural} · ${dur}s"
  if [ -t 1 ]; then
    printf '\033[1;38;5;30m%s\033[0m\n\n' "$line"
  else
    printf '%s\n\n' "$line"
  fi
  [ "$hide_results" = 1 ] || printf '%s\n' "$out" | "$emit"
}


cmd_query() {
  local mode="lex" label="keyword" n=6 enrich=0 all=0 new_search=0 recent_days="" min_evidence=1 compact=0 context_packet=0 follow_up="" episode="" request_id=""
  local -a words=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --episode|--request-id)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "search: $1 requires a value" >&2; return 1; }
        if [ "$1" = "--episode" ]; then episode="$2"; else request_id="$2"; fi
        shift
        ;;
      --fast) mode="lex"; label="keyword" ;;
      --semantic) mode="vec"; label="semantic" ;;
      --hybrid) mode="lex+vec"; label="hybrid" ;;
      --enrich) enrich=1 ;;
      --no-enrich) enrich=0 ;;
      --all) all=1 ;;
      --new-search) new_search=1 ;;
      --follow-up)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "search: --follow-up requires the missing evidence" >&2; return 1; }
        follow_up="$2"
        shift
        ;;
      --recent-days)
        [ $# -ge 2 ] || { echo "search: --recent-days requires a positive integer" >&2; return 1; }
        recent_days="$2"
        shift
        ;;
      --min-evidence)
        [ $# -ge 2 ] || { echo "search: --min-evidence requires a positive integer" >&2; return 1; }
        min_evidence="$2"
        shift
        ;;
      --compact) compact=1 ;;
      --context-packet) context_packet=1 ;;
      -n)
        [ $# -ge 2 ] || { echo "search: -n requires a positive integer" >&2; return 1; }
        n="$2"
        shift
        ;;
      *) words+=("$1") ;;
    esac
    shift
  done
  local q="${words[*]}"
  if [ -z "$q" ]; then
    echo "usage: bash bin/search.sh query \"text\" [-n N] [--fast|--semantic|--hybrid] [--recent-days N] [--min-evidence N] [--compact] [--context-packet] [--all] [--new-search]" >&2
    return 1
  fi
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "search: -n requires a positive integer" >&2; return 1; }
  [ -z "$recent_days" ] || [[ "$recent_days" =~ ^[1-9][0-9]*$ ]] || {
    echo "search: --recent-days requires a positive integer" >&2
    return 1
  }
  [[ "$min_evidence" =~ ^[1-9][0-9]*$ ]] || {
    echo "search: --min-evidence requires a positive integer" >&2
    return 1
  }
  [ "$all" = 1 ] && n=10000

  local -a args=(query --task "$q" --mode "$mode" --limit "$n")
  [ -n "$episode" ] && args+=(--episode "$episode")
  [ -n "$request_id" ] && args+=(--request-id "$request_id")
  [ "$new_search" = 1 ] && args+=(--new-search)
  [ -n "$follow_up" ] && args+=(--follow-up "$follow_up")
  [ -n "$recent_days" ] && args+=(--recent-days "$recent_days")
  args+=(--min-evidence "$min_evidence")
  [ "$compact" = 1 ] && args+=(--compact)
  case "$mode" in
    lex) args+=(--lex "$q") ;;
    vec) args+=(--vec "$q") ;;
    lex+vec) args+=(--lex "$q" --vec "$q") ;;
  esac

  if [ "$context_packet" = 1 ]; then
    _runtime "${args[@]}" --private-result
    return $?
  fi
  local t0 out emit="cat" query_rc
  t0=$(_now_ms)
  out=$(_runtime "${args[@]}" 2>&1)
  query_rc=$?
  if [ "$query_rc" -ne 0 ]; then
    if [ "$query_rc" -eq 2 ]; then
      printf '%s\n' "$out" >&2
      return 2
    fi
    {
      echo "⚠ Egregore Runtime retrieval failed."
      printf '%s\n' "$out" | tail -3 | sed 's/^/  /'
      echo "This is a Runtime failure — do not fall back to manual scanning (rg/grep/ls over memory), a global qmd, npx, or optional hosted indexes."
      echo "Diagnose with: bash bin/search.sh readiness · report with /issue · stop here."
    } >&2
    return "$query_rc"
  fi
  # The runtime marks a query that ran without its persistent worker (the
  # pinned CLI started cold). Strip the marker from the evidence and carry
  # it into the banner, the telemetry, and a one-line repair hint.
  local cold=0 cold_json=false
  if printf '%s\n' "$out" | grep -qx 'EGREGORE_RETRIEVAL_COLD_START'; then
    cold=1
    cold_json=true
    out=$(printf '%s\n' "$out" | grep -vx 'EGREGORE_RETRIEVAL_COLD_START')
  fi
  # Content-free query telemetry: mode, duration, result count, degraded
  # path. Never the query text. This is what makes Runtime/QMD retrieval
  # visible in the telemetry event list instead of only legacy graph_query rows.
  local _tele_count _tele_ms
  _tele_ms=$(( $(_now_ms) - t0 ))
  _tele_count=$(printf '%s' "$out" | jq 'if type == "array" then length elif type == "object" then (.results // [] | length) else empty end' 2>/dev/null || true)
  if [[ "$_tele_count" =~ ^[0-9]+$ ]]; then
    bash "$SCRIPT_DIR/bin/telemetry.sh" emit "query" \
      "$(jq -n --arg mode "$label" --argjson d "$_tele_ms" --argjson c "$_tele_count" --argjson cold "$cold_json" \
        '{mode:$mode, duration_ms:$d, count:$c, degraded:$cold}')" 2>/dev/null &
  else
    bash "$SCRIPT_DIR/bin/telemetry.sh" emit "query" \
      "$(jq -n --arg mode "$label" --argjson d "$_tele_ms" --argjson cold "$cold_json" \
        '{mode:$mode, duration_ms:$d, degraded:$cold}')" 2>/dev/null &
  fi
  # The request may have fallen back to lexical retrieval. Render what ran.
  local executed_mode
  executed_mode=$(printf '%s\n' "$out" | sed -n 's/^Executed retrieval mode: \([^;]*\);.*/\1/p' | head -1)
  case "$executed_mode" in
    lex) label="lex" ;;
    vec) label="semantic" ;;
    lex+vec) label="hybrid" ;;
  esac
  [ "$cold" = 1 ] && label="${label} · cold start"

  [ "$enrich" = 1 ] && emit="_enrich"
  _banner_and_emit "$label" "$t0" "$emit" "$out"
  if [ "$cold" = 1 ]; then
    echo "  ↳ the retrieval server was not running, so this query started QMD cold. Repair: bash bin/search.sh start" >&2
  fi
}

cmd_reindex() {
  local -a args=(update)
  [ "${1:-}" = "--embed" ] && args+=(--embed)
  _maintenance_runtime "${args[@]}"
}

cmd_status() {
  _runtime status
  echo ""
  echo "canonical memory: $MEM_PATH"
}

cmd_investigate() {
  local private_packet=0 packet out result_code
  local -a arguments=()
  for argument in "$@"; do
    case "$argument" in
      --context-packet) private_packet=1 ;;
      *) arguments+=("$argument") ;;
    esac
  done
  if [ "$private_packet" = 1 ]; then
    _runtime investigate "${arguments[@]}" --private-result
  else
    _runtime investigate "${arguments[@]}"
  fi
}

# The observation covers the query command's process boundary, including
# validation/rendering errors. It does not claim the answer was correct or the
# surrounding skill completed. Optional telemetry cannot alter the command exit.
_operation_observation() {
  EGREGORE_ROOT="$SCRIPT_DIR" PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m egregore_runtime.operation_cli "$@" 2>/dev/null || true
}
if [ "${1:-}" = "query" ] && [ -f "$SCRIPT_DIR/egregore_runtime/operation_cli.py" ] && \
   [ -z "$(trap -p EXIT INT TERM HUP)" ]; then
  _observed_operation_id="$(_operation_observation start --operation search)"
  # An explicit caller ID belongs to this invocation, not nested operations.
  unset EGREGORE_OPERATION_ID
  if [ -n "$_observed_operation_id" ]; then
    trap '_observed_exit=$?; _operation_observation finish --operation search --invocation-id "$_observed_operation_id" --exit-status "$_observed_exit" >/dev/null; exit "$_observed_exit"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
  fi
fi

case "${1:-}" in
  query) shift; cmd_query "$@" ;;
  reindex) shift; cmd_reindex "$@" ;;
  install) shift; _maintenance_runtime install "$@" ;;
  status) shift; cmd_status ;;
  readiness) shift; _runtime readiness "$@" ;;
  handoffs)
    shift
    if ! _runtime handoffs "$@"; then
      {
        echo "⚠ Egregore Runtime lifecycle lookup failed."
        echo "This is a Runtime failure — do not fall back to manual scanning (ls/rg/grep over memory), a semantic re-query, or optional hosted indexes."
        echo "Diagnose with: bash bin/search.sh readiness · report with /issue · stop here."
      } >&2
      exit 1
    fi
    ;;
  find)
    shift
    FIND_ARGS=()
    for arg in "$@"; do
      if [ "$arg" = --context-packet ]; then FIND_ARGS+=(--private-result); else FIND_ARGS+=("$arg"); fi
    done
    _runtime find "${FIND_ARGS[@]}"
    ;;
  investigate) shift; cmd_investigate "$@" ;;
  start) shift; _runtime start "$@" ;;
  stop) shift; _runtime stop "$@" ;;
  open)
    shift
    OPEN_PACKET=0; OPEN_PATHS=()
    OPEN_BINDING=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --context-packet) OPEN_PACKET=1 ;;
        --episode|--request-id|--harness|--offset|--length)
          [ $# -ge 2 ] && [ -n "$2" ] || { echo "search: $1 requires a value" >&2; exit 1; }
          OPEN_BINDING+=("$1" "$2"); shift ;;
        *) OPEN_PATHS+=("$1") ;;
      esac
      shift
    done
    [ "$OPEN_PACKET" = 1 ] && OPEN_BINDING+=(--private-result)
    # Older Bash treats an empty array as unset under nounset. Optional flags
    # must expand to zero arguments without requiring an explicit episode ID.
    _runtime open ${OPEN_PATHS[@]+"${OPEN_PATHS[@]}"} ${OPEN_BINDING[@]+"${OPEN_BINDING[@]}"}
    ;;
  help|-h|--help)
    cat <<'USAGE'
usage: bash bin/search.sh {find|investigate|query|handoffs|reindex|install|start|stop|status|readiness|open}
  find "terms" [--kind keyword|semantic|hybrid|filename|literal|dates] [--recent-days N]
  open memory/path.md [memory/other.md ...] [--offset N] [--length N]
  handoffs --mine --status open --order newest --limit 1 --open
  handoffs [--addressed-to NAME|--sent|--sent-by NAME] [--status STATUS] [--order newest|oldest] [--limit N] [--json]
USAGE
    ;;
  *)
    echo "usage: bash bin/search.sh {find|investigate|query|handoffs|reindex|install|start|stop|status|readiness|open}" >&2
    exit 1
    ;;
esac
