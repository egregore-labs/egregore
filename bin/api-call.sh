#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
# Repository selection belongs to this script, never to inherited Git overrides.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# Keep credentials inside the helper and off curl's argument vector.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/egregore.json}"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/config.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/scratch.sh"

usage() {
  echo 'Usage: bash bin/api-call.sh <METHOD> <path-or-url> [--auth github|egregore|resend|egregore+github] [--json-file <file>] [--out <file>] [--error-out <file>]' >&2
  echo 'Failed responses are discarded unless --error-out requests a private HTTP error body.' >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
method="$1"
target="$2"
shift 2
case "$method" in ''|*[!A-Z]*) usage ;; esac
case "$target" in /*|https://?*) ;; *) usage ;; esac
auth=''
json_file=''
out=''
error_out=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] && [ -n "$2" ] || usage
  case "$1" in
    --auth)
      [ -z "$auth" ] || usage
      case "$2" in github|egregore|resend|egregore+github) auth="$2" ;; *) usage ;; esac
      ;;
    --json-file) [ -z "$json_file" ] || usage; json_file="$2" ;;
    --out) [ -z "$out" ] || usage; out="$2" ;;
    --error-out) [ -z "$error_out" ] || usage; error_out="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -z "$out" ] || [ "$out" != "$error_out" ] || usage

mkdir -p "$SCRIPT_DIR/tmp"
out_dir=''
if [ -n "$out" ]; then
  out_dir=$(dirname -- "$out")
  if [ -d "$out" ] || [[ "$out" == */ ]] || [ ! -d "$out_dir" ] \
      || [ ! -w "$out_dir" ] || [ ! -x "$out_dir" ]; then
    printf 'api-call: cannot write --out %s\n' "$out" >&2
    exit 2
  fi
fi
error_out_dir=''
if [ -n "$error_out" ]; then
  error_out_dir=$(dirname -- "$error_out")
  if [ -d "$error_out" ] || [[ "$error_out" == */ ]] || [ ! -d "$error_out_dir" ] \
      || [ ! -w "$error_out_dir" ] || [ ! -x "$error_out_dir" ]; then
    printf 'api-call: cannot write --error-out %s\n' "$error_out" >&2
    exit 2
  fi
fi
if [ -n "$out" ] && [ -n "$error_out" ]; then
  out_path="$(cd "$out_dir" && pwd -P)/$(basename -- "$out")"
  error_out_path="$(cd "$error_out_dir" && pwd -P)/$(basename -- "$error_out")"
  [ "$out_path" != "$error_out_path" ] || usage
fi

response_file=''
staging_file=''
error_published=false
request_started=false
cleanup() {
  local result=$?
  if [ "$request_started" = true ] && [ -n "$json_file" ]; then
    scratch_consume "$json_file"
  fi
  [ -z "$response_file" ] || rm -f -- "$response_file"
  [ -z "$staging_file" ] || rm -f -- "$staging_file"
  if [ "$result" -ne 0 ] && [ -n "$out" ]; then
    rm -f -- "$out"
  fi
  if [ -n "$error_out" ] && [ "$error_published" != true ]; then
    rm -f -- "$error_out"
  fi
  return "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ -n "$json_file" ] && [ ! -f "$json_file" ]; then
  printf 'api-call: JSON file does not exist: %s\n' "$json_file" >&2
  exit 2
fi

url="$target"
if [[ "$target" == /* ]]; then
  # config-get.sh refuses an address that is not plain, and says why.
  api_url=$(bash "$SCRIPT_DIR/bin/config-get.sh" api_url) || exit 2
  if [ -z "$api_url" ]; then
    echo 'api-call: api_url is not set' >&2
    exit 2
  fi
  url="${api_url%/}$target"
fi
# The retired hosted origin (October 2026 reset) never receives a credential,
# whether it came from egregore.json or an absolute target, and neither does an
# origin that is not plain. Resolve the final address before any key is
# loaded; curl runs with --globoff, so the path and query stay literal.
url="$(_hosted_api_target "$url")" || exit 2

# load_key KEY_NAME: the key from .env, edges trimmed; GITHUB_TOKEN falls
# back to `gh auth token`. Sets `loaded`; exits 2 when the key is missing.
loaded=''
load_key() {
  loaded=$(_load_env_var "$1")
  # Strip surrounding whitespace, including CRLF, without evaluating .env.
  loaded="${loaded#"${loaded%%[![:space:]]*}"}"
  loaded="${loaded%"${loaded##*[![:space:]]}"}"
  if [ "$1" = RESEND_API_KEY ]; then
    # The email skill historically removes all whitespace from Resend keys.
    loaded=$(printf '%s' "$loaded" | tr -d '[:space:]')
  elif [ "$1" = GITHUB_TOKEN ] && [ -z "$loaded" ]; then
    loaded=$(gh auth token 2>/dev/null) || loaded=''
    loaded="${loaded#"${loaded%%[![:space:]]*}"}"
    loaded="${loaded%"${loaded##*[![:space:]]}"}"
  fi
  if [ -z "$loaded" ]; then
    printf 'api-call: %s is not set in .env\n' "$1" >&2
    exit 2
  fi
}

# egregore+github: the org key names the organisation (Authorization) and the
# caller's own GitHub token proves the person (X-GitHub-Token).
token=''
person_token=''
case "$auth" in
  github) load_key GITHUB_TOKEN; token="$loaded" ;;
  egregore) load_key EGREGORE_API_KEY; token="$loaded" ;;
  resend) load_key RESEND_API_KEY; token="$loaded" ;;
  egregore+github)
    load_key EGREGORE_API_KEY; token="$loaded"
    load_key GITHUB_TOKEN; person_token="$loaded"
    ;;
esac
loaded=''

response_file=$(mktemp "$SCRIPT_DIR/tmp/api-call.XXXXXX")
args=(-q -sS --globoff --max-time 60 --request "$method" --url "$url"
  --output "$response_file" --write-out '%{http_code}' -H @-)
if [ -n "$json_file" ]; then
  args+=(--data-binary "@$json_file")
fi

headers() {
  if [ -n "$token" ]; then
    printf 'Authorization: Bearer %s\n' "$token"
  fi
  if [ -n "$person_token" ]; then
    printf 'X-GitHub-Token: %s\n' "$person_token"
  fi
  # Preserve delete-user's JSON header even on its bodyless DELETE request.
  if [ -n "$json_file" ] || [ "$method" = DELETE ]; then
    printf '%s\n' 'Content-Type: application/json'
  fi
  return 0
}

# Buffer every response; publish --out privately and atomically only on success.
# No redirects, retries, or JSON validation: the server owns those semantics.
request_started=true
transport_status=0
status=$(headers | curl "${args[@]}") || transport_status=$?
[ -z "$json_file" ] || scratch_consume "$json_file"
request_started=false
[ "$transport_status" -eq 0 ] || exit 1
case "$status" in
  2[0-9][0-9])
    if [ -n "$out" ]; then
      staging_file=$(mktemp "$out_dir/.api-call.XXXXXX")
      cat "$response_file" > "$staging_file"
      mv -f -- "$staging_file" "$out"
    else
      cat "$response_file"
    fi
    ;;
  *)
    if [ -n "$error_out" ]; then
      staging_file=$(mktemp "$error_out_dir/.api-call.XXXXXX")
      cat "$response_file" > "$staging_file"
      mv -f -- "$staging_file" "$error_out"
      error_published=true
    fi
    printf 'api-call: HTTP %s %s %s\n' "$status" "$method" "${url%%\?*}" >&2
    exit 1
    ;;
esac
