#!/usr/bin/env bash
# Uses an already-running local Docker engine and an already-cached image.
# Never pulls an image, starts Docker, exposes a port, or uses a supplied database.
set -euo pipefail

skip() { printf 'SKIP: %s\n' "$1"; exit 0; }
command -v docker >/dev/null 2>&1 || skip 'Docker CLI unavailable'
docker_host="${DOCKER_HOST:-}"
if [ -z "$docker_host" ]; then
  docker_host="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" || skip 'Docker context unavailable'
fi
case "$docker_host" in
  unix://*) ;;
  *) skip 'test requires a local Unix-socket Docker engine' ;;
esac
docker_local() { env -u DOCKER_CONTEXT docker --host "$docker_host" "$@"; }
docker_local info >/dev/null 2>&1 || skip 'local Docker engine is not running'
image='postgres:17-alpine'
docker_local image inspect "$image" >/dev/null 2>&1 || skip 'postgres:17-alpine is not cached; no image was downloaded'

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
container="egregore-agent-rpc-permissions-$$"
cleanup() { docker_local rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker_local run --detach --pull=never --network=none --name "$container" \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  --mount "type=bind,source=$repo_root,target=/repo,readonly" \
  "$image" >/dev/null

# Wait through initdb's temporary server and the final post-init startup.
ready=0
for _attempt in $(seq 1 80); do
  if docker_local exec "$container" psql -X -U postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
    ready=$((ready + 1))
    [ "$ready" -lt 3 ] || break
  else
    ready=0
  fi
  sleep 0.25
done
[ "$ready" -ge 3 ] || { echo 'FAIL: disposable PostgreSQL did not start' >&2; exit 1; }
docker_local exec "$container" psql -X -q -v ON_ERROR_STOP=1 -U postgres \
  -f /repo/tests/sql/agent_control_rpc_permissions.sql
