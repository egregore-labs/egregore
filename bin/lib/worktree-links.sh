# shellcheck shell=bash
# worktree-links.sh - shared-state bootstrap for git worktrees.
#
# Claude Code worktrees are normally created through bin/worktree-create.sh,
# which links memory/, .env, and local state from the main checkout. Portable
# runtimes such as Codex can land in a plain git worktree, so startup and
# agent.sh use this helper to self-heal those links before reading context.

egregore_main_project_dir() {
  local project_dir="${1:?project dir required}"
  if [ -f "$project_dir/.git" ]; then
    local wt_gitdir
    wt_gitdir=$(sed 's/^gitdir: //' "$project_dir/.git" 2>/dev/null || true)
    if [ -n "$wt_gitdir" ]; then
      cd "$wt_gitdir/../../.." 2>/dev/null && pwd
      return
    fi
  fi
  cd "$project_dir" 2>/dev/null && pwd
}

egregore_link_shared_state() {
  local worktree_dir="${1:?worktree dir required}"
  local main_dir="${2:-}"
  local file src dst resolved

  [ -f "$worktree_dir/.git" ] || return 0
  [ -n "$main_dir" ] || main_dir="$(egregore_main_project_dir "$worktree_dir")"
  [ -n "$main_dir" ] || return 0
  [ "$main_dir" != "$worktree_dir" ] || return 0

  for file in memory .env .egregore-state.json .egregore-session-id; do
    src="$main_dir/$file"
    dst="$worktree_dir/$file"

    if [ "$file" = "memory" ]; then
      if [ -L "$src" ] || [ -d "$src" ]; then
        resolved="$(realpath "$src" 2>/dev/null || true)"
        [ -n "$resolved" ] && [ -d "$resolved" ] || continue
        src="$resolved"
      else
        continue
      fi
    else
      [ -f "$src" ] || continue
    fi

    if [ -L "$dst" ]; then
      ln -sfn "$src" "$dst" 2>/dev/null || true
    elif [ ! -e "$dst" ]; then
      ln -s "$src" "$dst" 2>/dev/null || true
    fi
  done
}

# Resolve the .env that governs a checkout. A worktree can be missing its .env
# symlink (created before .env existed, or by a runtime that skipped worktree
# setup) — self-heal the links, then fall back to the main checkout's .env so
# credential loading never silently comes up empty. Prints the usable path, or
# nothing when neither checkout has one. Always returns 0.
egregore_env_file() {
  local project_dir="${1:?project dir required}"
  if [ ! -f "$project_dir/.env" ] && [ -f "$project_dir/.git" ]; then
    egregore_link_shared_state "$project_dir" 2>/dev/null || true
  fi
  if [ -f "$project_dir/.env" ]; then
    echo "$project_dir/.env"
    return 0
  fi
  if [ -f "$project_dir/.git" ]; then
    local main_dir
    main_dir="$(egregore_main_project_dir "$project_dir" 2>/dev/null || true)"
    if [ -n "$main_dir" ] && [ -f "$main_dir/.env" ]; then
      echo "$main_dir/.env"
      return 0
    fi
  fi
  return 0
}
