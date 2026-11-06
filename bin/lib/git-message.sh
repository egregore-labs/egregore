#!/usr/bin/env bash
# git-message.sh — shared commit/PR message mechanics, sourced by composers.
# Spec: .claude/context/commit-format.md + .claude/context/pr-format.md.
#
# Provides:
#   egregore_session_id <hub_dir>
#       Print the calling session's own Egregore session id through
#       bin/session-id.sh: its harness's native session id mapped at session
#       start, else the id in <hub_dir>/.egregore-session-id, which names
#       only the latest session start. Print nothing when neither exists.
#   egregore_session_trailer <hub_dir>
#       Print "Egregore-Session: <id>" for that id; print nothing when
#       there is none. Never fails.
#   egregore_commit <git_dir> <hub_dir> <message> [git-commit flags…]
#       git -C <git_dir> commit with the session trailer added through
#       git's own --trailer, so it joins a trailer block the message already
#       ends with (Co-Authored-By, Refs) instead of opening a paragraph of
#       its own that would turn those lines back into body text.
#   egregore_pr_skeleton <what> <why> <verification> <footer>
#       The one source of the skeleton PR body shape.

_EGREGORE_SESSION_RESOLVER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/session-id.sh"

egregore_session_id() {
  local hub="${1:-.}"
  if [ -f "$_EGREGORE_SESSION_RESOLVER" ]; then
    bash "$_EGREGORE_SESSION_RESOLVER" --root "$hub" 2>/dev/null
  else
    head -n 1 "$hub/.egregore-session-id" 2>/dev/null
  fi
  return 0
}

egregore_session_trailer() {
  local sid
  sid="$(egregore_session_id "${1:-.}")"
  [ -n "$sid" ] && printf 'Egregore-Session: %s' "$sid"
  return 0
}

egregore_commit() {
  local git_dir="$1" hub_dir="$2" msg="$3"
  shift 3
  local trailer
  trailer="$(egregore_session_trailer "$hub_dir")"
  if [ -n "$trailer" ]; then
    git -C "$git_dir" commit -m "$msg" --trailer "$trailer" "$@"
  else
    git -C "$git_dir" commit -m "$msg" "$@"
  fi
}

egregore_pr_skeleton() {
  printf '## What\n%s\n\n## Why\n%s\n\n## Verification\n%s\n\n%s\n' \
    "$1" "$2" "$3" "$4"
}
