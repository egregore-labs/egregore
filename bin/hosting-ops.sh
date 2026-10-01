#!/usr/bin/env bash
set -euo pipefail
set +vx
umask 077
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-$SCRIPT_DIR/egregore.json}"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/config.sh"

usage() {
  echo 'Usage: bash bin/hosting-ops.sh status|enable|wait-ready|users <slug>' >&2
  echo '       bash bin/hosting-ops.sh ssh <slug> [--] <remote command…>' >&2
  echo '       bash bin/hosting-ops.sh scp <slug> <local file> <remote path>' >&2
  echo '       bash bin/hosting-ops.sh deploy-template <slug> [--name <version>]' >&2
  echo '       bash bin/hosting-ops.sh restart-workspace <slug> <workspace id>' >&2
  echo '       bash bin/hosting-ops.sh user <slug> <github username>' >&2
  echo '       bash bin/hosting-ops.sh list' >&2
  exit 2
}

die() { printf 'hosting-ops: %s\n' "$*" >&2; exit 1; }

[ "$#" -ge 1 ] || usage
operation="$1"
shift
case "$operation" in
  list) [ "$#" -eq 0 ] || usage ;;
  status|enable|wait-ready|users) [ "$#" -eq 1 ] || usage ;;
  user|restart-workspace) [ "$#" -eq 2 ] && [ -n "$2" ] || usage ;;
  scp) [ "$#" -eq 3 ] && [ -n "$2" ] && [ -n "$3" ] || usage ;;
  ssh) [ "$#" -ge 2 ] || usage ;;
  deploy-template)
    [ "$#" -eq 1 ] || { [ "$#" -eq 3 ] && [ "$2" = --name ] && [ -n "$3" ]; } || usage
    ;;
  *) usage ;;
esac
slug="${1-}"
if [ "$operation" != list ]; then
  # Slugs are URL path/query components, never shell source.
  case "$slug" in ''|*[!a-zA-Z0-9_-]*) usage ;; esac
  shift
fi
if [ "$operation" = ssh ]; then
  if [ "${1-}" = -- ]; then shift; fi
  [ "$#" -ge 1 ] && [ -n "$1" ] || usage
  # A quoted command is unchanged; separate words use SSH's usual space join.
  remote_command="$*"
fi
if [ "$operation" = restart-workspace ]; then
  case "$1" in *[!a-zA-Z0-9_-]*) usage ;; esac
fi
case "$operation" in
  ssh|scp|deploy-template|restart-workspace)
    command -v sshpass >/dev/null 2>&1 || die 'sshpass is required; install via brew install hudochenkov/sshpass/sshpass'
    ;;
esac

scratch=$(mktemp -d "${TMPDIR:-/tmp}/hosting-ops.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 1' HUP INT TERM

gateway() {
  bash "$SCRIPT_DIR/bin/api-call.sh" "$@" --auth github || die 'API gateway request failed'
}

body_error() {
  jq -er 'if type == "object" then (.error // .detail // (if .status == "error" then "request failed" else empty end)) else empty end | select(. != false and . != "") | if type == "string" then . else tojson end' "$1" 2>/dev/null
}

check_body() {
  local detail
  jq -e 'type == "object"' "$1" >/dev/null 2>&1 || die 'invalid response body'
  if detail=$(body_error "$1"); then die "$detail"; fi
}

credentials() {
  local failure="no hosted VPS or missing credentials for $slug"
  bash "$SCRIPT_DIR/bin/api-call.sh" GET "/api/hosting/credentials/$slug" --auth github --out "$scratch/credentials.json" 2>/dev/null \
    || die "$failure"
  ip=$(jq -r '.ip | select(type == "string")' "$scratch/credentials.json" 2>/dev/null) || die "$failure"
  vps_password=$(jq -r '.password | select(type == "string")' "$scratch/credentials.json" 2>/dev/null) || die "$failure"
  [ -n "$ip" ] && [ -n "$vps_password" ] || die "$failure"
}

vps_ssh() {
  SSHPASS="$vps_password" sshpass -e ssh -o StrictHostKeyChecking=no "root@$ip" "$@"
}

vps_scp() {
  SSHPASS="$vps_password" sshpass -e scp -o StrictHostKeyChecking=no "$1" "root@$ip:$2"
}

coder_login() {
  # jq reads the password from stdin, never a --arg value.
  printf '%s' "$vps_password" | jq -Rs '{email:"admin@egregore.xyz", password:.}' > "$scratch/login.json"
  vps_ssh "curl -q -sS -H 'Content-Type: application/json' --data-binary @- http://localhost/api/v2/users/login" \
    < "$scratch/login.json" > "$scratch/login-response.json" 2>/dev/null || die 'Coder login failed'
  coder_token=$(jq -er '.session_token | select(type == "string" and length > 0)' "$scratch/login-response.json" 2>/dev/null) \
    || die 'Coder login failed'
}

curl_config_value() {
  # Curl config quoting, using builtins so secret values stay off exec argv.
  local value="$2"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s = "%s"\n' "$1" "$value"
}

coder_request() {
  local code
  {
    curl_config_value header "Coder-Session-Token: $coder_token"
    curl_config_value url "http://localhost/api/v2$2"
    curl_config_value request "$1"
    if [ -n "${3-}" ]; then
      curl_config_value header 'Content-Type: application/json'
      curl_config_value data "$(cat "$3")"
    fi
  } > "$scratch/coder-curl.conf"
  vps_ssh "curl -q -sS -K - --write-out '\n%{http_code}'" < "$scratch/coder-curl.conf" \
    > "$scratch/coder-response" 2>/dev/null || die 'Coder request failed'
  code=$(tail -n 1 "$scratch/coder-response")
  case "$code" in 2[0-9][0-9]) ;; *) die 'Coder request failed' ;; esac
  sed '$d' "$scratch/coder-response" > "$scratch/coder.json"
  jq -e 'type == "object"' "$scratch/coder.json" >/dev/null 2>&1 || die 'Coder request failed'
  if body_error "$scratch/coder.json" >/dev/null; then die 'Coder request failed'; fi
}

deploy_template() {
  local version="$1" api_url
  vps_ssh 'mkdir -p /tmp/egregore-template' > /dev/null || die 'template directory creation failed'
  vps_scp "$SCRIPT_DIR/docker/egregore-template/main.tf" /tmp/egregore-template/main.tf > /dev/null || die 'template copy failed'
  coder_login
  vps_ssh 'cat /opt/egregore/org-config.json' > "$scratch/org-config.json" || die 'cannot read VPS org config'
  vps_ssh 'cat /opt/egregore/github-token 2>/dev/null' > "$scratch/github-token" || die 'cannot read VPS GitHub token'
  api_url=$(bash "$SCRIPT_DIR/bin/config-get.sh" api_url) || die 'cannot read api_url'
  [ -n "$api_url" ] || die 'api_url is not set'
  # A JSON object is also a YAML mapping, as accepted by --variables-file.
  # Do not use secret-valued --var flags: they leak on the remote argv too.
  jq -e --arg api_url "$api_url" --rawfile github_token "$scratch/github-token" '
    {egregore_api_key, api_url:$api_url, memory_url, fork_url,
     ghcr_token:"not-needed", github_token:($github_token | sub("\\n+$"; ""))}
    | if all(.[]; type == "string") then . else error("missing template variable") end
  ' "$scratch/org-config.json" > "$scratch/variables.json" 2>/dev/null || die 'VPS template variables are missing or invalid'
  {
    printf 'set -euo pipefail\nset +vx\numask 077\nunset CODER_SESSION_TOKEN\nexport CODER_URL=http://localhost\n'
    # Coder reads its session file; no secret is exported to child processes.
    printf 'coder_config=$(mktemp -d /tmp/egregore-coder-config.XXXXXX)\n'
    printf 'trap '\''rm -rf -- "$coder_config"'\'' EXIT\ntrap '\''exit 1'\'' HUP INT TERM\n'
    printf 'printf "%%s" %q > "$coder_config/session"\n' "$coder_token"
    printf 'vars_file=$(mktemp /tmp/egregore-template-vars.XXXXXX)\n'
    printf 'trap '\''rm -f -- "$vars_file"; rm -rf -- "$coder_config"'\'' EXIT\n'
    # printf is a Bash builtin, so these values never reach an exec argv.
    printf 'printf "%%s" %q > "$vars_file"\n' "$(cat "$scratch/variables.json")"
    printf 'coder --global-config "$coder_config" templates push Egregore --directory /tmp/egregore-template --name %q --variables-file "$vars_file" --yes\n' "$version"
  } > "$scratch/push.sh"
  vps_ssh bash -s < "$scratch/push.sh" || die 'template push failed'
  printf 'Template "Egregore" deployed: %s\n' "$version"
}

restart_workspace() {
  local workspace_id="$1" template_id active_version attempt stopped=false
  coder_login
  coder_request GET "/workspaces/$workspace_id"
  template_id=$(jq -er '.template_id | select(type == "string" and length > 0)' "$scratch/coder.json") \
    || die 'workspace has no template_id'
  printf '%s\n' '{"transition":"stop"}' > "$scratch/build.json"
  coder_request POST "/workspaces/$workspace_id/builds" "$scratch/build.json"
  for ((attempt=1; attempt<=24; attempt++)); do
    sleep 5
    coder_request GET "/workspaces/$workspace_id"
    if jq -e '.latest_build.status == "stopped"' "$scratch/coder.json" >/dev/null; then stopped=true; break; fi
  done
  [ "$stopped" = true ] || die 'workspace did not stop after 24 checks'
  coder_request GET "/templates/$template_id"
  active_version=$(jq -er '.active_version_id | select(type == "string" and length > 0)' "$scratch/coder.json") \
    || die 'template has no active_version_id'
  jq -n --arg version "$active_version" '{transition:"start", template_version_id:$version}' > "$scratch/build.json"
  coder_request POST "/workspaces/$workspace_id/builds" "$scratch/build.json"
  cat "$scratch/coder.json"
}

create_users() {
  local requested="${1-}" username detail response created=0 failed=0
  gateway GET "/api/admin/org/$slug" > "$scratch/org.json"
  check_body "$scratch/org.json"
  jq -er '.members | type == "array"' "$scratch/org.json" >/dev/null || die 'org response has no members'
  jq -r --arg requested "$requested" '.members[]
    | select(if $requested == "" then .status == "active" else .github_username == $requested end)
    | .github_username | select(type == "string" and length > 0)' "$scratch/org.json" > "$scratch/members"
  while IFS= read -r username; do
    jq -n --arg name "$username" '{username:$name}' > "$scratch/member.json"
    detail=''
    response="$scratch/member-response.json"
    if ! bash "$SCRIPT_DIR/bin/api-call.sh" POST "/api/hosting/user/$slug" --auth egregore --json-file "$scratch/member.json" \
        --error-out "$scratch/member-error.json" > "$response" 2>/dev/null; then
      response="$scratch/member-error.json"
      detail='API gateway request failed'
    fi
    if ! jq -e 'type == "object"' "$response" >/dev/null 2>&1; then
      detail="${detail:-invalid response body}"
    else
      # Only the bounded, operator-facing detail is published, never raw JSON.
      detail=$(jq -r --arg fallback "$detail" '(.detail | select(. != "")) // $fallback | if type == "string" then . else tojson end | .[:200]' "$response")
    fi
    if [ -n "$detail" ]; then
      printf '✗ %s — error: %s\n' "$username" "$detail"
      failed=$((failed + 1))
    else
      printf '✓ %s — Coder user created (workspace is created on first open)\n' "$username"
      created=$((created + 1))
    fi
  done < "$scratch/members"
  printf 'Done: %s created, %s failed\n' "$created" "$failed"
  [ "$failed" -eq 0 ]
}

case "$operation" in
  status) gateway GET "/api/hosting/status/$slug" ;;
  enable) gateway POST "/api/hosting/enable/$slug" ;;
  list) gateway GET /api/admin/health ;;
  wait-ready)
    poll_seconds="${HOSTING_OPS_POLL_SECONDS:-30}"
    case "$poll_seconds" in ''|*[!0-9]*) usage ;; esac
    for ((attempt=1; attempt<=10; attempt++)); do
      # Emit a progress line even when this attempt returns an error body.
      gateway GET "/api/hosting/status/$slug" > "$scratch/status.json"
      progress=$(jq -r '"ip: \(.ip // "unknown") — token_stored: \(if has("token_stored") then .token_stored else "unknown" end)"' "$scratch/status.json" 2>/dev/null) || die 'invalid status response'
      printf 'check %s/10 — %s\n' "$attempt" "$progress"
      check_body "$scratch/status.json"
      if jq -e '.coder_ready == true' "$scratch/status.json" >/dev/null; then exit 0; fi
      if [ "$attempt" -lt 10 ]; then sleep "$poll_seconds"; fi
    done
    die 'Coder did not become ready after 10 checks'
    ;;
  ssh) credentials; vps_ssh "$remote_command" || die 'SSH command failed' ;;
  scp) credentials; vps_scp "$1" "$2" || die 'SCP failed' ;;
  deploy-template) credentials; deploy_template "${2:-$slug-initial}" ;;
  restart-workspace) credentials; restart_workspace "$1" ;;
  users) create_users ;;
  user) create_users "$1" ;;
esac
