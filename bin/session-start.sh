#!/bin/bash
set -o pipefail

# Framework version — bumped on greeting/startup changes.
# Used for drift detection across team members.
FRAMEWORK_VERSION="2"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# --- Health tracking (rendered as dots in greeting) ---
HEALTH_GITHUB="skip"
HEALTH_GIT="skip"
HEALTH_APIKEY="skip"
HEALTH_GRAPH="skip"
HEALTH_TELEGRAM="skip"

# --- Config ---
STATE_FILE="$SCRIPT_DIR/.egregore-state.json"
DATE=$(date +%Y-%m-%d)

# --- Determine author identity ---
# Priority: .egregore-state.json github_username > repo-local git config > GitHub API auto-detect > global git config
ENV_FILE="$SCRIPT_DIR/.env"
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
          jq --arg u "$GH_LOGIN" --arg n "${GH_NAME:-$GH_LOGIN}" --arg ut "$USAGE_TYPE" \
            '.github_username = $u | .github_name = $n | .name = $n | .onboarding_complete = true | .usage_type = $ut' "$STATE_FILE" > "$STATE_FILE.tmp" \
            && mv "$STATE_FILE.tmp" "$STATE_FILE"
          FIRST_SESSION="false"
        else
          cat > "$STATE_FILE" << STATEEOF
{
  "github_username": "$GH_LOGIN",
  "github_name": "${GH_NAME:-$GH_LOGIN}",
  "name": "${GH_NAME:-$GH_LOGIN}",
  "onboarding_complete": true,
  "usage_type": "$USAGE_TYPE",
  "first_session": true
}
STATEEOF
          FIRST_SESSION="true"
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

# --- Check onboarding state ---
# If state file doesn't exist, assume onboarding complete (existing team member)
# State file is only created by onboarding flow for new orgs/users
ONBOARDING_COMPLETE="true"
if [ -f "$STATE_FILE" ]; then
  ONBOARDING_COMPLETE=$(jq -r '.onboarding_complete // false' "$STATE_FILE" 2>/dev/null || echo "true")
fi

if [ "$ONBOARDING_COMPLETE" != "true" ]; then
  echo "{\"onboarding_complete\": false, \"author\": \"$AUTHOR\"}"
  exit 0
fi

# --- Auto-provision or fix EGREGORE_API_KEY (background, non-blocking) ---
ENV_FILE="$SCRIPT_DIR/.env"
CONFIG="$SCRIPT_DIR/egregore.json"

# Check if key is missing OR if the key's slug doesn't match egregore.json slug
KEY_NEEDS_FIX="false"
if [ -f "$ENV_FILE" ]; then
  CURRENT_KEY=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
  EXPECTED_SLUG=$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)
  if [ -z "$CURRENT_KEY" ]; then
    KEY_NEEDS_FIX="true"
  elif [ -n "$EXPECTED_SLUG" ]; then
    # Extract slug from key: ek_<slug>_<secret> → <slug>
    KEY_SLUG=$(echo "$CURRENT_KEY" | cut -d'_' -f2)
    if [ "$KEY_SLUG" != "$EXPECTED_SLUG" ]; then
      KEY_NEEDS_FIX="true"
    fi
  fi
fi

# Track API key health
if [ "$KEY_NEEDS_FIX" = "true" ]; then
  HEALTH_APIKEY="fail"
elif [ -f "$ENV_FILE" ] && grep -q '^EGREGORE_API_KEY=.' "$ENV_FILE" 2>/dev/null; then
  HEALTH_APIKEY="ok"
else
  HEALTH_APIKEY="fail"
fi

if [ "$KEY_NEEDS_FIX" = "true" ]; then
  (
    GITHUB_TOKEN=$(grep '^GITHUB_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
    API_URL=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)
    GITHUB_ORG=$(jq -r '.github_org // empty' "$CONFIG" 2>/dev/null)

    if [ -n "$GITHUB_TOKEN" ] && [ -n "$API_URL" ] && [ -n "$GITHUB_ORG" ]; then
      SLUG=$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)
      if [ -z "$SLUG" ]; then
        # No slug in egregore.json — cannot safely derive one. Skip key fix.
        exit 0
      fi
      KEY_RESPONSE=$(curl -s -X GET "${API_URL}/api/org/${SLUG}/key" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        --connect-timeout 5 --max-time 10 2>/dev/null || echo "")

      if [ -n "$KEY_RESPONSE" ]; then
        FETCHED_KEY=$(echo "$KEY_RESPONSE" | jq -r '.api_key // empty' 2>/dev/null)
        if [ -n "$FETCHED_KEY" ] && [ "$FETCHED_KEY" != "null" ]; then
          # Safety: verify the fetched key's slug matches what we expected
          FETCHED_SLUG=$(echo "$FETCHED_KEY" | cut -d'_' -f2)
          if [ "$FETCHED_SLUG" = "$SLUG" ]; then
            # Replace existing key or append
            if grep -q '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null; then
              sed -i.bak "s|^EGREGORE_API_KEY=.*|EGREGORE_API_KEY=$FETCHED_KEY|" "$ENV_FILE"
              rm -f "$ENV_FILE.bak"
            else
              echo "EGREGORE_API_KEY=$FETCHED_KEY" >> "$ENV_FILE"
            fi
          fi
        fi
      fi
    fi
  ) &
fi

# --- Self-register in instance registry (for pre-registry installs) ---
# Wrapped in subshell — registration is optional, must not block session start
if command -v jq &>/dev/null && [ -f "$CONFIG" ]; then
  (
    REGISTRY_DIR="$HOME/.egregore"
    REGISTRY="$REGISTRY_DIR/instances.json"
    INST_SLUG=$(jq -r '.slug // empty' "$CONFIG")
    if [ -z "$INST_SLUG" ]; then
      # No slug in egregore.json — skip instance registration
      exit 0
    fi
    INST_NAME=$(jq -r '.org_name // empty' "$CONFIG")

    if [ -n "$INST_SLUG" ] && [ -n "$INST_NAME" ]; then
      mkdir -p "$REGISTRY_DIR"
      if [ ! -f "$REGISTRY" ]; then echo "[]" > "$REGISTRY"; fi

      ALREADY=$(jq --arg p "$SCRIPT_DIR" '[.[] | select(.path == $p)] | length' "$REGISTRY")
      if [ "$ALREADY" = "0" ]; then
        ENTRY=$(jq -n --arg s "$INST_SLUG" --arg n "$INST_NAME" --arg p "$SCRIPT_DIR" \
          '{slug: $s, name: $n, path: $p}')
        jq --argjson e "$ENTRY" '. + [$e]' "$REGISTRY" > "$REGISTRY.tmp" \
          && mv "$REGISTRY.tmp" "$REGISTRY"
      fi
    fi
  ) 2>/dev/null || true
fi

# --- Compute session boundary for environment isolation ---
compute_boundary() {
  local hash
  hash=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
  local boundary_file="/tmp/egregore-boundary-${hash}.json"
  local project_dir="$SCRIPT_DIR"

  # Resolve memory directory (follow symlink)
  local memory_dir=""
  if [ -L "$SCRIPT_DIR/memory" ]; then
    memory_dir=$(realpath "$SCRIPT_DIR/memory" 2>/dev/null || echo "")
  fi

  # Validate and resolve managed repos
  local managed_repos_json="[]"
  local parent_dir
  parent_dir="$(dirname "$SCRIPT_DIR")"
  local repos
  repos=$(jq -r '.repos[]? // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
  if [ -n "$repos" ]; then
    # Validate repos first
    bash "$SCRIPT_DIR/bin/boundary.sh" validate-repos 2>/dev/null || true
    managed_repos_json="["
    local first=true
    for repo in $repos; do
      # Skip entries with path traversal or absolute paths
      [[ "$repo" == *".."* ]] && continue
      [[ "$repo" == /* ]] && continue
      local resolved
      resolved=$(realpath "$parent_dir/$repo" 2>/dev/null || echo "")
      [ -z "$resolved" ] && continue
      # Must resolve under parent directory
      [[ "$resolved" != "$parent_dir"/* ]] && continue
      $first || managed_repos_json="$managed_repos_json,"
      managed_repos_json="$managed_repos_json\"$resolved\""
      first=false
    done
    managed_repos_json="$managed_repos_json]"
  fi

  # Collect denied paths from instance registry
  local denied_paths_json="[]"
  local registry="$HOME/.egregore/instances.json"
  if [ -f "$registry" ]; then
    denied_paths_json=$(jq --arg self "$project_dir" \
      '[.[] | select(.path != $self) | .path]' "$registry" 2>/dev/null || echo "[]")
  fi

  # Write boundary file (atomic: write to tmp, then mv)
  jq -n \
    --arg project_dir "$project_dir" \
    --arg memory_dir "$memory_dir" \
    --argjson managed_repos "$managed_repos_json" \
    --argjson denied_paths "$denied_paths_json" \
    '{project_dir: $project_dir, memory_dir: $memory_dir, managed_repos: $managed_repos, denied_paths: $denied_paths}' \
    > "$boundary_file.tmp" && mv "$boundary_file.tmp" "$boundary_file"

  # Generate dynamic deny rules in .claude/settings.local.json
  local settings_local="$SCRIPT_DIR/.claude/settings.local.json"
  local deny_rules="[]"
  if [ "$denied_paths_json" != "[]" ]; then
    deny_rules=$(echo "$denied_paths_json" | jq '[.[] | "Read(" + . + "/**)", "Edit(" + . + "/**)", "Write(" + . + "/**)"]')
  fi
  # Deny writing to instance registry (reads allowed for multi-instance features)
  deny_rules=$(echo "$deny_rules" | jq '. + ["Edit(~/.egregore/instances.json)", "Write(~/.egregore/instances.json)"]')

  # Merge with existing settings.local.json — only touch permissions.deny
  mkdir -p "$SCRIPT_DIR/.claude"
  if [ -f "$settings_local" ]; then
    jq --argjson deny "$deny_rules" '.permissions.deny = $deny' "$settings_local" \
      > "$settings_local.tmp" && mv "$settings_local.tmp" "$settings_local"
  else
    jq -n --argjson deny "$deny_rules" \
      '{permissions: {deny: $deny}}' > "$settings_local"
  fi
}

# Run boundary computation (non-blocking, but fast — just file I/O)
compute_boundary 2>/dev/null || true

# --- Fetch all remotes in parallel ---
# Set git transfer timeout so hangs don't block startup indefinitely.
export GIT_HTTP_LOW_SPEED_LIMIT=1000  # abort if <1KB/s
export GIT_HTTP_LOW_SPEED_TIME=10     # for 10 seconds

git fetch origin --quiet 2>/dev/null &

# Fetch upstream framework (for update check — non-blocking)
git remote add upstream https://github.com/Curve-Labs/egregore-core.git 2>/dev/null || true
git fetch upstream main --quiet 2>/dev/null &

# Sync memory in parallel
MEMORY_SYNCED="false"
if [ -L "$SCRIPT_DIR/memory" ] && [ -d "$SCRIPT_DIR/memory/.git" ]; then
  git -C "$SCRIPT_DIR/memory" fetch origin --quiet 2>/dev/null &
fi

# Fetch managed repos in parallel
MANAGED_REPOS=$(jq -r '.repos[]? // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
for REPO in $MANAGED_REPOS; do
  if [ -d "$SCRIPT_DIR/../$REPO/.git" ]; then
    git -C "$SCRIPT_DIR/../$REPO" fetch origin --quiet 2>/dev/null &
  fi
done

# Wait for all fetches
wait 2>/dev/null || true

# --- Git health check ---
if git show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then
  HEALTH_GIT="ok"
else
  HEALTH_GIT="fail"
fi

# --- Setup develop (wrapped — failures set HEALTH_GIT but don't crash) ---
setup_develop() {
  # Ensure develop branch exists locally
  if ! git show-ref --verify --quiet refs/heads/develop 2>/dev/null; then
    if git show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then
      git checkout -b develop origin/develop --quiet 2>/dev/null
    else
      # No develop on remote either — create from main
      git checkout -b develop --quiet 2>/dev/null
      git push -u origin develop --quiet 2>/dev/null
    fi
  fi

  # Sync develop (without checkout — safe for concurrent sessions)
  CURRENT_BRANCH=$(git branch --show-current)

  # Update local develop ref from remote without switching branches
  git fetch origin develop:develop --quiet 2>/dev/null || true
  DEVELOP_SYNCED="true"

  # Count commits on develop ahead of main
  COMMITS_AHEAD=0
  if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
    COMMITS_AHEAD=$(git rev-list origin/main..develop --count 2>/dev/null || echo "0")
  fi

  # Always start from develop
  # Every session begins on develop. Claude creates a fresh topic branch
  # (dev/{author}/{topic-slug}) when the user says what they're working on.
  # If we're on a working branch with uncommitted work, save it first.
  ACTION="ready"
  SAVED_BRANCH=""

  if [[ "$CURRENT_BRANCH" != "develop" ]]; then
    # Check for uncommitted work (staged + unstaged + untracked in tracked dirs)
    if [ -n "$(git status --porcelain 2>/dev/null | head -1)" ]; then
      # Save uncommitted work so nothing is lost
      git add -A 2>/dev/null
      git commit -m "Auto-save: uncommitted work from $CURRENT_BRANCH" --quiet 2>/dev/null || true
      SAVED_BRANCH="$CURRENT_BRANCH"
    fi

    # Push the branch if it has unpushed commits (so work is never only local)
    if [[ "$CURRENT_BRANCH" == dev/* ]] || [[ "$CURRENT_BRANCH" == feature/* ]] || [[ "$CURRENT_BRANCH" == bugfix/* ]]; then
      LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
      REMOTE_HEAD=$(git rev-parse "origin/$CURRENT_BRANCH" 2>/dev/null || echo "none")
      if [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
        git push origin "$CURRENT_BRANCH" --quiet 2>/dev/null || true
      fi
    fi

    # Switch to develop (already updated by fetch origin develop:develop above)
    git checkout develop --quiet 2>/dev/null || true
  else
    # Already on develop — fetch couldn't update it (checked-out branch), so pull
    git merge --ff-only origin/develop --quiet 2>/dev/null || true
  fi

  BRANCH="develop"
}

# Initialize defaults used by setup_develop
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
DEVELOP_SYNCED="false"
COMMITS_AHEAD=0
ACTION="ready"
SAVED_BRANCH=""
BRANCH="${CURRENT_BRANCH:-develop}"

if ! setup_develop 2>/dev/null; then
  HEALTH_GIT="fail"
fi

# --- Sync memory ---
if [ -L "$SCRIPT_DIR/memory" ] && [ -d "$SCRIPT_DIR/memory/.git" ]; then
  MEM_LOCAL=$(git -C "$SCRIPT_DIR/memory" rev-parse HEAD 2>/dev/null || echo "")
  MEM_REMOTE=$(git -C "$SCRIPT_DIR/memory" rev-parse origin/main 2>/dev/null || echo "")
  if [ -n "$MEM_LOCAL" ] && [ -n "$MEM_REMOTE" ] && [ "$MEM_LOCAL" != "$MEM_REMOTE" ]; then
    git -C "$SCRIPT_DIR/memory" pull origin main --quiet 2>/dev/null || true
  fi
  MEMORY_SYNCED="true"
fi

# --- Sync managed repos ---
REPOS_STATUS=""
for REPO in $MANAGED_REPOS; do
  REPO_DIR="$SCRIPT_DIR/../$REPO"
  if [ -d "$REPO_DIR/.git" ]; then
    # Ensure develop branch exists locally
    if ! git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/develop 2>/dev/null; then
      if git -C "$REPO_DIR" show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then
        git -C "$REPO_DIR" branch develop origin/develop --quiet 2>/dev/null || true
      fi
    else
      git -C "$REPO_DIR" fetch origin develop:develop --quiet 2>/dev/null || true
    fi
    # Collect status
    R_BRANCH=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo "?")
    R_DIRTY=""
    if [ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null | head -1)" ]; then
      R_DIRTY=" *"
    fi
    REPOS_STATUS="${REPOS_STATUS}  ◇ ${REPO}: ${R_BRANCH}${R_DIRTY}\n"
  fi
done

# --- Bootstrap graph on first launch (deferred from web setup to avoid orphans) ---
# Runs in background — must not block session start
if [ -f "$CONFIG" ] && [ -f "$ENV_FILE" ]; then
  (
    API_KEY=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
    if [ -n "$API_KEY" ]; then
      ORG_NAME=$(jq -r '.org_name // empty' "$CONFIG" 2>/dev/null)
      GITHUB_ORG=$(jq -r '.github_org // empty' "$CONFIG" 2>/dev/null)

      if [ -n "$ORG_NAME" ] && [ -n "$GITHUB_ORG" ]; then
        # Check if Org node exists — if not, bootstrap
        # $_org is auto-injected by the API from the API key
        EXISTS=$(bash "$SCRIPT_DIR/bin/graph.sh" query "MATCH (o:Org {id: \$_org}) RETURN o.id" 2>/dev/null || echo "")
        if echo "$EXISTS" | jq -e '.values | length == 0' &>/dev/null; then
          bash "$SCRIPT_DIR/bin/graph.sh" query \
            "MERGE (o:Org {id: \$_org}) SET o.name = \$name, o.github_org = \$github_org" \
            "{\"name\":\"$ORG_NAME\",\"github_org\":\"$GITHUB_ORG\"}" 2>/dev/null || true
          bash "$SCRIPT_DIR/bin/graph.sh" query \
            "MERGE (pr:Project {name: 'Egregore'}) WITH pr MATCH (o:Org {id: \$_org}) MERGE (pr)-[:PART_OF]->(o)" \
            2>/dev/null || true
        fi

        # Always ensure Person node exists (idempotent)
        # Match by github username first (stable across renames), fall back to name
        if [ -n "$AUTHOR" ]; then
          GH_USERNAME_STATE=""
          GH_FULLNAME_STATE=""
          if [ -f "$STATE_FILE" ]; then
            GH_USERNAME_STATE=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null)
            GH_FULLNAME_STATE=$(jq -r '.github_name // empty' "$STATE_FILE" 2>/dev/null)
          fi
          # Use display_name for p.name when set, otherwise fall back to github username
          GRAPH_NAME="${DISPLAY_NAME_STATE:-$AUTHOR}"
          PERSON_PARAMS=$(jq -n \
            --arg name "$GRAPH_NAME" \
            --arg github "${GH_USERNAME_STATE:-$AUTHOR}" \
            --arg fullName "${GH_FULLNAME_STATE:-}" \
            --arg hasDisplayName "$([ -n "$DISPLAY_NAME_STATE" ] && echo "true" || echo "false")" \
            '{name: $name, github: $github, fullName: $fullName, hasDisplayName: $hasDisplayName}')
          bash "$SCRIPT_DIR/bin/graph.sh" query \
            "MERGE (p:Person {github: \$github}) ON CREATE SET p.name = \$name SET p.fullName = CASE WHEN \$fullName <> '' THEN \$fullName ELSE p.fullName END SET p.name = CASE WHEN \$hasDisplayName = 'true' THEN \$name ELSE p.name END WITH p MATCH (o:Org {id: \$_org}) MERGE (p)-[:MEMBER_OF]->(o) RETURN p.name" \
            "$PERSON_PARAMS" 2>/dev/null || true

          # Sync user + membership to Supabase (non-blocking, non-fatal)
          SB_API_URL=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)
          if [ -n "$SB_API_URL" ]; then
            SB_BODY="{\"github_username\":\"${GH_USERNAME_STATE:-$AUTHOR}\",\"github_name\":\"${GH_FULLNAME_STATE:-}\"}"
            if [ -n "$DISPLAY_NAME_STATE" ]; then
              SB_BODY=$(echo "$SB_BODY" | jq --arg dn "$DISPLAY_NAME_STATE" '. + {display_name: $dn}')
            fi
            curl -sf "${SB_API_URL}/api/user/ensure" \
              -H "Authorization: Bearer $API_KEY" \
              -H "Content-Type: application/json" \
              -d "$SB_BODY" \
              --max-time 5 >/dev/null 2>&1 || true
          fi

          # Auto-capture: create personal Session node with status='active'
          AUTO_CAPTURE="true"
          if [ -f "$STATE_FILE" ]; then
            AUTO_CAPTURE=$(jq -r '.auto_capture // "true"' "$STATE_FILE" 2>/dev/null || echo "true")
          fi

          if [ "$AUTO_CAPTURE" = "true" ]; then
            SESSION_CYPHER="MATCH (p:Person) WHERE p.github = \$github OR toLower(p.name) = \$author
              MERGE (s:Session {id: \$sid})
              ON CREATE SET s.date = date(\$date), s.branch = \$branch,
                s.startedAt = datetime(), s.status = 'active'
              MERGE (s)-[:BY]->(p) RETURN s.id"
            SESSION_PARAMS=$(jq -n \
              --arg sid "$EGREGORE_SESSION_ID" \
              --arg author "$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]')" \
              --arg github "${GH_USERNAME_STATE:-$AUTHOR}" \
              --arg branch "$BRANCH" \
              --arg date "$(date +%Y-%m-%d)" \
              '{sid: $sid, author: $author, github: $github, branch: $branch, date: $date}')

            # WAL first (guaranteed persistence)
            bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$SESSION_CYPHER" "$SESSION_PARAMS" 2>/dev/null || true
            # Direct write (best effort, immediate)
            bash "$SCRIPT_DIR/bin/graph.sh" query "$SESSION_CYPHER" "$SESSION_PARAMS" 2>/dev/null || true
          fi
        fi
      fi
    fi
  ) &
fi

# --- Retry failed transcript uploads (background, silent) ---
RETRY_QUEUE="$SCRIPT_DIR/.transcript-retry-queue"
TRANSCRIPTS_DIR="$SCRIPT_DIR/../egregore-transcripts"
if [ -f "$RETRY_QUEUE" ] && [ -s "$RETRY_QUEUE" ]; then
  (
    RETRIED=false
    # If git repo exists, retry push (CL internal)
    if [ -d "$TRANSCRIPTS_DIR/.git" ]; then
      if git -C "$TRANSCRIPTS_DIR" push origin main 2>/dev/null; then
        RETRIED=true
      fi
    fi
    # If API is available, retry upload for queued sessions (customer orgs)
    if [ "$RETRIED" = "false" ] && [ -f "$CONFIG" ] && [ -f "$ENV_FILE" ]; then
      R_API_URL=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null || true)
      R_API_KEY=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || true)
      if [ -n "$R_API_URL" ] && [ -n "$R_API_KEY" ]; then
        REMAINING=""
        COUNT=0
        while IFS= read -r SID && [ $COUNT -lt 5 ]; do
          SID=$(echo "$SID" | tr -cd 'a-zA-Z0-9_-')
          [ -z "$SID" ] && continue
          # Re-run the archive for this session (it will find the transcript)
          RETRIED=true
          COUNT=$((COUNT + 1))
        done < "$RETRY_QUEUE"
        if [ "$RETRIED" = "true" ]; then
          # Clear queue on any progress — archive script will re-queue failures
          rm -f "$RETRY_QUEUE"
        fi
      fi
    fi
    if [ "$RETRIED" = "true" ]; then
      rm -f "$RETRY_QUEUE"
    fi
  ) >/dev/null 2>&1 &
fi

# --- Drain WAL (background, non-blocking) ---
bash "$SCRIPT_DIR/bin/graph-wal.sh" drain >/dev/null 2>&1 &

# --- Gather session context + service health in parallel (all background, no blocking) ---
CTX_DIR=$(mktemp -d)

# Time of day
HOUR=$(date +%H)
if [ "$HOUR" -lt 12 ]; then TIME_OF_DAY="morning"
elif [ "$HOUR" -lt 17 ]; then TIME_OF_DAY="afternoon"
else TIME_OF_DAY="evening"
fi

# 1. Recent handoffs (background)
(
  JSON="[]"
  if [ -d "$SCRIPT_DIR/memory/handoffs" ]; then
    FILES=$(ls -t "$SCRIPT_DIR/memory/handoffs/"*.md 2>/dev/null | grep -v index.md | head -3)
    JSON="["
    FIRST=true
    for F in $FILES; do
      [ -z "$F" ] && continue
      NAME=$(basename "$F" .md)
      PREVIEW=$(head -c 120 "$F" 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g')
      $FIRST || JSON="$JSON,"
      JSON="$JSON{\"name\":\"$NAME\",\"preview\":\"$PREVIEW\"}"
      FIRST=false
    done
    JSON="$JSON]"
  fi
  echo "$JSON" > "$CTX_DIR/handoffs"
) &

# 2. Quests (background)
(
  JSON="[]"
  if [ -d "$SCRIPT_DIR/memory/quests" ]; then
    JSON="["
    FIRST=true
    for F in "$SCRIPT_DIR/memory/quests/"*.md; do
      [ -e "$F" ] || continue
      echo "$F" | grep -q draft && continue
      NAME=$(basename "$F" .md)
      $FIRST || JSON="$JSON,"
      JSON="$JSON\"$NAME\""
      FIRST=false
    done
    JSON="$JSON]"
  fi
  echo "$JSON" > "$CTX_DIR/quests"
) &

# 3. User's last activity (background)
(
  git log --author="$AUTHOR" --format="%ar|%s" -1 2>/dev/null > "$CTX_DIR/activity" || echo "" > "$CTX_DIR/activity"
) &

# 4. Team recent memory commits (background)
(
  JSON="[]"
  if [ -d "$SCRIPT_DIR/memory/.git" ]; then
    JSON="["
    FIRST=true
    while IFS='|' read -r T_AUTHOR T_TIME T_MSG; do
      [ -z "$T_AUTHOR" ] && continue
      T_MSG_ESC=$(echo "$T_MSG" | sed 's/"/\\"/g')
      $FIRST || JSON="$JSON,"
      JSON="$JSON{\"author\":\"$T_AUTHOR\",\"time\":\"$T_TIME\",\"message\":\"$T_MSG_ESC\"}"
      FIRST=false
    done <<< "$(git -C "$SCRIPT_DIR/memory" log --format="%an|%ar|%s" -5 2>/dev/null)"
    JSON="$JSON]"
  fi
  echo "$JSON" > "$CTX_DIR/team"
) &

# 5. Soul self-summary (background)
(
  SUMMARY=""
  if [ -f "$SCRIPT_DIR/egregore.md" ]; then
    SUMMARY=$(sed -n '/^## Self-Summary/,/^##/p' "$SCRIPT_DIR/egregore.md" | sed '1d;/^##/d' | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  fi
  echo "$SUMMARY" > "$CTX_DIR/soul_summary"
) &

# 6. Handoffs addressed to user (background)
(
  JSON="[]"
  if [ -d "$SCRIPT_DIR/memory/handoffs" ]; then
    ADDRESSED=$(grep -rl "to: $AUTHOR\|to:$AUTHOR" "$SCRIPT_DIR/memory/handoffs/" 2>/dev/null | head -5 || true)
    JSON="["
    FIRST=true
    for AF in $ADDRESSED; do
      [ -z "$AF" ] && continue
      AF_NAME=$(basename "$AF" .md)
      $FIRST || JSON="$JSON,"
      JSON="$JSON\"$AF_NAME\""
      FIRST=false
    done
    JSON="$JSON]"
  fi
  echo "$JSON" > "$CTX_DIR/addressed"
) &

# 7. Graph health (background — zero added latency, runs in parallel)
(
  if bash "$SCRIPT_DIR/bin/graph.sh" test 2>/dev/null | grep -q "Connected"; then
    echo "ok"
  else
    echo "fail"
  fi
) > "$CTX_DIR/graph_health" 2>/dev/null &

# 8. Telegram health (background)
(
  if bash "$SCRIPT_DIR/bin/notify.sh" test 2>/dev/null | grep -q "connected"; then
    echo "ok"
  else
    echo "fail"
  fi
) > "$CTX_DIR/telegram_health" 2>/dev/null &

# Wait for all context gathering + health checks to finish
wait

# --- Read service health results ---
GRAPH_RESULT=$(cat "$CTX_DIR/graph_health" 2>/dev/null || echo "")
if [ -n "$GRAPH_RESULT" ]; then HEALTH_GRAPH="$GRAPH_RESULT"; fi
TELEGRAM_RESULT=$(cat "$CTX_DIR/telegram_health" 2>/dev/null || echo "")
if [ -n "$TELEGRAM_RESULT" ]; then HEALTH_TELEGRAM="$TELEGRAM_RESULT"; fi

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
# Humanize repo_name: egregore-0 → Egregore 0
REPO_NAME=$(jq -r '.repo_name // "egregore"' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
INSTANCE_NAME=$(echo "$REPO_NAME" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')
ORG_NAME=$(jq -r '.org_name // ""' "$SCRIPT_DIR/egregore.json" 2>/dev/null)

# Build the status line with right-aligned org name
SEPARATOR="  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"
echo "$SEPARATOR"

# Instance + org line (right-aligned org)
LEFT="  ◈ $INSTANCE_NAME"
RIGHT="$ORG_NAME"
LINE_WIDTH=67
LEFT_LEN=${#LEFT}
RIGHT_LEN=${#RIGHT}
PADDING=$((LINE_WIDTH - LEFT_LEN - RIGHT_LEN))
if [ "$PADDING" -lt 1 ]; then PADDING=1; fi
printf "%s%*s%s\n" "$LEFT" "$PADDING" "" "$RIGHT"

# User + branch + memory line
DISPLAY_NAME=""
if [ -f "$STATE_FILE" ]; then
  DISPLAY_NAME=$(jq -r '.display_name // .name // empty' "$STATE_FILE" 2>/dev/null)
fi
GREETING_NAME="${DISPLAY_NAME:-$AUTHOR}"

BRANCH_STATUS="$BRANCH · synced"
if [ "$COMMITS_AHEAD" -gt 0 ] 2>/dev/null; then
  BRANCH_STATUS="$BRANCH_STATUS · $COMMITS_AHEAD ahead"
fi

MEMORY_STATUS=""
if [ "$MEMORY_SYNCED" = "true" ]; then
  MEMORY_STATUS="◆ memory · synced"
fi

echo "  ◇ $GREETING_NAME        ⎇ $BRANCH_STATUS        $MEMORY_STATUS"

# --- Health dots ---
health_symbol() {
  case "$1" in
    ok)   printf "✓" ;;
    fail) printf "✗" ;;
    *)    printf "—" ;;
  esac
}

HEALTH_LINE="  ●"
HEALTH_LINE="$HEALTH_LINE github $(health_symbol "$HEALTH_GITHUB")"
HEALTH_LINE="$HEALTH_LINE  git $(health_symbol "$HEALTH_GIT")"
HEALTH_LINE="$HEALTH_LINE  api-key $(health_symbol "$HEALTH_APIKEY")"
HEALTH_LINE="$HEALTH_LINE  graph $(health_symbol "$HEALTH_GRAPH")"
HEALTH_LINE="$HEALTH_LINE  telegram $(health_symbol "$HEALTH_TELEGRAM")"
echo "$HEALTH_LINE"

# Show /checkup hint if anything failed
HAS_FAILURE="false"
for h in "$HEALTH_GITHUB" "$HEALTH_GIT" "$HEALTH_APIKEY" "$HEALTH_GRAPH" "$HEALTH_TELEGRAM"; do
  if [ "$h" = "fail" ]; then HAS_FAILURE="true"; break; fi
done
if [ "$HAS_FAILURE" = "true" ]; then
  echo "  ⚠ Issues detected — run /checkup to diagnose and fix"
fi

# Show auto-save notice if work was committed from a previous branch
if [ -n "$SAVED_BRANCH" ]; then
  echo "  ✓ Auto-saved uncommitted work on $SAVED_BRANCH"
fi

# Managed repos status
if [ -n "$REPOS_STATUS" ]; then
  printf "$REPOS_STATUS"
fi

# Auto-apply upstream framework updates (bin/, .claude/commands/, CLAUDE.md, skills/)
# Only update when upstream has NEW commits we don't have (forward-only).
# git log HEAD..upstream/main shows commits in upstream that aren't in our history.
UPSTREAM_NEW=$(git log HEAD..upstream/main --oneline -- bin/ .claude/commands/ CLAUDE.md skills/ 2>/dev/null || true)
if [ -n "$UPSTREAM_NEW" ]; then
  UPDATE_COUNT=$(echo "$UPSTREAM_NEW" | wc -l | tr -d ' ')
  # Check for uncommitted local changes to framework files (protects active development)
  LOCAL_FRAMEWORK_DIRTY=$(git diff -- bin/ .claude/commands/ CLAUDE.md skills/ 2>/dev/null || true)
  if [ -n "$LOCAL_FRAMEWORK_DIRTY" ]; then
    echo "  ⟳ Framework update available — run /update"
  elif git checkout upstream/main -- bin/ .claude/commands/ CLAUDE.md skills/ 2>/dev/null; then
    git add bin/ .claude/commands/ CLAUDE.md skills/ 2>/dev/null
    git commit -m "Auto-update Egregore framework" --quiet 2>/dev/null || true
    echo "  ✓ Framework updated"
  else
    echo "  ⟳ Framework update available — run /update"
  fi
fi

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

cat << CTXEOF

<!-- session-context
{
  "framework_version": "$FRAMEWORK_VERSION",
  "time_of_day": "$TIME_OF_DAY",
  "recent_handoffs": $CONTEXT_HANDOFFS,
  "addressed_to_user": $CONTEXT_ADDRESSED,
  "quests": $CONTEXT_QUESTS,
  "last_user_activity": "$CONTEXT_ACTIVITY",
  "team_recent_memory": $CONTEXT_TEAM,
  "soul_self_summary": "$CONTEXT_SOUL"
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
