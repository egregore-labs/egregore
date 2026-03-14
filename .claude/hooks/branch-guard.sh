#!/bin/bash
# branch-guard.sh — PreToolUse hook blocking modifications on protected branches
# Receives tool input JSON on stdin from Claude Code.
# Exit 0 = allow, exit 2 = block (reason on stderr).
# Must be fast (<50ms) — no network calls, just path/branch checks.

# No set -e — hook must never accidentally block by crashing
# If anything fails unexpectedly, fall through to exit 0 (allow)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# --- Get current branch ---
BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0

# Only guard protected branches
case "$BRANCH" in
  develop|main|master) ;;
  *) exit 0 ;;
esac

# --- Maintainer fast-path ---
# Founders/maintainers can push directly to develop (not main).
# This unblocks shipping fixes without waiting on PR reviews.
# main is always protected — use /release for that.
USAGE_TYPE=$(jq -r '.usage_type // empty' "$PROJECT_DIR/.egregore-state.json" 2>/dev/null) || true
if [[ "$USAGE_TYPE" == "founder_group" || "$USAGE_TYPE" == "founder_solo" ]] && [[ "$BRANCH" == "develop" ]]; then
  exit 0
fi

# --- Read tool input from stdin ---
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || true

if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

# --- Read author from state file ---
AUTHOR=$(jq -r '.display_name // .name // "dev"' "$PROJECT_DIR/.egregore-state.json" 2>/dev/null) || AUTHOR="dev"

# --- Resolve memory directory (for exemption checks) ---
MEMORY_DIR=$(realpath "$PROJECT_DIR/memory" 2>/dev/null || echo "$PROJECT_DIR/memory")

# --- Helper: check if path is exempt from branch guard ---
is_exempt() {
  local path="$1"

  # Resolve relative paths
  if [[ "$path" != /* ]]; then
    path="$PROJECT_DIR/$path"
  fi

  # Resolve symlinks
  local resolved
  resolved=$(realpath "$path" 2>/dev/null || echo "$path")

  # Exempt: .claude/ directory
  case "$resolved" in
    "$PROJECT_DIR/.claude"/*|"$PROJECT_DIR/.claude") return 0 ;;
  esac

  # Exempt: .egregore-state.json
  if [[ "$resolved" == "$PROJECT_DIR/.egregore-state.json" ]]; then
    return 0
  fi

  # Exempt: .env
  if [[ "$resolved" == "$PROJECT_DIR/.env" ]]; then
    return 0
  fi

  # Exempt: memory/ (resolve symlink to check both the link and target)
  if [[ "$resolved" == "$PROJECT_DIR/memory"/* || "$resolved" == "$PROJECT_DIR/memory" ]]; then
    return 0
  fi
  if [[ "$resolved" == "$MEMORY_DIR"/* || "$resolved" == "$MEMORY_DIR" ]]; then
    return 0
  fi

  # Exempt: /tmp/
  case "$resolved" in
    /tmp/*|/tmp|/private/tmp/*|/private/tmp) return 0 ;;
  esac

  return 1
}

# --- Helper: check if bash command targets a non-hub repo ---
# Returns 0 (true) if the git command operates on memory/, a managed repo,
# or any directory outside the hub project.
# Strategy: extract paths from cd/git-C, resolve them, check if they're
# outside PROJECT_DIR. If so, it's a different repo — allow it.
targets_other_repo() {
  local cmd="$1"

  # Extract directory targets from common patterns:
  #   cd <path>          →  path
  #   git -C <path>      →  path
  #   git -C "<path>"    →  path
  local paths=""

  # cd targets (handles: cd path, cd "path", cd 'path')
  paths="$paths $(echo "$cmd" | grep -oE 'cd\s+["'"'"']?[^ ;&|"'"'"']+' 2>/dev/null | sed 's/^cd\s*["'"'"']*//g')"

  # git -C targets
  paths="$paths $(echo "$cmd" | grep -oE 'git\s+-C\s+["'"'"']?[^ ;&|"'"'"']+' 2>/dev/null | sed 's/^git\s*-C\s*["'"'"']*//g')"

  for p in $paths; do
    # Skip empty
    [ -z "$p" ] && continue

    # Resolve relative paths from PROJECT_DIR
    if [[ "$p" != /* ]]; then
      p="$PROJECT_DIR/$p"
    fi

    # Resolve symlinks
    local resolved
    resolved=$(realpath "$p" 2>/dev/null || echo "$p")

    # If it resolves to memory dir — allow
    if [[ "$resolved" == "$MEMORY_DIR" || "$resolved" == "$MEMORY_DIR/"* ]]; then
      return 0
    fi

    # If it's outside the project dir entirely — it's a different repo, allow
    if [[ "$resolved" != "$PROJECT_DIR" && "$resolved" != "$PROJECT_DIR/"* ]]; then
      return 0
    fi
  done

  return 1
}

# --- Block message (short — Claude knows what to do from CLAUDE.md) ---
BLOCK_MSG="Protected branch: create a working branch first. Run: git fetch origin develop --quiet && git checkout -b dev/${AUTHOR}/{topic-slug} origin/develop"

# --- Check based on tool type ---
case "$TOOL_NAME" in
  Edit|Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true
    if [ -z "${FILE_PATH:-}" ]; then
      exit 0
    fi

    if ! is_exempt "$FILE_PATH"; then
      echo "$BLOCK_MSG" >&2
      exit 2
    fi
    ;;

  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
    if [ -z "${COMMAND:-}" ]; then
      exit 0
    fi

    # Allow branch cleanup (git push --delete) — not pushing to current branch
    if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--delete' 2>/dev/null; then
      exit 0
    fi

    # Only check commands that contain git commit or git push
    if echo "$COMMAND" | grep -qE 'git\s+(commit|push)' 2>/dev/null; then
      # Allow if targeting memory/ or a managed repo (separate repos, own branch model)
      if targets_other_repo "$COMMAND"; then
        exit 0
      fi
      echo "$BLOCK_MSG" >&2
      exit 2
    fi
    ;;

  *)
    exit 0
    ;;
esac

# Default: allow
exit 0
