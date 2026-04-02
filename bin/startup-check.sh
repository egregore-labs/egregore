#!/bin/bash
# startup-check.sh — Validate local config and phone home health status.
# Called by session-start.sh in background. Fire-and-forget.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"
ENV_FILE="$SCRIPT_DIR/.env"
STATE_FILE="$SCRIPT_DIR/.egregore-state.json"

# Bail if essential files missing
[ -f "$CONFIG" ] || exit 0
[ -f "$ENV_FILE" ] || exit 0

# --- Read config ---
API_URL=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)
CONFIG_SLUG=$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)
ORG_NAME=$(jq -r '.org_name // empty' "$CONFIG" 2>/dev/null)
GITHUB_ORG=$(jq -r '.github_org // empty' "$CONFIG" 2>/dev/null)

GITHUB_TOKEN=$(grep '^GITHUB_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
API_KEY=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)

[ -z "$API_URL" ] && exit 0
[ -z "$GITHUB_TOKEN" ] && exit 0
[ -z "$CONFIG_SLUG" ] && exit 0

# --- Framework version ---
FRAMEWORK_VERSION=""
if [ -f "$SCRIPT_DIR/bin/session-start.sh" ]; then
  FRAMEWORK_VERSION=$(grep '^FRAMEWORK_VERSION=' "$SCRIPT_DIR/bin/session-start.sh" 2>/dev/null | head -1 | cut -d'"' -f2)
fi

# --- Validate API key ---
KEY_VALID="false"
KEY_SLUG=""
ERRORS="[]"
ERR_LIST=""

if [ -n "$API_KEY" ]; then
  KEY_SLUG=$(echo "$API_KEY" | cut -d'_' -f2)
  if [ "$KEY_SLUG" = "$CONFIG_SLUG" ]; then
    KEY_VALID="true"
  else
    ERR_LIST="\"key_slug_mismatch: key=$KEY_SLUG config=$CONFIG_SLUG\""
  fi
else
  ERR_LIST="\"no_api_key\""
fi

# --- Check memory directory ---
MEMORY_LINKED="false"
if [ -d "$SCRIPT_DIR/memory" ]; then
  MEMORY_LINKED="true"
else
  [ -n "$ERR_LIST" ] && ERR_LIST="$ERR_LIST,"
  ERR_LIST="${ERR_LIST}\"memory_not_found\""
fi

# --- Check git sync ---
GIT_SYNCED="false"
BRANCH=""
if [ -d "$SCRIPT_DIR/.git" ]; then
  BRANCH=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "")
  LOCAL=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo "")
  REMOTE=$(git -C "$SCRIPT_DIR" rev-parse origin/develop 2>/dev/null || echo "none")
  if [ "$LOCAL" = "$REMOTE" ] || git -C "$SCRIPT_DIR" merge-base --is-ancestor origin/develop HEAD 2>/dev/null; then
    GIT_SYNCED="true"
  else
    [ -n "$ERR_LIST" ] && ERR_LIST="$ERR_LIST,"
    ERR_LIST="${ERR_LIST}\"git_behind_develop\""
  fi
fi

ERRORS="[$ERR_LIST]"

# --- Platform info ---
PLATFORM=$(uname -s 2>/dev/null || echo "unknown")
SHELL_NAME=$(basename "$SHELL" 2>/dev/null || echo "unknown")

# --- POST health check-in (fire & forget) ---
PAYLOAD=$(jq -n \
  --arg org_slug "$CONFIG_SLUG" \
  --argjson key_valid "$KEY_VALID" \
  --arg key_slug "$KEY_SLUG" \
  --arg config_slug "$CONFIG_SLUG" \
  --arg framework_version "$FRAMEWORK_VERSION" \
  --argjson memory_linked "$MEMORY_LINKED" \
  --argjson git_synced "$GIT_SYNCED" \
  --arg branch "$BRANCH" \
  --argjson errors "$ERRORS" \
  --arg platform "$PLATFORM" \
  --arg shell "$SHELL_NAME" \
  '{
    org_slug: $org_slug,
    key_valid: $key_valid,
    key_slug: $key_slug,
    config_slug: $config_slug,
    framework_version: $framework_version,
    memory_linked: $memory_linked,
    git_synced: $git_synced,
    branch: $branch,
    errors: $errors,
    platform: $platform,
    shell: $shell
  }')

curl -sf "${API_URL}/api/health/checkin" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --connect-timeout 5 --max-time 10 >/dev/null 2>&1 || true
