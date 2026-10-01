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

# --- Is a resolved path covered by a denied entry? ---
# Self-scope carve-out, per entry: an ENCLOSING denied checkout (different or
# unproven organization identity) never covers the project's own files — the
# enclosing tree stays denied while the project stays usable. A denied entry
# nested INSIDE the project is still enforced: residence under the project
# proves nothing about identity.
denied_covers() {
  local resolved="$1" denied
  local in_project=1
  if [ -n "${PROJECT_DIR:-}" ] && path_starts_with "$resolved" "$PROJECT_DIR"; then
    in_project=0
  fi
  for denied in $DENIED_PATHS; do
    if path_starts_with "$resolved" "$denied"; then
      if [ "$in_project" = "0" ] && path_starts_with "$PROJECT_DIR" "$denied"; then
        continue
      fi
      echo "$denied"
      return 0
    fi
  done
  return 1
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

  # Explicitly denied paths (other instances) — per-entry self-scope carve-out
  local covering
  if covering=$(denied_covers "$resolved"); then
    echo "BLOCKED: $resolved is inside another Egregore instance ($covering)"
    return 1
  fi

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
    # But NOT if it resolves into a denied path (denied_covers already ran
    # above and returns first, so reaching here means no covering entry)
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

# --- MODE: compute-denied <registry> <project_dir> [org_id] [allow_path] ---
# Emits the denied_paths JSON array for a session boundary: every registered
# instance not proven to share this project's identity. An entry is excluded
# only when one of these proofs holds:
#   - it IS the project (.path == project_dir)
#   - caller-proven same instance: .path == allow_path, passed only when the
#     caller holds a stronger proof (worktree-create passes the enclosing repo
#     whose git dir this worktree physically shares)
#   - registry-proven same organization: both the project's org_id and the
#     entry's org_id are present and equal
# No path relationship proves identity: not ancestry, not residence under the
# project's own .claude/worktrees (legitimate task worktrees are covered by
# matching org_id or the caller-proven allowance), and a slug is presentation,
# not identity. Entries with a different or missing org_id stay denied (fail
# closed) — the enforcement layers' self-scope carve-out keeps a nested
# project usable while its unproven enclosing tree stays denied, and a denied
# entry nested inside the project is still enforced.
compute_denied() {
  local registry="$1" project_dir="$2" org_id="${3:-}" allow_path="${4:-}"
  if [ ! -f "$registry" ]; then
    echo "[]"
    return 0
  fi
  jq --arg self "$project_dir" \
     --arg org "$org_id" \
     --arg allow "$allow_path" \
    '[.[]
      | select(.path != $self)
      | select(if $allow == "" then true else (.path != $allow) end)
      | select(if $org == "" then true else ((.org_id // "") != $org) end)
      | .path]' \
    "$registry" 2>/dev/null || echo "[]"
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
  compute-denied)
    if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
      echo "Usage: boundary.sh compute-denied <registry> <project_dir> [org_id] [allow_path]"
      exit 1
    fi
    compute_denied "$2" "$3" "${4:-}" "${5:-}"
    ;;
  *)
    echo "Usage: boundary.sh {check <path>|validate-repos|compute-denied <registry> <project_dir> [org_id] [allow_path]}"
    exit 1
    ;;
esac
