#!/bin/bash
# Creating a task workspace records its topic and branch on the session's
# graph node — on every runtime, without the model running anything.
#
# Two entry points share the contract:
#   - bin/worktree-create.sh   (Claude Code's WorktreeCreate hook)
#   - bin/agent.sh branch      (Codex / Pi / Prime bridge)
# The by-hand step CLAUDE.md used to prescribe was silently dead under Claude
# Code's worktree parser (2026-09-10); the write now lives in the mechanics.
#
# Fixture: a bare remote, a clone with the real bin/ tree, a stub graph.sh
# that logs what it is asked, and a throwaway HOME so no instance registry is
# touched. Nothing here reaches a live service.
#
# Hook contract also covered: one stdout line (the path); dev/<author>/<slug>
# from origin/<base> without tracking; shared-state symlinks; success without
# a session id (and no graph call); the two-second budget.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; }

echo "=== workspace topic record: worktree-create.sh + agent.sh branch ==="

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

REMOTE="$TMP/origin.git"
CLONE="$TMP/clone"
MEMORY="$TMP/memory-repo"
GRAPH_LOG="$TMP/graph.log"

git init --bare -q "$REMOTE"
git clone -q "$REMOTE" "$CLONE" 2>/dev/null
git -C "$CLONE" checkout -qb develop
printf '%s\n' base > "$CLONE/README.md"
printf '%s\n' '{"mode":"connected","upstream_url":"none","slug":"fixture"}' > "$CLONE/egregore.json"
mkdir -p "$CLONE/bin/lib"
cp -R "$ROOT/bin/." "$CLONE/bin/"
# Stub graph gateway: log every invocation, never touch a network.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s\n' "$GRAPH_LOG" > "$CLONE/bin/graph.sh"
chmod +x "$CLONE/bin/graph.sh"
printf '%s\n' '{"github_username":"tester","onboarding_complete":true}' > "$CLONE/.egregore-state.json"
git -C "$CLONE" add README.md egregore.json bin .egregore-state.json
git -C "$CLONE" -c user.name=t -c user.email=t@example.com commit -qm init
git -C "$CLONE" push -qu origin develop 2>/dev/null

# Unversioned per-checkout state the hook symlinks into the worktree.
mkdir -p "$MEMORY/handoffs"
ln -s "$MEMORY" "$CLONE/memory"
printf 'GITHUB_TOKEN=x\n' > "$CLONE/.env"
printf 'sess-fixture-001\n' > "$CLONE/.egregore-session-id"

# --- 1. Happy path ---------------------------------------------------------
START=$(date +%s)
OUT=$(printf '{"name":"evrim-call-ingest"}' | CLAUDE_PROJECT_DIR="$CLONE" bash "$CLONE/bin/worktree-create.sh" 2>"$TMP/hook.err")
RC=$?
ELAPSED=$(( $(date +%s) - START ))
WT="$CLONE/.claude/worktrees/evrim-call-ingest"

[ "$RC" -eq 0 ] && pass "hook exits 0" || fail "hook exit $RC" "$(cat "$TMP/hook.err")"
[ "$OUT" = "$WT" ] && pass "stdout is exactly the worktree path" || fail "stdout was: $OUT"
[ "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" = "0" ] && pass "stdout is a single line" || fail "stdout has extra lines"
[ "$ELAPSED" -le 2 ] && pass "finished within the 2s hook budget (${ELAPSED}s)" || fail "took ${ELAPSED}s"
[ -d "$WT" ] && pass "worktree directory exists" || fail "worktree missing"

BRANCH=$(git -C "$WT" branch --show-current 2>/dev/null)
[ "$BRANCH" = "dev/tester/evrim-call-ingest" ] && pass "branch is dev/<author>/<slug>" || fail "branch was: $BRANCH"
UPSTREAM=$(git -C "$WT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
[ -z "$UPSTREAM" ] && pass "task branch does not track the base" || fail "tracks $UPSTREAM"
[ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$CLONE" rev-parse origin/develop)" ] \
  && pass "branch starts at origin/develop" || fail "branch point differs from origin/develop"

for link in memory .env .egregore-state.json .egregore-session-id; do
  [ -L "$WT/$link" ] && pass "symlink: $link" || fail "missing symlink: $link"
done
# egregore.json is committed in this fixture, so the worktree carries the real
# file and the hook must not replace it with a symlink.
[ -f "$WT/egregore.json" ] && [ ! -L "$WT/egregore.json" ] && pass "committed egregore.json is left as a real file" || fail "egregore.json was replaced or is missing"

# The graph write is detached; give it a moment.
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$GRAPH_LOG" ] && break; sleep 0.5; done
if [ -s "$GRAPH_LOG" ]; then
  pass "graph write happened without the model"
  grep -q 'sess-fixture-001' "$GRAPH_LOG" && pass "graph write carries the session id" || fail "session id missing from graph call" "$(cat "$GRAPH_LOG")"
  grep -q '"topic": "evrim call ingest"' "$GRAPH_LOG" && pass "topic derived from slug (dashes to spaces)" || fail "topic missing" "$(cat "$GRAPH_LOG")"
  grep -q '"branch": "dev/tester/evrim-call-ingest"' "$GRAPH_LOG" && pass "graph write carries the branch" || fail "branch missing" "$(cat "$GRAPH_LOG")"
  grep -q 's.topic = \$topic, s.branch = \$branch' "$GRAPH_LOG" && pass "uses the set-topic Cypher with branch" || fail "unexpected Cypher" "$(cat "$GRAPH_LOG")"
else
  fail "graph write never happened" "$(cat "$TMP/hook.err")"
fi

# --- 2. Idempotent re-entry: same slug again reuses the branch -------------
OUT2=$(printf '{"name":"evrim-call-ingest"}' | CLAUDE_PROJECT_DIR="$CLONE" bash "$CLONE/bin/worktree-create.sh" 2>/dev/null)
[ "$OUT2" = "$WT" ] && [ -d "$WT" ] && pass "re-entering the same slug is idempotent" || fail "re-entry broke: $OUT2"

# --- 3. No session id: succeeds, no graph call -----------------------------
: > "$GRAPH_LOG"
rm -f "$CLONE/.egregore-session-id"
OUT3=$(printf '{"name":"second-topic"}' | CLAUDE_PROJECT_DIR="$CLONE" bash "$CLONE/bin/worktree-create.sh" 2>"$TMP/hook3.err")
[ "$?" -eq 0 ] && [ -d "$CLONE/.claude/worktrees/second-topic" ] && pass "without a session id the worktree is still created" || fail "hook failed without session id" "$(cat "$TMP/hook3.err")"
sleep 1
[ ! -s "$GRAPH_LOG" ] && pass "without a session id no graph call is made" || fail "graph called without a session id" "$(cat "$GRAPH_LOG")"

# --- 4. Denial: empty name -------------------------------------------------
if printf '{}' | CLAUDE_PROJECT_DIR="$CLONE" bash "$CLONE/bin/worktree-create.sh" >/dev/null 2>&1; then
  fail "empty name should fail"
else
  pass "empty name is refused"
fi

# --- 5. From inside a worktree: resolves back to the main repo -------------
printf 'sess-fixture-002\n' > "$CLONE/.egregore-session-id"
OUT5=$(printf '{"name":"from-inside"}' | CLAUDE_PROJECT_DIR="$WT" bash "$WT/bin/worktree-create.sh" 2>"$TMP/hook5.err")
# The hook resolves the main repo with cd/pwd, which on macOS turns /var into
# /private/var; compare physical paths.
WANT5=$(cd "$CLONE/.claude/worktrees/from-inside" 2>/dev/null && pwd -P)
GOT5=$(cd "$OUT5" 2>/dev/null && pwd -P)
[ -n "$GOT5" ] && [ "$GOT5" = "$WANT5" ] && pass "called from a worktree, creates beside it under the main repo" || fail "wrong path from inside a worktree: $OUT5" "$(cat "$TMP/hook5.err")"
# Let the detached graph write land before moving on.
for _ in 1 2 3 4 5 6; do grep -q 'sess-fixture-002' "$GRAPH_LOG" 2>/dev/null && break; sleep 0.5; done

# --- 6. Codex/Pi/Prime bridge: agent.sh branch records the topic too --------
: > "$GRAPH_LOG"
printf 'sess-fixture-003\n' > "$CLONE/.egregore-session-id"
BR_OUT=$(bash "$CLONE/bin/agent.sh" branch --topic "codex topic smoke" 2>"$TMP/agent.err")
BR_RC=$?
[ "$BR_RC" -eq 0 ] && pass "agent.sh branch exits 0" || fail "agent.sh branch exit $BR_RC" "$(cat "$TMP/agent.err")"
grep -q "branch: dev/tester/codex-topic-smoke" <<< "$BR_OUT" && pass "agent.sh branch names dev/<author>/<slug>" || fail "unexpected branch line" "$BR_OUT"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'sess-fixture-003' "$GRAPH_LOG" 2>/dev/null && break; sleep 0.5; done
if grep -q 'sess-fixture-003' "$GRAPH_LOG" 2>/dev/null; then
  pass "agent.sh branch records the topic on the graph (new worktree path)"
  grep -q '"topic": "codex topic smoke"' "$GRAPH_LOG" && pass "bridge passes the human topic, not the slug" || fail "topic text differs" "$(cat "$GRAPH_LOG")"
  grep -q '"branch": "dev/tester/codex-topic-smoke"' "$GRAPH_LOG" && pass "bridge passes the branch" || fail "branch missing" "$(cat "$GRAPH_LOG")"
else
  fail "agent.sh branch made no graph write" "$(cat "$TMP/agent.err")"
fi

# Re-entering an existing branch (the 'existing worktree' path) records too.
: > "$GRAPH_LOG"
bash "$CLONE/bin/agent.sh" branch --topic "codex topic smoke" >/dev/null 2>"$TMP/agent2.err"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'sess-fixture-003' "$GRAPH_LOG" 2>/dev/null && break; sleep 0.5; done
grep -q 'sess-fixture-003' "$GRAPH_LOG" 2>/dev/null && pass "re-entering an existing branch records the topic (existing worktree path)" || fail "no graph write on re-entry" "$(cat "$TMP/agent2.err")"

# From inside a worktree (the 'checkout in place' path) records too.
: > "$GRAPH_LOG"
AGENT_WT="$CLONE/.claude/worktrees/codex-topic-smoke"
bash "$AGENT_WT/bin/agent.sh" branch --topic "codex pivot" >/dev/null 2>"$TMP/agent3.err"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'sess-fixture-003' "$GRAPH_LOG" 2>/dev/null && break; sleep 0.5; done
if grep -q '"branch": "dev/tester/codex-pivot"' "$GRAPH_LOG" 2>/dev/null; then
  pass "branching in place inside a worktree records the new topic (checkout path)"
else
  fail "no graph write on in-place branch" "$(cat "$TMP/agent3.err"; cat "$GRAPH_LOG")"
fi

echo ""
echo "workspace-topic-record: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
