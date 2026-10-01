#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export EGREGORE_ROOT="${EGREGORE_ROOT:-$ROOT}"
export PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
exec python3 -m egregore_runtime.onboarding_cli "$@"
