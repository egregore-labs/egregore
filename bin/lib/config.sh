#!/usr/bin/env bash
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

# Get base branch for a repo. Reads base_branch from egregore.json — top-level
# for the core egregore repo, per-entry under repos[] for managed repos.
# Defaults to "develop" for backwards compatibility only when a valid config
# omits the setting. Missing, unreadable, malformed, or invalid config fails:
# callers must never turn a config read failure into a remote branch mutation.
#
# Setting a top-level "base_branch": "main" is single-branch mode: the whole
# develop layer disappears and everything (session start, sync, the branch
# guard, PR bases) targets main instead. Solo operators who never wanted the
# develop/main split had no way to say so — the core repo used to be hardcoded
# even though managed repos were already configurable.
#
# Usage: _get_base_branch "repo-name"   (omit for core repo)
_get_base_branch() {
  local repo_name="${1:-}"
  local config="${CONFIG:-$SCRIPT_DIR/egregore.json}"
  local base=""

  if [ ! -r "$config" ]; then
    echo "config: cannot read $config" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$config" >/dev/null 2>&1; then
    echo "config: invalid JSON object in $config" >&2
    return 1
  fi

  if [ -z "$repo_name" ]; then
    # Core egregore repo — top-level base_branch. An absent value preserves
    # the historical develop default; an explicitly invalid value is an error.
    if jq -e 'has("base_branch")' "$config" >/dev/null 2>&1; then
      if ! base=$(jq -er '.base_branch | select(type == "string")' "$config" 2>/dev/null); then
        echo "config: base_branch must be a valid branch name" >&2
        return 1
      fi
    else
      base="develop"
    fi
  else
    # Managed repo — its own entry under repos[]. Unknown/string-form entries
    # retain the historical develop default.
    local repo_json
    repo_json=$(jq -c --arg name "$repo_name" \
      'first(.repos[]? | select((if type == "object" then .name else . end) == $name)) // null' \
      "$config" 2>/dev/null) || {
        echo "config: cannot resolve managed repo $repo_name" >&2
        return 1
      }
    if [ "$repo_json" != "null" ] \
       && [ "$(printf '%s' "$repo_json" | jq -r 'type')" = "object" ] \
       && printf '%s' "$repo_json" | jq -e 'has("base_branch")' >/dev/null 2>&1; then
      if ! base=$(printf '%s' "$repo_json" | jq -er '.base_branch | select(type == "string")' 2>/dev/null); then
        echo "config: base_branch for $repo_name must be a valid branch name" >&2
        return 1
      fi
    else
      base="develop"
    fi
  fi

  if [ -z "$base" ] || ! git check-ref-format --branch "$base" >/dev/null 2>&1; then
    echo "config: base_branch must be a valid branch name" >&2
    return 1
  fi
  echo "$base"
}

# Detect local vs connected mode
_detect_mode() {
  local config="${CONFIG:-$SCRIPT_DIR/egregore.json}"
  if [ -f "$config" ] && jq -e \
    '(.mode // "") != "local" and ((.api_url // "") | length > 0)' \
    "$config" >/dev/null 2>&1; then
    echo "connected"
  else
    echo "local"
  fi
}

# Compact runtime identity shared by terminal surfaces. The sigils deliberately
# distinguish an active hosted connection from the self-contained local mode
# without implying that local Egregore is unhealthy.
_runtime_mode_badge() {
  if [ "$(_detect_mode)" = "connected" ]; then
    echo "◆ CONNECTED"
  else
    echo "◇ LOCAL"
  fi
}
