#!/usr/bin/env bash
# PostToolUse observation hook — fires after Edit, Write, Bash, NotebookEdit.
# Appends one JSONL line per invocation to a per-session buffer file.
# No jq, no network, always exit 0. Observe layer — never blocks.

# No set -e — must never accidentally block by crashing
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# --- Guard: if project dir no longer exists (worktree deleted), exit silently ---
if [ ! -d "$PROJECT_DIR" ]; then
  exit 0
fi

# --- Read session ID (written by session-start.sh) ---
SESSION_ID=""
SID_FILE="$PROJECT_DIR/.egregore-session-id"
if [ -f "$SID_FILE" ]; then
  SESSION_ID=$(cat "$SID_FILE" 2>/dev/null) || true
fi
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

BUFFER="/tmp/egregore-obs-${SESSION_ID}.jsonl"

# --- Buffer guard: cap at 500KB ---
if [ -f "$BUFFER" ]; then
  SIZE=$(wc -c < "$BUFFER" 2>/dev/null | tr -d ' ')
  if [ "${SIZE:-0}" -gt 512000 ] 2>/dev/null; then
    exit 0
  fi
fi

# --- Read tool input from stdin ---
INPUT=$(cat 2>/dev/null) || exit 0

# Extract tool_name using grep/sed (no jq — saves ~15ms per invocation)
TOOL=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/')
if [ -z "$TOOL" ]; then
  exit 0
fi

# --- Extract file path based on tool type ---
PATH_VALUE=""
case "$TOOL" in
  Edit|Write)
    PATH_VALUE=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/')
    ;;
  NotebookEdit)
    PATH_VALUE=$(echo "$INPUT" | grep -o '"notebook_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/')
    ;;
  Bash)
    # Best-effort: extract first path-like token from command
    CMD=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/')
    PATH_VALUE=$(echo "$CMD" | grep -oE '(/[a-zA-Z0-9_./-]+|[a-zA-Z0-9_./-]+\.[a-zA-Z]{1,10})' | head -1)
    ;;
esac

# Strip project directory prefix for relative paths
if [ -n "$PATH_VALUE" ] && [ -n "$PROJECT_DIR" ]; then
  PATH_VALUE="${PATH_VALUE#$PROJECT_DIR/}"
fi

if [ -z "$PATH_VALUE" ]; then
  PATH_VALUE="unknown"
fi

# --- Timestamp ---
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Append JSONL line (O(1) local write) ---
echo "{\"ts\":\"$TS\",\"tool\":\"$TOOL\",\"path\":\"$PATH_VALUE\"}" >> "$BUFFER" 2>/dev/null

# --- Advisory drift check (Edit/Write only) ---
# If the file we just edited also changed on develop, surface a warning.
# Uses local refs only (no fetch here). Background fetch staleness ≤5min
# is handled by the fetch guard below.
DRIFT_MSG=""
if [ "$TOOL" = "Edit" ] || [ "$TOOL" = "Write" ]; then
  if [ -n "$PATH_VALUE" ] && [ "$PATH_VALUE" != "unknown" ]; then
    REPO_DIR="$(pwd)"

    # Staleness guard: background-fetch develop if FETCH_HEAD is >5 min old
    FETCH_HEAD="$REPO_DIR/.git/FETCH_HEAD"
    # In worktrees .git is a file, resolve to actual git dir
    if [ -f "$REPO_DIR/.git" ] && [ ! -d "$REPO_DIR/.git" ]; then
      GIT_DIR=$(git -C "$REPO_DIR" rev-parse --git-dir 2>/dev/null)
      FETCH_HEAD="${GIT_DIR:+$GIT_DIR/FETCH_HEAD}"
    fi
    LAST_FETCH=0
    if [ -f "$FETCH_HEAD" ]; then
      LAST_FETCH=$(stat -f %m "$FETCH_HEAD" 2>/dev/null || stat -c %Y "$FETCH_HEAD" 2>/dev/null || echo 0)
    fi
    NOW=$(date +%s)
    if (( NOW - LAST_FETCH > 300 )) 2>/dev/null; then
      git -C "$REPO_DIR" fetch origin develop --quiet 2>/dev/null &
    fi

    # Check if this file has changes on develop that our branch doesn't have.
    # merge-base diff: files changed on develop since we branched off.
    if git -C "$REPO_DIR" diff "$(git -C "$REPO_DIR" merge-base HEAD origin/develop 2>/dev/null)"..origin/develop --name-only 2>/dev/null | grep -qF "$PATH_VALUE"; then
      DRIFT_MSG="⚠ $PATH_VALUE also changed on develop — consider running /save soon to rebase"
    fi
  fi
fi

# Return JSON with optional systemMessage for drift warning
if [ -n "$DRIFT_MSG" ]; then
  printf '{"continue":true,"systemMessage":"%s"}\n' "$DRIFT_MSG"
fi

exit 0
