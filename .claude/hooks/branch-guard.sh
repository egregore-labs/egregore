#!/usr/bin/env bash
# branch-guard.sh — PreToolUse hook blocking modifications on protected branches
# Receives tool input JSON on stdin from Claude Code.
# Exit 0 = allow, exit 2 = block (reason on stderr).
# Must be fast (<50ms) — no network calls, just path/branch checks.

# No set -e — hook must never accidentally block by crashing
# If anything fails unexpectedly, fall through to exit 0 (allow)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# --- Guard: if project dir no longer exists (worktree deleted), allow gracefully ---
if [ ! -d "$PROJECT_DIR" ]; then
  exit 0
fi

# --- Get current branch ---
# In a worktree, CWD is the worktree — git without -C returns the correct branch.
# Fallback to -C PROJECT_DIR for non-worktree contexts.
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || \
  BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0

# Resolve the configured integration branch before deciding whether the current
# branch is protected. Single-branch instances may use main; custom instances
# may use another name such as trunk.
BASE_BRANCH=$(jq -r 'if (.base_branch | type) == "string" then .base_branch else "develop" end' "$PROJECT_DIR/egregore.json" 2>/dev/null) || BASE_BRANCH="develop"
if [ -z "$BASE_BRANCH" ] || ! git check-ref-format --branch "$BASE_BRANCH" >/dev/null 2>&1; then
  BASE_BRANCH="develop"
fi

# Guard the conventional protected branches plus the configured base branch.
case "$BRANCH" in
  develop|main|master|"$BASE_BRANCH") ;;
  *) exit 0 ;;
esac

# --- Consent bypass: the user explicitly chose to work on this protected branch ---
# Set by the agent (per CLAUDE.md branch-guard protocol) only after the user
# picks "Proceed on <branch>" in an AskUserQuestion. Scoped to the branch name
# and cleared on session start, so consent is asked once per session, not per write.
CONSENT_FILE="$PROJECT_DIR/.egregore-branch-consent"
if [ -f "$CONSENT_FILE" ] && [ "$(cat "$CONSENT_FILE" 2>/dev/null)" = "$BRANCH" ]; then
  exit 0
fi

# --- Read tool input from stdin (before fast-path so we can check tool) ---
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

  # Exempt: paths outside the hub project (managed repos are sibling dirs
  # with their own branch state — the hub's develop guard doesn't apply).
  if [[ "$resolved" != "$PROJECT_DIR" && "$resolved" != "$PROJECT_DIR/"* ]]; then
    return 0
  fi

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

# --- Block message — keep routine branch mechanics out of the user's way ---
BLOCK_MSG="Protected branch (${BRANCH}). Move project work to a task branch before writing.

If the work topic is clear, create the branch automatically:
  git fetch origin ${BASE_BRANCH} --quiet && git checkout -b dev/${AUTHOR}/{topic-slug} origin/${BASE_BRANCH}
Then continue there and briefly tell the user. Do not ask for routine Git permission.

AskUserQuestion only when the work topic is genuinely ambiguous; ask for the topic, not whether branching is allowed.

Only when the user explicitly requested writing on ${BRANCH}, record consent and retry:
  echo '${BRANCH}' > .egregore-branch-consent

Memory, managed-repo, and runtime-state writes should bypass this project guard."

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
      # Allow framework updates from upstream (not user work — safe on develop)
      if echo "$COMMAND" | grep -qF 'EGREGORE_FRAMEWORK_UPDATE=1' 2>/dev/null; then
        exit 0
      fi
      # Allow commits that only touch framework paths (bin/, .claude/, CLAUDE.md, skills/)
      if echo "$COMMAND" | grep -qE 'git\s+commit' 2>/dev/null; then
        _NON_FW=$(git -C "$PROJECT_DIR" diff --cached --name-only 2>/dev/null | grep -vE '^(bin/|\.claude/|CLAUDE\.md$|skills/)' | head -1)
        if [ -z "$_NON_FW" ]; then
          # All staged files are framework paths — allow
          exit 0
        fi
      fi
      echo "$BLOCK_MSG" >&2
      exit 2
    fi
    ;;

  EnterPlanMode)
    # Plan mode doesn't write anything — allow on protected branches.
    # The actual Edit/Write/Bash that follows will still trigger branching.
    exit 0
    ;;

  *)
    exit 0
    ;;
esac

# Default: allow
exit 0
