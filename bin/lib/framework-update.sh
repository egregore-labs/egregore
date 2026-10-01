# shellcheck shell=bash
# Shared upstream overlay for manual and startup framework updates. Callers own
# branch selection, fetch, rendering, owned-skill restoration, and committing.
_checkout_framework_paths() {
  local target_dir="${1:-.}" framework_path
  if [ ! -d "$target_dir" ] || \
     [ "$(git -C "$target_dir" rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
    printf 'update-framework: not a working checkout: %s\n' "$target_dir" >&2
    return 1
  fi
  target_dir=$(git -C "$target_dir" rev-parse --show-toplevel) || return 1
  # Every caller, including the explicit update command, must respect the
  # target instance's Runtime ownership. Loading the helper from this library
  # also works when the command updates a checkout other than its own cwd.
  if (
    SCRIPT_DIR="$target_dir"
    # shellcheck source=bin/lib/runtime-owned.sh
    source "$(dirname "${BASH_SOURCE[0]}")/runtime-owned.sh"
    runtime_owns_framework
  ); then
    printf '%s\n' 'update-framework: Runtime manages this installation. Open egregore, select this instance, then Settings > Runtime update.' >&2
    return 1
  fi
  if ! git -C "$target_dir" remote get-url upstream >/dev/null 2>&1; then
    printf 'update-framework: upstream remote is missing in %s\n' "$target_dir" >&2
    return 1
  fi
  if ! git -C "$target_dir" rev-parse --verify --quiet 'refs/remotes/upstream/main^{commit}' >/dev/null; then
    printf 'update-framework: upstream/main is missing in %s; fetch upstream main first\n' "$target_dir" >&2
    return 1
  fi

  # A path checkout does not merge, rebase, move HEAD, or consult the user's
  # pull/merge/rebase strategy. Tolerate each missing or failed path separately,
  # preserving the historical overlay behavior while reporting each skip once.
  for framework_path in bin/ .claude/commands/ .claude/skills/ .claude/hooks/ .claude/context/ .claude/agents/ .pi/ .prime/ loom/ CLAUDE.md skills/; do
    if ! git -C "$target_dir" checkout upstream/main -- "$framework_path" 2>/dev/null; then
      printf 'update-framework: skipped %s (absent from upstream/main or checkout failed)\n' "$framework_path" >&2
    fi
  done
}
