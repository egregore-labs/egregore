#!/usr/bin/env bash
# boundary-hook.sh — runtime-neutral PreToolUse entry for the instance wall.
# Usage: boundary-hook.sh claude|codex   (hook JSON on stdin)
# Claude Code reaches it through .claude/hooks/boundary-check.sh, Codex
# through .codex/hooks.json. The policy lives in bin/boundary-guard.cjs; this
# file only starts it and keeps the exit contract: 0 allows, 2 blocks with the
# reason on stderr. A hook host treats any other status as a non-blocking
# error, so every failure to start or finish the check becomes a denial here.

deny() {
  echo "Environment isolation: the boundary check could not run ($1), so this action is blocked. Ask the user to install Node 22 or run /update, then restart the session." >&2
  exit 2
}

missing() {
  echo "Environment isolation: boundary guard missing ($1) — run /update, then restart the session. Every action is blocked until the guard is back." >&2
  exit 2
}

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || deny "its directory cannot be resolved"
ROOT="$(dirname "$BIN_DIR")"
GUARD="$BIN_DIR/boundary-guard.cjs"
case "${1:-claude}" in
  codex) PROJECT_DIR="${EGREGORE_CODEX_PROJECT_DIR:-$ROOT}" ;;
  *) PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$ROOT}" ;;
esac
[ -f "$GUARD" ] || missing "bin/boundary-guard.cjs"

NODE_BIN="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE_BIN" ] && [ -f "$BIN_DIR/node-run.sh" ]; then
  NODE_BIN="$(bash "$BIN_DIR/node-run.sh" -e 'process.stdout.write(process.execPath)' 2>/dev/null || true)"
fi
[ -n "$NODE_BIN" ] || deny "Node is missing"

# The check runs with no inherited Node options: a preload cannot replace it.
env -u NODE_OPTIONS "$NODE_BIN" "$GUARD" --project-dir "$PROJECT_DIR"
status=$?
case "$status" in
  0|2) exit "$status" ;;
  *) deny "it exited with status $status" ;;
esac
