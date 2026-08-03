#!/usr/bin/env bash
set -euo pipefail

# publish-artifact.sh — Generate HTML artifact + upload to API
# Usage: publish-artifact.sh <type> <file> [--title "..."] [--author "..."] [--description "..."] [--id "..."] [--raw-html] [--no-references]
#
# Connected mode (API key present): publishes to /api/artifacts/publish (permanent, org-scoped)
# OSS mode (no API key): publishes to /api/artifacts/share on a PUBLIC, UNAUTHENTICATED
#   relay (ephemeral, 7-day TTL). OFF unless the instance opted in — see
#   "Public-relay opt-in" below and `bin/settings.sh relay on`.
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
# Outputs artifact URL on success, exits silently on soft failure.
# Designed for fire-and-forget use: `bash bin/publish-artifact.sh handoff file.md &`
#
# Exit codes: 0 ok (or soft failure — no URL on stdout) · 1 usage/validation
#             3 hosting turned off (features.publishing=false)
#             4 nothing uploaded — public relay not enabled and no org API key,
#               or egregore.json is missing/unreadable (fail closed)
#             5 renderer/fidelity validation failed (nothing uploaded)

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
PAIR=""
VERIFY_FIDELITY=0
FIDELITY_SOURCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --id) ARTIFACT_ID="$2"; shift 2 ;;
    --pair) PAIR="$2"; shift 2 ;;
    --verify-fidelity) VERIFY_FIDELITY=1; shift ;;
    --source) FIDELITY_SOURCE="$2"; shift 2 ;;
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
  EGREGORE_USE_PUBLISHED="${EGREGORE_USE_PUBLISHED:-$(grep '^EGREGORE_USE_PUBLISHED=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
fi

# A config we cannot parse is a config we cannot trust. Every routing decision
# below — authenticated org upload vs. public relay, hosting on vs. off — is
# read out of this file, so an unreadable one means we cannot tell those apart.
if [ ! -f "$CONFIG" ] || ! jq -e 'type == "object"' "$CONFIG" >/dev/null 2>&1; then
  echo "Not published — nothing left this machine." >&2
  echo "egregore.json is missing or unreadable, so there is no way to tell an authenticated org upload from a public one." >&2
  exit 4
fi

API_URL="${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)}"
API_KEY="${EGREGORE_API_KEY:-}"
ORG_SLUG="$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)"
VIEW_BASE="https://egregore.xyz/view"

# Resolve "use published renderer" from env first, then egregore.json. The
# env var lets individuals override per-shell; egregore.json lets an
# instance (e.g. the upstream dev repo) opt in for every teammate.
if [ -z "${EGREGORE_USE_PUBLISHED:-}" ]; then
  CONFIG_USE_PUBLISHED="$(jq -r '.prefer_published_artifacts // empty' "$CONFIG" 2>/dev/null)"
  if [ "$CONFIG_USE_PUBLISHED" = "true" ]; then
    EGREGORE_USE_PUBLISHED=1
  fi
fi

# Public relay for OSS share endpoint. Unauthenticated: anything posted here is
# readable by anyone holding the URL, for 7 days, with nothing in front of it.
RELAY_URL="https://egregore-production-55f2.up.railway.app"

# --- Artifact hosting off-switch (compliance / privacy) ---
# An instance can disable ALL egregore.xyz publishing via `bin/settings.sh hosting off`
# (sets features.publishing=false). Absent/true means ON, so existing instances are
# unaffected. We bail BEFORE any render or upload so "off" truly does nothing and costs
# nothing. Exit 3 is distinct from usage errors; fire-and-forget callers ignore it.
# NOTE: test `!= false`, not jq's `// "true"` — `//` treats an explicit `false` as empty
# and would return the default, silently defeating the off-switch.
PUBLISHING_ENABLED="$(jq -r 'if .features.publishing == false then "false" else "true" end' "$CONFIG" 2>/dev/null || echo "true")"
if [ "$PUBLISHING_ENABLED" = "false" ]; then
  echo "Artifact hosting is off for this egregore (features.publishing=false); nothing uploaded." >&2
  echo "Turn it on with: bin/settings.sh hosting on   (or: egregore settings → Hosting)." >&2
  exit 3
fi

# --- Public-relay opt-in (privacy) ---
# Without BOTH an api_url and an org API key there is exactly one upload route
# left: the unauthenticated public relay below. Content must not leave the
# machine for that route unless a person explicitly enabled it. The gate sits
# before rendering so the default path generates and uploads nothing.
#
# NOTE: use an explicit `== true` test, never jq's `// false`: `//` treats an
# explicit false like null and silently replaces it with the default.
if [ -z "$API_URL" ] || [ -z "$API_KEY" ]; then
  PUBLIC_RELAY_ENABLED="$(jq -r 'if .features.public_relay == true then "true" else "false" end' "$CONFIG" 2>/dev/null || echo "false")"
  if [ "$PUBLIC_RELAY_ENABLED" != "true" ]; then
    echo "Not published — nothing left this machine." >&2
    echo "Without an org API key the only sharing route is a public relay: no auth, anyone with the link can read it, expires after 7 days. It is off unless you turn it on." >&2
    echo "Turn it on with: bin/settings.sh relay on" >&2
    exit 4
  fi
fi

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
  # Palette family (meridian default | agronomic | sovereign). Role-token driven,
  # so it themes any composed artifact with no extra CSS.
  if [ -n "$PAIR" ]; then
    RENDER_ARGS+=(--pair "$PAIR")
  fi
  if [ "$VERIFY_FIDELITY" -eq 1 ]; then
    RENDER_ARGS+=(--verify-fidelity)
    if [ "$TYPE" = "composed" ]; then
      [ -n "$FIDELITY_SOURCE" ] || {
        echo "Handoff fidelity check requires --source <canonical-handoff.md>" >&2
        exit 1
      }
      RENDER_ARGS+=(--source "$FIDELITY_SOURCE")
    fi
  fi

  # Prefer the in-repo package copy when it's present AND its dependencies
  # have been installed — that way local edits to packages/egregore-artifacts
  # are exercised without waiting for an npm release. Fall back to the
  # published `npx egregore-artifacts` otherwise.
  # Set EGREGORE_USE_PUBLISHED=1 to force the npm-published renderer even
  # when a local install is present — useful in the upstream dev repo to
  # dogfood what teammates and OSS users actually run.
  LOCAL_CLI="$SCRIPT_DIR/packages/egregore-artifacts/bin/cli.js"
  RENDER_ERROR="/tmp/egregore-artifacts/render-error-$$.log"
  if [ "${EGREGORE_USE_PUBLISHED:-0}" != "1" ] && [ -f "$LOCAL_CLI" ] && [ -d "$SCRIPT_DIR/packages/egregore-artifacts/node_modules/react" ]; then
    if ! node "$LOCAL_CLI" "${RENDER_ARGS[@]}" >/dev/null 2>"$RENDER_ERROR"; then
      sed -n '1,4p' "$RENDER_ERROR" >&2
      rm -f "$RENDER_ERROR"
      exit 5
    fi
  else
    if ! npx -y egregore-artifacts@latest "${RENDER_ARGS[@]}" >/dev/null 2>"$RENDER_ERROR"; then
      sed -n '1,4p' "$RENDER_ERROR" >&2
      rm -f "$RENDER_ERROR"
      exit 5
    fi
  fi
  rm -f "$RENDER_ERROR"
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
    # Register in the local artifact registry (memory/artifacts/) so this hosted
    # artifact is findable by CONTENT, not just name — grep/ls (Claude Code /
    # Codex, OSS), and search + graph (paid). Never fatal to the publish.
    bash "$SCRIPT_DIR/bin/artifact-register.sh" \
      --id "$ARTIFACT_ID" --url "$URL" --type "$TYPE" --title "$TITLE" \
      --author "$AUTHOR" --source "$FILE" --description "$DESCRIPTION" \
      >/dev/null 2>&1 || true
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
