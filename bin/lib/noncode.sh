#!/usr/bin/env bash
# noncode.sh — shared "non-coding change" classifier for auto-merge decisions.
#
# The org rule: non-coding PRs auto-merge to develop; code goes to review.
# Non-coding means:
#   - any .md file, anywhere
#   - anything under content directories (artifacts/, docs/, .threads/) —
#     html/css/images/design bundles there are authored content, not shipped code
#   - session-state droppings (.egregore-worktree-tty)
# Everything else — bin/, api/, packages/, .claude/, site 2/, root config — is
# code and stays open for review.
#
# Sourced by handoff-save-egregore.sh, session-autosave.sh, agent.sh, and the
# /save skill. Keep the policy HERE — call sites must not grow their own.

# noncode_filter — reads paths on stdin, prints the first code-bearing path.
# Empty output = everything is non-coding.
noncode_filter() {
  grep -Ev '\.md$' \
    | grep -Ev '^(artifacts|docs|\.threads)/' \
    | grep -Ev '^\.egregore-worktree-tty$' \
    | head -1 || true
}

# noncode_blockers [base-ref] [repo-dir] — first code-bearing path committed
# on HEAD relative to base (three-dot: only our side of the diff).
# Empty output = the branch is non-coding and safe to auto-merge.
noncode_blockers() {
  local base="${1:-origin/develop}" dir="${2:-.}"
  git -C "$dir" diff "$base...HEAD" --name-only 2>/dev/null | noncode_filter
}
