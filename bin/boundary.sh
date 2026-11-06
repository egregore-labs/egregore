#!/usr/bin/env bash
# boundary.sh — Path validation utility for environment isolation
# Modes:
#   boundary.sh check <path>         — exits 0 if path is within boundary, 1 if not
#   boundary.sh validate-repos       — validates egregore.json repos[] has no traversal
#   boundary.sh compute-denied <registry> <project_dir> [org_id] [allow_path]
#                                    — emit denied_paths JSON for a session boundary
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: boundary.sh <command> [args...]"
  echo ""
  echo "Path validation utility for environment isolation."
  echo "Ensures sessions stay within their allowed boundaries."
  echo ""
  echo "Commands:"
  echo "  check <path>      Exit 0 if path is within boundary, 1 if not"
  echo "  validate-repos    Check egregore.json repos[] for path traversal"
  echo "  compute-denied <registry> <project_dir> [org_id] [allow_path]"
  echo "                    Emit denied_paths JSON: registered instances not"
  echo "                    proven to share <project_dir>'s stable org identity"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# The isolation policy (boundary cache, instance identity, core boundary, hard
# tier) has one implementation, shared by every runtime's pre-action check:
# bin/boundary-guard.cjs. `check` and `compute-denied` delegate to it.
GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/boundary-guard.cjs"

guard() {
  if [ ! -f "$GUARD" ]; then
    echo "boundary.sh: $GUARD is missing" >&2
    return 1
  fi
  bash "$(dirname "$GUARD")/node-run.sh" "$GUARD" "$@"
}

# --- Check if path is within an allowed directory ---
path_starts_with() {
  local path="$1"
  local prefix="$2"
  [[ "$path" == "$prefix" || "$path" == "$prefix/"* ]]
}

# --- MODE: validate-repos ---
validate_repos() {
  local config="$SCRIPT_DIR/egregore.json"
  if [ ! -f "$config" ]; then
    return 0
  fi

  local repos
  repos=$(jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' "$config" 2>/dev/null)
  local parent_dir
  parent_dir="$(dirname "$SCRIPT_DIR")"
  local exit_code=0

  for repo in $repos; do
    # Check for path traversal
    if [[ "$repo" == *".."* ]]; then
      echo "WARNING: repos[] entry '$repo' contains '..', skipping"
      exit_code=1
      continue
    fi

    # Check for absolute paths
    if [[ "$repo" == /* ]]; then
      echo "WARNING: repos[] entry '$repo' is an absolute path, skipping"
      exit_code=1
      continue
    fi

    # Resolve and check it stays under parent directory
    local resolved
    resolved=$(realpath "$parent_dir/$repo" 2>/dev/null || echo "")
    if [ -n "$resolved" ] && ! path_starts_with "$resolved" "$parent_dir"; then
      echo "WARNING: repos[] entry '$repo' resolves outside parent directory, skipping"
      exit_code=1
      continue
    fi
  done

  return $exit_code
}

# --- Main ---
case "${1:-}" in
  check)
    if [ -z "${2:-}" ]; then
      echo "Usage: boundary.sh check <path>"
      exit 1
    fi
    guard check "$2" --project-dir "$SCRIPT_DIR"
    ;;
  validate-repos)
    validate_repos
    ;;
  compute-denied)
    # Every registered instance not proven to share <project_dir>'s identity
    # (computeDenied in bin/boundary-guard.cjs). Exits 1 when the registry
    # exists but cannot be read: callers fail closed, never read it as [].
    if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
      echo "Usage: boundary.sh compute-denied <registry> <project_dir> [org_id] [allow_path]"
      exit 1
    fi
    guard compute-denied "$2" "$3" "${4:-}" "${5:-}"
    ;;
  *)
    echo "Usage: boundary.sh {check <path>|validate-repos|compute-denied <registry> <project_dir> [org_id] [allow_path]}"
    exit 1
    ;;
esac
