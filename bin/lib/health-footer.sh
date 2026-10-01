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
  local width="${LINE_WIDTH:-65}" failed=0
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
  if [ "${FRAMEWORK_UPDATED:-false}" = "true" ]; then
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
