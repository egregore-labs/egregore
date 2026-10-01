#!/usr/bin/env bash
# Explicit management boundary for the optional derived graph projection.
# Usage: bash bin/graph-projection.sh {status|verify|rebuild} [--enable]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMAND="${1:-status}"
shift || true
ENABLED=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --enable) ENABLED=true ;;
    --help|-h)
      echo "Usage: graph-projection.sh {status|verify|rebuild} [--enable]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$COMMAND" in
  status|verify|rebuild) ;;
  --help|-h)
    echo "Usage: graph-projection.sh {status|verify|rebuild} [--enable]"
    exit 0
    ;;
  *) echo "Usage: graph-projection.sh {status|verify|rebuild} [--enable]" >&2; exit 2 ;;
esac

RUNTIME_PYTHONPATH="$ROOT"
if [ -n "${PYTHONPATH:-}" ]; then
  RUNTIME_PYTHONPATH="$RUNTIME_PYTHONPATH:$PYTHONPATH"
fi

GRAPH_OVERRIDE=0
[ "$ENABLED" = "true" ] && GRAPH_OVERRIDE=1
ROOT="$ROOT" ENABLED="$ENABLED" COMMAND="$COMMAND" \
EGREGORE_GRAPH_PROJECTION="$GRAPH_OVERRIDE" PYTHONSAFEPATH=1 PYTHONPATH="$RUNTIME_PYTHONPATH" \
python3 - <<'PY'
import json
import os
from pathlib import Path

from egregore_runtime.graph import graph_projection

projection = graph_projection(
    Path(os.environ["ROOT"]), enabled=os.environ["ENABLED"] == "true"
)
command = os.environ["COMMAND"]
health = projection.rebuild() if command == "rebuild" else projection.verify()
print(json.dumps(health.to_dict(), sort_keys=True))
PY
