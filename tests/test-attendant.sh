#!/bin/bash
# Smoke test for bin/attendant.sh — ripcord + auto-push reflexes against a
# scratch instance with a fake Claude transcript. No network, no real memory.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d -t egregore-attendant-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
FAIL=0

check() { # check <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  ✓ $desc"; else echo "  ✗ $desc"; FAIL=1; fi
}

# --- Scratch instance -------------------------------------------------------
INST="$TMP/instance"
mkdir -p "$INST/bin" "$INST/memory/handoffs"
cp "$REPO_DIR/bin/attendant.sh" "$INST/bin/attendant.sh"
echo '{"slug":"testorg","features":{"attendant":true}}' > "$INST/egregore.json"
echo "memory/" > "$INST/.gitignore"   # memory is a symlink in real instances — never tracked

git -C "$INST" init -q -b develop
git -C "$INST" -c user.email=t@t -c user.name=test add -A
git -C "$INST" -c user.email=t@t -c user.name=test commit -qm init
git -C "$INST" checkout -qb dev/test/widget-fix

git -C "$INST/memory" init -q -b main
git -C "$INST/memory" -c user.email=t@t -c user.name=test commit -qm init --allow-empty

# --- Fake transcript (stale, >20KB, with user prompts) -----------------------
PROJ_KEY=$(echo -n "$INST" | sed 's|[^A-Za-z0-9]|-|g')
TDIR="$TMP/claude-projects/$PROJ_KEY"
mkdir -p "$TDIR"
T="$TDIR/sess-ripcord-test.jsonl"
{
  echo '{"type":"user","message":{"content":"fix the widget rendering bug"}}'
  echo '{"type":"user","message":{"content":[{"type":"text","text":"also add a test for the empty state"}]}}'
  for i in $(seq 1 400); do echo '{"type":"assistant","message":{"content":"padding line to exceed the size threshold '"$i"'"}}'; done
} > "$T"
touch -t "$(date -v-30M '+%Y%m%d%H%M' 2>/dev/null || date -d '30 minutes ago' '+%Y%m%d%H%M')" "$T"

# --- Stale dirty file on the dev branch --------------------------------------
echo "wip" > "$INST/widget.txt"
touch -t "$(date -v-30M '+%Y%m%d%H%M' 2>/dev/null || date -d '30 minutes ago' '+%Y%m%d%H%M')" "$INST/widget.txt"

run_sweep() {
  CLAUDE_PROJECTS_DIR="$TMP/claude-projects" \
  ATTENDANT_HOME="$TMP/state" \
  EGREGORE_MEMORY_DIR="$INST/memory" \
  GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@t \
  bash "$INST/bin/attendant.sh" sweep
}

echo "attendant smoke:"

# 1. Sweep on a dead session pulls the ripcord
run_sweep
RIPCORD=$(find "$INST/memory/handoffs" -name '*-ripcord-*.md' | head -1)
check "ripcord handoff created" test -n "$RIPCORD"
check "ripcord carries kind: ripcord" grep -q '^kind: ripcord' "$RIPCORD"
check "ripcord captured user prompts" grep -q 'widget rendering bug' "$RIPCORD"
check "ripcord captured branch state" grep -q 'dev/test/widget-fix' "$RIPCORD"
check "memory committed" bash -c "git -C '$INST/memory' log --oneline | grep -q Ripcord"

# 2. Auto-commit of the stale dirty dev branch
check "dirty dev branch auto-committed" bash -c "git -C '$INST' log --oneline -1 | grep -q 'ripcord auto-save'"
check "working tree clean after auto-save" bash -c "test -z \"\$(git -C '$INST' status --porcelain)\""

# 3. Second sweep is a no-op (journal dedupe)
MEM_COMMITS_BEFORE=$(git -C "$INST/memory" rev-list --count HEAD)
run_sweep
MEM_COMMITS_AFTER=$(git -C "$INST/memory" rev-list --count HEAD)
check "second sweep creates no duplicate" test "$MEM_COMMITS_BEFORE" = "$MEM_COMMITS_AFTER"

# 4. Active session = attendant stands by
T2="$TDIR/sess-active-test.jsonl"
cp "$T" "$T2" && touch "$T2"   # fresh mtime = active
echo "more wip" > "$INST/widget.txt"
run_sweep
check "no commit while a session is active" bash -c "test -n \"\$(git -C '$INST' status --porcelain)\""
rm -f "$T2"

# 5. ensure restarts a daemon when the installed script changes
CLAUDE_PROJECTS_DIR="$TMP/claude-projects" ATTENDANT_HOME="$TMP/state" \
  EGREGORE_MEMORY_DIR="$INST/memory" bash "$INST/bin/attendant.sh" ensure
sleep 0.2
PIDFILE=$(find "$TMP/state" -name '*.pid' | head -1)
OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
printf '\n# version bump fixture\n' >> "$INST/bin/attendant.sh"
CLAUDE_PROJECTS_DIR="$TMP/claude-projects" ATTENDANT_HOME="$TMP/state" \
  EGREGORE_MEMORY_DIR="$INST/memory" bash "$INST/bin/attendant.sh" ensure
sleep 0.2
NEW_PID=$(cat "$PIDFILE" 2>/dev/null)
check "ensure restarts outdated attendant" test -n "$NEW_PID" -a "$NEW_PID" != "$OLD_PID"
CLAUDE_PROJECTS_DIR="$TMP/claude-projects" ATTENDANT_HOME="$TMP/state" \
  bash "$INST/bin/attendant.sh" stop >/dev/null 2>&1 || true

# 6. Kill switch
echo '{"slug":"testorg","features":{"attendant":false}}' > "$INST/egregore.json"
CLAUDE_PROJECTS_DIR="$TMP/claude-projects" ATTENDANT_HOME="$TMP/state" \
  bash "$INST/bin/attendant.sh" ensure
check "ensure respects features.attendant=false" test ! -f "$TMP/state/"*.pid

if [ "$FAIL" = "0" ]; then echo "attendant smoke: ok"; else echo "attendant smoke: FAILED"; exit 1; fi
