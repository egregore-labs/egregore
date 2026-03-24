# shellcheck shell=bash
# identity.sh — User identity resolution for session-start.sh
#
# Resolves the current user's identity through multiple fallback layers:
#   1. .egregore-state.json github_username (stored during setup)
#   2. GitHub API auto-detect via GITHUB_TOKEN
#   3. Graph person lookup (existing team member on new machine)
#   4. Global git config user.name (last resort)
#
# Inputs:  STATE_FILE, ENV_FILE, SCRIPT_DIR, HEALTH_GITHUB
# Outputs: AUTHOR, DISPLAY_NAME_STATE, FIRST_SESSION, HEALTH_GITHUB,
#          EGREGORE_USER, EGREGORE_ORG, EGREGORE_SESSION_ID
#          Writes .egregore-session-id and ~/.egregore/session-*.id

STORED_USERNAME=""
FIRST_SESSION=""
AUTHOR=""
if [ -f "$STATE_FILE" ]; then
  STORED_USERNAME=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null)
fi

DISPLAY_NAME_STATE=""
if [ -f "$STATE_FILE" ]; then
  DISPLAY_NAME_STATE=$(jq -r '.display_name // empty' "$STATE_FILE" 2>/dev/null)
fi

if [ -n "$STORED_USERNAME" ]; then
  # Identity stored during setup — use it and ensure repo-local git config matches
  AUTHOR="$STORED_USERNAME"
  HEALTH_GITHUB="ok"
  CURRENT_LOCAL=$(git config --local user.name 2>/dev/null || echo "")
  if [ "$CURRENT_LOCAL" != "$STORED_USERNAME" ]; then
    STORED_NAME=$(jq -r '.github_name // empty' "$STATE_FILE" 2>/dev/null)
    git config user.name "${STORED_NAME:-$STORED_USERNAME}" 2>/dev/null || true
    git config user.email "${STORED_USERNAME}@users.noreply.github.com" 2>/dev/null || true
  fi
else
  # No stored identity — try GitHub API to auto-detect (self-healing for pre-fix installs)
  if [ -f "$ENV_FILE" ]; then
    GH_TOKEN=$(grep '^GITHUB_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
    if [ -n "$GH_TOKEN" ]; then
      GH_USER_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" https://api.github.com/user --max-time 5 2>/dev/null || echo "")
      GH_LOGIN=$(echo "$GH_USER_JSON" | jq -r '.login // empty' 2>/dev/null)
      GH_NAME=$(echo "$GH_USER_JSON" | jq -r '.name // empty' 2>/dev/null)
      if [ -n "$GH_LOGIN" ]; then
        AUTHOR="$GH_LOGIN"
        HEALTH_GITHUB="ok"
        # Set repo-local config and save to state for next time
        git config user.name "${GH_NAME:-$GH_LOGIN}" 2>/dev/null || true
        git config user.email "${GH_LOGIN}@users.noreply.github.com" 2>/dev/null || true
        # Save to state file so we don't need API call next time
        # Include onboarding_complete + name so it doesn't re-trigger onboarding
        # Determine if founder or joiner: if github_username != github_org, they're a joiner
        GITHUB_ORG_CFG=$(jq -r '.github_org // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
        if [ -n "$GITHUB_ORG_CFG" ] && [ "$GH_LOGIN" != "$GITHUB_ORG_CFG" ]; then
          USAGE_TYPE="joiner_group"
        else
          USAGE_TYPE="founder_group"
        fi
        if [ -f "$STATE_FILE" ]; then
          # Existing state file — update identity but preserve onboarding status
          HAS_ONBOARDING=$(jq -r '.onboarding_complete // "unset"' "$STATE_FILE" 2>/dev/null)
          if [ "$HAS_ONBOARDING" = "unset" ]; then
            # State file exists but no onboarding flag — set to false to trigger it
            jq --arg u "$GH_LOGIN" --arg n "${GH_NAME:-$GH_LOGIN}" --arg ut "$USAGE_TYPE" \
              '.github_username = $u | .github_name = $n | .name = $n | .onboarding_complete = false | .usage_type = $ut' "$STATE_FILE" > "$STATE_FILE.tmp" \
              && mv "$STATE_FILE.tmp" "$STATE_FILE"
          else
            jq --arg u "$GH_LOGIN" --arg n "${GH_NAME:-$GH_LOGIN}" --arg ut "$USAGE_TYPE" \
              '.github_username = $u | .github_name = $n | .name = $n | .usage_type = $ut' "$STATE_FILE" > "$STATE_FILE.tmp" \
              && mv "$STATE_FILE.tmp" "$STATE_FILE"
          fi
          FIRST_SESSION="false"
        else
          # No state file — check graph to see if this person already exists
          # (handles fresh clone / new machine for existing team members)
          GRAPH_PERSON=""
          GRAPH_DISPLAY_NAME=""
          GRAPH_PERSON=$(bash "$SCRIPT_DIR/bin/graph.sh" query \
            "MATCH (p:Person {github: \$github}) RETURN p.name AS name" \
            "$(jq -n --arg github "$GH_LOGIN" '{github: $github}')" 2>/dev/null || echo "")
          if echo "$GRAPH_PERSON" | jq -e '.values | length > 0' &>/dev/null; then
            GRAPH_DISPLAY_NAME=$(echo "$GRAPH_PERSON" | jq -r '.values[0][0] // empty' 2>/dev/null)
            # Existing team member — skip onboarding
            cat > "$STATE_FILE" << STATEEOF
{
  "github_username": "$GH_LOGIN",
  "github_name": "${GH_NAME:-$GH_LOGIN}",
  "name": "${GRAPH_DISPLAY_NAME:-${GH_NAME:-$GH_LOGIN}}",
  "display_name": "${GRAPH_DISPLAY_NAME:-}",
  "onboarding_complete": true,
  "usage_type": "$USAGE_TYPE",
  "session_tracking": true,
  "transcript_sharing": true,
  "telemetry": true,
  "contact_preference": "all",
  "telemetry_noticed": true
}
STATEEOF
            FIRST_SESSION="false"
          else
            # Genuinely new user — trigger onboarding
            cat > "$STATE_FILE" << STATEEOF
{
  "github_username": "$GH_LOGIN",
  "github_name": "${GH_NAME:-$GH_LOGIN}",
  "name": "${GH_NAME:-$GH_LOGIN}",
  "onboarding_complete": false,
  "usage_type": "$USAGE_TYPE",
  "first_session": true
}
STATEEOF
            FIRST_SESSION="true"
          fi
        fi
      fi
    fi
  fi

  # Final fallback: git config user.name (global or local)
  if [ -z "$AUTHOR" ]; then
    FULLNAME=$(git config user.name 2>/dev/null || echo "")
    AUTHOR=$(echo "$FULLNAME" | tr '[:upper:]' '[:lower:]' | cut -d' ' -f1)
  fi
fi

if [ -z "$AUTHOR" ]; then
  AUTHOR="unknown"
  HEALTH_GITHUB="fail"
fi

# --- Validate gh CLI identity matches git identity ---
# The gh CLI has its own auth (keyring) separate from .env GITHUB_TOKEN.
# If they diverge, PRs get created under the wrong account.
if command -v gh &>/dev/null; then
  GH_CLI_USER=$(gh api user --jq '.login' 2>/dev/null || true)
  if [ -n "$GH_CLI_USER" ] && [ -n "$AUTHOR" ] && [ "$AUTHOR" != "unknown" ]; then
    AUTHOR_LC=$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]')
    GH_CLI_LC=$(echo "$GH_CLI_USER" | tr '[:upper:]' '[:lower:]')
    if [ "$AUTHOR_LC" != "$GH_CLI_LC" ]; then
      echo ""
      echo "WARNING: Identity mismatch detected."
      echo "  Git identity (.env):  $AUTHOR"
      echo "  gh CLI (active):      $GH_CLI_USER"
      echo "  PRs will be created as '$GH_CLI_USER', not '$AUTHOR'."
      echo "  Fix: gh auth switch --user $AUTHOR"
      echo ""
    fi
  fi
fi

# --- Export telemetry identity env vars ---
export EGREGORE_USER="$AUTHOR"
export EGREGORE_ORG="$(jq -r '.slug // .github_org // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null || true)"
export EGREGORE_SESSION_ID="$(date -u +%Y%m%dT%H%M%S)-${AUTHOR}-$$"

# Persist session ID to file so telemetry.sh can read it
# (env vars from hooks don't propagate into the Claude Code agent)
SESSION_ID_DIR="$HOME/.egregore"
mkdir -p "$SESSION_ID_DIR"
PROJ_HASH=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
echo "$EGREGORE_SESSION_ID" > "$SESSION_ID_DIR/session-${PROJ_HASH}.id"
# Also write project-local file (CLAUDE.md reads this — no glob needed)
echo "$EGREGORE_SESSION_ID" > "$SCRIPT_DIR/.egregore-session-id"
