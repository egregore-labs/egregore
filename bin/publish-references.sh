#!/bin/bash
set -uo pipefail

# publish-references.sh — Depth-1 auto-publish for referenced memory files.
#
# Usage: publish-references.sh <source-markdown-file>
#
# Reads the source markdown, extracts backtick-wrapped references to
# `memory/**/*.{md,html}` paths, and publishes each one in parallel with a
# deterministic artifact id (see bin/lib/artifact-id.sh). The deterministic id
# means the rendered parent view can construct a predictable link to each
# referenced file *before* this script finishes — so even a slight delay
# produces clickable links that resolve once the referenced publish completes.
#
# Connected mode only. Skips silently if EGREGORE_API_KEY is missing, because
# the OSS relay ignores artifact ids and would assign random slugs.
#
# Fire-and-forget: silent on errors, does not block the caller, bounded
# parallelism via EGREGORE_REF_PUBLISH_PARALLELISM (default 8).

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_FILE="${1:-}"

[ -n "$SOURCE_FILE" ] || exit 0
[ -f "$SOURCE_FILE" ] || exit 0

# --- Connected-mode check ---
API_KEY="${EGREGORE_API_KEY:-}"
if [ -z "$API_KEY" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  API_KEY="$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)"
fi
[ -n "$API_KEY" ] || exit 0

# --- Helpers ---
# shellcheck disable=SC1091
. "$SCRIPT_DIR/bin/lib/artifact-id.sh"

PARALLELISM="${EGREGORE_REF_PUBLISH_PARALLELISM:-8}"

GIT_ROOT="$(git -C "$(dirname "$SOURCE_FILE")" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"

# Absolute, symlink-resolved path of the source file. Used below to compare
# each resolved ref against the source and skip self-references. Using
# symlink-resolved absolute paths means `memory/` as a symlink into a sibling
# repo (and macOS's `/var` → `/private/var`) compare correctly — basename
# comparison alone would falsely skip unrelated files that happen to share
# a filename (e.g. date-prefixed handoffs, README.md, index.md).
SOURCE_ABS="$(cd "$(dirname "$SOURCE_FILE")" 2>/dev/null && pwd -P)/$(basename "$SOURCE_FILE")"

# Infer artifact type from path — mirrors egregore-artifacts/bin/cli.js inferType.
infer_type() {
  local fp="$1"
  case "$fp" in
    */quests/*)   echo "quest" ;;
    */handoffs/*) echo "handoff" ;;
    *)            echo "document" ;;
  esac
}

# Resolve a backtick-referenced path to a real file on disk.
resolve_ref() {
  local ref="$1"
  local src_dir
  src_dir="$(dirname "$SOURCE_FILE")"
  # Candidates: source file's repo-root resolution, then git root, then cwd.
  local candidates=(
    "$src_dir/../../$ref"
    "$GIT_ROOT/$ref"
    "$ref"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

publish_one() {
  local ref="$1"
  local resolved
  resolved="$(resolve_ref "$ref")" || return 0
  [ -n "$resolved" ] || return 0

  # Self-ref guard: skip refs that resolve to the source file itself.
  # Compared as symlink-resolved absolute paths so symlinked memory layouts
  # (and unrelated files with the same basename) are handled correctly.
  local resolved_abs
  resolved_abs="$(cd "$(dirname "$resolved")" 2>/dev/null && pwd -P)/$(basename "$resolved")"
  if [ "$resolved_abs" = "$SOURCE_ABS" ]; then
    return 0
  fi

  local id
  id="$(artifact_id_from_path "$ref")" || return 0
  [ -n "$id" ] || return 0

  case "$ref" in
    *.md)
      local type
      type="$(infer_type "$ref")"
      bash "$SCRIPT_DIR/bin/publish-artifact.sh" "$type" "$resolved" --id "$id" --no-references >/dev/null 2>&1 || true
      ;;
    *.html)
      bash "$SCRIPT_DIR/bin/publish-artifact.sh" document "$resolved" --id "$id" --raw-html --no-references >/dev/null 2>&1 || true
      ;;
  esac
}

# --- Extract refs, dedupe, publish in parallel ---
# grep -Eo prints each match on its own line; sed strips the surrounding
# backticks; sort -u dedupes. No dependency on GNU grep -P.
REFS="$(grep -Eo '`memory/[^`[:space:]]+\.(md|html)`' "$SOURCE_FILE" 2>/dev/null \
  | sed 's/^`//; s/`$//' \
  | sort -u)"

[ -n "$REFS" ] || exit 0

# Bounded parallelism — cap concurrent jobs at PARALLELISM.
# On bash ≥ 4 (`wait -n`) this is rolling parallelism. On bash 3.2 (macOS
# default /bin/bash), `wait -n` is unsupported and the `|| wait` fallback
# drains the whole batch before spawning the next — effectively batch-parallel
# of size PARALLELISM. Correct in both cases, just slower on bash 3.2.
active=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  # Self-reference filtering happens inside publish_one, after the ref is
  # resolved to an absolute path — see the SOURCE_ABS check there.
  publish_one "$ref" &
  active=$((active + 1))
  if [ "$active" -ge "$PARALLELISM" ]; then
    if wait -n 2>/dev/null; then
      active=$((active - 1))
    else
      wait
      active=0
    fi
  fi
done <<< "$REFS"

wait 2>/dev/null || true
exit 0
