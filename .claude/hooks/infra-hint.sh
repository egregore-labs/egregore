#!/usr/bin/env bash
# infra-hint.sh — PreToolUse hook for infrastructure command awareness
# When infra-related CLI commands are detected, inject a system hint
# about the service registry.
# No jq, no network, always exit 0. Advisory only — never blocks.

# No set -e — must never accidentally block
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Guard: if project dir no longer exists (worktree deleted), exit silently
if [ ! -d "$PROJECT_DIR" ]; then
  exit 0
fi

# Read tool input from stdin
INPUT=$(cat 2>/dev/null) || exit 0

# Extract tool_name (no jq — saves ~15ms)
TOOL=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/')

# Only care about Bash
if [ "$TOOL" != "Bash" ]; then
  exit 0
fi

# Extract command
CMD=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/')

if [ -z "$CMD" ]; then
  exit 0
fi

# Check for infra-related commands
if ! echo "$CMD" | grep -qiE '(^|\s|/)(netlify|vercel|railway|supabase|fly\s|heroku|render\s|docker\s+(push|build|tag)|kubectl|helm)\b' 2>/dev/null; then
  exit 0
fi

# Rate limit: only hint once per session
SESSION_ID=""
SID_FILE="$PROJECT_DIR/.egregore-session-id"
if [ -f "$SID_FILE" ]; then
  SESSION_ID=$(cat "$SID_FILE" 2>/dev/null) || true
fi

HINT_FLAG="/tmp/egregore-infra-hint-${SESSION_ID:-default}"
if [ -f "$HINT_FLAG" ]; then
  exit 0
fi
touch "$HINT_FLAG" 2>/dev/null

# Check if registry exists and hint accordingly
REGISTRY="$PROJECT_DIR/memory/infrastructure/services.yml"
if [ -f "$REGISTRY" ]; then
  printf '{"continue":true,"systemMessage":"Tip: This org has a service registry at memory/infrastructure/services.yml. Run /infra to see registered services and their URLs/names before guessing."}\n'
else
  printf '{"continue":true,"systemMessage":"Tip: Run /infra add to register infrastructure services so other sessions can find them."}\n'
fi

exit 0
