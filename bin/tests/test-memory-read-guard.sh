#!/usr/bin/env bash
set -uo pipefail

# Test: memory-read-guard hook. During a retrieval episode (fresh evidence
# packet for the session), raw dumps of memory files — cat/sed/head/tail via
# Bash, or the Read tool — are blocked with the private opener as the hint.
# Searching, listing, git, code reads, edits, and anything outside an
# episode pass untouched.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.claude/hooks/memory-read-guard.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1" >&2; }

mkdir -p "$T/proj/memory/meetings" "$T/proj/bin" "$T/tmp/egregore-retrieval-context"
echo "guard-test-session" > "$T/proj/.egregore-session-id"
echo "# note" > "$T/proj/memory/meetings/x.md"
echo "echo hi" > "$T/proj/bin/tool.sh"
PACKET="$T/tmp/egregore-retrieval-context/guard-test-session.context"

run() {
  CLAUDE_PROJECT_DIR="$T/proj" TMPDIR="$T/tmp" bash "$HOOK" <<<"$1" 2>"$T/err"
  echo $?
}
bash_json() { jq -cn --arg c "$1" '{session_id:"guard-native-session",tool_name:"Bash",tool_input:{command:$c}}'; }
read_json() { jq -cn --arg f "$1" '{session_id:"guard-native-session",tool_name:"Read",tool_input:{file_path:$f}}'; }

echo "Testing: memory read guard"
echo ""

rm -f "$PACKET"
[ "$(run "$(bash_json 'sed -n 1,140p memory/meetings/x.md')")" = 0 ] \
  && pass "no retrieval episode: raw memory read passes" || fail "blocked without a packet"

echo "evidence" > "$PACKET"
[ "$(run "$(bash_json 'sed -n 1,140p memory/meetings/x.md')")" = 2 ] \
  && pass "sed dump of a memory file is blocked during an episode" || fail "sed dump not blocked"
grep -q 'bin/search.sh open memory/meetings/x.md --context-packet' "$T/err" \
  && pass "the block names the private opener for that file" || fail "opener hint missing: $(cat "$T/err")"
[ "$(run "$(bash_json 'cat memory/meetings/x.md; echo done')")" = 2 ] \
  && pass "cat is blocked" || fail "cat not blocked"

# Native sessions retain their investigation state after private delivery.
# Delivery itself is exercised by test_native_result_delivery.py and the
# packed-runtime canary. This guard fixture supplies the persisted binding
# and proves it works without any legacy shared packet or episode marker.
rm -f "$PACKET" "${PACKET%.context}.episode"
STATE=$(python3 - "$T/proj" <<'PYFIXTURE'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1]) / '.egregore/runtime'
bindings = root / 'bindings'; bindings.mkdir(parents=True)
states = root / 'investigations'; states.mkdir(parents=True)
episode = 'ep_guard_fixture'
key = hashlib.sha256(b'claude:guard-native-session').hexdigest()
(bindings / (key + '.current')).write_text(json.dumps({'episode_id': episode}))
state = states / (hashlib.sha256(episode.encode()).hexdigest() + '.json')
state.write_text(json.dumps({'episode_id': episode, 'calls': []}))
print(state)
PYFIXTURE
)
[ ! -f "$PACKET" ] && [ ! -f "${PACKET%.context}.episode" ] \
  && pass "native fixture has no legacy packet or marker" || fail "legacy packet remains"
[ "$(run "$(bash_json 'sed -n 1,140p memory/meetings/x.md')")" = 2 ] \
  && pass "native investigation still blocks after private delivery" || fail "native investigation not enforced"
echo "evidence" > "$PACKET"
[ "$(run "$(bash_json 'ls -t memory/handoffs | head -3; tail -20 memory/meetings/x.md')")" = 2 ] \
  && pass "tail inside a command chain is blocked" || fail "chained tail not blocked"
[ "$(run "$(bash_json 'bash bin/search.sh open memory/meetings/x.md --context-packet')")" = 0 ] \
  && pass "the private opener passes" || fail "opener blocked"
[ "$(run "$(bash_json 'grep -rl cem memory/handoffs/')")" = 0 ] \
  && pass "grep search over memory passes" || fail "grep blocked"
[ "$(run "$(bash_json 'ls -la memory/handoffs/2026-09/')")" = 0 ] \
  && pass "ls passes" || fail "ls blocked"
[ "$(run "$(bash_json 'git -C memory log --oneline -3')")" = 0 ] \
  && pass "git on the memory repo passes" || fail "git blocked"
[ "$(run "$(bash_json 'sed -n 1,40p bin/attendant.sh')")" = 0 ] \
  && pass "sed on a code file passes" || fail "code read blocked"
[ "$(run "$(bash_json 'bash bin/handoff-run.sh memory/handoffs/2026-09/x.md')")" = 0 ] \
  && pass "a script taking a memory path passes" || fail "script blocked"
[ "$(run "$(read_json "$T/proj/memory/meetings/x.md")")" = 2 ] \
  && pass "Read tool on a memory file is blocked during an episode" || fail "Read not blocked"
grep -q 'bin/search.sh open memory/meetings/x.md --context-packet' "$T/err" \
  && pass "Read block names the private opener" || fail "Read hint missing: $(cat "$T/err")"
[ "$(run "$(read_json "$T/proj/bin/tool.sh")")" = 0 ] \
  && pass "Read tool on code passes" || fail "Read on code blocked"
[ "$(run "$(jq -cn '{tool_name:"Edit",tool_input:{file_path:"memory/meetings/x.md"}}')")" = 0 ] \
  && pass "Edit is never the guard's business" || fail "Edit blocked"

touch -t "$(date -v-30M '+%Y%m%d%H%M' 2>/dev/null || date -d '30 minutes ago' '+%Y%m%d%H%M')" "$PACKET" "${PACKET%.context}.episode" "$STATE"
[ "$(run "$(bash_json 'cat memory/meetings/x.md')")" = 0 ] \
  && pass "a 30-minute-old native investigation ends the episode" || fail "stale packet still blocks"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
