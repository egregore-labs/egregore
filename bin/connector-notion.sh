#!/usr/bin/env bash
# Notion connector CLI — wrapper delegating to TypeScript implementation.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/connector-notion"
LOCAL_TSX="$PKG_DIR/node_modules/.bin/tsx"
if [ -x "$LOCAL_TSX" ]; then
  exec "$LOCAL_TSX" "$PKG_DIR/src/index.ts" "$@"
fi
echo "First run: fetching the TypeScript runner (one-time, ~30s)..." >&2
exec npx --yes tsx "$PKG_DIR/src/index.ts" "$@"
