#!/usr/bin/env bash
set -o pipefail

# Framework version — bumped on greeting/startup changes.
# Used for drift detection across team members.
FRAMEWORK_VERSION="2"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# --- Worktree detection ---
# Git worktrees have .git as a FILE (not directory) pointing to the main repo's .git/worktrees/
IS_WORKTREE="false"
MAIN_PROJECT_DIR="$SCRIPT_DIR"
if [ -f "$SCRIPT_DIR/.git" ]; then
  IS_WORKTREE="true"
  WT_GITDIR=$(sed 's/^gitdir: //' "$SCRIPT_DIR/.git" 2>/dev/null)
  MAIN_PROJECT_DIR=$(cd "$WT_GITDIR/../../.." 2>/dev/null && pwd)
fi

# Clear any branch-guard consent from a previous session — consent to write on
# a protected branch is asked fresh each session (see CLAUDE.md branch-guard protocol).
rm -f "$SCRIPT_DIR/.egregore-branch-consent" "$MAIN_PROJECT_DIR/.egregore-branch-consent" 2>/dev/null

# --- Health tracking (rendered as dots in greeting) ---
HEALTH_GITHUB="skip"
HEALTH_GIT="skip"
HEALTH_APIKEY="skip"
HEALTH_GRAPH="skip"
HEALTH_TELEGRAM="skip"

# --- Config ---
STATE_FILE="$SCRIPT_DIR/.egregore-state.json"
ENV_FILE="$SCRIPT_DIR/.env"
CONFIG="$SCRIPT_DIR/egregore.json"
DATE=$(date +%Y-%m-%d)

# --- Source shared libs ---
source "$SCRIPT_DIR/bin/lib/config.sh"
source "$SCRIPT_DIR/bin/lib/hash.sh"
source "$SCRIPT_DIR/bin/lib/time.sh"

# ============================================================
# 1. Resolve identity
# ============================================================
source "$SCRIPT_DIR/bin/lib/identity.sh"

# ============================================================
# 2. Ensure develop branch exists (needed before onboarding creates working branches)
# ============================================================
if ! git show-ref --verify --quiet refs/heads/develop 2>/dev/null; then
  if git show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then
    git checkout -b develop origin/develop --quiet 2>/dev/null
    git checkout - --quiet 2>/dev/null
  else
    git branch develop --quiet 2>/dev/null
    git push -u origin develop --quiet 2>/dev/null &
  fi
fi

# ============================================================
# 2.5 Sync managed repos — fetch and ensure base branch tracking (background)
# ============================================================
(
  _managed_repos=$(jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
  [ -z "$_managed_repos" ] && exit 0
  _parent_dir="$(dirname "$SCRIPT_DIR")"
  for _repo in $_managed_repos; do
    _repo_path="$_parent_dir/$_repo"
    [ -d "$_repo_path/.git" ] || continue
    git -C "$_repo_path" fetch origin --quiet 2>/dev/null || true
    # Ensure local tracking branch for repo's base branch
    _base=$(_get_base_branch "$_repo")
    if ! git -C "$_repo_path" show-ref --verify --quiet "refs/heads/$_base" 2>/dev/null; then
      if git -C "$_repo_path" show-ref --verify --quiet "refs/remotes/origin/$_base" 2>/dev/null; then
        git -C "$_repo_path" branch "$_base" "origin/$_base" --quiet 2>/dev/null || true
      fi
    fi
  done
) &

# ============================================================
# 3. Check onboarding state
# ============================================================
ONBOARDING_COMPLETE="true"
if [ -f "$STATE_FILE" ]; then
  ONBOARDING_COMPLETE=$(jq -r '.onboarding_complete // false' "$STATE_FILE" 2>/dev/null || echo "true")
fi

# Self-heal: state says incomplete but a completion witness exists →
# onboarding finished, the state write was lost. See SKILL.md "Completion witness".
# Three witnesses, in order of strength:
#   1. `^Onboarded:` in person file — explicit, written by new flow's step 1
#   2. `^# ` H1 in person file — back-compat, matches any pre-PR-544 person
#      file (real onboardings always start with a markdown header). Excludes
#      invite stubs which use `---` YAML frontmatter.
#   3. `### {display_name}` under egregore.md `## Members` — fallback for
#      cases where the person file is missing/corrupted but Members has them.
if [ "$ONBOARDING_COMPLETE" != "true" ] && [ -n "$AUTHOR" ]; then
  PEOPLE_FILE="$SCRIPT_DIR/memory/people/${AUTHOR}.md"
  WITNESSED="false"
  if [ -f "$PEOPLE_FILE" ]; then
    if grep -q '^Onboarded:' "$PEOPLE_FILE" 2>/dev/null; then
      WITNESSED="true"
    elif head -1 "$PEOPLE_FILE" 2>/dev/null | grep -q '^# '; then
      WITNESSED="true"
    fi
  fi
  if [ "$WITNESSED" != "true" ] && [ -n "$DISPLAY_NAME_STATE" ] && [ -f "$SCRIPT_DIR/egregore.md" ]; then
    sed -n '/^## Members/,/^## /p' "$SCRIPT_DIR/egregore.md" 2>/dev/null \
      | grep -qx "### ${DISPLAY_NAME_STATE}" && WITNESSED="true"
  fi
  if [ "$WITNESSED" = "true" ] && [ -f "$STATE_FILE" ]; then
    jq '.onboarding_complete = true | .onboarding.phase = "complete"' "$STATE_FILE" > "$STATE_FILE.tmp" \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"
    ONBOARDING_COMPLETE="true"
  fi
fi

if [ "$ONBOARDING_COMPLETE" != "true" ]; then
  # Output as a single compact line — Claude reads it, user doesn't need to see it
  echo "onboarding_needed author=$AUTHOR"
  exit 0
fi

# ============================================================
# 3. Detect mode + provision API key
# ============================================================
LOCAL_MODE="false"
[ "$(_detect_mode)" = "local" ] && LOCAL_MODE="true"

# In local mode, skip all key validation and auto-fix
KEY_NEEDS_FIX="false"
HEALTH_APIKEY="skip"

if [ "$LOCAL_MODE" != "true" ]; then
  # Check if key is missing OR if the key's slug doesn't match egregore.json slug
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

# ============================================================
# 4. Instance registry + boundary
# ============================================================

# --- Self-register in instance registry (for pre-registry installs) ---
# Worktrees should NOT register as separate instances
# Wrapped in subshell — registration is optional, must not block session start
if [ "$IS_WORKTREE" = "false" ] && command -v jq &>/dev/null && [ -f "$CONFIG" ]; then
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
  repos=$(jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
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
    denied_paths_json=$(jq --arg self "$project_dir" --arg wt_prefix "$project_dir/.claude/worktrees" \
      '[.[] | select(.path != $self) | select((.path | startswith($wt_prefix)) | not) | .path]' \
      "$registry" 2>/dev/null || echo "[]")
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
    deny_rules=$(echo "$denied_paths_json" | jq '[.[] | "Read(" + . + "/**)", "Edit(" + . + "/**)"]')
  fi
  # Deny writing to instance registry (reads allowed for multi-instance features).
  # Edit() alone covers Write/NotebookEdit too — Write() rules are never matched by
  # the permission checker and only trigger a startup "not matched" warning if included.
  deny_rules=$(echo "$deny_rules" | jq '. + ["Edit(~/.egregore/instances.json)"]')

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

# ============================================================
# 5. Git sync
# ============================================================
source "$SCRIPT_DIR/bin/lib/git-sync.sh"

# ============================================================
# 6. Graph bootstrap
# ============================================================

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
            "$(jq -n --arg name "$ORG_NAME" --arg github_org "$GITHUB_ORG" '{name: $name, github_org: $github_org}')" 2>/dev/null || true
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
            SB_BODY=$(jq -n --arg gu "${GH_USERNAME_STATE:-$AUTHOR}" --arg gn "${GH_FULLNAME_STATE:-}" \
              '{github_username: $gu, github_name: $gn}')
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
            SESSION_CYPHER="MATCH (p:Person {github: \$github})
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

# ============================================================
# 7. Transcript retry + WAL drain
# ============================================================

# --- Retry failed transcript uploads (background, silent) ---
RETRY_QUEUE="$SCRIPT_DIR/.transcript-retry-queue"
TRANSCRIPTS_DIR=$(jq -r '.transcripts_dir // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
[ -z "$TRANSCRIPTS_DIR" ] && TRANSCRIPTS_DIR="$SCRIPT_DIR/../egregore-transcripts"
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

# ============================================================
# 7b. Session baseline (for session-log.sh delta computation)
# ============================================================
BASELINE_FILE="/tmp/egregore-baseline-${EGREGORE_SESSION_ID}.json"
jq -n \
  --arg branch "$BRANCH" \
  --arg commit "$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo '')" \
  --argjson dirty "$([ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null | head -1)" ] && echo 'true' || echo 'false')" \
  --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{branch: $branch, commit: $commit, dirty: $dirty, started_at: $started_at}' \
  > "$BASELINE_FILE" 2>/dev/null || true

# ============================================================
# 8. Gather context
# ============================================================
source "$SCRIPT_DIR/bin/lib/context.sh"

# ============================================================
# 8b. Generate session dashboard artifact
# ============================================================
source "$SCRIPT_DIR/bin/lib/dashboard-artifact.sh"

# Stable board URL — shown in greeting, refreshable. Connected mode only;
# /view board upserts content at this URL via `publish-artifact.sh --id board`.
BOARD_URL=""
if [ "${LOCAL_MODE:-false}" != "true" ] && [ -f "$SCRIPT_DIR/memory/board/board.json" ]; then
  _ORG_SLUG=$(jq -r '.slug // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
  if [ -n "$_ORG_SLUG" ]; then
    BOARD_URL="https://egregore.xyz/view/${_ORG_SLUG}/board"
  fi
fi

# ============================================================
# 9. Render greeting
# ============================================================
source "$SCRIPT_DIR/bin/lib/greeting.sh"
