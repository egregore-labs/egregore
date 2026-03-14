#!/bin/bash
# PreCompact hook — fires before context compaction.
# Auto-commits unsaved work on working branches, externalizes session
# knowledge to the graph via WAL, then re-injects a richer summary
# so Claude has continuity after compaction.
set -euo pipefail

# pwd is worktree-aware; SCRIPT_DIR would resolve to main repo in worktrees.
REPO_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

BRANCH=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo "unknown")
CHANGED=$(git -C "$REPO_DIR" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
STAGED=$(git -C "$REPO_DIR" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((CHANGED + STAGED))
DEVELOP_REF=$(git -C "$REPO_DIR" rev-parse --short develop 2>/dev/null || echo 'unknown')

# --- Auto-commit checkpoint on working branches ---
# Prevents work loss if context compaction discards edit history.
# Only on working branches (dev/*, feature/*, bugfix/*), never develop/main.
COMMITTED=0
if [ "$TOTAL" -gt 0 ]; then
  case "$BRANCH" in
    dev/*|feature/*|bugfix/*)
      git -C "$REPO_DIR" add -A 2>/dev/null
      git -C "$REPO_DIR" commit -m "checkpoint: pre-compact $(date +%H:%M)" --quiet 2>/dev/null && COMMITTED=1
      # Recount after commit
      CHANGED=0
      STAGED=0
      TOTAL=0
      ;;
  esac
fi

# --- Read session ID (check worktree first, then main repo) ---
SESSION_ID=""
for SID_DIR in "$REPO_DIR" "$SCRIPT_DIR"; do
  SID_FILE="$SID_DIR/.egregore-session-id"
  if [ -f "$SID_FILE" ]; then
    SESSION_ID=$(cat "$SID_FILE" 2>/dev/null) || true
    [ -n "$SESSION_ID" ] && break
  fi
done

# --- Observation buffer summary ---
# Buffer parsing uses awk/grep (safe). Graph write uses jq (can fail).
# The graph write is wrapped in a subshell || true so jq failures never
# kill the script before CONTEXT_REINJECT output below.
OBS_COUNT=0
OBS_UNIQUE_FILES=0
OBS_TOP_FILES=""
OBS_UNIQUE_TOOLS=""
SEQ=""

if [ -n "$SESSION_ID" ]; then
  OBS_BUFFER="/tmp/egregore-obs-${SESSION_ID}.jsonl"
  if [ -f "$OBS_BUFFER" ] && [ -s "$OBS_BUFFER" ]; then
    OBS_COUNT=$(wc -l < "$OBS_BUFFER" 2>/dev/null | tr -d ' ') || OBS_COUNT=0

    # Unique tools
    OBS_UNIQUE_TOOLS=$(awk -F'"tool":"' '{print $2}' "$OBS_BUFFER" | cut -d'"' -f1 | sort -u | paste -sd', ' -) || true

    # Top 10 most-touched files (by frequency)
    OBS_TOP_FILES=$(awk -F'"path":"' '{print $2}' "$OBS_BUFFER" | cut -d'"' -f1 | sort | uniq -c | sort -rn | head -10) || true
    OBS_UNIQUE_FILES=$(echo "$OBS_TOP_FILES" | grep -c '[^ ]' 2>/dev/null || echo "0")
  fi

  # Sequence counter for multiple compactions per session
  SEQ_FILE="/tmp/egregore-compact-seq-${SESSION_ID}"
  SEQ=1
  if [ -f "$SEQ_FILE" ]; then
    SEQ=$(( $(cat "$SEQ_FILE" 2>/dev/null || echo "0") + 1 ))
  fi
  echo "$SEQ" > "$SEQ_FILE" 2>/dev/null || true
fi

# --- Write CompactSnapshot to WAL (O(1), no network) ---
# Subshell-guarded: jq failures here must not prevent CONTEXT_REINJECT.
(
  if [ -n "$SESSION_ID" ]; then
    # Build files_touched array
    FILES_JSON="[]"
    if [ -n "$OBS_TOP_FILES" ]; then
      FILES_JSON=$(echo "$OBS_TOP_FILES" | awk '{print $2}' | jq -R . 2>/dev/null | jq -s '.' 2>/dev/null || echo '[]')
    fi

    COMPACT_CYPHER="MATCH (s:Session {id: \$sid})
      MERGE (c:CompactSnapshot {session: \$sid, seq: \$seq})
      SET c.branch = \$branch, c.unsaved = \$unsaved,
          c.files_touched = \$files, c.tool_count = \$tool_count,
          c.createdAt = datetime()
      MERGE (s)-[:COMPACTED]->(c)"
    COMPACT_PARAMS=$(jq -n -c \
      --arg sid "$SESSION_ID" \
      --argjson seq "${SEQ:-1}" \
      --arg branch "$BRANCH" \
      --argjson unsaved "$TOTAL" \
      --argjson files "$FILES_JSON" \
      --argjson tool_count "${OBS_COUNT:-0}" \
      '{sid: $sid, seq: $seq, branch: $branch, unsaved: $unsaved, files: $files, tool_count: $tool_count}')

    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$COMPACT_CYPHER" "$COMPACT_PARAMS" 2>/dev/null || true
  fi
) || true

# --- Re-inject state so it survives compaction ---
echo "CONTEXT_REINJECT:"
echo "  Branch: $BRANCH"
echo "  Develop: $DEVELOP_REF"

if [ "$COMMITTED" -eq 1 ]; then
  echo "  ✓ Auto-committed checkpoint before compaction"
elif [ "$TOTAL" -gt 0 ]; then
  echo "  Unsaved changes: $TOTAL files"
fi

if [ "$OBS_COUNT" -gt 0 ]; then
  echo "  Session activity: $OBS_COUNT tool calls across $OBS_UNIQUE_FILES files"
  if [ -n "$OBS_TOP_FILES" ]; then
    echo "  Most active:"
    echo "$OBS_TOP_FILES" | head -5 | while read -r count path; do
      echo "    $path ($count)"
    done
  fi
  SEQ_DISPLAY="${SEQ:-1}"
  echo "  Compaction #$SEQ_DISPLAY — your earlier work is preserved in the graph."
fi

if [ "$TOTAL" -gt 0 ] && [ "$COMMITTED" -eq 0 ]; then
  echo ""
  echo "IMPORTANT: Tell the user they have $TOTAL unsaved changes. Suggest running /save before continuing."
fi
