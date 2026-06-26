# shellcheck shell=bash
# dashboard-artifact.sh — Generate a session dashboard artifact with a shareable URL
#
# Runs after context.sh (all $CTX_DIR/* files populated), before greeting.sh.
# Compiles gathered context into a markdown document, generates HTML via
# egregore-artifacts, publishes it, and exports DASHBOARD_URL for greeting.sh.
#
# Inputs:  SCRIPT_DIR, CTX_DIR, AUTHOR, GREETING_NAME, LOCAL_MODE,
#          EGREGORE_SESSION_ID, FIRST_SESSION
# Outputs: DASHBOARD_URL (exported for greeting.sh)

DASHBOARD_URL=""

# Skip conditions: first session, onboarding incomplete, no session ID
if [ "${FIRST_SESSION:-false}" = "true" ]; then
  return 0 2>/dev/null || exit 0
fi
if [ -z "${EGREGORE_SESSION_ID:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

# --- Read gathered context ---
_DB_ADDRESSED=$(cat "$CTX_DIR/addressed_rich" 2>/dev/null || echo "[]")
_DB_ADDR_COUNT=$(echo "$_DB_ADDRESSED" | jq 'length' 2>/dev/null || echo "0")
_DB_QUESTS=$(cat "$CTX_DIR/quests" 2>/dev/null || echo "[]")
_DB_QUEST_COUNT=$(echo "$_DB_QUESTS" | jq 'length' 2>/dev/null || echo "0")
_DB_TEAM=$(cat "$CTX_DIR/team" 2>/dev/null || echo "[]")
_DB_TEAM_COUNT=$(echo "$_DB_TEAM" | jq 'length' 2>/dev/null || echo "0")
_DB_LIFECYCLE=$(cat "$CTX_DIR/lifecycle" 2>/dev/null || echo '{}')
_DB_MERGED_COUNT=$(echo "$_DB_LIFECYCLE" | jq '.merged_prs.values // [] | length' 2>/dev/null || echo "0")
_DB_IMPL_COUNT=$(echo "$_DB_LIFECYCLE" | jq '.implemented_handoffs.values // [] | length' 2>/dev/null || echo "0")
_DB_PULSE=$(cat "$CTX_DIR/pulse_brief" 2>/dev/null || echo '{}')
_DB_PULSE_BRIEF=$(echo "$_DB_PULSE" | jq -r '.brief // empty' 2>/dev/null || true)

# Skip if all context is empty — nothing worth showing
_DB_HAS_CONTENT="false"
if [ "$_DB_ADDR_COUNT" -gt 0 ] 2>/dev/null; then _DB_HAS_CONTENT="true"; fi
if [ "$_DB_QUEST_COUNT" -gt 0 ] 2>/dev/null; then _DB_HAS_CONTENT="true"; fi
if [ "$_DB_TEAM_COUNT" -gt 0 ] 2>/dev/null; then _DB_HAS_CONTENT="true"; fi
if [ "$_DB_MERGED_COUNT" -gt 0 ] 2>/dev/null; then _DB_HAS_CONTENT="true"; fi
if [ "$_DB_IMPL_COUNT" -gt 0 ] 2>/dev/null; then _DB_HAS_CONTENT="true"; fi

if [ "$_DB_HAS_CONTENT" = "false" ]; then
  return 0 2>/dev/null || exit 0
fi

# --- Compile markdown ---
_DB_DATE=$(date +%Y-%m-%d)
_DB_ORG=$(jq -r '.org_name // "Egregore"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "Egregore")
_DB_MD="/tmp/egregore-dashboard-${EGREGORE_SESSION_ID}.md"
mkdir -p /tmp

{
  printf '# Session Dashboard — %s\n\n' "$_DB_ORG"

  # --- Pulse Brief (first — sets the tone) ---
  if [ -n "$_DB_PULSE_BRIEF" ]; then
    printf '## Pulse\n\n'
    printf '✦ %s\n\n' "$_DB_PULSE_BRIEF"
  fi

  # --- Handoffs & Asks (dense format matching terminal TUI) ---
  if [ "$_DB_ADDR_COUNT" -gt 0 ] 2>/dev/null; then
    printf '## Handoffs & Asks\n\n'
    _DB_NOW_SEC=$(date +%s)
    echo "$_DB_ADDRESSED" | jq -r '.[] | "\(.author // "unknown")\t\(.topic // "Untitled")\t\(.date // "--")"' 2>/dev/null | while IFS=$'\t' read -r _HF_AUTHOR _HF_TOPIC _HF_DATE; do
      [ -z "$_HF_AUTHOR" ] && continue
      # Compute relative time
      _HF_DATE_ONLY="${_HF_DATE%%T*}"
      _HF_EPOCH=$(date -j -f "%Y-%m-%d" "$_HF_DATE_ONLY" +%s 2>/dev/null || \
                  date -d "$_HF_DATE_ONLY" +%s 2>/dev/null || echo "0")
      _HF_DAYS=$(( (_DB_NOW_SEC - _HF_EPOCH) / 86400 ))
      if [ "$_HF_DAYS" -le 0 ] 2>/dev/null; then _HF_AGO="today"
      elif [ "$_HF_DAYS" -eq 1 ] 2>/dev/null; then _HF_AGO="yesterday"
      else _HF_AGO="${_HF_DAYS}d ago"
      fi
      _HF_NAME_LC=$(printf '%s' "$_HF_AUTHOR" | awk '{print tolower($1)}')
      printf '● %s → you: %s (%s)\n\n' "$_HF_NAME_LC" "$_HF_TOPIC" "$_HF_AGO"
    done
  fi

  # --- Team Activity (right after handoffs, recent only) ---
  if [ "$_DB_TEAM_COUNT" -gt 0 ] 2>/dev/null; then
    _DB_NOW=$(date +%s)
    _DB_RECENCY=$((7 * 86400))
    _DB_TEAM_FILTERED=$(echo "$_DB_TEAM" | jq --argjson now "$_DB_NOW" --argjson window "$_DB_RECENCY" \
      '[.[] | select(.last_seen_sort > 0 and ($now - .last_seen_sort) < $window)]' 2>/dev/null || echo "[]")
    _DB_TEAM_FCOUNT=$(echo "$_DB_TEAM_FILTERED" | jq 'length' 2>/dev/null || echo "0")
    if [ "$_DB_TEAM_FCOUNT" -gt 0 ] 2>/dev/null; then
      printf '## Team Activity\n\n'
      printf '| Name | Last Seen | Working On |\n'
      printf '|------|-----------|------------|\n'
      echo "$_DB_TEAM_FILTERED" | jq -r '.[] | "| \(.name) | \(.last_seen) | \(.branches | join(", ")) |"' 2>/dev/null || true
      printf '\n'
    fi
  fi

  # --- What Changed ---
  if [ "$_DB_MERGED_COUNT" -gt 0 ] 2>/dev/null || [ "$_DB_IMPL_COUNT" -gt 0 ] 2>/dev/null; then
    printf '## What Changed\n\n'
    if [ "$_DB_MERGED_COUNT" -gt 0 ] 2>/dev/null; then
      echo "$_DB_LIFECYCLE" | jq -r '.merged_prs.values[]? | "- ✓ PR #\(.[0]) \(.[2] // .[1] // "")"' 2>/dev/null || true
    fi
    if [ "$_DB_IMPL_COUNT" -gt 0 ] 2>/dev/null; then
      echo "$_DB_LIFECYCLE" | jq -r '.implemented_handoffs.values[]? | "- ✓ \(.[1] // "someone") worked on: \(.[0] // "handoff")"' 2>/dev/null || true
    fi
    printf '\n'
  fi

  # --- Active Quests (bottom — reference, exclude meta entries) ---
  if [ "$_DB_QUEST_COUNT" -gt 0 ] 2>/dev/null; then
    _DB_QUESTS_FILTERED=$(echo "$_DB_QUESTS" | jq '[.[] | select(. != "_template" and . != "index")][:10]' 2>/dev/null || echo "[]")
    _DB_QF_COUNT=$(echo "$_DB_QUESTS_FILTERED" | jq 'length' 2>/dev/null || echo "0")
    if [ "$_DB_QF_COUNT" -gt 0 ] 2>/dev/null; then
      printf '## Active Quests\n\n'
      echo "$_DB_QUESTS_FILTERED" | jq -r '.[] | "- \(.)"' 2>/dev/null || true
      printf '\n'
    fi
  fi

} > "$_DB_MD" 2>/dev/null

# --- Publish markdown → HTML → hosted URL ---
# publish-artifact.sh handles HTML generation internally (npx egregore-artifacts)
# then uploads. Don't pre-generate HTML — that causes double-wrapping.
# https:// URLs are universally cmd+clickable across all terminal emulators.
# publish-artifact.sh may output npx progress lines before the URL — extract just the URL
_DB_PUBLISH_OUT=$(bash "$SCRIPT_DIR/bin/publish-artifact.sh" document "$_DB_MD" \
  --title "Session Dashboard" \
  --author "${GREETING_NAME:-$AUTHOR}" 2>/dev/null || true)
DASHBOARD_URL=$(echo "$_DB_PUBLISH_OUT" | grep -o 'https://[^ ]*' | tail -1)

# Fallback: generate HTML locally and use file:// URL (offline, no API key, etc.)
if [ -z "$DASHBOARD_URL" ]; then
  _DB_HTML="/tmp/egregore-artifacts/dashboard-${EGREGORE_SESSION_ID}.html"
  mkdir -p /tmp/egregore-artifacts
  if npx egregore-artifacts@latest document "$_DB_MD" --output "$_DB_HTML" --no-open >/dev/null 2>&1 && [ -f "$_DB_HTML" ]; then
    DASHBOARD_URL="file://${_DB_HTML}"
  fi
fi

rm -f "$_DB_MD"
