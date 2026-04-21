#!/bin/bash
set -euo pipefail

# publish-artifact.sh — Generate HTML artifact + upload to API
# Usage: publish-artifact.sh <type> <file> [--title "..."] [--author "..."] [--description "..."] [--id "..."]
#
# Connected mode (API key present): publishes to /api/artifacts/publish (permanent, org-scoped)
# OSS mode (no API key): publishes to /api/artifacts/share (ephemeral, 7-day TTL)
#
# --id <slug>: stable artifact ID — re-publishing with the same ID upserts the content
#              at the same URL. Managed Egregore only; ignored otherwise.
#              Must be 1-50 chars, alphanumeric/hyphen/underscore.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --id) ARTIFACT_ID="$2"; shift 2 ;;
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

# Public relay for OSS share endpoint
RELAY_URL="https://egregore-production-55f2.up.railway.app"

# --- Generate HTML ---
TMP_HTML="/tmp/egregore-artifacts/publish-$$.html"
mkdir -p /tmp/egregore-artifacts

if ! npx egregore-artifacts "$TYPE" "$FILE" --output "$TMP_HTML" >/dev/null 2>&1; then
  # Silent failure — don't block caller
  exit 0
fi

if [ ! -f "$TMP_HTML" ]; then
  exit 0
fi

# Default title from filename if not provided
if [ -z "$TITLE" ]; then
  TITLE="$(basename "$FILE" .md | sed 's/[-_]/ /g')"
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
if [ -n "$RESPONSE" ]; then
  URL=$(echo "$RESPONSE" | jq -r '.url // empty' 2>/dev/null)
  if [ -n "$URL" ]; then
    echo "$URL"
  fi
fi
