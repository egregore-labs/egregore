#!/bin/bash
# SubagentStart hook — injects compact organizational context into subagents.
# Reads pre-cached context from session-start.sh. Falls back to minimal info.
# No network calls, no graph queries. Always exit 0.

# No set -e — must never block by crashing
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# --- Read session ID ---
SESSION_ID=""
SID_FILE="$PROJECT_DIR/.egregore-session-id"
if [ -f "$SID_FILE" ]; then
  SESSION_ID=$(cat "$SID_FILE" 2>/dev/null) || true
fi

# --- Try cached context first (written by session-start.sh) ---
if [ -n "$SESSION_ID" ]; then
  CTX_FILE="/tmp/egregore-subagent-ctx-${SESSION_ID}.txt"
  if [ -f "$CTX_FILE" ]; then
    cat "$CTX_FILE" 2>/dev/null
    exit 0
  fi
fi

# --- Fallback: minimal context from local files ---
ORG_NAME=""
GITHUB_ORG=""
if [ -f "$PROJECT_DIR/egregore.json" ]; then
  ORG_NAME=$(grep -o '"org_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$PROJECT_DIR/egregore.json" | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/')
  GITHUB_ORG=$(grep -o '"github_org"[[:space:]]*:[[:space:]]*"[^"]*"' "$PROJECT_DIR/egregore.json" | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/')
fi

BRANCH=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "unknown")

cat << EOF
<!-- egregore-context
Organization: ${ORG_NAME:-Unknown} (github: ${GITHUB_ORG:-unknown})
Branch: $BRANCH
Memory: memory/ is a symlink to shared knowledge base. Use bin/graph.sh for Neo4j queries.
-->
EOF

exit 0
