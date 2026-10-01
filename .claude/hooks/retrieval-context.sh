#!/usr/bin/env bash
# Thin native PostToolUse adapter. Runtime owns packet identity and validation.
set -u
ROOT="${EGREGORE_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}}"
EGREGORE_ROOT="$ROOT" PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m egregore_runtime.harness_cli result-hook --harness claude
