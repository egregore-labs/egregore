#!/bin/bash
# boundary.sh — Path validation utility for environment isolation
# Two modes:
#   boundary.sh check <path>         — exits 0 if path is within boundary, 1 if not
#   boundary.sh validate-repos       — validates egregore.json repos[] has no traversal
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
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Load boundary file ---
# Boundary file is written by session-start.sh at /tmp/egregore-boundary-{hash}.json
# Hash is md5 of the project directory path for uniqueness
load_boundary() {
  local hash
  hash=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
  BOUNDARY_FILE="/tmp/egregore-boundary-${hash}.json"

  if [ ! -f "$BOUNDARY_FILE" ]; then
    # No boundary file — fall back to project dir only
    PROJECT_DIR="$SCRIPT_DIR"
    MEMORY_DIR=""
    MANAGED_REPOS=""
    DENIED_PATHS=""
    return
  fi

  PROJECT_DIR=$(jq -r '.project_dir // empty' "$BOUNDARY_FILE" 2>/dev/null)
  MEMORY_DIR=$(jq -r '.memory_dir // empty' "$BOUNDARY_FILE" 2>/dev/null)
  MANAGED_REPOS=$(jq -r '.managed_repos[]? // empty' "$BOUNDARY_FILE" 2>/dev/null)
  DENIED_PATHS=$(jq -r '.denied_paths[]? // empty' "$BOUNDARY_FILE" 2>/dev/null)
}

# --- Resolve path to absolute ---
resolve_path() {
  local path="$1"
  # Expand ~ to $HOME
  path="${path/#\~/$HOME}"
  # Resolve to absolute
  if [[ "$path" != /* ]]; then
    path="$SCRIPT_DIR/$path"
  fi
  # Resolve symlinks and ../ components
  realpath "$path" 2>/dev/null || echo "$path"
}

# --- Check if path is within an allowed directory ---
path_starts_with() {
  local path="$1"
  local prefix="$2"
  [[ "$path" == "$prefix" || "$path" == "$prefix/"* ]]
}

# --- MODE: check <path> ---
check_path() {
  local target="$1"
  local resolved
  resolved=$(resolve_path "$target")

  load_boundary

  # Always-allowed system paths
  if path_starts_with "$resolved" "/tmp"; then return 0; fi
  if path_starts_with "$resolved" "$HOME/.claude"; then return 0; fi
  if path_starts_with "$resolved" "/usr"; then return 0; fi
  if path_starts_with "$resolved" "/etc"; then return 0; fi
  if path_starts_with "$resolved" "/var"; then return 0; fi
  if path_starts_with "$resolved" "/bin"; then return 0; fi
  if path_starts_with "$resolved" "/sbin"; then return 0; fi
  if path_starts_with "$resolved" "/opt"; then return 0; fi

  # Explicitly denied paths (other instances)
  for denied in $DENIED_PATHS; do
    if path_starts_with "$resolved" "$denied"; then
      echo "BLOCKED: $resolved is inside another Egregore instance ($denied)"
      return 1
    fi
  done

  # Allow instance registry (read-only, needed for multi-instance features)
  if path_starts_with "$resolved" "$HOME/.egregore"; then
    return 0
  fi

  # Allowed: project directory
  if [ -n "$PROJECT_DIR" ] && path_starts_with "$resolved" "$PROJECT_DIR"; then
    return 0
  fi

  # Allowed: memory directory (resolved symlink target)
  if [ -n "$MEMORY_DIR" ] && path_starts_with "$resolved" "$MEMORY_DIR"; then
    return 0
  fi

  # Allowed: managed repos
  for repo_path in $MANAGED_REPOS; do
    if path_starts_with "$resolved" "$repo_path"; then
      return 0
    fi
  done

  # Allowed: parent directory (for sibling repo operations like git clone)
  local parent_dir
  parent_dir="$(dirname "$PROJECT_DIR")"
  if path_starts_with "$resolved" "$parent_dir"; then
    # But NOT if it resolves into a denied path
    for denied in $DENIED_PATHS; do
      if path_starts_with "$resolved" "$denied"; then
        echo "BLOCKED: $resolved is inside another Egregore instance ($denied)"
        return 1
      fi
    done
    return 0
  fi

  # Default: block
  echo "BLOCKED: $resolved is outside the session boundary"
  return 1
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
    check_path "$2"
    ;;
  validate-repos)
    validate_repos
    ;;
  *)
    echo "Usage: boundary.sh {check <path>|validate-repos}"
    exit 1
    ;;
esac
