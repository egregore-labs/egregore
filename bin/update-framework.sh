#!/usr/bin/env bash
set -euo pipefail
# Repository selection belongs to the caller, never to inherited Git overrides.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# Apply the shared framework path overlay only in the given checkout (cwd by
# default). Never discover another worktree, switch branches, or fetch here.
# Exit 0 = overlay completed, including reported per-path skips
# Exit 1 = checkout/upstream unavailable; Exit 2 = invalid arguments
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/lib/framework-update.sh
source "$SCRIPT_DIR/bin/lib/framework-update.sh"

usage() {
  printf '%s\n' 'Usage: bash bin/update-framework.sh [--main-dir <path>]' >&2
  exit 2
}

target_dir=.
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = "--main-dir" ] && [ -n "$2" ] || usage
  target_dir="$2"
fi
_checkout_framework_paths "$target_dir"
