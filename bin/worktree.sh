#!/usr/bin/env bash
# Worktree lifecycle management for Egregore sessions.
# Each session gets an isolated worktree so parallel sessions don't conflict.
#
# Usage:
#   bash bin/worktree.sh setup <worktree-path> <main-project-dir>
#   bash bin/worktree.sh cleanup <worktree-path>
#   bash bin/worktree.sh cleanup-stale <main-project-dir>
#   bash bin/worktree.sh health [path]
#   bash bin/worktree.sh list

set -o pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: worktree.sh <command> [args...]"
  echo ""
  echo "Worktree lifecycle management for Egregore sessions."
  echo ""
  echo "Commands:"
  echo "  setup <path> <main-dir>         Set up symlinks for a new worktree"
  echo "  cleanup <path>                  Remove a worktree"
  echo "  cleanup-stale <main-dir>        List stale worktrees (manual review)"
  echo "  health [path]                   Check worktree + branch health"
  echo "  list                            List all git worktrees"
  exit 0
fi

CMD="${1:-}"
shift 2>/dev/null || true

case "$CMD" in

  setup)
    # Setup symlinks so worktree shares state with main project.
    # Args: <worktree-path> <main-project-dir>
    WT_PATH="${1:?Usage: worktree.sh setup <worktree-path> <main-project-dir>}"
    MAIN_DIR="${2:?Usage: worktree.sh setup <worktree-path> <main-project-dir>}"

    # Symlink shared files from main project
    for FILE in memory .env .egregore-state.json .egregore-session-id; do
      SRC="$MAIN_DIR/$FILE"
      DST="$WT_PATH/$FILE"
      if [ "$FILE" = "memory" ]; then
        # memory may be a symlink (follow to its target) or a real directory.
        if [ -L "$SRC" ]; then
          SRC=$(realpath "$SRC" 2>/dev/null) || continue
        fi
        [ -d "$SRC" ] || continue
      else
        [ -f "$SRC" ] || continue
      fi
      ln -sfn "$SRC" "$DST"
    done

    # Symlink egregore.json if not already present (committed file)
    if [ -f "$MAIN_DIR/egregore.json" ] && [ ! -f "$WT_PATH/egregore.json" ]; then
      ln -sfn "$MAIN_DIR/egregore.json" "$WT_PATH/egregore.json"
    fi

    # Find terminal TTY for statusline matching
    _pid=$$
    _tty=""
    while [ "$_pid" -gt 1 ] 2>/dev/null; do
      _ptty=$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')
      if [ -n "$_ptty" ] && [ "$_ptty" != "??" ]; then
        _tty="$_ptty"
        break
      fi
      _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    done
    [ -n "$_tty" ] && echo "$_tty" > "$WT_PATH/.egregore-worktree-tty"

    echo "Worktree setup complete: $WT_PATH"
    ;;

  cleanup)
    # Remove a worktree. Only called explicitly (ExitWorktree or manual).
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

    git worktree remove "$WT_PATH" --force 2>/dev/null || true
    git worktree prune 2>/dev/null || true

    echo "Worktree cleaned up: $WT_PATH"
    ;;

  cleanup-stale)
    # List stale worktrees for manual review. Does NOT auto-delete.
    # Run interactively or from a cleanup command — never from session-start.
    # Args: <main-project-dir>
    MAIN_DIR="${1:?Usage: worktree.sh cleanup-stale <main-project-dir>}"
    WT_BASE="$MAIN_DIR/.claude/worktrees"

    if [ ! -d "$WT_BASE" ]; then
      echo "No worktrees directory."
      exit 0
    fi

    NOW_TS=$(date +%s)
    FOUND=0

    for WT_DIR in "$WT_BASE"/*/; do
      [ -d "$WT_DIR" ] || continue

      WT_NAME=$(basename "$WT_DIR")
      WT_BRANCH=""
      STATUS="unknown"

      if [ -f "$WT_DIR/.git" ]; then
        WT_BRANCH=$(git -C "$WT_DIR" branch --show-current 2>/dev/null || echo "?")

        # Check if merged
        if [ "$WT_BRANCH" != "?" ] && [ "$WT_BRANCH" != "develop" ] && [ "$WT_BRANCH" != "main" ]; then
          if git merge-base --is-ancestor "$(git -C "$WT_DIR" rev-parse HEAD 2>/dev/null)" \
               "$(git -C "$MAIN_DIR" rev-parse origin/develop 2>/dev/null)" 2>/dev/null; then
            STATUS="merged"
          else
            STATUS="active"
          fi
        fi
      else
        STATUS="broken"
      fi

      # Age
      WT_MTIME=$(stat -f %m "$WT_DIR" 2>/dev/null || stat -c %Y "$WT_DIR" 2>/dev/null || echo "$NOW_TS")
      WT_AGE_H=$(( (NOW_TS - WT_MTIME) / 3600 ))

      if [ "$STATUS" = "merged" ] || [ "$STATUS" = "broken" ] || [ "$WT_AGE_H" -gt 24 ]; then
        echo "  $WT_NAME  [$STATUS]  ${WT_AGE_H}h old  branch: ${WT_BRANCH:-none}"
        FOUND=$((FOUND + 1))
      fi
    done

    if [ "$FOUND" -eq 0 ]; then
      echo "No stale worktrees found."
    else
      echo ""
      echo "To remove: bash bin/worktree.sh cleanup <path>"
    fi

    # Prune git's internal worktree list
    git -C "$MAIN_DIR" worktree prune 2>/dev/null || true
    ;;

  health)
    # Check worktree + branch health
    # Exit codes: 0=healthy, 1=not_worktree, 2=branch_gone, 3=protected_branch
    WT_PATH="${1:-$(pwd)}"

    if [ ! -f "$WT_PATH/.git" ]; then
      echo '{"status":"not_worktree"}'
      exit 1
    fi

    BRANCH=$(git -C "$WT_PATH" branch --show-current 2>/dev/null || echo "")

    case "$BRANCH" in
      develop|main|master)
        jq -n --arg branch "$BRANCH" '{status: "protected_branch", branch: $branch}'
        exit 3
        ;;
    esac

    # Check if remote branch still exists
    git -C "$WT_PATH" fetch origin --prune --quiet 2>/dev/null || true
    if ! git -C "$WT_PATH" ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q "$BRANCH"; then
      if git -C "$WT_PATH" branch -r --merged origin/develop 2>/dev/null | grep -q "origin/$BRANCH" 2>/dev/null; then
        jq -n --arg branch "$BRANCH" '{status: "merged", branch: $branch}'
      else
        jq -n --arg branch "$BRANCH" '{status: "remote_deleted", branch: $branch}'
      fi
      exit 2
    fi

    jq -n --arg branch "$BRANCH" '{status: "healthy", branch: $branch}'
    exit 0
    ;;

  list)
    git worktree list
    ;;

  *)
    echo "Usage: worktree.sh {setup|cleanup|cleanup-stale|health|list}" >&2
    exit 1
    ;;
esac
