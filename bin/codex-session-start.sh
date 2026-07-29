#!/usr/bin/env bash
set -o pipefail

# Codex does not run Claude Code SessionStart hooks. This is the runtime-neutral
# startup card: it reuses the same identity, git sync, and context-gathering
# libraries as Claude's SessionStart, then renders a terminal greeting before
# Codex itself starts.

FRAMEWORK_VERSION="3"
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
source "$SCRIPT_DIR/bin/lib/context.sh" >/dev/null 2>/dev/null
trap 'rm -rf "${CTX_DIR:-}"' EXIT

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

shorten() {
  local value="$1"
  local max="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -nr --arg value "$value" --argjson max "$max" '
      $value
      | if length > $max then .[0:($max - 3)] + "..." else . end
    '
    return
  fi
  if [ "${#value}" -gt "$max" ]; then
    printf '%s...\n' "${value:0:$((max - 3))}"
  else
    printf '%s\n' "$value"
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

TEAM_DATA="$(cat "$CTX_DIR/team" 2>/dev/null || echo "[]")"
ADDRESSED_RICH="$(cat "$CTX_DIR/addressed_rich" 2>/dev/null || echo "[]")"
PENDING_Q="$(cat "$CTX_DIR/pending_questions" 2>/dev/null || echo "[]")"
LAST_ACTIVITY="$(cat "$CTX_DIR/activity" 2>/dev/null || true)"
ADDRESSED_COUNT="$(echo "$ADDRESSED_RICH" | jq 'length' 2>/dev/null || echo "0")"
PENDING_Q_COUNT="$(echo "$PENDING_Q" | jq 'length' 2>/dev/null || echo "0")"

render_for_you_summary() {
  if [ "$PENDING_Q_COUNT" -gt 0 ] 2>/dev/null; then
    local senders noun
    senders="$(echo "$PENDING_Q" | jq -r '[.[].from] | unique | join(", ")' 2>/dev/null)"
    [ "$PENDING_Q_COUNT" = "1" ] && noun="question" || noun="questions"
    if [ -n "$senders" ]; then
      printf '  ◐ %s pending %s from %s - bin/agent.sh answer\n' "$PENDING_Q_COUNT" "$noun" "$senders"
    else
      printf '  ◐ %s pending %s - bin/agent.sh answer\n' "$PENDING_Q_COUNT" "$noun"
    fi
  elif [ "$ADDRESSED_COUNT" -gt 0 ] 2>/dev/null; then
    printf '  ◇ %s handoffs for %s - bin/agent.sh activity --for %s\n' "$ADDRESSED_COUNT" "$AUTHOR" "$AUTHOR"
  else
    printf '  ◇ nothing pending for %s\n' "$AUTHOR"
  fi
}

render_handoff_rows() {
  if [ "$ADDRESSED_COUNT" -gt 0 ] 2>/dev/null; then
    echo "$ADDRESSED_RICH" | jq -r '.[] | [.author, .date, .topic] | @tsv' 2>/dev/null | head -4 | while IFS=$'\t' read -r author date topic; do
      [ -z "$author" ] && continue
      printf '  ○ %-10s%-12s%s\n' "$(shorten "$author" 9)" "$date" "$(shorten "$topic" 40)"
    done
  elif [ -n "$LAST_ACTIVITY" ]; then
    local last_when last_msg
    last_when="$(printf '%s\n' "$LAST_ACTIVITY" | cut -d'|' -f1 | sed 's/ hours\{0,1\} ago/h ago/; s/ days\{0,1\} ago/d ago/; s/ minutes\{0,1\} ago/m ago/')"
    last_msg="$(printf '%s\n' "$LAST_ACTIVITY" | cut -d'|' -f2-)"
    printf '  ◇ %-10s%-12s%s\n' "you" "$last_when" "$(shorten "$last_msg" 40)"
  fi
}

render_team_rows() {
  local now_render online_threshold
  now_render=$(date +%s)
  online_threshold=7200
  echo "$TEAM_DATA" | jq -r '.[] | [.name, .last_seen_sort, .last_seen, (.branches | join(", "))] | @tsv' 2>/dev/null | head -4 | while IFS=$'\t' read -r name epoch seen branches; do
    [ -z "$name" ] && continue
    local dot
    if [ "$epoch" -gt 0 ] 2>/dev/null && [ $((now_render - epoch)) -lt "$online_threshold" ] 2>/dev/null; then
      dot="●"
    else
      dot="○"
    fi
    printf '  %s %-10s%-12s%s\n' "$dot" "$(shorten "$name" 9)" "$seen" "$(shorten "$branches" 40)"
  done
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
  printf '  ◦ for you\n'
  render_for_you_summary
  render_handoff_rows
  printf '\n'
  printf '  ◦ around\n'
  render_team_rows
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

  if [ -n "$SLUG" ]; then
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
