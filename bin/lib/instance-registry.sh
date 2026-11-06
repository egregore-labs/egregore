#!/usr/bin/env bash
# instance-registry.sh — session start's maintenance of the instance registry
# (~/.egregore/instances.json). Sourced by bin/session-start.sh (register +
# prune) and bin/codex-session-start.sh (prune). Requires jq.
#
#   egregore_registry_prune <registry>
#       Drop entries that can never be an instance: a checkout inside another
#       registered instance's .egregore/ runtime directory (an evaluation
#       sandbox) is runtime state of that instance.
#   egregore_registry_register <registry> <dir> <slug> <name> [org_id]
#       Register <dir> unless it is already registered or is such runtime
#       state; patch a legacy entry with its org_id.
#
# Every write goes through a temporary file and a rename: the boundary check
# reads an empty or half-written registry as damage and fails closed.

# True when $p sits inside another listed path's .egregore/ directory.
_EGREGORE_REGISTRY_JQ_DEFS='
def runtime_state($all): . as $p | any($all[]; . as $root | $root != $p and ($p | startswith($root + "/.egregore/")));
def registered_paths: [.[] | objects | .path | strings];
def runtime_entry($all): type == "object" and (.path | type) == "string" and (.path | runtime_state($all));
'

_egregore_registry_write() {
  local registry="$1" tmp="$1.tmp.$$"
  shift
  if jq "$@" "$registry" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$registry"
  else
    rm -f "$tmp"
    return 1
  fi
}

egregore_registry_prune() {
  local registry="$1" pruned
  [ -f "$registry" ] || return 0
  pruned=$(jq "$_EGREGORE_REGISTRY_JQ_DEFS"'
    if type == "array" then registered_paths as $all | [.[] | select(runtime_entry($all))] | length else 0 end' \
    "$registry" 2>/dev/null) || return 0
  [ "${pruned:-0}" -gt 0 ] 2>/dev/null || return 0
  _egregore_registry_write "$registry" "$_EGREGORE_REGISTRY_JQ_DEFS"'
    registered_paths as $all | map(select(runtime_entry($all) | not))'
}

egregore_registry_register() {
  local registry="$1" dir="$2" slug="$3" name="$4" org="${5:-}" entry
  [ -n "$dir" ] && [ -n "$slug" ] && [ -n "$name" ] || return 0
  mkdir -p "$(dirname "$registry")" || return 0
  if [ ! -f "$registry" ]; then
    echo "[]" > "$registry.tmp.$$" && mv "$registry.tmp.$$" "$registry"
  fi
  # Runtime state of another registered instance never registers itself.
  if jq -e --arg p "$dir" "$_EGREGORE_REGISTRY_JQ_DEFS"'registered_paths as $all | $p | runtime_state($all)' \
    "$registry" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$(jq --arg p "$dir" '[.[] | objects | select(.path == $p)] | length' "$registry" 2>/dev/null)" = "0" ]; then
    # org_id is the stable identity other sessions use to prove this
    # checkout is same-organization rather than foreign
    entry=$(jq -n --arg s "$slug" --arg n "$name" --arg p "$dir" --arg o "$org" \
      '{slug: $s, name: $n, path: $p} + (if $o == "" then {} else {org_id: $o} end)')
    _egregore_registry_write "$registry" --argjson e "$entry" '. + [$e]'
  elif [ -n "$org" ]; then
    # Backward compatibility: patch this checkout's own legacy entry with its
    # org_id so other sessions can prove identity instead of failing closed
    # against it
    _egregore_registry_write "$registry" --arg p "$dir" --arg o "$org" \
      'map(if type == "object" and .path == $p and ((.org_id // "") == "") then . + {org_id: $o} else . end)'
  fi
}
