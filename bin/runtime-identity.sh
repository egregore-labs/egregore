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

case "${1:-ensure}" in
  status)
    if resolved; then
      printf '{"status":"resolved"}\n'
      exit 0
    fi
    printf '{"status":"unresolved"}\n'
    exit 1
    ;;
  ensure)
    resolved && exit 0
    mode="$(jq -r 'if (.mode // "local") == "connected" or (.api_url // "") != "" then "connected" else "local" end' "$CONFIG" 2>/dev/null || echo local)"
    if [ "$mode" = "local" ]; then
      EGREGORE_ROOT="$ROOT" \
        PYTHONSAFEPATH=1 PYTHONPATH="$RUNTIME_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
        python3 -m egregore_runtime.identity_cli initialize-local >/dev/null
    else
      api_url="$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null)"
      slug="$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)"
      api_key="$(grep '^EGREGORE_API_KEY=' "$ROOT/.env" 2>/dev/null | cut -d= -f2-)"
      [ -n "$api_url" ] && [ -n "$slug" ] || exit 1
      # Identity repair selects already-existing account and membership
      # records, then adopts their opaque IDs locally. If a stale credential
      # belongs to another org, recover only the configured org's existing key
      # through verified GitHub membership. No control-plane records are made.
      control_plane=""
      if [ -n "$api_key" ]; then
        control_plane="$(curl -sf "$api_url/api/org/status" \
          -H "Authorization: Bearer $api_key" --connect-timeout 2 --max-time 4 \
          2>/dev/null || true)"
      fi
      if ! printf '%s' "$control_plane" | jq -e --arg slug "$slug" '
        (.org_id | type == "string" and length > 0) and .slug == $slug
      ' >/dev/null 2>&1; then
        # A historic path/namespace collision could leave this checkout with
        # another Egregore's API key. Recover the configured org's existing key
        # only through the membership-verifying endpoint, install it atomically,
        # and retry. No credential bytes are printed.
        github_token="$(grep '^GITHUB_TOKEN=' "$ROOT/.env" 2>/dev/null | cut -d= -f2-)"
        [ -n "$github_token" ] || exit 1
        encoded_slug="$(printf '%s' "$slug" | jq -sRr @uri)"
        recovered="$(curl -sf "$api_url/api/org/$encoded_slug/key" \
          -H "Authorization: Bearer $github_token" --connect-timeout 2 --max-time 12 \
          2>/dev/null || true)"
        printf '%s' "$recovered" | jq -e --arg slug "$slug" '
          (.api_key | type == "string" and length > 0) and .org_slug == $slug
        ' >/dev/null 2>&1 || exit 1
        printf '%s' "$recovered" | \
          EGREGORE_ROOT="$ROOT" \
          PYTHONSAFEPATH=1 PYTHONPATH="$RUNTIME_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
          python3 -m egregore_runtime.identity_cli install-connected-key >/dev/null
        api_key="$(grep '^EGREGORE_API_KEY=' "$ROOT/.env" 2>/dev/null | cut -d= -f2-)"
        control_plane="$(curl -sf "$api_url/api/org/status" \
          -H "Authorization: Bearer $api_key" --connect-timeout 2 --max-time 4 \
          2>/dev/null || true)"
        printf '%s' "$control_plane" | jq -e --arg slug "$slug" '
          (.org_id | type == "string" and length > 0) and .slug == $slug
        ' >/dev/null 2>&1 || exit 1
      fi
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
    echo 'usage: bash bin/runtime-identity.sh {ensure|status}' >&2
    exit 2
    ;;
esac
