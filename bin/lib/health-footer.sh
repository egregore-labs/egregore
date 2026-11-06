# shellcheck shell=bash
# health-footer.sh — the one health footer every greeting renders.
#
# Claude (bin/lib/greeting.sh), Codex, Pi, and Prime (bin/codex-session-start.sh)
# used to carry their own copy of the footer loop, and each copy reduced every
# failure to "<name> ✗ — run /checkup". This library is the single renderer:
# one line per failed dimension, naming the cause and the action, and a
# separate non-failure line when recall is merely stale.
#
# Inputs (all optional; unset reads as "skip"):
#   LOCAL_MODE               "true" → only github/git/memory/recall are judged
#   HEALTH_GITHUB, HEALTH_GITHUB_REASON
#   HEALTH_GIT, HEALTH_GIT_REASON
#   HEALTH_MEMORY, HEALTH_MEMORY_REASON
#   HEALTH_RETRIEVAL         ok | stale | fail | skip
#   HEALTH_RETRIEVAL_DETAIL
#   HEALTH_APIKEY, HEALTH_GRAPH, HEALTH_TELEGRAM   (connected mode only)
#   MEMORY_SYNCED            "true" when canonical memory reached the remote
#   FRAMEWORK_UPDATED        "true" when a framework update was applied
#   LINE_WIDTH               card width for the ready line (default 65)
#
# Output: the footer lines on stdout, each already indented two spaces.
# Returns 0 when nothing failed, 1 when at least one dimension failed.

# Dated, release-delivered incident copy, not a live availability check. Keep
# the launcher counterpart aligned; launcher-connected-status.test.js checks
# the actual output of both implementations. No network or credential reads.
_hosted_recovery_notice() {
  [ "${LOCAL_MODE:-true}" != "true" ] || return 0
  local origin now
  [ -f "${CONFIG:-}" ] || return 0
  origin=$(jq -r '.api_url // empty' "$CONFIG" 2>/dev/null) || return 0
  case "$origin" in
    https://api.egregore.xyz|https://api.egregore.xyz/|https://egregore-production-55f2.up.railway.app|https://egregore-production-55f2.up.railway.app/) ;;
    *) return 0 ;;
  esac
  now=$(date -u +%s 2>/dev/null) || now=0
  # A stale bundled notice never presents itself as current service status.
  if [ "$now" -ge 1792627200 ] 2>/dev/null && [ "$now" -lt 1792800000 ] 2>/dev/null; then
    printf '%s\n' '  ◐ Service recovery · 22 Oct 2026' \
      '    Some connected services are temporarily unavailable' \
      '    during security recovery.'
  else
    printf '%s\n' '  ◐ Service recovery · last update 22 Oct 2026' \
      '    Some connected services were unavailable at this update.' \
      '    Current hosted availability has not been checked.'
  fi
  printf '%s\n' '    Local memory and search remain available.' \
    '    Keep your existing Egregore; you do not need to set it up again.'
}

# Recorded in .egregore-state.json by bin/runtime-identity.sh when it renews,
# or cannot renew, an organization key retired in the October 2026 security
# reset. Local state only; no network. The renewal shows once; the sign-in
# line shows each session until a renewal works.
_hosted_key_notice() {
  [ "${LOCAL_MODE:-true}" != "true" ] || return 0
  local state_file="${STATE_FILE:-}" file tmp
  [ -n "$state_file" ] && [ -f "$state_file" ] || return 0
  case "$(jq -r '.hosted_key_notice.state // empty' "$state_file" 2>/dev/null)" in
    renewed)
      printf '%s\n' "  ↻ Hosted services renewed this organization's key after" \
        '    the October security reset. Your memory, files and' \
        '    history are untouched.'
      file=$(realpath "$state_file" 2>/dev/null) || file="$state_file"
      tmp=$(mktemp "$file.XXXXXX" 2>/dev/null) || return 0
      jq 'if .hosted_key_notice.state == "renewed" then del(.hosted_key_notice) else . end' \
        "$file" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv "$tmp" "$file" || rm -f "$tmp"
      ;;
    needs_sign_in)
      printf '%s\n' '  ◐ Hosted services need a fresh key after the October' \
        '    security reset. Your memory, files and history are' \
        '    untouched. Run bash bin/github-auth.sh and start a new' \
        '    session — it renews on its own.'
      ;;
  esac
  return 0
}

# A Connected org whose saved api_url is not a plain web address sends nothing
# to hosted services (bin/lib/config.sh refuses it), and /update rewrites only
# a plain retired address. Say so each session until egregore.json is fixed.
# Needs config.sh's resolver; reads local config only.
_hosted_address_notice() {
  [ "${LOCAL_MODE:-true}" != "true" ] || return 0
  [ -f "${CONFIG:-}" ] || return 0
  command -v _config_api_url >/dev/null 2>&1 || return 0
  EGREGORE_ADDRESS_NOTICE=shown _config_api_url >/dev/null 2>&1 && return 0
  printf '%s\n' "  ◐ Hosted services are off: api_url in egregore.json isn't" \
    '    a plain web address, so nothing is sent to it. Correct it' \
    "    (the hosted address is ${EGREGORE_HOSTED_API_ORIGIN:-https://api.egregore.xyz})" \
    '    and start a new session. Local memory and search work.'
}

_health_footer_label() {
  case "$1" in
    github) printf 'github' ;;
    git) printf 'git' ;;
    memory) printf 'memory sync' ;;
    retrieval) printf 'recall' ;;
    api-key) printf 'api-key' ;;
    graph) printf 'optional hosted index' ;;
    telegram) printf 'telegram' ;;
    *) printf '%s' "$1" ;;
  esac
}

_health_footer_reason() {
  case "$1" in
    github) printf '%s' "${HEALTH_GITHUB_REASON:-}" ;;
    git) printf '%s' "${HEALTH_GIT_REASON:-}" ;;
    memory) printf '%s' "${HEALTH_MEMORY_REASON:-}" ;;
    retrieval) printf '%s' "${HEALTH_RETRIEVAL_DETAIL:-}" ;;
    api-key) printf '%s' "${HEALTH_APIKEY_REASON:-}" ;;
    graph) printf '%s' "${HEALTH_GRAPH_REASON:-}" ;;
    telegram) printf '%s' "${HEALTH_TELEGRAM_REASON:-}" ;;
    *) printf '' ;;
  esac
}

# Print the failure line for one dimension when its state is "fail".
# Returns 1 when it printed (the dimension failed), 0 otherwise. Written as
# a per-call helper rather than a word-split loop so bash and zsh agree.
_health_footer_check() {
  local dim="$1" state="${2:-skip}" label reason
  [ "$state" = "fail" ] || return 0
  label="$(_health_footer_label "$dim")"
  reason="$(_health_footer_reason "$dim")"
  if [ -n "$reason" ]; then
    printf '  ⚠ %s ✗ — %s\n' "$label" "$reason"
  else
    printf '  ⚠ %s ✗ — run /checkup\n' "$label"
  fi
  return 1
}

_render_health_footer() {
  local width="${LINE_WIDTH:-65}" failed=0 recovery_notice key_notice address_notice local_only=""
  address_notice=$(_hosted_address_notice)
  [ -z "$address_notice" ] || { printf '%s\n' "$address_notice"; local_only=1; }
  recovery_notice=$(_hosted_recovery_notice)
  [ -z "$recovery_notice" ] || printf '%s\n' "$recovery_notice"
  key_notice=$(_hosted_key_notice)
  [ -z "$key_notice" ] || printf '%s\n' "$key_notice"
  # Hosted services stay out of reach for this person until the key renews.
  [ -z "$recovery_notice" ] || local_only=1
  case "$key_notice" in *"need a fresh key"*) local_only=1 ;; esac
  _health_footer_check github "${HEALTH_GITHUB:-skip}" || failed=1
  _health_footer_check git "${HEALTH_GIT:-skip}" || failed=1
  _health_footer_check memory "${HEALTH_MEMORY:-skip}" || failed=1
  _health_footer_check retrieval "${HEALTH_RETRIEVAL:-skip}" || failed=1
  if [ "${LOCAL_MODE:-false}" != "true" ]; then
    _health_footer_check api-key "${HEALTH_APIKEY:-skip}" || failed=1
    _health_footer_check graph "${HEALTH_GRAPH:-skip}" || failed=1
    _health_footer_check telegram "${HEALTH_TELEGRAM:-skip}" || failed=1
  fi

  # Stale recall is information, not a failure: the index answers from a
  # snapshot slightly behind the tree, and the detail says by how much.
  if [ "${HEALTH_RETRIEVAL:-skip}" = "stale" ]; then
    printf '  ◐ recall stale — %s\n' "${HEALTH_RETRIEVAL_DETAIL:-index is behind the canonical tree}"
  fi

  if [ "$failed" = "1" ]; then
    return 1
  fi

  local left right pad
  if [ -n "$local_only" ]; then
    left="  ✓ local checks ready"
  elif [ "${FRAMEWORK_UPDATED:-false}" = "true" ]; then
    left="  ◆ updated"
  else
    left="  ✓ ready"
  fi
  right=""
  if [ "${LOCAL_MODE:-false}" != "true" ]; then
    if [ "${MEMORY_SYNCED:-false}" = "true" ]; then
      case "${HEALTH_RETRIEVAL:-skip}" in
        ok) right="◆ memory + recall ready" ;;
        stale) right="◆ memory synced · recall stale" ;;
        *) right="◆ memory synced · recall unavailable" ;;
      esac
    elif [ "${HEALTH_MEMORY:-skip}" != "skip" ]; then
      right="◆ memory not synced"
    fi
  fi
  if [ -n "$right" ]; then
    pad=$((width - ${#left} - ${#right}))
    [ "$pad" -lt 1 ] && pad=1
    printf '%s%*s%s\n' "$left" "$pad" "" "$right"
  else
    printf '%s\n' "$left"
  fi
  return 0
}
