#!/bin/bash
# search-hint.sh — UserPromptSubmit hook.
#
# When the user's prompt is recall-shaped ("find the handoff about…",
# "did we decide…", "do we have notes on…"), inject a soft routing hint
# so the model reaches for /search (one ranked call over memory/) instead
# of improvising ls/grep/graph exploration — the muscle-memory path that
# costs five tool calls and sometimes invents graph labels.
#
# Advisory only — never blocks. Rate-limited to once per session.
# Always exits 0. No jq, no network.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ ! -d "$PROJECT_DIR" ] && exit 0

# No engine, no hint (e.g. checkout without the search feature yet).
[ -f "$PROJECT_DIR/bin/search.sh" ] || exit 0

INPUT=$(cat 2>/dev/null) || exit 0

PROMPT=$(echo "$INPUT" | grep -o '"prompt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')
[ -z "$PROMPT" ] && exit 0

# Already oriented toward search — no hint needed.
if echo "$PROMPT" | grep -qiE '(/search\b|search\.sh|\bsearch (the )?memory\b)'; then
  exit 0
fi

# Recall-shaped patterns. Case-insensitive. Three families:
#   - retrieval verbs aimed at org artifacts: find/dig up/locate + handoff/decision/notes/doc/meeting/harvest/quest
#   - org-past questions: did we decide/discuss…, do we have notes on…, what did we say about…, have we covered…
#   - current org facts whose answer lives in shared memory: our pricing/tiers/
#     plans, strategy, policy, positioning, ownership, or team decisions
if ! echo "$PROMPT" | grep -qiE '(\b(find|locate|dig up|look up|pull up)\b.*\b(handoff|decision|notes?|docs?|meeting|harvest|quest|reflection)s?\b|\bdid we (decide|discuss|agree|say|talk about|cover)\b|\bdo we have (any )?(notes?|docs?|anything|something)( on| about)?\b|\bwhat did we (decide|say|agree|discuss)\b|\bhave we (discussed|decided|covered|talked about|looked at)\b|\bnotes on\b|\bhandoff (from|about)\b|\bwho worked on\b|\bdidn.?t (someone|we) already\b|\bwas there (a|any) (handoff|decision|discussion|meeting)\b|\b(our|company|org|organization|team)\b.*\b(pricing|price|tiers?|plans?|paid|free|strategy|policy|positioning|ownership|decision)\b|\b(pricing|price|tiers?|plans?|paid|free)\b.*\b(our|company|org|organization|team)\b)'; then
  exit 0
fi

# Rate-limit: once per session.
SESSION_ID=""
SID_FILE="$PROJECT_DIR/.egregore-session-id"
if [ -f "$SID_FILE" ]; then
  SESSION_ID=$(cat "$SID_FILE" 2>/dev/null) || true
fi
HINT_FLAG="/tmp/egregore-search-hint-${SESSION_ID:-default}"
if [ -f "$HINT_FLAG" ]; then
  exit 0
fi
touch "$HINT_FLAG" 2>/dev/null

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Routing hint: this prompt asks for recall from org memory. FIRST action: `bash bin/search.sh query \"<the concept, not the literal sentence>\"` — one ranked call over all of memory/ (hybrid keyword+semantic; graph-state annotations attach automatically in connected mode). Read the top hits and cite paths. Do NOT improvise ls/grep/graph exploration first — that is the slow path, and hand-written graph queries against invented labels (e.g. :Handoff — handoffs are :Session nodes) return empty. Full spec: the /search skill."}}
EOF

exit 0
