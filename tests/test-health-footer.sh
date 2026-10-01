#!/bin/bash
# The greeting health footer: one renderer for every runtime, a failed
# dimension names its cause and the action, stale recall is not a failure.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; return 0; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; return 0; }

echo "Testing: greeting health footer"
echo ""

# Render with an explicit environment; every variable the footer reads is
# passed on the command line so nothing leaks from this shell.
render() {
  env -i PATH="$PATH" HOME="$HOME" "$@" bash -c 'source "$0"; _render_health_footer' "$ROOT/bin/lib/health-footer.sh"
}

# --- all green ------------------------------------------------------------------

out="$(render LOCAL_MODE=true HEALTH_GITHUB=ok HEALTH_GIT=ok HEALTH_MEMORY=ok HEALTH_RETRIEVAL=ok)"
[ "$out" = "  ✓ ready" ] && pass "local mode all ok renders ready" || fail "local mode all ok" "$out"

out="$(render LOCAL_MODE=true HEALTH_GITHUB=ok HEALTH_GIT=ok HEALTH_MEMORY=ok HEALTH_RETRIEVAL=ok FRAMEWORK_UPDATED=true)"
[ "$out" = "  ◆ updated" ] && pass "framework update shows as updated" || fail "framework updated" "$out"

out="$(render LOCAL_MODE=false HEALTH_GITHUB=ok HEALTH_GIT=ok HEALTH_MEMORY=ok HEALTH_RETRIEVAL=ok HEALTH_APIKEY=ok HEALTH_GRAPH=ok HEALTH_TELEGRAM=ok MEMORY_SYNCED=true)"
case "$out" in
  "  ✓ ready"*"◆ memory + recall ready") pass "connected all ok renders ready with memory + recall" ;;
  *) fail "connected all ok" "$out" ;;
esac

# --- a failure names its cause ------------------------------------------------------

out="$(render LOCAL_MODE=true HEALTH_GITHUB=ok HEALTH_GIT=ok HEALTH_MEMORY=fail HEALTH_MEMORY_REASON="resolve the conflict in the memory repository, then rerun sync" HEALTH_RETRIEVAL=ok)"
[ "$out" = "  ⚠ memory sync ✗ — resolve the conflict in the memory repository, then rerun sync" ] \
  && pass "memory failure prints the remedy, not /checkup" || fail "memory failure remedy" "$out"

out="$(render LOCAL_MODE=true HEALTH_GITHUB=ok HEALTH_GIT=fail HEALTH_GIT_REASON="origin/develop is missing; the fetch did not reach GitHub" HEALTH_MEMORY=ok HEALTH_RETRIEVAL=ok)"
[ "$out" = "  ⚠ git ✗ — origin/develop is missing; the fetch did not reach GitHub" ] \
  && pass "git failure prints its reason" || fail "git failure reason" "$out"

out="$(render LOCAL_MODE=true HEALTH_GITHUB=ok HEALTH_GIT=fail HEALTH_MEMORY=ok HEALTH_RETRIEVAL=ok)"
[ "$out" = "  ⚠ git ✗ — run /checkup" ] \
  && pass "a failure without a reason still points at /checkup" || fail "no-reason fallback" "$out"

out="$(render LOCAL_MODE=true HEALTH_GITHUB=ok HEALTH_GIT=fail HEALTH_GIT_REASON="base missing" HEALTH_MEMORY=fail HEALTH_MEMORY_REASON="offline; memory stays local until the next sync" HEALTH_RETRIEVAL=fail HEALTH_RETRIEVAL_DETAIL="lexical index is not built yet")"
expected="  ⚠ git ✗ — base missing
  ⚠ memory sync ✗ — offline; memory stays local until the next sync
  ⚠ recall ✗ — lexical index is not built yet"
[ "$out" = "$expected" ] && pass "each failed dimension gets its own line" || fail "multi failure lines" "$out"

# --- memory failure never masquerades as git -------------------------------------------

out="$(render LOCAL_MODE=true HEALTH_GITHUB=ok HEALTH_GIT=ok HEALTH_MEMORY=fail HEALTH_MEMORY_REASON="x" HEALTH_RETRIEVAL=ok)"
case "$out" in
  *"git ✗"*) fail "memory failure must not render as git ✗" "$out" ;;
  *) pass "memory failure is not reported as git" ;;
esac

# --- stale recall is information, not failure --------------------------------------------

out="$(render LOCAL_MODE=true HEALTH_GITHUB=ok HEALTH_GIT=ok HEALTH_MEMORY=ok HEALTH_RETRIEVAL=stale HEALTH_RETRIEVAL_DETAIL="3 uncommitted memory files not yet indexed")"
expected="  ◐ recall stale — 3 uncommitted memory files not yet indexed
  ✓ ready"
[ "$out" = "$expected" ] && pass "stale recall renders as ◐ and the card stays ready" || fail "stale recall" "$out"

out="$(render LOCAL_MODE=false HEALTH_GITHUB=ok HEALTH_GIT=ok HEALTH_MEMORY=ok HEALTH_RETRIEVAL=stale HEALTH_APIKEY=ok HEALTH_GRAPH=ok HEALTH_TELEGRAM=ok MEMORY_SYNCED=true)"
case "$out" in
  *"◐ recall stale"*"◆ memory synced · recall stale") pass "connected stale recall names itself on the ready line" ;;
  *) fail "connected stale recall" "$out" ;;
esac

# Optional hosted failures stay separate from local recall readiness.
out="$(render LOCAL_MODE=false HEALTH_GRAPH=fail HEALTH_RETRIEVAL=ok)"
[ "$out" = "  ⚠ optional hosted index ✗ — run /checkup" ] \
  && pass "optional hosted failure has a product label" || fail "hosted index label" "$out"

# --- return code ---------------------------------------------------------------------------

env -i PATH="$PATH" HOME="$HOME" LOCAL_MODE=true HEALTH_GIT=ok HEALTH_MEMORY=ok HEALTH_RETRIEVAL=ok \
  bash -c 'source "$0"; _render_health_footer >/dev/null' "$ROOT/bin/lib/health-footer.sh" \
  && pass "returns 0 when nothing failed" || fail "return 0 on ok"
env -i PATH="$PATH" HOME="$HOME" LOCAL_MODE=true HEALTH_GIT=fail HEALTH_MEMORY=ok HEALTH_RETRIEVAL=ok \
  bash -c 'source "$0"; _render_health_footer >/dev/null' "$ROOT/bin/lib/health-footer.sh" \
  && fail "must return 1 on a failure" || pass "returns 1 when a dimension failed"

# --- connected-only dimensions are ignored in local mode --------------------------------

out="$(render LOCAL_MODE=true HEALTH_GIT=ok HEALTH_MEMORY=ok HEALTH_RETRIEVAL=ok HEALTH_APIKEY=fail HEALTH_GRAPH=fail HEALTH_TELEGRAM=fail)"
[ "$out" = "  ✓ ready" ] && pass "local mode ignores api-key/graph/telegram" || fail "local ignores connected dims" "$out"

# --- cross-runtime parity: one renderer, no private copies ----------------------------------

for entry in bin/lib/greeting.sh bin/codex-session-start.sh; do
  if grep -q '_render_health_footer' "$ROOT/$entry"; then
    pass "$entry renders through the shared footer"
  else
    fail "$entry does not use the shared footer"
  fi
  if grep -q 'FAILED_SERVICES\|failed_services' "$ROOT/$entry"; then
    fail "$entry still carries a private footer loop"
  else
    pass "$entry has no private footer loop"
  fi
done

# --- git-sync separates memory from git and grades retrieval ---------------------------------

sync="$ROOT/bin/lib/git-sync.sh"
grep -q 'HEALTH_MEMORY="fail"' "$sync" && pass "git-sync reports memory sync on its own dimension" || fail "git-sync HEALTH_MEMORY"
grep -q "\.remedy" "$sync" && pass "git-sync reads the Runtime remedy" || fail "git-sync remedy"
grep -q "\.retrieval_grade" "$sync" && pass "git-sync reads the Runtime retrieval grade" || fail "git-sync retrieval_grade"
grep -q 'HEALTH_RETRIEVAL="stale"' "$sync" && pass "git-sync can grade retrieval stale" || fail "git-sync stale grade"
# The memory-sync block must never set the project-git dimension.
block="$(sed -n '/Synchronize canonical memory and retrieval readiness/,/Sync managed repos/p' "$sync")"
if grep -q 'HEALTH_GIT="fail"' <<< "$block"; then
  fail "memory sync block still sets HEALTH_GIT"
else
  pass "memory sync block never touches HEALTH_GIT"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
