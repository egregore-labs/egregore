#!/usr/bin/env bash
# restore-owned-skills.sh — keep org-owned skills intact through a framework update.
#
# Org-owned skills are declared in egregore.json → owned_skills[]. The /update
# overlay stamps upstream framework paths (including .claude/skills/) over the
# working tree. This script runs AFTER the overlay and BEFORE the update
# commit. For every owned skill name:
#
#   - upstream does NOT ship that name  → nothing to do (the overlay never
#     touched it; local edits, committed or not, are left alone)
#   - upstream DOES ship that name      → the org's committed version wins:
#     the skill directory is reset to HEAD and the collision is reported so
#     the org can rename theirs or explicitly adopt upstream's
#   - collision but no committed org version → upstream's copy stays (there is
#     nothing to restore); the report says to commit and re-run /update
#
# Runtime-neutral: called from every harness's update flow. Idempotent; exits
# 0 silently when owned_skills is absent or empty.
#
# Usage: restore-owned-skills.sh [--upstream-ref <ref>]   (default upstream/main)

set -uo pipefail

UPSTREAM_REF="upstream/main"
if [ "${1:-}" = "--upstream-ref" ] && [ -n "${2:-}" ]; then
  UPSTREAM_REF="$2"
fi

command -v jq >/dev/null 2>&1 || exit 0
[ -f egregore.json ] || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

OWNED=$(jq -r '.owned_skills // [] | .[]' egregore.json 2>/dev/null)
[ -n "$OWNED" ] || exit 0

while IFS= read -r name; do
  [ -n "$name" ] || continue
  case "$name" in
    */*|.*|*..*|*' '*)
      echo "  ⚠ owned_skills: invalid name '$name' — skipped" >&2
      continue
      ;;
  esac
  SKILL_PATH=".claude/skills/$name"

  # Only a name collision needs work — an org-only skill is never touched by
  # the overlay, and resetting it here would destroy uncommitted local edits.
  if ! git ls-tree -d "$UPSTREAM_REF" -- "$SKILL_PATH" 2>/dev/null | grep -q .; then
    continue
  fi

  if git cat-file -e "HEAD:$SKILL_PATH" 2>/dev/null; then
    # Wipe the overlay's copy (index + tree), then restore the org's committed
    # version. rm+checkout also drops upstream-only files inside the dir.
    git rm -r --cached --quiet -- "$SKILL_PATH" 2>/dev/null || true
    rm -rf "$SKILL_PATH"
    git checkout HEAD -- "$SKILL_PATH" 2>/dev/null || true
    echo "  ◐ owned skill '$name': upstream ships a skill with this name — kept yours."
    echo "    Review upstream's version: git diff HEAD $UPSTREAM_REF -- $SKILL_PATH"
  else
    echo "  ⚠ owned skill '$name': upstream ships this name and you have no committed version — upstream's copy is in the tree. Commit yours and re-run /update to keep it."
  fi
done <<EOF
$OWNED
EOF

exit 0
