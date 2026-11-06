#!/usr/bin/env bash
# Instance-wall parity across Claude Code, Codex, Pi and Prime: one fixture
# table through every adapter of bin/boundary-guard.cjs. The table and its
# runner live in tests/test-boundary-parity.mjs; this entry point puts it in
# the shell-suite baseline.
# Usage: bash tests/test-boundary-parity.sh
set -euo pipefail
exec node --no-warnings "$(cd "$(dirname "$0")" && pwd)/test-boundary-parity.mjs"
