#!/usr/bin/env bash
set -o pipefail

# Framework version — bumped on greeting/startup changes.
# Used for drift detection across team members.
FRAMEWORK_VERSION="8"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# --- Card delivery by contract (bin/lib/card-delivery.sh) ---
# Inside a Claude Code hook the harness shows the card to the user (hook
# systemMessage) and the model receives only the context, so the model never
# retypes it. The launcher-printed card (#1420/#1472) could not do this: Claude
# Code ≥2.1.89 boots into the alternate screen and hid it (#1493).
# The startup runs as an inner pass with its stdout captured to a file:
# anything printed before the greeting (worktree warnings, repo checks,
# onboarding_needed) stays out of the JSON, and detached jobs inherit the file
# rather than the hook's pipe. With a fresh saved card the outer pass instead
# runs a quick pass (per-session work only), shows the saved card, and runs
# the full startup detached as a refresh pass. Harness mode exists only inside
# these passes, so a run that cannot capture falls back to the plain greeting
# and its display instruction.
source "$SCRIPT_DIR/bin/lib/card-delivery.sh"
_CARD_PASS=""
case "${_EGREGORE_CARD_PASS:-}" in
  inner|quick|refresh)
    _CARD_PASS="$_EGREGORE_CARD_PASS"
    EGREGORE_CARD_DELIVERY="harness"
    export -n EGREGORE_CARD_DELIVERY _EGREGORE_CARD_PASS 2>/dev/null || true
    ;;
  *)
    if [ "$(egregore_card_delivery_mode)" = "harness" ]; then
      egregore_card_outer_pass "$SCRIPT_DIR" "$FRAMEWORK_VERSION"
    fi
    EGREGORE_CARD_DELIVERY="text"
    ;;
esac

# --- Transient development-checkout detection ---
# Git worktrees have .git as a FILE. The launcher also marks standalone
# development clones as transient so startup preserves their feature branch
# and never registers them as a second Egregore instance.
IS_WORKTREE="false"
MAIN_PROJECT_DIR="$SCRIPT_DIR"
if [ -f "$SCRIPT_DIR/.git" ]; then
  IS_WORKTREE="true"
  WT_GITDIR=$(sed 's/^gitdir: //' "$SCRIPT_DIR/.git" 2>/dev/null)
  MAIN_PROJECT_DIR=$(cd "$WT_GITDIR/../../.." 2>/dev/null && pwd)
elif [ "${EGREGORE_TRANSIENT_CHECKOUT:-0}" = "1" ]; then
  IS_WORKTREE="true"
fi

# Defensive net: re-link worktree shared state (symlinks to the main checkout's
# memory/, .env, state files). worktree-create.sh links at creation; this heals
# links that were removed or broke since.
if [ -f "$SCRIPT_DIR/bin/lib/worktree-links.sh" ]; then
  source "$SCRIPT_DIR/bin/lib/worktree-links.sh" >/dev/null 2>/dev/null || true
  egregore_link_shared_state "$SCRIPT_DIR" "$MAIN_PROJECT_DIR" >/dev/null 2>/dev/null || true
fi

# A refresh pass runs after the session is live: the quick pass already reset
# consent, and a grant the user gave since then must survive.
if [ "$_CARD_PASS" != "refresh" ]; then
# Clear any branch-guard consent from a previous session — consent to write on
# a protected branch is asked fresh each session (see CLAUDE.md branch-guard protocol).
rm -f "$SCRIPT_DIR/.egregore-branch-consent" "$MAIN_PROJECT_DIR/.egregore-branch-consent" 2>/dev/null
# Same for boundary-crossing consent — grants are session-scoped (CLAUDE.md
# environment-isolation protocol); durable grants belong in .egregore-boundary.local.json.
rm -f "$SCRIPT_DIR/.egregore-boundary-consent" "$MAIN_PROJECT_DIR/.egregore-boundary-consent" 2>/dev/null
# Prune abandoned scratch without blocking startup or fresh sibling work.
( bash "$SCRIPT_DIR/bin/scratch-sweep.sh" --older-than 60 >/dev/null 2>&1 & ) 2>/dev/null
fi

# --- Health tracking (rendered as dots in greeting) ---
HEALTH_GITHUB="skip"
HEALTH_GIT="skip"
HEALTH_MEMORY="skip"
HEALTH_RETRIEVAL="skip"
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

# Opt-in monotonic phase tracing (EGREGORE_STARTUP_TRACE=1); traces land in
# ~/.egregore/runtime/startup-traces, normal output is untouched.
source "$SCRIPT_DIR/bin/lib/trace.sh" 2>/dev/null || true
egregore_trace_begin "session-start" 2>/dev/null || true
egregore_trace_mark "libs-loaded" 2>/dev/null || true

# ============================================================
# 1. Resolve identity
# ============================================================
# Claude Code hands this hook its own session id on stdin. identity.sh maps
# it to the Egregore id it mints (bin/session-id.sh), so this session's
# commits resolve their own id. Shell variables only: daemons started here
# outlive the session and must not inherit it. Only a SessionStart hook run
# (Claude Code sets CLAUDE_ENV_FILE for those alone) reads stdin; every other
# run, manual or scripted, never waits on it and maps nothing.
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  _HOOK_INPUT=""
  IFS= read -r -t 1 -d '' _HOOK_INPUT || true
  _HOOK_SESSION=$(printf '%s' "$_HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
  if [ -n "$_HOOK_SESSION" ]; then
    EGREGORE_NATIVE_SESSION_ID="$_HOOK_SESSION" EGREGORE_NATIVE_HARNESS=claude
    EGREGORE_START_HARNESS=claude
  fi
  unset _HOOK_INPUT _HOOK_SESSION
fi
source "$SCRIPT_DIR/bin/lib/identity.sh"
egregore_trace_mark "identity" 2>/dev/null || true

# ============================================================
# 2. Ensure the base branch exists (needed before onboarding creates working branches)
# ============================================================
# BASE_BRANCH is "develop" unless egregore.json sets base_branch. With
# base_branch: "main" this whole block is a no-op — main already exists locally
# and on the remote — which is the point: single-branch instances never get a
# second branch created, and never get one pushed to their remote.
if ! BASE_BRANCH=$(_get_base_branch); then
  echo "ERROR: Could not resolve the configured base branch; startup stopped before branch changes." >&2
  exit 1
fi
if ! git show-ref --verify --quiet "refs/heads/$BASE_BRANCH" 2>/dev/null; then
  if git show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH" 2>/dev/null; then
    git checkout -b "$BASE_BRANCH" "origin/$BASE_BRANCH" --quiet 2>/dev/null
    git checkout - --quiet 2>/dev/null
  else
    git branch "$BASE_BRANCH" --quiet 2>/dev/null
    # Double-fork: detached from the job table so later `wait`s don't block on
    # it. stdout must be redirected too — a detached child inheriting the
    # hook's stdout pipe keeps it open and the harness waits on it anyway.
    ( git push -u origin "$BASE_BRANCH" --quiet >/dev/null 2>&1 & ) 2>/dev/null
  fi
fi

# Managed repos are fetched (in parallel) and their base branches ensured by
# git-sync.sh below. A previous version also fetched them here sequentially in
# a background subshell — git-sync's `wait` then blocked on that subshell,
# adding ~2s per repo of duplicate network time to every boot.

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
  # A key needs fixing only when it's missing or the API rejects it (401/403).
  # A slug mismatch alone is NOT failure: after an org rename the old-slug key
  # can be the only key bound to the org's data — replacing it silently empties
  # every graph read. Slug match is just the no-network fast path.
  if [ -f "$ENV_FILE" ]; then
    CURRENT_KEY=$(grep '^EGREGORE_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
    EXPECTED_SLUG=$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)
    if [ -z "$CURRENT_KEY" ]; then
      KEY_NEEDS_FIX="true"
      HEALTH_APIKEY="fail"
    else
      # Extract slug from key: ek_<slug>_<secret> → <slug>
      KEY_SLUG=$(echo "$CURRENT_KEY" | cut -d'_' -f2)
      if [ -n "$EXPECTED_SLUG" ] && [ "$KEY_SLUG" != "$EXPECTED_SLUG" ] \
         && _graph_projection_enabled; then
        # Slug differs from config — ask the API whether the key actually works
        PROBE_URL=$(_config_api_url) || PROBE_URL=""
        PROBE_CODE="000"
        if [ -n "$PROBE_URL" ]; then
          PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer $CURRENT_KEY" \
            "${PROBE_URL}/api/graph/test" \
            --connect-timeout 3 --max-time 5 2>/dev/null || echo "000")
        fi
        case "$PROBE_CODE" in
          401|403)
            KEY_NEEDS_FIX="true"
            HEALTH_APIKEY="fail"
            ;;
          *)
            # 200: valid key under a legacy slug — keep it.
            # Anything else: network/API down — never replace a key on a blip;
            # the graph health check surfaces outages separately.
            HEALTH_APIKEY="ok"
            ;;
        esac
      else
        HEALTH_APIKEY="ok"
      fi
    fi
  else
    HEALTH_APIKEY="fail"
  fi
fi

if [ "$KEY_NEEDS_FIX" = "true" ] && [ "$_CARD_PASS" != "quick" ]; then
  # Plain background job, NOT double-forked: git-sync's `wait` must join this
  # before the graph bootstrap runs — a repaired key that lands after boot
  # means that launch already skipped auto-capture with no WAL entry to
  # recover the Session. The join costs nothing on healthy boots (the key is
  # fine, this block never runs) and bounds broken-key boots at curl's 10s cap.
  (
    GITHUB_TOKEN=$(grep '^GITHUB_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
    API_URL=$(_config_api_url) || API_URL=""
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
  ) >/dev/null 2>&1 &
fi

# ============================================================
# 4. Instance registry + boundary
# ============================================================

# --- Instance registry maintenance (bin/lib/instance-registry.sh) ---
# Prune entries that are runtime state of another instance (a checkout inside
# its .egregore/, such as an evaluation sandbox), then self-register this
# checkout (for pre-registry installs). Worktrees should NOT register as
# separate instances, and neither does runtime state. Wrapped in a subshell —
# maintenance is optional and must not block session start.
if [ "$_CARD_PASS" != "quick" ] && command -v jq &>/dev/null && [ -f "$SCRIPT_DIR/bin/lib/instance-registry.sh" ]; then
  ( (
    REGISTRY_DIR="$HOME/.egregore"
    REGISTRY="$REGISTRY_DIR/instances.json"
    source "$SCRIPT_DIR/bin/lib/instance-registry.sh"
    egregore_registry_prune "$REGISTRY"
    if [ "$IS_WORKTREE" = "false" ] && [ -f "$CONFIG" ]; then
      # Registration needs a slug and org_name in egregore.json; without them it does nothing.
      INST_SLUG=$(jq -r '.slug // empty' "$CONFIG")
      INST_NAME=$(jq -r '.org_name // empty' "$CONFIG")
      INST_ORG=$(jq -r '.org_id // empty' "$CONFIG")
      egregore_registry_register "$REGISTRY" "$SCRIPT_DIR" "$INST_SLUG" "$INST_NAME" "$INST_ORG"
    fi
  ) >/dev/null 2>&1 & ) 2>/dev/null || true
fi

# --- Compute session boundary for environment isolation ---
compute_boundary() {
  # repos[] traversal warnings stay visible in the greeting.
  if [ -n "$(jq -r '(.repos[]? // empty)' "$SCRIPT_DIR/egregore.json" 2>/dev/null)" ]; then
    bash "$SCRIPT_DIR/bin/boundary.sh" validate-repos 2>/dev/null || true
  fi

  # Memory, managed repos, denied instances (only checkouts proven to share
  # this instance's org_id are excluded; ancestry or a slug proves nothing),
  # posture and read roots come from one shared computation — the same one the
  # Codex/Pi/Prime session start, worktree creation, and every pre-action
  # check use. An unreadable registry is recorded, never read as empty.
  local deny_rules settings_local="$SCRIPT_DIR/.claude/settings.local.json"
  bash "$SCRIPT_DIR/bin/node-run.sh" "$SCRIPT_DIR/bin/boundary-guard.cjs" write-cache "$SCRIPT_DIR" >/dev/null 2>&1 || true

  # Claude's native deny rules (a second line of defence behind the hook):
  # generated by the same module, so they carry its self-scope carve-out and
  # registry protection instead of a second copy of the rules.
  deny_rules=$(bash "$SCRIPT_DIR/bin/node-run.sh" "$SCRIPT_DIR/bin/boundary-guard.cjs" native-denials "$SCRIPT_DIR" 2>/dev/null) || return 0
  printf '%s' "$deny_rules" | jq -e 'type == "array"' >/dev/null 2>&1 || return 0

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

# Run boundary computation (non-blocking, but fast — just file I/O). The
# quick pass already wrote it for a refreshing session.
[ "$_CARD_PASS" != "refresh" ] && { compute_boundary 2>/dev/null || true; }

# The quick pass ends here: the per-session work is done and the outer pass
# shows the saved card, then runs everything below as a detached refresh.
# That refresh leaves working trees alone under the live session
# (EGREGORE_GIT_SYNC_LIVE), so the checkout and the managed repos on their
# base branch catch up to the last fetch here: local, no network. The fast
# path runs only on the base branch.
if [ "$_CARD_PASS" = "quick" ]; then
  # No hooks: a post-merge hook must never stall the hook's quick path.
  if [ "$(git branch --show-current 2>/dev/null)" = "$BASE_BRANCH" ]; then
    git -c core.hooksPath=/dev/null merge --ff-only "origin/$BASE_BRANCH" --quiet >/dev/null 2>&1 || true
  fi
  for _REPO in $(jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' "$SCRIPT_DIR/egregore.json" 2>/dev/null); do
    case "$_REPO" in *..*|/*) continue ;; esac  # as bin/boundary.sh: siblings only
    _REPO_DIR="$SCRIPT_DIR/../$_REPO"
    [ -d "$_REPO_DIR/.git" ] || continue
    _REPO_BASE=$(_get_base_branch "$_REPO" 2>/dev/null) || continue
    [ "$(git -C "$_REPO_DIR" branch --show-current 2>/dev/null)" = "$_REPO_BASE" ] || continue
    git -C "$_REPO_DIR" -c core.hooksPath=/dev/null merge --ff-only "origin/$_REPO_BASE" --quiet >/dev/null 2>&1 || true
  done
  egregore_trace_end 2>/dev/null || true
  printf 'egregore-quick-ok %s\n' "$EGREGORE_SESSION_ID"
  exit 0
fi
[ "$_CARD_PASS" = "refresh" ] && EGREGORE_GIT_SYNC_LIVE=1

# ============================================================
# 5. Git sync
# ============================================================
egregore_trace_mark "branch-onboarding-mode-boundary" 2>/dev/null || true
source "$SCRIPT_DIR/bin/lib/startup-restart.sh"
_STARTUP_HEAD=$(egregore_startup_head)
source "$SCRIPT_DIR/bin/lib/git-sync.sh"
egregore_trace_mark "git-sync" 2>/dev/null || true
# A sync that pulled a newer startup finishes on it (bin/lib/startup-restart.sh),
# in the same card pass.
[ -n "$_CARD_PASS" ] && export _EGREGORE_CARD_PASS="$_CARD_PASS"
egregore_startup_restart "$_STARTUP_HEAD" "$SCRIPT_DIR/bin/session-start.sh"
export -n _EGREGORE_CARD_PASS 2>/dev/null || true
unset _STARTUP_HEAD

# Resolve a legacy instance's stable Runtime identity before SessionStart
# finishes and UserPromptSubmit can invoke Observe. Once persisted this is a
# local status check; a control-plane outage never blocks the harness.
if [ -f "$SCRIPT_DIR/bin/runtime-identity.sh" ]; then
  bash "$SCRIPT_DIR/bin/runtime-identity.sh" ensure >/dev/null 2>&1 || true
fi
egregore_trace_mark "runtime-identity" 2>/dev/null || true

# ============================================================
# 6. Graph bootstrap
# ============================================================

# --- Bootstrap graph on first launch (deferred from web setup to avoid orphans) ---
# Runs detached (double-fork) — must not block session start, and context.sh's
# `wait` must not block on it either. stdout goes to /dev/null: the session
# MERGE query RETURNs s.id, which used to leak a raw JSON line into the greeting.
if [ -f "$CONFIG" ] && [ -f "$ENV_FILE" ]; then
  ( (
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

        # Reconcile one canonical member across markdown, Supabase, and Neo4j.
        # GitHub's numeric id is stable across login and preferred-name changes.
        if [ -n "$AUTHOR" ]; then
          PERSON_SYNC_RESULT=$(bash "$SCRIPT_DIR/bin/person.sh" sync 2>/dev/null || true)
          if printf '%s' "$PERSON_SYNC_RESULT" | jq -e \
            '.status == "removed"' >/dev/null 2>&1; then
            exit 0
          fi
          GH_USERNAME_STATE=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null)
          PERSON_ID_STATE=$(jq -r \
            '.person_id // ("github-login:" + ((.github_username // "") | ascii_downcase))' \
            "$STATE_FILE" 2>/dev/null)

          # Auto-capture: create personal Session node with status='active'
          AUTO_CAPTURE="true"
          if [ -f "$STATE_FILE" ]; then
            AUTO_CAPTURE=$(jq -r '.auto_capture // "true"' "$STATE_FILE" 2>/dev/null || echo "true")
          fi

          if [ "$AUTO_CAPTURE" = "true" ]; then
            # Match by canonical personId OR github login. State files written
            # before the numeric-id migration carry person_id
            # "github-login:<name>" while the graph Person holds
            # "github:<numeric>" — the exact-personId MATCH found no row, the
            # MERGE below silently never ran, and no Session was captured.
            # Filters mirror the canonical Person lookup in identity.sh
            # (active, not ingested), and the ORDER BY makes the pick TOTALLY
            # ordered — exact personId first, then personId, then the node's
            # internal id as final tie-breaker (personId has no uniqueness
            # constraint) — so a later WAL replay resolves to the same node as
            # the direct write and the Session never gains two BY edges.
            SESSION_CYPHER="MATCH (p:Person)
              WHERE (p.personId = \$personId OR toLower(p.github) = toLower(\$github))
                AND NOT coalesce(p.kind, '') IN ['external', 'identity_alias']
                AND coalesce(p.status, 'active') = 'active'
                AND p.ingestRef IS NULL
              WITH p ORDER BY
                CASE WHEN p.personId = \$personId THEN 0 ELSE 1 END,
                p.personId, id(p)
              LIMIT 1
              MERGE (s:Session {id: \$sid})
              ON CREATE SET s.date = date(\$date), s.branch = \$branch,
                s.startedAt = datetime(), s.status = 'active'
              MERGE (s)-[:BY]->(p) RETURN s.id"
            SESSION_PARAMS=$(jq -n \
              --arg sid "$EGREGORE_SESSION_ID" \
              --arg author "$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]')" \
              --arg github "${GH_USERNAME_STATE:-$AUTHOR}" \
              --arg personId "$PERSON_ID_STATE" \
              --arg branch "$BRANCH" \
              --arg date "$(date +%Y-%m-%d)" \
              '{sid: $sid, author: $author, github: $github, personId: $personId, branch: $branch, date: $date}')

            # WAL first (guaranteed persistence)
            bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$SESSION_CYPHER" "$SESSION_PARAMS" 2>/dev/null || true
            # Direct write (best effort, immediate)
            bash "$SCRIPT_DIR/bin/graph.sh" query "$SESSION_CYPHER" "$SESSION_PARAMS" 2>/dev/null || true
          fi
        fi
      fi
    fi
  ) >/dev/null 2>&1 & ) 2>/dev/null
fi

# ============================================================
# 7. Transcript retry + WAL drain
# ============================================================

# --- Retry failed transcript uploads (background, silent) ---
RETRY_QUEUE="$SCRIPT_DIR/.transcript-retry-queue"
TRANSCRIPTS_DIR=$(jq -r '.transcripts_dir // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
[ -z "$TRANSCRIPTS_DIR" ] && TRANSCRIPTS_DIR="$SCRIPT_DIR/../egregore-transcripts"
if [ -f "$RETRY_QUEUE" ] && [ -s "$RETRY_QUEUE" ]; then
  ( (
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
  ) >/dev/null 2>&1 & ) 2>/dev/null
fi

# --- Drain WAL (detached, non-blocking) ---
( bash "$SCRIPT_DIR/bin/graph-wal.sh" drain >/dev/null 2>&1 & ) 2>/dev/null

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
# 7c. Attendant — background daemon (fire-and-forget)
# ============================================================
# Keeps the launch path warm (refs, graph cache, context seed), runs the
# handoff lifecycle job, and triggers the Thread projection when idle.
# `ensure` is a pidfile check (~ms); the daemon itself runs detached.
( bash "$SCRIPT_DIR/bin/attendant.sh" ensure >/dev/null 2>&1 & ) 2>/dev/null

# ============================================================
# 7c2. Connect overlay refresh (fire-and-forget)
# ============================================================
# Connected instances pick up newly released Connect skills without
# re-running the launcher. Local mode exits instantly inside the script.
( bash "$SCRIPT_DIR/bin/connect-refresh.sh" >/dev/null 2>&1 & ) 2>/dev/null

# ============================================================
# 7d. Autosave sweep — rescue non-coding leftovers (fire-and-forget)
# ============================================================
# Terminal-close cover: sessions that died before SessionEnd leave dirty
# checkouts/worktrees behind. The sweep saves + auto-merges any whose
# pending changes are entirely non-coding (gate + idle guard inside).
( bash "$SCRIPT_DIR/bin/session-autosave.sh" --sweep >/dev/null 2>&1 & ) 2>/dev/null

# ============================================================
# 8. Gather context
# ============================================================
# Read-only greeting queries go through the graph cache the attendant keeps
# warm — zero round-trips when warm, live queries on a cold cache. Mutating
# queries are never cached (guard lives in graph.sh).
# CTX_SEED_TAR points at the attendant's pre-baked context snapshot tar
# (_prebake_context); context.sh validates provenance (author, mode, config,
# freshness) and falls back to a full live gather when anything is off.
# _ATT_KEY comes from git-sync.sh and matches the attendant's own state key.
if [ -n "${_ATT_KEY:-}" ]; then
  export CTX_SEED_TAR="${ATTENDANT_HOME:-$HOME/.egregore/attendant}/${_ATT_KEY}.ctx.tar"
fi
export EGREGORE_GRAPH_CACHE_TTL=600
source "$SCRIPT_DIR/bin/lib/context.sh"
unset EGREGORE_GRAPH_CACHE_TTL CTX_SEED_TAR
egregore_trace_mark "context-gather" 2>/dev/null || true

# ============================================================
# 8b. Generate session dashboard artifact
# ============================================================
source "$SCRIPT_DIR/bin/lib/dashboard-artifact.sh"
egregore_trace_mark "dashboard-artifact" 2>/dev/null || true

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
# Loom stage-1 drift surfacing: fail-soft alias-drift warning for the greeting.
# A full `doctor --brief` pass is ~2s of jq. Its config inputs (routes.json,
# org overrides, ANTHROPIC_* env, harness settings env) change rarely, so the
# brief is cached keyed on a hash of those inputs. The 6h age floor forces a
# real pass often enough that ledger-derived warnings (instrument blind, trace
# gaps, pending proposals) still surface within the day.
LOOM_DOCTOR_BRIEF=""
if command -v jq >/dev/null 2>&1; then
  _LOOM_HASH=$(_md5 "$(cat "$SCRIPT_DIR/loom/routes.json" 2>/dev/null; \
    jq -c '.loom // {}' "$CONFIG" 2>/dev/null; \
    env | grep '^ANTHROPIC_' | sort; \
    jq -c '.env // {}' "$HOME/.claude/settings.json" 2>/dev/null)")
  _LOOM_CACHE="$HOME/.egregore/loom-doctor-brief-$(echo -n "${MAIN_PROJECT_DIR:-$SCRIPT_DIR}" | cksum | cut -d' ' -f1)"
  _LOOM_FRESH="false"
  if [ -f "$_LOOM_CACHE" ] && [ "$(head -1 "$_LOOM_CACHE" 2>/dev/null)" = "$_LOOM_HASH" ]; then
    _LOOM_AGE=$(( $(date +%s) - $(stat -c %Y "$_LOOM_CACHE" 2>/dev/null || stat -f %m "$_LOOM_CACHE" 2>/dev/null || echo 0) ))
    [ "$_LOOM_AGE" -lt 21600 ] && _LOOM_FRESH="true"
  fi
  if [ "$_LOOM_FRESH" = "true" ]; then
    LOOM_DOCTOR_BRIEF=$(tail -n +2 "$_LOOM_CACHE" 2>/dev/null)
  else
    LOOM_DOCTOR_BRIEF=$(bash "$SCRIPT_DIR/bin/loom.sh" doctor --brief 2>/dev/null || true)
    mkdir -p "$HOME/.egregore" 2>/dev/null
    { printf '%s\n' "$_LOOM_HASH"; printf '%s' "$LOOM_DOCTOR_BRIEF"; } > "$_LOOM_CACHE.tmp.$$" 2>/dev/null \
      && mv "$_LOOM_CACHE.tmp.$$" "$_LOOM_CACHE" 2>/dev/null || rm -f "$_LOOM_CACHE.tmp.$$" 2>/dev/null || true
  fi
fi
# Render the greeting into a buffer first (redirection on a brace group keeps
# variable/file side effects in this shell). The buffer lets us (a) cache the
# visible card for external launchers and (b) emit a slim reply when the
# launcher already displayed the card — the model then answers in one short
# message instead of re-typing ~1k tokens of box art.
egregore_trace_mark "loom-doctor" 2>/dev/null || true
_GREETING_BUF="${TMPDIR:-/tmp}/egregore-greeting-$$.txt"
{ source "$SCRIPT_DIR/bin/lib/greeting.sh"; } > "$_GREETING_BUF"
egregore_trace_mark "greeting-render" 2>/dev/null || true

# Cache the visible card (everything before the hidden context sections) for
# bin/greeting-card.sh. Keyed by the main checkout + framework version so a
# greeting format change invalidates old cards instead of replaying them.
# Worktree boots skip the write — their branch/status would clobber the card
# launchers show for the main checkout. Atomic write; fail-soft.
_CARD_KEY=$(echo -n "${MAIN_PROJECT_DIR:-$SCRIPT_DIR}" | cksum | cut -d' ' -f1)
_CARD_FILE="$HOME/.egregore/greeting-card-v${FRAMEWORK_VERSION}-${_CARD_KEY}"
if [ "$IS_WORKTREE" != "true" ]; then
  mkdir -p "$HOME/.egregore" 2>/dev/null
  rm -f "$HOME/.egregore/greeting-card-${_CARD_KEY}" 2>/dev/null  # pre-versioning cache name
  awk '/^<!-- session-context/{exit} {print}' "$_GREETING_BUF" > "$_CARD_FILE.tmp.$$" 2>/dev/null \
    && mv "$_CARD_FILE.tmp.$$" "$_CARD_FILE" 2>/dev/null \
    || rm -f "$_CARD_FILE.tmp.$$" 2>/dev/null || true
fi

# In a Claude Code hook this output is captured by the outer pass at the top
# of this script, which turns it into the card-delivery envelope.
cat "$_GREETING_BUF"
( bash "$SCRIPT_DIR/bin/session-record.sh" --mode sweep >/dev/null 2>&1 & ) 2>/dev/null
rm -f "$_GREETING_BUF" 2>/dev/null || true
egregore_trace_end 2>/dev/null || true
