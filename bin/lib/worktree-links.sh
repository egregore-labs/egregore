# shellcheck shell=bash
# worktree-links.sh - shared-state bootstrap for git worktrees.
#
# Claude Code worktrees are normally created through bin/worktree-create.sh,
# which links memory/, .env, and local state from the main checkout. Portable
# runtimes such as Codex can land in a plain git worktree, so startup and
# agent.sh use this helper to self-heal those links before reading context.
# Both creation paths (the hook and worktree.sh setup) also link installed
# tools through egregore_link_tools.

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
    elif [ -f "$dst" ] && cmp -s "$src" "$dst"; then
      # Older atomic writers could replace a shared-state symlink with an
      # identical private file. Exact equality makes this repair lossless;
      # differing files are left untouched for explicit reconciliation.
      rm -f "$dst" 2>/dev/null || continue
      ln -s "$src" "$dst" 2>/dev/null || true
    elif [ ! -e "$dst" ]; then
      ln -s "$src" "$dst" 2>/dev/null || true
    fi
  done
}

# Link the main checkout's installed tools into a new worktree: the root
# node_modules, each packages/<name>/node_modules the main checkout has, and
# .egregore/tools (the managed artifact renderer). All are gitignored, so a
# fresh worktree has none, and its tests and renderer fail before the work
# starts; a link shares the one install instead. A source the main checkout
# lacks is the normal state on many machines, so it is skipped silently.
#
# Anything already at a link's path stays, so a worktree's own install is
# never replaced. Nothing goes to stdout, which the WorktreeCreate hook
# reserves for the worktree path.
egregore_link_tools() {
  local worktree_dir="${1:?worktree dir required}"
  local main_dir="${2:?main checkout dir required}"
  local rel src

  for rel in node_modules .egregore/tools; do
    [ -d "$main_dir/$rel" ] || continue
    _egregore_link_tool "$worktree_dir" "$rel" "$main_dir/$rel"
  done
  for src in "$main_dir"/packages/*/node_modules; do
    rel="${src#"$main_dir"/}"
    [ -d "$src" ] && [ -d "$worktree_dir/${rel%/node_modules}" ] || continue
    _egregore_link_tool "$worktree_dir" "$rel" "$src"
  done
  return 0
}

# One tool link at <worktree>/<rel>. Git must ignore it, or the next save
# commits it as an untracked file. A trailing-slash pattern such as
# `node_modules/` matches only directories, never a link, and installed
# instances keep their own .gitignore (/update does not sync it), so a miss
# is hidden through info/exclude instead. Only when that file cannot take the
# pattern is the link taken back, with the one line this helper prints.
_egregore_link_tool() {
  local worktree_dir="$1" rel="$2" src="$3"
  local dst="$worktree_dir/$rel"

  if [ -e "$dst" ] || [ -L "$dst" ]; then
    return 0
  fi
  mkdir -p "${dst%/*}" 2>/dev/null || return 0
  ln -s "$src" "$dst" 2>/dev/null || return 0
  _egregore_git -C "$worktree_dir" check-ignore -q -- "$rel" && return 0
  if _egregore_exclude "$worktree_dir" "/$rel" \
     && _egregore_git -C "$worktree_dir" check-ignore -q -- "$rel"; then
    return 0
  fi
  rm -f "$dst"
  echo "worktree: not linking $rel; add \"$rel\" (no trailing slash) to .gitignore to keep the link out of commits" >&2
}

# Record one pattern in the checkout's info/exclude, the way
# packages/create-egregore records /.egregore/secret-entry/
# (recordRuntimeGitExcludes): git names the file, which a linked worktree
# shares with its main repository; only a regular file is written; the
# pattern goes in once, on its own line, under a comment. Returns 1 when the
# file cannot take the pattern.
_egregore_exclude() {
  local worktree_dir="$1" pattern="$2" exclude prefix=""

  exclude="$(_egregore_git -C "$worktree_dir" rev-parse --git-path info/exclude)" || return 1
  [ -n "$exclude" ] || return 1
  case "$exclude" in
    /*) ;;
    *) exclude="$worktree_dir/$exclude" ;;
  esac
  if [ -L "$exclude" ] || { [ -e "$exclude" ] && [ ! -f "$exclude" ]; }; then
    return 1
  fi
  if [ -f "$exclude" ]; then
    grep -qxF -e "$pattern" -e "$pattern"$'\r' "$exclude" && return 0
    if [ -s "$exclude" ] && [ -n "$(tail -c 1 "$exclude")" ]; then
      prefix=$'\n'
    fi
  fi
  mkdir -p "${exclude%/*}" 2>/dev/null || return 1
  { printf '%s# Egregore worktree tool link\n%s\n' "$prefix" "$pattern" >> "$exclude"; } 2>/dev/null
}

# git without inherited GIT_* overrides, which would point a worktree's
# answers, and the exclude write, at another repository.
_egregore_git() {
  (
    for name in $(compgen -e); do
      case "$name" in GIT_*) unset "$name" 2>/dev/null ;; esac
    done
    git "$@" 2>/dev/null
  )
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
