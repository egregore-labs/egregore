# shellcheck shell=bash
# greeting.sh — Greeting output renderer for session-start.sh
#
# Renders the full session greeting:
#   - ASCII art banner
#   - Identity line (org/repo + user + branch)
#   - Momentum board (sessions, commits, handoffs, knowledge)
#   - Pending questions signal
#   - Health footer
#   - Alias migration
#   - Session context JSON (hidden, for Claude)
#   - Soul file inclusion
#   - Telemetry emit
#   - First session welcome
#
# Inputs:  SCRIPT_DIR, STATE_FILE, CONFIG, CTX_DIR, BRANCH, BASE_BRANCH, COMMITS_AHEAD,
#          AUTHOR, LOCAL_MODE, MEMORY_SYNCED, SAVED_BRANCH,
#          HEALTH_*, FRAMEWORK_VERSION, TIME_OF_DAY, EGREGORE_SESSION_ID,
#          FIRST_SESSION, DISPLAY_NAME_STATE, DASHBOARD_URL

# --- Output greeting for Claude to display ---
cat << 'GREETING'

  ███████╗ ██████╗ ██████╗ ███████╗ ██████╗  ██████╗ ██████╗ ███████╗
  ██╔════╝██╔════╝ ██╔══██╗██╔════╝██╔════╝ ██╔═══██╗██╔══██╗██╔════╝
  █████╗  ██║  ███╗██████╔╝█████╗  ██║  ███╗██║   ██║██████╔╝█████╗
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║   ██║██║   ██║██╔══██╗██╔══╝
  ███████╗╚██████╔╝██║  ██║███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗
  ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝

GREETING

# --- Ornamented status ---
REPO_NAME=$(jq -r '.repo_name // "egregore"' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
GITHUB_ORG_DISPLAY=$(jq -r '.github_org // ""' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
ORG_NAME=$(jq -r '.org_name // ""' "$SCRIPT_DIR/egregore.json" 2>/dev/null)

DISPLAY_NAME=""
if [ -f "$STATE_FILE" ]; then
  DISPLAY_NAME=$(jq -r '.display_name // .name // empty' "$STATE_FILE" 2>/dev/null)
fi
GREETING_NAME="${DISPLAY_NAME:-$AUTHOR}"

# --- Line 1: Org/Repo + User + Branch (primary info) ---
SEPARATOR="  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"

# Build identity line: Org/repo on left, user + branch on right
if [ "$LOCAL_MODE" = "true" ]; then
  IDENTITY_LEFT="  Egregore"
else
  IDENTITY_LEFT="  ${GITHUB_ORG_DISPLAY}/${REPO_NAME}"
fi
BRANCH_COMPACT="$BRANCH"
if [ "$COMMITS_AHEAD" -gt 0 ] 2>/dev/null; then
  BRANCH_COMPACT="${BRANCH} · ${COMMITS_AHEAD}↑"
fi
IDENTITY_RIGHT="${GREETING_NAME} · ${BRANCH_COMPACT}"
LINE_WIDTH=67
ID_LEFT_LEN=${#IDENTITY_LEFT}
ID_RIGHT_LEN=${#IDENTITY_RIGHT}
ID_PADDING=$((LINE_WIDTH - ID_LEFT_LEN - ID_RIGHT_LEN))
if [ "$ID_PADDING" -lt 1 ]; then ID_PADDING=1; fi
printf "\n%s%*s%s\n" "$IDENTITY_LEFT" "$ID_PADDING" "" "$IDENTITY_RIGHT"
echo "$SEPARATOR"

# --- Momentum board ---
source "$SCRIPT_DIR/bin/lib/metrics.sh"
_render_momentum_board

# Pending questions and handoffs addressed to you. These are lightweight
# discovery beats; management stays in /answer and /activity.
PENDING_Q=$(cat "$CTX_DIR/pending_questions" 2>/dev/null || echo "[]")
PENDING_Q_COUNT=$(echo "$PENDING_Q" | jq 'length' 2>/dev/null || echo "0")
if [ "$PENDING_Q_COUNT" -gt 0 ] 2>/dev/null && [ "$PENDING_Q_COUNT" != "0" ]; then
  PQ_SENDERS=$(echo "$PENDING_Q" | jq -r '[.[].from] | unique | join(", ")' 2>/dev/null)
  if [ "$PENDING_Q_COUNT" = "1" ]; then
    PQ_NOUN="question"
  else
    PQ_NOUN="questions"
  fi
  if [ -n "$PQ_SENDERS" ]; then
    printf "  ◐ %s pending %s from %s — /answer to engage\n" "$PENDING_Q_COUNT" "$PQ_NOUN" "$PQ_SENDERS"
  else
    printf "  ◐ %s pending %s — /answer to engage\n" "$PENDING_Q_COUNT" "$PQ_NOUN"
  fi
fi
ADDRESSED_RICH=$(cat "$CTX_DIR/addressed_rich" 2>/dev/null || echo "[]")
ADDRESSED_COUNT=$(echo "$ADDRESSED_RICH" | jq 'length' 2>/dev/null || echo "0")
if [ "$ADDRESSED_COUNT" -gt 0 ] 2>/dev/null; then
  printf "  ◇ %s handoffs for you — say \"show my handoffs\" to review or close\n" "$ADDRESSED_COUNT"
fi

# Show auto-save notice if work was committed from a previous branch
if [ -n "$SAVED_BRANCH" ]; then
  echo "  ✓ Auto-saved uncommitted work on $SAVED_BRANCH"
fi

# --- Footer: health + repos + memory (tertiary) ---
echo "$SEPARATOR"

# Build compact footer line
if [ "$LOCAL_MODE" = "true" ]; then
  # Local mode: only check github + git, skip api-key/graph/telegram
  HAS_FAILURE="false"
  FAILED_SERVICES=""
  for pair in "github:$HEALTH_GITHUB" "git:$HEALTH_GIT"; do
    svc="${pair%%:*}"
    svc_status="${pair#*:}"
    if [ "$svc_status" = "fail" ]; then
      HAS_FAILURE="true"
      FAILED_SERVICES="${FAILED_SERVICES} ${svc} ✗"
    fi
  done

  if [ "$HAS_FAILURE" = "true" ]; then
    echo "  ⚠${FAILED_SERVICES} — run /checkup"
  else
    if [ "${FRAMEWORK_UPDATED:-false}" = "true" ]; then
      printf "  ◆ updated\n"
    else
      printf "  ✓ ready\n"
    fi
  fi
else
  # Connected mode: check all services
  HAS_FAILURE="false"
  FAILED_SERVICES=""
  for pair in "github:$HEALTH_GITHUB" "git:$HEALTH_GIT" "api-key:$HEALTH_APIKEY" "graph:$HEALTH_GRAPH" "telegram:$HEALTH_TELEGRAM"; do
    svc="${pair%%:*}"
    svc_status="${pair#*:}"
    if [ "$svc_status" = "fail" ]; then
      HAS_FAILURE="true"
      FAILED_SERVICES="${FAILED_SERVICES} ${svc} ✗"
    fi
  done

  if [ "$HAS_FAILURE" = "true" ]; then
    echo "  ⚠${FAILED_SERVICES} — run /checkup"
  else
    # Compact footer: ready + memory on one line, repos on next if present
    FOOTER_LEFT="  ✓ ready"
    FOOTER_RIGHT=""
    if [ "$MEMORY_SYNCED" = "true" ]; then
      FOOTER_RIGHT="◆ memory synced"
    fi

    FL_LEN=${#FOOTER_LEFT}
    FR_LEN=${#FOOTER_RIGHT}
    F_PAD=$((LINE_WIDTH - FL_LEN - FR_LEN))
    if [ "$F_PAD" -lt 1 ]; then F_PAD=1; fi
    printf "%s%*s%s\n" "$FOOTER_LEFT" "$F_PAD" "" "$FOOTER_RIGHT"
  fi
fi

# Framework update trail — an auto-update overwrites every framework path from
# upstream, local edits included. It used to surface as the footer word
# "updated" in local mode and as nothing at all in connected mode, which is not
# enough notice for files being replaced under you. Name the count, name the
# first few, and point at the commit that did it.
if [ "${FRAMEWORK_UPDATED:-false}" = "true" ] && [ "${FRAMEWORK_UPDATED_COUNT:-0}" -gt 0 ]; then
  FU_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "")
  printf "  ◆ framework updated from upstream — %s file(s) replaced: %s\n" \
    "$FRAMEWORK_UPDATED_COUNT" "${FRAMEWORK_UPDATED_FILES% }"
  if [ -n "$FU_SHA" ]; then
    printf "    local edits to framework paths are replaced by design — git show %s\n" "$FU_SHA"
  fi
fi

# Autosave trail — background saves (Stop-hook, sweep, SessionEnd) since the
# last greeting. The ledger is machine-scoped; this is where sweep rescues of
# abandoned sessions become visible to the user.
AUTOSAVE_LOG="${EGREGORE_AUTOSAVE_LOG:-$HOME/.egregore/autosave.log}"
AUTOSAVE_SEEN="${AUTOSAVE_LOG}.seen"
if [ -f "$AUTOSAVE_LOG" ]; then
  TOTAL_AS=$(grep -c '|autosave|' "$AUTOSAVE_LOG" 2>/dev/null || echo 0)
  SEEN_AS=$(cat "$AUTOSAVE_SEEN" 2>/dev/null || echo 0)
  case "$SEEN_AS" in ''|*[!0-9]*) SEEN_AS=0 ;; esac
  if [ "$TOTAL_AS" -gt "$SEEN_AS" ]; then
    NEW_AS=$((TOTAL_AS - SEEN_AS))
    MERGED_AS=$(grep '|autosave|' "$AUTOSAVE_LOG" 2>/dev/null | tail -n "$NEW_AS" | grep -c '|merged|' || echo 0)
    if [ "$MERGED_AS" -gt 0 ]; then
      printf "  ⟲ auto-saved %s non-coding save(s) → develop while you were away\n" "$MERGED_AS"
    fi
  fi
  printf '%s' "$TOTAL_AS" > "$AUTOSAVE_SEEN" 2>/dev/null || true
fi

# Staged auto-saves awaiting the user's merge (the /autosave consent gate).
# Live gh query so the line persists until the PRs actually merge — the
# ledger cursor above only reports once. Fail-soft when gh/network is out.
# Shown only while the autosave experiment is enabled: stale PRs from a
# disabled experiment should not nag every greeting.
AUTOSAVE_ON=$(jq -r '.autosave_enabled // false' "$STATE_FILE" 2>/dev/null)
if [ "$AUTOSAVE_ON" = "true" ] && command -v gh >/dev/null 2>&1; then
  GH_SELF=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null)
  if [ -n "$GH_SELF" ]; then
    WAITING_AS=$(gh pr list --state open --author "$GH_SELF" --limit 20 \
      --json number,title --jq '[.[] | select(.title | startswith("Auto-save:")) | .number] | join(", #")' 2>/dev/null || true)
    if [ -n "$WAITING_AS" ]; then
      printf "  ⟲ auto-saves awaiting your merge: PR #%s — say \"merge my auto-saves\"\n" "$WAITING_AS"
    fi
  fi
fi

# Greeting links. Org config `pinned_links` in egregore.json replaces the
# default dashboard + board links. Entries are strings or {url, label}.
# (OSC 8 hyperlink — clickable text in supported terminals)
PINNED_LINKS=$(jq -c '.pinned_links // []' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "[]")
if [ "$(printf '%s' "$PINNED_LINKS" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
  printf '%s' "$PINNED_LINKS" | jq -r '.[] |
    if type == "string" then "  ◆ \(.)"
    elif (.label // "") != "" then "  ◆ \(.label): \(.url)"
    else "  ◆ \(.url)" end' 2>/dev/null
else
  if [ -n "${DASHBOARD_URL:-}" ]; then
    printf "  ◆ %s\n" "$DASHBOARD_URL"
  fi

  if [ -n "${BOARD_URL:-}" ]; then
    printf "  ◆ %s (board)\n" "$BOARD_URL"
  fi
fi

if [ -n "${LOOM_DOCTOR_BRIEF:-}" ]; then
  # Indent every line — printf '  %s' indents only the first line of a
  # multiline brief, which misaligns the card and hides follow-up warnings
  # from the fast-path signal-line scraper (it keys on "^  ").
  printf '%s\n' "$LOOM_DOCTOR_BRIEF" | sed 's/^/  /'
fi

# --- Creator review gate: pending turns on owned scrolls/surfaces ---
# This is deliberately filesystem-only and fail-soft. The two environment seams
# make the scan safe to exercise without touching the instance memory repo.
_print_pending_scroll_turns() {
  local memory_root="${EGREGORE_MEMORY_ROOT:-$SCRIPT_DIR/memory}"
  local person="${EGREGORE_PERSON:-${AUTHOR:-}}"
  local rows="" file slug owner count surface_file

  if [ -z "$person" ] && [ -f "${STATE_FILE:-}" ]; then
    person=$(jq -r '.github_username // .display_name // .name // empty' "$STATE_FILE" 2>/dev/null || true)
  fi
  [ -n "$person" ] || return 0
  [ -d "$memory_root" ] || return 0

  for file in "$memory_root"/scrolls/.events/*.jsonl; do
    [ -f "$file" ] || continue
    slug=$(basename "$file" .jsonl)
    [[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    safe_slug=$(printf '%s' "$slug" | tr -d '\000-\037\177')
    [ "$safe_slug" = "$slug" ] || continue
    owner=$(sed -nE 's/^[[:space:]-]*(\*\*)?creator(\*\*)?[[:space:]]*:[[:space:]]*//p' "$memory_root/scrolls/$slug.md" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
    [ "$owner" = "$person" ] || continue
    count=$(jq -s -r '
      def event_id:
        if (.turn | type) == "object" then .turn.id
        elif (.turn | type) == "string" then .turn
        else .id end;
      def received($events):
        [$events[] | select(.type == "turn-received")
          | {id: event_id, answers: (.turn.answers // .answers // [])}
          | select(.id != null)] | unique_by(.id);
      def review_id: event_id;
      def is_absorbed($events; $id):
        any($events[]; .type == "version-published" and ((.absorbs // .version.absorbs // .record.absorbs // []) | index($id) != null));
      def is_applied($events; $id):
        any($events[]; .type == "turn-applied" and (event_id == $id));
      def is_declined($events; $received; $id):
        ([$received[] | select(.id == $id)] | .[0]) as $turn |
        ([$events[] | select(.type == "turn-reviewed" and review_id == $id)] | .[0]) as $review |
        if $review == null then false
        else if (($turn.answers // []) | length) == 0 then $review.disposition == "declined"
        else (($turn.answers // [])
          | map(($review.answers // {})[.fork] // $review.disposition)
          | map(select(. == "accepted")) | length) == 0
        end
        end;
      . as $events
      | ($events | received($events)) as $received
      | [$received[] as $turn
          | select((is_absorbed($events; $turn.id) | not))
          | select((is_declined($events; $received; $turn.id) | not))
          | select(if $mode == "scroll" then true else (is_applied($events; $turn.id) | not) end)]
      | length
    ' --arg mode scroll "$file" 2>/dev/null) || continue
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    [ "$count" -gt 0 ] && rows+="${safe_slug}"$'\t'"${count}"$'\n'
  done

  for file in "$memory_root"/harvests/.events/*.jsonl; do
    [ -f "$file" ] || continue
    slug=$(basename "$file" .jsonl)
    [[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    safe_slug=$(printf '%s' "$slug" | tr -d '\000-\037\177')
    [ "$safe_slug" = "$slug" ] || continue
    surface_file="$memory_root/harvests/$slug.json"
    [ -f "$surface_file" ] || continue
    owner=$(jq -r '.author // empty' "$surface_file" 2>/dev/null) || continue
    [ "$owner" = "$person" ] || continue
    count=$(jq -s -r '
      def event_id:
        if (.turn | type) == "object" then .turn.id
        elif (.turn | type) == "string" then .turn
        else .id end;
      def received($events):
        [$events[] | select(.type == "turn-received")
          | {id: event_id, answers: (.turn.answers // .answers // [])}
          | select(.id != null)] | unique_by(.id);
      def review_id: event_id;
      def is_absorbed($events; $id): false;
      def is_applied($events; $id):
        any($events[]; .type == "turn-applied" and (event_id == $id));
      def is_declined($events; $received; $id):
        ([$received[] | select(.id == $id)] | .[0]) as $turn |
        ([$events[] | select(.type == "turn-reviewed" and review_id == $id)] | .[0]) as $review |
        if $review == null then false
        else if (($turn.answers // []) | length) == 0 then $review.disposition == "declined"
        else (($turn.answers // [])
          | map(($review.answers // {})[.fork] // $review.disposition)
          | map(select(. == "accepted")) | length) == 0
        end
        end;
      . as $events
      | ($events | received($events)) as $received
      | [$received[] as $turn
          | select((is_applied($events; $turn.id) | not))
          | select((is_declined($events; $received; $turn.id) | not))]
      | length
    ' --arg mode harvest "$file" 2>/dev/null) || continue
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    [ "$count" -gt 0 ] && rows+="${safe_slug}"$'\t'"${count}"$'\n'
  done

  [ -n "$rows" ] || return 0
  local summary total details
  summary=$(printf '%s' "$rows" | awk -F '\t' 'NF == 2 { totals[$1] += $2 } END { for (slug in totals) print slug "\t" totals[slug] }' | sort -t $'\t' -k1,1) || return 0
  [ -n "$summary" ] || return 0
  total=$(printf '%s\n' "$summary" | awk -F '\t' '{ total += $2 } END { print total + 0 }') || return 0
  details=$(printf '%s\n' "$summary" | awk -F '\t' '{printf "%s%s (%s)", (NR == 1 ? "" : ", "), $1, $2}') || return 0
  [ -n "$details" ] || return 0
  printf "  ⧖ %s pending turn(s) on your scrolls: %s\n" "$total" "$details"
}

_print_pending_scroll_turns

# Framework updates come through PRs to develop — no separate auto-update channel.
# The develop sync above already keeps framework files current.
# Use /update for manual upstream pulls when needed.

# --- One-time migration: fix aliases to use 'claude "start"' ---
# v1: 'claude start' → 'claude' (cross-instance bug)
# v2: 'claude' → 'claude "start"' (blank prompt — auto-sends first message)
ALIAS_VERSION=$(jq -r '.alias_version // 0' "$STATE_FILE" 2>/dev/null || echo "0")
if [ "$ALIAS_VERSION" -lt 2 ] 2>/dev/null; then
  for profile in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ -f "$profile" ] && grep -q "$SCRIPT_DIR" "$profile" 2>/dev/null; then
      # Replace any egregore alias pointing to this directory with the correct command
      # Handles: && claude start, && claude, && claude "start" (idempotent)
      sed -i.bak "s|&& claude start|\\&\\& claude \"start\"|g; s|&& claude'|\\&\\& claude \"start\"'|g" "$profile" 2>/dev/null && rm -f "${profile}.bak" || true
    fi
  done
  if [ -f "$STATE_FILE" ] && jq . "$STATE_FILE" >/dev/null 2>&1; then
    jq '. + {"alias_fixed": true, "alias_version": 2}' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
fi

echo ""

# --- Session context (hidden, for Claude) ---
CONTEXT_HANDOFFS=$(cat "$CTX_DIR/handoffs" 2>/dev/null || echo "[]")
CONTEXT_HANDOFFS=$(printf '%s' "$CONTEXT_HANDOFFS" | jq -c 'map(if .preview then .preview |= .[0:80] else . end)' 2>/dev/null || printf '%s' "$CONTEXT_HANDOFFS")
CONTEXT_ADDRESSED=$(cat "$CTX_DIR/addressed" 2>/dev/null || echo "[]")
CONTEXT_QUESTS=$(cat "$CTX_DIR/quests" 2>/dev/null || echo "[]")
CONTEXT_QUESTS=$(printf '%s' "$CONTEXT_QUESTS" | jq -c 'if length > 20 then .[0:20] + ["+\(length - 20) more"] else . end' 2>/dev/null || printf '%s' "$CONTEXT_QUESTS")
CONTEXT_ACTIVITY=$(cat "$CTX_DIR/activity" 2>/dev/null || echo "")
CONTEXT_TEAM=$(cat "$CTX_DIR/team" 2>/dev/null || echo "[]")
# Trim the team blob for greeting injection: 8 most-recent people, drop sort
# keys, one branch each. This trimmed view is all the session ever sees —
# CTX_DIR is deleted at the end of this script — a deliberate cap to keep
# hook stdout inline-sized. Untrimmed this is the single largest field in
# session-context.
CONTEXT_TEAM=$(printf '%s' "$CONTEXT_TEAM" | jq -c '.[0:8] | map({name, last_seen, working_on: ((.working_on // "")[0:80]), branches: ((.branches // [])[0:1])})' 2>/dev/null || printf '%s' "$CONTEXT_TEAM")
CONTEXT_SOUL=$(cat "$CTX_DIR/soul_summary" 2>/dev/null || echo "")
CONTEXT_LIFECYCLE=$(cat "$CTX_DIR/lifecycle" 2>/dev/null || echo '{"merged_prs":[],"implemented_handoffs":[]}')
CONTEXT_PULSE=$(cat "$CTX_DIR/pulse_brief" 2>/dev/null || echo '{}')
if [ -f "$CTX_DIR/metrics" ]; then
  CONTEXT_METRICS=$(jq -c . "$CTX_DIR/metrics" 2>/dev/null || echo "{}")
  [ -n "$CONTEXT_METRICS" ] || CONTEXT_METRICS="{}"
else
  CONTEXT_METRICS="{}"
fi

# --- Write compact subagent context cache (reuses already-gathered data) ---
SUBAGENT_CTX="/tmp/egregore-subagent-ctx-${EGREGORE_SESSION_ID}.txt"
(
  SA_ORG_NAME=$(jq -r '.org_name // "Unknown"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "Unknown")
  SA_GITHUB_ORG=$(jq -r '.github_org // "unknown"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "unknown")

  # Format quests list
  SA_QUESTS="none"
  if [ "$CONTEXT_QUESTS" != "[]" ]; then
    SA_QUESTS=$(echo "$CONTEXT_QUESTS" | jq -r '.[]' 2>/dev/null | paste -sd', ' - 2>/dev/null || echo "none")
  fi

  # Format recent handoffs
  SA_HANDOFFS="none"
  if [ "$CONTEXT_HANDOFFS" != "[]" ]; then
    SA_HANDOFFS=$(echo "$CONTEXT_HANDOFFS" | jq -r '.[] | .name' 2>/dev/null | head -5 | paste -sd', ' - 2>/dev/null || echo "none")
  fi

  cat > "$SUBAGENT_CTX" << SAEOF
<!-- egregore-context
Organization: $SA_ORG_NAME (github: $SA_GITHUB_ORG)
Session: $BRANCH — ${EGREGORE_SESSION_ID}
Active quests: $SA_QUESTS
Recent handoffs: $SA_HANDOFFS
Memory: memory/ is a symlink to shared knowledge base. Use bin/graph.sh for Neo4j queries.
-->
SAEOF
) 2>/dev/null || true

# Emit the context JSON compacted (jq -c) — nested blobs arrive pretty-printed
# from CTX_DIR and the whitespace alone is ~1KB of hook stdout. Fall back to
# the raw heredoc if jq can't parse (a malformed fragment must not eat context).
_CTX_JSON=$(cat << CTXEOF
{
  "framework_version": "$FRAMEWORK_VERSION",
  "time_of_day": "$TIME_OF_DAY",
  "dashboard_url": "${DASHBOARD_URL:-}",
  "recent_handoffs": $CONTEXT_HANDOFFS,
  "addressed_to_user": $CONTEXT_ADDRESSED,
  "quests": $CONTEXT_QUESTS,
  "last_user_activity": "$CONTEXT_ACTIVITY",
  "team_recent_memory": $CONTEXT_TEAM,
  "soul_self_summary": "$CONTEXT_SOUL",
  "lifecycle": $CONTEXT_LIFECYCLE,
  "momentum": $CONTEXT_METRICS,
  "pulse": $CONTEXT_PULSE
}
CTXEOF
)
printf '\n<!-- session-context\n%s\n-->\n' \
  "$(printf '%s' "$_CTX_JSON" | jq -c . 2>/dev/null || printf '%s' "$_CTX_JSON")"

# Include soul file if present
if [ -f "$SCRIPT_DIR/egregore.md" ]; then
  echo ""
  echo "<!-- egregore-soul"
  cat "$SCRIPT_DIR/egregore.md"
  echo "-->"
fi

# Point at the latest soul reflection instead of inlining it. The full
# document is several KB; injected verbatim it pushed hook stdout past the
# harness inline threshold, which turns the greeting into a file the model
# must Read back — a whole extra API round-trip on every boot.
if [ -d "$SCRIPT_DIR/memory/soul" ]; then
  LATEST_REFLECTION=$(ls -t "$SCRIPT_DIR/memory/soul/"*.md 2>/dev/null | head -1 || true)
  if [ -n "$LATEST_REFLECTION" ]; then
    echo "<!-- latest-reflection: memory/soul/$(basename "$LATEST_REFLECTION") — read when org identity, culture, or history context matters -->"
  fi
fi

# --- Flush leftover telemetry from previous session (background) ---
# If the previous session exited without a clean flush (terminal closed,
# crash, kill -9), events are still in the local buffer. Drain them now.
bash "$SCRIPT_DIR/bin/telemetry.sh" flush 2>/dev/null &

# --- Emit session_start telemetry (background, non-blocking) ---
bash "$SCRIPT_DIR/bin/telemetry.sh" emit "session_start" \
  "$(jq -n --arg branch "$BRANCH" '{branch: $branch}')" 2>/dev/null &

# --- Health check-in (background, non-blocking) ---
bash "$SCRIPT_DIR/bin/startup-check.sh" >/dev/null 2>&1 &

# --- Warm npx cache for egregore-artifacts (background, throttled) ---
# publish-artifact.sh spawns `npx egregore-artifacts` — first run in a
# fresh npx cache pays a 5-10s npm download. Warmup is throttled to
# once per hour via a marker file so we don't storm npm when a user
# opens many tabs, and don't start runaway retry loops when offline.
_WARM_TS_FILE="$HOME/.cache/egregore/npx-warm-ts"
mkdir -p "$(dirname "$_WARM_TS_FILE")" 2>/dev/null
_WARM_LAST=$(cat "$_WARM_TS_FILE" 2>/dev/null || echo 0)
_WARM_NOW=$(date +%s)
if [ $(( _WARM_NOW - _WARM_LAST )) -gt 3600 ]; then
  (npx -y egregore-artifacts@latest --help >/dev/null 2>&1 \
    && echo "$_WARM_NOW" > "$_WARM_TS_FILE" &) >/dev/null 2>&1
fi

# Clean up temp files
rm -rf "$CTX_DIR"

# --- First session welcome ---
if [ -z "$FIRST_SESSION" ] && [ -f "$STATE_FILE" ]; then
  FIRST_SESSION=$(jq -r '.first_session // false' "$STATE_FILE" 2>/dev/null)
fi

if [ "$FIRST_SESSION" = "true" ]; then
  echo ""
  echo "  Welcome! This is your first session."
  echo ""
  echo "IMPORTANT: Display the above greeting exactly as-is (ASCII art + ornamented status). Then ask the user if they'd like a quick onboarding tour (run /onboarding), or if they want to jump straight in."
  # Clear the flag so it only shows once
  jq '.first_session = false' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
else
  # --- Tutorial tip (if onboarding done but tutorial not) ---
  TUTORIAL_COMPLETE="true"
  if [ -f "$STATE_FILE" ]; then
    TUTORIAL_COMPLETE=$(jq -r '.tutorial_complete // false' "$STATE_FILE" 2>/dev/null || echo "true")
  fi

  if [ "$TUTORIAL_COMPLETE" != "true" ]; then
    echo "  Tip: Run /tutorial to learn the core loop."
  fi

  echo ""
  echo "IMPORTANT: Display the above greeting to the user exactly as-is (preserve the ASCII art formatting and ornamented status) on their first message. Then ask: What are you working on?"
  echo ""
  echo "BRANCH RULE: When the user responds with what they're working on, your FIRST action is to create a working branch: git fetch origin $BASE_BRANCH --quiet && git checkout --no-track -b dev/{author}/{topic-slug} origin/$BASE_BRANCH. Do this BEFORE any other work. Derive the topic slug from their description. If they ask a pure question with no work intent, skip branching."
fi
