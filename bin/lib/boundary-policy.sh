#!/usr/bin/env bash
# boundary-policy.sh — single source of truth for the boundary policy layers.
#
# The org layer lives in egregore.json .boundary { posture, read[], write[], locked }
# (committed). The personal layer lives in .egregore-boundary.local.json
# { posture, read[], write[] } (gitignored) and is ignored entirely when the org
# layer sets locked: true.
#
# Sourced by:
#   bin/session-start.sh          — writes the cached boundary at session start
#   .claude/hooks/boundary-check.sh — re-merges mid-session when a layer changed
#   bin/boundary.sh               — grant/revoke/refresh
#
# Keeping the merge in one place is what makes a mid-session grant take effect:
# previously the hook could only read a cache computed at session start, so the
# remedy it printed ("add the path to read[]") silently did nothing until the
# next session.
#
# Contract: boundary_policy_json <project_dir> prints a compact JSON object
#   {posture, locked, read_roots, write_roots}
# and nothing else. Never exits non-zero for a missing/!malformed layer — an
# unreadable layer degrades to the defaults, it must not wedge a session.

# Print the merged policy for a project directory.
boundary_policy_json() {
  local project_dir="$1"
  local org_file="$project_dir/egregore.json"
  local personal_file="$project_dir/.egregore-boundary.local.json"

  local posture locked
  posture=$(jq -r '.boundary.posture // "standard"' "$org_file" 2>/dev/null)
  locked=$(jq -r '.boundary.locked // false' "$org_file" 2>/dev/null)
  case "$posture" in strict|standard|open) ;; *) posture="standard" ;; esac
  [ "$locked" = "true" ] || locked="false"

  if [ "$locked" != "true" ] && [ -f "$personal_file" ]; then
    local p_posture
    p_posture=$(jq -r '.posture // empty' "$personal_file" 2>/dev/null)
    case "$p_posture" in strict|standard|open) posture="$p_posture" ;; esac
  fi

  # Read roots: inbox defaults (unless strict) + org read[] + personal read[].
  local raw_read=""
  if [ "$posture" != "strict" ]; then
    raw_read="$HOME/Downloads
$HOME/Desktop"
  fi
  raw_read="$raw_read
$(jq -r '.boundary.read[]? // empty' "$org_file" 2>/dev/null)"

  # Write roots: opt-in only. There is no default write root at any posture —
  # a read grant must never silently become a write grant.
  local raw_write=""
  raw_write="$(jq -r '.boundary.write[]? // empty' "$org_file" 2>/dev/null)"

  if [ "$locked" != "true" ] && [ -f "$personal_file" ]; then
    raw_read="$raw_read
$(jq -r '.read[]? // empty' "$personal_file" 2>/dev/null)"
    raw_write="$raw_write
$(jq -r '.write[]? // empty' "$personal_file" 2>/dev/null)"
  fi

  # A write root implies the corresponding read root — granting write access to
  # a directory you cannot read is never what anyone means.
  raw_read="$raw_read
$raw_write"

  local read_json write_json
  read_json=$(_boundary_roots_to_json "$raw_read")
  write_json=$(_boundary_roots_to_json "$raw_write")

  jq -n -c \
    --arg posture "$posture" \
    --argjson locked "$locked" \
    --argjson read_roots "$read_json" \
    --argjson write_roots "$write_json" \
    '{posture: $posture, locked: $locked, read_roots: $read_roots, write_roots: $write_roots}'
}

# Normalize a newline-separated root list into a sorted, deduped JSON array.
# Expands a leading ~ and drops blanks and any entry that is not absolute —
# a relative root would silently mean "anything under the project", which the
# core boundary already covers.
_boundary_roots_to_json() {
  local raw="$1" cleaned
  cleaned=$(printf '%s\n' "$raw" \
    | sed -e "s|^~|$HOME|" \
    | grep -E '^/.+' \
    | sed -e 's|/*$||' \
    | sort -u 2>/dev/null) || cleaned=""
  if [ -z "$cleaned" ]; then
    echo "[]"
    return 0
  fi
  printf '%s\n' "$cleaned" | jq -R . | jq -s -c . 2>/dev/null || echo "[]"
}
