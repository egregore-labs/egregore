#!/usr/bin/env bash
set -euo pipefail
# Repository selection belongs to this script, never to inherited Git overrides.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# Print one configuration value for skill instructions to name and reuse.
# Present-but-empty and non-string values are unset; repo_name defaults to
# egregore. The composed repo requires a nonempty string github_org.
# Exit 0 = value printed (or unset), Exit 1 = invalid/unreadable configuration
# Exit 2 = invalid arguments
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/egregore.json}"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/config.sh"

usage() {
  echo "Usage: bash bin/config-get.sh <key>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
case "$1" in
  mode|api_url|github_org|org_name|slug|memory_repo|upstream_url|repo_name|repo|memory_dir|repos) ;;
  *) usage ;;
esac

if [ ! -r "$CONFIG" ]; then
  echo "config: cannot read $CONFIG" >&2
  exit 1
fi
if ! jq -se 'length == 1 and (.[0] | type == "object")' "$CONFIG" >/dev/null 2>&1; then
  echo "config: invalid JSON object in $CONFIG" >&2
  exit 1
fi

case "$1" in
  mode) _detect_mode ;;
  api_url|github_org|org_name|slug|memory_repo|upstream_url)
    value=$(jq -r --arg key "$1" '.[$key] | select(type == "string" and length > 0)' "$CONFIG")
    if [ -n "$value" ]; then printf '%s\n' "$value"; fi
    ;;
  repo_name)
    value=$(jq -r '.repo_name | select(type == "string" and length > 0)' "$CONFIG")
    printf '%s\n' "${value:-egregore}"
    ;;
  repo)
    github_org=$(jq -r '.github_org | select(type == "string" and length > 0)' "$CONFIG")
    if [ -z "$github_org" ]; then
      printf '%s\n' 'config: github_org is not set' >&2
      exit 1
    fi
    repo_name=$(jq -r '.repo_name | select(type == "string" and length > 0)' "$CONFIG")
    printf '%s/%s\n' "$github_org" "${repo_name:-egregore}"
    ;;
  memory_dir)
    value=$(jq -r '.memory_repo | select(type == "string" and length > 0)' "$CONFIG")
    if [ -n "$value" ]; then
      value=$(basename "$value")
      printf '%s\n' "${value%.git}"
    fi
    ;;
  repos)
    jq -r '.repos[]? | if type == "object" then .name else . end | select(type == "string")' "$CONFIG"
    ;;
esac
