#!/usr/bin/env bash
# ensure-develop.sh — Ensure a repository has a develop branch.
#
# Usage:
#   bash bin/lib/ensure-develop.sh <repo-path>
#   bash bin/lib/ensure-develop.sh <repo-path> --report
#
# Behavior:
#   1. Detects the repo's default branch (main, master, or HEAD)
#   2. Checks if develop exists locally and/or on origin
#   3. If missing, creates develop from the default branch and pushes it
#
# Flags:
#   --report   Print a JSON report of the repo's branching model instead of
#              creating develop. Used by create-egregore to analyze existing repos.
#
# Exit codes:
#   0 — develop exists (already existed or was just created)
#   1 — could not create develop (no default branch, not a git repo, push failed)
#
# Output (on success, without --report):
#   created:<default_branch>   — develop was created from <default_branch>
#   exists                     — develop already existed
#
# Output (with --report):
#   JSON object with branching analysis

set -o pipefail

REPO_PATH="${1:-.}"
FLAG="${2:-}"

if [ ! -d "$REPO_PATH/.git" ] && [ ! -f "$REPO_PATH/.git" ]; then
  echo "error:not_a_git_repo" >&2
  exit 1
fi

# ── Detect default branch ──────────────────────────────────────────
# Priority: what origin/HEAD points to > main > master > first branch found
detect_default_branch() {
  local repo="$1"

  # 1. Check origin/HEAD (set by GitHub on clone)
  local origin_head
  origin_head=$(git -C "$repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  if [ -n "$origin_head" ] && git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$origin_head" 2>/dev/null; then
    echo "$origin_head"
    return 0
  fi

  # 2. Check common names on remote
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
      echo "$branch"
      return 0
    fi
  done

  # 3. Check local branches (repo might not have a remote yet)
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
      echo "$branch"
      return 0
    fi
  done

  # 4. Fall back to whatever HEAD points to
  local head_branch
  head_branch=$(git -C "$repo" branch --show-current 2>/dev/null)
  if [ -n "$head_branch" ] && [ "$head_branch" != "develop" ]; then
    echo "$head_branch"
    return 0
  fi

  return 1
}

# ── Report mode ─────────────────────────────────────────────────────
if [ "$FLAG" = "--report" ]; then
  default_branch=$(detect_default_branch "$REPO_PATH" 2>/dev/null || echo "")
  has_develop_local="false"
  has_develop_remote="false"
  git -C "$REPO_PATH" show-ref --verify --quiet refs/heads/develop 2>/dev/null && has_develop_local="true"
  git -C "$REPO_PATH" show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null && has_develop_remote="true"

  # Count remote branches (excluding HEAD)
  branch_count=$(git -C "$REPO_PATH" branch -r 2>/dev/null | grep -cv 'HEAD' 2>/dev/null || echo "0")
  [ -z "$branch_count" ] && branch_count=0

  # List remote branch names (excluding origin/HEAD, max 20)
  _branch_list=$(git -C "$REPO_PATH" branch -r --format='%(refname:short)' 2>/dev/null \
    | grep -v 'origin/HEAD' \
    | sed 's|^origin/||' \
    | head -20)
  if [ -n "$_branch_list" ]; then
    branches=$(echo "$_branch_list" | jq -R . | jq -s .)
  else
    branches="[]"
  fi

  # Detect active contributors from branch names (dev/author/... pattern)
  _contrib_list=$(git -C "$REPO_PATH" branch -r --format='%(refname:short)' 2>/dev/null \
    | grep -E '^origin/dev/' \
    | sed 's|^origin/dev/||; s|/.*||' \
    | sort -u)
  if [ -n "$_contrib_list" ]; then
    contributors=$(echo "$_contrib_list" | jq -R . | jq -s .)
  else
    contributors="[]"
  fi

  jq -n \
    --arg default_branch "$default_branch" \
    --argjson has_develop_local "$has_develop_local" \
    --argjson has_develop_remote "$has_develop_remote" \
    --argjson branch_count "$branch_count" \
    --argjson branches "$branches" \
    --argjson contributors "$contributors" \
    '{
      default_branch: $default_branch,
      has_develop_local: $has_develop_local,
      has_develop_remote: $has_develop_remote,
      branch_count: $branch_count,
      branches: $branches,
      contributors: $contributors,
      needs_develop: (($has_develop_remote | not) and ($has_develop_local | not))
    }'
  exit 0
fi

# ── Ensure develop exists ──────────────────────────────────────────

# Already exists on remote?
if git -C "$REPO_PATH" show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then
  # Ensure local tracking branch exists too
  if ! git -C "$REPO_PATH" show-ref --verify --quiet refs/heads/develop 2>/dev/null; then
    git -C "$REPO_PATH" branch develop origin/develop --quiet 2>/dev/null || true
  fi
  echo "exists"
  exit 0
fi

# Already exists locally but not on remote? Push it.
if git -C "$REPO_PATH" show-ref --verify --quiet refs/heads/develop 2>/dev/null; then
  if git -C "$REPO_PATH" push -u origin develop --quiet 2>/dev/null; then
    echo "exists"
    exit 0
  fi
  # Push failed but local exists — still usable
  echo "exists:local_only"
  exit 0
fi

# Need to create develop from default branch
DEFAULT_BRANCH=$(detect_default_branch "$REPO_PATH")
if [ -z "$DEFAULT_BRANCH" ]; then
  echo "error:no_default_branch" >&2
  exit 1
fi

# Create develop from the default branch
# Prefer remote ref if available (more up-to-date after fetch)
if git -C "$REPO_PATH" show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH" 2>/dev/null; then
  git -C "$REPO_PATH" branch develop "origin/$DEFAULT_BRANCH" --quiet 2>/dev/null
else
  git -C "$REPO_PATH" branch develop "$DEFAULT_BRANCH" --quiet 2>/dev/null
fi

if [ $? -ne 0 ]; then
  echo "error:branch_create_failed" >&2
  exit 1
fi

# Push to remote
if git -C "$REPO_PATH" push -u origin develop --quiet 2>/dev/null; then
  echo "created:$DEFAULT_BRANCH"
  exit 0
else
  # Push failed — develop exists locally but not on remote
  # This is still usable; session-start.sh will retry the push
  echo "created:$DEFAULT_BRANCH:local_only"
  exit 0
fi
