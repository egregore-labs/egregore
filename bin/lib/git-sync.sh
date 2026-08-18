# shellcheck shell=bash
# git-sync.sh — Git synchronization for session-start.sh
#
# Handles all git operations during session startup:
#   - Pull rebase configuration
#   - Parallel fetches (origin, upstream, memory, managed repos)
#   - Worktree orphan cleanup
#   - Git health check
#   - Develop branch setup + sync
#   - Memory sync
#   - Managed repos sync
#
# Inputs:  SCRIPT_DIR, IS_WORKTREE, MAIN_PROJECT_DIR, STATE_FILE, ENV_FILE,
#          HEALTH_GIT, BASE_BRANCH (optional — resolved here if unset),
#          MANAGED_REPOS (not yet set — read from config here)
# Outputs: HEALTH_GIT, DEVELOP_SYNCED, COMMITS_AHEAD, ACTION, SAVED_BRANCH,
#          BRANCH, MEMORY_SYNCED, REPOS_STATUS, MANAGED_REPOS, CURRENT_BRANCH,
#          FRAMEWORK_UPDATED, FRAMEWORK_UPDATED_COUNT, FRAMEWORK_UPDATED_FILES,
#          BASE_BRANCH, BASE_BRANCH_READY

FRAMEWORK_UPDATED="false"
FRAMEWORK_UPDATED_COUNT=0
FRAMEWORK_UPDATED_FILES=""

# The core repo's integration branch: "develop" unless egregore.json sets
# base_branch. session-start.sh resolves this before sourcing; resolve it here
# too so the lib stands alone for other callers.
if [ -z "${BASE_BRANCH:-}" ]; then
  if ! BASE_BRANCH=$(_get_base_branch); then
    HEALTH_GIT="fail"
    return 1 2>/dev/null || exit 1
  fi
fi

# --- Ensure pull.rebase is set (prevents "divergent branches" errors) ---
git config pull.rebase true 2>/dev/null || true

# --- Fetch all remotes in parallel ---
# Set git transfer timeout so hangs don't block startup indefinitely.
export GIT_HTTP_LOW_SPEED_LIMIT=1000  # abort if <1KB/s
export GIT_HTTP_LOW_SPEED_TIME=10     # for 10 seconds

# Attendant fast path: the ambient daemon (bin/attendant.sh) fetches origin,
# memory, and managed repos every few minutes. If its warm marker is fresh,
# refs are already up to date — skip the network fetches and launch on local
# ops only. Upstream fetch (framework update check) is not covered by the
# attendant and stays unconditional below.
_REFS_FRESH="false"
_ATT_SLUG=$(jq -r '.slug // "egregore"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo "egregore")
# Key the marker by the MAIN checkout, not this directory: the attendant keys
# its state by MAIN_DIR, so hashing a worktree path here meant worktree
# sessions never matched the warm marker and always paid the full fetch round.
# Worktrees share refs with the main checkout (common git dir), so the skip is
# equally valid there. session-start.sh provides MAIN_PROJECT_DIR; standalone
# callers fall back to SCRIPT_DIR (identical for non-worktree checkouts).
_ATT_KEY="${_ATT_SLUG}-$(echo -n "${MAIN_PROJECT_DIR:-$SCRIPT_DIR}" | cksum | cut -d' ' -f1)"
_ATT_MARKER="${ATTENDANT_HOME:-$HOME/.egregore/attendant}/${_ATT_KEY}.warm-ts"
if [ -f "$_ATT_MARKER" ]; then
  # Harden the read: an empty or garbled marker (e.g. caught mid-write) must
  # degrade to "not fresh", never abort startup with an arithmetic error.
  _ATT_TS=$(cat "$_ATT_MARKER" 2>/dev/null || echo 0)
  case "$_ATT_TS" in ''|*[!0-9]*) _ATT_TS=0 ;; esac
  _ATT_AGE=$(( $(date +%s) - _ATT_TS ))
  # The attendant warms every ~5min and stamps the marker AFTER its fetches
  # finish, so a healthy marker's age peaks just above 300s. A 360s threshold
  # made the skip a coin flip — half of boots paid the full fetch round for
  # nothing. 600s (2× the warm cycle) means refs are at most ~10min stale at
  # launch, and the attendant converges them minutes later anyway.
  [ "$_ATT_AGE" -ge 0 ] && [ "$_ATT_AGE" -lt 600 ] && _REFS_FRESH="true"
fi

[ "$_REFS_FRESH" != "true" ] && git fetch origin --quiet 2>/dev/null &

# Fetch upstream framework (for update check — non-blocking)
# Default: official egregore-core repo. Set upstream_url in egregore.json to override,
# or set it to "none" to disable (e.g., in the dev repo where this IS the source).
_UPSTREAM_URL=$(jq -r '.upstream_url // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
[ -z "$_UPSTREAM_URL" ] && _UPSTREAM_URL="https://github.com/egregore-labs/egregore.git"
if [ "$_UPSTREAM_URL" != "none" ]; then
  git remote add upstream "$_UPSTREAM_URL" 2>/dev/null || true
  git fetch upstream main --quiet 2>/dev/null &
fi

# Sync memory in parallel (symlink or direct directory — both valid)
MEMORY_SYNCED="false"
if [ -d "$SCRIPT_DIR/memory/.git" ] && [ "$_REFS_FRESH" != "true" ]; then
  git -C "$SCRIPT_DIR/memory" fetch origin --quiet 2>/dev/null &
fi

# Fetch managed repos in parallel
MANAGED_REPOS=$(jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
if [ "$_REFS_FRESH" != "true" ]; then
  for REPO in $MANAGED_REPOS; do
    if [ -d "$SCRIPT_DIR/../$REPO/.git" ]; then
      git -C "$SCRIPT_DIR/../$REPO" fetch origin --quiet 2>/dev/null &
    fi
  done
fi

# Wait for all fetches
wait 2>/dev/null || true

# --- Auto-update framework from upstream (deferred) ---
# Moved AFTER setup_develop() so framework commits land on develop, not on
# working branches. See _apply_framework_update() below.

# _read_auto_update — resolve the auto_update flag. Correct, and FAIL CLOSED.
#
# This flag is the only thing standing between a user's checkout and a blind
# `git checkout upstream/main --` over every framework path, so it has to be
# read exactly right. It was not.
#
# The bug: `jq -r '.auto_update // true'`. jq's `//` returns its right-hand
# side when the left is null *or false* — so a config saying
# {"auto_update": false} evaluated to the string "true", and the guard
# `[ "$_AUTO_UPDATE" = "false" ]` could never fire. The documented opt-out
# has never disabled anything for anyone. Do not reintroduce `// <bool>` for
# a flag whose `false` is meaningful; read the raw value and map it.
#
# Second failure: jq prints nothing and exits non-zero on a missing or
# malformed egregore.json, and an empty string is not "false" either — so an
# unreadable config also read as consent. Absent key means "on" (the intended
# default); everything else that is not a parsed `true` means "leave the
# user's files alone".
_read_auto_update() {
  local _config="$SCRIPT_DIR/egregore.json"
  local _val
  [ -f "$_config" ] || { echo "false"; return; }
  # `| tojson`, not a bare `-r` read: under -r a *string* "true" renders as bare
  # true, indistinguishable from boolean true, so {"auto_update": "true"} would
  # re-authorize the overwrite — a fail-open hole in the middle of a fail-closed
  # resolver. tojson keeps the quotes, so the true arm matches only an absent key
  # or a real boolean.
  _val=$(jq -r '.auto_update | tojson' "$_config" 2>/dev/null) || { echo "false"; return; }
  case "$_val" in
    null|true) echo "true" ;;   # key absent, or explicitly enabled
    *)         echo "false" ;;  # false, "false", "true", garbage, or unparseable
  esac
}

_apply_framework_update() {
  # Applies framework paths from upstream to the CURRENT branch, which must be
  # the configured base branch.
  # Disable with "auto_update": false in egregore.json.
  # Dev repos (upstream_url: "none") skip this entirely.
  #
  # The flag is read HERE, not at source time: callers reach this function
  # after setup_develop() has switched branches, and egregore.json may differ
  # between the branch the session opened on and the configured base. Reading
  # late means the config that is actually checked out is the config that
  # decides.
  local _update_branch
  _update_branch=$(git branch --show-current 2>/dev/null) || return 1
  if [ "$_update_branch" != "$BASE_BRANCH" ]; then
    return 1
  fi
  _AUTO_UPDATE=$(_read_auto_update)
  if [ "$_UPSTREAM_URL" = "none" ] || [ "$_AUTO_UPDATE" != "true" ]; then
    return 0
  fi
  if ! git show-ref --verify --quiet refs/remotes/upstream/main 2>/dev/null; then
    return 0
  fi
  # Re-sync the base branch right before committing onto it: the warm-marker
  # fast path can leave origin/$BASE_BRANCH up to ~10min stale, and an update
  # committed onto a stale base creates divergence that later ff-only syncs
  # cannot resolve. Only this rare path (upstream set + auto_update on) pays
  # the fetch. FAIL CLOSED: if the fetch or fast-forward doesn't succeed
  # (offline, or the base already diverged), skip the update entirely rather
  # than commit upstream files onto a stale base — the next healthy boot
  # applies it.
  git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || return 0
  git merge --ff-only "origin/$BASE_BRANCH" --quiet 2>/dev/null || return 0
  # Apply upstream changes — checkout is idempotent, skip diff check
  # (git diff with variable path lists breaks in zsh — no word-splitting)
  for _p in bin/ .claude/commands/ .claude/skills/ .claude/hooks/ .claude/context/ .claude/agents/ loom/ CLAUDE.md skills/; do
    git checkout upstream/main -- "$_p" 2>/dev/null || true
  done
  # Only commit if there are actual changes. Record WHAT changed before
  # committing — an overwrite of local edits is the one outcome the user has
  # to be able to see afterwards, and the commit is the only other record.
  local _changed
  _changed=$(git status --porcelain bin/ .claude/ loom/ CLAUDE.md skills/ 2>/dev/null)
  if [ -n "$_changed" ]; then
    FRAMEWORK_UPDATED_COUNT=$(printf '%s\n' "$_changed" | grep -c . || echo 0)
    FRAMEWORK_UPDATED_FILES=$(printf '%s\n' "$_changed" | awk '{print $NF}' | head -3 | tr '\n' ' ')
    git add bin/ .claude/ loom/ CLAUDE.md skills/ 2>/dev/null
    EGREGORE_FRAMEWORK_UPDATE=1 git commit -m "chore(sync): update framework from upstream" --quiet 2>/dev/null || true
    FRAMEWORK_UPDATED="true"
  fi
}

# --- Worktree prune (just clean git's internal list, don't delete anything) ---
git worktree prune 2>/dev/null || true

# --- Git health check ---
if git show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH" 2>/dev/null; then
  HEALTH_GIT="ok"
else
  HEALTH_GIT="fail"
fi

# --- Guarded staging -------------------------------------------------------
# git_add_guarded() lives in the shared lib so the /handoff auto-save uses the
# exact same logic. Fallback to plain `git add -A` if the lib can't be sourced,
# so an unattended auto-save never silently no-ops.
# shellcheck source=bin/lib/git-safe.sh
. "$SCRIPT_DIR/bin/lib/git-safe.sh" 2>/dev/null || true
if ! type git_add_guarded >/dev/null 2>&1; then
  git_add_guarded() { git add -A 2>/dev/null || true; }
fi

# --- Setup base branch (wrapped — failures set HEALTH_GIT but don't crash) ---
# Named setup_develop for continuity; it operates on $BASE_BRANCH, which is
# "develop" by default and whatever egregore.json's base_branch says otherwise.
setup_develop() {
  # Detached HEAD (CI merge-ref checkouts, bisects): never create or switch
  # branches here — `git checkout -b $BASE_BRANCH origin/$BASE_BRANCH` would
  # silently replace the checked-out tree with the base branch. This is how
  # CI jobs that invoke session-start machinery ended up testing develop
  # instead of the PR under test. Syncing means updating the base-branch ref,
  # not claiming HEAD; on a detached HEAD there is nothing safe to do.
  [ -n "$(git branch --show-current 2>/dev/null)" ] || return 0

  # Ensure the base branch exists locally
  if ! git show-ref --verify --quiet "refs/heads/$BASE_BRANCH" 2>/dev/null; then
    if git show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH" 2>/dev/null; then
      git checkout -b "$BASE_BRANCH" "origin/$BASE_BRANCH" --quiet 2>/dev/null || return 1
    else
      # Not on the remote either — create it and publish it
      git checkout -b "$BASE_BRANCH" --quiet 2>/dev/null || return 1
      git push -u origin "$BASE_BRANCH" --quiet 2>/dev/null || return 1
    fi
  fi

  # Sync the base branch (without checkout — safe for concurrent sessions)
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null) || return 1

  # Update the local ref from remote without switching branches, using
  # force-update to handle divergence (e.g., from auto-update commits).
  # origin/$BASE_BRANCH is already current: either the parallel `git fetch
  # origin` above ran this boot, or the attendant fetched within the freshness
  # window. A second fetch here cost ~2s on every boot and never changed refs.
  if [[ "$CURRENT_BRANCH" != "$BASE_BRANCH" ]]; then
    # Safe to force-update when not checked out
    git branch -f "$BASE_BRANCH" "origin/$BASE_BRANCH" 2>/dev/null || true
  else
    # On the base branch — try ff merge, fall back to reset only if no unpushed work
    git merge --ff-only "origin/$BASE_BRANCH" --quiet 2>/dev/null || {
      # Only reset if there are no unpushed commits and no dirty tracked work.
      # A reset here runs before autosave and must never discard local changes.
      LOCAL_AHEAD=$(git rev-list "origin/$BASE_BRANCH..$BASE_BRANCH" --count 2>/dev/null || echo "0")
      if [ "$LOCAL_AHEAD" = "0" ] && [ -z "$(git status --porcelain 2>/dev/null)" ]; then
        git reset --hard "origin/$BASE_BRANCH" --quiet 2>/dev/null || true
      fi
    }
  fi
  # Count commits on the base branch ahead of main. Meaningless in
  # single-branch mode, where the base branch IS main.
  COMMITS_AHEAD=0
  if [ "$BASE_BRANCH" != "main" ] && git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
    COMMITS_AHEAD=$(git rev-list "origin/main..$BASE_BRANCH" --count 2>/dev/null || echo "0")
  fi

  # Always start from the base branch
  # Every session begins there. Claude creates a fresh topic branch
  # (dev/{author}/{topic-slug}) when the user says what they're working on.
  # If we're on a working branch with uncommitted work, save it first.
  ACTION="ready"
  SAVED_BRANCH=""

  if [[ "$CURRENT_BRANCH" != "$BASE_BRANCH" ]]; then
    # Check for uncommitted work (staged + unstaged + untracked in tracked dirs)
    if [ -n "$(git status --porcelain 2>/dev/null | head -1)" ]; then
      # Save uncommitted work so nothing is lost (guarded: never auto-commit
      # stray submodule pointers from sibling repos in the checkout)
      git_add_guarded
      git commit -m "chore(autosave): save uncommitted work from $CURRENT_BRANCH" --quiet 2>/dev/null || true
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

    # Switch to the base branch (already updated by the fetch above)
    if ! git checkout "$BASE_BRANCH" --quiet 2>/dev/null; then
      BRANCH=$(git branch --show-current 2>/dev/null || echo "?")
      return 1
    fi
  else
    # Already on it — fetch couldn't update a checked-out branch, so pull
    git merge --ff-only "origin/$BASE_BRANCH" --quiet 2>/dev/null || true
  fi

  # Never report the intended branch as the actual branch. A checkout can fail
  # when the base is held by another worktree or the index blocks the switch.
  # setup_develop must fail in that case so callers cannot apply framework files
  # to the user's working branch.
  BRANCH=$(git branch --show-current 2>/dev/null || echo "?")
  if [ "$BRANCH" != "$BASE_BRANCH" ]; then
    return 1
  fi
  DEVELOP_SYNCED="true"
  return 0
}

# Initialize defaults used by setup_develop
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
DEVELOP_SYNCED="false"
COMMITS_AHEAD=0
ACTION="ready"
SAVED_BRANCH=""
BRANCH="${CURRENT_BRANCH:-$BASE_BRANCH}"
BASE_BRANCH_READY="false"

if [ "$IS_WORKTREE" = "true" ]; then
  # Inside a worktree — skip the base-branch checkout and framework update.
  # Worktrees are isolated working copies; framework updates belong on the base.
  BRANCH=$(git branch --show-current 2>/dev/null || echo "?")
  DEVELOP_SYNCED="true"

  # --- Worktree branch health check ---
  # Detect if the branch was already merged into the base branch (e.g., PR
  # merged but worktree not cleaned up). This prevents working on a stale
  # branch whose commits already landed.
  WORKTREE_STALE="false"
  if [ "$BRANCH" != "?" ] && [ "$BRANCH" != "$BASE_BRANCH" ] && [ "$BRANCH" != "main" ]; then
    # Check if remote branch still exists. When the attendant marker is fresh,
    # local remote-tracking refs are authoritative (the attendant fetches with
    # --prune every warm cycle) — answering locally saves a ~2s ls-remote
    # round-trip on every worktree boot. Cold marker keeps the live query.
    if [ "$_REFS_FRESH" = "true" ]; then
      _BRANCH_ON_REMOTE() { git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" 2>/dev/null; }
    else
      _BRANCH_ON_REMOTE() { git ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q "$BRANCH"; }
    fi
    if ! _BRANCH_ON_REMOTE; then
      # Remote branch gone — check if it was merged into the base branch
      if git branch -r --merged "origin/$BASE_BRANCH" 2>/dev/null | grep -q "origin/$BRANCH" 2>/dev/null || \
         git merge-base --is-ancestor HEAD "origin/$BASE_BRANCH" 2>/dev/null; then
        WORKTREE_STALE="merged"
      else
        WORKTREE_STALE="remote_deleted"
      fi
    fi
  fi

  if [ "$WORKTREE_STALE" = "merged" ]; then
    echo ""
    echo "WARNING: Branch '$BRANCH' was already merged into $BASE_BRANCH."
    echo "This worktree is stale — your work here is already in $BASE_BRANCH."
    echo "Start a new session in the main project to get a fresh branch."
    echo ""
    HEALTH_GIT="fail"
  elif [ "$WORKTREE_STALE" = "remote_deleted" ]; then
    echo ""
    echo "WARNING: Remote branch '$BRANCH' was deleted but NOT merged into $BASE_BRANCH."
    echo "This worktree may contain unique local commits. Check before discarding:"
    echo "  git log origin/$BASE_BRANCH..HEAD --oneline"
    echo ""
  fi

  # Use main project's .env and state if ours are missing
  if [ ! -f "$SCRIPT_DIR/.env" ] && [ -f "$MAIN_PROJECT_DIR/.env" ]; then
    export ENV_FILE="$MAIN_PROJECT_DIR/.env"
  fi
elif setup_develop 2>/dev/null; then
  BASE_BRANCH_READY="true"
else
  HEALTH_GIT="fail"
fi

# Apply a framework update only after setup verified the configured base branch.
if [ "$IS_WORKTREE" != "true" ] && [ "$BASE_BRANCH_READY" = "true" ]; then
  _apply_framework_update 2>/dev/null || true
fi

# --- Sync memory (symlink or direct directory — both valid) ---
if [ -d "$SCRIPT_DIR/memory/.git" ]; then
  MEM_LOCAL=$(git -C "$SCRIPT_DIR/memory" rev-parse HEAD 2>/dev/null || echo "")
  MEM_REMOTE=$(git -C "$SCRIPT_DIR/memory" rev-parse origin/main 2>/dev/null || echo "")
  if [ -n "$MEM_LOCAL" ] && [ -n "$MEM_REMOTE" ] && [ "$MEM_LOCAL" != "$MEM_REMOTE" ]; then
    git -C "$SCRIPT_DIR/memory" pull origin main --quiet 2>/dev/null || true
  fi
  MEMORY_SYNCED="true"
fi

# --- Sync managed repos ---
# Managed repos sync silently — they are a CLI concern and never render in the
# greeting. REPOS_STATUS stays exported (empty) for consumers of this lib.
REPOS_STATUS=""
for REPO in $MANAGED_REPOS; do
  REPO_DIR="$SCRIPT_DIR/../$REPO"
  if [ -d "$REPO_DIR/.git" ]; then
    # Resolve base branch for this repo (from egregore.json or auto-detect)
    if ! REPO_BASE=$(_get_base_branch "$REPO"); then
      HEALTH_GIT="fail"
      continue
    fi
    # Sync base branch with remote (if not checked out)
    R_BRANCH=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo "?")
    if [ "$R_BRANCH" != "$REPO_BASE" ]; then
      git -C "$REPO_DIR" branch -f "$REPO_BASE" "origin/$REPO_BASE" --quiet 2>/dev/null || true
    else
      git -C "$REPO_DIR" merge --ff-only "origin/$REPO_BASE" --quiet 2>/dev/null || true
    fi
  fi
done
