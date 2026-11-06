#!/usr/bin/env bash
# Decide "Request access" asks for this organisation's hosted pages.
#
#   bash bin/page-access.sh requests [--page <id>] [--status pending|granted|declined|all]
#   bash bin/page-access.sh grant <request-id>
#   bash bin/page-access.sh decline <request-id>
#
# Someone signed in who opens a page outside its audience (publish-artifact.sh
# --visible-to) can ask for it. A grant adds their email to the page's
# audience; a decline shows them "Request declined" and stops new asks for
# seven days. Nothing is sent to anyone: the requester sees the outcome on
# the page. Connected mode only. The org key names the organisation and your
# own GitHub token proves who decides; both stay inside bin/api-call.sh.
#
# Exit: 0 done, 1 the request failed, 2 usage, 4 Local mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/config.sh"

usage() {
  echo 'Usage: bash bin/page-access.sh requests [--page <id>] [--status pending|granted|declined|all]' >&2
  echo '       bash bin/page-access.sh grant <request-id>' >&2
  echo '       bash bin/page-access.sh decline <request-id>' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
command="$1"
shift

page=''
status=pending
request_id=''
case "$command" in
  requests)
    while [ "$#" -gt 0 ]; do
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --page) page="$2" ;;
        --status) status="$2" ;;
        *) usage ;;
      esac
      shift 2
    done
    [[ "$status" =~ ^(pending|granted|declined|all)$ ]] || usage
    [ -z "$page" ] || [[ "$page" =~ ^[A-Za-z0-9_-]{1,50}$ ]] || usage
    ;;
  grant|decline)
    [ "$#" -eq 1 ] || usage
    request_id="$1"
    [[ "$request_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || usage
    ;;
  *) usage ;;
esac

if [ "$(_detect_mode)" != connected ]; then
  echo 'page-access: asking for a page and deciding requests needs Connected mode, where pages open by identity. In Local mode, hand over the password-protected file instead.' >&2
  exit 4
fi

mkdir -p "$SCRIPT_DIR/tmp"
out=$(mktemp "$SCRIPT_DIR/tmp/page-access.XXXXXX")
err=$(mktemp "$SCRIPT_DIR/tmp/page-access-error.XXXXXX")
trap 'rm -f -- "$out" "$err"' EXIT

call() {
  if ! bash "$SCRIPT_DIR/bin/api-call.sh" "$1" "$2" --auth egregore+github \
      --out "$out" --error-out "$err"; then
    detail=$(jq -r '.detail // empty' "$err" 2>/dev/null || true)
    [ -z "$detail" ] || printf 'page-access: %s\n' "$detail" >&2
    exit 1
  fi
}

case "$command" in
  requests)
    path="/api/page-access/requests?status=$status"
    [ -z "$page" ] || path="$path&page=$page"
    call GET "$path"
    if [ "$(jq '.requests | length' "$out")" -eq 0 ]; then
      echo "No $([ "$status" = all ] || printf '%s ' "$status")requests."
      exit 0
    fi
    jq -r '.requests[] | [
        .id,
        .page,
        (.requester.email + (if .requester.handle then " (@" + .requester.handle + ")" else "" end)),
        .status,
        .requested_at,
        (if .decided_by then "by " + .decided_by + " " + .decided_at else "" end)
      ] | @tsv' "$out"
    ;;
  grant)
    call POST "/api/page-access/requests/$request_id/grant"
    jq -r '"Granted: " + .request.requester.email + " can open " + .request.page + " when signed in."' "$out"
    ;;
  decline)
    call POST "/api/page-access/requests/$request_id/decline"
    jq -r '"Declined: " + .request.requester.email + " sees \"Request declined\" on " + .request.page + " and cannot ask again for seven days."' "$out"
    ;;
esac
