#!/bin/bash
# emissary-detect.sh — UserPromptSubmit hook.
#
# When the user expresses intent to create or send an Egregore emissary
# (or pastes an emissary link), inject a soft routing hint so the model
# reliably invokes the /emissary skill instead of getting confused with
# /handoff.
#
# Advisory only — never blocks. Rate-limited to once per session.
# Always exits 0. No jq, no network.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ ! -d "$PROJECT_DIR" ] && exit 0

INPUT=$(cat 2>/dev/null) || exit 0

# Extract the prompt text. Tolerate either "prompt" or "user_prompt" keys
# and any whitespace variations. Newlines in the prompt are encoded as \n
# in JSON, so this single-line grep works.
PROMPT=$(echo "$INPUT" | grep -o '"prompt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')

[ -z "$PROMPT" ] && exit 0

# Match the patterns that should route to /emissary. Case-insensitive.
# Patterns:
#   - explicit slash: /emissary
#   - creation verbs + "emissary": make / create / compose / draft / send
#   - "let's emissary this" colloquial
#   - egregore.xyz/emissary/e/ link (run intent)
if ! echo "$PROMPT" | grep -qiE '(/emissary\b|\b(make|create|compose|draft|send|run|build)( an?| this| the)? emissary\b|\blet'\''?s (make|create|do|emissary) (an? )?emissary\b|egregore\.xyz/emissary/e/)'; then
  exit 0
fi

# Rate-limit: once per session.
SESSION_ID=""
SID_FILE="$PROJECT_DIR/.egregore-session-id"
if [ -f "$SID_FILE" ]; then
  SESSION_ID=$(cat "$SID_FILE" 2>/dev/null) || true
fi
HINT_FLAG="/tmp/egregore-emissary-hint-${SESSION_ID:-default}"
if [ -f "$HINT_FLAG" ]; then
  exit 0
fi
touch "$HINT_FLAG" 2>/dev/null

# Inject a routing hint via the UserPromptSubmit additionalContext mechanism.
# Plain text on stdout is appended to the user's prompt context; the
# structured JSON form is more explicit about provenance.
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Routing hint: the user's prompt mentions an emissary. The /emissary skill is the right entry point — it wraps `npx egregore-emissary` for compose/send and handles run intent for pasted egregore.xyz/emissary/e/ links. Do not route to /handoff for capsule work; /handoff is the team session-handoff only."}}
EOF

exit 0
