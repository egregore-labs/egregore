#!/usr/bin/env bash
set -euo pipefail
set +x

# GitHub operations must not inherit repository-selection or Git overrides.
for gh_run_git_name in "${!GIT_@}"; do
  unset "$gh_run_git_name"
done

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Consumed by _load_env_var in the sourced config helper.
# shellcheck disable=SC2034
ENV_FILE="$SCRIPT_DIR/.env"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/config.sh"

gh_run_token=$(_load_env_var GITHUB_TOKEN)
# Trim surrounding whitespace, including CRLF, without evaluating .env.
gh_run_token="${gh_run_token#"${gh_run_token%%[![:space:]]*}"}"
gh_run_token="${gh_run_token%"${gh_run_token##*[![:space:]]}"}"

if [ -n "$gh_run_token" ]; then
  GITHUB_TOKEN="$gh_run_token" exec gh "$@"
fi
exec gh "$@"
