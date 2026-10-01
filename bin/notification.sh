#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EGREGORE_ROOT="$ROOT" PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  exec python3 -m egregore_runtime.notification_cli "$@"
