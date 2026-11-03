#!/usr/bin/env bash
set -uo pipefail

# Test: Claude Code's own runtime dirs stay inside the boundary when they do
# not live at a literal ~/.claude. Both enforcement layers resolve targets with
# realpath, so a symlinked ~/.claude (e.g. -> a state volume), a
# CLAUDE_CONFIG_DIR elsewhere, or the per-user scratch dir under TMPDIR
# (background task output, persisted tool results) was refused as outside the
# boundary. Unrelated paths outside the boundary must still be refused.
# Exercises: .claude/hooks/boundary-check.sh and bin/boundary.sh check.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$SCRIPT_DIR/.claude/hooks/boundary-check.sh"
BOUNDARY_SH="$SCRIPT_DIR/bin/boundary.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: Claude runtime dirs (symlinked config, CLAUDE_CONFIG_DIR, TMPDIR scratch)"
echo ""

# Fixture under $HOME, not /tmp or /private/var: both are system-allowed and
# would mask the refusals under test. The project sits two levels down so the
# sibling-repo allowance (the project's parent) does not cover the fixture.
T="$(mktemp -d "${HOME}/egregore-boundary-runtime-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
UID_N="$(id -u)"
FAKE_HOME="$T/home"
STATE="$T/state/claude"
CFG="$T/cfg/claude"
SCRATCH="$T/scratch"
PROJ="$T/work/proj"
mkdir -p "$FAKE_HOME" "$STATE/projects/p/memory" "$CFG/projects/p/memory" \
         "$SCRATCH/claude-$UID_N/tasks" "$PROJ" "$T/elsewhere" "$T/denied/claude"
ln -s "$STATE" "$FAKE_HOME/.claude"

HOOK_HASH=$(echo -n "$PROJ" | md5 2>/dev/null || echo -n "$PROJ" | md5sum 2>/dev/null | cut -d' ' -f1)
HOOK_FILE="/tmp/egregore-boundary-${HOOK_HASH}.json"
SH_HASH=$(echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)
SH_FILE="/tmp/egregore-boundary-${SH_HASH}.json"
SH_BACKUP=""
if [ -f "$SH_FILE" ]; then SH_BACKUP="$T/sh-boundary.bak"; cp "$SH_FILE" "$SH_BACKUP"; fi

cleanup() {
  rm -f "$HOOK_FILE"
  if [ -n "$SH_BACKUP" ]; then cp "$SH_BACKUP" "$SH_FILE"; else rm -f "$SH_FILE"; fi
  rm -rf "$T"
}
trap cleanup EXIT

for f in "$HOOK_FILE" "$SH_FILE"; do
  cat > "$f" <<EOF
{"project_dir": "$PROJ", "memory_dir": "", "posture": "standard", "locked": false,
 "read_roots": [], "managed_repos": [], "denied_paths": ["$T/denied"]}
EOF
done

# hook <tool> <path> [extra env...] -> exit code
hook() {
  local tool="$1" path="$2"; shift 2
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool" "$path" \
    | env HOME="$FAKE_HOME" TMPDIR="$SCRATCH" CLAUDE_PROJECT_DIR="$PROJ" "$@" bash "$HOOK" >/dev/null 2>&1
  echo $?
}
# sh <path> [extra env...] -> exit code
sh_check() {
  local path="$1"; shift
  env HOME="$FAKE_HOME" TMPDIR="$SCRATCH" "$@" bash "$BOUNDARY_SH" check "$path" >/dev/null 2>&1
  echo $?
}

echo "— hook (.claude/hooks/boundary-check.sh) —"
[ "$(hook Write "$STATE/projects/p/memory/a.md")" = 0 ] \
  && pass "write to symlinked ~/.claude target allowed" || fail "symlinked ~/.claude target refused"
[ "$(hook Write "$FAKE_HOME/.claude/projects/p/memory/a.md")" = 0 ] \
  && pass "write via the ~/.claude symlink allowed" || fail "write via ~/.claude symlink refused"
[ "$(hook Read "$SCRATCH/claude-$UID_N/tasks/b.output")" = 0 ] \
  && pass "read of TMPDIR claude scratch allowed" || fail "TMPDIR claude scratch refused"
[ "$(hook Write "$CFG/projects/p/memory/a.md" CLAUDE_CONFIG_DIR="$CFG")" = 0 ] \
  && pass "write under CLAUDE_CONFIG_DIR allowed" || fail "CLAUDE_CONFIG_DIR refused"
[ "$(hook Write "$CFG/projects/p/memory/a.md")" = 2 ] \
  && pass "same dir refused when it is not CLAUDE_CONFIG_DIR" || fail "unrelated config dir allowed"
[ "$(hook Write "$T/elsewhere/c.md")" = 2 ] \
  && pass "unrelated path outside the boundary still refused" || fail "unrelated path allowed"
[ "$(hook Read "$SCRATCH/other/d.txt")" = 2 ] \
  && pass "TMPDIR outside claude-<uid> still refused" || fail "TMPDIR sibling allowed"
[ "$(hook Write "$T/denied/claude/x.md" CLAUDE_CONFIG_DIR="$T/denied/claude")" = 2 ] \
  && pass "CLAUDE_CONFIG_DIR inside another instance stays denied" || fail "denied instance reachable via CLAUDE_CONFIG_DIR"

echo ""
echo "— bin/boundary.sh check —"
[ "$(sh_check "$STATE/projects/p/memory/a.md")" = 0 ] \
  && pass "symlinked ~/.claude target allowed" || fail "symlinked ~/.claude target refused"
[ "$(sh_check "$SCRATCH/claude-$UID_N/tasks/b.output")" = 0 ] \
  && pass "TMPDIR claude scratch allowed" || fail "TMPDIR claude scratch refused"
[ "$(sh_check "$CFG/projects/p/memory/a.md" CLAUDE_CONFIG_DIR="$CFG")" = 0 ] \
  && pass "CLAUDE_CONFIG_DIR allowed" || fail "CLAUDE_CONFIG_DIR refused"
[ "$(sh_check "$T/elsewhere/c.md")" = 1 ] \
  && pass "unrelated path outside the boundary still refused" || fail "unrelated path allowed"
[ "$(sh_check "$T/denied/claude/x.md" CLAUDE_CONFIG_DIR="$T/denied/claude")" = 1 ] \
  && pass "CLAUDE_CONFIG_DIR inside another instance stays denied" || fail "denied instance reachable via CLAUDE_CONFIG_DIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
