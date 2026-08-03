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
      GH_ID=$(echo "$GH_USER_JSON" | jq -r '.id // empty' 2>/dev/null)
      GH_NAME=$(echo "$GH_USER_JSON" | jq -r '.name // empty' 2>/dev/null)
      GH_EMAIL=$(echo "$GH_USER_JSON" | jq -r '.email // empty' 2>/dev/null)
      if [ -n "$GH_LOGIN" ]; then
        GH_ID_JSON="null"
        GH_PERSON_ID="github-login:$(echo "$GH_LOGIN" | tr '[:upper:]' '[:lower:]')"
        if [[ "$GH_ID" =~ ^[0-9]+$ ]]; then
          GH_ID_JSON="$GH_ID"
          GH_PERSON_ID="github:$GH_ID"
        fi
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
              --argjson gid "$GH_ID_JSON" --arg pid "$GH_PERSON_ID" --arg email "$GH_EMAIL" \
              '.github_username = $u | .github_id = $gid | .person_id = $pid |
               .github_name = $n | .name = $n |
               (if $email != "" then .email = ($email | ascii_downcase) else . end) |
               .onboarding_complete = false | .usage_type = $ut' "$STATE_FILE" > "$STATE_FILE.tmp" \
              && mv "$STATE_FILE.tmp" "$STATE_FILE"
          else
            jq --arg u "$GH_LOGIN" --arg n "${GH_NAME:-$GH_LOGIN}" --arg ut "$USAGE_TYPE" \
              --argjson gid "$GH_ID_JSON" --arg pid "$GH_PERSON_ID" --arg email "$GH_EMAIL" \
              '.github_username = $u | .github_id = $gid | .person_id = $pid |
               .github_name = $n | .name = $n |
               (if $email != "" then .email = ($email | ascii_downcase) else . end) |
               .usage_type = $ut' "$STATE_FILE" > "$STATE_FILE.tmp" \
              && mv "$STATE_FILE.tmp" "$STATE_FILE"
          fi
          FIRST_SESSION="false"
        else
          # No state file — check graph to see if this person already exists
          # (handles fresh clone / new machine for existing team members)
          GRAPH_PERSON=""
          GRAPH_DISPLAY_NAME=""
          GRAPH_PERSON=$(bash "$SCRIPT_DIR/bin/graph.sh" query \
            "MATCH (p:Person)
             WHERE NOT coalesce(p.kind, '') IN ['external', 'identity_alias']
               AND coalesce(p.status, 'active') = 'active'
               AND p.ingestRef IS NULL
               AND (p.github = \$github
                 OR (\$githubId <> '' AND coalesce(toString(p.githubId), '') = \$githubId)
                 OR toLower(\$github) IN [alias IN coalesce(p.githubAliases, []) | toLower(alias)])
             RETURN p.name AS name" \
            "$(jq -n --arg github "$GH_LOGIN" --arg githubId "$GH_ID" \
              '{github: $github, githubId: $githubId}')" 2>/dev/null || echo "")
          if echo "$GRAPH_PERSON" | jq -e '.values | length > 0' &>/dev/null; then
            GRAPH_DISPLAY_NAME=$(echo "$GRAPH_PERSON" | jq -r '.values[0][0] // empty' 2>/dev/null)
            # Existing team member — skip onboarding
            jq -n --arg github "$GH_LOGIN" --argjson githubId "$GH_ID_JSON" \
              --arg personId "$GH_PERSON_ID" --arg githubName "${GH_NAME:-$GH_LOGIN}" \
              --arg name "${GRAPH_DISPLAY_NAME:-${GH_NAME:-$GH_LOGIN}}" \
              --arg displayName "${GRAPH_DISPLAY_NAME:-}" --arg email "$GH_EMAIL" \
              --arg usageType "$USAGE_TYPE" \
              '{
                github_username: $github, github_id: $githubId, person_id: $personId,
                github_name: $githubName, name: $name, display_name: $displayName,
                email: (if $email == "" then null else ($email | ascii_downcase) end),
                onboarding_complete: true, usage_type: $usageType,
                session_tracking: true, transcript_sharing: true, telemetry: true,
                contact_preference: "all", telemetry_noticed: true
              }' > "$STATE_FILE"
            FIRST_SESSION="false"
          else
            # Genuinely new user — trigger onboarding
            jq -n --arg github "$GH_LOGIN" --argjson githubId "$GH_ID_JSON" \
              --arg personId "$GH_PERSON_ID" --arg githubName "${GH_NAME:-$GH_LOGIN}" \
              --arg email "$GH_EMAIL" --arg usageType "$USAGE_TYPE" \
              '{
                github_username: $github, github_id: $githubId, person_id: $personId,
                github_name: $githubName, name: $githubName,
                email: (if $email == "" then null else ($email | ascii_downcase) end),
                onboarding_complete: false, usage_type: $usageType, first_session: true
              }' > "$STATE_FILE"
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
# The `gh api user` round-trip (~1s) is off the boot path: each start reports
# the marker the previous background check left, then refreshes it detached.
# A mismatch therefore surfaces one session late — acceptable for a warning
# about a rare, persistent condition.
if command -v gh &>/dev/null && [ -n "$AUTHOR" ] && [ "$AUTHOR" != "unknown" ]; then
  _GH_MISMATCH_FILE="$HOME/.egregore/gh-identity-mismatch-$(echo -n "${MAIN_PROJECT_DIR:-$SCRIPT_DIR}" | cksum | cut -d' ' -f1)"
  # Marker format: line 1 = the AUTHOR the check ran as, line 2 = the gh login
  # observed. Warn only when line 1 matches the current AUTHOR — the same
  # machine/instance can serve different git identities, and Alice's stale
  # marker must not tell Bob that Bob mismatches Bob.
  _GH_MARKER_AUTHOR=$(sed -n '1p' "$_GH_MISMATCH_FILE" 2>/dev/null || true)
  GH_CLI_USER=$(sed -n '2p' "$_GH_MISMATCH_FILE" 2>/dev/null || true)
  if [ -n "$GH_CLI_USER" ] && [ "$_GH_MARKER_AUTHOR" = "$AUTHOR" ]; then
    echo ""
    echo "WARNING: Identity mismatch detected."
    echo "  Git identity (.env):  $AUTHOR"
    echo "  gh CLI (active):      $GH_CLI_USER"
    echo "  PRs will be created as '$GH_CLI_USER', not '$AUTHOR'."
    echo "  Fix: gh auth switch --user $AUTHOR"
    echo ""
  fi
  ( (
    _GH_LIVE=$(gh api user --jq '.login' 2>/dev/null || true)
    if [ -n "$_GH_LIVE" ]; then
      if [ "$(echo "$_GH_LIVE" | tr '[:upper:]' '[:lower:]')" != "$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]')" ]; then
        mkdir -p "$HOME/.egregore" 2>/dev/null
        printf '%s\n%s\n' "$AUTHOR" "$_GH_LIVE" > "$_GH_MISMATCH_FILE.tmp" \
          && mv "$_GH_MISMATCH_FILE.tmp" "$_GH_MISMATCH_FILE"
      else
        rm -f "$_GH_MISMATCH_FILE"
      fi
    fi
  ) >/dev/null 2>&1 & ) 2>/dev/null
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

# Model stamp hashes the git common-dir root because telemetry.sh resolves it that way.
MODEL_REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||') || MODEL_REPO_ROOT="$SCRIPT_DIR"
MODEL_PROJ_HASH=$(echo -n "$MODEL_REPO_ROOT" | md5 2>/dev/null || echo -n "$MODEL_REPO_ROOT" | md5sum 2>/dev/null | cut -d' ' -f1)
MODEL_STAMP_FILE="$SESSION_ID_DIR/session-model-${MODEL_PROJ_HASH}"
if [ -n "${CLAUDE_MODEL:-}" ]; then
  echo "$CLAUDE_MODEL" > "$MODEL_STAMP_FILE"
else
  rm -f "$MODEL_STAMP_FILE"
fi
