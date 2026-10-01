#!/usr/bin/env bash
# memory-read-guard.sh — PreToolUse hook for Read and Bash.
#
# After a Runtime retrieval, memory sources are opened through the private
# evidence packet — `bash bin/search.sh open <path> --context-packet` — and
# never dumped into the transcript with cat/sed/head/tail or the Read tool.
# Instructions alone did not hold (2026-09-03: three `sed -n 1,140p` dumps of
# memory files right after a clean search), so this hook enforces it.
#
# Scope: a retrieval episode. The guard engages only while this session's
# retrieval episode is fresh (a search or open within the last
# EGREGORE_RETRIEVAL_WINDOW_MIN minutes, default 15). Outside an episode — editing a decision record, a skill
# reading memory, ordinary work — memory reads are untouched. Edit and Write
# are never the guard's business. Discovery also belongs to Runtime; this guard only detects obvious reads.
#
# Exit 0 = allow, exit 2 = block (reason on stderr). Any unexpected failure
# falls through to allow; the hook must never block by crashing.
set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ -d "$PROJECT_DIR" ] || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL" in Bash|Read) ;; *) exit 0 ;; esac

# --- Retrieval episode: current native prompt's shared Runtime state -------
WINDOW_MIN="${EGREGORE_RETRIEVAL_WINDOW_MIN:-15}"
_fresh() { [ -f "$1" ] && [ -n "$(find "$1" -mmin "-$WINDOW_MIN" 2>/dev/null)" ]; }
NATIVE_SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
EPISODE=""
if [ -n "$NATIVE_SESSION" ]; then
  BINDING_KEY=$(printf 'claude:%s' "$NATIVE_SESSION" | shasum -a 256 | cut -d' ' -f1)
  EPISODE=$(jq -r '.episode_id // empty' "$PROJECT_DIR/.egregore/runtime/bindings/$BINDING_KEY.current" 2>/dev/null)
fi
if [ -n "$EPISODE" ]; then
  STATE_KEY=$(printf '%s' "$EPISODE" | shasum -a 256 | cut -d' ' -f1)
  _fresh "$PROJECT_DIR/.egregore/runtime/investigations/$STATE_KEY.json" || exit 0
else
  # Migration compatibility for pre-binding sessions only.
  SESSION=$(cat "$PROJECT_DIR/.egregore-session-id" 2>/dev/null | tr -cd 'A-Za-z0-9_.-')
  [ -n "$SESSION" ] || exit 0
  CTX_DIR="${TMPDIR:-/tmp}/egregore-retrieval-context"
  _fresh "$CTX_DIR/$SESSION.episode" || _fresh "$CTX_DIR/$SESSION.context" || exit 0
fi

_block() {
  printf 'Egregore: memory sources are opened through the private evidence packet, not printed into the transcript.\n' >&2
  printf 'Run, one file per call:\n  bash bin/search.sh open %s --context-packet %s\n' "$1" "${EPISODE:+--episode $EPISODE}" >&2
  printf 'Use search.sh investigate for discovery and source windows; raw memory search or reads bypass Runtime.\n' >&2
  exit 2
}

if [ "$TOOL" = "Read" ]; then
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  [ -n "$FILE" ] || exit 0
  case "$FILE" in
    "$PROJECT_DIR"/memory/*) _block "memory/${FILE#"$PROJECT_DIR"/memory/}" ;;
    memory/*) _block "$FILE" ;;
  esac
  # The memory symlink's target (the sibling memory repository) counts too.
  # Compare canonical paths: a differently spelled route to the same file
  # (/var vs /private/var, `..` segments) must not slip past a literal match.
  MEM_REAL=$(readlink -f "$PROJECT_DIR/memory" 2>/dev/null || true)
  FILE_REAL=$(readlink -f "$FILE" 2>/dev/null || true)
  if [ -z "$FILE_REAL" ]; then
    # BSD readlink -f needs the file to exist; canonicalize the directory then.
    FILE_DIR=$(readlink -f "$(dirname "$FILE")" 2>/dev/null || true)
    [ -n "$FILE_DIR" ] && FILE_REAL="$FILE_DIR/$(basename "$FILE")"
  fi
  if [ -n "$MEM_REAL" ]; then
    case "$FILE" in "$MEM_REAL"/*) _block "memory/${FILE#"$MEM_REAL"/}" ;; esac
    case "$FILE_REAL" in "$MEM_REAL"/*) _block "memory/${FILE_REAL#"$MEM_REAL"/}" ;; esac
  fi
  exit 0
fi

# --- Bash: a raw reader applied to a memory path -------------------------
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$CMD" ] || exit 0
case "$CMD" in *bin/search.sh*) exit 0 ;; esac
MEM_PATH=$(printf '%s' "$CMD" | grep -oE 'memory/[A-Za-z0-9_./@:+-]+' | head -1)
[ -n "$MEM_PATH" ] || exit 0
READERS='(cat|sed|head|tail|less|more|awk|bat|nl)'
CMDPOS='(^|[;&|(][[:space:]]*|(do|then|else)[[:space:]]+)'
ARGS='([[:space:]][^|;&]*)?'
# Block only when a reader is actually applied to memory. A reader that merely
# trims a listing (`ls memory/x | tail -5`, `find memory/x | sort | head`)
# exposes filenames, not content, and passes (false positives found
# 2026-09-10). Three shapes are dumps:
#   1. a reader at a command position whose own arguments (up to the next
#      |;&) name a memory path;
#   2. a reader whose arguments carry a shell expansion that could resolve to
#      one (`cat "$f"` inside a loop over memory/) — awk is exempt here because
#      its programs are full of `$1`, and shape 1 still catches awk on a path;
#   3. a reader fed by xargs or find -exec while a memory path is in the command;
#   4. git printing a memory blob (`git show <ref>:memory/x`, `git cat-file -p`),
#      which the old rule caught only when a reader happened to follow.
if printf '%s' "$CMD" | grep -qE "${CMDPOS}${READERS}${ARGS}memory/"; then
  _block "$MEM_PATH"
fi
if printf '%s' "$CMD" | grep -qE "${CMDPOS}(cat|sed|head|tail|less|more|bat|nl)${ARGS}(\\\$|\`)"; then
  _block "$MEM_PATH"
fi
if printf '%s' "$CMD" | grep -qE "(xargs|-exec)[[:space:]]+([^|;&]*[[:space:]])?${READERS}([[:space:]]|$)"; then
  _block "$MEM_PATH"
fi
if printf '%s' "$CMD" | grep -qE "git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(show|cat-file)[^|;&]*memory/"; then
  _block "$MEM_PATH"
fi
exit 0
