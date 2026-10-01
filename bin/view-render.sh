#!/usr/bin/env bash
# view-render.sh — deterministic /view mechanics: stage, cache, render, open.
#
# The model's job in /view ends at judgment: resolving which artifact the user
# means (and, for documents, picking a design brief). Everything after that is
# mechanical and runs here with no model in the loop — staging the canonical
# source through the Runtime read boundary, serving repeat views from a
# content-addressed cache, invoking the packaged deterministic renderer, and
# opening the result.
#
# Usage:
#   bash bin/view-render.sh <type> [source] [-- <extra renderer args>]
#     type    quest | handoff | document | activity | board | network
#     source  memory/... canonical path (staged via Runtime.open_source),
#             or a local file path (already staged/synthesized).
#             Omitted for the live types (activity, board, network).
#   Extra args after -- are passed to the renderer verbatim (e.g. --brief).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/scratch.sh"
TYPE="${1:-}"
[ -n "$TYPE" ] || { echo "usage: bash bin/view-render.sh <type> [source] [-- renderer args]" >&2; exit 2; }
shift

SOURCE=""
if [ $# -gt 0 ] && [ "$1" != "--" ]; then
  SOURCE="$1"
  shift
fi
[ "${1:-}" = "--" ] && shift
EXTRA=("$@")

_consume_render_inputs() {
  local result=$? input
  for input in ${RENDER_INPUTS[@]+"${RENDER_INPUTS[@]}"}; do
    scratch_consume "$input"
  done
  return "$result"
}

ARTIFACT_DIR="${TMPDIR:-/tmp}/egregore-artifacts"
CACHE_DIR="$HOME/.egregore/runtime/render-cache"
mkdir -p "$ARTIFACT_DIR" "$CACHE_DIR"

_open() {
  if command -v open >/dev/null 2>&1; then open "$1"; else xdg-open "$1" >/dev/null 2>&1; fi
}

# --- Resolve the packaged deterministic renderer (never fetch, never npx) ---
if [ -f "$SCRIPT_DIR/packages/egregore-artifacts/bin/cli.js" ] && [ -d "$SCRIPT_DIR/packages/egregore-artifacts/node_modules/react" ]; then
  RENDER=(bash "$SCRIPT_DIR/bin/node-run.sh" "$SCRIPT_DIR/packages/egregore-artifacts/bin/cli.js")
  RENDER_ID="$SCRIPT_DIR/packages/egregore-artifacts/bin/cli.js"
elif [ -f "$SCRIPT_DIR/packages/egregore-artifacts/bin/cli.js" ]; then
  echo "The checked-out artifact renderer is missing its local dependencies." >&2
  exit 1
elif command -v egregore-artifacts >/dev/null 2>&1; then
  RENDER=(bash "$SCRIPT_DIR/bin/node-run.sh" "$(command -v egregore-artifacts)")
  RENDER_ID="$(command -v egregore-artifacts)"
else
  echo "The local artifact renderer is not installed for this instance." >&2
  exit 1
fi

# --- Live surfaces render fresh every time (their data is the present) ------
case "$TYPE" in
  activity|board|network)
    "${RENDER[@]}" "$TYPE" ${EXTRA[@]+"${EXTRA[@]}"}
    exit $?
    ;;
esac

[ -n "$SOURCE" ] || { echo "type '$TYPE' needs a source file or memory/ path" >&2; exit 2; }

# --- Stage the source through the Runtime read boundary ---------------------
# An absolute path into this instance's memory is still organizational
# memory: normalize it to its canonical memory/... form so it goes through
# the same staging as any other canonical source — never rendered raw.
MEM_ROOT="$(cd "$SCRIPT_DIR/memory" 2>/dev/null && pwd -P || true)"
if [ -n "$MEM_ROOT" ]; then
  case "$SOURCE" in
    /*)
      RESOLVED="$(cd "$(dirname "$SOURCE")" 2>/dev/null && pwd -P)/$(basename "$SOURCE")"
      case "$RESOLVED" in
        "$MEM_ROOT"/*) SOURCE="memory/${RESOLVED#"$MEM_ROOT"/}" ;;
      esac
      ;;
  esac
fi
SLUG="$(basename "$SOURCE" .md | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')"
STAGE="$ARTIFACT_DIR/source-$SLUG.md"
case "$SOURCE" in
  memory/*)
    # Rendering consumes a complete authorized document, not an agent's bounded
    # evidence window. The existing adapter calls Runtime.open_source, retaining
    # actor, READ-scope and admin checks without adding pagination text to prose.
    if ! EGREGORE_ROOT="$SCRIPT_DIR" PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
      python3 -m egregore_runtime.adapters.qmd_cli open "$SOURCE" > "$STAGE" 2>/dev/null || [ ! -s "$STAGE" ]; then
      echo "source '$SOURCE' could not be opened through the Runtime read boundary" >&2
      rm -f "$STAGE"
      exit 1
    fi
    ;;
  *)
    [ -f "$SOURCE" ] || { echo "source file not found: $SOURCE" >&2; exit 1; }
    STAGE="$SOURCE"
    ;;
esac

# --- Content-addressed cache: same bytes + same renderer + same args --------
RENDER_INPUTS=("$STAGE")
for ((i=0; i<${#EXTRA[@]}; i++)); do
  if [ "${EXTRA[i]}" = "--brief" ] && [ "$((i + 1))" -lt "${#EXTRA[@]}" ]; then
    RENDER_INPUTS+=("${EXTRA[i+1]}")
  fi
done
trap _consume_render_inputs EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
FINGERPRINT="$(
  {
    shasum -a 256 "$STAGE" "$RENDER_ID" 2>/dev/null
    printf '%s\n' "$TYPE" ${EXTRA[@]+"${EXTRA[@]}"}
    for a in ${EXTRA[@]+"${EXTRA[@]}"}; do [ -f "$a" ] && shasum -a 256 "$a" 2>/dev/null; done
  } | shasum -a 256 | cut -c1-16
)"
OUT="$CACHE_DIR/$TYPE-$SLUG-$FINGERPRINT.html"

if [ -s "$OUT" ]; then
  NO_OPEN=0
  for a in ${EXTRA[@]+"${EXTRA[@]}"}; do [ "$a" = "--no-open" ] && NO_OPEN=1; done
  if [ "$NO_OPEN" = 1 ]; then
    echo "✓ Artifact written: $OUT"
  else
    _open "$OUT"
    echo "✓ Artifact opened in browser"
    echo "  File: $OUT"
  fi
  echo "  (served from render cache)"
  exit 0
fi

# The renderer prints its own report and opens the browser itself.
if ! "${RENDER[@]}" "$TYPE" "$STAGE" --output "$OUT" ${EXTRA[@]+"${EXTRA[@]}"}; then
  rm -f "$OUT"
  exit 1
fi
[ -s "$OUT" ] || { echo "renderer produced no output" >&2; exit 1; }
