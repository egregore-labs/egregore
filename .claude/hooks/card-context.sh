#!/usr/bin/env bash
# After a deterministic card renderer runs, attach only a compact hidden
# marker: the card is already fully visible as the command's stdout, and the
# assistant must not repeat it. The card bytes are never attached — the
# renderer's output is the single product surface, visible the moment
# rendering finishes.

set -u

INPUT=$(cat 2>/dev/null) || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL" = "Bash" ] || exit 0
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Contiguous invocation phrases only: a command merely mentioning these
# scripts (a grep, a test, an editor call) must not trigger the marker.
SURFACE=""
case "$COMMAND" in
  *"codex-skill-render.mjs activity-card"*) SURFACE="Activity" ;;
  *"codex-skill-render.mjs dashboard-card"*) SURFACE="Dashboard" ;;
  *"bin/handoff-preview.sh approve"*) SURFACE="Handoff result" ;;
  *"bin/agent.sh wrap"*) SURFACE="Wrap result" ;;
esac
[ -n "$SURFACE" ] || exit 0

jq -n --arg surface "$SURFACE" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: (
      "EGREGORE_CARD_DISPLAYED_V1: the " + $surface + " card is already fully "
      + "visible as the tool output above — deterministic renderer stdout, "
      + "action numbers included. Do not copy, re-render, summarize, or repeat "
      + "any part of it. The card itself addresses the user; reply only with "
      + "what the user separately asked for, or nothing."
    )
  }
}'
exit 0
