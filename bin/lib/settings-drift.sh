#!/usr/bin/env bash
# settings-drift.sh — heal launcher/installer settings drift around the
# base-branch fast-forward, and surface unshared org-settings changes.
#
# Two org-config surfaces accumulate legitimate local modifications outside
# any session: .claude/settings.json (the installer's generated public-safe
# adapter can replace the org's richer committed file) and egregore.json
# (launcher settings verbs: posture, workflow, people removals). Local
# modifications to files a fast-forward also changes make git refuse the
# merge — and that refusal used to be silently swallowed, leaving the
# checkout behind with no explanation.
#
# Contract (sourced; caller provides $BASE_BRANCH and runs from the repo
# root):
#   settings_drift_heal      — before the ff-merge. Restores settings.json
#                              only when the local copy is a reduced
#                              generated adapter (its hook events and
#                              permission allows are a subset of the
#                              committed file's). Snapshots egregore.json
#                              and returns it to HEAD so the merge can run.
#   settings_drift_reapply   — after the ff-merge. Re-applies the snapshot's
#                              changed settings-owned keys on top of the
#                              incoming egregore.json.
#   settings_drift_report    — sets UNSHARED_SETTINGS_KEYS to the
#                              settings-owned keys where the working file
#                              differs from HEAD, for the greeting.
#
# Anything dirty beyond these two files is user work and is never touched.

_SETTINGS_OWNED_KEYS='["boundary","base_branch","people_removed","features","repos","admins","people"]'
_SETTINGS_DRIFT_SNAPSHOT=""
_SETTINGS_DRIFT_BASE=""
# Read by bin/lib/greeting.sh after git-sync completes.
export SETTINGS_ADAPTER_RESTORED="false"
export UNSHARED_SETTINGS_KEYS=""

# The generated adapter only ever removes relative to the org file: fewer
# hook events, fewer permission allows. A local settings.json that carries
# anything the committed file lacks is user work and stays untouched.
_settings_is_reduced_adapter() {
  local tmp_head
  tmp_head=$(mktemp) || return 1
  if ! git show "HEAD:.claude/settings.json" > "$tmp_head" 2>/dev/null; then
    rm -f "$tmp_head"
    return 1
  fi
  jq -es '
    .[0] as $local | .[1] as $head |
    ($local != $head) and
    ((($local.hooks // {}) | keys) - (($head.hooks // {}) | keys) | length == 0) and
    ((($local.permissions.allow // []) - ($head.permissions.allow // [])) | length == 0)
  ' .claude/settings.json "$tmp_head" >/dev/null 2>&1
  local verdict=$?
  rm -f "$tmp_head"
  return "$verdict"
}

settings_drift_heal() {
  git rev-parse -q --verify "origin/$BASE_BRANCH" >/dev/null 2>&1 || return 0
  [ "$(git rev-parse HEAD 2>/dev/null)" = "$(git rev-parse "origin/$BASE_BRANCH" 2>/dev/null)" ] && return 0

  if ! git diff --quiet -- .claude/settings.json 2>/dev/null; then
    if _settings_is_reduced_adapter; then
      if git checkout -- .claude/settings.json 2>/dev/null; then
        SETTINGS_ADAPTER_RESTORED="true"
        mkdir -p .egregore 2>/dev/null && printf '%s restored .claude/settings.json: a generated adapter had replaced the org file\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .egregore/settings-drift.log 2>/dev/null || true
      fi
    fi
  fi

  if ! git diff --quiet -- egregore.json 2>/dev/null; then
    _SETTINGS_DRIFT_SNAPSHOT=$(cat egregore.json 2>/dev/null || true)
    _SETTINGS_DRIFT_BASE=$(git show "HEAD:egregore.json" 2>/dev/null || true)
    if [ -n "$_SETTINGS_DRIFT_SNAPSHOT" ] && [ -n "$_SETTINGS_DRIFT_BASE" ] \
      && printf '%s' "$_SETTINGS_DRIFT_SNAPSHOT" | jq -e . >/dev/null 2>&1; then
      git checkout -- egregore.json 2>/dev/null || _SETTINGS_DRIFT_SNAPSHOT=""
    else
      _SETTINGS_DRIFT_SNAPSHOT=""
    fi
  fi
}

settings_drift_reapply() {
  [ -n "$_SETTINGS_DRIFT_SNAPSHOT" ] || return 0
  local tmp_local tmp_base merged
  tmp_local=$(mktemp) && tmp_base=$(mktemp) || return 0
  printf '%s' "$_SETTINGS_DRIFT_SNAPSHOT" > "$tmp_local"
  printf '%s' "$_SETTINGS_DRIFT_BASE" > "$tmp_base"
  merged=$(jq -s --argjson keys "$_SETTINGS_OWNED_KEYS" '
    .[0] as $incoming | .[1] as $local | .[2] as $base |
    reduce $keys[] as $k ($incoming;
      if ($local[$k] // null) != ($base[$k] // null) then
        if ($local | has($k)) then .[$k] = $local[$k] else del(.[$k]) end
      else . end)
  ' egregore.json "$tmp_local" "$tmp_base" 2>/dev/null || true)
  rm -f "$tmp_local" "$tmp_base"
  if [ -n "$merged" ] && printf '%s' "$merged" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$merged" > egregore.json
  fi
  _SETTINGS_DRIFT_SNAPSHOT=""
  _SETTINGS_DRIFT_BASE=""
}

# ── control-plane sync (Connected mode) ─────────────────────────────────
# The control plane is authoritative for org settings in Connected mode: a
# teammate's confirmed CLI write lands in the orgs row immediately, and every
# session start pulls it down here. One trust rule: an incoming posture that
# RELAXES local file access is never auto-applied — it is held and surfaced
# for local confirm; tightening applies immediately. If the server has not
# moved but the local settings-owned keys have (an offline write whose push
# failed), the local state is pushed instead.
_settings_posture_rank() {
  case "$1" in strict) echo 0 ;; open) echo 2 ;; *) echo 1 ;; esac
}

export SETTINGS_POSTURE_HELD=""
export SETTINGS_SYNCED_FROM_ORG=""
# true once the control plane and the local settings-owned keys agree — the
# greeting then never asks the user to share what is already org-wide.
export SETTINGS_CP_SYNCED="false"

settings_drift_pull() {
  local api_url api_key resp revision applied local_subset server_settings
  api_url=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
  [ -n "$api_url" ] || return 0
  api_key=$(grep '^EGREGORE_API_KEY=' .env 2>/dev/null | cut -d'=' -f2-)
  [ -n "$api_key" ] || return 0
  resp=$(curl -s --max-time 8 -H "Authorization: Bearer $api_key" "$api_url/api/org/settings" 2>/dev/null) || return 0
  printf '%s' "$resp" | jq -e '.settings' >/dev/null 2>&1 || return 0
  revision=$(printf '%s' "$resp" | jq -r '.settings_revision // ""')
  server_settings=$(printf '%s' "$resp" | jq -c '.settings')
  applied=$(jq -r '.org_settings_revision // ""' .egregore-state.json 2>/dev/null)
  local_subset=$(jq -c --argjson keys "$_SETTINGS_OWNED_KEYS" \
    'with_entries(select(.key as $k | $keys | index($k)))' egregore.json 2>/dev/null)

  if [ -n "$revision" ] && [ "$revision" != "$applied" ] && [ "$server_settings" != "{}" ]; then
    # Server moved: apply it, holding a posture relaxation for local confirm.
    local incoming_posture local_posture hold="false"
    incoming_posture=$(printf '%s' "$resp" | jq -r '.settings.boundary.posture // empty')
    local_posture=$(jq -r '.boundary.posture // "standard"' egregore.json 2>/dev/null)
    if [ -n "$incoming_posture" ] \
      && [ "$(_settings_posture_rank "$incoming_posture")" -gt "$(_settings_posture_rank "$local_posture")" ]; then
      hold="true"
      SETTINGS_POSTURE_HELD="$incoming_posture"
      export SETTINGS_POSTURE_HELD
    fi
    local merged tmp
    merged=$(printf '%s' "$server_settings" | jq -c \
      --argjson keys "$_SETTINGS_OWNED_KEYS" --argjson hold "$hold" --slurpfile cfg egregore.json '
      . as $s | $cfg[0] as $local |
      reduce $keys[] as $k ($local;
        if ($s | has($k)) then
          if $k == "boundary" and $hold then
            .boundary = (($s.boundary // {}) + {posture: ($local.boundary.posture // "standard")})
          else .[$k] = $s[$k] end
        else del(.[$k]) end)
    ' 2>/dev/null || true)
    if [ -n "$merged" ] && printf '%s' "$merged" | jq -e . >/dev/null 2>&1; then
      tmp=$(mktemp "egregore.json.XXXXXX") || return 0
      printf '%s\n' "$merged" | jq . > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv "$tmp" egregore.json || { rm -f "$tmp"; return 0; }
      SETTINGS_SYNCED_FROM_ORG=$(printf '%s' "$resp" | jq -r '.settings | keys | join(", ")')
      export SETTINGS_SYNCED_FROM_ORG
      # A held posture keeps the revision unapplied so the next start retries.
      if [ "$hold" = "false" ] && [ -f .egregore-state.json ]; then
        tmp=$(mktemp ".egregore-state.json.XXXXXX") || return 0
        jq --arg rev "$revision" '.org_settings_revision = $rev' .egregore-state.json > "$tmp" 2>/dev/null \
          && [ -s "$tmp" ] && mv "$tmp" .egregore-state.json || rm -f "$tmp"
        SETTINGS_CP_SYNCED="true"; export SETTINGS_CP_SYNCED
      fi
    fi
  elif [ -n "$revision" ] && [ "$revision" = "$applied" ] && [ "$local_subset" != "$server_settings" ]; then
    # Server unchanged but local settings moved (offline write, failed push):
    # deliver the local state now. bin/settings.sh owns the push mechanics.
    if bash bin/settings.sh push >/dev/null 2>&1; then
      SETTINGS_CP_SYNCED="true"; export SETTINGS_CP_SYNCED
    fi
  elif [ "$local_subset" = "$server_settings" ]; then
    SETTINGS_CP_SYNCED="true"; export SETTINGS_CP_SYNCED
  fi
}

settings_drift_report() {
  UNSHARED_SETTINGS_KEYS=""
  # Control plane already carries these settings — nothing to ask the user.
  [ "${SETTINGS_CP_SYNCED:-false}" = "true" ] && return 0
  git diff --quiet -- egregore.json 2>/dev/null && return 0
  local tmp_head
  tmp_head=$(mktemp) || return 0
  if ! git show "HEAD:egregore.json" > "$tmp_head" 2>/dev/null; then
    rm -f "$tmp_head"
    return 0
  fi
  UNSHARED_SETTINGS_KEYS=$(jq -rs --argjson keys "$_SETTINGS_OWNED_KEYS" '
    .[0] as $local | .[1] as $head |
    [$keys[] | select(($local[.] // null) != ($head[.] // null))] | join(", ")
  ' egregore.json "$tmp_head" 2>/dev/null || true)
  rm -f "$tmp_head"
  export UNSHARED_SETTINGS_KEYS
}
