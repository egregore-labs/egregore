#!/usr/bin/env bash
set -o pipefail

# Codex does not run Claude Code SessionStart hooks. This is the runtime-neutral
# startup card: it reuses the same identity, git sync, and context-gathering
# libraries as Claude's SessionStart, then renders a terminal greeting before
# Codex itself starts.

FRAMEWORK_VERSION="7"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR" || exit 1

IS_WORKTREE="false"
MAIN_PROJECT_DIR="$SCRIPT_DIR"
if [ -f "$SCRIPT_DIR/.git" ]; then
  IS_WORKTREE="true"
  WT_GITDIR=$(sed 's/^gitdir: //' "$SCRIPT_DIR/.git" 2>/dev/null)
  MAIN_PROJECT_DIR=$(cd "$WT_GITDIR/../../.." 2>/dev/null && pwd)
fi

# Clear any branch-guard consent from a previous session — consent to write on
# a protected branch is asked fresh each session (see AGENTS.md branch-guard protocol).
rm -f "$SCRIPT_DIR/.egregore-branch-consent" "$MAIN_PROJECT_DIR/.egregore-branch-consent" 2>/dev/null
# Same for boundary-crossing consent — grants are session-scoped (AGENTS.md
# environment-isolation protocol); durable grants belong in .egregore-boundary.local.json.
rm -f "$SCRIPT_DIR/.egregore-boundary-consent" "$MAIN_PROJECT_DIR/.egregore-boundary-consent" 2>/dev/null

if [ -f "$SCRIPT_DIR/bin/lib/worktree-links.sh" ]; then
  source "$SCRIPT_DIR/bin/lib/worktree-links.sh" >/dev/null 2>/dev/null || true
  egregore_link_shared_state "$SCRIPT_DIR" "$MAIN_PROJECT_DIR" >/dev/null 2>/dev/null || true
fi

HEALTH_GITHUB="skip"
HEALTH_GIT="skip"
HEALTH_APIKEY="skip"
HEALTH_GRAPH="skip"
HEALTH_TELEGRAM="skip"

STATE_FILE="$SCRIPT_DIR/.egregore-state.json"
ENV_FILE="$SCRIPT_DIR/.env"
CONFIG="$SCRIPT_DIR/egregore.json"
DATE=$(date +%Y-%m-%d)

source "$SCRIPT_DIR/bin/lib/config.sh"
source "$SCRIPT_DIR/bin/lib/hash.sh"
source "$SCRIPT_DIR/bin/lib/time.sh"
source "$SCRIPT_DIR/bin/lib/identity.sh" >/dev/null 2>/dev/null

# Keep the durable local identity current before gathering context, then project
# it to Supabase + Neo4j in the background so startup is never network-blocked.
if [ -f "$STATE_FILE" ] && [ -f "$SCRIPT_DIR/bin/person.py" ]; then
  python3 "$SCRIPT_DIR/bin/person.py" sync-local >/dev/null 2>&1 || true
fi
if [ -f "$SCRIPT_DIR/bin/person.sh" ]; then
  ( bash "$SCRIPT_DIR/bin/person.sh" sync >/dev/null 2>&1 & ) 2>/dev/null
fi

LOCAL_MODE="false"
[ "$(_detect_mode)" = "local" ] && LOCAL_MODE="true"
MODE_BADGE="$(_runtime_mode_badge)"

if [ "$LOCAL_MODE" != "true" ]; then
  if [ -f "$ENV_FILE" ] && grep -q '^EGREGORE_API_KEY=.' "$ENV_FILE" 2>/dev/null; then
    HEALTH_APIKEY="ok"
  else
    HEALTH_APIKEY="fail"
  fi
fi

source "$SCRIPT_DIR/bin/lib/git-sync.sh" >/dev/null 2>/dev/null
# Warm-state parity with the Claude SessionStart path: hand context.sh the
# pre-baked snapshot and route greeting reads through the warm graph cache.
# The attendant daemon is deliberately NOT started from the Codex/Pi path —
# its session-liveness check reads Claude transcripts only, so a live Codex
# or Pi session with 12 quiet minutes would look idle and its sweep would
# run mid-work. Codex sessions still benefit from
# any snapshot a Claude session's attendant maintains; runtime-neutral
# liveness tracking is the prerequisite for starting the daemon here.
if [ -n "${_ATT_KEY:-}" ]; then
  export CTX_SEED_TAR="${ATTENDANT_HOME:-$HOME/.egregore/attendant}/${_ATT_KEY}.ctx.tar"
fi
export EGREGORE_GRAPH_CACHE_TTL=600
source "$SCRIPT_DIR/bin/lib/context.sh" >/dev/null 2>/dev/null
unset EGREGORE_GRAPH_CACHE_TTL CTX_SEED_TAR
source "$SCRIPT_DIR/bin/lib/metrics.sh" >/dev/null 2>/dev/null
trap 'rm -rf "${CTX_DIR:-}"' EXIT

# Rescue non-coding leftovers from sessions that died without ceremony
# (terminal closed). Gated + idle-guarded inside the script; fire-and-forget.
( bash "$SCRIPT_DIR/bin/session-autosave.sh" --sweep >/dev/null 2>&1 & ) 2>/dev/null

# Connected instances pick up newly released Connect skills without
# re-running the launcher. Local mode exits instantly inside the script.
# Pi shares this path (pi-session-start.sh delegates here).
( bash "$SCRIPT_DIR/bin/connect-refresh.sh" >/dev/null 2>&1 & ) 2>/dev/null

read_json() {
  local file="$1"
  local expr="$2"
  local fallback="${3:-}"
  if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
    jq -r "$expr // empty" "$file" 2>/dev/null | head -1
  else
    printf '%s\n' "$fallback"
  fi
}

ORG_NAME="$(read_json "$CONFIG" '.org_name' '')"
[ -z "$ORG_NAME" ] && ORG_NAME="$(read_json "$CONFIG" '.slug' 'Egregore')"
GITHUB_ORG="$(read_json "$CONFIG" '.github_org' '')"
REPO_NAME="$(read_json "$CONFIG" '.repo_name' 'egregore')"
SLUG="$(read_json "$CONFIG" '.slug' '')"
DISPLAY_NAME="$(read_json "$STATE_FILE" '.display_name' '')"
[ -z "$DISPLAY_NAME" ] && DISPLAY_NAME="${DISPLAY_NAME_STATE:-$AUTHOR}"
ONBOARDING_COMPLETE="$(read_json "$STATE_FILE" '.onboarding_complete' '')"
[ -z "$ONBOARDING_COMPLETE" ] && ONBOARDING_COMPLETE="unknown"

ADDRESSED_RICH="$(cat "$CTX_DIR/addressed_rich" 2>/dev/null || echo "[]")"
PENDING_Q="$(cat "$CTX_DIR/pending_questions" 2>/dev/null || echo "[]")"
ADDRESSED_COUNT="$(echo "$ADDRESSED_RICH" | jq 'length' 2>/dev/null || echo "0")"
PENDING_Q_COUNT="$(echo "$PENDING_Q" | jq 'length' 2>/dev/null || echo "0")"

render_pending_line() {
  if [ "$PENDING_Q_COUNT" -gt 0 ] 2>/dev/null; then
    local senders noun
    senders="$(echo "$PENDING_Q" | jq -r '[.[].from] | unique | join(", ")' 2>/dev/null)"
    [ "$PENDING_Q_COUNT" = "1" ] && noun="question" || noun="questions"
    if [ -n "$senders" ]; then
      printf '  ◐ %s pending %s from %s - bin/agent.sh answer\n' "$PENDING_Q_COUNT" "$noun" "$senders"
    else
      printf '  ◐ %s pending %s - bin/agent.sh answer\n' "$PENDING_Q_COUNT" "$noun"
    fi
  fi
  if [ "$ADDRESSED_COUNT" -gt 0 ] 2>/dev/null; then
    printf '  ◇ %s handoffs for %s - say "show my handoffs" to review or close\n' "$ADDRESSED_COUNT" "$AUTHOR"
  fi
}

banner() {
  cat <<'EOF'

  ███████╗ ██████╗ ██████╗ ███████╗ ██████╗  ██████╗ ██████╗ ███████╗
  ██╔════╝██╔════╝ ██╔══██╗██╔════╝██╔════╝ ██╔═══██╗██╔══██╗██╔════╝
  █████╗  ██║  ███╗██████╔╝█████╗  ██║  ███╗██║   ██║██████╔╝█████╗
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║   ██║██║   ██║██╔══██╗██╔══╝
  ███████╗╚██████╔╝██║  ██║███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗
  ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚══════╝

EOF
}

render_card() {
  local separator identity_left identity_right line_width pad footer_left footer_right board_url has_failure failed_services
  separator="  ..................................................................."
  identity_left="  ${GITHUB_ORG:-$ORG_NAME}/${REPO_NAME} · ${MODE_BADGE}"
  identity_right="${DISPLAY_NAME} · ${BRANCH:-?}"
  line_width=67
  pad=$((line_width - ${#identity_left} - ${#identity_right}))
  [ "$pad" -lt 1 ] && pad=1

  banner
  printf '%s%*s%s\n' "$identity_left" "$pad" "" "$identity_right"
  printf '%s\n' "$separator"
  SEPARATOR="$separator" LINE_WIDTH=$line_width _render_momentum_board
  render_pending_line
  printf '%s\n' "$separator"

  has_failure="false"
  failed_services=""
  for pair in "github:$HEALTH_GITHUB" "git:$HEALTH_GIT" "api-key:$HEALTH_APIKEY" "graph:$HEALTH_GRAPH" "telegram:$HEALTH_TELEGRAM"; do
    svc="${pair%%:*}"
    svc_status="${pair#*:}"
    if [ "$svc_status" = "fail" ]; then
      has_failure="true"
      failed_services="${failed_services} ${svc} ✗"
    fi
  done

  if [ "$has_failure" = "true" ]; then
    printf '  ⚠%s\n' "$failed_services"
  else
    footer_left="  ✓ ready"
    if [ "${MEMORY_SYNCED:-false}" = "true" ]; then
      footer_right="◆ memory synced"
    else
      footer_right="◆ memory not synced"
    fi
    pad=$((line_width - ${#footer_left} - ${#footer_right}))
    [ "$pad" -lt 1 ] && pad=1
    printf '%s%*s%s\n' "$footer_left" "$pad" "" "$footer_right"
  fi

  # Autosave trail — background saves since the last greeting (same ledger
  # the Claude greeting reads; sweep rescues become visible here).
  autosave_log="${EGREGORE_AUTOSAVE_LOG:-$HOME/.egregore/autosave.log}"
  autosave_seen="${autosave_log}.seen"
  if [ -f "$autosave_log" ]; then
    total_as=$(grep -c '|autosave|' "$autosave_log" 2>/dev/null || echo 0)
    seen_as=$(cat "$autosave_seen" 2>/dev/null || echo 0)
    case "$seen_as" in ''|*[!0-9]*) seen_as=0 ;; esac
    if [ "$total_as" -gt "$seen_as" ]; then
      new_as=$((total_as - seen_as))
      merged_as=$(grep '|autosave|' "$autosave_log" 2>/dev/null | tail -n "$new_as" | grep -c '|merged|' || echo 0)
      if [ "$merged_as" -gt 0 ]; then
        printf '  ⟲ auto-saved %s non-coding save(s) → develop while you were away\n' "$merged_as"
      fi
    fi
    printf '%s' "$total_as" > "$autosave_seen" 2>/dev/null || true
  fi

  # Staged auto-saves awaiting the user's merge (the autosave consent gate).
  # Live gh query so the line persists until the PRs actually merge.
  # Shown only while the autosave experiment is enabled.
  autosave_on=$(jq -r '.autosave_enabled // false' "$STATE_FILE" 2>/dev/null)
  if [ "$autosave_on" = "true" ] && command -v gh >/dev/null 2>&1; then
    gh_self=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null)
    if [ -n "$gh_self" ]; then
      waiting_as=$(gh pr list --state open --author "$gh_self" --limit 20 \
        --json number,title --jq '[.[] | select(.title | startswith("Auto-save:")) | .number] | join(", #")' 2>/dev/null || true)
      if [ -n "$waiting_as" ]; then
        printf '  ⟲ auto-saves awaiting your merge: PR #%s — \$autosave merge (or bin/agent.sh autosave merge)\n' "$waiting_as"
      fi
    fi
  fi

  # Greeting links. Org config `pinned_links` in egregore.json replaces the
  # default board link — same contract as bin/lib/greeting.sh.
  pinned_links=$(jq -c '.pinned_links // []' "$CONFIG" 2>/dev/null || echo "[]")
  if [ "$(printf '%s' "$pinned_links" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    printf '%s' "$pinned_links" | jq -r '.[] |
      if type == "string" then "  ◆ \(.)"
      elif (.label // "") != "" then "  ◆ \(.label): \(.url)"
      else "  ◆ \(.url)" end' 2>/dev/null
  elif [ -n "$SLUG" ]; then
    board_url="https://egregore.xyz/view/${SLUG}/board"
    printf '  ◆ %s\n' "$board_url"
  fi
  printf '\nWhat are you working on?\n'
}

case "${1:---card}" in
  --card|card)
    render_card
    ;;
  --prompt|prompt)
    cat <<EOF
You are Codex running inside Egregore for ${ORG_NAME} as ${AUTHOR}.
The launcher already rendered the Egregore startup card using the shared identity, git-sync, graph, and filesystem context pipeline.
This session is Trusted Codex: full shell/network access is enabled and approval prompts are disabled by the launcher.
Do not rerun startup checks or narrate startup unless the user asks.
Follow AGENTS.md before code changes.
After the user names what they are working on, use bin/agent.sh branch --topic "<work topic>" if you are not already in an appropriate task worktree, then continue file work from the printed worktree path.
Use bin/agent.sh to update shared activity: handoff, ask, and answer write to memory/ and push when possible.
Use bin/agent.sh handoff for internal team session-handoffs. Portable external capsules are emissaries; use egregore-emissary when installed, not the deprecated egregore-handoff CLI.
Codex reserves leading slash commands for built-ins, so custom Egregore /activity-style commands will not reach the agent. Egregore native Codex skills are: \$activity, \$handoff, \$wrap, \$announce, \$harvest, \$the-spiral, \$dashboard, \$deep-reflect, \$quest, \$invite, \$ask, \$save, \$view, and \$scroll. Natural-language requests such as "show activity", "make a handoff", or "render this as a scroll" work too. Remaining mirrored workflows are adapter skills for long-tail coverage.
\$save is the user-facing abstraction for committing, pushing, opening or reusing pull requests, and syncing memory; do not make users manage the git workflow by hand.
Egregore Codex workflows are skill invocations, not Claude Code slash commands. Do not rely on Claude Code-only command machinery.
If onboarding_complete is false, use the memory protocol directly and make sure memory/people/${AUTHOR}.md exists before the first handoff.
EOF
    ;;
  *)
    echo "usage: bin/codex-session-start.sh [--card|--prompt]" >&2
    exit 2
    ;;
esac
