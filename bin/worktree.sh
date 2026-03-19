#!/bin/bash
# Worktree lifecycle management for Egregore sessions.
# Each session gets an isolated worktree so parallel sessions don't conflict.
#
# Usage:
#   bash bin/worktree.sh setup <worktree-path> <main-project-dir>
#   bash bin/worktree.sh cleanup <worktree-path>
#   bash bin/worktree.sh cleanup-orphans <main-project-dir>
#   bash bin/worktree.sh list

set -o pipefail

CMD="${1:-}"
shift 2>/dev/null || true

case "$CMD" in

  setup)
    # Setup symlinks so worktree shares state with main project
    # Args: <worktree-path> <main-project-dir>
    WT_PATH="${1:?Usage: worktree.sh setup <worktree-path> <main-project-dir>}"
    MAIN_DIR="${2:?Usage: worktree.sh setup <worktree-path> <main-project-dir>}"

    # Resolve main project's memory symlink target (absolute path)
    if [ -L "$MAIN_DIR/memory" ]; then
      MEMORY_TARGET=$(realpath "$MAIN_DIR/memory" 2>/dev/null)
      if [ -n "$MEMORY_TARGET" ] && [ -d "$MEMORY_TARGET" ]; then
        ln -sfn "$MEMORY_TARGET" "$WT_PATH/memory"
      fi
    fi

    # Symlink .env
    if [ -f "$MAIN_DIR/.env" ]; then
      ln -sfn "$MAIN_DIR/.env" "$WT_PATH/.env"
    fi

    # Symlink .egregore-state.json
    if [ -f "$MAIN_DIR/.egregore-state.json" ]; then
      ln -sfn "$MAIN_DIR/.egregore-state.json" "$WT_PATH/.egregore-state.json"
    fi

    # Symlink .egregore-session-id
    if [ -f "$MAIN_DIR/.egregore-session-id" ]; then
      ln -sfn "$MAIN_DIR/.egregore-session-id" "$WT_PATH/.egregore-session-id"
    fi

    # Symlink egregore.json (needed by bin/ scripts)
    if [ -f "$MAIN_DIR/egregore.json" ] && [ ! -f "$WT_PATH/egregore.json" ]; then
      ln -sfn "$MAIN_DIR/egregore.json" "$WT_PATH/egregore.json"
    fi

    # Walk up process tree to find:
    #   1. Claude Code PID (long-lived) for orphan detection
    #   2. Terminal TTY (unique per tab) for statusline matching
    #
    # BUG FIX: $$ is this script's PID — dies immediately when setup
    # finishes. cleanup-orphans then sees it as dead and deletes the
    # worktree from under a live session. We need the Claude Code
    # process PID (node), which lives as long as the session does.
    _pid=$$
    _cc_pid=""
    _tty=""
    while [ "$_pid" -gt 1 ] 2>/dev/null; do
      # Check if this ancestor is Claude Code (node process)
      if [ -z "$_cc_pid" ]; then
        _cmd=$(ps -o comm= -p "$_pid" 2>/dev/null | tr -d ' ')
        case "$_cmd" in
          node|claude) _cc_pid="$_pid" ;;
        esac
      fi
      # Find first ancestor with a real TTY
      if [ -z "$_tty" ]; then
        _ptty=$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')
        if [ -n "$_ptty" ] && [ "$_ptty" != "??" ]; then
          _tty="$_ptty"
        fi
      fi
      # Stop if we have both
      [ -n "$_cc_pid" ] && [ -n "$_tty" ] && break
      _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    done

    # Write PID marker for orphan detection (Claude Code PID, not script PID)
    echo "${_cc_pid:-$$}" > "$WT_PATH/.egregore-worktree-pid"

    # Write TTY marker so statusline can match session → worktree
    [ -n "$_tty" ] && echo "$_tty" > "$WT_PATH/.egregore-worktree-tty"

    echo "Worktree setup complete: $WT_PATH"
    ;;

  cleanup)
    # Remove a worktree
    # Args: <worktree-path>
    WT_PATH="${1:?Usage: worktree.sh cleanup <worktree-path>}"

    # Remove from instance registry if accidentally registered
    REGISTRY="$HOME/.egregore/instances.json"
    if [ -f "$REGISTRY" ]; then
      RESOLVED_WT=$(realpath "$WT_PATH" 2>/dev/null || echo "$WT_PATH")
      UPDATED=$(jq --arg p "$RESOLVED_WT" '[.[] | select(.path != $p)]' "$REGISTRY" 2>/dev/null)
      if [ -n "$UPDATED" ]; then
        echo "$UPDATED" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
      fi
    fi

    # Remove the worktree
    git worktree remove "$WT_PATH" --force 2>/dev/null || true
    git worktree prune 2>/dev/null || true

    echo "Worktree cleaned up: $WT_PATH"
    ;;

  cleanup-orphans)
    # Find and clean worktrees with dead PIDs — CONSERVATIVE.
    # Only deletes worktrees that are:
    #   1. Older than 1 hour (prevents race with newly-created worktrees)
    #   2. Have a dead stored PID
    #   3. Have no active claude/node process with CWD inside the worktree
    # Args: <main-project-dir>
    MAIN_DIR="${1:?Usage: worktree.sh cleanup-orphans <main-project-dir>}"
    WT_BASE="$MAIN_DIR/.claude/worktrees"

    if [ ! -d "$WT_BASE" ]; then
      exit 0
    fi

    # Lock: prevent concurrent cleanup runs (race between parallel sessions)
    LOCK_FILE="/tmp/egregore-cleanup-$(echo -n "$MAIN_DIR" | md5 2>/dev/null || echo -n "$MAIN_DIR" | md5sum 2>/dev/null | cut -d' ' -f1).lock"
    if [ -f "$LOCK_FILE" ]; then
      # Check if lock is stale (>10 min old)
      LOCK_AGE=0
      LOCK_MTIME=$(stat -f %m "$LOCK_FILE" 2>/dev/null || stat -c %Y "$LOCK_FILE" 2>/dev/null || echo "0")
      NOW_TS=$(date +%s)
      LOCK_AGE=$((NOW_TS - LOCK_MTIME))
      if [ "$LOCK_AGE" -lt 600 ] 2>/dev/null; then
        exit 0  # Another cleanup is running
      fi
    fi
    echo $$ > "$LOCK_FILE" 2>/dev/null || true
    trap 'rm -f "$LOCK_FILE" 2>/dev/null' EXIT

    # Helper: check if any claude/node process has CWD inside a directory
    has_active_session() {
      local dir="$1"
      # macOS: use lsof to find processes with CWD in this dir
      # Linux: check /proc/*/cwd
      if command -v lsof &>/dev/null; then
        lsof +d "$dir" 2>/dev/null | grep -qE 'node|claude' && return 0
      fi
      # Fallback: check if any node/claude process lists this dir in its environment
      for pid in $(pgrep -x "node\|claude" 2>/dev/null); do
        local cwd
        cwd=$(lsof -p "$pid" -Fn 2>/dev/null | grep '^n.*'"$dir" | head -1) || true
        if [ -n "$cwd" ]; then
          return 0
        fi
      done
      return 1
    }

    NOW_TS=$(date +%s)
    MIN_AGE=3600  # 1 hour

    CLEANED=0
    for WT_DIR in "$WT_BASE"/*/; do
      [ -d "$WT_DIR" ] || continue

      # Safety: skip worktrees younger than MIN_AGE
      WT_MTIME=$(stat -f %m "$WT_DIR" 2>/dev/null || stat -c %Y "$WT_DIR" 2>/dev/null || echo "$NOW_TS")
      WT_AGE=$((NOW_TS - WT_MTIME))
      if [ "$WT_AGE" -lt "$MIN_AGE" ] 2>/dev/null; then
        continue
      fi

      PID_FILE="$WT_DIR/.egregore-worktree-pid"

      if [ -f "$PID_FILE" ]; then
        STORED_PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$STORED_PID" ] && kill -0 "$STORED_PID" 2>/dev/null; then
          continue  # PID alive — skip
        fi
        # PID is dead — but double-check no active session has CWD here
        if has_active_session "$WT_DIR"; then
          continue  # Active session detected — skip
        fi
        # Safe to clean
        bash "$0" cleanup "$WT_DIR" 2>/dev/null || true
        CLEANED=$((CLEANED + 1))
      else
        # No PID file — only clean if truly stale (no .git file AND old)
        if [ ! -f "$WT_DIR/.git" ]; then
          rm -rf "$WT_DIR" 2>/dev/null || true
          CLEANED=$((CLEANED + 1))
        fi
      fi
    done

    # Also clean stale entries from instance registry
    REGISTRY="$HOME/.egregore/instances.json"
    if [ -f "$REGISTRY" ]; then
      jq --arg prefix "$WT_BASE" \
        '[.[] | select((.path | startswith($prefix)) | not)]' \
        "$REGISTRY" > "$REGISTRY.tmp" 2>/dev/null && mv "$REGISTRY.tmp" "$REGISTRY"
    fi

    # Prune git's worktree list
    git -C "$MAIN_DIR" worktree prune 2>/dev/null || true

    if [ "$CLEANED" -gt 0 ]; then
      echo "Cleaned $CLEANED orphaned worktree(s)"
    fi
    ;;

  health)
    # Check worktree + branch health
    # Args: [worktree-path-or-cwd]
    # Exit codes: 0=healthy, 1=not_worktree, 2=branch_gone, 3=protected_branch
    WT_PATH="${1:-$(pwd)}"

    # Not a worktree?
    if [ ! -f "$WT_PATH/.git" ]; then
      echo '{"status":"not_worktree"}'
      exit 1
    fi

    BRANCH=$(git -C "$WT_PATH" branch --show-current 2>/dev/null || echo "")

    # On a protected branch?
    case "$BRANCH" in
      develop|main|master)
        echo "{\"status\":\"protected_branch\",\"branch\":\"$BRANCH\"}"
        exit 3
        ;;
    esac

    # Check if remote branch still exists
    git -C "$WT_PATH" fetch origin --prune --quiet 2>/dev/null || true
    if ! git -C "$WT_PATH" ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q "$BRANCH"; then
      # Was it merged into develop?
      if git -C "$WT_PATH" branch -r --merged origin/develop 2>/dev/null | grep -q "origin/$BRANCH" 2>/dev/null; then
        echo "{\"status\":\"merged\",\"branch\":\"$BRANCH\"}"
      else
        echo "{\"status\":\"remote_deleted\",\"branch\":\"$BRANCH\"}"
      fi
      exit 2
    fi

    echo "{\"status\":\"healthy\",\"branch\":\"$BRANCH\"}"
    exit 0
    ;;

  list)
    git worktree list
    ;;

  *)
    echo "Usage: worktree.sh {setup|cleanup|cleanup-orphans|health|list}" >&2
    exit 1
    ;;
esac
