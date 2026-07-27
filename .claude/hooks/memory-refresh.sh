#!/usr/bin/env bash
# memory-refresh.sh — UserPromptSubmit hook that keeps the shared memory repo
# fresh during long-lived sessions.
#
# Why: memory is a git repo shared across the team. session-start pulls it once
# at boot; after that, teammates' handoffs, notes, and knowledge won't surface
# until the user runs /pull, /activity, or restarts the session. This hook
# keeps memory fresh opportunistically so "let's see the handoff from oskar"
# works without an explicit /pull.
#
# Design:
#   - Throttled to at most one fetch every 5 minutes (FETCH_HEAD mtime check)
#   - Runs fetch+pull in background — never blocks the user's prompt
#   - Fast-forward only — never rebases or merges the memory repo
#   - Silent — no output unless debugging
#   - Must always exit 0 (this is an observe-style hook, not a gate)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Guard: project gone (worktree deleted) → nothing to do
[ ! -d "$PROJECT_DIR" ] && exit 0

MEMORY_LINK="$PROJECT_DIR/memory"

# No memory symlink or missing target → nothing to do
[ ! -e "$MEMORY_LINK" ] && exit 0

# Resolve symlink → real dir. Use `cd && pwd` (portable; avoids readlink -f
# which is GNU-only — BSD/macOS doesn't have it).
MEMORY_DIR="$(cd "$MEMORY_LINK" 2>/dev/null && pwd)" || exit 0
[ ! -d "$MEMORY_DIR/.git" ] && exit 0

# Throttle: only fetch if last fetch was >5 minutes ago (or never).
# 5 min is a balance — fresh enough that teammates' updates show up quickly,
# infrequent enough that we don't thrash the network.
FETCH_HEAD="$MEMORY_DIR/.git/FETCH_HEAD"
if [ -f "$FETCH_HEAD" ]; then
  # stat flag differs between BSD (macOS) and GNU (Linux)
  LAST_FETCH=$(stat -f %m "$FETCH_HEAD" 2>/dev/null || stat -c %Y "$FETCH_HEAD" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE=$((NOW - LAST_FETCH))
  [ "$AGE" -lt 300 ] && exit 0
fi

# Background fetch+pull. Never blocks the prompt. Next tool read of memory/
# will see fresh data (usually completes in <2s).
(
  git -C "$MEMORY_DIR" fetch origin --quiet 2>/dev/null

  # Only pull when local and remote diverge AND fast-forward is possible.
  # Skip if not on a branch (detached HEAD), if no upstream, or if we'd need
  # to merge (would be a three-way situation that shouldn't happen for
  # append-only handoff/memory writes, but if it did, we don't want to leave
  # the repo in a conflicted state unattended).
  LOCAL=$(git -C "$MEMORY_DIR" rev-parse HEAD 2>/dev/null)
  UPSTREAM=$(git -C "$MEMORY_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
  if [ -n "$LOCAL" ] && [ -n "$UPSTREAM" ]; then
    REMOTE=$(git -C "$MEMORY_DIR" rev-parse "$UPSTREAM" 2>/dev/null)
    if [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
      # --ff-only: fail cleanly instead of merging or rebasing
      git -C "$MEMORY_DIR" pull --ff-only --quiet 2>/dev/null || true
    fi
  fi
) &
disown 2>/dev/null || true

exit 0
