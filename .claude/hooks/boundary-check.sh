#!/usr/bin/env bash
# boundary-check.sh — Claude Code PreToolUse adapter for environment isolation.
# Receives tool input JSON on stdin. Exit 0 = allow, exit 2 = block (reason on
# stderr). The policy itself (two-tier instance wall, posture, consent) lives
# in bin/boundary-guard.cjs, shared with the Codex hook and the Pi/Prime
# tool_call gate; bin/boundary-hook.sh starts it and denies when it cannot run.
# A missing guard blocks (exit 2) rather than failing as a non-blocking error.

ROOT="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"
for file in bin/boundary-hook.sh bin/boundary-guard.cjs; do
  if [ -z "$ROOT" ] || [ ! -f "$ROOT/$file" ]; then
    echo "Environment isolation: boundary guard missing ($file) — run /update, then restart the session. Every action is blocked until the guard is back." >&2
    exit 2
  fi
done
exec bash "$ROOT/bin/boundary-hook.sh" claude
