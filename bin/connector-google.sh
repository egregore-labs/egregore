#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec npx --yes tsx "$SCRIPT_DIR/bin/connector-google/src/index.ts" "$@"
