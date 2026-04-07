# shellcheck shell=bash
# greeting.sh — Greeting output renderer for session-start.sh
#
# Renders the full session greeting:
#   - ASCII art banner
#   - Identity line (org/repo + user + branch)
#   - "For you" section (handoffs, last activity)
#   - "Around" section (team presence)
#   - "Merged" section (PRs, implemented handoffs)
#   - Health footer
#   - Alias migration
#   - Session context JSON (hidden, for Claude)
#   - Soul file inclusion
#   - Telemetry emit
#   - First session welcome
#
# Inputs:  SCRIPT_DIR, STATE_FILE, CONFIG, CTX_DIR, BRANCH, COMMITS_AHEAD,
#          AUTHOR, LOCAL_MODE, MEMORY_SYNCED, REPOS_STATUS, SAVED_BRANCH,
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

# --- Shared rendering state ---
TEAM_DATA=$(cat "$CTX_DIR/team" 2>/dev/null || echo "[]")
TEAM_DATA_COUNT=$(echo "$TEAM_DATA" | jq 'length' 2>/dev/null || echo "0")
NOW_RENDER=$(date +%s)
ONLINE_THRESHOLD=7200  # 2 hours — considered "online"
RECENCY_DAYS=3
RECENCY_THRESHOLD=$((RECENCY_DAYS * 86400))
TODAY_DATE=$(date +%Y-%m-%d)
TODAY_MIDNIGHT=$(date -j -f "%Y-%m-%d" "$TODAY_DATE" +%s 2>/dev/null || \
                 date -d "$TODAY_DATE" +%s 2>/dev/null || echo "$NOW_RENDER")
# Column layout: 2(indent) + 2(dot+space) + 9(name) + 12(time) + 40(info) = 65
MAX_INFO=40

# --- Section 1: For you (always present) ---
echo "  ◦ for you"
ADDRESSED_RICH=$(cat "$CTX_DIR/addressed_rich" 2>/dev/null || echo "[]")
ADDRESSED_COUNT=$(echo "$ADDRESSED_RICH" | jq 'length' 2>/dev/null || echo "0")

# Handoffs addressed to you
if [ "$ADDRESSED_COUNT" -gt 0 ] 2>/dev/null && [ "$ADDRESSED_COUNT" != "0" ]; then
  echo "$ADDRESSED_RICH" | jq -r '.[] | "\(.author)\t\(.date)\t\(.topic)"' 2>/dev/null | while IFS=$'\t' read -r H_AUTHOR H_DATE H_TOPIC; do
    [ -z "$H_AUTHOR" ] && continue
    # Convert date to epoch (UTC) and compute calendar-day diff
    H_DATE_ONLY="${H_DATE%%T*}"
    H_EVENT_MIDNIGHT=$(date -j -f "%Y-%m-%d" "$H_DATE_ONLY" +%s 2>/dev/null || \
                       date -d "$H_DATE_ONLY" +%s 2>/dev/null || echo "0")
    H_CAL_DAYS=$(( (TODAY_MIDNIGHT - H_EVENT_MIDNIGHT) / 86400 ))
    # Skip if older than recency threshold
    [ "$H_CAL_DAYS" -gt "$RECENCY_DAYS" ] 2>/dev/null && continue
    H_NAME=$(echo "$H_AUTHOR" | awk '{print tolower($1)}')
    if [ ${#H_NAME} -gt 8 ]; then H_NAME="${H_NAME:0:8}"; fi
    # Online status from team presence data
    H_SEEN_EPOCH=$(echo "$TEAM_DATA" | jq -r --arg n "$H_NAME" '[.[] | select((.name | ascii_downcase) == $n) | .last_seen_sort] | .[0] // 0' 2>/dev/null || echo "0")
    if [ "$H_SEEN_EPOCH" -gt 0 ] 2>/dev/null && [ $(( NOW_RENDER - H_SEEN_EPOCH )) -lt $ONLINE_THRESHOLD ] 2>/dev/null; then
      DOT="●"
    else
      DOT="○"
    fi
    # Calendar-day relative label
    if [ "$H_CAL_DAYS" -le 0 ] 2>/dev/null; then H_AGO="today"
    elif [ "$H_CAL_DAYS" -eq 1 ] 2>/dev/null; then H_AGO="yesterday"
    else H_AGO="${H_CAL_DAYS}d ago"
    fi
    if [ ${#H_TOPIC} -gt $MAX_INFO ]; then H_TOPIC="${H_TOPIC:0:$((MAX_INFO - 1))}…"; fi
    printf "  %s %-9s%-12s%s\n" "$DOT" "$H_NAME" "$H_AGO" "$H_TOPIC"
  done
fi

# Fallback: last activity if no handoffs
if [ "$ADDRESSED_COUNT" = "0" ] || [ -z "$ADDRESSED_COUNT" ]; then
  LAST_ACTIVITY=$(cat "$CTX_DIR/activity" 2>/dev/null || echo "")
  if [ -n "$LAST_ACTIVITY" ]; then
    LA_TIME=$(echo "$LAST_ACTIVITY" | cut -d'|' -f1)
    # Compact relative time: "20 hours ago" → "20h ago", "3 days ago" → "3d ago"
    LA_TIME=$(echo "$LA_TIME" | sed 's/ hours\{0,1\} ago/h ago/; s/ days\{0,1\} ago/d ago/; s/ minutes\{0,1\} ago/m ago/; s/ weeks\{0,1\} ago/w ago/; s/ months\{0,1\} ago/mo ago/')
    LA_MSG=$(echo "$LAST_ACTIVITY" | cut -d'|' -f2-)
    if [ ${#LA_MSG} -gt $MAX_INFO ]; then LA_MSG="${LA_MSG:0:$((MAX_INFO - 1))}…"; fi
    printf "  ◇ %-9s%-12s%s\n" "you" "$LA_TIME" "$LA_MSG"
  fi
fi

echo ""
# --- Section 2: Around (team presence with online status) ---
if [ "$TEAM_DATA_COUNT" -gt 0 ] 2>/dev/null && [ "$TEAM_DATA_COUNT" != "0" ]; then
  echo "  ◦ around"
  # Presence roster with online/offline dots (hide inactive >3 days)
  STALE_THRESHOLD=$((RECENCY_DAYS * 86400))
  echo "$TEAM_DATA" | jq -r '.[] | "\(.name)\t\(.last_seen_sort)\t\(.last_seen)\t\(.branches | join(", "))"' 2>/dev/null | while IFS=$'\t' read -r P_NAME P_EPOCH P_SEEN P_BRANCHES; do
    [ -z "$P_NAME" ] && continue
    # Skip if no recent activity (within recency window)
    if [ "$P_EPOCH" -le 0 ] 2>/dev/null; then
      continue
    elif [ $(( NOW_RENDER - P_EPOCH )) -ge $STALE_THRESHOLD ] 2>/dev/null; then
      continue
    fi
    if [ ${#P_NAME} -gt 8 ]; then P_NAME="${P_NAME:0:8}"; fi
    # Online: last seen within threshold
    if [ $(( NOW_RENDER - P_EPOCH )) -lt $ONLINE_THRESHOLD ] 2>/dev/null; then
      DOT="●"
    else
      DOT="○"
    fi
    if [ ${#P_BRANCHES} -gt $MAX_INFO ]; then
      P_BRANCHES="${P_BRANCHES:0:$((MAX_INFO - 9))}... +more"
    fi
    printf "  %s %-9s%-12s%s\n" "$DOT" "$P_NAME" "$P_SEEN" "$P_BRANCHES"
  done
fi

# --- Section 3: Recently merged PRs + implemented handoffs ---
LIFECYCLE_JSON=$(cat "$CTX_DIR/lifecycle" 2>/dev/null || echo '{}')
MERGED_COUNT=$(echo "$LIFECYCLE_JSON" | jq '.merged_prs.values // [] | length' 2>/dev/null || echo "0")
IMPL_COUNT=$(echo "$LIFECYCLE_JSON" | jq '.implemented_handoffs.values // [] | length' 2>/dev/null || echo "0")

if [ "$MERGED_COUNT" -gt 0 ] 2>/dev/null || [ "$IMPL_COUNT" -gt 0 ] 2>/dev/null; then
  echo ""
  echo "  ◦ merged"
  if [ "$MERGED_COUNT" -gt 0 ] 2>/dev/null; then
    echo "$LIFECYCLE_JSON" | jq -r '.merged_prs.values[]? // empty | "  ✓ PR #\(.[0]) \(.[1])"' 2>/dev/null || true
  fi
  if [ "$IMPL_COUNT" -gt 0 ] 2>/dev/null; then
    echo "$LIFECYCLE_JSON" | jq -r '.implemented_handoffs.values[]? // empty | "  ✓ \(.[1]) worked on your handoff"' 2>/dev/null || true
  fi
fi

# Show auto-save notice if work was committed from a previous branch
if [ -n "$SAVED_BRANCH" ]; then
  echo "  ✓ Auto-saved uncommitted work on $SAVED_BRANCH"
fi

# --- Footer: health + repos + memory (tertiary) ---
echo "$SEPARATOR"

# Dashboard URL (cmd+clickable in terminal)
if [ -n "${DASHBOARD_URL:-}" ]; then
  printf "  ◆ dashboard  %s\n" "$DASHBOARD_URL"
fi

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
      FOOTER_LEFT="  ◆ updated"
    else
      FOOTER_LEFT="  ✓ ready"
    fi

    # Add managed repos inline
    if [ -n "$REPOS_STATUS" ]; then
      REPOS_COMPACT=$(printf '%s' "$REPOS_STATUS" | sed 's/^  ◇ //;s/^[[:space:]]*//' | paste -sd'  ' - | sed 's/[[:space:]]*$//')
      if [ -n "$REPOS_COMPACT" ]; then
        FOOTER_LEFT="${FOOTER_LEFT}          ${REPOS_COMPACT}"
      fi
    fi

    FOOTER_RIGHT=""

    FL_LEN=${#FOOTER_LEFT}
    FR_LEN=${#FOOTER_RIGHT}
    F_PAD=$((LINE_WIDTH - FL_LEN - FR_LEN))
    if [ "$F_PAD" -lt 1 ]; then F_PAD=1; fi
    printf "%s%*s%s\n" "$FOOTER_LEFT" "$F_PAD" "" "$FOOTER_RIGHT"
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
    # Compact footer: ready + repos + memory
    FOOTER_LEFT="  ✓ ready"

    # Add managed repos inline
    if [ -n "$REPOS_STATUS" ]; then
      # Extract repo info into compact format (strip ornaments)
      REPOS_COMPACT=$(printf '%s' "$REPOS_STATUS" | sed 's/^  ◇ //;s/^[[:space:]]*//' | paste -sd'  ' - | sed 's/[[:space:]]*$//')
      if [ -n "$REPOS_COMPACT" ]; then
        FOOTER_LEFT="${FOOTER_LEFT}          ${REPOS_COMPACT}"
      fi
    fi

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
CONTEXT_ADDRESSED=$(cat "$CTX_DIR/addressed" 2>/dev/null || echo "[]")
CONTEXT_QUESTS=$(cat "$CTX_DIR/quests" 2>/dev/null || echo "[]")
CONTEXT_ACTIVITY=$(cat "$CTX_DIR/activity" 2>/dev/null || echo "")
CONTEXT_TEAM=$(cat "$CTX_DIR/team" 2>/dev/null || echo "[]")
CONTEXT_SOUL=$(cat "$CTX_DIR/soul_summary" 2>/dev/null || echo "")
CONTEXT_LIFECYCLE=$(cat "$CTX_DIR/lifecycle" 2>/dev/null || echo '{"merged_prs":[],"implemented_handoffs":[]}')
CONTEXT_PULSE=$(cat "$CTX_DIR/pulse_brief" 2>/dev/null || echo '{}')

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

cat << CTXEOF

<!-- session-context
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
  "pulse": $CONTEXT_PULSE
}
-->
CTXEOF

# Include soul file if present
if [ -f "$SCRIPT_DIR/egregore.md" ]; then
  echo ""
  echo "<!-- egregore-soul"
  cat "$SCRIPT_DIR/egregore.md"
  echo "-->"
fi

# Include latest soul reflection if present
if [ -d "$SCRIPT_DIR/memory/soul" ]; then
  LATEST_REFLECTION=$(ls -t "$SCRIPT_DIR/memory/soul/"*.md 2>/dev/null | head -1 || true)
  if [ -n "$LATEST_REFLECTION" ]; then
    echo "<!-- latest-reflection"
    cat "$LATEST_REFLECTION"
    echo "-->"
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
  echo "BRANCH RULE: When the user responds with what they're working on, your FIRST action is to create a working branch: git fetch origin develop --quiet && git checkout -b dev/{author}/{topic-slug} origin/develop. Do this BEFORE any other work. Derive the topic slug from their description. If they ask a pure question with no work intent, skip branching."
fi
