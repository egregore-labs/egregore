#!/bin/bash
set -euo pipefail

# artifact-register.sh — record a PUBLISHED (hosted) artifact in the local
# registry so it's findable by CONTENT, not just name, across all three layers:
#
#   • Claude Code / Codex (OSS)  — grep/ls/read over memory/artifacts/*.md
#   • graph (paid)               — upserted here as an Artifact node (connected
#                                  mode, via graph-op.sh register-artifact) and
#                                  reconciled by /save's sync-graph.sh; queried
#                                  back by bin/artifacts.sh for fast, relationship
#                                  -aware retrieval
#
# The filesystem record is the source of truth (works in OSS with nothing but
# grep); the graph is an index over it. Hosted artifacts join the same pool as
# /add-ed knowledge artifacts, with a `url:` field linking to the egregore.xyz
# render.
#
# Usage: artifact-register.sh --id <id> --url <url> --type <type> \
#          --title <title> [--author <a>] [--source <file>] [--description <d>]
#
# Idempotent: re-registering the same artifact (same date+author+slug) upserts.
# Non-fatal by design — a registry-write failure must never break a publish.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REG_DIR="$SCRIPT_DIR/memory/artifacts"

# Types that already have a canonical filesystem home (or are transient UI) —
# skip them to keep the registry to findable content artifacts.
SKIP_TYPES=" handoff board activity network dashboard subgraph "

ID="" URL="" TYPE="artifact" TITLE="" AUTHOR="" SOURCE="" DESCRIPTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)          ID="$2"; shift 2 ;;
    --url)         URL="$2"; shift 2 ;;
    --type)        TYPE="$2"; shift 2 ;;
    --title)       TITLE="$2"; shift 2 ;;
    --author)      AUTHOR="$2"; shift 2 ;;
    --source)      SOURCE="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Skip transient / already-homed types.
case "$SKIP_TYPES" in *" $TYPE "*) exit 0 ;; esac

[ -n "$URL" ] || exit 0
[ -d "$SCRIPT_DIR/memory" ] || exit 0   # memory not linked → nothing to do
mkdir -p "$REG_DIR" 2>/dev/null || exit 0

# --- Derive id from the URL tail if not supplied ---
[ -n "$ID" ] || ID="$(printf '%s' "$URL" | sed 's#/*$##; s#.*/##')"

# --- Title fallback from source filename ---
if [ -z "$TITLE" ] && [ -n "$SOURCE" ]; then
  TITLE="$(basename "$SOURCE" | sed 's/\.[^.]*$//; s/[-_]/ /g')"
fi
[ -n "$TITLE" ] || TITLE="Untitled artifact"

DATE="$(date +%Y-%m-%d)"
AUTH="${AUTHOR:-unknown}"

# --- Slug + stable filename (date-author-slug, matching the existing convention) ---
# Portable (BSD + GNU): lowercase, non-alnum → single '-', trim, cap length.
slug() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
  | LC_ALL=C tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-60 \
  | sed 's/-$//'; }
SLUG="$(slug "$TITLE")"; [ -n "$SLUG" ] || SLUG="artifact"
FILE="$REG_DIR/${DATE}-$(slug "$AUTH")-${SLUG}.md"

# --- Topics: derive 2–5 slugs from the title, minus stopwords (grep + graph) ---
STOP=" the a an is for and or in of to on with our we v0 v1 v2 "
TOPICS=""
for w in $(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' '); do
  [ ${#w} -ge 3 ] || continue
  case "$STOP" in *" $w "*) continue ;; esac
  case " $TOPICS " in *" $w "*) continue ;; esac
  TOPICS="${TOPICS:+$TOPICS, }$w"
  [ "$(printf '%s' "$TOPICS" | tr ',' '\n' | wc -l)" -ge 5 ] && break
done

# --- Body: the content that makes it findable by CONTENT, not just name ---
#  • source under memory/ → it's already grep/searchable there; link + excerpt.
#  • ephemeral source (/tmp, raw html) → capture a generous excerpt inline.
EXCERPT=""
SRC_REL=""
if [ -n "$SOURCE" ] && [ -f "$SOURCE" ]; then
  case "$SOURCE" in
    *.md|*.markdown|*.txt)
      EXCERPT="$(sed -e '/^---$/,/^---$/d' "$SOURCE" 2>/dev/null | grep -v '^\s*$' | head -140)"
      ;;
    *) EXCERPT="" ;;   # html/binary: rely on title + description + topics
  esac
  case "$SOURCE" in "$SCRIPT_DIR"/memory/*) SRC_REL="memory/${SOURCE#"$SCRIPT_DIR"/memory/}" ;; esac
fi

# --- Write the entry (upsert) ---
{
  printf -- '---\n'
  printf 'id: %s\n' "$ID"
  printf 'title: %s\n' "$TITLE"
  printf 'type: %s\n' "$TYPE"
  printf 'author: %s\n' "$AUTH"
  printf 'date: %s\n' "$DATE"
  printf 'topics: [%s]\n' "$TOPICS"
  printf 'url: %s\n' "$URL"
  [ -n "$SRC_REL" ] && printf 'source: %s\n' "$SRC_REL"
  printf 'published: true\n'
  printf -- '---\n\n'
  printf '# %s\n\n' "$TITLE"
  [ -n "$DESCRIPTION" ] && printf '%s\n\n' "$DESCRIPTION"
  printf '**Hosted artifact:** %s\n' "$URL"
  [ -n "$SRC_REL" ] && printf '**Rendered from:** `%s`\n' "$SRC_REL"
  if [ -n "$EXCERPT" ]; then
    printf '\n---\n\n'
    printf '%s\n' "$EXCERPT"
  fi
} > "$FILE" 2>/dev/null || exit 0

printf '%s\n' "$FILE"

# --- Persist across sessions ---
# A registry entry that never leaves the machine that published is invisible to
# every other session's finder. Commit JUST this record (pathspec-scoped, so it
# never sweeps unrelated in-progress memory changes) and push — fire-and-forget
# and detached, so a slow or racing push can never delay or fail the publish.
# If a push loses a race the commit still lands locally and rides out on the
# next push (/save, handoff, or the next registration).
REL="artifacts/$(basename "$FILE")"
(
  cd "$SCRIPT_DIR/memory" 2>/dev/null || exit 0
  git add -- "$REL" >/dev/null 2>&1 || exit 0
  git diff --cached --quiet -- "$REL" 2>/dev/null && exit 0
  git commit -m "artifact: register ${TITLE}" -- "$REL" >/dev/null 2>&1 || exit 0
  for _ in 1 2 3; do
    git pull --rebase --no-edit >/dev/null 2>&1 && git push >/dev/null 2>&1 && break
    sleep 1
  done
) >/dev/null 2>&1 &

# --- Index into the graph (connected mode only) ---
# In paid mode the graph is the fast, relationship-aware retrieval layer that
# bin/artifacts.sh queries. Upsert an Artifact node keyed by this record's
# FILENAME STEM (matching sync-graph.sh, so /save reconciles the same node
# instead of duplicating it), carrying url + a content excerpt for CONTAINS
# retrieval. Detached + best-effort: the graph is an index over the filesystem
# record, never the source of truth — a graph hiccup must not touch the publish.
if [ "$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null)" != "local" ]; then
  (
    bash "$SCRIPT_DIR/bin/graph-op.sh" register-artifact \
      "$(basename "$FILE" .md)" "$URL" "$TITLE" "$TYPE" "$AUTH" \
      "$TOPICS" "${DESCRIPTION} ${EXCERPT}" >/dev/null 2>&1 || true
  ) &
fi
