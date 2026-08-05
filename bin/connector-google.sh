#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONNECTOR_DIR="$SCRIPT_DIR/bin/connector-google"
# First run on a fresh checkout: the local TS source needs its dependencies
# (googleapis, open) before tsx can execute it.
if [ ! -d "$CONNECTOR_DIR/node_modules" ]; then
  echo "First run — installing Google connector dependencies (one time)..." >&2
  npm install --prefix "$CONNECTOR_DIR" --no-fund --no-audit --loglevel=error >&2
fi
exec npx --yes tsx "$CONNECTOR_DIR/src/index.ts" "$@"
