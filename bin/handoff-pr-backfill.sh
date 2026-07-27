#!/usr/bin/env bash
# handoff-pr-backfill.sh — fill in PR numbers in a handoff file's ## Repo State
# table, then re-commit + push the memory repo. Detached fire-and-forget from
# /handoff's hot path so user-visible latency doesn't include N × `gh pr list`.
#
# Usage:
#   handoff-pr-backfill.sh <abs-handoff-file> <topic>
#
# Reads the ## Repo State table, looks up each (repo, branch)'s open PR via
# `gh pr list`, rewrites the PR column from `—` to `#N`, commits the memory
# repo, pushes to main. Silent on all failures — this is cosmetic.
#
# Detached usage (the skill / orchestrator call it this way):
#   ( bash bin/handoff-pr-backfill.sh "$ABS_FILE" "$TOPIC" >/dev/null 2>&1 & ) >/dev/null 2>&1

set -uo pipefail

ABS_FILE="${1:-}"
TOPIC="${2:-handoff}"

[ -n "$ABS_FILE" ] && [ -f "$ABS_FILE" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"

command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

GITHUB_ORG=$(jq -r '.github_org // empty' "$CONFIG" 2>/dev/null)
[ -n "$GITHUB_ORG" ] || exit 0

# Extract the ## Repo State table rows: format is `| repo | branch | — | base |`.
# Skip header and separator lines (first two rows of the markdown table).
ROWS=$(awk '
  /^## Repo State/ { in_section=1; next }
  in_section && /^## / { in_section=0 }
  in_section && /^\|/ && !/^\|[-\s]/ && !/^\| Repo/ { print }
' "$ABS_FILE" 2>/dev/null)

[ -n "$ROWS" ] || exit 0

UPDATED=0
while IFS= read -r row; do
  [ -z "$row" ] && continue
  # Parse: | repo | branch | pr | base |
  repo=$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}')
  branch=$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
  pr_col=$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}')

  # Only backfill `—` cells (leave `#N` alone)
  [ "$pr_col" = "—" ] || continue
  [ -n "$repo" ] && [ -n "$branch" ] || continue

  pr_num=$(gh pr list --repo "$GITHUB_ORG/$repo" --head "$branch" --json number --jq '.[0].number // empty' 2>/dev/null || echo "")
  [ -n "$pr_num" ] || continue

  # Rewrite the `—` in this branch's row to `#N`. Match by branch name to
  # avoid cross-repo collisions when repos share branch names.
  awk -v branch="$branch" -v pr="#$pr_num" '
    BEGIN { in_section=0 }
    /^## Repo State/ { in_section=1; print; next }
    in_section && /^## / { in_section=0 }
    in_section && $0 ~ "\\| " branch " " && /—/ {
      sub(/—/, pr)
      print; next
    }
    { print }
  ' "$ABS_FILE" > "$ABS_FILE.tmp" && mv "$ABS_FILE.tmp" "$ABS_FILE"
  UPDATED=1
done <<< "$ROWS"

[ "$UPDATED" = "1" ] || exit 0

# Re-commit + push the memory repo with the backfilled PR numbers.
MEMORY_DIR="$SCRIPT_DIR/memory"
if [ -d "$MEMORY_DIR" ]; then
  (
    cd "$MEMORY_DIR" || exit 0
    git add -A >/dev/null 2>&1
    git commit -m "Backfill PR numbers for handoff: $TOPIC" >/dev/null 2>&1 || exit 0
    git pull --rebase origin main --quiet >/dev/null 2>&1
    git push origin main --quiet >/dev/null 2>&1
  ) || true
fi

exit 0
