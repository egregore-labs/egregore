#!/usr/bin/env bash
# Attach actor identity and retrieval guidance for harness UserPromptSubmit hooks.
# Input: the harness hook JSON on stdin. Output: a hook additionalContext JSON
# envelope. No organizational evidence is retrieved before the model runs.

set -u

ROOT="${EGREGORE_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}}"
HARNESS="${1:-shell}"

EGREGORE_ROOT="$ROOT" \
EGREGORE_RUNTIME="$HARNESS" \
PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m egregore_runtime.harness_cli prompt-hook --harness "$HARNESS" || true
