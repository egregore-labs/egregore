#!/usr/bin/env bash
# Runtime-neutral shell adapter for canonical asynchronous questions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export EGREGORE_ROOT="${EGREGORE_ROOT:-$ROOT}"
export PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
exec python3 -m egregore_runtime.question_cli "$@"
