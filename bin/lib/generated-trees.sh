#!/usr/bin/env bash
# Shared generated-tree exclusions. Sourced library; no repository access.
# Usage: source bin/lib/generated-trees.sh; is_generated_path <repo-relative-path>
# Exit codes (is_generated_path): 0 = generated, 1 = source path

# Runtime bundles are copies of bin/ and .claude/skills, so scanning the sources covers them.
GENERATED_TREES=(
  '*/packages/create-egregore/runtime/*'
  '*/node_modules/*'
  '*/dist/*'
  '/.claude/worktrees/*'
  '/.codex/worktrees/*'
  '/.pi/worktrees/*'
  '/.egregore/runtime/*'
)

is_generated_path() {
  local tree
  for tree in "${GENERATED_TREES[@]}"; do
    # These entries deliberately contain glob patterns.
    # shellcheck disable=SC2254
    case "/$1" in
      $tree) return 0 ;;
    esac
  done
  return 1
}
