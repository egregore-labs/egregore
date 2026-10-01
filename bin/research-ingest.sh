#!/usr/bin/env bash
# Typed Runtime boundary for approved meeting/interview analysis packages.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EGREGORE_ROOT="$ROOT" PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  exec python3 -m egregore_runtime.research_ingest_cli "$@"
