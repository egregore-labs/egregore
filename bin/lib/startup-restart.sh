#!/usr/bin/env bash
# Finish a startup on the script its own sync just pulled.
#
# The startup sync (bin/lib/git-sync.sh) can fast-forward this checkout onto a
# newer framework. Bash keeps reading the copy of the startup script it opened,
# while every library sourced after the sync is the new version, so the rest
# of the run would mix both. When the sync moved HEAD and changed the startup
# itself, start the new script once, with the same session id. Shared by the
# Claude startup (bin/session-start.sh) and the Codex, Pi and Prime startup
# (bin/codex-session-start.sh).
#
# Usage (sourced, before the sync):
#   _STARTUP_HEAD=$(egregore_startup_head)
#   source "$SCRIPT_DIR/bin/lib/git-sync.sh"
#   egregore_startup_restart "$_STARTUP_HEAD" "$SCRIPT_DIR/bin/<script>" "$@"

# Empty outside a Git checkout (.git is a directory, or a file in a worktree):
# nothing there can be synced, so nothing restarts and Git is never called.
egregore_startup_head() {
  [ -e "${SCRIPT_DIR:-.}/.git" ] || return 0
  git rev-parse HEAD 2>/dev/null || true
}

# egregore_startup_restart <head-before-sync> <script> [args...]
# Returns when no restart is needed; otherwise replaces this process. Callers
# export anything else the new run must inherit before calling.
egregore_startup_restart() {
  local before="$1" script="$2"
  shift 2
  if [ -z "${_EGREGORE_STARTUP_REEXEC:-}" ] && [ -n "$before" ] \
    && [ "$(git rev-parse HEAD 2>/dev/null)" != "$before" ] \
    && ! git diff --quiet "$before" HEAD -- \
      bin/session-start.sh bin/codex-session-start.sh bin/lib 2>/dev/null; then
    egregore_trace_end 2>/dev/null || true
    # The hook's stdin was read before the sync and its session id mapped.
    export _EGREGORE_STARTUP_REEXEC=1 _EGREGORE_REUSE_SESSION_ID="$EGREGORE_SESSION_ID"
    exec bash "$script" "$@" < /dev/null
  fi
  # One restart per launch, and never inherited by what this run starts.
  export -n _EGREGORE_STARTUP_REEXEC 2>/dev/null || true
}
