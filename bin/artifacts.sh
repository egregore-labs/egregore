#!/usr/bin/env bash
# The link commands read the org API key: never trace it.
set +vx

# artifacts.sh — find something you generated, by NAME or CONTENT, and get its URL.
#
#   artifacts find [--since D|--until D|--on D] <query...>   rank matches
#   artifacts list [N]                                       most recently recorded
#
# Both run in the Runtime (`harness_cli artifacts`), which ranks hosted
# artifacts, handoffs, emissaries and knowledge as this script once did and
# prints only what the reader may see. The hosted link controls stay here.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/lib/config.sh
source "$SCRIPT_DIR/bin/lib/config.sh"

_runtime_artifacts() {
  EGREGORE_ROOT="$SCRIPT_DIR" PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m egregore_runtime.harness_cli artifacts "$1" -- "${@:2}"
}

# --- Hosted link controls (Connected: the page lives on egregore.xyz) --------
#   artifacts close <id>    close the link now; it opens a "link closed" notice
#   artifacts reopen <id>   open it again, with no closing date
#   artifacts opens <id>    when the page was opened (people; previews apart)
_link_call() { # <method> <id> <action> → JSON on stdout; plain reason on failure
  local method="$1" id="$2" action="$3" api_url api_key body status
  api_url="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2-)}"
  api_url="$(_hosted_api_url "${api_url:-$(jq -r '.api_url // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)}")" || return 4
  api_key="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2-)}"
  if [ -z "$api_url" ] || [ -z "$api_key" ]; then
    echo "Hosted links are part of Egregore Connect; this configuration has none." >&2
    return 4
  fi
  if ! [[ "$id" =~ ^[A-Za-z0-9_-]{1,50}$ ]]; then
    echo "usage: artifacts $action <id>   (the id in egregore.xyz/view/<org>/<id>)" >&2
    return 1
  fi
  body="$(mktemp)"
  # The key goes in on standard input, never in curl's arguments, which any
  # local process can read.
  status="$(curl -q -s -o "$body" -w '%{http_code}' -X "$method" -H @- \
    "${api_url}/api/artifact-links/${id}/${action}" <<< "Authorization: Bearer ${api_key}")" || status=000
  if [ "$status" != "200" ]; then
    case "$status" in
      404) echo "This organization has no hosted page with the id '$id'." >&2 ;;
      401|403) echo "The API key was refused; run /env to check it." >&2 ;;
      000) echo "Could not reach the Egregore API; check the connection and try again." >&2 ;;
      *) echo "The API answered $status: $(jq -r '.detail // empty' "$body" 2>/dev/null)" >&2 ;;
    esac
    rm -f "$body"
    return 1
  fi
  cat "$body"
  rm -f "$body"
}

cmd_close() {
  local out; out="$(_link_call POST "${1:-}" close)" || return $?
  printf 'Closed: egregore.xyz/view/…/%s now opens a "link closed" notice.\n' "$1"
  jq -r '.note // empty' <<< "$out"
  echo "Reopen with: bash bin/artifacts.sh reopen $1"
}

cmd_reopen() {
  _link_call POST "${1:-}" reopen >/dev/null || return $?
  printf 'Reopened: %s has no closing date.\n' "$1"
}

cmd_opens() {
  local out; out="$(_link_call GET "${1:-}" opens)" || return $?
  jq -r '
    (if .opens == 0 then "Not opened by anyone yet."
     else "Opened \(.opens) time\(if .opens == 1 then "" else "s" end) by people · first \(.first) · last \(.last) (UTC)" end),
    (if .automated > 0 then "\(.automated) more fetch\(if .automated == 1 then "" else "es" end) by link previews and bots." else empty end),
    (if .complete then empty else "Counts cover the newest 500 opens." end),
    "Counted at most once a minute; opens the edge cache answers (within 5 minutes) go uncounted."
  ' <<< "$out"
}

case "${1:-find}" in
  find) shift; _runtime_artifacts find "$@" ;;
  list) shift; _runtime_artifacts list "$@" ;;
  close) shift; cmd_close "$@" ;;
  reopen) shift; cmd_reopen "$@" ;;
  opens) shift; cmd_opens "$@" ;;
  *) _runtime_artifacts find "$@" ;;
esac
