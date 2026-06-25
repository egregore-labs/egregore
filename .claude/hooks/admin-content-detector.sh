#!/bin/bash
# admin-content-detector.sh — PostToolUse hook for sensitive-content detection.
#
# Fires after Edit/Write to memory/**/*.md. If the file matches sensitive
# keywords (fundraising, legal, personnel, strategic) AND is NOT already
# marked admin-only, prints a hint to the agent so it can confirm with the
# user via AskUserQuestion.
#
# Soft layer — never blocks. Always exits 0. Hint goes to stdout (the agent
# sees it as part of the tool result).

# No set -e — must never accidentally crash the tool flow.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

if [ ! -d "$PROJECT_DIR" ]; then
  exit 0
fi

# --- Read tool input from stdin (JSON) ---
INPUT=$(cat 2>/dev/null) || exit 0

# Tool name (Edit, Write, NotebookEdit) — extract without jq for speed.
TOOL=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/')
case "$TOOL" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

# File path
PATH_VALUE=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/')
[ -n "$PATH_VALUE" ] || exit 0

# Resolve to absolute, then check it's under memory/ and ends in .md
case "$PATH_VALUE" in
  /*) ABS_PATH="$PATH_VALUE" ;;
  *)  ABS_PATH="$PROJECT_DIR/$PATH_VALUE" ;;
esac
[ -f "$ABS_PATH" ] || exit 0

# Restrict scope to memory/**/*.md (handoffs, notes, knowledge, quests, etc.)
case "$ABS_PATH" in
  *"/memory/"*.md) ;;
  *) exit 0 ;;
esac

# Whitelist synthesis areas where incidental keyword matches are expected.
# Canvas files aggregate product/feature text and routinely mention fundraising,
# investors, etc. as topics, not as sensitive content. Re-prompting on every
# canvas edit is pure noise.
case "$ABS_PATH" in
  *"/memory/knowledge/canvas/"*) exit 0 ;;
esac

# --- Source helpers ---
# shellcheck source=../../bin/lib/permissions.sh
. "$PROJECT_DIR/bin/lib/permissions.sh" 2>/dev/null || exit 0

# Admin status already decided (admin: true OR admin: false)? Nothing to do.
# An explicit `admin: false` means the user reviewed and chose public — don't
# re-prompt on subsequent edits.
if _has_admin_decision "$ABS_PATH"; then
  exit 0
fi

# Sensitive keywords present?
if _looks_sensitive "$ABS_PATH"; then
  REL_PATH="${ABS_PATH#$PROJECT_DIR/}"

  # Surface guidance to the agent via Claude Code's PostToolUse output protocol:
  # stdout JSON with hookSpecificOutput.additionalContext reaches the model.
  # (stderr is shown to the user but not to the agent. Plain stdout text is
  # swallowed.) jq -Rs reads the whole heredoc as a single JSON string,
  # handling escaping for newlines, quotes, and special chars automatically.
  cat <<EOF | jq -Rsc '{ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: . } }'
admin-content-detector: $REL_PATH matches sensitive keywords [fundraising / legal / personnel] but is not marked admin-only.

Call AskUserQuestion now to confirm with the user:
  question: "$REL_PATH mentions sensitive content. Mark admin-only?"
  header:   "Admin flag"
  options:
    - "Yes, mark admin-only"     -> Edit the file to add 'admin: true' to frontmatter
    - "No, it's actually public" -> Edit the file to add 'admin: false' to frontmatter
    - "Cancel"                   -> don't touch it

Both Yes and No write the frontmatter — the explicit value is what stops this
hook from re-firing on the next edit. "Cancel" leaves no record, so the hook
will ask again later.

Frontmatter target (use whichever the user picked):
  ---
  admin: true   # or: admin: false
  ---

Helpers: bin/lib/permissions.sh (_is_admin_only_file, _has_admin_decision, _looks_sensitive).
EOF
fi

exit 0
