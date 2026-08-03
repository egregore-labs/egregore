#!/usr/bin/env bash
# Regression test for framework updates after a failed base-branch checkout.
#
# History: setup_develop() swallowed `git checkout "$BASE_BRANCH"` failures and
# ended with BRANCH="$BASE_BRANCH", so it always returned success and reported
# the branch it wanted rather than the branch Git was actually on. The caller
# then applied upstream framework files to the user's topic branch. Holding the
# base branch in another worktree reproduces the failure deterministically.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t egregore-checkout-guard-XXXXXX)"
PASS=0
FAIL=0
trap 'rm -rf "$TMP"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
check() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1 — expected '$2', got '$3'"
  fi
}

echo "test-git-sync-checkout-guard"

make_fixture() {
  local name="$1"
  local dir="$TMP/$name"
  local repo="$dir/repo"
  local origin="$dir/origin.git"
  local upstream_work="$dir/upstream-work"
  local upstream="$dir/upstream.git"

  mkdir -p "$dir"
  git init --bare --initial-branch=develop --quiet "$origin"
  git init --bare --initial-branch=main --quiet "$upstream"

  git init --initial-branch=develop --quiet "$repo"
  git -C "$repo" config user.name "Checkout Guard Test"
  git -C "$repo" config user.email "checkout-guard@example.test"
  mkdir -p "$repo/bin/lib"
  cp "$ROOT/bin/lib/config.sh" "$repo/bin/lib/config.sh"
  cp "$ROOT/bin/lib/git-safe.sh" "$repo/bin/lib/git-safe.sh"
  cp "$ROOT/bin/lib/git-sync.sh" "$repo/bin/lib/git-sync.sh"
  printf 'downstream framework\n' > "$repo/bin/framework.txt"
  jq -n --arg upstream "$upstream" \
    '{mode:"local", slug:"checkout-guard-test", upstream_url:$upstream, auto_update:true, repos:[]}' \
    > "$repo/egregore.json"
  git -C "$repo" add -A
  git -C "$repo" commit -m "Seed downstream" --quiet
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -u origin develop --quiet

  git -C "$repo" switch -c feature/unique --quiet
  printf 'topic work\n' > "$repo/topic.txt"
  git -C "$repo" add topic.txt
  git -C "$repo" commit -m "Unique topic work" --quiet
  git -C "$repo" push -u origin feature/unique --quiet

  git init --initial-branch=main --quiet "$upstream_work"
  git -C "$upstream_work" config user.name "Upstream Test"
  git -C "$upstream_work" config user.email "upstream@example.test"
  mkdir -p "$upstream_work/bin"
  printf 'upstream framework\n' > "$upstream_work/bin/framework.txt"
  git -C "$upstream_work" add -A
  git -C "$upstream_work" commit -m "New upstream framework" --quiet
  git -C "$upstream_work" remote add origin "$upstream"
  git -C "$upstream_work" push -u origin main --quiet

  printf '%s\n' "$repo"
}

run_sync() {
  local repo="$1"
  local direct_probe="${2:-false}"
  (
    cd "$repo" || exit 1
    SCRIPT_DIR="$repo"
    IS_WORKTREE="false"
    MAIN_PROJECT_DIR="$repo"
    STATE_FILE="$repo/.egregore-state.json"
    ENV_FILE="$repo/.env"
    HEALTH_GIT="ok"
    # shellcheck source=bin/lib/config.sh
    . "$repo/bin/lib/config.sh"
    BASE_BRANCH="$(_get_base_branch)"
    # shellcheck source=bin/lib/git-sync.sh
    . "$repo/bin/lib/git-sync.sh"
    if [ "$direct_probe" = "true" ]; then
      # Defense-in-depth probe: even if a future caller invokes the updater
      # after setup failed, the updater itself must reject the topic branch.
      _apply_framework_update 2>/dev/null || true
    fi
    printf 'branch=%s\nhealth=%s\nupdated=%s\nready=%s\n' \
      "$BRANCH" "$HEALTH_GIT" "$FRAMEWORK_UPDATED" "$BASE_BRANCH_READY"
  )
}

# --- Failed checkout: base branch is held by another worktree ---------------
blocked_repo="$(make_fixture blocked)"
blocked_worktree="$TMP/blocked/develop-worktree"
git -C "$blocked_repo" worktree add "$blocked_worktree" develop --quiet
blocked_head_before="$(git -C "$blocked_repo" rev-parse HEAD)"
blocked_result="$(run_sync "$blocked_repo")"

check "failed checkout leaves Git on the topic branch" \
  "feature/unique" "$(git -C "$blocked_repo" branch --show-current)"
check "reported branch matches Git after checkout failure" \
  "branch=feature/unique" "$(printf '%s\n' "$blocked_result" | grep '^branch=')"
check "checkout failure marks Git health failed" \
  "health=fail" "$(printf '%s\n' "$blocked_result" | grep '^health=')"
check "base branch is not declared ready" \
  "ready=false" "$(printf '%s\n' "$blocked_result" | grep '^ready=')"
check "framework updater does not run on the topic branch" \
  "updated=false" "$(printf '%s\n' "$blocked_result" | grep '^updated=')"
check "topic branch HEAD is untouched" \
  "$blocked_head_before" "$(git -C "$blocked_repo" rev-parse HEAD)"
check "topic branch keeps its downstream framework file" \
  "downstream framework" "$(cat "$blocked_repo/bin/framework.txt")"
check "no framework update commit lands on the topic branch" \
  "0" "$(git -C "$blocked_repo" log --format=%s | grep -c '^Auto-update Egregore framework$' || true)"

# --- Defense in depth: updater rejects a direct wrong-branch call ------------
direct_repo="$(make_fixture direct)"
direct_worktree="$TMP/direct/develop-worktree"
git -C "$direct_repo" worktree add "$direct_worktree" develop --quiet
direct_head_before="$(git -C "$direct_repo" rev-parse HEAD)"
direct_result="$(run_sync "$direct_repo" true)"

check "direct updater call still refuses the topic branch" \
  "updated=false" "$(printf '%s\n' "$direct_result" | grep '^updated=')"
check "direct updater call leaves topic HEAD untouched" \
  "$direct_head_before" "$(git -C "$direct_repo" rev-parse HEAD)"
check "direct updater call preserves downstream framework content" \
  "downstream framework" "$(cat "$direct_repo/bin/framework.txt")"

# --- Successful checkout: updater still runs on the real base branch --------
ready_repo="$(make_fixture ready)"
ready_result="$(run_sync "$ready_repo")"

check "successful checkout switches to the base branch" \
  "develop" "$(git -C "$ready_repo" branch --show-current)"
check "successful setup reports the actual base branch" \
  "branch=develop" "$(printf '%s\n' "$ready_result" | grep '^branch=')"
check "successful setup declares the base ready" \
  "ready=true" "$(printf '%s\n' "$ready_result" | grep '^ready=')"
check "framework updater runs after verified checkout" \
  "updated=true" "$(printf '%s\n' "$ready_result" | grep '^updated=')"
check "base branch receives the upstream framework file" \
  "upstream framework" "$(cat "$ready_repo/bin/framework.txt")"
check "topic branch retains its original framework file" \
  "downstream framework" "$(git -C "$ready_repo" show feature/unique:bin/framework.txt)"
check "framework update commit lands on the base branch" \
  "Auto-update Egregore framework" "$(git -C "$ready_repo" log -1 --format=%s)"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
