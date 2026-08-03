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
      echo "$_DB_TEAM_FILTERED" | jq -r '.[] | ((.working_on // "")) as $w | (.branches // []) as $b | "| \(.name) | \(.last_seen) | \(if $w != "" then $w else ($b | join(", ")) end) |"' 2>/dev/null || true
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
#
# Connected mode publishes to a STABLE per-user artifact id and runs the
# render+upload detached: the URL is known up front, so the greeting prints it
# without paying the ~2s render/upload on the boot path. Content lands moments
# later; until then (and through the ~5min edge cache) the URL serves the
# previous session's dashboard, which is an acceptable trade for a greeting
# link. This also stops every boot from minting a new artifact URL.
#
# The id is RANDOM, generated once and persisted in the user's state file —
# never derived from the username. Dashboard reads are public and unauth'd,
# so a predictable id (org slug + github handle) would make every teammate's
# operational dashboard enumerable; and a name-derived id without an org
# component collides across orgs for multi-org users (artifact ids upsert
# globally). Random-per-instance gives unguessable AND collision-free.
_DB_SLUG=$(jq -r '.slug // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
_DB_STATE="${STATE_FILE:-$SCRIPT_DIR/.egregore-state.json}"
_DB_ID=$(jq -r '.dashboard_artifact_id // empty' "$_DB_STATE" 2>/dev/null)
if [ -z "$_DB_ID" ] && [ -f "$_DB_STATE" ]; then
  # First-id creation is SERIALIZED (mkdir is the portable atomic primitive):
  # without a lock, two first boots can each persist-then-adopt different ids
  # and both publish, stranding an orphan stable artifact. The winner creates
  # exactly one id; the loser re-reads and either adopts it or (readback still
  # empty) falls through to the legacy synchronous publish for this boot.
  # A crashed creator's stale lock breaks after 5 minutes.
  _DB_LOCK="$HOME/.egregore/dashboard-id-$(echo -n "${MAIN_PROJECT_DIR:-$SCRIPT_DIR}" | cksum | cut -d' ' -f1).lock"
  mkdir -p "$HOME/.egregore" 2>/dev/null
  if ! mkdir "$_DB_LOCK" 2>/dev/null; then
    _DB_LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$_DB_LOCK" 2>/dev/null || stat -c %Y "$_DB_LOCK" 2>/dev/null || echo 0) ))
    # Stale reap by atomic rename, never rmdir+mkdir: two reapers doing
    # remove-then-recreate can alternately delete each other's FRESH lock and
    # both proceed. Directory rename is atomic — exactly one reaper's mv
    # succeeds; the loser (and anyone losing the follow-up mkdir to a fresh
    # contender) backs off to the read-only path.
    if [ "$_DB_LOCK_AGE" -gt 300 ] && mv "$_DB_LOCK" "$_DB_LOCK.reap.$$" 2>/dev/null; then
      rm -rf "$_DB_LOCK.reap.$$" 2>/dev/null
      mkdir "$_DB_LOCK" 2>/dev/null || _DB_LOCK=""
    else
      _DB_LOCK=""
    fi
  fi
  if [ -n "$_DB_LOCK" ]; then
    # Re-read under the lock — the racing boot may have created the id already.
    _DB_ID=$(jq -r '.dashboard_artifact_id // empty' "$_DB_STATE" 2>/dev/null)
    if [ -z "$_DB_ID" ]; then
      _DB_RAND=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 16)
      [ -n "$_DB_RAND" ] || _DB_RAND=$(openssl rand -hex 8 2>/dev/null)
      if [ -n "$_DB_RAND" ]; then
        jq --arg id "dashboard-${_DB_RAND}" \
          '.dashboard_artifact_id = (.dashboard_artifact_id // $id)' "$_DB_STATE" > "$_DB_STATE.tmp.$$" 2>/dev/null \
          && mv "$_DB_STATE.tmp.$$" "$_DB_STATE" 2>/dev/null || rm -f "$_DB_STATE.tmp.$$" 2>/dev/null
        _DB_ID=$(jq -r '.dashboard_artifact_id // empty' "$_DB_STATE" 2>/dev/null)
      fi
    fi
    rmdir "$_DB_LOCK" 2>/dev/null || true
  else
    # Lost the race — adopt whatever the winner persisted, if it landed yet.
    _DB_ID=$(jq -r '.dashboard_artifact_id // empty' "$_DB_STATE" 2>/dev/null)
  fi
fi
if [ "${LOCAL_MODE:-false}" != "true" ] && [ -n "$_DB_SLUG" ] && [ -n "$_DB_ID" ]; then
  # Confirmation is BOUND TO THE ID: dashboard_published_id must equal the id
  # we are about to advertise. A bare boolean could be set by a publish of a
  # different id (racing first boots) or by publish-artifact's ephemeral-relay
  # fallback returning some other https URL when the API key is missing —
  # later boots would then advertise a stable URL nothing was published to.
  _DB_EXPECTED_URL="https://egregore.xyz/view/${_DB_SLUG}/${_DB_ID}"
  _DB_CONFIRMED_ID=$(jq -r '.dashboard_published_id // empty' "$_DB_STATE" 2>/dev/null)
  if [ "$_DB_CONFIRMED_ID" = "$_DB_ID" ]; then
    # An artifact is confirmed at this exact id — safe to print the URL
    # immediately and refresh its content detached, off the boot path.
    DASHBOARD_URL="$_DB_EXPECTED_URL"
    ( (
      bash "$SCRIPT_DIR/bin/publish-artifact.sh" document "$_DB_MD" \
        --id "$_DB_ID" \
        --title "Session Dashboard" \
        --author "${GREETING_NAME:-$AUTHOR}" >/dev/null 2>&1 || true
      rm -f "$_DB_MD"
    ) >/dev/null 2>&1 & ) 2>/dev/null
  else
    # First publish for this id: synchronous, so the greeting never advertises
    # a URL with nothing behind it (publishing disabled, missing key, renderer
    # failure, API outage). Confirm only when the returned URL is actually the
    # stable URL for THIS id — host-agnostic suffix match, so a relay/ephemeral
    # URL is shown for this boot but never confirms the stable id.
    _DB_PUBLISH_OUT=$(bash "$SCRIPT_DIR/bin/publish-artifact.sh" document "$_DB_MD" \
      --id "$_DB_ID" \
      --title "Session Dashboard" \
      --author "${GREETING_NAME:-$AUTHOR}" 2>/dev/null || true)
    DASHBOARD_URL=$(echo "$_DB_PUBLISH_OUT" | grep -o 'https://[^ ]*' | tail -1)
    case "$DASHBOARD_URL" in
      */"${_DB_SLUG}/${_DB_ID}")
        jq --arg id "$_DB_ID" '.dashboard_published_id = $id | del(.dashboard_published)' "$_DB_STATE" > "$_DB_STATE.tmp.$$" 2>/dev/null \
          && mv "$_DB_STATE.tmp.$$" "$_DB_STATE" 2>/dev/null || rm -f "$_DB_STATE.tmp.$$" 2>/dev/null
        ;;
    esac
    rm -f "$_DB_MD"
  fi
else
  # Local/OSS mode: no stable hosted URL to print early — keep the synchronous
  # publish (ephemeral relay URL) with the local file:// render as fallback.
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
fi
