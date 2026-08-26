#!/usr/bin/env bash
set -uo pipefail

# Test: boundary-check.sh does not treat remote paths in ssh/scp/rsync
# commands as local out-of-boundary access, while still checking local
# paths on the same command line.
# Covers: .claude/hooks/boundary-check.sh Bash soft-tier candidate scrubbing

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$SCRIPT_DIR/.claude/hooks/boundary-check.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

if [ ! -x "$HOOK" ]; then
  echo "FATAL: hook not found or not executable at $HOOK" >&2
  exit 1
fi

echo "Testing: boundary-check.sh ssh/scp/rsync remote-path handling"
echo ""

# --- Fixture: project dir + boundary file the hook expects ---
FIXTURE_PROJECT="$(mktemp -d)"
FIXTURE_MEMORY="$(mktemp -d)"
HASH=$(echo -n "$FIXTURE_PROJECT" | md5 2>/dev/null || echo -n "$FIXTURE_PROJECT" | md5sum 2>/dev/null | cut -d' ' -f1)
BOUNDARY_FILE="/tmp/egregore-boundary-${HASH}.json"
cat > "$BOUNDARY_FILE" <<EOF
{
  "project_dir": "$FIXTURE_PROJECT",
  "memory_dir": "$FIXTURE_MEMORY",
  "managed_repos": [],
  "denied_paths": ["/tmp/egregore-other-instance"]
}
EOF
export CLAUDE_PROJECT_DIR="$FIXTURE_PROJECT"

cleanup() {
  rm -rf "$FIXTURE_PROJECT" "$FIXTURE_MEMORY" "$BOUNDARY_FILE"
}
trap cleanup EXIT

run_bash() {
  # Pipes a Bash tool call to the hook, returns "exit_code|stderr"
  local cmd="$1"
  local err rc
  err=$(jq -n --arg c "$cmd" '{"tool_name":"Bash","tool_input":{"command":$c}}' | "$HOOK" 2>&1 >/dev/null)
  rc=$?
  printf '%s|%s' "$rc" "$err"
}

# --- 1. Remote paths inside ssh commands are not local access ---
OUT=$(run_bash "ssh remote-host 'cd /Users/alice/some-repo && git pull'")
RC="${OUT%%|*}"
[ "$RC" = "0" ] && pass "ssh single-quoted remote command allowed" || fail "ssh single-quoted remote command" "expected 0, got $RC · ${OUT#*|}"

OUT=$(run_bash "ssh -p 2222 deploy@remote-host \"cat /Users/alice/notes.txt\"")
RC="${OUT%%|*}"
[ "$RC" = "0" ] && pass "ssh with options + double-quoted remote command allowed" || fail "ssh double-quoted remote command" "expected 0, got $RC · ${OUT#*|}"

OUT=$(run_bash "ssh remote-host cat /Users/alice/file.txt")
RC="${OUT%%|*}"
[ "$RC" = "0" ] && pass "ssh unquoted remote command allowed" || fail "ssh unquoted remote command" "expected 0, got $RC · ${OUT#*|}"

OUT=$(run_bash "ssh remote-host 'ls ~/projects/demo'")
RC="${OUT%%|*}"
[ "$RC" = "0" ] && pass "ssh remote tilde path allowed" || fail "ssh remote tilde path" "expected 0, got $RC · ${OUT#*|}"

# --- 2. Remote specs (scp/rsync host:/path) are not local access ---
OUT=$(run_bash "scp remote-host:/Users/alice/report.pdf /tmp/report.pdf")
RC="${OUT%%|*}"
[ "$RC" = "0" ] && pass "scp remote-to-tmp allowed" || fail "scp remote spec" "expected 0, got $RC · ${OUT#*|}"

OUT=$(run_bash "rsync -av deploy@remote-host:/Users/alice/dir/ /tmp/dir/")
RC="${OUT%%|*}"
[ "$RC" = "0" ] && pass "rsync remote spec allowed" || fail "rsync remote spec" "expected 0, got $RC · ${OUT#*|}"

# --- 3. Local paths on the same command line are still checked ---
OUT=$(run_bash "ssh remote-host 'bash -s' < /Users/bob/scripts/setup.sh")
RC="${OUT%%|*}"
ERR="${OUT#*|}"
[ "$RC" = "2" ] && pass "local stdin redirect still blocked" || fail "local stdin redirect" "expected 2, got $RC"
echo "$ERR" | grep -q "/Users/bob/scripts/setup.sh" && pass "block names the local path" || fail "block should name local path" "stderr: $ERR"

OUT=$(run_bash "scp /Users/bob/notes.txt remote-host:/Users/alice/")
RC="${OUT%%|*}"
ERR="${OUT#*|}"
[ "$RC" = "2" ] && pass "scp local source still blocked" || fail "scp local source" "expected 2, got $RC"
echo "$ERR" | grep -q "/Users/bob/notes.txt" && pass "scp block names local source, not remote spec" || fail "scp block should name local source" "stderr: $ERR"

OUT=$(run_bash "ssh remote-host 'cat /tmp/x' && cat /Users/bob/secret.txt")
RC="${OUT%%|*}"
[ "$RC" = "2" ] && pass "local command after && still blocked" || fail "local command after &&" "expected 2, got $RC"

OUT=$(run_bash "ssh remote-host 'journalctl -u app' > /Users/bob/logs/app.log")
RC="${OUT%%|*}"
[ "$RC" = "2" ] && pass "local output redirect still blocked" || fail "local output redirect" "expected 2, got $RC"

# --- 4. Plain local access unchanged ---
OUT=$(run_bash "cat /Users/bob/notes.txt")
RC="${OUT%%|*}"
[ "$RC" = "2" ] && pass "plain out-of-boundary local path still blocked" || fail "plain local path" "expected 2, got $RC"

OUT=$(run_bash "cat '$FIXTURE_PROJECT/README.md'")
RC="${OUT%%|*}"
[ "$RC" = "0" ] && pass "in-boundary local path still allowed" || fail "in-boundary local path" "expected 0, got $RC"

# --- 5. Hard tier stays conservative: denied paths block even inside ssh ---
OUT=$(run_bash "ssh remote-host 'cat /tmp/egregore-other-instance/secret.txt'")
RC="${OUT%%|*}"
[ "$RC" = "2" ] && pass "denied instance path inside ssh still hard-blocked" || fail "hard tier inside ssh" "expected 2, got $RC"

# --- Summary ---
echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
