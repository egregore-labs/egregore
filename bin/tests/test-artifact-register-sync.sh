#!/usr/bin/env bash
set -uo pipefail

# Test: bin/artifact-register.sh commits each registry record to the memory
# repo and pushes it in the background. Two teammates can write records at
# the same time without seeing each other's, and the memory repo must never
# be left mid-rebase: every other script that pulls there would then fail.
# Covers:
#   - two teammates recording the same referenced file on the same day under
#     different hosted ids: two records, both pushed
#   - the same record (same day and hosted id) pushed first by someone else:
#     theirs is kept, and the local copy follows it
#   - a conflict on another file: the pull is undone, local commits stay
#   - a rebase this script did not start is left alone

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

WORK="$(mktemp -d -t artifact-register-sync-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

CANON="m-0fec3905a74e"
DECISION="knowledge/decisions/plan.md"

# new_remote <name>: a bare memory repo with one commit on main.
new_remote() {
  local remote="$WORK/$1.git" seed="$WORK/$1-seed"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  git init -q "$seed"
  git -C "$seed" checkout -q -b main
  mkdir -p "$seed/knowledge/decisions" "$seed/artifacts"
  printf '# Plan\n\nThe plan.\n' > "$seed/$DECISION"
  printf 'notes\n' > "$seed/notes.md"
  : > "$seed/artifacts/.keep"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m seed
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" push -q origin main
}

# new_instance <name> <remote>: an instance whose memory/ is a clone.
new_instance() {
  local inst="$WORK/$1"
  mkdir -p "$inst/bin"
  cp "$SCRIPT_DIR/bin/artifact-register.sh" "$inst/bin/"
  printf '{"mode":"local"}\n' > "$inst/egregore.json"
  git clone -q "$WORK/$2.git" "$inst/memory"
}

# register <instance> <hosted id> [description]: records the decision as a
# referenced file.
register() {
  bash "$WORK/$1/bin/artifact-register.sh" --id "$2" \
    --url "https://egregore.xyz/view/acme/$2" --type decision \
    --source "$WORK/$1/memory/$DECISION" --canonical-id "$CANON" \
    --description "${3:-}"
}

mid_rebase() { # <repo>
  [ -d "$1/.git/rebase-merge" ] || [ -d "$1/.git/rebase-apply" ]
}

# wait_until <command…>: polls for up to 15 seconds.
wait_until() {
  local tries=0
  while [ "$tries" -lt 75 ]; do
    "$@" && return 0
    sleep 0.2
    tries=$((tries + 1))
  done
  return 1
}

remote_has() { # <remote> <path>
  git --git-dir="$WORK/$1.git" ls-tree -r --name-only main 2>/dev/null | grep -qxF "$2"
}

remote_records_mention() { # <remote> <text>
  git --git-dir="$WORK/$1.git" grep -qF "$2" main -- artifacts 2>/dev/null
}

in_sync() { # <instance> <remote>
  ! mid_rebase "$WORK/$1/memory" \
    && [ "$(git -C "$WORK/$1/memory" rev-parse HEAD 2>/dev/null)" \
      = "$(git --git-dir="$WORK/$2.git" rev-parse main 2>/dev/null)" ]
}

aborted_three_times() { # <repo>
  [ "$(git -C "$1" reflog 2>/dev/null | grep -c 'rebase (abort)')" -ge 3 ]
}

HOSTED_A="m-$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32)"
HOSTED_B="m-$(printf 'b%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32)"

# --- 1. Different hosted ids on the same day ---
echo "1. Two teammates record one referenced file on one day, neither has pulled"
new_remote one
new_instance ana one
new_instance bo one

RECORD_A="$(register ana "$HOSTED_A")"
REL_A="artifacts/$(basename "$RECORD_A")"
wait_until remote_has one "$REL_A" || fail "the first record was never pushed"

RECORD_B="$(register bo "$HOSTED_B")"
REL_B="artifacts/$(basename "$RECORD_B")"
if [ "$REL_A" != "$REL_B" ]; then
  pass "records with different hosted ids have different names"
else
  fail "both records have one name" "$REL_A"
fi
if wait_until remote_records_mention one "$HOSTED_B" \
  && remote_records_mention one "$HOSTED_A"; then
  pass "both records are pushed"
else
  fail "the second record was not pushed" "$(git -C "$WORK/bo/memory" status 2>&1 | head -3)"
fi
if mid_rebase "$WORK/bo/memory"; then
  fail "the memory repo was left mid-rebase"
else
  pass "the memory repo is not left mid-rebase"
fi

# --- 2. The same record pushed first by someone else ---
echo ""
echo "2. The same record (same day and hosted id) was pushed first"
new_remote two
new_instance ana2 two
new_instance bo2 two

RECORD_A="$(register ana2 "$HOSTED_A" "Ana's copy")"
REL_A="artifacts/$(basename "$RECORD_A")"
wait_until remote_has two "$REL_A" || fail "the first record was never pushed"
RECORD_B="$(register bo2 "$HOSTED_A" "Bo's copy")"
[ "artifacts/$(basename "$RECORD_B")" = "$REL_A" ] || fail "the same record got two names"

if wait_until in_sync bo2 two; then
  pass "the local repo follows the pushed record and is not left mid-rebase"
else
  fail "the local repo did not settle" "$(git -C "$WORK/bo2/memory" status 2>&1 | head -3)"
fi
if [ "$(git --git-dir="$WORK/two.git" show "main:$REL_A" 2>/dev/null)" = "$(cat "$RECORD_A")" ]; then
  pass "the record pushed first is kept"
else
  fail "the pushed record was replaced"
fi

# --- 3. A conflict on another file ---
echo ""
echo "3. The pull conflicts on a file this script did not write"
new_remote three
new_instance ana3 three
new_instance bo3 three
printf 'notes from Ana\n' > "$WORK/ana3/memory/notes.md"
git -C "$WORK/ana3/memory" commit -q -am "ana's notes"
git -C "$WORK/ana3/memory" push -q origin main
printf 'notes from Bo\n' > "$WORK/bo3/memory/notes.md"
git -C "$WORK/bo3/memory" commit -q -am "bo's notes"

RECORD_B="$(register bo3 "$HOSTED_B")"
REL_B="artifacts/$(basename "$RECORD_B")"
wait_until aborted_three_times "$WORK/bo3/memory"
sleep 0.5
if mid_rebase "$WORK/bo3/memory"; then
  fail "the memory repo was left mid-rebase"
else
  pass "the conflicting pull is undone, not left open"
fi
if [ "$(git -C "$WORK/bo3/memory" show HEAD~1:notes.md 2>/dev/null)" = "notes from Bo" ] \
  && git -C "$WORK/bo3/memory" cat-file -e "HEAD:$REL_B" 2>/dev/null; then
  pass "local commits stay as they were"
else
  fail "local commits changed" "$(git -C "$WORK/bo3/memory" log --oneline -3 2>&1)"
fi

# --- 4. A rebase someone else started ---
echo ""
echo "4. A rebase this script did not start is left alone"
git -C "$WORK/bo3/memory" pull -q --rebase >/dev/null 2>&1
if mid_rebase "$WORK/bo3/memory"; then
  register bo3 "$HOSTED_A" >/dev/null
  sleep 3
  if mid_rebase "$WORK/bo3/memory"; then
    pass "the other rebase is still open"
  else
    fail "the script ended a rebase it did not start"
  fi
else
  fail "could not set up an open rebase"
fi

# --- Summary ---
echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
