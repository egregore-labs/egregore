#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"
EXPECTED_REPO=""

usage() {
  echo "usage: bash bin/contribute-guard.sh [--config <path>] [--expect <owner/repo>]" >&2
  exit 2
}

fail() {
  echo "contribute: $1" >&2
  exit "${2:-2}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || usage
      CONFIG="$2"
      shift 2
      ;;
    --expect)
      [ $# -ge 2 ] || usage
      EXPECTED_REPO="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[ -f "$CONFIG" ] || fail "cannot read configuration at $CONFIG; refusing to select an upstream target"

UPSTREAM_URL=$(jq -er '
  if has("upstream_url") then
    if .upstream_url == null then ""
    elif (.upstream_url | type) == "string" then .upstream_url
    else error("upstream_url must be a string")
    end
  else ""
  end
' "$CONFIG" 2>/dev/null) ||
  fail "configuration is invalid; refusing to select an upstream target"

if [ "$UPSTREAM_URL" = "none" ]; then
  fail 'disabled because upstream_url is "none"; this checkout is a framework source, so use the save workflow for its configured integration branch' 3
fi

[ -n "$UPSTREAM_URL" ] || UPSTREAM_URL="https://github.com/egregore-labs/egregore.git"

case "$UPSTREAM_URL" in
  https://github.com/*/*)
    UPSTREAM_REPO="${UPSTREAM_URL#*github.com/}"
    ;;
  git@github.com:*/*)
    UPSTREAM_REPO="${UPSTREAM_URL#git@github.com:}"
    ;;
  *)
    fail "unsupported upstream_url '$UPSTREAM_URL'; expected a GitHub repository URL"
    ;;
esac

UPSTREAM_REPO="${UPSTREAM_REPO%/}"
UPSTREAM_REPO="${UPSTREAM_REPO%.git}"
printf '%s\n' "$UPSTREAM_REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ||
  fail "invalid upstream repository '$UPSTREAM_REPO'; refusing external Git operations"

if [ -n "$EXPECTED_REPO" ] && [ "$EXPECTED_REPO" != "$UPSTREAM_REPO" ]; then
  fail "target changed from '$EXPECTED_REPO' to '$UPSTREAM_REPO'; refusing external Git operations"
fi

printf '%s\n' "$UPSTREAM_REPO"
