#!/usr/bin/env bash
# session-id.sh — the calling harness session's own Egregore session id.
#
# Every session start mints an Egregore session id and writes it to the
# checkout's .egregore-session-id, which each worktree links to. With several
# sessions open on one machine, the latest start owns that file, so a commit
# that reads it can carry another session's Egregore-Session trailer. This
# script keeps one small map file per harness session and resolves the
# caller's own id from the native session id its harness exports.
#
#   session-id.sh [--root DIR]
#       Print the caller's Egregore session id; print nothing and exit 1
#       when there is none. A native id in the environment whose map was
#       recorded for DIR's repository wins; otherwise DIR/.egregore-session-id.
#   session-id.sh record <harness> <native-id> <egregore-id> [--root DIR]
#       Map a starting session (bin/lib/identity.sh), replacing an old map.
#   session-id.sh bind <harness> <native-id> [--root DIR]
#       Map a session first seen after its start (a Codex thread, at its
#       first prompt) to the id it resolves to now. A map this repository
#       can use is kept; one recorded for a moved checkout is replaced.
#
# Native ids, in order: EGREGORE_NATIVE_SESSION_ID under
# EGREGORE_NATIVE_HARNESS (Claude, Pi and Prime tool commands), then
# CLAUDE_CODE_SESSION_ID, then CODEX_THREAD_ID. A Codex worker started from a
# Claude or Pi shell inherits that shell's ids and so resolves to the session
# that started it.
#
# Map files: ~/.egregore/sessions/<harness>-<native-id>.id, two lines: the
# Egregore id and the repository's physical git common dir, so a map never
# applies to another repository (a test fixture, another instance). Names are
# checked, never rewritten. Each record prunes maps unused for 30 days; every
# resolve and bind that uses a map marks it used.
set -u
export LC_ALL=C

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAP_DIR=""
[ -z "${HOME:-}" ] || MAP_DIR="$HOME/.egregore/sessions"
SCOPE=""

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

valid_harness() {
  case "$1" in ''|*[!a-z0-9]*) return 1 ;; esac
  [ "${#1}" -le 16 ]
}

valid_native() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

valid_session() {
  case "$1" in ''|*[[:cntrl:]]*) return 1 ;; esac
  [ "${#1}" -le 200 ]
}

# The repository's git common dir, physical, so worktrees and every spelling
# of one checkout agree.
scope_of() {
  local dir
  dir="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$dir" in /*) ;; *) dir="$1/$dir" ;; esac
  (cd "$dir" 2>/dev/null && pwd -P)
}

# Print a map's Egregore id when the map belongs to this repository, and mark
# it used so the age prune spares a session that is still working.
lookup() {
  local harness="$1" native="$2" file id="" scope=""
  [ -n "$MAP_DIR" ] && valid_harness "$harness" && valid_native "$native" || return 1
  file="$MAP_DIR/$harness-$native.id"
  [ -f "$file" ] || return 1
  { IFS= read -r id; IFS= read -r scope; } < "$file" 2>/dev/null
  valid_session "$id" && [ -n "$scope" ] || return 1
  [ -n "$SCOPE" ] || SCOPE="$(scope_of "$ROOT_DIR")" || return 1
  [ "$scope" = "$SCOPE" ] || return 1
  touch -c "$file" 2>/dev/null   # -c: a map pruned meanwhile stays gone, never empty
  printf '%s\n' "$id"
}

resolve() {
  local id=""
  if [ -n "${EGREGORE_NATIVE_SESSION_ID:-}" ] && [ -n "${EGREGORE_NATIVE_HARNESS:-}" ]; then
    if lookup "$EGREGORE_NATIVE_HARNESS" "$EGREGORE_NATIVE_SESSION_ID"; then return 0; fi
  fi
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    if lookup claude "$CLAUDE_CODE_SESSION_ID"; then return 0; fi
  fi
  if [ -n "${CODEX_THREAD_ID:-}" ]; then
    if lookup codex "$CODEX_THREAD_ID"; then return 0; fi
  fi
  [ -f "$ROOT_DIR/.egregore-session-id" ] || return 1
  IFS= read -r id < "$ROOT_DIR/.egregore-session-id" 2>/dev/null
  valid_session "$id" || return 1
  printf '%s\n' "$id"
}

record() {
  local harness="$1" native="$2" id="$3" scope tmp
  [ -n "$MAP_DIR" ] && valid_harness "$harness" && valid_native "$native" && valid_session "$id" || return 1
  scope="$(scope_of "$ROOT_DIR")" && [ -n "$scope" ] || return 1
  mkdir -p "$MAP_DIR" 2>/dev/null || return 1
  tmp="$MAP_DIR/.$harness-$native.$$"
  printf '%s\n%s\n' "$id" "$scope" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$MAP_DIR/$harness-$native.id" 2>/dev/null || { rm -f "$tmp"; return 1; }
  find "$MAP_DIR" -maxdepth 1 -type f \( -name '*.id' -o -name '.*' \) -mtime +30 \
    -exec rm -f {} + 2>/dev/null
  return 0
}

bind() {
  local harness="$1" native="$2" id
  [ -n "$MAP_DIR" ] && valid_harness "$harness" && valid_native "$native" || return 1
  # A map this repository can use is kept; one recorded for a checkout that
  # has since moved is replaced rather than left unusable.
  lookup "$harness" "$native" >/dev/null && return 0
  id="$(resolve)" || return 1
  record "$harness" "$native" "$id"
}

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ -n "${2:-}" ] || { echo "session-id.sh: --root needs a directory" >&2; exit 2; }
      ROOT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

case "${1:-resolve}" in
  resolve)
    [ $# -le 1 ] || { usage >&2; exit 2; }
    resolve ;;
  record)
    [ $# -eq 4 ] || { usage >&2; exit 2; }
    record "$2" "$3" "$4" ;;
  bind)
    [ $# -eq 3 ] || { usage >&2; exit 2; }
    bind "$2" "$3" ;;
  *) usage >&2; exit 2 ;;
esac
