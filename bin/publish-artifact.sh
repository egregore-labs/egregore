#!/bin/bash
set -euo pipefail

# publish-artifact.sh — Generate HTML artifact + upload to API
# Usage: publish-artifact.sh <type> <file> [--title "..."] [--author "..."] [--description "..."] [--id "..."] [--raw-html] [--no-references]
#
# Connected mode (API key present): publishes to /api/artifacts/publish (permanent, org-scoped)
# OSS mode (no API key): publishes to /api/artifacts/share (ephemeral, 7-day TTL)
#
# --id <slug>: stable artifact ID — re-publishing with the same ID upserts the content
#              at the same URL (e.g. egregore.xyz/view/{org}/board). Connected mode only;
#              ignored in OSS mode. Must be 1-50 chars, alphanumeric/hyphen/underscore.
#
# --raw-html:  Skip the egregore-artifacts render step and upload <file> directly.
#              Use for already-rendered HTML attachments referenced from a handoff.
#
# --no-references: Skip the depth-1 auto-publish of backtick-referenced memory files.
#              Set automatically when publish-references.sh invokes us for a child,
#              preventing recursion.
#
# Outputs artifact URL on success, exits silently on failure.
# Designed for fire-and-forget use: `bash bin/publish-artifact.sh handoff file.md &`

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"

# --- Parse arguments ---
TYPE=""
FILE=""
TITLE=""
AUTHOR=""
DESCRIPTION=""
ARTIFACT_ID=""
RAW_HTML=0
SKIP_REFERENCES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --id) ARTIFACT_ID="$2"; shift 2 ;;
    --raw-html) RAW_HTML=1; shift ;;
    --no-references) SKIP_REFERENCES=1; shift ;;
    *)
      if [ -z "$TYPE" ]; then
        TYPE="$1"
      elif [ -z "$FILE" ]; then
        FILE="$1"
      fi
      shift ;;
  esac
done

if [ -z "$TYPE" ] || [ -z "$FILE" ]; then
  echo "Usage: publish-artifact.sh <type> <file> [--title ...] [--author ...] [--description ...] [--id ...]" >&2
  exit 1
fi

# Validate --id format if provided (matches API regex ^[a-zA-Z0-9_-]{1,50}$)
if [ -n "$ARTIFACT_ID" ] && ! [[ "$ARTIFACT_ID" =~ ^[a-zA-Z0-9_-]{1,50}$ ]]; then
  echo "--id must be 1-50 chars, alphanumeric/hyphen/underscore only" >&2
  exit 1
fi

if [ ! -f "$FILE" ]; then
  echo "File not found: $FILE" >&2
  exit 1
fi

# --- Load config ---
if [ -f "$SCRIPT_DIR/.env" ]; then
  EGREGORE_API_URL="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
  EGREGORE_API_KEY="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
fi

API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)}"
API_KEY="${EGREGORE_API_KEY:-}"
ORG_SLUG="$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)"
VIEW_BASE="https://egregore.xyz/view"

# Public relay for OSS share endpoint
RELAY_URL="https://egregore-production-55f2.up.railway.app"

# --- Prepare HTML ---
TMP_HTML="/tmp/egregore-artifacts/publish-$$.html"
mkdir -p /tmp/egregore-artifacts

if [ "$RAW_HTML" -eq 1 ]; then
  # Upload the file as-is (used for pre-rendered HTML attachments).
  cp "$FILE" "$TMP_HTML" 2>/dev/null || exit 0
else
  # Pass --org-slug + --view-base so the renderer can emit clickable links
  # for backtick `memory/*.{md,html}` references. Only when connected AND the
  # slug is known — in OSS mode we leave them empty so rendering falls back
  # to plain <code> and we don't produce dead links.
  RENDER_ARGS=("$TYPE" "$FILE" --output "$TMP_HTML")
  if [ -n "$API_KEY" ] && [ -n "$ORG_SLUG" ]; then
    RENDER_ARGS+=(--org-slug "$ORG_SLUG" --view-base "$VIEW_BASE")
  fi

  # Prefer the in-repo package copy when it's present AND its dependencies
  # have been installed — that way local edits to packages/egregore-artifacts
  # are exercised without waiting for an npm release. Fall back to the
  # published `npx egregore-artifacts` otherwise.
  LOCAL_CLI="$SCRIPT_DIR/packages/egregore-artifacts/bin/cli.js"
  if [ -f "$LOCAL_CLI" ] && [ -d "$SCRIPT_DIR/packages/egregore-artifacts/node_modules/react" ]; then
    if ! node "$LOCAL_CLI" "${RENDER_ARGS[@]}" >/dev/null 2>&1; then
      exit 0
    fi
  else
    if ! npx egregore-artifacts "${RENDER_ARGS[@]}" >/dev/null 2>&1; then
      exit 0
    fi
  fi
fi

if [ ! -f "$TMP_HTML" ]; then
  exit 0
fi

# Default title from filename if not provided
if [ -z "$TITLE" ]; then
  TITLE="$(basename "$FILE" | sed 's/\.[^.]*$//' | sed 's/[-_]/ /g')"
fi

# --- Upload ---
RESPONSE=""

if [ -n "$API_URL" ] && [ -n "$API_KEY" ]; then
  # Connected mode: permanent, org-scoped
  RESPONSE=$(curl -s -X POST "${API_URL}/api/artifacts/publish" \
    -H "Authorization: Bearer $API_KEY" \
    -F "file=@${TMP_HTML}" \
    -F "artifact_type=${TYPE}" \
    -F "title=${TITLE}" \
    -F "author=${AUTHOR}" \
    -F "description=${DESCRIPTION}" \
    -F "artifact_id=${ARTIFACT_ID}" \
    --max-time 15 2>/dev/null) || true
else
  # OSS mode: ephemeral, 7-day TTL
  RESPONSE=$(curl -s -X POST "${RELAY_URL}/api/artifacts/share" \
    -F "file=@${TMP_HTML}" \
    -F "artifact_type=${TYPE}" \
    -F "title=${TITLE}" \
    -F "author=${AUTHOR}" \
    -F "description=${DESCRIPTION}" \
    --max-time 15 2>/dev/null) || true
fi

# Clean up
rm -f "$TMP_HTML"

# Output URL if successful
URL=""
if [ -n "$RESPONSE" ]; then
  URL=$(echo "$RESPONSE" | jq -r '.url // empty' 2>/dev/null)
  if [ -n "$URL" ]; then
    echo "$URL"
  fi
fi

# Depth-1 auto-publish of backtick-referenced memory files so the clickable
# links in the rendered parent resolve. Connected mode only; the helper exits
# silently in OSS mode. Skipped when:
#   - parent publish failed (no URL),
#   - --raw-html (HTML attachments don't embed markdown refs we'd parse),
#   - --no-references (caller explicitly opts out / recursion guard).
if [ -n "$URL" ] && [ "$RAW_HTML" -eq 0 ] && [ "$SKIP_REFERENCES" -eq 0 ]; then
  bash "$SCRIPT_DIR/bin/publish-references.sh" "$FILE" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
