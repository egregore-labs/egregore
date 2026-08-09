#!/usr/bin/env bash
# Integration tests for the boundary consent path — the remedy the PreToolUse
# hook prints must actually be reachable and must actually take effect.
#
# Covers three defects that were live in the framework:
#   1. The hook blocked its own remedy. Every shell command that recorded a
#      grant contained the blocked path, so the soft-tier scan blocked the fix.
#   2. Grants were read from a cache written at session start, so editing
#      .egregore-boundary.local.json mid-session did nothing until the next
#      session — the documented remedy silently no-op'd.
#   3. branch-guard blocked writes to the runtime-state files that carry the
#      grant whenever the session happened to be on a protected branch.
#
# Everything runs against a synthetic project in a temp dir. Usage:
#   bash tests/test-boundary-grant.sh
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/boundary-check.sh"
BRANCH_GUARD="$REPO_ROOT/.claude/hooks/branch-guard.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== boundary grant / refresh / branch-guard tests ==="
echo ""

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

PROJECT=$(mktemp -d)
# macOS mktemp hands back /var/folders/... which is a symlink into /private;
# the hook resolves paths, so resolve here too or every comparison misses.
PROJECT=$(cd "$PROJECT" && pwd -P)

# The "outside" paths are deliberately synthetic and never created: /tmp and
# /private are always-allowed system prefixes, so a real temp dir would test
# nothing. realpath falls through to string comparison for a path that does
# not exist, which is exactly the comparison being exercised.
FAKE_ROOT="/Users/egregore-grant-test-$$"
if [ -e "$FAKE_ROOT" ]; then
  echo "SKIP: $FAKE_ROOT exists on this machine"
  exit 0
fi
OUTSIDE="$FAKE_ROOT/outside"
OTHER_INSTANCE="$FAKE_ROOT/other-instance"

HASH=$(echo -n "$PROJECT" | md5 2>/dev/null || echo -n "$PROJECT" | md5sum 2>/dev/null | cut -d' ' -f1)
BOUNDARY_FILE="/tmp/egregore-boundary-${HASH}.json"
trap 'rm -rf "$PROJECT"; rm -f "$BOUNDARY_FILE"' EXIT

mkdir -p "$PROJECT/bin/lib" "$PROJECT/.claude/hooks"
cp "$REPO_ROOT/bin/boundary.sh" "$PROJECT/bin/boundary.sh"
cp "$REPO_ROOT/bin/lib/boundary-policy.sh" "$PROJECT/bin/lib/boundary-policy.sh"
cp "$HOOK" "$PROJECT/.claude/hooks/boundary-check.sh"
echo '{"org_name":"test","slug":"test","mode":"local"}' > "$PROJECT/egregore.json"

write_boundary() {
  jq -n --arg p "$PROJECT" --arg d "$OTHER_INSTANCE" \
    '{project_dir: $p, memory_dir: "", posture: "standard", locked: false,
      read_roots: [], write_roots: [], managed_repos: [], denied_paths: [$d]}' \
    > "$BOUNDARY_FILE"
}

# Run the hook the way Claude Code does: tool JSON on stdin, verdict as exit code.
verdict() {
  local input="$1" rc
  echo "$input" | CLAUDE_PROJECT_DIR="$PROJECT" bash "$PROJECT/.claude/hooks/boundary-check.sh" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && { echo allow; return; }
  echo "block"
}

read_input() { jq -n --arg p "$1" '{tool_name: "Read", tool_input: {file_path: $p}}'; }
write_input() { jq -n --arg p "$1" '{tool_name: "Write", tool_input: {file_path: $p}}'; }
bash_input() { jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }

expect() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"; else fail "$name — expected $want, got $got"; fi
}

# ---------------------------------------------------------------- baseline
write_boundary
expect "outside path blocked before any grant" "block" "$(verdict "$(read_input "$OUTSIDE/secret.txt")")"
expect "project path allowed" "allow" "$(verdict "$(read_input "$PROJECT/README.md")")"

# ------------------------------------- 1. the remedy command is reachable
GRANT_CMD="bash bin/boundary.sh grant $OUTSIDE"
expect "the grant command itself is not blocked" "allow" "$(verdict "$(bash_input "$GRANT_CMD")")"
expect "a chained grant command is still blocked" "block" \
  "$(verdict "$(bash_input "$GRANT_CMD && cat $OUTSIDE/secret.txt")")"

# ------------------------------------- 2. a grant takes effect immediately
if (cd "$PROJECT" && bash bin/boundary.sh grant "$OUTSIDE" >/dev/null 2>&1); then
  pass "grant exits 0"
else
  fail "grant exits 0"
fi
if grep -qxF "$OUTSIDE" "$PROJECT/.egregore-boundary-consent" 2>/dev/null; then
  pass "grant records the session consent line"
else
  fail "grant records the session consent line"
fi
expect "read allowed in the SAME session after grant" "allow" \
  "$(verdict "$(read_input "$OUTSIDE/secret.txt")")"
# A session grant is scoped to one session and covers the directory outright.
expect "session grant covers writes too" "allow" \
  "$(verdict "$(write_input "$OUTSIDE/secret.txt")")"

# -------------------------------- 3. persistent grants, and cache staleness
rm -f "$PROJECT/.egregore-boundary-consent"
write_boundary
expect "revoking the session grant restores the block" "block" \
  "$(verdict "$(read_input "$OUTSIDE/secret.txt")")"

(cd "$PROJECT" && bash bin/boundary.sh grant --always "$OUTSIDE" >/dev/null 2>&1)
if jq -e --arg d "$OUTSIDE" '.read | index($d)' "$PROJECT/.egregore-boundary.local.json" >/dev/null 2>&1; then
  pass "grant --always writes read[] to the personal layer"
else
  fail "grant --always writes read[] to the personal layer"
fi
expect "persistent grant takes effect immediately" "allow" \
  "$(verdict "$(read_input "$OUTSIDE/secret.txt")")"
# Persistent grants are split read/write — least privilege by default.
expect "persistent read grant does not permit writes" "block" \
  "$(verdict "$(write_input "$OUTSIDE/secret.txt")")"
(cd "$PROJECT" && bash bin/boundary.sh grant --always --write "$OUTSIDE" >/dev/null 2>&1)
expect "persistent --write grant permits writes" "allow" \
  "$(verdict "$(write_input "$OUTSIDE/secret.txt")")"
rm -f "$PROJECT/.egregore-boundary.local.json"
write_boundary

# Hand-edit the personal layer without going through boundary.sh, exactly as a
# user following the old instructions would. The cache is now stale; the hook
# has to notice and re-merge, or the documented remedy does nothing.
write_boundary
sleep 1
jq -n --arg d "$OUTSIDE" '{read: [$d]}' > "$PROJECT/.egregore-boundary.local.json"
expect "hand-edited personal layer is picked up mid-session" "allow" \
  "$(verdict "$(read_input "$OUTSIDE/secret.txt")")"
if jq -e --arg d "$OUTSIDE" '.read_roots | index($d)' "$BOUNDARY_FILE" >/dev/null 2>&1; then
  pass "the refreshed policy is written back to the cache"
else
  fail "the refreshed policy is written back to the cache"
fi
rm -f "$PROJECT/.egregore-boundary.local.json"

# ------------------------------------------ 4. the hard tier stays absolute
write_boundary
if (cd "$PROJECT" && bash bin/boundary.sh grant "$OTHER_INSTANCE" >/dev/null 2>&1); then
  fail "grant refuses another Egregore instance"
else
  pass "grant refuses another Egregore instance"
fi
if grep -qF "$OTHER_INSTANCE" "$PROJECT/.egregore-boundary-consent" 2>/dev/null; then
  fail "a refused grant writes nothing"
else
  pass "a refused grant writes nothing"
fi
expect "the denied instance is still blocked" "block" \
  "$(verdict "$(read_input "$OTHER_INSTANCE/CLAUDE.md")")"

# ----------------------------------------------- 5. a lock has no consent path
echo '{"org_name":"test","slug":"test","mode":"local","boundary":{"locked":true}}' \
  > "$PROJECT/egregore.json"
if (cd "$PROJECT" && bash bin/boundary.sh grant "$OUTSIDE" >/dev/null 2>&1); then
  fail "grant refuses to write while the org boundary is locked"
else
  pass "grant refuses to write while the org boundary is locked"
fi
echo '{"org_name":"test","slug":"test","mode":"local"}' > "$PROJECT/egregore.json"

# ------------------------- 6. branch-guard must not block the grant files
GIT_PROJECT=$(mktemp -d)
GIT_PROJECT=$(cd "$GIT_PROJECT" && pwd -P)
(
  cd "$GIT_PROJECT" || exit 1
  git init -q -b develop .
  printf '.egregore-boundary-consent\n.egregore-boundary.local.json\n.egregore-branch-consent\nscratch.log\n' > .gitignore
  git add .gitignore >/dev/null 2>&1
  git -c user.email=t@example.com -c user.name=t commit -qm init >/dev/null 2>&1
) || true
echo '{"display_name":"tester"}' > "$GIT_PROJECT/.egregore-state.json"

guard_verdict() {
  local path="$1" rc
  ( cd "$GIT_PROJECT" && jq -n --arg p "$path" '{tool_name: "Write", tool_input: {file_path: $p}}' \
      | CLAUDE_PROJECT_DIR="$GIT_PROJECT" bash "$BRANCH_GUARD" >/dev/null 2>&1 )
  rc=$?
  [ "$rc" -eq 0 ] && { echo allow; return; }
  echo block
}

if [ "$(cd "$GIT_PROJECT" && git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "develop" ]; then
  expect "branch-guard blocks project content on develop" "block" \
    "$(guard_verdict "$GIT_PROJECT/README.md")"
  expect "branch-guard allows .egregore-boundary-consent on develop" "allow" \
    "$(guard_verdict "$GIT_PROJECT/.egregore-boundary-consent")"
  expect "branch-guard allows .egregore-boundary.local.json on develop" "allow" \
    "$(guard_verdict "$GIT_PROJECT/.egregore-boundary.local.json")"
  expect "branch-guard allows any git-ignored file on develop" "allow" \
    "$(guard_verdict "$GIT_PROJECT/scratch.log")"
else
  echo "  SKIP: could not create a develop-branch fixture repo"
fi
rm -rf "$GIT_PROJECT"

echo ""
echo "boundary grant: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
