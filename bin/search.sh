#!/usr/bin/env bash
# Hybrid search over shared memory — powered by qmd (BM25 + vector + rerank, fully local).
# Usage:
#   bash bin/search.sh query "text" [-n N] [--fast|--semantic] [--all]
#   bash bin/search.sh reindex [--embed]
#   bash bin/search.sh status
#
# The memory repo is registered as a qmd collection named "{slug}-memory".
# Every call is scoped to that collection with -c, so other qmd collections
# on the machine are never read or modified.
#
# Modes:
#   (default)   qmd query   — hybrid BM25 + vector + rerank (needs local models, ~2GB one-time download)
#   --fast      qmd search  — BM25 keyword only, instant, no models
#   --semantic  qmd vsearch — vector similarity only (needs embeddings: reindex --embed)
# Hybrid/semantic fall back to BM25 automatically if models or embeddings are missing.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export NODE_NO_WARNINGS=1
# Do NOT set CI=1 here — it disables qmd's LLM ops (query expansion, rerank).

# qmd's progress spinner can leak into stdout when it misdetects a TTY;
# strip ANSI escapes and spinner frames from anything we return.
_clean() {
  sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' | grep -v 'Gathering information' || true
}

SLUG=$(jq -r '.slug // "egregore"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "egregore")
COLLECTION="${SLUG}-memory"
MEM_PATH="$(readlink -f "$SCRIPT_DIR/memory" 2>/dev/null || true)"

# qmd 2.5.x may render --full-path results as absolute `**file:**` paths,
# while older output uses qmd:// URIs. Normalize both to the canonical
# memory/... form users can open from an Egregore checkout, and parse both
# forms when counting hits or attaching graph state.
_normalize_file_paths() {
  local line absolute_prefix uri_prefix
  absolute_prefix="**file:** \`$MEM_PATH/"
  uri_prefix="**file:** \`qmd://${COLLECTION}/"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "$absolute_prefix"* ]]; then
      printf '**file:** `memory/%s\n' "${line#"$absolute_prefix"}"
    elif [[ "$line" == "$uri_prefix"* ]]; then
      printf '**file:** `memory/%s\n' "${line#"$uri_prefix"}"
    else
      printf '%s\n' "$line"
    fi
  done
}

_result_paths() {
  local line path canonical_prefix absolute_prefix uri_prefix
  canonical_prefix="**file:** \`memory/"
  absolute_prefix="**file:** \`$MEM_PATH/"
  uri_prefix="**file:** \`qmd://${COLLECTION}/"
  while IFS= read -r line || [ -n "$line" ]; do
    path=""
    if [[ "$line" == "$canonical_prefix"* ]]; then
      path="${line#"$canonical_prefix"}"
    elif [[ "$line" == "$absolute_prefix"* ]]; then
      path="${line#"$absolute_prefix"}"
    elif [[ "$line" == "$uri_prefix"* ]]; then
      path="${line#"$uri_prefix"}"
    elif [[ "$line" == *"qmd://${COLLECTION}/"* ]]; then
      path="${line#*"qmd://${COLLECTION}/"}"
    fi
    path="${path%%\`*}"
    case "$path" in
      *.md*) printf '%s\n' "${path%%.md*}.md" ;;
    esac
  done | sort -u
}

QMD_VERSION="2.5.3"  # pinned — bump deliberately, never float @latest

_qmd() {
  if command -v qmd >/dev/null 2>&1; then
    qmd "$@"
  else
    npx -y "@tobilu/qmd@${QMD_VERSION}" "$@"
  fi
}

# --- Weight ladder ----------------------------------------------------------
# Three tiers, chosen by what is already on disk — no mode ever triggers a
# model download in a session's critical path:
#   keyword   0 MB    BM25, works at install, forever
#   semantic  ~334 MB embed model, fetched silently by the background warm
#   hybrid    ~2.2 GB rerank + expansion — org opt-in (features.search_hybrid),
#                     prefetched by the background warm, never inline
MODELS_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/qmd/models"
_have_embed()  { ls "$MODELS_DIR"/*embedding* >/dev/null 2>&1; }
_have_hybrid() { ls "$MODELS_DIR"/*reranker* >/dev/null 2>&1 && ls "$MODELS_DIR"/*expansion* >/dev/null 2>&1; }
_hybrid_opted() { [ "$(jq -r '.features.search_hybrid // false' "$SCRIPT_DIR/egregore.json" 2>/dev/null)" = "true" ]; }

_ensure() {
  if [ -z "$MEM_PATH" ] || [ ! -d "$MEM_PATH" ]; then
    echo "memory/ not found — run bin/search.sh from an Egregore instance with a memory symlink" >&2
    exit 1
  fi
  if ! _qmd collection list 2>/dev/null | grep -q "^${COLLECTION} "; then
    _qmd collection add "$MEM_PATH" --name "$COLLECTION" >/dev/null 2>&1 || true
  fi
  # Incremental re-index so new handoffs/decisions are searchable immediately.
  # NEVER swallow a failure silently: a dead path in ANY registered collection
  # (e.g. a deleted side-project dir) crashes `qmd update` for every collection,
  # and the index quietly stops absorbing new documents. Caught in dogfooding
  # 2026-07-07 — results looked fine while missing three days of handoffs.
  if ! _qmd update >/dev/null 2>&1; then
    echo "(search: index update FAILED — results may be missing recent documents. A registered qmd collection likely points at a deleted path: run 'qmd collection list', remove the dead one, retry.)" >&2
  fi
  _embed_bg
}

# Keep vector embeddings warm without anyone running a manual step: fire a
# detached, lock-guarded `qmd embed` on every query. Nothing pending → exits
# in ~1s. First run on a machine → downloads models + embeds in the
# background while queries fall back to keyword mode.
_embed_bg() {
  [ "${EGREGORE_SEARCH_NO_WARM:-0}" = "1" ] && return 0
  local lock="${TMPDIR:-/tmp}/egregore-qmd-embed-${COLLECTION}.lock"
  if [ -f "$lock" ]; then
    # A crashed embed shouldn't block warming forever — expire the lock after 60 min.
    if [ -n "$(find "$lock" -mmin +60 2>/dev/null)" ]; then rm -f "$lock"; else return 0; fi
  fi
  touch "$lock"
  if ! _have_embed; then
    echo "(first run: building the semantic index in the background — searches use keyword mode until it finishes)" >&2
  fi
  # Background fetch policy: `qmd embed` pulls only the ~334MB embed model
  # (the semantic tier). The ~1.9GB hybrid pack is prefetched here ONLY when
  # the org opted in — a session never waits on either.
  ( ( _qmd embed >/dev/null 2>&1
      if _hybrid_opted && ! _have_hybrid; then
        _qmd query "warmup" -c "$COLLECTION" -n 1 >/dev/null 2>&1
      fi
      rm -f "$lock" ) & ) >/dev/null 2>&1
}

# Annotate results with live graph state (connected mode): each hit that the
# graph knows (Session by filePath = handoffs; Artifact by filePath = knowledge)
# gets one "↳ graph:" line — search finds the artifact, the graph tells you its
# state, in a single call. Fails soft everywhere: local mode / graph offline /
# unknown paths simply produce no annotations.
_enrich() {
  local results paths params out
  results=$(cat)
  echo "$results"
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
    [ -n "$ann" ] && echo "↳ graph · $fp — $ann"
  done
}

cmd_query() {
  local mode="query" n=6 enrich=auto all=()
  local -a words=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --fast) mode="search" ;;
      --semantic) mode="vsearch" ;;
      --enrich) enrich=1 ;;
      --no-enrich) enrich=0 ;;
      --all) all=(--all) ;;
      -n) n="$2"; shift ;;
      *) words+=("$1") ;;
    esac
    shift
  done
  # Default mode rides the weight ladder: use the heaviest tier whose models
  # are already local. Explicit flags always win; nothing downloads inline.
  if [ "$mode" = "query" ] && ! _have_hybrid; then
    if _have_embed; then mode="vsearch"; else mode="search"; fi
  fi
  # Enrichment is managed, not a user choice: on wherever a graph exists
  # (connected mode), silently off everywhere else. Flags only override.
  if [ "$enrich" = "auto" ]; then
    if [ "$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null)" != "local" ] && \
       [ -n "$(jq -r '.api_url // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)" ]; then
      enrich=1
    else
      enrich=0
    fi
  fi
  local q="${words[*]}"
  if [ -z "$q" ]; then
    echo "usage: bash bin/search.sh query \"text\" [-n N] [--fast|--semantic] [--all]" >&2
    exit 1
  fi
  _ensure
  local emit="cat"
  [ "$enrich" = 1 ] && emit="_enrich"
  local t0 out label
  t0=$(date +%s)
  if [ "$mode" != "search" ]; then
    out=$(_qmd "$mode" "$q" -c "$COLLECTION" -n "$n" --format md --full-path "${all[@]}" 2>/dev/null | _clean | _normalize_file_paths)
    if [ -n "$out" ] && [ "$out" != "No results found." ]; then
      [ "$mode" = "query" ] && label="hybrid" || label="semantic"
      _banner_and_emit "$label" "$t0" "$emit" "$q" "$out"
      return 0
    fi
    echo "_(hybrid/semantic returned nothing — showing keyword results. If this persists, run: bash bin/search.sh reindex --embed)_"
    echo ""
  fi
  out=$(_qmd search "$q" -c "$COLLECTION" -n "$n" --format md --full-path "${all[@]}" | _clean | _normalize_file_paths)
  _banner_and_emit "keyword" "$t0" "$emit" "$q" "$out"
}

# One visible product-attribution line per search — the tell that Egregore's
# organizational retrieval layer (not an improvised agent grep loop) answered.
# It names the graph only when enrichment actually ran, then reports mode,
# hit count, and latency. Colored when stdout is a terminal; plain glyph in
# harness transcripts. Also appends to ~/.egregore/search.log (local only,
# never uploaded) so dogfooding can measure search-first rate and latency.
_banner_and_emit() {
  local label="$1" t0="$2" emit="$3" q="$4" out="$5"
  local hits dur modef product surface plural=""
  hits=$(printf '%s\n' "$out" | _result_paths | wc -l | tr -d ' ')
  dur=$(( $(date +%s) - t0 ))
  modef="$label"
  product="Egregore"
  surface="searching your organization’s memory"
  if [ "$emit" = "_enrich" ] && [ "$hits" -gt 0 ]; then
    modef="${label}+graph"
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
  printf '%s\n' "$out" | $emit
  mkdir -p "$HOME/.egregore" 2>/dev/null
  echo "$(date '+%Y-%m-%d %H:%M:%S') mode=${modef} hits=${hits} dur=${dur}s q=\"$(printf '%.80s' "$q")\"" >> "$HOME/.egregore/search.log" 2>/dev/null || true
}

cmd_reindex() {
  _ensure
  _qmd update
  if [ "${1:-}" = "--embed" ]; then
    _qmd embed
    # Hybrid pack prefetch only when the org opted in (features.search_hybrid).
    if _hybrid_opted && ! _have_hybrid; then
      _qmd query "warmup" -c "$COLLECTION" -n 1 >/dev/null 2>&1 || true
    fi
  fi
}

cmd_status() {
  _qmd status 2>/dev/null
  echo ""
  echo "collection: $COLLECTION → $MEM_PATH"
}

case "${1:-}" in
  query)   shift; cmd_query "$@" ;;
  reindex) shift; cmd_reindex "$@" ;;
  status)  shift; cmd_status ;;
  *)
    echo "usage: bash bin/search.sh {query|reindex|status}" >&2
    exit 1
    ;;
esac
