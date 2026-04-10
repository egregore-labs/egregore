#!/bin/bash
# onboarding-guard.sh — PreToolUse hook that blocks work until onboarding completes
# Receives tool input JSON on stdin from Claude Code.
# Exit 0 = allow, exit 2 = block (reason on stderr).
# Must be fast (<50ms) — no network calls, just file checks.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Guard: if project dir no longer exists (worktree deleted), allow gracefully
if [ ! -d "$PROJECT_DIR" ]; then
  exit 0
fi

STATE_FILE="$PROJECT_DIR/.egregore-state.json"

# No state file = fresh install, onboarding hasn't started yet.
# session-start.sh handles this case — don't block here.
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

# Fast path: check onboarding_complete without jq (saves ~30ms)
# grep for the literal JSON key — covers both true and false
if grep -q '"onboarding_complete"[[:space:]]*:[[:space:]]*true' "$STATE_FILE" 2>/dev/null; then
  exit 0
fi

# If we get here, either onboarding_complete is false, missing, or file is corrupt.
# Distinguish: corrupt/unreadable → fail-open; explicitly false → block
if ! grep -q '"onboarding_complete"' "$STATE_FILE" 2>/dev/null; then
  # Field missing or file unreadable — fail-open
  exit 0
fi

# Onboarding incomplete — read tool info to decide whether to block
INPUT=$(cat)

# Extract tool_name without jq (saves another ~30ms)
TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' 2>/dev/null) || true

# No tool name = malformed input — fail-open
if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

# Allow Skill invocations (needed for /onboarding itself)
if [ "$TOOL_NAME" = "Skill" ]; then
  exit 0
fi

# Allow reads — information gathering doesn't need blocking
case "$TOOL_NAME" in
  Read|Glob|Grep) exit 0 ;;
esac

# Allow AskUserQuestion — onboarding uses this
if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
  exit 0
fi

# Allow ALL Bash commands during onboarding.
# The guard's purpose is to block non-onboarding Edit/Write/EnterWorktree —
# not Bash. Onboarding needs Bash freedom for VERIFY (.env reads, egregore.json
# reads, memory symlink checks), state writes (jq with escaped quotes), graph
# calls, and more. A per-command whitelist was incomplete and the regex to
# extract commands from JSON broke on escaped quotes (jq commands routinely
# contain \"). Allowing all Bash is simpler and correct — the real gatekeeping
# happens on Edit/Write/EnterWorktree below.
if [ "$TOOL_NAME" = "Bash" ]; then
  exit 0
fi

# Allow Edit/Write to onboarding-related files
if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
  FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' 2>/dev/null) || true
  case "$FILE_PATH" in
    */.egregore-state.json) exit 0 ;;
    */memory/people/*) exit 0 ;;
    */memory/handoffs/*) exit 0 ;;
    */egregore.md) exit 0 ;;
  esac
fi

# Block everything else — onboarding must complete first
echo "Onboarding incomplete — complete onboarding before starting work. Invoke /onboarding to continue." >&2
exit 2
