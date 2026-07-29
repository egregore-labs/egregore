#!/usr/bin/env bash
# handoff-save-egregore.sh — background save+auto-merge for the core repo after a handoff.
#
# /handoff renders its card first, then fires this detached. The user never waits on git.
#
# Behavior:
#   - If nothing to save (clean working tree + up-to-date with origin) → exit silently.
#   - If on develop/main/master → create dev/{author}/handoff-{YYYY-MM-DD} branch from origin/develop.
#   - Commit all changes, rebase onto origin/develop, push.
#   - If push succeeds: create PR to develop (or reuse existing), then:
#     - Markdown-only diff → `gh pr merge --auto --merge` (auto-merges when checks pass).
#     - Code/config present → leave PR open for review (no auto-merge).
#
# Usage:
#   handoff-save-egregore.sh <author> <topic> [--repo-dir <path>]
#
# --repo-dir overrides the default working directory (normally the script's
# own repo root, resolved from $0). Tests and sandbox runs MUST pass it;
# without it, the script operates on the real repo regardless of caller cwd.
#
# Detached usage (the skill calls it this way):
#   ( bash bin/handoff-save-egregore.sh "$AUTHOR" "$TOPIC" >/dev/null 2>&1 & ) >/dev/null 2>&1
#
# Exit 0 on any non-fatal outcome. The caller never reads stdout/stderr — all status
# lives in the PR itself and in `git log`.

set -uo pipefail

AUTHOR="${1:-}"
TOPIC="${2:-session work}"
shift 2 2>/dev/null || true

REPO_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir) REPO_DIR="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$AUTHOR" ] || { echo "handoff-save-egregore: missing author" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# If --repo-dir wasn't given, default to the script's own repo root.
[ -z "$REPO_DIR" ] && REPO_DIR="$SCRIPT_DIR"
cd "$REPO_DIR" || exit 1

# --- Early exit if nothing to do -----------------------------------------
DIRTY=0
[ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY=1

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
AHEAD=0
if [ -n "$CURRENT_BRANCH" ]; then
  # Count commits ahead of origin/develop on the current branch (works from any
  # dev/* branch or from develop itself).
  AHEAD=$(git rev-list --count "origin/develop..HEAD" 2>/dev/null || echo 0)
fi

if [ "$DIRTY" = "0" ] && [ "$AHEAD" = "0" ]; then
  exit 0
fi

# --- Protect the protected branches: create a working branch if needed --
case "$CURRENT_BRANCH" in
  develop|main|master|"")
    SLUG_DATE=$(date +%Y-%m-%d)
    NEW_BRANCH="dev/${AUTHOR}/handoff-${SLUG_DATE}"
    git fetch origin develop --quiet 2>/dev/null || true
    git checkout -b "$NEW_BRANCH" origin/develop --quiet 2>/dev/null || \
      git checkout "$NEW_BRANCH" --quiet 2>/dev/null || exit 0
    CURRENT_BRANCH="$NEW_BRANCH"
    ;;
esac

# --- Commit whatever is uncommitted --------------------------------------
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  git add -A 2>/dev/null || true
  git commit -m "Handoff: ${TOPIC}" --quiet 2>/dev/null || true
fi

# --- Rebase onto develop, fall back to merge if rebase conflicts ---------
git fetch origin develop --quiet 2>/dev/null || true
if ! git rebase origin/develop --quiet --empty=drop 2>/dev/null; then
  git rebase --abort 2>/dev/null || true
  if ! git merge origin/develop --quiet -m "Sync with develop" 2>/dev/null; then
    # Conflicts we can't auto-resolve. Leave the branch as-is; the user will see it
    # next session or when they run /save explicitly.
    git merge --abort 2>/dev/null || true
    exit 0
  fi
fi

# --- Push ---------------------------------------------------------------
if ! git push -u origin "$CURRENT_BRANCH" --quiet 2>/dev/null; then
  # Push failed (network, auth). Commits are safe locally.
  exit 0
fi

# --- PR: reuse open PR on this branch, or create one --------------------
command -v gh >/dev/null 2>&1 || exit 0

PR_NUMBER=""
EXISTING=$(gh pr list --head "$CURRENT_BRANCH" --state open --json number,baseRefName --jq '.[0]' 2>/dev/null)
EXISTING_NUMBER=$(echo "$EXISTING" | jq -r '.number // empty' 2>/dev/null)
EXISTING_BASE=$(echo "$EXISTING" | jq -r '.baseRefName // empty' 2>/dev/null)

if [ -n "$EXISTING_NUMBER" ]; then
  PR_NUMBER="$EXISTING_NUMBER"
  if [ "$EXISTING_BASE" != "develop" ]; then
    gh pr edit "$PR_NUMBER" --base develop >/dev/null 2>&1 || true
  fi
else
  PR_URL=$(gh pr create \
    --base develop \
    --head "$CURRENT_BRANCH" \
    --title "Handoff: ${TOPIC}" \
    --body "Auto-created by /handoff. Session work for: ${TOPIC}" \
    2>/dev/null || echo "")
  PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' || echo "")
fi

[ -n "$PR_NUMBER" ] || exit 0

# --- Auto-merge iff markdown-only ---------------------------------------
NON_MD=$(git diff origin/develop --name-only 2>/dev/null | grep -v '\.md$' | head -1 || echo "")
if [ -z "$NON_MD" ]; then
  gh pr merge "$PR_NUMBER" --auto --merge >/dev/null 2>&1 || true
fi

exit 0
