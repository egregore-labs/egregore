#!/bin/bash
# Shared config helpers — sourced by session-start.sh and other scripts.
# Expects SCRIPT_DIR to be set by the caller.

# Load specific variables from .env (safe extraction, no code execution)
_load_env_var() {
  local var_name="$1"
  local env_file="${ENV_FILE:-$SCRIPT_DIR/.env}"
  if [ -f "$env_file" ]; then
    grep "^${var_name}=" "$env_file" 2>/dev/null | cut -d'=' -f2- || true
  fi
}

# Read a value from egregore.json
_config_val() {
  local key="$1"
  local default="${2:-}"
  local config="${CONFIG:-$SCRIPT_DIR/egregore.json}"
  if [ -f "$config" ]; then
    local val
    val=$(jq -r ".${key} // empty" "$config" 2>/dev/null || true)
    echo "${val:-$default}"
  else
    echo "$default"
  fi
}

# Get base branch for a repo. Reads base_branch from egregore.json repos[] config.
# Defaults to "develop" for backwards compatibility (existing egregores use develop).
# Only returns something other than "develop" when base_branch is explicitly set
# (e.g., for teams who added existing repos with a different default branch).
# Usage: _get_base_branch "repo-name"   (omit for core repo)
_get_base_branch() {
  local repo_name="${1:-}"
  local config="${CONFIG:-$SCRIPT_DIR/egregore.json}"

  # Core egregore repo — always develop
  if [ -z "$repo_name" ]; then
    echo "develop"
    return
  fi

  # Managed repo — check egregore.json for explicit base_branch
  if [ -f "$config" ]; then
    local base
    base=$(jq -r --arg name "$repo_name" \
      '(.repos[]? // empty) | select((if type == "object" then .name else . end) == $name) | if type == "object" then .base_branch // empty else empty end' \
      "$config" 2>/dev/null || true)
    if [ -n "$base" ]; then
      echo "$base"
      return
    fi
  fi

  # No explicit config — default to develop (backwards compatible)
  echo "develop"
}

# Detect local vs connected mode
_detect_mode() {
  local config="${CONFIG:-$SCRIPT_DIR/egregore.json}"
  local mode
  mode=$(jq -r '.mode // empty' "$config" 2>/dev/null || true)
  local api_url
  api_url=$(jq -r '.api_url // empty' "$config" 2>/dev/null || true)
  if [ "$mode" = "local" ] || [ -z "$api_url" ]; then
    echo "local"
  else
    echo "connected"
  fi
}
