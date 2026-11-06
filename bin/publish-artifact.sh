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
#              An ID another org already holds is refused (HTTP 409, exit 6).
#
# --canonical-id <id>: the memory file's path-derived id (bin/lib/artifact-id.sh)
#              when --id is the random hosted id publish-references.sh gave it.
#              Recorded in the registry so the next publish reuses the hosted id.
#
# --raw-html:  Skip the egregore-artifacts render step and upload <file> directly.
#              Use for already-rendered HTML attachments referenced from a handoff.
#
# --no-references: Skip the depth-1 auto-publish of backtick-referenced memory files.
#              Set automatically when publish-references.sh invokes us for a child,
#              preventing recursion.
#
# --expires <days|never>: close the page's link that many days from now (1-365),
#              or keep it open with never. Left out, a republish keeps the
#              link's current closing date. Org pages only; close, reopen and
#              see opens with bin/artifacts.sh close|reopen|opens <id>.
#
# --visible-to <@handle|email,...|public>: open the page only to these signed-in
#              people (Connected only; refused in Local). public reopens it to
#              anyone with the link; left out, a republish keeps the list.
#
# Outputs artifact URL on success, exits silently on soft failure (the server
# could not be reached).
# Designed for fire-and-forget use: `bash bin/publish-artifact.sh handoff file.md &`
#
# Exit codes: 0 ok (or soft failure — no URL on stdout) · 1 usage/validation
#             3 hosting turned off (features.publishing=false)
#             4 nothing uploaded — public relay not enabled and no org API key,
#               or egregore.json is missing/unreadable (fail closed)
#             5 renderer/fidelity validation failed (nothing uploaded)
#             6 the server answered but did not publish, for example 409 when
#               another org already holds the --id; the reason is on stderr
#               as "Not published: <reason>"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"
# shellcheck source=bin/lib/config.sh
source "$SCRIPT_DIR/bin/lib/config.sh"

# --- Parse arguments ---
TYPE=""
FILE=""
TITLE=""
AUTHOR=""
DESCRIPTION=""
ARTIFACT_ID=""
CANONICAL_ID=""
RAW_HTML=0
SKIP_REFERENCES=0
ALLOW_ADMIN=0
PAIR=""
VERIFY_FIDELITY=0
FIDELITY_SOURCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --id) ARTIFACT_ID="$2"; shift 2 ;;
    --canonical-id) CANONICAL_ID="$2"; shift 2 ;;
    --pair) PAIR="$2"; shift 2 ;;
    --verify-fidelity) VERIFY_FIDELITY=1; shift ;;
    --source) FIDELITY_SOURCE="$2"; shift 2 ;;
    --raw-html) RAW_HTML=1; shift ;;
    --allow-admin) ALLOW_ADMIN=1; shift ;;
    --no-references) SKIP_REFERENCES=1; shift ;;
    --expires) EXPIRES="$2"; shift 2 ;;
    --visible-to) VISIBLE_TO="$2"; shift 2 ;;
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
if [ -n "${EXPIRES:-}" ] && ! [[ "$EXPIRES" =~ ^([1-9][0-9]{0,2}|never)$ && ( "$EXPIRES" == never || "$EXPIRES" -le 365 ) ]]; then
  echo "--expires takes a number of days from 1 to 365, or never" >&2
  exit 1
fi
if [ -n "${VISIBLE_TO:-}" ] && ! [[ "$VISIBLE_TO" =~ ^(public|[^,[:space:]]+(,[^,[:space:]]+){0,49})$ ]]; then
  echo "--visible-to takes @handles or emails separated by commas, or public" >&2
  exit 1
fi
if [ -n "$CANONICAL_ID" ] && ! [[ "$CANONICAL_ID" =~ ^[mh]-[0-9a-f]{12}$ ]]; then
  echo "--canonical-id must be a memory file id (m- or h- and 12 hex characters)" >&2
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

# A refused address stops here: a Connected org's page must never fall back
# to the public relay because its saved address is not plain.
if ! API_URL="$(_hosted_api_url "${EGREGORE_API_URL:-$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)}")"; then
  echo "Not published — nothing left this machine." >&2
  exit 4
fi
API_KEY="${EGREGORE_API_KEY:-}"
ORG_SLUG="$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)"
VIEW_BASE="https://egregore.xyz/view"

# A page opened by identity needs the hosted sign-in, so it is org-only. The
# public relay would show it to anyone with the link: refuse, upload nothing.
if [ -n "${VISIBLE_TO:-}" ] && { [ -z "$API_URL" ] || [ -z "$API_KEY" ]; }; then
  echo "Not published — nothing left this machine." >&2
  echo "--visible-to opens a page by identity, which needs Connected mode. In Local mode, hand over the password-protected file instead." >&2
  exit 4
fi

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
RELAY_URL="$EGREGORE_HOSTED_API_ORIGIN"

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

# --- Held-content gate: a publish is a hand-over -----------------------------
# The source and every backtick-referenced memory file go through one
# `access check --hand-over`: every held class is refused to a non-admin,
# under every policy, and a failed check refuses too. An admin may publish
# held material only with the explicit --allow-admin confirmation, which is
# separate from and never replaces normal publication approval.
MEMORY_REAL="$(cd "$SCRIPT_DIR/memory" 2>/dev/null && pwd -P || true)"
SOURCE_REAL="$(cd "$(dirname "$FILE")" && pwd -P)/$(basename "$FILE")"
if [ -n "$MEMORY_REAL" ] && [[ "$SOURCE_REAL" == "$MEMORY_REAL"/* ]]; then
  SOURCES=("memory/${SOURCE_REAL#"$MEMORY_REAL"/}")
else
  SOURCES=("$SOURCE_REAL")
fi
if [ "$RAW_HTML" -eq 0 ]; then
  while IFS= read -r ref; do
    rel="${ref//\`/}"
    [ -f "$SCRIPT_DIR/$rel" ] && SOURCES+=("$rel")
  done < <(grep -Eo '`memory/[^`[:space:]]+\.(md|html)`' "$FILE" 2>/dev/null | sort -u)
fi
HELD_CHECK=0
CHECKED="$(cd "$SCRIPT_DIR" && EGREGORE_ROOT="$SCRIPT_DIR" PYTHONSAFEPATH=1 \
  PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m egregore_runtime.harness_cli access check --hand-over "${SOURCES[@]}" 2>/dev/null)" || HELD_CHECK=$?
if [ "$HELD_CHECK" -ne 0 ] || [ -z "$CHECKED" ]; then
  echo "publish refused: a non-admin cannot publish held material, or access could not be checked:" >&2
  printf '%s\n' "$CHECKED" | awk -F '\t' '$3 != "allowed" && NF { print "  " $1 }' >&2
  exit 5
fi
if [ "$ALLOW_ADMIN" -ne 1 ] && printf '%s\n' "$CHECKED" | grep -q ' for everyone else$'; then
  echo "publish refused: this content is held from everyone but admins:" >&2
  printf '%s\n' "$CHECKED" | awk -F '\t' '/ for everyone else$/ { print "  " $1 " (" $4 ")" }' >&2
  echo "re-run with --allow-admin to confirm publishing it" >&2
  echo "(this confirmation is separate from normal publication approval)" >&2
  exit 5
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

  # Use the same provisioned renderer as previews and /view. Rendering never
  # downloads a package; EGREGORE_USE_PUBLISHED skips the source checkout.
  RENDER_ERROR="/tmp/egregore-artifacts/render-error-$$.log"
  if ! bash "$SCRIPT_DIR/bin/artifact-renderer.sh" "${RENDER_ARGS[@]}" >/dev/null 2>"$RENDER_ERROR"; then
    sed -n '1,4p' "$RENDER_ERROR" >&2
    rm -f "$RENDER_ERROR"
    exit 5
  fi
  rm -f "$RENDER_ERROR"
fi

if [ ! -f "$TMP_HTML" ]; then
  exit 0
fi

# --- Hosted ids for referenced memory files ---
# The renderer links each backtick `memory/…` mention to the file's canonical
# id, a hash of its path that anyone who knows the path can compute. Org pages
# open for anyone with the URL, so the page each link opens is hosted under a
# random id instead (bin/lib/hosted-ref-id.sh): the one the registry records
# for the file, or, when this publish goes on to publish its references, a new
# one that publish-references.sh then uses. Point the links there. A mention
# with neither (on a page published with --no-references) keeps the canonical
# link, which the server never serves: nothing is hosted at a computable URL.
REF_IDS=""
if [ "$RAW_HTML" -eq 0 ] && [ -n "$API_KEY" ] && [ -n "$ORG_SLUG" ]; then
  # shellcheck source=bin/lib/artifact-id.sh
  source "$SCRIPT_DIR/bin/lib/artifact-id.sh"
  # shellcheck source=bin/lib/hosted-ref-id.sh
  source "$SCRIPT_DIR/bin/lib/hosted-ref-id.sh"
  MINT_REF_IDS=1
  [ "$SKIP_REFERENCES" -eq 0 ] || MINT_REF_IDS=0
  REF_IDS="$(hosted_ref_ids_for_source "$FILE" "$SCRIPT_DIR/memory/artifacts" "$ORG_SLUG" "$MINT_REF_IDS")"
  if ! hosted_ref_rewrite_links "$TMP_HTML" "$VIEW_BASE/$ORG_SLUG" "$REF_IDS"; then
    echo "Not published: could not point reference links at their hosted pages." >&2
    rm -f "$TMP_HTML" "$TMP_HTML.links"
    exit 5
  fi
fi

# Default title from filename if not provided
if [ -z "$TITLE" ]; then
  TITLE="$(basename "$FILE" | sed 's/\.[^.]*$//' | sed 's/[-_]/ /g')"
fi

# --- Upload ---
RESPONSE=""

if [ -n "$API_URL" ] && [ -n "$API_KEY" ]; then
  # Connected mode: permanent, org-scoped. A list goes to publish-restricted,
  # which a server that cannot open pages by identity does not have: it
  # refuses there instead of ignoring the list and opening the page to all.
  PUBLISH_PATH="/api/artifacts/publish"
  [ -z "${VISIBLE_TO:-}" ] || PUBLISH_PATH="/api/artifacts/publish-restricted"
  RESPONSE=$(curl -s -X POST "${API_URL}${PUBLISH_PATH}" \
    -H "Authorization: Bearer $API_KEY" \
    -F "file=@${TMP_HTML}" \
    -F "artifact_type=${TYPE}" \
    -F "title=${TITLE}" \
    -F "author=${AUTHOR}" \
    -F "description=${DESCRIPTION}" \
    -F "artifact_id=${ARTIFACT_ID}" \
    -F "expires_in_days=${EXPIRES:-}" \
    --form-string "visible_to=${VISIBLE_TO:-}" \
    --max-time 15 2>/dev/null) || true
else
  # OSS mode: ephemeral, 7-day TTL
  if [ -n "${EXPIRES:-}" ]; then
    echo "Note: --expires applies to organization pages; this public copy closes after 7 days." >&2
  fi
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
  # An answer that is not JSON (a proxy error page) has no URL either.
  URL=$(echo "$RESPONSE" | jq -r '.url // empty' 2>/dev/null || true)
  if [ -n "$URL" ]; then
    echo "$URL"
    # Register in the local artifact registry (memory/artifacts/) so this hosted
    # artifact is findable by CONTENT, not just name — grep/ls (Claude Code /
    # Codex, OSS), and search + graph (paid). Never fatal to the publish.
    bash "$SCRIPT_DIR/bin/artifact-register.sh" \
      --id "$ARTIFACT_ID" --url "$URL" --type "$TYPE" --title "$TITLE" \
      --author "$AUTHOR" --source "$FILE" --description "$DESCRIPTION" \
      --canonical-id "$CANONICAL_ID" \
      >/dev/null 2>&1 || true
  else
    # The server refused (409 for an id another org holds, 400, 413, 503…).
    # A distinct exit code lets callers that report stderr on failure show why.
    DETAIL=$(echo "$RESPONSE" | jq -r 'if (.detail | type) == "string" then .detail else empty end' 2>/dev/null || true)
    if [ -n "${VISIBLE_TO:-}" ] && { [ "$DETAIL" = "Not Found" ] || [ "$DETAIL" = "Method Not Allowed" ]; }; then
      DETAIL="the hosted service cannot open pages by identity yet, so nothing was stored."
    fi
    echo "Not published: ${DETAIL:-the server answered without a URL.}" >&2
    exit 6
  fi
fi

# Depth-1 auto-publish of backtick-referenced memory files so the clickable
# links in the rendered parent resolve. Connected mode only; the helper exits
# silently in OSS mode. Skipped when:
#   - parent publish failed (no URL),
#   - --raw-html (HTML attachments don't embed markdown refs we'd parse),
#   - --no-references (caller explicitly opts out / recursion guard).
#   - the page opens by identity (its stored list, so a republish that keeps
#     the list counts): the files it links to would open to anyone.
RESTRICTED=0
if [ -n "$URL" ] && [ "$(echo "$RESPONSE" | jq -r '.visible_to | type' 2>/dev/null || true)" = "array" ]; then
  RESTRICTED=1
  if [ -n "$REF_IDS" ] && [ "$SKIP_REFERENCES" -eq 0 ]; then
    echo "Note: the files this page links to were not published; it opens only for the people it is shared with." >&2
  fi
fi
if [ -n "$URL" ] && [ "$RESTRICTED" -eq 0 ] && [ "$RAW_HTML" -eq 0 ] && [ "$SKIP_REFERENCES" -eq 0 ]; then
  EGREGORE_REF_IDS="$REF_IDS" bash "$SCRIPT_DIR/bin/publish-references.sh" "$FILE" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
