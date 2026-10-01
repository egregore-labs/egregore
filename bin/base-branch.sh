#!/usr/bin/env bash
set -euo pipefail
# Repository selection belongs to this script, never to inherited Git overrides.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# Print the configured integration branch, optionally resolving a comparison ref.
# Usage: bash bin/base-branch.sh [repo-name] [--resolve]
# Exit 0 = branch/ref printed, Exit 1 = invalid or unreadable configuration
# Exit 2 = invalid arguments, missing managed checkout, or unresolved ref

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/egregore.json}"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/config.sh"

repo_name=""
resolve=false
for arg in "$@"; do
  case "$arg" in
    --resolve) resolve=true ;;
    -*|*/*|*\\*|*..*) echo "Usage: bash bin/base-branch.sh [repo-name] [--resolve]" >&2; exit 2 ;;
    *)
      if [ -n "$repo_name" ] || [ -z "$arg" ]; then
        echo "Usage: bash bin/base-branch.sh [repo-name] [--resolve]" >&2
        exit 2
      fi
      repo_name="$arg"
      ;;
  esac
done

base=$(_get_base_branch "$repo_name") || exit 1
if [ -n "$repo_name" ] && ! jq -e --arg name "$repo_name" \
    'first(.repos[]? | select((if type == "object" then .name else . end) == $name)) // null' \
    "$CONFIG" >/dev/null; then
  echo "base-branch: managed repo $repo_name is not registered in egregore.json" >&2
  exit 2
fi
if ! $resolve; then
  printf '%s\n' "$base"
  exit 0
fi

repo_dir="$SCRIPT_DIR"
if [ -n "$repo_name" ]; then
  common_dir=$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir) || exit 2
  main_checkout="$(dirname "$common_dir")"
  repo_dir="$main_checkout/../$repo_name"
  if { [ ! -d "$repo_dir/.git" ] && [ ! -f "$repo_dir/.git" ]; } \
     || ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "base-branch: managed repo $repo_name not found at $repo_dir" >&2
    exit 2
  fi
fi
if git -C "$repo_dir" rev-parse --verify --quiet "origin/$base^{commit}" >/dev/null; then
  printf 'origin/%s\n' "$base"
elif git -C "$repo_dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  printf '%s\n' "$base"
else
  echo "base-branch: cannot resolve origin/$base or $base; fetch it or pass a ref explicitly" >&2
  exit 2
fi
