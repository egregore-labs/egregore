#!/bin/bash
# Tests for .claude/hooks/memory-read-guard.sh
#
# The guard blocks raw dumps of memory files (cat/sed/head/tail/… applied to a
# memory/ path) during a fresh retrieval episode, and must let everything else
# through — in particular listings that happen to be trimmed by a reader
# (`ls memory/x | tail -5`), which exposed only filenames and were blocked
# before 2026-09-10.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/.claude/hooks/memory-read-guard.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== memory-read-guard.sh tests ==="

# --- Fixture: a project dir with a session id and a fresh retrieval episode ---
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PROJECT="$WORK/project"
MEMREAL="$WORK/memory-repo"
mkdir -p "$PROJECT" "$MEMREAL/meetings" "$MEMREAL/quests"
printf '# fixture\n' > "$MEMREAL/quests/evrim.md"
ln -s "$MEMREAL" "$PROJECT/memory"   # memory is a symlink to the sibling repo, as in production
SESSION="test-session-$$"
printf '%s' "$SESSION" > "$PROJECT/.egregore-session-id"
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR/egregore-retrieval-context"
touch "$TMPDIR/egregore-retrieval-context/$SESSION.episode"
export CLAUDE_PROJECT_DIR="$PROJECT"

run_bash() {
  # $1 = command string; returns the hook's exit code
  jq -cn --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}' \
    | bash "$HOOK" >/dev/null 2>&1
}
run_tool() {
  # $1 = tool name, $2 = file_path; returns the hook's exit code
  jq -cn --arg t "$1" --arg f "$2" '{tool_name: $t, tool_input: {file_path: $f}}' \
    | bash "$HOOK" >/dev/null 2>&1
}

expect_block() {
  if run_bash "$1"; then fail "should block: $1"; else pass "blocks: $1"; fi
}
expect_allow() {
  if run_bash "$1"; then pass "allows: $1"; else fail "should allow: $1"; fi
}
expect_tool_block() {
  if run_tool "$1" "$2"; then fail "should block $1 on $2"; else pass "blocks $1 on $2"; fi
}
expect_tool_allow() {
  if run_tool "$1" "$2"; then pass "allows $1 on $2"; else fail "should allow $1 on $2"; fi
}

# --- Dumps of a memory file: blocked ---
expect_block 'cat memory/quests/evrim.md'
expect_block 'sed -n 1,140p memory/knowledge/decisions/x.md'
expect_block 'head -50 memory/handoffs/index.md | grep foo'
expect_block 'grep -l foo memory/ ; cat memory/people/cem.md'
expect_block 'awk "{print}" memory/people/cem.md'
expect_block 'echo "$(sed -n 1p memory/x.md)"'
expect_block 'for f in memory/handoffs/*.md; do cat "$f"; done'
expect_block 'find memory/meetings -name "*.md" | xargs cat'
expect_block 'find memory/meetings -name "*.md" -exec head -5 {} \;'
expect_block 'find memory/meetings -name "*.md" | xargs -I{} sed -n 1,5p {}'

# --- Listings trimmed by a reader: allowed (filenames, not content) ---
expect_allow 'ls memory/meetings/ | tail -15'
expect_allow 'find memory/meetings -maxdepth 1 -type f -name "2026-09*" | sort | tail -12'
expect_allow 'ls -la memory/handoffs | head -20'
expect_allow 'ls memory/ | awk "{print \$1}"'

# --- Searching and non-reader work on memory: allowed ---
expect_allow 'grep -rn "beyanname" memory/knowledge | head -5'
expect_allow 'grep -oE "memory/[a-z/.-]+" file.txt | head -1'
expect_allow 'ls memory/quests'
expect_allow 'wc -l memory/handoffs/index.md'
expect_allow 'bash bin/search.sh open memory/quests/evrim.md --context-packet'

# --- Readers on non-memory paths while a memory path is elsewhere: allowed ---
expect_allow 'ls memory/ ; cat README.md'
expect_allow 'cat README.md | grep memory/handoffs'

# --- git printing a memory blob: blocked; git metadata on memory: allowed ---
expect_block 'git show HEAD:memory/handoffs/index.md'
expect_block 'git show origin/main:memory/quests/evrim.md | head -40'
expect_block 'git -C /repo cat-file -p HEAD:memory/people/cem.md'
expect_allow 'git log --oneline -5 -- memory/handoffs/index.md'
expect_allow 'git status --short memory/'

# --- No memory path at all: allowed ---
expect_allow 'cat bin/search.sh | head -20'

# --- Read tool: memory paths blocked in every spelling, other files allowed ---
expect_tool_block Read 'memory/quests/evrim.md'
expect_tool_block Read "$PROJECT/memory/quests/evrim.md"
expect_tool_block Read "$MEMREAL/quests/evrim.md"
expect_tool_block Read "$MEMREAL/quests/../quests/evrim.md"
expect_tool_block Read "$MEMREAL/quests/not-yet-written.md"
expect_tool_allow Read "$PROJECT/bin/search.sh"
expect_tool_allow Read 'docs/memory-model.md'

# --- Other tools are never the guard's business ---
expect_tool_allow Edit 'memory/knowledge/decisions/x.md'
expect_tool_allow Write "$MEMREAL/handoffs/new.md"

# --- Malformed input must fall through to allow, never crash-block ---
if printf 'not json' | bash "$HOOK" >/dev/null 2>&1; then pass "malformed input allows"; else fail "malformed input blocked"; fi
if printf '' | bash "$HOOK" >/dev/null 2>&1; then pass "empty input allows"; else fail "empty input blocked"; fi
if jq -cn '{tool_name: "Bash", tool_input: {}}' | bash "$HOOK" >/dev/null 2>&1; then pass "missing command allows"; else fail "missing command blocked"; fi

# --- Block reason names the file to open through the packet ---
REASON=$(jq -cn '{tool_name: "Bash", tool_input: {command: "cat memory/quests/evrim.md"}}' | bash "$HOOK" 2>&1 >/dev/null)
grep -q 'bin/search.sh open memory/quests/evrim.md --context-packet' <<< "$REASON" \
  && pass "block reason names the exact packet command" || fail "block reason lacks the packet command" "$REASON"

# --- Stale episode (older than the window): everything allowed ---
touch -t 202001010000 "$TMPDIR/egregore-retrieval-context/$SESSION.episode"
expect_allow 'cat memory/quests/evrim.md'
touch "$TMPDIR/egregore-retrieval-context/$SESSION.episode"
expect_block 'cat memory/quests/evrim.md'

# --- No session id: everything allowed ---
rm -f "$PROJECT/.egregore-session-id"
expect_allow 'cat memory/quests/evrim.md'
printf '%s' "$SESSION" > "$PROJECT/.egregore-session-id"

# --- Outside a retrieval episode: everything allowed ---
rm -f "$TMPDIR/egregore-retrieval-context/$SESSION.episode"
expect_allow 'cat memory/quests/evrim.md'

# --- Native prompt state works without a shared launcher marker or packet ---
NATIVE_SESSION="native-guard-fixture"
EPISODE="ep_0123456789abcdef0123456789abcdef"
BINDING_KEY=$(printf 'claude:%s' "$NATIVE_SESSION" | shasum -a 256 | cut -d' ' -f1)
STATE_KEY=$(printf '%s' "$EPISODE" | shasum -a 256 | cut -d' ' -f1)
mkdir -p "$PROJECT/.egregore/runtime/bindings" "$PROJECT/.egregore/runtime/investigations"
jq -cn --arg ep "$EPISODE" '{episode_id:$ep}' > "$PROJECT/.egregore/runtime/bindings/$BINDING_KEY.current"
printf '{}' > "$PROJECT/.egregore/runtime/investigations/$STATE_KEY.json"
rm -f "$PROJECT/.egregore-session-id"
REASON=$(jq -cn --arg session "$NATIVE_SESSION" '{session_id:$session,tool_name:"Bash",tool_input:{command:"cat memory/quests/evrim.md"}}' | bash "$HOOK" 2>&1 >/dev/null)
grep -q -- "--episode $EPISODE" <<< "$REASON" && pass "native state guards reads with exact reference" || fail "native state did not guard read"
if jq -cn '{session_id:"other-session",tool_name:"Bash",tool_input:{command:"cat memory/quests/evrim.md"}}' | bash "$HOOK" >/dev/null 2>&1; then
  pass "another native session has no active episode"
else
  fail "native session guard leaked across sessions"
fi

echo ""
echo "memory-read-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
