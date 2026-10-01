#!/usr/bin/env bash
# One bounded, authorized, canonical Runtime snapshot for the activity ritual.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Compatibility: the positional handle is intentionally ignored. Identity is
# resolved by Egregore Runtime, not by a GitHub username supplied by a harness.
if [ "${1:-}" = "--help" ]; then
  echo "usage: bash bin/activity-data.sh"
  exit 0
fi

ARGS=(activity --time-range P7D)
[ "${EGREGORE_STATUS_CONNECTED_ENRICH:-0}" = "1" ] && ARGS+=(--connected-enrichment)
EGREGORE_ROOT="$ROOT" PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  exec python3 -m egregore_runtime.status_cli "${ARGS[@]}"
