#!/usr/bin/env bash
# Refresh the Connect runtime overlay (skills served by the org's API) for
# this instance. Fired fire-and-forget from session start on every runtime;
# local-mode instances exit immediately and nothing here may block or break
# a session. New Connect features appear without re-running the launcher.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 0

# Connected instances only — resolved the same way the runtime does.
MODE=$(jq -r '.mode // empty' egregore.json 2>/dev/null)
API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
if [ "$MODE" != "connected" ] && [ -z "$API_URL" ]; then
  exit 0
fi

# The refresh runs whichever create-egregore npx has cached, which may be a
# release from before the October 2026 security reset: it sends the org key
# to the saved address exactly as written. Run it only when that address needs
# no resolving, so it never reaches the retired origin or an address the
# resolver refuses (bin/lib/config.sh). Those wait for /update, quietly.
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh" 2>/dev/null || exit 0
SAVED="$API_URL"
SAVED="${SAVED#"${SAVED%%[![:space:]]*}"}"
SAVED="${SAVED%"${SAVED##*[![:space:]]}"}"
while [ "${SAVED%/}" != "$SAVED" ]; do SAVED="${SAVED%/}"; done
RESOLVED="$(EGREGORE_ADDRESS_NOTICE=shown _hosted_api_url "$API_URL" 2>/dev/null)" || exit 0
if [ -z "$RESOLVED" ] || [ "$RESOLVED" != "$SAVED" ]; then
  exit 0
fi

LOG_DIR="$ROOT/.egregore"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/connect-refresh.log"

# The refresh logic lives in the installed create-egregore tooling (client
# instances do not carry packages/ in their tree). --prefer-offline keeps the
# common case fast; the first run may fetch the package once.
{
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] connect refresh"
  npx --yes --prefer-offline create-egregore --refresh-connect 2>&1
} >>"$LOG" 2>&1 || true

# Keep the log bounded.
tail -n 200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
exit 0
