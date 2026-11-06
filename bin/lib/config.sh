#!/usr/bin/env bash
# Shared config helpers — sourced by session-start.sh and other scripts.
# Expects SCRIPT_DIR to be set by the caller.

# Load specific variables from .env (safe extraction, no code execution)
_load_env_var() {
  local var_name="$1"
  local env_file="${ENV_FILE:-$SCRIPT_DIR/.env}"
  if [ -f "$env_file" ]; then
    grep "^${var_name}=" "$env_file" 2>/dev/null | cut -d'=' -f2- || true
  fi
}

# Read a value from egregore.json
_config_val() {
  local key="$1"
  local default="${2:-}"
  local config="${CONFIG:-$SCRIPT_DIR/egregore.json}"
  if [ -f "$config" ]; then
    local val
    val=$(jq -r ".${key} // empty" "$config" 2>/dev/null || true)
    echo "${val:-$default}"
  else
    echo "$default"
  fi
}

# --- Hosted API address -------------------------------------------------------
# The hosted API moved to api.egregore.xyz after the October 2026 security
# reset. Its old Railway origin is retired and no longer ours to trust: a token
# or key sent there could reach whoever holds that address next. Every request
# that carries a credential resolves its address through _hosted_api_url, so an
# egregore.json or environment saved before the move never reaches it.
#
# The rule is an allowlist, not a normalizer. Only a plain web address is
# used: http or https, a host of letters, digits, dots, hyphens and
# underscores, an optional port and a plain path. Every transport reads such
# an address the same way, so its host is the one the request reaches. A plain
# address on the retired host becomes the hosted API; any other plain address
# is kept. Anything else (userinfo, backslashes, percent-encoding, curl glob
# characters, a query, whitespace inside, non-ASCII) is refused and nothing is
# sent, because curl, urllib and WHATWG parsers disagree about where it goes.
# Python: egregore_runtime/hosted_api.py. Node: packages/create-egregore/lib/
# hosted-api.js and the launcher's inline copy. TypeScript: bin/connector-
# google/src/hosted-api.ts. bin/tests/fixtures/hosted-api-url-vectors.json
# holds all of them to one rule and one table.
EGREGORE_HOSTED_API_ORIGIN="https://api.egregore.xyz"
EGREGORE_RETIRED_API_ORIGIN="https://egregore-production-55f2.up.railway.app"
EGREGORE_PLAIN_API_URL='^https?://([A-Za-z0-9._-]+)(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'
EGREGORE_PLAIN_API_TARGET='^https?://([A-Za-z0-9._-]+)(:[0-9]{1,5})?([/?#][!-~]*)?$'
EGREGORE_REFUSED_API_URL_NOTICE="The hosted services address isn't a plain web address, so nothing was sent. Correct api_url in egregore.json; the hosted address is $EGREGORE_HOSTED_API_ORIGIN."

# _api_url_trim TEXT — TEXT without surrounding ASCII whitespace.
_api_url_trim() {
  local LC_ALL=C
  local text="${1:-}"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

# _plain_api_url TEXT — succeeds when TEXT is a plain address; sets
# _PLAIN_API_HOST (the host, compared ignoring case and trailing dots) and
# _PLAIN_API_PATH. No subshells: this runs on every hosted request.
_plain_api_url() {
  local LC_ALL=C
  local restore_case=0 retired="${EGREGORE_RETIRED_API_ORIGIN#https://}" host
  _PLAIN_API_HOST=""
  _PLAIN_API_PATH=""
  _PLAIN_API_RETIRED=false
  if shopt -q nocasematch; then shopt -u nocasematch; restore_case=1; fi
  if ! [[ "${1:-}" =~ $EGREGORE_PLAIN_API_URL ]]; then
    [ "$restore_case" = 0 ] || shopt -s nocasematch
    return 1
  fi
  host="${BASH_REMATCH[1]}"
  _PLAIN_API_PATH="${BASH_REMATCH[3]}"
  while [ "${host%.}" != "$host" ]; do host="${host%.}"; done
  _PLAIN_API_HOST="$host"
  shopt -s nocasematch
  [[ "$host" == "$retired" ]] && _PLAIN_API_RETIRED=true
  [ "$restore_case" = 1 ] || shopt -u nocasematch
  return 0
}

# _retired_api_url URL — succeeds when URL is a plain address on the retired
# host. Silent; a refused address is not retired.
_retired_api_url() {
  local text="${1:-}" LC_ALL=C
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  _plain_api_url "$text" && [ "$_PLAIN_API_RETIRED" = true ]
}

# _hosted_api_url URL — the address to send a request to, trailing slashes
# trimmed. A plain address on the retired host becomes the hosted API with its
# path kept; any other plain address keeps its text; empty stays empty. Any
# other address prints nothing, says why once on stderr (EGREGORE_ADDRESS_NOTICE
# =shown silences it), and fails: callers send nothing, exactly as when no
# hosted address is set.
_hosted_api_url() {
  local url="${1:-}" LC_ALL=C
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  if [ -z "$url" ]; then
    printf '\n'
    return 0
  fi
  if ! _plain_api_url "$url"; then
    [ "${EGREGORE_ADDRESS_NOTICE:-}" = shown ] || printf '%s\n' "$EGREGORE_REFUSED_API_URL_NOTICE" >&2
    return 1
  fi
  [ "$_PLAIN_API_RETIRED" = false ] || url="$EGREGORE_HOSTED_API_ORIGIN$_PLAIN_API_PATH"
  while [ "${url%/}" != "$url" ]; do url="${url%/}"; done
  printf '%s\n' "$url"
}

# _hosted_api_target URL — a full request URL (a path and query after the
# origin) to send a credential to. Its origin must be plain, so every
# transport reads the same host; the rest may be any printable ASCII without
# spaces (curl callers pass --globoff, so glob characters there stay literal).
# A plain retired origin becomes the hosted API and keeps the rest. Anything
# else prints nothing, says why on stderr, and fails.
_hosted_api_target() {
  local url="${1:-}" LC_ALL=C restore_case=0 rest
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  if shopt -q nocasematch; then shopt -u nocasematch; restore_case=1; fi
  if ! [[ "$url" =~ $EGREGORE_PLAIN_API_TARGET ]]; then
    [ "$restore_case" = 0 ] || shopt -s nocasematch
    [ "${EGREGORE_ADDRESS_NOTICE:-}" = shown ] || printf '%s\n' "$EGREGORE_REFUSED_API_URL_NOTICE" >&2
    return 1
  fi
  rest="${BASH_REMATCH[3]}"
  [ "$restore_case" = 0 ] || shopt -s nocasematch
  if _retired_api_url "${url%"$rest"}"; then
    url="$EGREGORE_HOSTED_API_ORIGIN$rest"
  fi
  printf '%s\n' "$url"
}

# _config_api_url — egregore.json's api_url, resolved for a request; fails
# when it is refused.
_config_api_url() {
  _hosted_api_url "$(_config_val api_url)"
}

# Get base branch for a repo. Reads base_branch from egregore.json — top-level
# for the core egregore repo, per-entry under repos[] for managed repos.
# Defaults to "develop" for backwards compatibility only when a valid config
# omits the setting. Missing, unreadable, malformed, or invalid config fails:
# callers must never turn a config read failure into a remote branch mutation.
#
# Setting a top-level "base_branch": "main" is single-branch mode: the whole
# develop layer disappears and everything (session start, sync, the branch
# guard, PR bases) targets main instead. Solo operators who never wanted the
# develop/main split had no way to say so — the core repo used to be hardcoded
# even though managed repos were already configurable.
#
# Usage: _get_base_branch "repo-name"   (omit for core repo)
_get_base_branch() {
  local repo_name="${1:-}"
  local config="${CONFIG:-$SCRIPT_DIR/egregore.json}"
  local base=""

  if [ ! -r "$config" ]; then
    echo "config: cannot read $config" >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "$config" >/dev/null 2>&1; then
    echo "config: invalid JSON object in $config" >&2
    return 1
  fi

  if [ -z "$repo_name" ]; then
    # Core egregore repo — top-level base_branch. An absent value preserves
    # the historical develop default; an explicitly invalid value is an error.
    if jq -e 'has("base_branch")' "$config" >/dev/null 2>&1; then
      if ! base=$(jq -er '.base_branch | select(type == "string")' "$config" 2>/dev/null); then
        echo "config: base_branch must be a valid branch name" >&2
        return 1
      fi
    else
      base="develop"
    fi
  else
    # Managed repo — its own entry under repos[]. Unknown/string-form entries
    # retain the historical develop default.
    local repo_json
    repo_json=$(jq -c --arg name "$repo_name" \
      'first(.repos[]? | select((if type == "object" then .name else . end) == $name)) // null' \
      "$config" 2>/dev/null) || {
        echo "config: cannot resolve managed repo $repo_name" >&2
        return 1
      }
    if [ "$repo_json" != "null" ] \
       && [ "$(printf '%s' "$repo_json" | jq -r 'type')" = "object" ] \
       && printf '%s' "$repo_json" | jq -e 'has("base_branch")' >/dev/null 2>&1; then
      if ! base=$(printf '%s' "$repo_json" | jq -er '.base_branch | select(type == "string")' 2>/dev/null); then
        echo "config: base_branch for $repo_name must be a valid branch name" >&2
        return 1
      fi
    else
      base="develop"
    fi
  fi

  if [ -z "$base" ] || ! git check-ref-format --branch "$base" >/dev/null 2>&1; then
    echo "config: base_branch must be a valid branch name" >&2
    return 1
  fi
  echo "$base"
}

# The Connected test as a jq filter: not explicitly Local, and an api_url saved.
EGREGORE_CONNECTED_JQ='(.mode // "") != "local" and ((.api_url // "") | length > 0)'

# Detect local vs connected mode
_detect_mode() {
  local config="${CONFIG:-$SCRIPT_DIR/egregore.json}"
  if [ -f "$config" ] && jq -e "$EGREGORE_CONNECTED_JQ" "$config" >/dev/null 2>&1; then
    echo "connected"
  else
    echo "local"
  fi
}

# Whether the optional derived graph projection may be used by compatibility
# commands. An explicit environment value wins for bounded maintenance/tests.
# Connected membership alone never enables this optional content projection.
# Missing, malformed, and non-boolean configuration all remain disabled.
_graph_projection_enabled() {
  case "${EGREGORE_GRAPH_PROJECTION:-}" in
    1|true|enabled) return 0 ;;
    0|false|disabled) return 1 ;;
  esac

  local config="${CONFIG:-$SCRIPT_DIR/egregore.json}"
  [ -r "$config" ] || return 1
  jq -e '.features | type == "object" and .graph_projection == true' \
    "$config" >/dev/null 2>&1
}

# Compact runtime identity shared by terminal surfaces. The sigils deliberately
# distinguish an active hosted connection from the self-contained local mode
# without implying that local Egregore is unhealthy.
_runtime_mode_badge() {
  if [ "$(_detect_mode)" = "connected" ]; then
    echo "◆ CONNECTED"
  else
    echo "◇ LOCAL"
  fi
}

# Session record policy readers preserve explicit false values. Missing policy
# is off; missing detail/model inherit the documented defaults.
_session_records_val() {
  local key="$1" default="$2" val
  local config="${CONFIG:-$SCRIPT_DIR/egregore.json}"
  val=$(jq -r --arg key "$key" '
    .features.session_records | if type == "object" and has($key)
    then .[$key] | tostring else empty end
  ' "$config" 2>/dev/null || true)
  printf '%s\n' "${val:-$default}"
}

_session_records_enabled() {
  [ "$(_session_records_val enabled false)" = "true" ]
}

_session_records_default_detail() {
  _session_records_val default_detail outline
}

_session_records_model() {
  _session_records_val model haiku
}
