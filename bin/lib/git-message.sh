#!/usr/bin/env bash
# git-message.sh — shared commit/PR message mechanics, sourced by composers.
# Spec: .claude/context/commit-format.md + .claude/context/pr-format.md.
#
# Provides:
#   egregore_session_trailer <hub_dir>
#       Print "Egregore-Session: <id>" when <hub_dir>/.egregore-session-id
#       exists; print nothing otherwise. Never fails.
#   egregore_commit <git_dir> <hub_dir> <message> [git-commit flags…]
#       git -C <git_dir> commit with the session trailer appended as the
#       final paragraph (a valid git trailer block) when an id exists.
#   egregore_pr_skeleton <what> <why> <verification> <footer>
#       The one source of the skeleton PR body shape.

egregore_session_trailer() {
  local sid
  sid="$(cat "${1:-.}/.egregore-session-id" 2>/dev/null || true)"
  [ -n "$sid" ] && printf 'Egregore-Session: %s' "$sid"
  return 0
}

egregore_commit() {
  local git_dir="$1" hub_dir="$2" msg="$3"
  shift 3
  local trailer
  trailer="$(egregore_session_trailer "$hub_dir")"
  if [ -n "$trailer" ]; then
    git -C "$git_dir" commit -m "$msg" -m "$trailer" "$@"
  else
    git -C "$git_dir" commit -m "$msg" "$@"
  fi
}

egregore_pr_skeleton() {
  printf '## What\n%s\n\n## Why\n%s\n\n## Verification\n%s\n\n%s\n' \
    "$1" "$2" "$3" "$4"
}
