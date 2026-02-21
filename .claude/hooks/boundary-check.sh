#!/bin/bash
# boundary-check.sh — PreToolUse hook for environment isolation
# Receives tool input JSON on stdin from Claude Code.
# Exit 0 = allow, exit 2 = block (reason on stderr).
# Must be fast (<50ms) — no network calls, just path checks.

# No set -e — hook must never accidentally block by crashing
# If anything fails unexpectedly, fall through to exit 0 (allow)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# --- Load boundary file (cached at session start) ---
HASH=$(echo -n "$PROJECT_DIR" | md5 2>/dev/null || echo -n "$PROJECT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
BOUNDARY_FILE="/tmp/egregore-boundary-${HASH}.json"

if [ ! -f "$BOUNDARY_FILE" ]; then
  # No boundary computed yet (session-start hasn't run) — allow everything
  exit 0
fi

# Read boundary once
BOUNDARY_JSON=$(cat "$BOUNDARY_FILE" 2>/dev/null) || exit 0
B_PROJECT_DIR=$(echo "$BOUNDARY_JSON" | jq -r '.project_dir // empty' 2>/dev/null) || true
B_MEMORY_DIR=$(echo "$BOUNDARY_JSON" | jq -r '.memory_dir // empty' 2>/dev/null) || true

# --- Read tool input from stdin ---
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || true

if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

# --- Helper: resolve path ---
resolve_path() {
  local path="$1"
  path="${path/#\~/$HOME}"
  if [[ "$path" != /* ]]; then
    path="$PROJECT_DIR/$path"
  fi
  realpath "$path" 2>/dev/null || echo "$path"
}

# --- Helper: check if path is within allowed boundary ---
is_allowed() {
  local resolved="$1"

  # Always-allowed system paths
  case "$resolved" in
    /tmp/*|/tmp) return 0 ;;
    "$HOME/.claude"/*|"$HOME/.claude") return 0 ;;
    /usr/*|/etc/*|/var/*|/bin/*|/sbin/*|/opt/*) return 0 ;;
  esac

  # Allow reading instance registry (needed for multi-instance features)
  if [[ "$resolved" == "$HOME/.egregore"/* ]]; then
    return 0
  fi

  # Project directory
  if [ -n "${B_PROJECT_DIR:-}" ]; then
    if [[ "$resolved" == "$B_PROJECT_DIR" || "$resolved" == "$B_PROJECT_DIR/"* ]]; then
      return 0
    fi
  fi

  # Memory directory
  if [ -n "${B_MEMORY_DIR:-}" ]; then
    if [[ "$resolved" == "$B_MEMORY_DIR" || "$resolved" == "$B_MEMORY_DIR/"* ]]; then
      return 0
    fi
  fi

  # Managed repos
  local repo_paths
  repo_paths=$(echo "$BOUNDARY_JSON" | jq -r '.managed_repos[]?' 2>/dev/null) || true
  for repo_path in $repo_paths; do
    if [[ "$resolved" == "$repo_path" || "$resolved" == "$repo_path/"* ]]; then
      return 0
    fi
  done

  # Parent directory (for sibling repo operations) — but check denied paths
  local parent_dir
  parent_dir="$(dirname "${B_PROJECT_DIR:-$PROJECT_DIR}")"
  if [[ "$resolved" == "$parent_dir" || "$resolved" == "$parent_dir/"* ]]; then
    local denied_paths
    denied_paths=$(echo "$BOUNDARY_JSON" | jq -r '.denied_paths[]?' 2>/dev/null) || true
    for denied in $denied_paths; do
      if [[ "$resolved" == "$denied" || "$resolved" == "$denied/"* ]]; then
        return 1
      fi
    done
    return 0
  fi

  # Check denied paths (even outside parent)
  local denied_paths
  denied_paths=$(echo "$BOUNDARY_JSON" | jq -r '.denied_paths[]?' 2>/dev/null) || true
  for denied in $denied_paths; do
    if [[ "$resolved" == "$denied" || "$resolved" == "$denied/"* ]]; then
      return 1
    fi
  done

  # Outside all known boundaries — block
  return 1
}

# --- Check based on tool type ---
case "$TOOL_NAME" in
  Read|Edit|Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true
    if [ -z "${FILE_PATH:-}" ]; then
      exit 0
    fi

    RESOLVED=$(resolve_path "$FILE_PATH")
    if ! is_allowed "$RESOLVED"; then
      echo "Environment isolation: $RESOLVED is outside this instance's boundary. Each Egregore instance can only access its own project, memory, and managed repos." >&2
      exit 2
    fi
    ;;

  Glob|Grep)
    SEARCH_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null) || true
    if [ -z "${SEARCH_PATH:-}" ]; then
      exit 0  # No path = CWD = project dir, allowed
    fi

    RESOLVED=$(resolve_path "$SEARCH_PATH")
    if ! is_allowed "$RESOLVED"; then
      echo "Environment isolation: $RESOLVED is outside this instance's boundary." >&2
      exit 2
    fi
    ;;

  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
    if [ -z "${COMMAND:-}" ]; then
      exit 0
    fi

    # Check for denied instance paths in the command
    DENIED_PATHS=$(echo "$BOUNDARY_JSON" | jq -r '.denied_paths[]?' 2>/dev/null) || true
    for denied in ${DENIED_PATHS:-}; do
      if echo "$COMMAND" | grep -qF "$denied" 2>/dev/null; then
        echo "Environment isolation: command references another Egregore instance at $denied." >&2
        exit 2
      fi
    done
    ;;

  *)
    # Other tools (WebFetch, etc.) — allow
    exit 0
    ;;
esac

# Default: allow
exit 0
