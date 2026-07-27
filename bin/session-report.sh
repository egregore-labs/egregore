#!/usr/bin/env bash
# Egregore session report — opt-in feedback from OSS users.
# Mirrors bin/telemetry.sh patterns.
#
# Subcommands:
#   submit           Read report JSON from stdin, POST to Supabase
#   status           Show reporting config and any unsent reports
#
# Consent: opt-out via EGREGORE_NO_REPORTS=1, DO_NOT_TRACK=1,
#          or .egregore-state.json → "session_reports": false
#
# What is sent: AI-analyzed topic, summary, gap classifications,
#               user description, system info (mode, platform, shell).
# Never sent: code, file contents, file paths, env var values,
#             conversation transcript, org-specific data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORTS_DIR="$HOME/.egregore/reports"
STATE_FILE="$SCRIPT_DIR/.egregore-state.json"
CONFIG="$SCRIPT_DIR/egregore.json"

# --- Consent check ---
_check_consent() {
  [ "${EGREGORE_NO_REPORTS:-}" = "1" ] && return 1
  [ "${DO_NOT_TRACK:-}" = "1" ] && return 1

  if [ -f "$STATE_FILE" ]; then
    local val
    val=$(jq -r '.session_reports // "true"' "$STATE_FILE" 2>/dev/null || echo "true")
    [ "$val" = "false" ] && return 1
  fi

  return 0
}

# --- Read Supabase config ---
_get_report_url() {
  if [ -f "$CONFIG" ]; then
    jq -r '.report_url // empty' "$CONFIG" 2>/dev/null || true
  fi
}

_get_report_key() {
  if [ -f "$CONFIG" ]; then
    jq -r '.report_key // empty' "$CONFIG" 2>/dev/null || true
  fi
}

# --- Resolve identity ---
_resolve_user() {
  if [ -n "${EGREGORE_USER:-}" ]; then
    echo "$EGREGORE_USER"
  elif [ -f "$STATE_FILE" ]; then
    jq -r '.github_username // .name // "anonymous"' "$STATE_FILE" 2>/dev/null || echo "anonymous"
  else
    echo "anonymous"
  fi
}

_resolve_org() {
  if [ -f "$CONFIG" ]; then
    jq -r '.org_name // "unknown"' "$CONFIG" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

# --- submit: read JSON from stdin, POST to Supabase ---
cmd_submit() {
  # Consent gate
  if ! _check_consent; then
    echo '{"status":"skipped","reason":"consent_denied"}' >&2
    return 0
  fi

  local report_url
  local report_key
  report_url=$(_get_report_url)
  report_key=$(_get_report_key)

  if [ -z "$report_url" ] || [ -z "$report_key" ]; then
    echo '{"status":"skipped","reason":"not_configured"}' >&2
    return 0
  fi

  # Read JSON from stdin
  local payload
  payload=$(cat)

  if [ -z "$payload" ]; then
    echo '{"status":"error","reason":"empty_payload"}' >&2
    return 1
  fi

  # Inject identity fields (override any client-sent values for consistency)
  local user org
  user=$(_resolve_user)
  org=$(_resolve_org)
  payload=$(echo "$payload" | jq \
    --arg user "$user" \
    --arg org "$org" \
    '. + {github_username: $user, org_name: $org}' 2>/dev/null || echo "$payload")

  # POST to Supabase REST API
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "${report_url}/rest/v1/session_reports" \
    -H "apikey: ${report_key}" \
    -H "Authorization: Bearer ${report_key}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    --data-raw "$payload" \
    --connect-timeout 5 \
    --max-time 15 2>/dev/null || echo "000")

  if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null; then
    echo '{"status":"submitted"}'
  else
    # Fallback: save locally
    mkdir -p "$REPORTS_DIR"
    local ts slug fallback_file
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    slug=$(echo "$payload" | jq -r '.topic // "report"' 2>/dev/null | \
      tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 40)
    fallback_file="$REPORTS_DIR/$(date -u +%Y-%m-%d)-${slug}.json"
    echo "$payload" | jq --arg ts "$ts" '. + {saved_at: $ts}' > "$fallback_file" 2>/dev/null \
      || echo "$payload" > "$fallback_file"

    jq -n --arg path "$fallback_file" --arg code "$http_code" \
      '{status: "saved_locally", path: $path, http_code: $code}' >&2
  fi
}

# --- status: show reporting config ---
cmd_status() {
  echo "Session report status:"
  echo ""

  # Consent
  if _check_consent; then
    echo "  Enabled: yes"
  else
    echo "  Enabled: no"
    if [ "${EGREGORE_NO_REPORTS:-}" = "1" ]; then
      echo "  Reason: EGREGORE_NO_REPORTS=1"
    elif [ "${DO_NOT_TRACK:-}" = "1" ]; then
      echo "  Reason: DO_NOT_TRACK=1"
    else
      echo "  Reason: session_reports=false in .egregore-state.json"
    fi
  fi

  # Config
  local report_url
  report_url=$(_get_report_url)
  if [ -n "$report_url" ]; then
    echo "  Endpoint: configured"
  else
    echo "  Endpoint: not configured (report_url missing from egregore.json)"
  fi

  # Unsent reports
  if [ -d "$REPORTS_DIR" ]; then
    local count
    count=$(find "$REPORTS_DIR" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
      echo "  Unsent: $count reports in $REPORTS_DIR"
    fi
  fi

  echo ""
  echo "  Opt-out: set EGREGORE_NO_REPORTS=1 in .env, or set session_reports=false in state"
}

# --- Main dispatch ---
case "${1:-status}" in
  submit)
    cmd_submit
    ;;
  status)
    cmd_status
    ;;
  help|*)
    echo "Usage: session-report.sh <command>"
    echo ""
    echo "Commands:"
    echo "  submit    Read report JSON from stdin, submit to Supabase"
    echo "  status    Show reporting config and unsent reports"
    ;;
esac
