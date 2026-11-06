#!/usr/bin/env bash
set -euo pipefail

# Resolve the stable Runtime identity before Observe can emit attributed
# context. Connected instances adopt IDs from the authenticated control plane;
# legacy Local instances create opaque local IDs once. Network failure remains
# non-fatal to startup and is retried next session.

RUNTIME_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A launcher-carried bridge runs outside the selected instance. Keep code
# rooted in the packaged Runtime while resolving and persisting identity in
# exactly the instance the launcher selected.
ROOT="${EGREGORE_INSTANCE_ROOT:-$RUNTIME_ROOT}"
ROOT="$(cd "$ROOT" && pwd)"
CONFIG="$ROOT/egregore.json"
STATE="$ROOT/.egregore-state.json"
# shellcheck source=bin/lib/config.sh
source "$RUNTIME_ROOT/bin/lib/config.sh"

resolved() {
  [ -f "$CONFIG" ] && [ -f "$STATE" ] || return 1
  jq -e '
    (.org_id | type == "string" and length > 0 and (startswith("legacy-org:") | not))
  ' "$CONFIG" >/dev/null 2>&1 || return 1
  jq -e '
    [ .account_id, .actor_id, .membership_id ]
    | all(type == "string" and length > 0)
  ' "$STATE" >/dev/null 2>&1
}

# The saved address is resolved: an egregore.json saved before the October
# 2026 move still names the retired origin, which never receives a token.
connected_config() {
  api_url="$(_config_api_url)" || api_url=""
  slug="$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)"
  api_key="$(grep '^EGREGORE_API_KEY=' "$ROOT/.env" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$api_url" ] && [ -n "$slug" ]
}

# The greeting's one note about the organization key (bin/lib/health-footer.sh
# renders it): "renewed" shows once; "needs_sign_in" shows until renewal works.
key_notice_state() {
  jq -r '.hosted_key_notice.state // empty' "$STATE" 2>/dev/null || true
}

key_notice() {
  local file tmp
  [ -f "$STATE" ] || return 0
  # A worktree links the checkout's state file: rename onto its target.
  file="$(realpath "$STATE" 2>/dev/null)" || file="$STATE"
  tmp="$(mktemp "$file.XXXXXX" 2>/dev/null)" || return 0
  if [ "$1" = clear ]; then
    jq 'if .hosted_key_notice.state == "needs_sign_in" then del(.hosted_key_notice) else . end' \
      "$file" >"$tmp" 2>/dev/null
  else
    jq --arg state "$1" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.hosted_key_notice = {state: $state, at: $at}' "$file" >"$tmp" 2>/dev/null
  fi && [ -s "$tmp" ] && mv "$tmp" "$file" || rm -f "$tmp"
}

# One authenticated status read; sets status_code and status_body.
probe_status() {
  local response=""
  status_code=""
  status_body=""
  [ -n "$api_key" ] || return 0
  response="$(curl -s "$api_url/api/org/status" \
    -H "Authorization: Bearer $api_key" --connect-timeout 2 --max-time 4 \
    -w '\n%{http_code}' 2>/dev/null || true)"
  status_code="${response##*$'\n'}"
  status_body="${response%$'\n'*}"
}

status_ok() {
  [ "$status_code" = 200 ] && printf '%s' "$status_body" | jq -e --arg slug "$slug" '
    (.org_id | type == "string" and length > 0) and .slug == $slug
  ' >/dev/null 2>&1
}

rejection_code() {
  [ "$status_code" = 401 ] || return 0
  printf '%s' "$status_body" | jq -r '.code // empty' 2>/dev/null || true
}

# Recover the configured org's key only through the membership-verifying
# endpoint, which renews a key retired in the October 2026 security reset.
# A historic path/namespace collision could also leave this checkout with
# another Egregore's key. Install it atomically, then verify it. No
# credential bytes are printed. $1 is the API's code for the rejected key.
recover_key() {
  local rejected="${1:-}" github_token encoded_slug response code recovered renewed previous_key
  github_token="$(grep '^GITHUB_TOKEN=' "$ROOT/.env" 2>/dev/null | cut -d= -f2- || true)"
  if [ -z "$github_token" ]; then
    [ "$rejected" != key_retired ] || key_notice needs_sign_in
    return 1
  fi
  encoded_slug="$(printf '%s' "$slug" | jq -sRr @uri)"
  response="$(curl -s "$api_url/api/org/$encoded_slug/key" \
    -H "Authorization: Bearer $github_token" --connect-timeout 2 --max-time 12 \
    -w '\n%{http_code}' 2>/dev/null || true)"
  code="${response##*$'\n'}"
  recovered="${response%$'\n'*}"
  if [ "$code" = 401 ]; then
    # The GitHub sign-in was rejected; a fresh one renews the key.
    [ "$rejected" != key_retired ] || key_notice needs_sign_in
    return 1
  fi
  [ "$code" = 200 ] || return 1
  # The key itself must name this org (ek_<slug>_<secret>), not just the reply.
  printf '%s' "$recovered" | jq -e --arg slug "$slug" '
    (.api_key | type == "string" and startswith("ek_" + $slug + "_")
      and length > ($slug | length) + 4)
    and .org_slug == $slug
  ' >/dev/null 2>&1 || return 1
  renewed="$(printf '%s' "$recovered" | jq -r '.renewed == true' 2>/dev/null || echo false)"
  # Prove the candidate works before it replaces the saved key.
  previous_key="$api_key"
  api_key="$(printf '%s' "$recovered" | jq -r '.api_key')"
  probe_status
  if ! status_ok; then
    api_key="$previous_key"
    return 1
  fi
  if ! printf '%s' "$recovered" | \
    EGREGORE_ROOT="$ROOT" \
    PYTHONSAFEPATH=1 PYTHONPATH="$RUNTIME_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m egregore_runtime.identity_cli install-connected-key >/dev/null; then
    api_key="$previous_key"
    return 1
  fi
  api_key="$(grep '^EGREGORE_API_KEY=' "$ROOT/.env" 2>/dev/null | cut -d= -f2- || true)"
  if [ "$rejected" = key_retired ] || [ "$renewed" = true ]; then
    key_notice renewed
  else
    key_notice clear
  fi
}

case "${1:-ensure}" in
  status)
    if resolved; then
      printf '{"status":"resolved"}\n'
      exit 0
    fi
    printf '{"status":"unresolved"}\n'
    exit 1
    ;;
  recover)
    # A hosted request just rejected the organization key ($2 is the API's
    # code). Once a fresh sign-in is known to be needed, only session start
    # retries, so the notice and the retry stay one per session.
    [ "$(key_notice_state)" != needs_sign_in ] || exit 1
    connected_config || exit 1
    recover_key "${2:-}"
    ;;
  ensure)
    if resolved; then
      # Healthy starts stop here, with no network call. After a recorded
      # need for a fresh sign-in, retry so the greeting shows the outcome.
      [ "$(key_notice_state)" = needs_sign_in ] || exit 0
      connected_config || exit 0
      probe_status
      if status_ok; then
        key_notice clear
      else
        recover_key "$(rejection_code)" || true
      fi
      exit 0
    fi
    mode="$(jq -r 'if (.mode // "local") == "connected" or (.api_url // "") != "" then "connected" else "local" end' "$CONFIG" 2>/dev/null || echo local)"
    if [ "$mode" = "local" ]; then
      EGREGORE_ROOT="$ROOT" \
        PYTHONSAFEPATH=1 PYTHONPATH="$RUNTIME_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
        python3 -m egregore_runtime.identity_cli initialize-local >/dev/null
    else
      connected_config || exit 1
      # Identity repair selects already-existing account and membership
      # records, then adopts their opaque IDs locally. A rejected key is
      # recovered for the configured org only, through verified GitHub
      # membership. No control-plane records are made.
      probe_status
      if ! status_ok; then
        recover_key "$(rejection_code)" || exit 1
      fi
      control_plane="$status_body"
      roster="$(curl -sf "$api_url/api/org/$slug/members?include_removed=true" \
        -H "Authorization: Bearer $api_key" --connect-timeout 2 --max-time 4 \
        2>/dev/null || true)"
      printf '%s' "$roster" | jq -e \
        '.members | type == "array"' >/dev/null 2>&1 || exit 1
      jq -cn \
        --argjson organization "$control_plane" \
        --argjson roster "$roster" \
        '{organization:$organization,roster:$roster}' | \
        EGREGORE_ROOT="$ROOT" \
          PYTHONSAFEPATH=1 PYTHONPATH="$RUNTIME_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
          python3 -m egregore_runtime.identity_cli \
          reconcile-records >/dev/null
    fi
    resolved
    ;;
  *)
    echo 'usage: bash bin/runtime-identity.sh {ensure|status|recover [code]}' >&2
    exit 2
    ;;
esac
