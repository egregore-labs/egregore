#!/usr/bin/env bash
# One bounded, authorized, canonical Runtime snapshot for the dashboard ritual.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIME_RANGE="${2:-${1:-P7D}}"

# Keep the historical `[username] [range]` shape without treating a provider
# alias as identity. A recognized range in argv[1] is the new compact form.
case "$TIME_RANGE" in
  P1D|P7D|P30D|P365D) ;;
  *) TIME_RANGE="P7D" ;;
esac

ARGS=(dashboard --time-range "$TIME_RANGE")
[ "${EGREGORE_STATUS_CONNECTED_ENRICH:-0}" = "1" ] && ARGS+=(--connected-enrichment)
EGREGORE_ROOT="$ROOT" PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  exec python3 -m egregore_runtime.status_cli "${ARGS[@]}"
