#!/usr/bin/env bash
# handoff-save-publish.sh — parallelise memory push + artifact publish; detach PR backfill.
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
#   - PR-number backfill into the handoff file's ## Repo State table (cosmetic)
#
# Notifications are intentionally absent. A detached process cannot obtain
# separate human consent for an exact external delivery.
#
# Exit code 0 only when both foreground operations succeed. A successfully
# published artifact URL is retained on stdout even if memory save is pending.

set -uo pipefail

HANDOFF_FILE="${1:-}"
TOPIC="${2:-}"
AUTHOR="${3:-}"
DESCRIPTION="${4:-}"
shift 4 2>/dev/null || true

REPO_STATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --recipient) shift 2;; # retained for caller compatibility; never notified here
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
  cd "$SCRIPT_DIR/memory" 2>/dev/null || exit 1
  git add -A || exit 1
  if ! git diff --cached --quiet; then
    git commit -m "chore(handoff): record $TOPIC" >/dev/null 2>&1 || exit 1
  fi
  for _ in 1 2 3; do
    if git pull --rebase origin main --quiet 2>/dev/null; then
      if bash "$SCRIPT_DIR/bin/memory-push.sh" --repository "$SCRIPT_DIR/memory" --branch main >/dev/null 2>&1; then
        exit 0
      else
        case "$?" in 75) ;; *) exit 1 ;; esac
      fi
    fi
    sleep 1
  done
  exit 1
) > "$SAVE_OUT" 2>&1 &
SAVE_PID=$!

(
  bash "$SCRIPT_DIR/bin/publish-artifact.sh" handoff "$HANDOFF_FILE" \
    --title "$TOPIC" \
    --author "$AUTHOR" \
    --description "$DESCRIPTION" 2>/dev/null
) > "$PUB_OUT" 2>&1 &
PUB_PID=$!

SAVE_STATUS=0
PUB_STATUS=0
wait "$SAVE_PID" || SAVE_STATUS=$?
wait "$PUB_PID" || PUB_STATUS=$?

if [ "$PUB_STATUS" -eq 0 ]; then
  ARTIFACT_URL=$(tail -1 "$PUB_OUT" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$ARTIFACT_URL" ]; then
    echo "$ARTIFACT_URL"
  else
    PUB_STATUS=1
  fi
fi
if [ "$SAVE_STATUS" -ne 0 ]; then
  echo "Memory save did not complete; local files are retained. Check memory sync before retrying the save." >&2
fi
if [ "$PUB_STATUS" -ne 0 ]; then
  echo "The handoff page could not be published. Retry page publication after checking the publishing service." >&2
fi
if [ "$SAVE_STATUS" -ne 0 ] || [ "$PUB_STATUS" -ne 0 ]; then
  exit 1
fi

# --- Background, detached: PR backfill only ---
# `( cmd & ) >/dev/null 2>&1` reparents to init so these survive session exit.

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
      cd "$SCRIPT_DIR/memory" 2>/dev/null || exit 1
      git add -A
      git commit -m "chore(handoff): backfill PR numbers for $TOPIC" >/dev/null 2>&1 || true
      git pull --rebase origin main --quiet 2>/dev/null
      bash "$SCRIPT_DIR/bin/memory-push.sh" --repository "$SCRIPT_DIR/memory" --branch main >/dev/null 2>&1
    )
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

exit 0
