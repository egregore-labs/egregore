#!/usr/bin/env bash
# repo-state.sh — Capture current branch state across all repos.
# Outputs a markdown table (## Repo State) for handoff files.
# Only includes repos on non-base branches or with uncommitted changes.
#
# Usage: bash bin/repo-state.sh [--no-pr]
#   --no-pr    Skip the `gh pr list` lookup per repo (~400–600ms each).
#              PR column will be `—`. Useful on the hot path where a detached
#              backfill will fill PR numbers in later.
#   Outputs the markdown section to stdout. Empty output = nothing to report.
set -euo pipefail

NO_PR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pr) NO_PR=1; shift ;;
    *) shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source config helpers for _get_base_branch
source "$SCRIPT_DIR/bin/lib/config.sh" 2>/dev/null || true

CORE_REPO=$(jq -r '.repo_name // "egregore"' "$CONFIG" 2>/dev/null)
GITHUB_ORG=$(jq -r '.github_org // empty' "$CONFIG" 2>/dev/null)
MANAGED_REPOS=$(jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' "$CONFIG" 2>/dev/null)

ROWS=""

check_repo() {
  local repo_name="$1"
  local repo_dir="$2"
  local base_branch="$3"

  [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] || return 0

  local branch
  branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || echo "")
  [ -z "$branch" ] && return 0

  local dirty=""
  [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null | head -1)" ] && dirty="yes"

  # Skip if on base branch with no changes
  if [ "$branch" = "$base_branch" ] && [ -z "$dirty" ]; then
    return 0
  fi

  # Count commits ahead of base
  local ahead=0
  ahead=$(git -C "$repo_dir" rev-list "origin/${base_branch}..HEAD" --count 2>/dev/null || echo "0")

  # Skip if on base branch, no dirty files, no commits ahead
  if [ "$branch" = "$base_branch" ] && [ -z "$dirty" ] && [ "$ahead" = "0" ]; then
    return 0
  fi

  # Check for open PR (skipped with --no-pr; a detached backfill fills it in)
  local pr="—"
  if [ "$NO_PR" = "0" ] && command -v gh &>/dev/null && [ -n "$GITHUB_ORG" ]; then
    local pr_num
    pr_num=$(gh pr list --repo "$GITHUB_ORG/$repo_name" --head "$branch" --json number -q '.[0].number' 2>/dev/null || true)
    [ -n "$pr_num" ] && pr="#$pr_num"
  fi

  ROWS="${ROWS}| ${repo_name} | ${branch} | ${pr} | ${base_branch} |\n"
}

# Check core repo
if ! CORE_BASE=$(_get_base_branch); then
  echo "repo-state: could not resolve the configured base branch" >&2
  exit 1
fi
check_repo "$CORE_REPO" "$SCRIPT_DIR" "$CORE_BASE"

# Check managed repos
for REPO in $MANAGED_REPOS; do
  REPO_DIR="$PARENT_DIR/$REPO"
  if ! BASE=$(_get_base_branch "$REPO"); then
    continue
  fi
  check_repo "$REPO" "$REPO_DIR" "$BASE"
done

# Output
if [ -n "$ROWS" ]; then
  echo "## Repo State"
  echo ""
  echo "| Repo | Branch | PR | Base |"
  echo "|------|--------|----|------|"
  printf '%b' "$ROWS"
fi
