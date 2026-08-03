#!/usr/bin/env bash
# session-autosave.sh — save non-coding session work without an explicit /save.
#
# Terminal-close is the design constraint: no single "session end" event is
# reliable (people just close the window), so durability comes from three
# overlapping triggers:
#   - Stop hook, debounced (Claude Code): saves DURING the session, after a
#     turn completes — a killed terminal loses at most the debounce window.
#   - Session-start sweep (--sweep, all runtimes): the next launch on this
#     machine rescues leftovers in the main checkout and lingering worktrees.
#   - SessionEnd hook / agent.sh wrap (Codex, Pi): immediate save on clean exit.
#
# Gate: acts ONLY when every pending change — uncommitted files AND commits
# ahead of origin/develop — is non-coding per bin/lib/noncode.sh. Any code in
# the pending set → exit silently; code always goes through explicit /save and
# review. Never auto-commits half-finished code.
#
# When the gate passes, delegates commit→push→PR→auto-merge to
# handoff-save-egregore.sh (--kind autosave), and pushes the memory repo.
#
# Usage:
#   session-autosave.sh [--dir <repo-dir>] [--author <name>]
#                       [--debounce <sec>] [--min-idle <sec>] [--sweep]
#   --debounce  skip if this dir was autosaved less than <sec> ago (Stop hook)
#   --min-idle  skip if any dirty file was modified less than <sec> ago
#               (don't commit prose someone is actively typing)
#   --sweep     iterate main checkout + .claude/worktrees/* (session start)
#   (Hook invocations pass nothing; stdin JSON supplies cwd.)

set -uo pipefail

DIR=""
AUTHOR=""
DEBOUNCE=0
MIN_IDLE=0
SWEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 ;;
    --author) AUTHOR="${2:-}"; shift 2 ;;
    --debounce) DEBOUNCE="${2:-0}"; shift 2 ;;
    --min-idle) MIN_IDLE="${2:-0}"; shift 2 ;;
    --sweep) SWEEP=1; shift ;;
    *) shift ;;
  esac
done

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Sweep mode: rescue abandoned checkouts, then exit -------------------
if [ "$SWEEP" = "1" ]; then
  # Let session-start's own git syncs settle before touching the checkout.
  sleep 15
  for d in "$SCRIPT_ROOT" "$SCRIPT_ROOT"/.claude/worktrees/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    # min-idle protects live sessions in other terminals: never commit files
    # someone touched in the last 10 minutes. debounce dedupes concurrent
    # session launches sweeping the same dirs.
    bash "$0" --dir "$d" --min-idle 600 --debounce 120 >/dev/null 2>&1 || true
  done
  exit 0
fi

# Hook invocations deliver JSON on stdin (cwd = where the session worked).
if [ -z "$DIR" ] && [ ! -t 0 ]; then
  HOOK_INPUT=$(cat 2>/dev/null || true)
  DIR=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
fi

[ -n "$DIR" ] && [ -d "$DIR" ] || DIR="$SCRIPT_ROOT"
cd "$DIR" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# --- Debounce (per-dir stamp) --------------------------------------------
# NB: `cmd | cut || fallback` doesn't work — cut succeeds on empty input, so
# the fallback never fires and every dir collapses to one stamp (macOS has
# md5, not md5sum). Group the hash commands, then cut.
DIR_HASH=$( { md5sum <<<"$DIR" 2>/dev/null || md5 -q -s "$DIR" 2>/dev/null || echo default; } | cut -c1-8 )
STAMP="/tmp/.egregore-autosave-${DIR_HASH}"
if [ "$DEBOUNCE" -gt 0 ] && [ -f "$STAMP" ]; then
  LAST=$(stat -f %m "$STAMP" 2>/dev/null || stat -c %Y "$STAMP" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - LAST )) -lt "$DEBOUNCE" ] && exit 0
fi
touch "$STAMP" 2>/dev/null || true

# shellcheck source=bin/lib/noncode.sh
. "$SCRIPT_ROOT/bin/lib/noncode.sh" 2>/dev/null || exit 0

# --- Per-user consent settings (bin/autosave.sh / the /autosave skill) ----
# enabled=false  → fully off, nothing captured ambiently
# scope=handoffs → memory repo only; the core repo is never touched ambiently
# publish=gate   → PR is opened but NEVER merged without the user's word
# NB: jq's `//` swallows false (falsy) — `.k // empty` on k:false yields the
# default, silently re-enabling autosave. Test key presence instead (this is
# the same trap that broke auto_update:false).
_as_conf() { # key default
  local v
  v=$(jq -r "if (.$1 != null) then (.$1|tostring) else empty end" "$DIR/.egregore-state.json" 2>/dev/null)
  [ -n "$v" ] || v=$(jq -r "if (.$1 != null) then (.$1|tostring) else empty end" "$SCRIPT_ROOT/.egregore-state.json" 2>/dev/null)
  [ -n "$v" ] && echo "$v" || echo "$2"
}
# Autosave is an opt-in experiment: enabled defaults to FALSE. Nothing is
# captured ambiently until the user runs `/autosave on` (or autosave.sh on).
AS_ENABLED=$(_as_conf autosave_enabled false)
AS_SCOPE=$(_as_conf autosave_scope all)
AS_PUBLISH=$(_as_conf autosave_publish gate)
[ "$AS_ENABLED" = "true" ] || exit 0

if [ -z "$AUTHOR" ]; then
  AUTHOR=$(jq -r '.github_username // .name // empty' "$DIR/.egregore-state.json" 2>/dev/null || true)
  [ -n "$AUTHOR" ] || AUTHOR=$(jq -r '.github_username // .name // empty' "$SCRIPT_ROOT/.egregore-state.json" 2>/dev/null || true)
  [ -n "$AUTHOR" ] || AUTHOR=$(git config user.name 2>/dev/null | tr '[:upper:] ' '[:lower:]-' || true)
  [ -n "$AUTHOR" ] || AUTHOR="egregore"
fi

# --- Memory repo: markdown by definition, push straight to main ----------
if git -C "$DIR/memory" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -n "$(git -C "$DIR/memory" status --porcelain 2>/dev/null)" ]; then
    git -C "$DIR/memory" add -A >/dev/null 2>&1 || true
    git -C "$DIR/memory" commit -m "Auto-save: session content" --quiet 2>/dev/null || true
  fi
  if [ -n "$(git -C "$DIR/memory" log origin/main..HEAD --oneline 2>/dev/null)" ]; then
    for _try in 1 2 3; do
      if git -C "$DIR/memory" pull --rebase origin main --quiet 2>/dev/null \
         && git -C "$DIR/memory" push origin main --quiet 2>/dev/null; then
        break
      fi
      sleep 1
    done
  fi
fi

# scope=handoffs: memory (above) is the handoff channel; stop before the
# core repo — it is never captured ambiently under this scope.
[ "$AS_SCOPE" = "handoffs" ] && exit 0

# --- Core repo gate: everything pending must be non-coding ---------------
# -uall expands untracked dirs to individual files: a collapsed "docs/" entry
# would defeat both the classifier (code nested under a content dir) and the
# idle guard (directory mtime, not file mtime).
DIRTY_PATHS=$(git status --porcelain -uall 2>/dev/null | cut -c4- | sed 's/.* -> //' | sed '/^$/d')
PENDING=$(
  {
    printf '%s\n' "$DIRTY_PATHS"
    git diff origin/develop...HEAD --name-only 2>/dev/null
  } | sed '/^$/d'
)
[ -n "$PENDING" ] || exit 0

BLOCKER=$(printf '%s\n' "$PENDING" | noncode_filter)
if [ -n "$BLOCKER" ]; then
  # Code in the pending set — leave it for an explicit /save + review.
  exit 0
fi

# --- Idle guard: don't commit files someone is actively editing ----------
if [ "$MIN_IDLE" -gt 0 ] && [ -n "$DIRTY_PATHS" ]; then
  NOW=$(date +%s)
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    M=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    [ $(( NOW - M )) -lt "$MIN_IDLE" ] && exit 0
  done <<< "$DIRTY_PATHS"
fi

ORIG_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

bash "$SCRIPT_ROOT/bin/handoff-save-egregore.sh" "$AUTHOR" \
  "session content $(date +%Y-%m-%d)" --kind autosave --repo-dir "$DIR" \
  --branch-suffix "$DIR_HASH" --publish "$AS_PUBLISH" \
  >/dev/null 2>&1 || true

# Tell the user what just happened. Under the Stop hook this line surfaces in
# the Claude Code UI; sweep/SessionEnd invocations discard stdout (their trail
# is the ledger, reported by the next greeting).
LEDGER="${EGREGORE_AUTOSAVE_LOG:-$HOME/.egregore/autosave.log}"
LAST=$(grep -F "|autosave|$DIR|" "$LEDGER" 2>/dev/null | tail -1 || true)
if [ -n "$LAST" ]; then
  TS=$(echo "$LAST" | cut -d'|' -f1)
  PR=$(echo "$LAST" | cut -d'|' -f5)
  RESULT=$(echo "$LAST" | cut -d'|' -f6)
  NF=$(echo "$LAST" | cut -d'|' -f7)
  NOW_EPOCH=$(date +%s)
  TS_EPOCH=$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$TS" +%s 2>/dev/null || date -u -d "$TS" +%s 2>/dev/null || echo 0)
  if [ $(( NOW_EPOCH - TS_EPOCH )) -lt 120 ]; then
    case "$RESULT" in
      merged) echo "⟲ auto-saved: $NF non-coding file(s) → develop (PR #$PR merged)" ;;
      staged) echo "⟲ auto-saved: $NF non-coding file(s) → PR #$PR — yours to merge (say \"merge my auto-saves\" or /autosave)" ;;
      open)   echo "⟲ auto-saved: $NF non-coding file(s) → PR #$PR (merge pending)" ;;
      *)      echo "⟲ auto-saved: $NF non-coding file(s) → branch pushed (PR pending)" ;;
    esac
  fi
fi

# The helper branches off protected branches before committing. If this
# checkout was on develop/main (e.g. the main checkout during a sweep),
# restore it so the next session doesn't land on a stray autosave branch.
case "$ORIG_BRANCH" in
  develop|main|master)
    CUR=$(git branch --show-current 2>/dev/null || echo "")
    if [ "$CUR" != "$ORIG_BRANCH" ]; then
      git checkout "$ORIG_BRANCH" --quiet 2>/dev/null || true
      git pull --ff-only origin "$ORIG_BRANCH" --quiet 2>/dev/null || true
    fi
    ;;
esac

exit 0
