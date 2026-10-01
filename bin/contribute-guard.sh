#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"
EXPECTED_REPO=""
# shellcheck source=bin/lib/config.sh
source "$SCRIPT_DIR/bin/lib/config.sh"

usage() {
  echo "usage: bash bin/contribute-guard.sh [--config <path>] [--expect <owner/repo>]" >&2
  echo "       bash bin/contribute-guard.sh scan [--config <path>] [--stdin | --] [file ...]" >&2
  exit 2
}

fail() {
  echo "contribute: $1" >&2
  exit "${2:-2}"
}

scan() {
  local from_stdin=false key value file status=0 grep_status
  local files=() patterns=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --config)
        [ $# -ge 2 ] || usage
        CONFIG="$2"
        shift 2
        ;;
      --stdin)
        from_stdin=true
        shift
        ;;
      --)
        shift
        files+=("$@")
        break
        ;;
      -*) usage ;;
      *)
        files+=("$1")
        shift
        ;;
    esac
  done
  if "$from_stdin"; then
    [ "${#files[@]}" -eq 0 ] || usage
    while IFS= read -r file || [ -n "$file" ]; do
      [ -z "$file" ] || files+=("$file")
    done
  fi
  [ -r "$CONFIG" ] || fail "cannot read configuration at $CONFIG; refusing to scan"
  jq -e 'type == "object" and all(.org_name, .github_org, .slug; . == null or type == "string")' \
    "$CONFIG" >/dev/null 2>&1 || fail 'configuration is invalid; refusing to scan'
  [ "${#files[@]}" -gt 0 ] || return 0
  for file in "${files[@]}"; do
    # Validate the complete list before emitting any matches. Deleted paths
    # can still appear in the contribution's diff file list.
    [ -e "$file" ] || continue
    [ -f "$file" ] && [ -r "$file" ] || fail "cannot read file $file; refusing to scan"
  done
  for key in org_name github_org slug; do
    value="$(_config_val "$key")"
    # An absent identifier must not turn into a pattern matching every line.
    [ -z "$value" ] || patterns+=(-e "$value")
  done
  [ "${#patterns[@]}" -gt 0 ] || return 0
  for file in "${files[@]}"; do
    [ -e "$file" ] || continue
    grep -Hn "${patterns[@]}" -- "$file"
    grep_status=$?
    case "$grep_status" in
      0) status=1 ;;
      1) ;;
      *) fail "could not scan file $file" ;;
    esac
  done
  return "$status"
}

if [ "${1:-}" = scan ]; then
  shift
  scan "$@"
  exit $?
fi

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
