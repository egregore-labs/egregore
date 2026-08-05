#!/usr/bin/env bash
set -euo pipefail

# Org-scoped intake plane. Shared manifests live in memory/; normalized bodies
# stay in this checkout's gitignored cache; qmd uses a separate per-org index.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NODE_NO_WARNINGS=1
PY="$ROOT/bin/ingest.py"
SURFACE="$ROOT/bin/ingest_surface.py"
SLUG="$(jq -r '.slug // "egregore"' "$ROOT/egregore.json")"
INDEX="${SLUG}-ingest"
COLLECTION="${SLUG}-ingest"
INGEST_ROOT="${EGREGORE_INGEST_ROOT:-$ROOT/.egregore/ingest}"
INGEST_META_ROOT="${EGREGORE_INGEST_META_ROOT:-$ROOT/memory/ingest}"
QMD_VERSION="2.5.3"
GRAPH_PROJECTOR="${EGREGORE_INGEST_GRAPH_PROJECTOR:-$ROOT/bin/ingest-graph.sh}"

_qmd() {
  if command -v qmd >/dev/null 2>&1; then
    qmd --index "$INDEX" "$@"
  else
    npx -y "@tobilu/qmd@${QMD_VERSION}" --index "$INDEX" "$@"
  fi
}

_ensure_index() {
  mkdir -p "$INGEST_ROOT"
  if ! _qmd collection list 2>/dev/null | grep -q "^${COLLECTION} "; then
    _qmd collection add "$INGEST_ROOT" --name "$COLLECTION" >/dev/null
  fi
  _qmd update >/dev/null
}

_graph_sync() {
  local source="${1:-}" manifest result status
  local total=0 succeeded=0 failed=0 stored=0 queries=0
  local manifests=()
  if [ -n "$source" ]; then
    manifests+=("$INGEST_META_ROOT/sources/$source/manifest.json")
  else
    while IFS= read -r manifest; do manifests+=("$manifest"); done < <(
      find "$INGEST_META_ROOT/sources" "$INGEST_META_ROOT/knowledge" \
        -type f -name '*.json' 2>/dev/null | sort
    )
  fi
  for manifest in "${manifests[@]}"; do
    [ -f "$manifest" ] || continue
    total=$((total + 1))
    if result="$(bash "$GRAPH_PROJECTOR" apply "$manifest")"; then
      status="$(printf '%s' "$result" | jq -r '.status')"
      queries=$((queries + $(printf '%s' "$result" | jq -r '.queries // 0')))
      if [ "$status" = "stored" ]; then stored=$((stored + 1)); else succeeded=$((succeeded + 1)); fi
    else
      failed=$((failed + 1))
    fi
  done
  if [ "$failed" -gt 0 ]; then
    jq -cn --argjson manifests "$total" --argjson succeeded "$succeeded" --argjson stored "$stored" --argjson failed "$failed" --argjson queries "$queries" \
      '{status:"partial",manifests:$manifests,succeeded:$succeeded,stored:$stored,failed:$failed,queries:$queries,replayable:true}'
    return 1
  fi
  if [ "$total" -eq 0 ]; then
    printf '%s\n' '{"status":"nothing-to-project","manifests":0,"failed":0,"queries":0,"replayable":true}'
  elif [ "$stored" -eq "$total" ]; then
    jq -cn --argjson manifests "$total" --argjson queries "$queries" \
      '{status:"stored-local",manifests:$manifests,failed:0,queries:$queries,replayable:true}'
  else
    jq -cn --argjson manifests "$total" --argjson queries "$queries" \
      '{status:"synced",manifests:$manifests,failed:0,queries:$queries,replayable:true}'
  fi
}

_journal() {
  local source="$1" phase="$2" detail="${3:-}"
  [ -n "$detail" ] || detail='{}'
  python3 "$PY" journal --source "$source" --phase "$phase" --detail "$detail"
}

_journal_clear() {
  python3 "$PY" journal --source "$1" --clear
}

_notify_receipt() {
  local url="$1" token="$2" payload="$3"
  [ -z "$url" ] && return 0
  python3 - "$url" "$token" "$payload" <<'PY' >/dev/null 2>&1 || true
import sys, urllib.request
body = sys.argv[3].encode()
request = urllib.request.Request(
    sys.argv[1] + "/api/result",
    data=body,
    method="POST",
    headers={"Content-Type": "application/json", "X-Egregore-Token": sys.argv[2]},
)
urllib.request.urlopen(request, timeout=5).read()
PY
}

cmd_add() {
  local source="" summary graph final qmd_status
  local args=("$@")
  local i
  for ((i=0; i<${#args[@]}; i++)); do
    if [ "${args[$i]}" = "--source" ] && [ $((i+1)) -lt ${#args[@]} ]; then source="${args[$((i+1))]}"; fi
  done
  summary="$(python3 "$PY" add "$@")"
  _journal "$source" "normalized" "$(printf '%s' "$summary" | jq -c '{ingested,unchanged,metadata_updated,skipped,pruned}')"
  if ! _ensure_index; then
    qmd_status='{"status":"failed"}'
    _journal "$source" "index_failed" "$qmd_status"
    printf '%s\n' "$summary" | jq --argjson qmd "$qmd_status" '. + {status:"failed",qmd:$qmd,graph:{status:"not-attempted"}}'
    return 1
  fi
  qmd_status='{"status":"indexed"}'
  if graph="$(_graph_sync "$source")"; then :; else :; fi
  if [ "$(printf '%s' "$summary" | jq -r .skipped)" -gt 0 ]; then
    _journal "$source" "extraction_attention" "$(printf '%s' "$summary" | jq -c '{skipped}')"
    final="$(printf '%s' "$summary" | jq --argjson qmd "$qmd_status" --argjson graph "$graph" '. + {status:"attention",qmd:$qmd,graph:$graph}')"
  elif [ "$(printf '%s' "$graph" | jq -r .status)" = "partial" ]; then
    _journal "$source" "graph_pending" "$graph"
    final="$(printf '%s' "$summary" | jq --argjson qmd "$qmd_status" --argjson graph "$graph" '. + {status:"attention",qmd:$qmd,graph:$graph}')"
  else
    _journal_clear "$source"
    final="$(printf '%s' "$summary" | jq --argjson qmd "$qmd_status" --argjson graph "$graph" '. + {status:"complete",qmd:$qmd,graph:$graph}')"
  fi
  printf '%s\n' "$final"
}

cmd_add_selection() {
  local manifest="${1:?usage: bin/ingest.sh add-selection MANIFEST}"
  local source receipt_url receipt_token summary graph qmd_status outcome final message contract
  contract="$(python3 - "$manifest" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps({"source": value["source"]["id"], "url": value.get("receipt", {}).get("url", ""), "token": value.get("receipt", {}).get("token", "")}))
PY
)"
  source="$(printf '%s' "$contract" | jq -r .source)"
  receipt_url="$(printf '%s' "$contract" | jq -r .url)"
  receipt_token="$(printf '%s' "$contract" | jq -r .token)"
  if ! summary="$(python3 "$PY" add-selection "$manifest")"; then
    final="$(jq -cn --arg source "$source" '{status:"failed",outcome:"normalization failed",source:$source,message:"The selection failed validation or extraction. Its staging directory was retained for diagnosis."}')"
    _notify_receipt "$receipt_url" "$receipt_token" "$final"
    return 2
  fi
  _journal "$source" "normalized" "$(printf '%s' "$summary" | jq -c '{ingested,unchanged,metadata_updated,skipped,pruned}')"
  if _ensure_index; then
    qmd_status='{"status":"indexed"}'
  else
    qmd_status='{"status":"failed"}'
    _journal "$source" "index_failed" "$qmd_status"
  fi
  if [ "$(printf '%s' "$qmd_status" | jq -r .status)" = "indexed" ]; then
    if graph="$(_graph_sync "$source")"; then :; else :; fi
  else
    graph='{"status":"not-attempted","batches":0,"failed":0}'
  fi
  if [ "$(printf '%s' "$qmd_status" | jq -r .status)" != "indexed" ]; then
    outcome="index failed"
    message="The normalized source was retained, but QMD did not finish indexing it. Run bin/ingest.sh reindex to repair it."
    final="$(printf '%s' "$summary" | jq --argjson qmd "$qmd_status" --argjson graph "$graph" --arg outcome "$outcome" --arg message "$message" '. + {status:"failed",outcome:$outcome,message:$message,qmd:$qmd,graph:$graph}')"
  elif [ "$(printf '%s' "$summary" | jq -r '.skipped')" -gt 0 ]; then
    outcome="indexed with skipped files"
    message="Searchable files were indexed, but one or more files still need a compatible extractor. Their staging bytes were retained."
    _journal "$source" "extraction_attention" "$(printf '%s' "$summary" | jq -c '{skipped,selection_path}')"
    final="$(printf '%s' "$summary" | jq --argjson qmd "$qmd_status" --argjson graph "$graph" --arg outcome "$outcome" --arg message "$message" '. + {status:"attention",outcome:$outcome,message:$message,qmd:$qmd,graph:$graph}')"
  elif [ "$(printf '%s' "$graph" | jq -r .status)" = "partial" ]; then
    outcome="indexed · graph pending"
    message="The source is searchable now. Graph projection was incomplete and is recorded for retry."
    _journal "$source" "graph_pending" "$graph"
    final="$(printf '%s' "$summary" | jq --argjson qmd "$qmd_status" --argjson graph "$graph" --arg outcome "$outcome" --arg message "$message" '. + {status:"attention",outcome:$outcome,message:$message,qmd:$qmd,graph:$graph}')"
  else
    outcome="indexed · org-scoped · unverified"
    message="The files were validated, normalized, and added to this organization’s retrieval index."
    _journal_clear "$source"
    final="$(printf '%s' "$summary" | jq --argjson qmd "$qmd_status" --argjson graph "$graph" --arg outcome "$outcome" --arg message "$message" '. + {status:"complete",outcome:$outcome,message:$message,qmd:$qmd,graph:$graph}')"
  fi
  _notify_receipt "$receipt_url" "$receipt_token" "$final"
  printf '%s\n' "$final"
}

cmd_search() {
  local query="${1:?usage: bin/ingest.sh search \"query\" [--source id] [--boundary key=value] [-n N]}"
  shift
  local limit=8 raw filtered filter_args=() qmd_n=200
  while [ $# -gt 0 ]; do
    case "$1" in
      -n) limit="$2"; shift 2 ;;
      --source) filter_args+=(--source "$2"); shift 2 ;;
      --boundary) filter_args+=(--boundary "$2"); shift 2 ;;
      *) echo "unknown search option: $1" >&2; exit 2 ;;
    esac
  done
  _ensure_index
  raw="$(_qmd search "$query" -c "$COLLECTION" -n "$qmd_n" --all --json 2>/dev/null || echo '[]')"
  if [ ${#filter_args[@]} -gt 0 ]; then
    filtered="$(printf '%s' "$raw" | python3 "$PY" filter-results "${filter_args[@]}" --limit "$limit")"
  else
    filtered="$(printf '%s' "$raw" | python3 "$PY" filter-results --limit "$limit")"
  fi
  printf '%s' "$filtered" | jq -r --arg org "$SLUG" '
    "⌕ ingest · keyword · \(length) hit\(if length == 1 then "" else "s" end) · org=" + $org,
    (.[] | "\n### " + (.title // .file) + "\n" + .file + "\n\n" + (.snippet // ""))'
}

cmd_select() {
  # Stitch the Google sign-in into the picker itself: when the shim ships and
  # no account is connected yet, pre-start the OAuth listener and hand its
  # consent URL to the surface — clicking Google then continues the SAME tab
  # into sign-in instead of bouncing through the terminal. Already connected:
  # pass the account so the page says so honestly. Everything degrades to the
  # terminal-guided flow when the URL isn't ready in time.
  local auth_urls="{}" accounts="{}" auth_pid="" auth_log="" result status=0
  if [ -x "$ROOT/bin/connector-google.sh" ]; then
    local active_account
    active_account="$(jq -r '.google_account // empty' "$ROOT/.egregore-state.json" 2>/dev/null)"
    if [ -n "$active_account" ]; then
      accounts="$(jq -cn --arg a "$active_account" '{google: $a}')"
    else
      auth_log="$(mktemp)"
      bash "$ROOT/bin/connector-google.sh" auth --print-url > "$auth_log" 2>/dev/null &
      auth_pid=$!
      local waited=0 url=""
      while [ "$waited" -lt 15 ]; do
        url="$(head -1 "$auth_log" 2>/dev/null | jq -r '.auth_url // empty' 2>/dev/null)"
        [ -n "$url" ] && break
        sleep 1; waited=$((waited + 1))
      done
      if [ -n "$url" ]; then
        auth_urls="$(jq -cn --arg u "$url" '{google: $u}')"
      fi
    fi
  fi
  result="$(EGREGORE_CONNECTOR_AUTH_URLS="$auth_urls" EGREGORE_CONNECTOR_ACCOUNTS="$accounts" python3 "$SURFACE" "$@")" || status=$?
  if [ -n "$auth_pid" ]; then
    if [ "$(printf '%s' "$result" | jq -r '.auth // empty' 2>/dev/null)" = "in-browser" ]; then
      # The user is on Google's consent page in their tab; the listener
      # finishes the token exchange. Wait for it and fold in the outcome.
      if wait "$auth_pid" 2>/dev/null; then
        result="$(printf '%s' "$result" | jq -c '. + {auth: "connected"}')"
      else
        result="$(printf '%s' "$result" | jq -c '. + {auth: "failed"}')"
      fi
    else
      kill "$auth_pid" 2>/dev/null || true
      wait "$auth_pid" 2>/dev/null || true
    fi
  fi
  [ -n "$auth_log" ] && rm -f "$auth_log"
  printf '%s\n' "$result"
  return "$status"
}

case "${1:-}" in
  select) shift; cmd_select "$@" ;;
  add) shift; cmd_add "$@" ;;
  add-selection) shift; cmd_add_selection "$@" ;;
  register-extraction) shift; python3 "$PY" register-extraction "$@" ;;
  search) shift; cmd_search "$@" ;;
  reindex)
    _ensure_index
    if graph="$(_graph_sync "")"; then
      find "$INGEST_ROOT/.state" -type f -name '*.json' -delete 2>/dev/null || true
    fi
    printf '%s\n' "$graph"
    ;;
  graph-sync) shift; _graph_sync "${1:-}" ;;
  status) python3 "$PY" status; _qmd status 2>/dev/null || true ;;
  *)
    echo 'usage: bash bin/ingest.sh {select|add|add-selection|register-extraction|search|reindex|graph-sync|status}' >&2
    echo '  select [--no-open] [--timeout SECONDS]' >&2
    echo '  add PATH --source ID [--name NAME] [--kind TYPE] [--boundary key=value]... [--prune]' >&2
    echo '  add-selection MANIFEST' >&2
    echo '  register-extraction MANIFEST RELATIVE_PATH --extractor NAME < normalized.txt' >&2
    echo '  search "QUERY" [--source ID] [--boundary key=value]... [-n N]' >&2
    exit 2
    ;;
esac
