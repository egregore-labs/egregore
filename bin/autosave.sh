#!/usr/bin/env bash
# autosave.sh — per-user autosave settings. The consent surface for ambient
# session capture (see bin/session-autosave.sh, docs/autosave.md).
#
# Settings live in .egregore-state.json (gitignored, personal — same pattern
# as the transcript_sharing consent flag):
#   autosave_enabled  true|false   ambient capture on/off        (default FALSE — opt-in experiment)
#   autosave_scope    all|handoffs what it touches               (default all)
#                     all      = memory repo + core-repo non-coding work
#                     handoffs = memory repo only; core repo never touched
#                                ambiently
#   autosave_publish  gate|auto    what happens to the PR        (default gate)
#                     gate = PR opened, merge waits for your explicit word
#                     auto = PR merged to develop automatically
#
# Usage:
#   autosave.sh status
#   autosave.sh on | off
#   autosave.sh scope all|handoffs
#   autosave.sh publish gate|auto
#   autosave.sh merge          # the consent act: merge YOUR staged auto-save PRs
#
# Exposed to Claude via the /autosave skill and to Codex/Pi via
# `bin/agent.sh autosave ...`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$SCRIPT_DIR/.egregore-state.json"

[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

# NB: jq's `//` swallows false — status would show "on" for enabled:false.
# Test key presence instead.
get() {
  local v
  v=$(jq -r "if ($1 != null) then ($1|tostring) else empty end" "$STATE_FILE" 2>/dev/null)
  [ -n "$v" ] && echo "$v" || echo "$2"
}

set_key() { # key value(json-encoded)
  jq ".$1 = $2" "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

status() {
  local enabled scope publish
  enabled=$(get '.autosave_enabled' 'false')
  scope=$(get '.autosave_scope' 'all')
  publish=$(get '.autosave_publish' 'gate')
  echo "autosave: $([ "$enabled" = "true" ] && echo on || echo "off (opt-in — 'autosave on' to join the experiment)")"
  echo "scope:    $scope  (all = handoffs + artifacts + docs · handoffs = memory repo only)"
  echo "publish:  $publish  (gate = PRs wait for your merge · auto = merge to develop automatically)"
}

case "${1:-status}" in
  status) status ;;
  on)  set_key autosave_enabled true  && echo "autosave: on" ;;
  off) set_key autosave_enabled false && echo "autosave: off — nothing is captured ambiently; /save and /handoff still work" ;;
  scope)
    case "${2:-}" in
      all|handoffs) set_key autosave_scope "\"$2\"" && echo "scope: $2" ;;
      *) echo "usage: autosave.sh scope all|handoffs" >&2; exit 2 ;;
    esac ;;
  publish)
    case "${2:-}" in
      gate|auto) set_key autosave_publish "\"$2\"" && echo "publish: $2" ;;
      *) echo "usage: autosave.sh publish gate|auto" >&2; exit 2 ;;
    esac ;;
  merge)
    # The consent act under publish=gate: merge this user's own staged
    # Auto-save PRs. Never touches anyone else's.
    command -v gh >/dev/null 2>&1 || { echo "gh not available" >&2; exit 1; }
    GH_SELF=$(get '.github_username' '')
    [ -n "$GH_SELF" ] || { echo "no github_username in .egregore-state.json" >&2; exit 1; }
    PRS=$(gh pr list --state open --author "$GH_SELF" --limit 20 \
      --json number,title --jq '.[] | select(.title | startswith("Auto-save:")) | .number' 2>/dev/null)
    [ -n "$PRS" ] || { echo "no auto-saves waiting"; exit 0; }
    for n in $PRS; do
      if gh pr merge "$n" --merge >/dev/null 2>&1; then
        echo "✓ merged auto-save PR #$n → develop"
      else
        echo "✗ PR #$n did not merge (conflict with develop?) — it stays open"
      fi
    done ;;
  *) echo "usage: autosave.sh [status|on|off|scope all|handoffs|publish gate|auto|merge]" >&2; exit 2 ;;
esac
