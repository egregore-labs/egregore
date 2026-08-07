#!/usr/bin/env bash
# Regression tests for graph credential resolution in worktrees.
#
# Incident: a worktree missing its .env symlink ran graph.sh with an empty API
# key, and the connected-mode graph silently returned {"results":[]} — the
# graph looked empty instead of failing loudly.
#
# Covers:
#   1. Worktree missing .env symlink → graph.sh self-heals via worktree-links.sh
#      and finds the main checkout's credentials (never reports no_api_key).
#   2. api_url configured but no key anywhere → query fails loudly, never fakes
#      an empty result (graph.sh and graph-batch.sh).
#   3. Local-mode gate and unconfigured (no api_url) offline fallback unchanged.
#
# Runs in an isolated temp git repo — never touches the real project.
# Usage: bash tests/test-graph-env-selfheal.sh
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

TEST_ROOT=$(mktemp -d)
MAIN_REPO="$TEST_ROOT/main-repo"
WT_PATH="$MAIN_REPO/.claude/worktrees/wt"
trap 'rm -rf "$TEST_ROOT"' EXIT

# --- Setup: isolated repo with a worktree that has NO shared-state symlinks ---
mkdir -p "$MAIN_REPO/bin/lib" "$MAIN_REPO/.claude/worktrees"
cd "$MAIN_REPO" || exit 1
git init --quiet
git config user.email "test@test.com"
git config user.name "Test User"

# api_url points at a closed local port so credentialed calls fail fast
# without touching the network beyond localhost.
cat > egregore.json <<'EOF'
{"slug":"test","org_name":"Test Org","mode":"connected","api_url":"http://127.0.0.1:9"}
EOF
printf 'GITHUB_TOKEN=fake\nEGREGORE_API_KEY=fake-key\n' > .env
printf 'memory\n.env\n' > .gitignore

cp "$SCRIPT_DIR/bin/graph.sh" bin/graph.sh
cp "$SCRIPT_DIR/bin/graph-batch.sh" bin/graph-batch.sh
cp "$SCRIPT_DIR/bin/lib/worktree-links.sh" bin/lib/worktree-links.sh
chmod +x bin/graph.sh bin/graph-batch.sh

git add -A
git commit -m "init" --quiet

# Plain `git worktree add` — no Egregore setup, so no .env symlink. This is the
# broken state the incident started from.
git worktree add "$WT_PATH" --quiet -b test-branch

echo "=== graph credential self-heal tests ==="
echo ""

# --- 1. Worktree missing .env symlink finds main checkout's credentials ---
echo "1. Self-heal: worktree without .env symlink"
if [ -e "$WT_PATH/.env" ]; then
  fail "precondition — worktree unexpectedly has .env"
else
  pass "precondition — worktree has no .env"
fi

RESULT=$(bash "$WT_PATH/bin/graph.sh" test 2>&1)
RESULT_RC=$?
if echo "$RESULT" | grep -qF "no_api_key"; then
  fail "graph.sh reported no_api_key despite main checkout having a key"
else
  pass "graph.sh found credentials from the main checkout (no no_api_key)"
fi
# With credentials resolved, graph.sh enters API mode and the connection
# attempt against the closed port fails non-zero (offline mode would exit 0
# with status JSON instead).
if [ "$RESULT_RC" -ne 0 ] && ! echo "$RESULT" | grep -qF '"status":"offline"'; then
  pass "graph.sh reached API mode (connection attempt, not silent offline)"
else
  fail "graph.sh did not attempt a credentialed connection (rc=$RESULT_RC): $RESULT"
fi
if [ -L "$WT_PATH/.env" ]; then
  pass "worktree .env symlink was self-healed"
else
  fail "worktree .env symlink was not created"
fi

# --- 2. api_url configured, no key anywhere → loud failure, no fake empties ---
echo "2. Loud failure: connected config without a key"
rm -f "$MAIN_REPO/.env" "$WT_PATH/.env"

OUT=$(bash "$WT_PATH/bin/graph.sh" query "RETURN 1 AS test" 2>/dev/null)
RC=$?
ERR=$(bash "$WT_PATH/bin/graph.sh" query "RETURN 1 AS test" 2>&1 >/dev/null)
if [ "$RC" -ne 0 ]; then
  pass "graph.sh query exits non-zero without credentials"
else
  fail "graph.sh query exited 0 without credentials"
fi
if echo "$OUT" | grep -qF '"results":[]'; then
  fail "graph.sh query faked an empty graph on stdout"
else
  pass "graph.sh query did not fake an empty graph"
fi
if echo "$ERR" | grep -qF "EGREGORE_API_KEY is empty"; then
  pass "graph.sh query names the missing key on stderr"
else
  fail "graph.sh query stderr missing diagnostic: $ERR"
fi

BOUT=$(bash "$WT_PATH/bin/graph-batch.sh" '[{"statement":"RETURN 1 AS test","parameters":{}}]' 2>/dev/null)
BRC=$?
if [ "$BRC" -ne 0 ] && ! echo "$BOUT" | grep -qF '"results":[]'; then
  pass "graph-batch.sh fails loudly without credentials"
else
  fail "graph-batch.sh silent/zero-exit without credentials (rc=$BRC out=$BOUT)"
fi

# test subcommand keeps its offline JSON contract (dashboards consume it)
TOUT=$(bash "$WT_PATH/bin/graph.sh" test 2>&1)
if echo "$TOUT" | grep -qF '"reason":"no_api_key"'; then
  pass "graph.sh test keeps the offline no_api_key contract"
else
  fail "graph.sh test lost its offline contract: $TOUT"
fi

# --- 3. Local mode and unconfigured offline fallback unchanged ---
echo "3. Local gate and unconfigured fallback"
cat > "$MAIN_REPO/egregore.json" <<'EOF'
{"slug":"test","org_name":"Test Org","mode":"local"}
EOF
LOUT=$(bash "$MAIN_REPO/bin/graph.sh" query "RETURN 1" 2>&1)
LRC=$?
if [ "$LRC" -eq 0 ] && echo "$LOUT" | grep -qF '"results":[]'; then
  pass "local mode still returns quiet empty results"
else
  fail "local mode gate changed (rc=$LRC out=$LOUT)"
fi

cat > "$MAIN_REPO/egregore.json" <<'EOF'
{"slug":"test","org_name":"Test Org"}
EOF
UOUT=$(bash "$MAIN_REPO/bin/graph.sh" query "RETURN 1" 2>&1)
URC=$?
if [ "$URC" -eq 0 ] && echo "$UOUT" | grep -qF '"results":[]'; then
  pass "unconfigured (no api_url) keeps the quiet offline fallback"
else
  fail "unconfigured offline fallback changed (rc=$URC out=$UOUT)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
