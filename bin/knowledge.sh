#!/usr/bin/env bash
# Stable harness adapter for shared knowledge capture and private notes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export EGREGORE_ROOT="${EGREGORE_ROOT:-$ROOT}"
export EGREGORE_SESSION_ID="${EGREGORE_SESSION_ID:-$(cat "$ROOT/.egregore-session-id" 2>/dev/null || true)}"
export PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"

exec python3 -m egregore_runtime.knowledge_cli "$@"
