#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 PYTHONSAFEPATH=1 PYTHONPATH="$ROOT" python3 -c 'from egregore_runtime.spirit_discovery_cli import main; raise SystemExit(main(runtime="prime"))' "$@"
