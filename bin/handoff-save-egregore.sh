#!/usr/bin/env bash
# handoff-save-egregore.sh — background save+auto-merge for the core repo after a handoff.
#
# /handoff renders its card first, then fires this detached. The user never waits on git.
#
# Behavior:
#   - If nothing to save (clean working tree + up-to-date with origin) → exit silently.
#   - If on the configured base (or another protected branch) → create a
#     dev/{author}/handoff-{YYYY-MM-DD} branch from origin/{base}.
#   - Commit all changes, rebase onto origin/{base}, push.
#   - If push succeeds: create a PR to the configured base (or reuse existing), then:
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
KIND="handoff"
BRANCH_SUFFIX=""
PUBLISH="auto"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir) REPO_DIR="${2:-}"; shift 2 ;;
    --kind) KIND="${2:-handoff}"; shift 2 ;;
    --branch-suffix) BRANCH_SUFFIX="${2:-}"; shift 2 ;;
    --publish) PUBLISH="${2:-auto}"; shift 2 ;;
    *) shift ;;
  esac
done

case "$KIND" in
  autosave)
    MSG_PREFIX="chore(autosave): save"
    PR_WHAT="Save session content captured by the opted-in autosave workflow."
    PR_WHY="This preserves unattended non-coding work without requiring an explicit /save."
    ;;
  *)
    MSG_PREFIX="chore(handoff): record"
    PR_WHAT="Save core-repository session work captured when the handoff was created."
    PR_WHY="The handoff records shared context immediately; this companion PR keeps the originating checkout's work from remaining only local."
    ;;
esac
[ -n "$AUTHOR" ] || { echo "handoff-save-egregore: missing author" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# If --repo-dir wasn't given, default to the script's own repo root.
[ -z "$REPO_DIR" ] && REPO_DIR="$SCRIPT_DIR"
cd "$REPO_DIR" || exit 1

# Resolve the target checkout's configured integration branch. SCRIPT_DIR points
# at the framework that owns this helper, while CONFIG must follow --repo-dir so
# sandboxed and installed instances read their own egregore.json.
CONFIG="$REPO_DIR/egregore.json"
[ -f "$SCRIPT_DIR/bin/lib/config.sh" ] || {
  echo "handoff-save-egregore: base-branch resolver is unavailable" >&2
  exit 1
}
# shellcheck source=bin/lib/config.sh
. "$SCRIPT_DIR/bin/lib/config.sh" 2>/dev/null || exit 1
if ! BASE_BRANCH=$(_get_base_branch); then
  echo "handoff-save-egregore: could not resolve the configured base branch" >&2
  exit 1
fi
BASE_REF="origin/$BASE_BRANCH"

# Shared safe-staging guard — never auto-commit stray sibling-repo gitlinks.
# shellcheck source=bin/lib/git-safe.sh
. "$SCRIPT_DIR/bin/lib/git-safe.sh" 2>/dev/null || true
type git_add_guarded >/dev/null 2>&1 || git_add_guarded() { git add -A 2>/dev/null || true; }

# Shared commit/PR message mechanics (trailers + skeleton body shape).
# shellcheck source=bin/lib/git-message.sh
. "$SCRIPT_DIR/bin/lib/git-message.sh" 2>/dev/null || true
type egregore_commit >/dev/null 2>&1 || egregore_commit() {
  local gd="$1" m="$3"; shift 3; git -C "$gd" commit -m "$m" "$@"
}
type egregore_pr_skeleton >/dev/null 2>&1 || egregore_pr_skeleton() {
  printf '## What\n%s\n\n## Why\n%s\n\n## Verification\n%s\n\n%s\n' "$1" "$2" "$3" "$4"
}
PR_BODY=$(egregore_pr_skeleton \
  "- $PR_WHAT" \
  "$PR_WHY Topic: \`$TOPIC\`." \
  "Not verified — background $KIND save; review code or configuration changes before merging." \
  "🤖 Saved via \`bin/handoff-save-egregore.sh\`")

# Shared non-coding classifier (auto-merge policy lives in one place).
# shellcheck source=bin/lib/noncode.sh
. "$SCRIPT_DIR/bin/lib/noncode.sh" 2>/dev/null || true
type noncode_blockers >/dev/null 2>&1 || noncode_blockers() {
  git -C "${2:-.}" diff "${1:-$BASE_REF}...HEAD" --name-only 2>/dev/null | grep -v '\.md$' | head -1 || true
}

# --- Early exit if nothing to do -----------------------------------------
DIRTY=0
[ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY=1

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
AHEAD=0
if [ -n "$CURRENT_BRANCH" ]; then
  # A missing remote base is not evidence that there is nothing to save. The
  # former `|| echo 0` made a main-only instance silently discard clean,
  # committed topic work because origin/develop did not exist.
  if ! AHEAD=$(git rev-list --count "$BASE_REF..HEAD" 2>/dev/null); then
    AHEAD=1
  fi
fi

if [ "$DIRTY" = "0" ] && [ "$AHEAD" = "0" ]; then
  exit 0
fi

# --- Protect the protected branches: create a working branch if needed --
if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ] \
   || [ "$CURRENT_BRANCH" = "develop" ] || [ "$CURRENT_BRANCH" = "main" ] \
   || [ "$CURRENT_BRANCH" = "master" ]; then
  SLUG_DATE=$(date +%Y-%m-%d)
  # --branch-suffix keeps concurrent rescues distinct (e.g. per-checkout
  # hash from the autosave sweep) — same-name pushes wedge on non-FF.
  NEW_BRANCH="dev/${AUTHOR}/${KIND}-${SLUG_DATE}${BRANCH_SUFFIX:+-$BRANCH_SUFFIX}"
  git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true
  git checkout -b "$NEW_BRANCH" "$BASE_REF" --quiet 2>/dev/null || \
    git checkout "$NEW_BRANCH" --quiet 2>/dev/null || exit 0
  CURRENT_BRANCH="$NEW_BRANCH"
fi

# --- Commit whatever is uncommitted --------------------------------------
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  git_add_guarded
  egregore_commit . "$REPO_DIR" "${MSG_PREFIX} ${TOPIC}" --quiet 2>/dev/null || true
fi

# --- Rebase onto the configured base, fall back to merge on conflicts ----
git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true
if ! git rebase "$BASE_REF" --quiet 2>/dev/null; then
  git rebase --abort 2>/dev/null || true
  if ! git merge "$BASE_REF" --quiet -m "Sync with $BASE_BRANCH" 2>/dev/null; then
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

# --- Ledger: the user-visible trail of background saves ------------------
# Read by session-autosave.sh (immediate Stop-hook notice) and the greeting
# (next-launch summary). Machine-scoped so worktree saves surface everywhere.
LEDGER="${EGREGORE_AUTOSAVE_LOG:-$HOME/.egregore/autosave.log}"
ledger_write() { # pr outcome
  local n_files
  n_files=$(git diff "$BASE_REF...HEAD" --name-only 2>/dev/null | grep -c . || echo 0)
  mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true
  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$KIND" "$REPO_DIR" "$CURRENT_BRANCH" \
    "$1" "$2" "$n_files" >> "$LEDGER" 2>/dev/null || true
}

# --- PR: reuse open PR on this branch, or create one --------------------
command -v gh >/dev/null 2>&1 || { ledger_write "-" "pushed"; exit 0; }

PR_NUMBER=""
EXISTING=$(gh pr list --head "$CURRENT_BRANCH" --state open --json number,baseRefName --jq '.[0]' 2>/dev/null)
EXISTING_NUMBER=$(echo "$EXISTING" | jq -r '.number // empty' 2>/dev/null)
EXISTING_BASE=$(echo "$EXISTING" | jq -r '.baseRefName // empty' 2>/dev/null)

if [ -n "$EXISTING_NUMBER" ]; then
  PR_NUMBER="$EXISTING_NUMBER"
  if [ "$EXISTING_BASE" != "$BASE_BRANCH" ]; then
    gh pr edit "$PR_NUMBER" --base "$BASE_BRANCH" >/dev/null 2>&1 || true
  fi
else
  PR_URL=$(gh pr create \
    --base "$BASE_BRANCH" \
    --head "$CURRENT_BRANCH" \
    --title "${MSG_PREFIX} ${TOPIC}" \
    --body "$PR_BODY" \
    2>/dev/null || echo "")
  PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' || echo "")
fi

[ -n "$PR_NUMBER" ] || { ledger_write "-" "pushed"; exit 0; }

# --- Merge decision -------------------------------------------------------
# Non-coding + publish=auto → merge now. publish=gate → the PR is staged and
# the merge waits for the user's explicit word (the /autosave consent gate).
# `--auto` only works when the repo allows auto-merge AND required checks are
# pending; on a repo with no branch protection it always errors. Fall back to
# an immediate merge so non-coding PRs never sit open.
OUTCOME="open"
NON_CODE_BLOCKER=$(noncode_blockers "$BASE_REF" .)
if [ -z "$NON_CODE_BLOCKER" ]; then
  if [ "$PUBLISH" = "gate" ]; then
    OUTCOME="staged"
  elif gh pr merge "$PR_NUMBER" --auto --merge >/dev/null 2>&1 \
     || gh pr merge "$PR_NUMBER" --merge >/dev/null 2>&1; then
    OUTCOME="merged"
  fi
fi

ledger_write "$PR_NUMBER" "$OUTCOME"

exit 0
