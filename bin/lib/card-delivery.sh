# shellcheck shell=bash
# card-delivery.sh — deliver the startup card by contract, not by inference.
#
# Claude Code shows a SessionStart hook's `systemMessage` to the user and gives
# `hookSpecificOutput.additionalContext` to the model only. Splitting the
# rendered greeting that way puts the scripted card on screen the moment the
# session opens, and the model never retypes it: echoing the box art used to
# cost ~15 s of output before the first reply. Codex and Pi already show a
# scripted card (bin/codex-session-start.sh); this gives Claude the same
# contract.
#
# Startup from the saved card: every full startup saves its envelope. The next
# launch on the same branch and identity within three days, the next morning
# included and under any framework version, shows that saved card at once
# (stamped with when it was saved) after a quick pass that does only the
# per-session work (session id, consent resets, onboarding check, boundary
# rules, local fast-forwards), then
# runs the full startup detached to refresh memory, state and the saved card
# for the launch after. The full startup used to sit in front of the first
# reply: p50 26 s over 30 days of launches.
#
# Usage (sourced by bin/session-start.sh):
#   [ "$(egregore_card_delivery_mode)" = harness ] && egregore_card_outer_pass "$root" "$version"

# Above this many characters Claude Code moves hook context into a file the
# model has to read back, an extra round trip on every boot. Stay under it by
# dropping the model's copy of the card first; the hidden context stays whole.
EGREGORE_CARD_CONTEXT_MAX="${EGREGORE_CARD_CONTEXT_MAX:-9500}"

# Print "harness" inside a Claude Code SessionStart hook (Claude sets
# CLAUDE_ENV_FILE for those runs alone), "text" everywhere else. An explicit
# EGREGORE_CARD_DELIVERY=harness|text wins.
egregore_card_delivery_mode() {
  case "${EGREGORE_CARD_DELIVERY:-}" in
    harness|text) printf '%s\n' "$EGREGORE_CARD_DELIVERY"; return 0 ;;
  esac
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && command -v jq >/dev/null 2>&1; then
    printf 'harness\n'
  else
    printf 'text\n'
  fi
}

# Print the hook JSON envelope for a rendered greeting file. The visible card
# is everything before the hidden `<!-- session-context` block; the model gets
# that card without its logo and rules, then the hidden context and the
# closing instruction. Prints nothing and returns 1 when the file has no
# hidden block or jq fails, so the caller can fall back to plain text.
egregore_emit_card_json() {
  local greeting="$1" card hidden model_card context
  [ -f "$greeting" ] || return 1
  grep -q '^<!-- session-context' "$greeting" 2>/dev/null || return 1

  # Leading blank lines would push the logo down the screen.
  card=$(awk '/^<!-- session-context/{exit} {print}' "$greeting" | sed '/./,$!d')
  hidden=$(awk '/^<!-- session-context/{found=1} found' "$greeting")
  # Fixed-string matches: the logo and rule glyphs are multibyte, which BSD
  # awk/sed bracket expressions do not handle.
  model_card=$(printf '%s\n' "$card" | grep -v -F -e '██' -e '╚═' -e '┄┄┄┄' | sed '/./,$!d')

  context=$(printf '<!-- startup-card: already on the user'"'"'s screen; never reprint it\n%s\n-->\n\n%s\n' \
    "$model_card" "$hidden")
  if [ "${#context}" -gt "$EGREGORE_CARD_CONTEXT_MAX" ]; then
    context="$hidden"
  fi

  jq -n --arg card "$card" --arg context "$context" '{
    systemMessage: $card,
    hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}
  }' 2>/dev/null
}

# --- Saved card -------------------------------------------------------------

# Print the saved-card path for a checkout, or nothing when saving does not
# apply: worktrees and transient clones (their branch would clobber the main
# checkout's card), or EGREGORE_STARTUP_CACHE=off. `force` also saves for a
# worktree; it exists for end-to-end tests.
egregore_card_cache_path() {
  local root="$1" version="$2" key
  case "${EGREGORE_STARTUP_CACHE:-on}" in
    off) return 0 ;;
    force) ;;
    *)
      [ -f "$root/.git" ] && return 0
      [ "${EGREGORE_TRANSIENT_CHECKOUT:-0}" = "1" ] && return 0
      ;;
  esac
  key=$(printf '%s' "$root" | cksum | cut -d' ' -f1)
  printf '%s/startup-card-v%s-%s.json\n' "${EGREGORE_CARD_CACHE_DIR:-$HOME/.egregore}" "$version" "$key"
}

# Print the saved card to start from: this version's, else the newest card
# another framework version saved for the same checkout. A version bump moves
# the path, and the refresh that renders the new version's card can run from
# the old version's startup, so neither may cost a full startup.
egregore_card_cache_find() {
  local cache="$1" key
  [ -n "$cache" ] || return 0
  if [ -f "$cache" ]; then
    printf '%s\n' "$cache"
    return 0
  fi
  key="${cache##*-}"
  find "$(dirname "$cache")" -maxdepth 1 -name "startup-card-v*-$key" -exec ls -t {} + 2>/dev/null | head -1
}

# The identity a saved card belongs to: branch and GitHub login.
_egregore_card_branch() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || true; }
_egregore_card_author() { jq -r '.github_username // empty' "$1/.egregore-state.json" 2>/dev/null || true; }
# The configured base branch (bin/lib/config.sh _get_base_branch, top level).
_egregore_card_base() {
  jq -r 'if has("base_branch") then .base_branch else "develop" end' "$1/egregore.json" 2>/dev/null || true
}

# Save an envelope with the identity it was rendered for, and the notice
# stage of the render that produced it in the same record (null for a
# foreground render, which recorded its notices directly), so the card and
# its notices are replaced together. Atomic; fail-soft.
egregore_card_cache_write() {
  local cache="$1" envelope="$2" root="$3" stage="${4:-}" notices='null'
  if [ -n "$stage" ] && jq -e 'type == "object"' "$stage" >/dev/null 2>&1; then
    notices=$(jq -c . "$stage" 2>/dev/null) || notices='null'
  fi
  [ -z "$stage" ] || rm -f "$stage"
  [ -n "$cache" ] || return 0
  mkdir -p "$(dirname "$cache")" 2>/dev/null || return 0
  printf '%s' "$envelope" | jq -c \
    --argjson saved_at "$(date +%s)" \
    --arg day "$(date +%Y-%m-%d)" \
    --arg branch "$(_egregore_card_branch "$root")" \
    --arg author "$(_egregore_card_author "$root")" \
    --argjson notices "$notices" \
    '{saved_at: $saved_at, day: $day, branch: $branch, author: $author, envelope: ., notices: $notices}' \
    > "$cache.tmp.$$" 2>/dev/null \
    && mv "$cache.tmp.$$" "$cache" 2>/dev/null \
    || rm -f "$cache.tmp.$$" 2>/dev/null
  return 0
}

# The saved card (a snapshot of it) is on screen now: record the notices it
# shows. The record keeps them, so a failed write is retried at the next
# showing of the same card.
_egregore_card_promote_notices() {
  local snap="$1" root="$2" stage
  jq -e '.notices | type == "object"' "$snap" >/dev/null 2>&1 || return 0
  stage=$(mktemp "${TMPDIR:-/tmp}/egregore-card-notices.XXXXXX" 2>/dev/null) || return 0
  if jq -c '.notices' "$snap" > "$stage" 2>/dev/null && . "$root/bin/lib/notices.sh" 2>/dev/null; then
    _notice_promote "$stage" >/dev/null 2>&1
  fi
  rm -f "$stage"
  return 0
}

# Succeed when a full startup may apply a framework update from upstream
# (bin/lib/git-sync.sh _apply_framework_update, same tests): a downstream
# instance with auto_update on whose framework the Runtime does not own. A
# refresh under a live session never applies one, so such an instance keeps
# the full startup on its first launch each day.
_egregore_card_daily_update() {
  local root="$1"
  [ "$(jq -r '.upstream_url // empty' "$root/egregore.json" 2>/dev/null)" != "none" ] || return 1
  case "$(jq -r '.auto_update | tojson' "$root/egregore.json" 2>/dev/null)" in
    null|true) ;;
    *) return 1 ;;
  esac
  ! (
    # shellcheck disable=SC2034  # runtime_owns_framework reads SCRIPT_DIR
    SCRIPT_DIR="$root"
    . "$root/bin/lib/runtime-owned.sh" >/dev/null 2>&1 && runtime_owns_framework
  )
}

# Print the saved card's age in seconds when it may stand in for a full
# startup: younger than EGREGORE_CARD_CACHE_TTL (default 3 days, so the first
# launch of a day or after a weekend is quick too), rendered for the current
# branch and identity, and that branch is the base branch: any other branch
# needs the full startup's autosave, push and switch, which never run under a
# live session. Where the full startup applies framework updates
# (_egregore_card_daily_update) the card must also be from today and under
# 12 h old. Returns 1 otherwise.
egregore_card_cache_fresh() {
  local cache="$1" root="$2" now age day="" ttl=259200
  [ -n "$cache" ] && [ -f "$cache" ] || return 1
  [ "$(_egregore_card_branch "$root")" = "$(_egregore_card_base "$root")" ] || return 1
  if _egregore_card_daily_update "$root"; then
    day=$(date +%Y-%m-%d)
    ttl=43200
  fi
  now=$(date +%s)
  age=$(jq -r \
    --arg day "$day" \
    --arg branch "$(_egregore_card_branch "$root")" \
    --arg author "$(_egregore_card_author "$root")" \
    --argjson now "$now" \
    'select(($day == "" or .day == $day) and .branch == $branch and .author == $author
            and (.envelope.systemMessage | type) == "string")
     | $now - .saved_at' "$cache" 2>/dev/null) || return 1
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age" -lt "${EGREGORE_CARD_CACHE_TTL:-$ttl}" ] || return 1
  printf '%s\n' "$age"
}

# Print the saved envelope for this launch: anything the quick pass printed
# goes on top of the card, an age line goes above the closing question, and
# the model is told how old its startup context is. A card from an earlier
# day names that day and time, so its own "today" and "yesterday" read as of
# then.
egregore_card_cache_show() {
  local cache="$1" preamble="$2" age="$3" when day clock dated=""
  if [ "$age" -lt 120 ]; then when="just now"
  elif [ "$age" -lt 7200 ]; then when="$((age / 60)) min ago"
  else when="$((age / 3600)) h ago"; fi
  day=$(jq -r '.day // empty' "$cache" 2>/dev/null)
  if [ -n "$day" ] && [ "$day" != "$(date +%Y-%m-%d)" ] \
     && clock=$(jq -er '.saved_at | strflocaltime("%a %H:%M")' "$cache" 2>/dev/null); then
    if [ "$day" = "$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d 2>/dev/null)" ]; then
      when="yesterday ${clock#* }"
    else
      when="$clock"
    fi
    dated="; its dates (today, yesterday, ago) are as of then"
  fi
  jq -c --arg pre "$preamble" --arg when "$when" --arg dated "$dated" '.envelope
    | .systemMessage |= (
        split("\n") as $l
        | ([range(0; $l | length)] | map(select($l[.] | test("\\S"))) | last // ($l | length)) as $i
        | ($l[:$i] + ["  ◦ card from \($when) · updating in the background", ""] + $l[$i:])
        | join("\n")
        | if $pre == "" then . else $pre + "\n\n" + . end)
    | .hookSpecificOutput.additionalContext |= (
        "<!-- startup-context-age: saved \($when)\($dated); a background startup is refreshing memory and state now -->\n\n" + .)' \
    "$cache" 2>/dev/null
}

# Run the full startup detached for a session the quick pass identified, and
# save its envelope for the next launch. Nothing inherits the hook's pipe.
egregore_card_refresh_detached() {
  local root="$1" cache="$2" sid="$3"
  ( (
    # Its notices wait in a stage, saved with its card, until that card is
    # shown (bin/lib/notices.sh). Without a capture file the refresh still
    # runs; it just saves no card.
    _refresh_stage="$cache.notices.tmp.$$"
    _refresh_out=$(mktemp "${TMPDIR:-/tmp}/egregore-card-refresh.XXXXXX" 2>/dev/null) || _refresh_out=""
    _EGREGORE_CARD_PASS=refresh _EGREGORE_REUSE_SESSION_ID="$sid" EGREGORE_NOTICE_STAGE="$_refresh_stage" \
      bash "$root/bin/session-start.sh" > "${_refresh_out:-/dev/null}" 2>/dev/null < /dev/null
    if [ -n "$_refresh_out" ] && _refresh_envelope=$(egregore_emit_card_json "$_refresh_out"); then
      egregore_card_cache_write "$cache" "$_refresh_envelope" "$root" "$_refresh_stage"
    fi
    rm -f "$_refresh_stage" ${_refresh_out:+"$_refresh_out"}
  ) > /dev/null 2>&1 < /dev/null & ) 2>/dev/null
}

# Print a finished startup's envelope and save it, then exit with the
# startup's status. When no envelope can be built the output goes out as plain
# text, so its closing instruction becomes the text-mode one: nothing is on
# the user's screen for the model to leave alone.
_egregore_card_finish() {
  local out="$1" cache="$2" root="$3" rc="$4" envelope
  if envelope=$(egregore_emit_card_json "$out"); then
    printf '%s\n' "$envelope"
    egregore_card_cache_write "$cache" "$envelope" "$root"
  else
    awk '
      /^egregore-quick-ok / { next }
      /^STARTUP CARD: .*\/onboarding/ {
        print "IMPORTANT: Display the above greeting exactly as-is (ASCII art + ornamented status). Then ask the user if they'"'"'d like a quick onboarding tour (run /onboarding), or if they want to jump straight in."
        next
      }
      /^STARTUP CARD: / {
        print "IMPORTANT: Display the above greeting to the user exactly as-is (preserve the ASCII art formatting and ornamented status) on their first message. Then ask: What are you working on?"
        next
      }
      { print }' "$out"
  fi
  rm -f "$out"
  exit "$rc"
}

# The hook's outer pass. Exits the calling script with the startup's status
# once the envelope (or the plain fallback) is printed; returns 1 only when it
# could not set up a capture, so the caller continues as a plain run.
egregore_card_outer_pass() {
  local root="$1" version="$2" out cache saved="" snap="" age rc sid envelope
  out=$(mktemp "${TMPDIR:-/tmp}/egregore-card.XXXXXX" 2>/dev/null) || return 1
  cache=$(egregore_card_cache_path "$root" "$version")

  # Read the saved card once: a refresh can replace it at any moment, and the
  # notices recorded must be the ones on the card shown. The refresh saves
  # under this version's path whichever version's card was shown.
  [ "${EGREGORE_STARTUP_FAST:-on}" = "off" ] || saved=$(egregore_card_cache_find "$cache")
  if [ -n "$saved" ]; then
    snap=$(mktemp "${TMPDIR:-/tmp}/egregore-card-snap.XXXXXX" 2>/dev/null) || snap=""
    if [ -n "$snap" ] && ! cp "$saved" "$snap" 2>/dev/null; then rm -f "$snap"; snap=""; fi
  fi

  if [ -n "$snap" ] && age=$(egregore_card_cache_fresh "$snap" "$root"); then
    # The quick pass inherits the hook's stdin so it maps this session's id.
    _EGREGORE_CARD_PASS=quick bash "$root/bin/session-start.sh" > "$out"
    rc=$?
    sid=$(sed -n 's/^egregore-quick-ok //p' "$out" | tail -1)
    if [ "$rc" -ne 0 ] || [ -z "$sid" ]; then
      # The quick pass stopped early (onboarding_needed, an error): show what
      # it said; nothing else runs for this session.
      rm -f "$snap"
      _egregore_card_finish "$out" "" "$root" "$rc"
    fi
    if envelope=$(egregore_card_cache_show "$snap" "$(grep -v '^egregore-quick-ok ' "$out")" "$age") \
       && [ -n "$envelope" ]; then
      printf '%s\n' "$envelope"
      # Before the refresh renders the next card against the ledger.
      _egregore_card_promote_notices "$snap" "$root"
      egregore_card_refresh_detached "$root" "$cache" "$sid"
      rm -f "$out" "$snap"
      exit 0
    fi
    # The saved card could not be read after all: finish this session's
    # startup in the foreground under the id the quick pass minted.
    rm -f "$snap"
    _EGREGORE_CARD_PASS=refresh _EGREGORE_REUSE_SESSION_ID="$sid" \
      bash "$root/bin/session-start.sh" > "$out" < /dev/null
    _egregore_card_finish "$out" "$cache" "$root" "$?"
  fi
  [ -z "$snap" ] || rm -f "$snap"

  _EGREGORE_CARD_PASS=inner bash "$root/bin/session-start.sh" > "$out"
  _egregore_card_finish "$out" "$cache" "$root" "$?"
}
