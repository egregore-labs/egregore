# shellcheck shell=bash
# notices.sh — the greeting's memory of what it already told you.
#
# Every greeting line used to be recomputed from scratch and printed whether
# or not the reader had seen it before: a loom drift notice for a deliberate
# standing override, a tutorial tip after a hundred sessions, the same five
# handoffs every morning. This library gives each notice a signature and a
# ledger, and renders by class:
#
#   standing  — informational state (runtime version, a pinned link, a loom
#               drift). Printed in full the first time a signature is seen
#               and whenever it changes; on repeat sessions folded into one
#               quiet "◦ unchanged:" line so the reference survives without
#               the repetition.
#   open      — actionable items (handoffs for you, pending questions, scroll
#               turns). Always printed, because they still want an action;
#               when unchanged since a previous session the line says since
#               when, so a stale pile reads as stale.
#   tip       — onboarding hints. Printed at most NOTICE_TIP_MAX times ever.
#
# Ledger: JSON at ${EGREGORE_NOTICE_LEDGER:-$HOME/.egregore/notices-<key>.json}
#   { "<id>": {"sig": "…", "first": "YYYY-MM-DD", "last": "YYYY-MM-DD", "shown": N} }
# `first` is the date the current signature was first shown; a changed
# signature resets it. EGREGORE_NOTICE_LEDGER=off disables the ledger
# (every notice renders in full, nothing is recorded) — test harnesses and
# one-off renders use this.
#
# Requires: jq. Sourced after bin/lib/hash.sh when the default path is used.
# Shell-neutral: no word-split loops, no reserved names (zsh owns `status`).

NOTICE_TIP_MAX="${NOTICE_TIP_MAX:-3}"
_NOTICE_LEDGER=""
_NOTICE_JSON="{}"
_NOTICE_FOLD=""
_NOTICE_TODAY=""
_NOTICE_ENABLED="false"

# _notice_init [instance-key]
# Resolve the ledger path and load it. The key isolates instances that share
# a $HOME (the same key the loom doctor cache uses).
_notice_init() {
  local key="${1:-}"
  _NOTICE_FOLD=""
  _NOTICE_TODAY="$(date +%Y-%m-%d)"
  if [ "${EGREGORE_NOTICE_LEDGER:-}" = "off" ] || ! command -v jq >/dev/null 2>&1; then
    _NOTICE_ENABLED="false"
    _NOTICE_LEDGER=""
    _NOTICE_JSON="{}"
    return 0
  fi
  if [ -n "${EGREGORE_NOTICE_LEDGER:-}" ]; then
    _NOTICE_LEDGER="$EGREGORE_NOTICE_LEDGER"
  else
    [ -n "$key" ] || key="$(echo -n "${MAIN_PROJECT_DIR:-${SCRIPT_DIR:-$PWD}}" | cksum | cut -d' ' -f1)"
    _NOTICE_LEDGER="$HOME/.egregore/notices-${key}.json"
  fi
  _NOTICE_ENABLED="true"
  _NOTICE_JSON="$(cat "$_NOTICE_LEDGER" 2>/dev/null || echo "{}")"
  printf '%s' "$_NOTICE_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || _NOTICE_JSON="{}"
  return 0
}

_notice_field() {
  # _notice_field id field default
  printf '%s' "$_NOTICE_JSON" | jq -r --arg id "$1" --arg f "$2" --arg d "$3" '.[$id][$f] // $d' 2>/dev/null
}

_notice_record() {
  # _notice_record id sig changed(true|false)
  local id="$1" sig="$2" changed="$3"
  _NOTICE_JSON="$(printf '%s' "$_NOTICE_JSON" | jq -c \
    --arg id "$id" --arg sig "$sig" --arg today "$_NOTICE_TODAY" --argjson changed "$changed" '
    .[$id] = (
      if $changed then {sig: $sig, first: $today, last: $today, shown: 1}
      else (.[$id] // {}) | .sig = $sig | .last = $today | .shown = ((.shown // 0) + 1)
        | .first = (.first // $today)
      end)' 2>/dev/null || printf '%s' "$_NOTICE_JSON")"
}

# Render "Sep 3" from an ISO date for the "since" suffix. Falls back to the
# ISO form when the platform date cannot parse it.
_notice_pretty_date() {
  local iso="$1"
  date -j -f "%Y-%m-%d" "$iso" "+%b %-d" 2>/dev/null \
    || date -d "$iso" "+%b %-d" 2>/dev/null \
    || printf '%s' "$iso"
}

# _notice id class label sig line
#   id     stable identifier ("loom-drift", "handoffs-for-you")
#   class  standing | open | tip
#   label  short name used in the folded line ("loom drift", "team board")
#   sig    the content signature; any change re-renders the line in full
#   line   the full line to print (already indented)
_notice() {
  local id="$1" class="$2" label="$3" sig="$4" line="$5"
  local prev_sig changed="false" shown first
  if [ "$_NOTICE_ENABLED" != "true" ]; then
    printf '%s\n' "$line"
    return 0
  fi
  prev_sig="$(_notice_field "$id" sig "")"
  shown="$(_notice_field "$id" shown 0)"
  case "$shown" in ''|*[!0-9]*) shown=0 ;; esac
  [ "$prev_sig" = "$sig" ] || changed="true"
  [ "$shown" -gt 0 ] || changed="true"

  case "$class" in
    standing)
      if [ "$changed" = "true" ]; then
        printf '%s\n' "$line"
      else
        _NOTICE_FOLD="${_NOTICE_FOLD:+$_NOTICE_FOLD · }$label"
      fi
      ;;
    open)
      if [ "$changed" = "true" ]; then
        printf '%s\n' "$line"
      else
        first="$(_notice_field "$id" first "$_NOTICE_TODAY")"
        if [ "$first" = "$_NOTICE_TODAY" ]; then
          printf '%s\n' "$line"
        else
          printf '%s · since %s\n' "$line" "$(_notice_pretty_date "$first")"
        fi
      fi
      ;;
    tip)
      if [ "$changed" = "true" ] || [ "$shown" -lt "$NOTICE_TIP_MAX" ]; then
        printf '%s\n' "$line"
      else
        return 0
      fi
      ;;
    *)
      printf '%s\n' "$line"
      ;;
  esac
  _notice_record "$id" "$sig" "$changed"
  return 0
}

# _notice_pinned_links '<json array>'
# Render org `pinned_links` (strings or {url, label}) as standing notices,
# one per position. Shared by every greeting so the contract stays single.
_notice_pinned_links() {
  local links="${1:-[]}" count i line label
  count=$(printf '%s' "$links" | jq 'length' 2>/dev/null || echo 0)
  i=0
  while [ "$i" -lt "$count" ]; do
    line=$(printf '%s' "$links" | jq -r --argjson i "$i" '.[$i] |
      if type == "string" then "  ◆ \(.)"
      elif (.label // "") != "" then "  ◆ \(.label): \(.url)"
      else "  ◆ \(.url)" end' 2>/dev/null)
    label=$(printf '%s' "$links" | jq -r --argjson i "$i" '.[$i] |
      if type == "string" then . elif (.label // "") != "" then .label else .url end' 2>/dev/null)
    _notice "pinned-link-$i" standing "$label" "$line" "$line"
    i=$((i + 1))
  done
  return 0
}

# _notice_flush — print the folded standing notices (one line) and persist
# the ledger atomically. Call once, after the last _notice of the render.
_notice_flush() {
  if [ -n "$_NOTICE_FOLD" ]; then
    printf '  ◦ unchanged: %s\n' "$_NOTICE_FOLD"
  fi
  _NOTICE_FOLD=""
  [ "$_NOTICE_ENABLED" = "true" ] || return 0
  [ -n "$_NOTICE_LEDGER" ] || return 0
  mkdir -p "$(dirname "$_NOTICE_LEDGER")" 2>/dev/null || return 0
  printf '%s\n' "$_NOTICE_JSON" > "$_NOTICE_LEDGER.tmp.$$" 2>/dev/null \
    && mv "$_NOTICE_LEDGER.tmp.$$" "$_NOTICE_LEDGER" 2>/dev/null \
    || rm -f "$_NOTICE_LEDGER.tmp.$$" 2>/dev/null
  return 0
}
