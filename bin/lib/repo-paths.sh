#!/usr/bin/env bash
# Shared physical path containment. Sourced library; no effects until called.
# Usage: source bin/lib/repo-paths.sh; inside_repository <path> [root]
# Exit codes (physical_path): 0 = physical path printed, 1 = resolution failed
# Exit codes (inside_repository): 0 = inside root, 1 = outside or unresolved
# Neither function reads file contents. An absent ordinary final component can
# be named for missing-file diagnostics; dangling symlinks fail resolution.

physical_path() {
  local path="${1:-}" directory name target hops=0
  [ -n "$path" ] || return 1
  case "$path" in /*) ;; *) path="./$path" ;; esac
  while :; do
    directory="${path%/*}"
    name="${path##*/}"
    directory=$(cd -P "${directory:-/}" 2>/dev/null && pwd -P) || return 1
    path="${directory%/}/$name"
    if [ -L "$path" ]; then
      hops=$((hops + 1))
      [ "$hops" -le 40 ] || return 1
      target=$(readlink "$path" 2>/dev/null) || return 1
      case "$target" in /*) path="$target" ;; *) path="$directory/$target" ;; esac
    else
      # A symlink must end at an existing target, not an absent directory entry.
      if [ "$hops" -gt 0 ] && [ ! -e "$path" ]; then return 1; fi
      case "$name" in ''|.|..) path=$(cd -P "$path" 2>/dev/null && pwd -P) || return 1 ;; esac
      printf '%s\n' "$path"
      return 0
    fi
  done
}

inside_repository() {
  local path="${1:-}" root="${2:-$SCRIPT_DIR}"
  [ -n "$path" ] || return 1
  root=$(physical_path "$root") || return 1
  case "$path" in /*) ;; *) path="$root/$path" ;; esac
  path=$(physical_path "$path") || return 1
  case "$path" in "$root"|"${root%/}/"*) return 0 ;; *) return 1 ;; esac
}
