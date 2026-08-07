#!/usr/bin/env bash
# The attendant — Egregore's ambient listener. A per-instance daemon that
# watches for work Claude Code sessions leave behind when they die without
# ceremony (terminal closed, laptop shut) and captures it:
#
#   ripcord    dead session + no handoff → deterministic auto-handoff to
#              memory/handoffs/ (kind: ripcord), assembled from the session
#              transcript + git state. No model, no API calls.
#   auto-push  dirty/unpushed dev|feature|bugfix branches in this repo's
#              worktrees, once no session is active → commit + push the
#              branch. Never merges, never touches develop/main.
#
# In-harness hooks (SessionEnd, PreCompact) die with the process; the
# attendant lives outside it. The signal is Claude Code's own transcript
# files (~/.claude/projects/<key>/*.jsonl), written continuously regardless
# of how a session ends: transcript gone stale + work on disk = pull the cord.
#
# Usage:
#   bash bin/attendant.sh ensure   # spawn daemon if not running (fire-and-forget from session-start)
#   bash bin/attendant.sh run      # daemon loop (foreground)
#   bash bin/attendant.sh sweep    # single pass (tests, cron)
#   bash bin/attendant.sh status   # is it alive + last log lines
#   bash bin/attendant.sh stop     # kill the daemon
#
# Env overrides (mainly for tests):
#   ATTENDANT_STALE_MIN   minutes of transcript silence = dead session (default 12)
#   ATTENDANT_DRY_RUN=1   log actions, mutate nothing
#   ATTENDANT_HOME        state dir (default ~/.egregore/attendant)
#   CLAUDE_PROJECTS_DIR   transcript root (default ~/.claude/projects)
#   EGREGORE_MEMORY_DIR   memory repo (default <repo>/memory)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_DIR="$SCRIPT_DIR"
if [ -f "$SCRIPT_DIR/.git" ]; then
  WT_GITDIR=$(sed 's/^gitdir: //' "$SCRIPT_DIR/.git" 2>/dev/null || true)
  [ -n "$WT_GITDIR" ] && MAIN_DIR=$(cd "$WT_GITDIR/../../.." 2>/dev/null && pwd || echo "$SCRIPT_DIR")
fi

CONFIG="$MAIN_DIR/egregore.json"
MEMORY_DIR="${EGREGORE_MEMORY_DIR:-$MAIN_DIR/memory}"
STALE_MIN="${ATTENDANT_STALE_MIN:-12}"
MAX_AGE_MIN=1440                 # ignore transcripts older than 24h
RIPCORD_MIN_BYTES=20000          # skip trivial sessions
DRY_RUN="${ATTENDANT_DRY_RUN:-0}"
CLAUDE_PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

SLUG=$(jq -r '.slug // "egregore"' "$CONFIG" 2>/dev/null || echo "egregore")
KEY="${SLUG}-$(echo -n "$MAIN_DIR" | cksum | cut -d' ' -f1)"
STATE_DIR="${ATTENDANT_HOME:-$HOME/.egregore/attendant}"
PIDFILE="$STATE_DIR/$KEY.pid"
VERSIONFILE="$STATE_DIR/$KEY.version"
LOGFILE="$STATE_DIR/$KEY.log"
JOURNAL="$STATE_DIR/$KEY.journal"
mkdir -p "$STATE_DIR"

# Munged project key, same rule Claude Code uses for ~/.claude/projects dirs.
PROJ_KEY=$(echo -n "$MAIN_DIR" | sed 's|[^A-Za-z0-9]|-|g')

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
  # keep the log bounded
  if [ "$(wc -c < "$LOGFILE" 2>/dev/null | tr -d ' ')" -gt 1000000 ]; then
    tail -500 "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
  fi
}

_script_version() {
  cksum "$MAIN_DIR/bin/attendant.sh" 2>/dev/null | awk '{print $1 ":" $2}'
}

_enabled() {
  [ "$(jq -r 'if .features.attendant == false then "false" else "true" end' "$CONFIG" 2>/dev/null)" != "false" ]
}

_weaver_enabled() {
  [ "$(jq -r 'if .features.weaver == false then "false" else "true" end' "$CONFIG" 2>/dev/null)" != "false" ]
}

_trigger_auto_thread() {
  local reason="$1"
  local runner="$MAIN_DIR/threads/bin/auto-thread.sh"
  local dry_arg=""
  _weaver_enabled || return 0
  [ -f "$runner" ] || return 0
  [ "$DRY_RUN" = "1" ] && dry_arg="--dry-run"

  # Projection is downstream of capture. Run it detached so a slow or broken
  # renderer can never delay ripcord persistence or branch auto-save. The
  # runner's atomic lock coalesces ripcord + end-of-sweep triggers.
  (
    if ! bash "$runner" \
      --repo-dir "$MAIN_DIR" \
      --memory-dir "$MEMORY_DIR" \
      ${dry_arg:+"$dry_arg"}; then
      log "auto-thread failed ($reason)"
    fi
  ) >> "$LOGFILE" 2>&1 &
}

# Personal off switch for ambient capture. ripcord_enabled=false disables BOTH
# ripcord notes and auto-push of dirty worktrees — a user who opts out of
# ambient capture must not find silent commits either. The attendant's other
# duties (graph cache, context seed, handoff lifecycle) are unaffected.
# NOTE: jq's `//` treats false as empty (the auto_update:false gotcha), so the
# test compares the raw value, never `.key // true`.
_capture_enabled() {
  [ "$(jq -r '.ripcord_enabled' "$MAIN_DIR/.egregore-state.json" 2>/dev/null)" != "false" ]
}

_author() {
  local a
  a=$(jq -r '.github_username // empty' "$MAIN_DIR/.egregore-state.json" 2>/dev/null)
  [ -z "$a" ] && a=$(git -C "$MAIN_DIR" config user.name 2>/dev/null | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
  echo "${a:-unknown}"
}

# --- Session liveness ------------------------------------------------------

_transcript_dirs() {
  find "$CLAUDE_PROJECTS" -maxdepth 1 -type d -name "${PROJ_KEY}*" 2>/dev/null
}

_active_session() {
  local d
  for d in $(_transcript_dirs); do
    if [ -n "$(find "$d" -maxdepth 1 -name '*.jsonl' -mmin "-$STALE_MIN" 2>/dev/null | head -1)" ]; then
      return 0
    fi
  done
  return 1
}

_stale_transcripts() {
  local d
  for d in $(_transcript_dirs); do
    find "$d" -maxdepth 1 -name '*.jsonl' -mmin "+$STALE_MIN" -mmin "-$MAX_AGE_MIN" -size "+${RIPCORD_MIN_BYTES}c" 2>/dev/null
  done
}

# --- Ripcord ---------------------------------------------------------------

_last_prompts() {
  # Last few human prompts from a transcript, cleaned of harness noise.
  jq -r 'select(.type=="user") | .message.content
         | if type=="string" then .
           else ([.[]? | select(.type?=="text") | .text] | join(" ")) end' "$1" 2>/dev/null \
    | grep -v -e '^\s*$' -e 'system-reminder' -e '<command-' -e 'tool_use_error' -e '^Caveat:' -e '<task-notification' \
              -e '<local-command-caveat' -e '</local-command-caveat>' -e '<bash-input>' -e '<bash-stdout>' -e '<bash-stderr>' \
    | tail -5 | cut -c1-300
}

_slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/<[^>]*>/ /g; s/[`*_#|:;,.!?()[\]{}"'"'"']/ /g; s/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-72 \
    | sed 's/-$//'
}

_prompt_topic_slug() {
  local prompts="$1"
  local line clean lower slug score best_score=0 best_slug=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lower=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      start|*request\ interrupted*|*system-reminder*|*local-command-caveat*|*bash-input*|*bash-stdout*|*bash-stderr*|*tool_use_error*)
        continue
        ;;
    esac

    clean=$(printf '%s' "$line" | sed 's/^>[[:space:]]*//; s/<[^>]*>/ /g; s/[|`*_#]/ /g')
    slug=$(_slugify "$clean")
    [ -z "$slug" ] && continue
    [ "${#slug}" -lt 8 ] && continue

    score=${#slug}
    case "$slug" in
      *handoff*|*emissary*|*harvest*|*ssh*|*pr*|*review*|*egregore*|*invite*|*deploy*|*release*)
        score=$((score + 20))
        ;;
    esac

    if [ "$score" -gt "$best_score" ]; then
      best_score="$score"
      best_slug="$slug"
    fi
  done <<EOF
$prompts
EOF

  printf '%s\n' "$best_slug"
}

_branch_topic_slug() {
  local gitsum="$1"
  local author="$2"
  local branch rest score best_score=0 best_slug=""

  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    case "$branch" in
      develop|main|master) continue ;;
      dev/"$author"/*) rest="${branch#dev/$author/}"; score=90 ;;
      feature/*|bugfix/*|hotfix/*) rest="${branch#*/}"; score=80 ;;
      dev/*/*) rest="${branch#dev/}"; rest="${rest#*/}"; score=60 ;;
      */*) rest="${branch#*/}"; score=50 ;;
      *) rest="$branch"; score=40 ;;
    esac

    rest=$(_slugify "$rest")
    [ -z "$rest" ] && continue
    if [ "$score" -gt "$best_score" ]; then
      best_score="$score"
      best_slug="$rest"
    fi
  done <<EOF
$(printf '%s\n' "$gitsum" | awk -F'`' '/^- `/{print $2}')
EOF

  printf '%s\n' "$best_slug"
}

_ripcord_topic_slug() {
  local prompts="$1"
  local gitsum="$2"
  local author="$3"
  local slug

  slug=$(_prompt_topic_slug "$prompts")
  [ -z "$slug" ] && slug=$(_branch_topic_slug "$gitsum" "$author")
  [ -z "$slug" ] && slug="session"
  printf '%s\n' "$slug"
}

_topic_from_slug() {
  printf '%s\n' "$1" | tr '-' ' '
}

_git_summary() {
  # Branch + dirty/unpushed state for the main checkout and every worktree.
  local wt branch dirty ahead
  git -C "$MAIN_DIR" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | while read -r wt; do
    branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    [ -z "$branch" ] && continue
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ahead=$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
    if [ "$dirty" != "0" ] || { [ "$ahead" != "0" ] && [ "$ahead" != "?" ]; }; then
      echo "- \`$branch\` — $dirty uncommitted, $ahead unpushed ($(basename "$wt"))"
      git -C "$wt" status --porcelain 2>/dev/null | head -8 | sed 's/^/    /'
    fi
  done
}

_ripcord() {
  local transcript="$1" base author date_ym date_d slug topic file prompts gitsum
  base=$(basename "$transcript" .jsonl)

  _capture_enabled || return 0

  grep -q "$base" "$JOURNAL" 2>/dev/null && return 0
  # Session already ended with ceremony? Then the attendant has no business
  # here. Scan only the tail — a session that merely *read* the /handoff or
  # /save skill text mid-way would otherwise false-positive.
  if tail -c 300000 "$transcript" 2>/dev/null | grep -q -e 'handoff-run.sh' -e 'wraps/'; then
    echo "ripcord-skip $base (explicit handoff/wrap)" >> "$JOURNAL"
    return 0
  fi

  author=$(_author)
  prompts=$(_last_prompts "$transcript")
  gitsum=$(_git_summary)

  # Nothing on disk and nothing said — not worth a handoff.
  if [ -z "$gitsum" ] && [ -z "$prompts" ]; then
    echo "ripcord-skip $base (no work found)" >> "$JOURNAL"
    return 0
  fi

  slug=$(_ripcord_topic_slug "$prompts" "$gitsum" "$author")
  topic=$(_topic_from_slug "$slug")

  date_ym=$(date '+%Y-%m'); date_d=$(date '+%d')
  file="$MEMORY_DIR/handoffs/$date_ym/${date_d}-${author}-ripcord-${slug}.md"

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY ripcord → $file"
    _trigger_auto_thread "ripcord"
    return 0
  fi

  mkdir -p "$(dirname "$file")"
  {
    echo "---"
    echo "date: $(date '+%Y-%m-%d')"
    echo "author: $author"
    echo "to: $author"
    echo "kind: ripcord"
    echo "status: draft"
    echo "topic: $topic"
    echo "---"
    echo ""
    echo "# Ripcord: $topic"
    echo ""
    echo "Automatic capture — this session ended without an explicit handoff."
    echo "Assembled by the attendant from the flight recorder (transcript + git state)."
    echo ""
    if [ -n "$gitsum" ]; then
      echo "## Where the work lives"
      echo ""
      echo "$gitsum"
      echo ""
    fi
    if [ -n "$prompts" ]; then
      echo "## Last things the user asked for"
      echo ""
      echo "$prompts" | sed 's/^/> /'
      echo ""
    fi
    echo "## Pick it up"
    echo ""
    echo "Check out the branch above and run \`/activity\` for surrounding context."
    echo "Session transcript id: \`$base\` ($(date -r "$transcript" '+%Y-%m-%d %H:%M' 2>/dev/null))"
  } > "$file"

  # Commit + push memory (retry for concurrent pushers; tolerate no remote).
  local rel="${file#"$MEMORY_DIR"/}"
  git -C "$MEMORY_DIR" add "$rel" 2>/dev/null
  git -C "$MEMORY_DIR" commit -q -m "Ripcord: auto-handoff for $author ($slug)" 2>/dev/null
  if git -C "$MEMORY_DIR" remote get-url origin >/dev/null 2>&1; then
    local i
    for i in 1 2 3; do
      git -C "$MEMORY_DIR" pull --rebase origin main --quiet 2>/dev/null && \
        git -C "$MEMORY_DIR" push origin main --quiet 2>/dev/null && break
      sleep 2
    done
  fi
  bash "$MAIN_DIR/bin/index-handoff.sh" "$rel" >/dev/null 2>&1 || true

  echo "ripcord $base $rel" >> "$JOURNAL"
  log "ripcord → memory/$rel"
  _trigger_auto_thread "ripcord"
}

# --- Auto-push -------------------------------------------------------------

_auto_push() {
  _capture_enabled || return 0
  local wt branch dirty ahead upstream
  git -C "$MAIN_DIR" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | while read -r wt; do
    branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    case "$branch" in dev/*|feature/*|bugfix/*) ;; *) continue ;; esac
    # Mid-rebase/merge — never touch.
    local gd; gd=$(git -C "$wt" rev-parse --git-dir 2>/dev/null)
    { [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ] || [ -f "$gd/MERGE_HEAD" ]; } && continue

    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    # Only act on work that has itself gone quiet (nothing modified recently).
    if [ "$dirty" != "0" ]; then
      local fresh
      fresh=$(git -C "$wt" status --porcelain 2>/dev/null | sed 's/^...//' | head -50 | while read -r f; do
        find "$wt/$f" -mmin "-$STALE_MIN" 2>/dev/null | head -1
      done | head -1)
      [ -n "$fresh" ] && continue
      if [ "$DRY_RUN" = "1" ]; then log "DRY auto-commit $branch ($dirty files, $wt)"; else
        git -C "$wt" add -A 2>/dev/null
        git -C "$wt" commit -q -m "chore(attendant): ripcord auto-save

Uncommitted work captured after the session went quiet.

Co-Authored-By: Egregore Attendant <noreply@egregore.xyz>" 2>/dev/null
        log "auto-commit $branch ($dirty files)"
      fi
    fi

    upstream=$(git -C "$wt" rev-parse --abbrev-ref '@{u}' 2>/dev/null || true)
    if [ -z "$upstream" ]; then
      ahead=$(git -C "$wt" rev-list --count origin/develop..HEAD 2>/dev/null || echo 0)
    else
      ahead=$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    fi
    if [ "${ahead:-0}" != "0" ]; then
      if [ "$DRY_RUN" = "1" ]; then log "DRY auto-push $branch ($ahead commits)"; else
        git -C "$wt" push -u origin "$branch" --quiet 2>/dev/null && log "auto-push $branch ($ahead commits)"
      fi
    fi
  done
}

# --- Warm: pre-pay the launch path -------------------------------------------
# Session-start's cost is network: git fetches + the greeting's graph queries.
# The attendant pays them in the background every WARM_MIN minutes so launch
# finds fresh refs (git-sync skips its fetch+wait) and a hot graph cache
# (context.sh reads answers instead of making round-trips). Runs even while
# sessions are active — fetch and read-only replay are safe mid-work.

WARM_MIN="${ATTENDANT_WARM_MIN:-5}"
WARM_MARKER="$STATE_DIR/$KEY.warm-ts"

# Non-secret fingerprint of the effective graph endpoint + credential, matching
# bin/graph.sh's resolution order exactly (process env → .env → committed
# api_url). Scopes the graph cache and the snapshot provenance to the tenant
# answers actually come from, not just the tenant the committed config names.
_effective_scope() {
  local url key
  url="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "$MAIN_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
  key="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "$MAIN_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
  [ -n "$url" ] || url=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)
  echo -n "${url}|${key}" | cksum | cut -d' ' -f1
}

_warm() {
  local now last
  now=$(date +%s)
  last=$(cat "$WARM_MARKER" 2>/dev/null || echo 0)
  # Numeric + not-future guard: a malformed legacy marker must not abort
  # warming, and a future timestamp must not suppress it indefinitely.
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$last" -gt "$now" ] && last=0
  [ $(( now - last )) -lt $(( WARM_MIN * 60 )) ] && return 0
  [ "$DRY_RUN" = "1" ] && { log "DRY warm"; return 0; }

  # --prune keeps remote-tracking refs honest so the launch path can answer
  # "does my branch still exist on origin?" from local refs (worktree stale
  # check in git-sync.sh) instead of a ~2s ls-remote round-trip.
  local _origin_pid _origin_ok="false"
  git -C "$MAIN_DIR" fetch origin --prune --quiet 2>/dev/null &
  _origin_pid=$!
  [ -d "$MEMORY_DIR/.git" ] || [ -f "$MEMORY_DIR/.git" ] && git -C "$MEMORY_DIR" fetch origin --quiet 2>/dev/null &
  local repo
  jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' "$CONFIG" 2>/dev/null | while read -r repo; do
    [ -d "$MAIN_DIR/../$repo/.git" ] && git -C "$MAIN_DIR/../$repo" fetch origin --quiet 2>/dev/null
  done &
  wait "$_origin_pid" 2>/dev/null && _origin_ok="true"
  wait
  # Stamp the marker ONLY when the origin fetch actually succeeded, and stamp
  # it atomically (tmp+mv): the launch path treats a fresh marker as "local
  # refs are authoritative", so a failed fetch must not silence live fetches
  # for ten minutes, and a reader must never catch a half-written timestamp.
  if [ "$_origin_ok" = "true" ]; then
    date +%s > "$WARM_MARKER.tmp" && mv "$WARM_MARKER.tmp" "$WARM_MARKER"
  fi

  # Replay graph cache entries touched in the last 24h (connected mode only —
  # in local mode graph.sh exits instantly and no cache exists).
  local cache_dir f q p
  # Key must match graph.sh's _CACHE_DIR derivation exactly: repo root plus
  # the effective endpoint/credential fingerprint, so entries never cross
  # tenants when the same checkout is repointed at a different org/API.
  cache_dir="$HOME/.egregore/graph-cache/$(echo -n "${MAIN_DIR}|$(_effective_scope)" | cksum | cut -d' ' -f1)"
  if [ -d "$cache_dir" ]; then
    for f in $(find "$cache_dir" -name '*.json' -mmin -1440 2>/dev/null); do
      q=$(jq -r '.query // empty' "$f" 2>/dev/null)
      p=$(jq -c '.params // {}' "$f" 2>/dev/null)
      [ -n "$q" ] && EGREGORE_GRAPH_CACHE_TTL=1 bash "$MAIN_DIR/bin/graph.sh" query "$q" "$p" >/dev/null 2>&1 || true
    done
  fi
  _prebake_context
  log "warm: refs fetched, graph cache replayed, context baked"
}

# --- Pre-bake the session-start context snapshot -----------------------------
# Runs the same context gather session-start would (bin/lib/context.sh) and
# stores the result as a single tar at $STATE_DIR/$KEY.ctx.tar. On boot,
# context.sh reuses the baked graph-bound results (todos, lifecycle, pulse,
# metrics, service health) when the bake is <15min old and its provenance
# matches (author, mode, config), re-running the local collectors live —
# taking the greeting's graph work off the launch path entirely.
#
# One tar + atomic rename, not a directory swap: readers open either the whole
# old bake or the whole new one, never a half-replaced directory. The tmp name
# carries $$ so two attendants racing (possible before the run-loop self-check
# converges them) never write through each other's file.
_prebake_context() {
  [ -f "$MAIN_DIR/bin/lib/context.sh" ] || return 0
  local snap="$STATE_DIR/$KEY.ctx.tar"
  (
    set +u +e
    unset CTX_SEED_TAR CTX_SEED_DIR   # never let a bake seed itself from an old bake
    SCRIPT_DIR="$MAIN_DIR"
    CONFIG="$MAIN_DIR/egregore.json"
    STATE_FILE="$MAIN_DIR/.egregore-state.json"
    ENV_FILE="$MAIN_DIR/.env"
    AUTHOR=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null)
    [ -n "$AUTHOR" ] || exit 0
    # Canonical mode semantics (config.sh _detect_mode): local when the config
    # says so OR api_url is absent — legacy OSS configs carry no mode key, and
    # a bare '.mode == local' test would bake failed connected health for them.
    LOCAL_MODE="false"
    source "$MAIN_DIR/bin/lib/config.sh" 2>/dev/null || true
    if type _detect_mode >/dev/null 2>&1; then
      [ "$(_detect_mode)" = "local" ] && LOCAL_MODE="true"
    elif ! jq -e '(.mode // "") != "local" and ((.api_url // "") | length > 0)' "$CONFIG" >/dev/null 2>&1; then
      LOCAL_MODE="true"
    fi
    # Capture ALL provenance BEFORE gathering, then publish only if it is
    # unchanged AFTER — a user, config, or credential switch mid-gather would
    # otherwise produce mixed-tenant/mixed-user data labeled with whatever the
    # final values happened to be (TOCTOU).
    _PRE_CONFIG=$(cksum "$CONFIG" 2>/dev/null | cut -d' ' -f1)
    _PRE_SCOPE=$(_effective_scope)
    _PRE_SCHEMA=$(cksum "$MAIN_DIR/bin/lib/context.sh" 2>/dev/null | cut -d' ' -f1)
    # PIN the effective credentials for the entire gather: graph.sh re-reads
    # env/.env in every subprocess, so without pinning, an A→B→A .env flip
    # during the gather could fetch B-tenant data that the pre/post scope
    # samples cannot see. With the pin, every graph call in this bake uses
    # the credentials the provenance stamp names. Empty values stay empty
    # (local mode) — graph.sh treats them as unset.
    export EGREGORE_API_URL="${EGREGORE_API_URL:-$(grep '^EGREGORE_API_URL=' "$MAIN_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
    export EGREGORE_API_KEY="${EGREGORE_API_KEY:-$(grep '^EGREGORE_API_KEY=' "$MAIN_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)}"
    export EGREGORE_GRAPH_CACHE_TTL=600
    source "$MAIN_DIR/bin/lib/context.sh"
    [ -n "$CTX_DIR" ] && [ -d "$CTX_DIR" ] || exit 0
    _POST_AUTHOR=$(jq -r '.github_username // empty' "$STATE_FILE" 2>/dev/null)
    _POST_CONFIG=$(cksum "$CONFIG" 2>/dev/null | cut -d' ' -f1)
    _POST_SCOPE=$(_effective_scope)
    _POST_SCHEMA=$(cksum "$MAIN_DIR/bin/lib/context.sh" 2>/dev/null | cut -d' ' -f1)
    if [ "$_POST_AUTHOR" != "$AUTHOR" ] || [ "$_POST_CONFIG" != "$_PRE_CONFIG" ] \
      || [ "$_POST_SCOPE" != "$_PRE_SCOPE" ] || [ "$_POST_SCHEMA" != "$_PRE_SCHEMA" ]; then
      rm -rf "$CTX_DIR"
      exit 0
    fi
    # Provenance the reader validates before trusting the bake.
    date +%s > "$CTX_DIR/.baked-ts"
    printf '%s\n' "$AUTHOR" > "$CTX_DIR/.baked-author"
    printf '%s\n' "$LOCAL_MODE" > "$CTX_DIR/.baked-local-mode"
    printf '%s\n' "$_PRE_CONFIG" > "$CTX_DIR/.baked-config"
    # Effective endpoint/credential + the context.sh revision that produced
    # this bake: a seed from a different tenant or a different collector
    # schema must never be trusted.
    printf '%s\n' "$_PRE_SCOPE" > "$CTX_DIR/.baked-scope"
    printf '%s\n' "$_PRE_SCHEMA" > "$CTX_DIR/.baked-schema"
    if (cd "$CTX_DIR" && tar -cf "$snap.tmp.$$" .) 2>/dev/null; then
      mv -f "$snap.tmp.$$" "$snap" 2>/dev/null || rm -f "$snap.tmp.$$" 2>/dev/null
    else
      rm -f "$snap.tmp.$$" 2>/dev/null
    fi
    rm -rf "$CTX_DIR"
  ) >/dev/null 2>&1 || true
  # Clean up the directory-format snapshot from the previous iteration
  rm -rf "$STATE_DIR/$KEY.ctx" 2>/dev/null || true
}

# --- Handoff lifecycle: recurring close / nudge / expiry --------------------
# Connected-mode only. The job itself filters to lifecycle-v1 handoffs with an
# explicit intent, so legacy unclassified backfill never runs unattended.

LIFECYCLE_MIN="${ATTENDANT_LIFECYCLE_MIN:-360}"
LIFECYCLE_MARKER="$STATE_DIR/$KEY.handoff-lifecycle-ts"

_handoff_lifecycle() {
  local now last mode api_url api_key result
  # Read the raw value, not `// true` — jq's `//` returns its right-hand side
  # for null *and false*, so `{"features":{"handoff_lifecycle":false}}` used to
  # resolve to "true" and the opt-out did nothing. Absent key still means on.
  case "$(jq -r '.features.handoff_lifecycle | tojson' "$CONFIG" 2>/dev/null)" in
    null|true) ;;
    *) return 0 ;;
  esac
  [ -f "$MAIN_DIR/bin/handoff-lifecycle-job.sh" ] || return 0

  mode=$(jq -r '.mode // "connected"' "$CONFIG" 2>/dev/null)
  api_url=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)
  api_key=$(grep '^EGREGORE_API_KEY=' "$MAIN_DIR/.env" 2>/dev/null | cut -d'=' -f2- || true)
  [ "$mode" = "connected" ] && [ -n "$api_url" ] && [ -n "$api_key" ] || return 0

  now=$(date +%s)
  last=$(cat "$LIFECYCLE_MARKER" 2>/dev/null || echo 0)
  [ $(( now - last )) -lt $(( LIFECYCLE_MIN * 60 )) ] && return 0
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY handoff-lifecycle"
    return 0
  fi

  if result=$(bash "$MAIN_DIR/bin/handoff-lifecycle-job.sh" run 2>&1); then
    log "handoff-lifecycle: $(printf '%s' "$result" | jq -c \
      '{transitions,nudges:(.nudges|length)}' 2>/dev/null || echo success)"
  else
    log "handoff-lifecycle failed: $(printf '%s' "$result" | tail -1 | cut -c1-300)"
  fi
  date +%s > "$LIFECYCLE_MARKER"
}

# --- Commands ---------------------------------------------------------------

cmd_sweep() {
  _enabled || return 0
  _warm
  _handoff_lifecycle
  if _active_session; then
    log "sweep: session active — standing by"
    return 0
  fi
  local t
  for t in $(_stale_transcripts); do
    _ripcord "$t"
  done
  _auto_push
  _trigger_auto_thread "sweep"
}

cmd_run() {
  _enabled || exit 0
  echo $$ > "$PIDFILE"
  _script_version > "$VERSIONFILE"
  log "attendant up (pid $$, stale=${STALE_MIN}m, $MAIN_DIR)"
  while true; do
    [ -d "$MAIN_DIR" ] || { log "project gone — exiting"; break; }
    # Duplicate-daemon convergence: cmd_ensure's check-then-spawn is lockless,
    # so two concurrent cold starts can both launch a run loop. Whoever owns
    # the pidfile keeps running; the other notices within one cycle and exits
    # without touching shared state.
    [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] || { log "superseded (pid $$) — exiting"; exit 0; }
    cmd_sweep
    sleep 60
  done
  rm -f "$PIDFILE"
}

cmd_ensure() {
  _enabled || exit 0
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    if [ "$(cat "$VERSIONFILE" 2>/dev/null)" = "$(_script_version)" ]; then
      exit 0
    fi
    log "attendant code changed — restarting"
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  # Atomic spawn gate: the pidfile check above is check-then-spawn, so two
  # concurrent cold starts could both reach here and launch two daemons that
  # overlap for a full cycle (lifecycle jobs, ripcord, auto-push). mkdir is
  # the portable atomic primitive; a crashed spawner's stale lock breaks
  # after 5 minutes. Losing the race means someone else is spawning — done.
  local _spawn_lock="$STATE_DIR/$KEY.spawn-lock"
  if ! mkdir "$_spawn_lock" 2>/dev/null; then
    local _lock_age
    _lock_age=$(( $(date +%s) - $(stat -f %m "$_spawn_lock" 2>/dev/null || stat -c %Y "$_spawn_lock" 2>/dev/null || echo 0) ))
    # Stale reap by atomic rename, never rmdir+mkdir: two reapers doing
    # remove-then-recreate can alternately delete each other's FRESH lock and
    # both spawn. Exactly one mv succeeds; losing the mv or the follow-up
    # mkdir means someone else owns a fresh lock — back off.
    if [ "$_lock_age" -gt 300 ] && mv "$_spawn_lock" "$_spawn_lock.reap.$$" 2>/dev/null; then
      rm -rf "$_spawn_lock.reap.$$" 2>/dev/null
      mkdir "$_spawn_lock" 2>/dev/null || exit 0
    else
      exit 0
    fi
  fi
  # Re-check under the lock — the racing ensure may already have spawned.
  if ! { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }; then
    nohup bash "$MAIN_DIR/bin/attendant.sh" run >> "$LOGFILE" 2>&1 &
    disown 2>/dev/null || true
    # Hold the lock until the child's ownership is durably visible (it writes
    # its pidfile first thing in cmd_run). Releasing earlier reopens the race:
    # another ensure passes the pidfile re-check before the child registers
    # and spawns a second daemon whose first sweep overlaps this one.
    local _i _spawned="false"
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
      if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        _spawned="true"
        break
      fi
      sleep 0.2
    done
    if [ "$_spawned" != "true" ]; then
      # Child still hasn't registered: KEEP the lock rather than reopen the
      # spawn window — a merely-delayed child may yet come up, and the stale
      # reaper above frees the lock in 5 minutes if it never does. Fail
      # closed: no attendant for a few minutes beats two attendants sweeping.
      log "ensure: spawned child slow to register — holding spawn lock (pid $$)"
      exit 0
    fi
  fi
  rmdir "$_spawn_lock" 2>/dev/null || true
}

cmd_status() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    echo "attendant: running (pid $(cat "$PIDFILE"), key $KEY)"
  else
    echo "attendant: not running (key $KEY)"
  fi
  [ -f "$LOGFILE" ] && tail -5 "$LOGFILE"
}

cmd_stop() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
    rm -f "$PIDFILE" "$VERSIONFILE"
    echo "attendant: stopped"
  else
    echo "attendant: not running"
  fi
}

case "${1:-}" in
  ensure) cmd_ensure ;;
  run)    cmd_run ;;
  sweep)  cmd_sweep ;;
  status) cmd_status ;;
  stop)   cmd_stop ;;
  *) echo "usage: bash bin/attendant.sh {ensure|run|sweep|status|stop}" >&2; exit 1 ;;
esac
