#!/usr/bin/env bash
# handoff-save-publish.sh — parallelise memory push + artifact publish; detach notify + PR backfill.
#
# Used by the /handoff skill. Moves the parallel/background plumbing out of
# SKILL.md so the skill stays declarative.
#
# Usage:
#   handoff-save-publish.sh <handoff_file> <topic> <author> <description_first_sentence> \
#                           [--recipient <name>] [--repo-state-section <text>]
#
# Foreground (blocks until done):
#   - memory repo commit + pull-rebase-push to main
#   - publish-artifact.sh (HTML + upload) → ARTIFACT_URL
#   Both run in parallel subshells; wall-clock = max(push, publish).
#
# Background (detached, survives session exit):
#   - notify.sh send $RECIPIENT $MESSAGE (if recipient set)
#   - PR-number backfill into the handoff file's ## Repo State table (cosmetic)
#
# Exit code 0 on foreground success. Prints ARTIFACT_URL to stdout on success.

set -uo pipefail

HANDOFF_FILE="${1:-}"
TOPIC="${2:-}"
AUTHOR="${3:-}"
DESCRIPTION="${4:-}"
shift 4 2>/dev/null || true

RECIPIENT=""
REPO_STATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --recipient) RECIPIENT="$2"; shift 2;;
    --repo-state-section) REPO_STATE="$2"; shift 2;;
    *) shift;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "$HANDOFF_FILE" ] || [ ! -f "$HANDOFF_FILE" ]; then
  echo "handoff-save-publish: handoff file missing: $HANDOFF_FILE" >&2
  exit 1
fi

SAVE_OUT=$(mktemp) || exit 1
PUB_OUT=$(mktemp) || exit 1
trap 'rm -f "$SAVE_OUT" "$PUB_OUT"' EXIT

# --- Foreground, parallel: memory push + artifact publish ---

(
  cd memory 2>/dev/null || exit 0
  git add -A
  git commit -m "Handoff: $TOPIC" >/dev/null 2>&1 || true
  for _ in 1 2 3; do
    git -c rebase.empty=drop pull --rebase origin main --quiet 2>/dev/null \
      && git push origin main --quiet 2>/dev/null && break
    sleep 1
  done
) > "$SAVE_OUT" 2>&1 &
SAVE_PID=$!

(
  bash "$SCRIPT_DIR/bin/publish-artifact.sh" handoff "$HANDOFF_FILE" \
    --title "$TOPIC" \
    --author "$AUTHOR" \
    --description "$DESCRIPTION" 2>/dev/null
) > "$PUB_OUT" 2>&1 &
PUB_PID=$!

wait "$SAVE_PID" "$PUB_PID"

ARTIFACT_URL=$(tail -1 "$PUB_OUT" 2>/dev/null | tr -d '[:space:]')
echo "$ARTIFACT_URL"

# --- Background, detached: notify + PR backfill ---
# `( cmd & ) >/dev/null 2>&1` reparents to init so these survive session exit.

if [ -n "$RECIPIENT" ]; then
  MODE=$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
  if [ -n "$ARTIFACT_URL" ]; then
    MSG="Handoff from $AUTHOR: $TOPIC

$DESCRIPTION

View: $ARTIFACT_URL"
  else
    MSG="Handoff from $AUTHOR: $TOPIC

$DESCRIPTION"
  fi

  if [ "$MODE" = "local" ]; then
    ( bash "$SCRIPT_DIR/bin/notify.sh" group "$MSG" >/dev/null 2>&1 & ) >/dev/null 2>&1
  else
    ( bash "$SCRIPT_DIR/bin/notify.sh" send "$RECIPIENT" "$MSG" >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
fi

# PR-number backfill (connected mode only; requires gh auth).
# Reads ## Repo State table from the handoff file, looks up each repo's
# open PR number, rewrites `—` → `#N` in the PR column. Detached.
if [ -n "$REPO_STATE" ] && command -v gh >/dev/null 2>&1; then
  (
    GITHUB_ORG=$(jq -r '.github_org // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
    [ -z "$GITHUB_ORG" ] && exit 0
    awk '/^## Repo State/,/^$/' "$HANDOFF_FILE" | awk -F'|' 'NR>3 && NF>=5 { gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); print $2"|"$3 }' | while IFS='|' read -r repo branch; do
      [ -z "$repo" ] || [ -z "$branch" ] && continue
      pr=$(gh pr list --repo "$GITHUB_ORG/$repo" --head "$branch" --json number --jq '.[0].number // empty' 2>/dev/null || echo "")
      [ -z "$pr" ] && continue
      # sed-in-place: replace `—` in the row matching this branch with `#N`
      awk -v branch="$branch" -v pr="#$pr" '
        BEGIN{FS=OFS="|"}
        /^## Repo State/,/^$/ {
          if ($0 ~ branch && $4 ~ /—/) { sub(/—/, pr, $4); gsub(/^ +| +$/,"",$4); $4=" "$4" " }
          print; next
        }
        { print }
      ' "$HANDOFF_FILE" > "$HANDOFF_FILE.tmp" && mv "$HANDOFF_FILE.tmp" "$HANDOFF_FILE"
    done
    # Re-commit + push the updated handoff file (memory repo).
    (
      cd memory 2>/dev/null || exit 0
      git add -A
      git commit -m "Backfill PR numbers for handoff: $TOPIC" >/dev/null 2>&1 || true
      git -c rebase.empty=drop pull --rebase origin main --quiet 2>/dev/null
      git push origin main --quiet 2>/dev/null
    )
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

exit 0
