#!/usr/bin/env bash
# One managed push, guarded in this process at dispatch. No raw-push fallback.
set -eu
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  exec python3 -m egregore_runtime.memory_push "$@"
