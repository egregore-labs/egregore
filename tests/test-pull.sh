#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# Isolated integration tests for the executable pull skill.
# Usage: bash tests/test-pull.sh
# Exit 0 = all cases passed, Exit 1 = a case failed

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
CASE_NUMBER=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
  printf '    exit: %s\n    output: %s\n' "$EXIT_CODE" "$OUTPUT"
  sed 's/^/    stderr: /' "$scratch/stderr"
}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/test-pull.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home"

# Fixture commands never inherit the driver's checkout or personal Git config.
fixture_env() {
  HOME="$scratch/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
      -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR "$@"
}
fixture_git() { fixture_env git "$@"; }
fixture_run() (
  cd "$1"
  shift
  fixture_env env PULL_SYNC_MARKER="$case_dir/sync-called" bash "$@"
)
capture() {
  EXIT_CODE=0
  OUTPUT=$("$@" 2> "$scratch/stderr") || EXIT_CODE=$?
}
json_is() { printf '%s\n' "$OUTPUT" | jq -e "$1" >/dev/null; }
text_has() { grep -Fq -- "$1" <<< "$OUTPUT"; }
configure_author() {
  fixture_git -C "$1" config --local user.name 'Pull Fixture'
  fixture_git -C "$1" config --local user.email 'pull@example.invalid'
  fixture_git -C "$1" config --local core.hooksPath /dev/null
  fixture_git -C "$1" config --local commit.gpgsign false
}
commit_fixture() {
  fixture_git -C "$1" add -A
  fixture_git -C "$1" commit -qm "$2"
}
new_fixture() {
  CASE_NUMBER=$((CASE_NUMBER + 1))
  case_dir="$scratch/case-$CASE_NUMBER"
  hub="$case_dir/hub"
  memory="$case_dir/memory-fixture"
  mkdir -p "$case_dir"
  fixture_git init --bare --initial-branch=main "$case_dir/origin.git" >/dev/null
  fixture_git clone "$case_dir/origin.git" "$hub" >/dev/null 2>&1
  configure_author "$hub"
  fixture_git init --bare --initial-branch=main "$case_dir/memory.git" >/dev/null
  fixture_git clone "$case_dir/memory.git" "$memory" >/dev/null 2>&1
  configure_author "$memory"
  mkdir -p "$memory/handoffs" "$hub/bin/lib"
  printf '%s\n' initial > "$memory/handoffs/index.md"
  commit_fixture "$memory" 'Initial memory'
  fixture_git -C "$memory" push -u origin main >/dev/null 2>&1
  cp "$SCRIPT_DIR/bin/pull.sh" "$SCRIPT_DIR/bin/base-branch.sh" "$hub/bin/"
  cp "$SCRIPT_DIR/bin/lib/config.sh" "$hub/bin/lib/"
  cat > "$hub/bin/agent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
if [ "${1:-}" != sync ]; then exit 2; fi
printf '%s\n' called >> "$PULL_SYNC_MARKER"
if [ "${STUB_SYNC_FAIL:-0}" = 1 ]; then
  printf '%s\n' 'stub first' 'stub second' 'stub third' 'stub fourth' 'stub fifth' 'stub sixth' 'stub sync failed'
  exit 1
fi
git -C "$(dirname "$0")/../memory" pull --rebase origin main --quiet
printf '%s\n' 'stub sync'
EOF
  printf '%s\n' '{"mode":"local","base_branch":"main","memory_repo":"https://example.invalid/memory-fixture.git"}' > "$hub/egregore.json"
  printf '%s\n' /memory > "$hub/.gitignore"
  printf '%s\n' initial > "$hub/shared.txt"
  commit_fixture "$hub" 'Initial framework'
  fixture_git -C "$hub" push -u origin main >/dev/null 2>&1
  memory=$(cd "$memory" && pwd -P)
  ln -s "$memory" "$hub/memory"
  run_dir="$hub"
}
make_task() {
  fixture_git -C "$hub" switch -c dev/t/topic >/dev/null 2>&1
  printf '%s\n' topic > "$hub/topic.txt"
  commit_fixture "$hub" 'Topic work'
}
advance_base() {
  fixture_git clone "$case_dir/origin.git" "$case_dir/advancer" >/dev/null 2>&1
  configure_author "$case_dir/advancer"
  printf '%s\n' "${2:-remote}" > "$case_dir/advancer/${1:-remote.txt}"
  commit_fixture "$case_dir/advancer" 'Advance main'
  fixture_git -C "$case_dir/advancer" push origin main >/dev/null 2>&1
}
advance_memory() {
  fixture_git clone "$case_dir/memory.git" "$case_dir/memory-advancer" >/dev/null 2>&1
  configure_author "$case_dir/memory-advancer"
  printf '%s\n' updated > "$case_dir/memory-advancer/handoffs/index.md"
  printf '%s\n' new > "$case_dir/memory-advancer/handoffs/new handoff.md"
  commit_fixture "$case_dir/memory-advancer" 'Advance memory'
  fixture_git -C "$case_dir/memory-advancer" push origin main >/dev/null 2>&1
}
run_pull() {
  if [ "$report_mode" = json ]; then
    capture fixture_run "$run_dir" bin/pull.sh --json
  else
    capture fixture_run "$run_dir" bin/pull.sh
  fi
}
report_is() {
  [ "$EXIT_CODE" -eq "$1" ] || return 1
  if [ "$report_mode" = json ]; then
    json_is 'type == "object" and (.base.name | type) == "string"
      and (.base.ref | type) == "string" and (.base.action | type) == "string"
      and (.base.new_commits | type) == "number"
      and (.branch.name | type) == "string" and (.branch.action | type) == "string"
      and (.branch.note | type) == "string" and (.memory.path | type) == "string"
      and (.memory.action | type) == "string" and (.memory.note | type) == "string"
      and (.memory.new_commits | type) == "number" and (.memory.files | type) == "array"' \
      && json_is ".exit == $1" && json_is "$3"
  else
    text_has 'Pulling...' && text_has "$2"
  fi
}
expect_report() {
  if report_is "$2" "$3" "$4"; then pass "$1 ($report_mode)"; else fail "$1 ($report_mode)"; fi
}
expect_fatal() {
  if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && grep -Fq -- "$2" "$scratch/stderr"; then
    pass "$1 ($report_mode)"
  else fail "$1 ($report_mode)"; fi
}

echo '=== pull.sh tests ==='
# Every report outcome is exercised independently in both text and JSON modes.
for report_mode in text json; do
  new_fixture
  make_task
  advance_base
  run_pull
  if report_is 0 '✓ rebased onto main' '.branch.action == "rebased" and .base.new_commits == 1 and .base.ref == "origin/main"' \
     && [ "$(fixture_git -C "$hub" rev-parse HEAD^)" = "$(fixture_git -C "$hub" rev-parse origin/main)" ] \
     && { [ "$report_mode" = json ] || text_has '↓ 1 commits → synced'; }; then
    pass "task branch rebases onto fetched origin/main ($report_mode)"
  else fail "task branch rebases onto fetched origin/main ($report_mode)"; fi

  new_fixture
  advance_base
  run_pull
  expect_report 'base branch fast-forwards' 0 '✓ fast-forwarded' '.branch.name == "main" and .branch.action == "fast-forwarded"'

  new_fixture
  fixture_git -C "$hub" config branch.main.mergeOptions --squash
  advance_base
  run_pull
  if report_is 0 '✓ fast-forwarded' '.branch.name == "main" and .branch.action == "fast-forwarded"' \
     && [ "$(fixture_git -C "$hub" rev-parse HEAD)" = "$(fixture_git -C "$hub" rev-parse origin/main)" ] \
     && [ -z "$(fixture_git -C "$hub" status --porcelain)" ] && [ ! -e "$hub/.git/MERGE_HEAD" ]; then
    pass "base fast-forward overrides branch squash configuration ($report_mode)"
  else fail "base fast-forward overrides branch squash configuration ($report_mode)"; fi

  new_fixture
  printf '%s\n' config.local >> "$hub/.git/info/exclude"
  printf '%s\n' 'local settings to preserve' > "$hub/config.local"
  before=$(fixture_git -C "$hub" rev-parse HEAD)
  advance_base config.local
  run_pull
  if report_is 0 '⚠ skipped:' '.branch.name == "main" and .branch.action == "skipped"' \
     && [ "$(cat "$hub/config.local")" = 'local settings to preserve' ] \
     && [ "$before" = "$(fixture_git -C "$hub" rev-parse HEAD)" ] \
     && [ -z "$(fixture_git -C "$hub" status --porcelain)" ] \
     && [ ! -e "$hub/.git/MERGE_HEAD" ] && [ -f "$case_dir/sync-called" ]; then
    pass "base fast-forward preserves ignored files and leaves a clean tree ($report_mode)"
  else fail "base fast-forward preserves ignored files and leaves a clean tree ($report_mode)"; fi

  new_fixture
  make_task
  printf '%s\n' config.local >> "$hub/.git/info/exclude"
  printf '%s\n' 'local settings to preserve' > "$hub/config.local"
  before=$(fixture_git -C "$hub" rev-parse HEAD)
  advance_base config.local
  run_pull
  if report_is 0 '⚠ skipped: ignored files would be overwritten: config.local' \
       '.branch.action == "skipped" and .branch.note == "ignored files would be overwritten: config.local"' \
     && [ "$(cat "$hub/config.local")" = 'local settings to preserve' ] \
     && [ "$before" = "$(fixture_git -C "$hub" rev-parse HEAD)" ] \
     && [ -z "$(fixture_git -C "$hub" status --porcelain)" ] \
     && [ ! -e "$hub/.git/rebase-merge" ] && [ ! -e "$hub/.git/rebase-apply" ] \
     && [ -f "$case_dir/sync-called" ]; then
    pass "task rebase skips incoming paths occupied by ignored files ($report_mode)"
  else fail "task rebase skips incoming paths occupied by ignored files ($report_mode)"; fi

  for ignored_branch in main dev/t/topic; do
    new_fixture
    printf '%s\n' 'tracked source to preserve' > "$hub/tracked.txt"
    commit_fixture "$hub" 'Add the tracked rename source'
    fixture_git -C "$hub" push origin main >/dev/null 2>&1
    if [ "$ignored_branch" != main ]; then make_task; fi
    fixture_git -C "$hub" config diff.renames true
    printf '%s\n' config.local >> "$hub/.git/info/exclude"
    printf '%s\n' 'local settings to preserve' > "$hub/config.local"
    before=$(fixture_git -C "$hub" rev-parse HEAD)
    fixture_git clone "$case_dir/origin.git" "$case_dir/advancer" >/dev/null 2>&1
    configure_author "$case_dir/advancer"
    fixture_git -C "$case_dir/advancer" mv tracked.txt config.local
    commit_fixture "$case_dir/advancer" 'Rename a tracked file onto an ignored local path'
    fixture_git -C "$case_dir/advancer" push origin main >/dev/null 2>&1
    run_pull
    if report_is 0 '⚠ skipped: ignored files would be overwritten: config.local' \
         '.branch.action == "skipped" and .branch.note == "ignored files would be overwritten: config.local"' \
       && [ "$(cat "$hub/config.local")" = 'local settings to preserve' ] \
       && [ "$(cat "$hub/tracked.txt")" = 'tracked source to preserve' ] \
       && [ "$before" = "$(fixture_git -C "$hub" rev-parse HEAD)" ] \
       && [ -z "$(fixture_git -C "$hub" status --porcelain)" ] \
       && [ ! -e "$hub/.git/rebase-merge" ] && [ ! -e "$hub/.git/rebase-apply" ] \
       && [ ! -e "$hub/.git/MERGE_HEAD" ] && [ -f "$case_dir/sync-called" ]; then
      pass "incoming rename preserves ignored destination and tracked source on $ignored_branch ($report_mode)"
    else fail "incoming rename preserves ignored destination and tracked source on $ignored_branch ($report_mode)"; fi
  done

  new_fixture
  make_task
  fixture_git -C "$hub" branch -f main dev/t/topic
  fixture_git -C "$hub" config rebase.updateRefs true
  before=$(fixture_git -C "$hub" rev-parse main)
  advance_base
  run_pull
  if report_is 0 '✓ rebased onto main' '.branch.action == "rebased"' \
     && [ "$before" = "$(fixture_git -C "$hub" rev-parse main)" ] \
     && [ "$before" != "$(fixture_git -C "$hub" rev-parse HEAD)" ] \
     && [ "$(fixture_git -C "$hub" rev-parse HEAD^)" = "$(fixture_git -C "$hub" rev-parse origin/main)" ]; then
    pass "rebase.updateRefs cannot move an unchecked-out main ref ($report_mode)"
  else fail "rebase.updateRefs cannot move an unchecked-out main ref ($report_mode)"; fi

  new_fixture
  make_task
  advance_base
  advance_memory
  printf '%s\n' dirty >> "$hub/shared.txt"
  before=$(fixture_git -C "$hub" rev-parse HEAD)
  run_pull
  if report_is 0 '⚠ skipped: uncommitted changes; branch not rebased' '.branch.action == "skipped" and .branch.note == "uncommitted changes; branch not rebased" and .memory.action == "updated"' \
     && [ "$before" = "$(fixture_git -C "$hub" rev-parse HEAD)" ] \
     && [ -f "$memory/handoffs/new handoff.md" ] && [ -f "$case_dir/sync-called" ]; then
    pass "dirty tracked files skip branch but still sync memory ($report_mode)"
  else fail "dirty tracked files skip branch but still sync memory ($report_mode)"; fi

  new_fixture
  make_task
  advance_base
  printf '%s\n' untracked > "$hub/untracked-only.txt"
  run_pull
  expect_report 'untracked files alone allow a rebase' 0 '✓ rebased onto main' '.branch.action == "rebased"'

  new_fixture
  fixture_git -C "$hub" switch -c dev/t/topic >/dev/null 2>&1
  printf '%s\n' topic > "$hub/shared.txt"
  commit_fixture "$hub" 'Conflicting topic change'
  before=$(fixture_git -C "$hub" rev-parse HEAD)
  advance_base shared.txt
  run_pull
  if report_is 1 '✗ conflict: resolve by hand; tree restored' '.branch.action == "conflict" and .branch.note == "resolve by hand; tree restored"' \
     && [ "$before" = "$(fixture_git -C "$hub" rev-parse HEAD)" ] \
     && [ -z "$(fixture_git -C "$hub" status --porcelain)" ] \
     && [ ! -e "$hub/.git/rebase-merge" ] && [ ! -e "$hub/.git/rebase-apply" ] \
     && [ ! -e "$hub/.git/MERGE_HEAD" ] && [ -f "$case_dir/sync-called" ]; then
    pass "failed rebase and merge restore the tree and still sync memory ($report_mode)"
  else fail "failed rebase and merge restore the tree and still sync memory ($report_mode)"; fi

  new_fixture
  fixture_git -C "$hub" switch -c dev/t/topic >/dev/null 2>&1
  printf '%s\n' temporary > "$hub/shared.txt"
  commit_fixture "$hub" 'Intermediate conflicting change'
  printf '%s\n' initial > "$hub/shared.txt"
  printf '%s\n' topic > "$hub/topic.txt"
  commit_fixture "$hub" 'Restore shared content and retain topic work'
  advance_base shared.txt
  run_pull
  if report_is 0 '✓ merged with main' '.branch.action == "merged"' \
     && fixture_git -C "$hub" merge-base --is-ancestor origin/main HEAD \
     && [ "$(fixture_git -C "$hub" rev-list --parents -n 1 HEAD | awk '{print NF}')" -eq 3 ]; then
    pass "merge fallback succeeds when only intermediate commits conflict ($report_mode)"
  else fail "merge fallback succeeds when only intermediate commits conflict ($report_mode)"; fi

  new_fixture
  fixture_git -C "$hub" switch -c dev/t/topic >/dev/null 2>&1
  printf '%s\n' temporary > "$hub/shared.txt"
  commit_fixture "$hub" 'Intermediate conflicting change'
  printf '%s\n' initial > "$hub/shared.txt"
  printf '%s\n' topic > "$hub/topic.txt"
  commit_fixture "$hub" 'Restore shared content and retain topic work'
  fixture_git -C "$hub" config branch.dev/t/topic.mergeOptions --no-commit
  fixture_git -C "$hub" config merge.ff only
  before=$(fixture_git -C "$hub" rev-parse HEAD)
  advance_base shared.txt
  run_pull
  if report_is 0 '✓ merged with main' '.branch.action == "merged"' \
     && fixture_git -C "$hub" merge-base --is-ancestor origin/main HEAD \
     && [ "$before" != "$(fixture_git -C "$hub" rev-parse HEAD)" ] \
     && [ "$(fixture_git -C "$hub" rev-list --parents -n 1 HEAD | awk '{print NF}')" -eq 3 ] \
     && [ ! -e "$hub/.git/MERGE_HEAD" ] && [ -z "$(fixture_git -C "$hub" status --porcelain)" ]; then
    pass "merge fallback overrides no-commit and ff-only configuration ($report_mode)"
  else fail "merge fallback overrides no-commit and ff-only configuration ($report_mode)"; fi

  new_fixture
  printf '%s\n' initial > "$hub/x.txt"
  commit_fixture "$hub" 'Add the merge fixture source'
  fixture_git -C "$hub" push origin main >/dev/null 2>&1
  fixture_git -C "$hub" switch -c dev/t/topic >/dev/null 2>&1
  printf '%s\n' task > "$hub/x.txt"
  commit_fixture "$hub" 'Create an intermediate conflict'
  printf '%s\n' base > "$hub/x.txt"
  commit_fixture "$hub" 'Converge with the incoming base content'
  fixture_git -C "$hub" config branch.dev/t/topic.mergeOptions --ff-only
  before=$(fixture_git -C "$hub" rev-parse HEAD)
  advance_base x.txt base
  run_pull
  if report_is 0 '✓ merged with main' '.branch.action == "merged"' \
     && fixture_git -C "$hub" merge-base --is-ancestor origin/main HEAD \
     && [ "$before" != "$(fixture_git -C "$hub" rev-parse HEAD)" ] \
     && [ "$(fixture_git -C "$hub" rev-list --parents -n 1 HEAD | awk '{print NF}')" -eq 3 ] \
     && [ "$(cat "$hub/x.txt")" = base ] \
     && [ -z "$(fixture_git -C "$hub" status --porcelain)" ] && [ ! -e "$hub/.git/MERGE_HEAD" ]; then
    pass "merge fallback overrides branch ff-only when the tips merge cleanly ($report_mode)"
  else fail "merge fallback overrides branch ff-only when the tips merge cleanly ($report_mode)"; fi

  new_fixture
  rm "$hub/memory"
  run_pull
  if report_is 0 '✓ up to date' '.memory.action == "up-to-date" and .memory.new_commits == 0' \
     && [ "$(readlink "$hub/memory")" = "$memory" ] \
     && { [ "$report_mode" = json ] || text_has "✓ linked $memory"; }; then
    pass "main checkout links physical sibling memory and syncs ($report_mode)"
  else fail "main checkout links physical sibling memory and syncs ($report_mode)"; fi

  new_fixture
  fixture_git -C "$hub" worktree add "$case_dir/wt" -b dev/t/wt main >/dev/null 2>&1
  before=$(fixture_git -C "$hub" rev-parse main)
  advance_base
  run_dir="$case_dir/wt"
  run_pull
  if report_is 0 '✓ rebased onto main' '.branch.action == "rebased" and .branch.name == "dev/t/wt" and .base.new_commits == 1' \
     && [ "$before" = "$(fixture_git -C "$hub" rev-parse main)" ] \
     && [ "$(fixture_git -C "$hub" branch --show-current)" = main ] \
     && [ "$(readlink "$run_dir/memory")" = "$memory" ]; then
    pass "linked worktree sync leaves checked-out main untouched and links shared memory ($report_mode)"
  else fail "linked worktree sync leaves checked-out main untouched and links shared memory ($report_mode)"; fi

  new_fixture
  advance_memory
  run_pull
  if report_is 0 '↓ 1 commits — 2 files updated' '.memory.action == "updated" and .memory.new_commits == 1
       and (.memory.files | length) == 2
       and any(.memory.files[]; .path == "handoffs/index.md" and .status == "M")
       and any(.memory.files[]; .path == "handoffs/new handoff.md" and .status == "A")' \
     && { [ "$report_mode" = json ] || { text_has 'handoffs/index.md' && text_has 'handoffs/new handoff.md (new)'; }; }; then
    pass "memory changes report commit count and added/modified files ($report_mode)"
  else fail "memory changes report commit count and added/modified files ($report_mode)"; fi

  new_fixture
  if [ "$report_mode" = json ]; then
    capture fixture_env env PULL_SYNC_MARKER="$case_dir/sync-called" STUB_SYNC_FAIL=1 bash "$hub/bin/pull.sh" --json
  else
    capture fixture_env env PULL_SYNC_MARKER="$case_dir/sync-called" STUB_SYNC_FAIL=1 bash "$hub/bin/pull.sh"
  fi
  if report_is 1 '✗ failed: sync failed' '.memory.action == "failed" and .memory.note == "sync failed" and .branch.action == "up-to-date"' \
     && grep -Fq 'stub third' "$scratch/stderr" && grep -Fq 'stub sync failed' "$scratch/stderr" \
     && ! grep -Fq 'stub second' "$scratch/stderr"; then
    pass "sync failure retains branch report and shows the last five captured lines ($report_mode)"
  else fail "sync failure retains branch report and shows the last five captured lines ($report_mode)"; fi

  new_fixture
  rm "$hub/memory"
  mv "$memory" "$case_dir/memory-away"
  run_pull
  if report_is 1 "⚠ unlinked: memory checkout not found at $memory" '.memory.action == "unlinked" and (.memory.note | startswith("memory checkout not found at "))' \
     && [ ! -e "$case_dir/sync-called" ]; then
    pass "missing memory target is reported without sync ($report_mode)"
  else fail "missing memory target is reported without sync ($report_mode)"; fi

  new_fixture
  mv "$memory" "$case_dir/memory-away"
  run_pull
  if report_is 1 "⚠ unlinked: memory checkout not found at $memory" '.memory.action == "unlinked" and (.memory.note | startswith("memory checkout not found at "))' \
     && [ -L "$hub/memory" ] && [ ! -e "$case_dir/sync-called" ]; then
    pass "dangling memory link is reported without sync ($report_mode)"
  else fail "dangling memory link is reported without sync ($report_mode)"; fi

  new_fixture
  printf '%s\n' '{"mode":"local","base_branch":"nowhere"}' > "$hub/egregore.json"
  run_pull
  expect_fatal 'unresolvable base has no stdout' 'pull: origin/nowhere not found'

  new_fixture
  fixture_git -C "$hub" switch --detach >/dev/null 2>&1
  run_pull
  if report_is 0 '⚠ skipped: detached HEAD' '.branch.name == "HEAD" and .branch.action == "skipped" and .branch.note == "detached HEAD"' \
     && [ -f "$case_dir/sync-called" ] \
     && { [ "$report_mode" = json ] || text_has 'HEAD'; }; then
    pass "detached HEAD skips branch and syncs memory ($report_mode)"
  else fail "detached HEAD skips branch and syncs memory ($report_mode)"; fi

  new_fixture
  make_task
  advance_base
  if [ "$report_mode" = json ]; then
    capture fixture_env env GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent \
      GIT_OBJECT_DIRECTORY=/nonexistent GIT_ALTERNATE_OBJECT_DIRECTORIES=/nonexistent GIT_COMMON_DIR=/nonexistent \
      PULL_SYNC_MARKER="$case_dir/sync-called" bash "$hub/bin/pull.sh" --json
  else
    capture fixture_env env GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent \
      GIT_OBJECT_DIRECTORY=/nonexistent GIT_ALTERNATE_OBJECT_DIRECTORIES=/nonexistent GIT_COMMON_DIR=/nonexistent \
      PULL_SYNC_MARKER="$case_dir/sync-called" bash "$hub/bin/pull.sh"
  fi
  expect_report 'inherited Git overrides are cleared' 0 '✓ rebased onto main' '.branch.action == "rebased" and .base.new_commits == 1'

  new_fixture
  make_task
  run_pull
  expect_report 'task already containing origin/main is up to date' 0 '✓ up to date' '.branch.action == "up-to-date" and .base.new_commits == 0'

  new_fixture
  make_task
  advance_base
  fixture_git -C "$hub" fetch origin main --quiet
  advance_memory
  fixture_git -C "$hub" config remote.origin.url "$case_dir/absent-origin.git"
  run_pull
  if report_is 1 '⚠ fetch failed — using last known origin/main' \
       '.base.action == "fetch-failed" and .branch.action == "rebased" and .base.new_commits == 0 and .memory.action == "updated"' \
     && grep -Fq 'pull: fetch failed' "$scratch/stderr" && [ -f "$case_dir/sync-called" ] \
     && [ -f "$memory/handoffs/new handoff.md" ] \
     && { [ "$report_mode" = json ] || { text_has '✓ rebased onto main' && text_has '↓ 1 commits — 2 files updated'; }; }; then
    pass "failed fetch reports failure while branch and memory updates continue ($report_mode)"
  else fail "failed fetch reports failure while branch and memory updates continue ($report_mode)"; fi

  new_fixture
  fixture_git -C "$hub" config --remove-section remote.origin
  run_pull
  if report_is 1 '⚠ fetch failed — using last known origin/main' \
       '.base.action == "fetch-failed" and .branch.action == "up-to-date" and .base.new_commits == 0' \
     && grep -Fq 'pull: fetch failed' "$scratch/stderr"; then
    pass "absent origin still uses an existing tracking ref ($report_mode)"
  else fail "absent origin still uses an existing tracking ref ($report_mode)"; fi

  new_fixture
  make_task
  fixture_git -C "$hub" push origin main:other >/dev/null 2>&1
  fixture_git -C "$hub" config remote.origin.fetch '+refs/heads/other:refs/remotes/origin/other'
  advance_base
  after=$(fixture_git -C "$case_dir/advancer" rev-parse HEAD)
  run_pull
  if report_is 0 '↓ 1 commits → synced' '.base.new_commits == 1 and .branch.action == "rebased"' \
     && [ "$after" = "$(fixture_git -C "$hub" rev-parse origin/main)" ] \
     && [ "$after" = "$(fixture_git -C "$hub" rev-parse HEAD^)" ]; then
    pass "explicit fetch refspec updates origin/main despite restricted remote configuration ($report_mode)"
  else fail "explicit fetch refspec updates origin/main despite restricted remote configuration ($report_mode)"; fi

  new_fixture
  fixture_git -C "$hub" remote remove origin
  run_pull
  expect_fatal 'absent origin and tracking ref fail with no stdout' 'pull: origin/main not found'

  new_fixture
  printf '%s\n' '{"mode":"local","base_branch":"main"}' > "$hub/egregore.json"
  commit_fixture "$hub" 'Remove memory configuration'
  run_pull
  if report_is 0 '⚠ skipped: no memory_repo configured' '.memory.action == "skipped" and .memory.note == "no memory_repo configured"' \
     && [ ! -e "$case_dir/sync-called" ]; then
    pass "missing memory_repo skips synchronization ($report_mode)"
  else fail "missing memory_repo skips synchronization ($report_mode)"; fi

  for invalid_repo in '..' 'https://x/y/..' '../../etc'; do
    new_fixture
    rm "$hub/memory"
    mkdir -p "$case_dir/etc"
    jq --arg repo "$invalid_repo" '.memory_repo = $repo' "$hub/egregore.json" > "$case_dir/config.json"
    mv "$case_dir/config.json" "$hub/egregore.json"
    commit_fixture "$hub" 'Configure invalid memory repository'
    run_pull
    if report_is 1 '⚠ unlinked: invalid memory_repo' '.memory.action == "unlinked" and .memory.note == "invalid memory_repo"' \
       && [ ! -e "$hub/memory" ] && [ ! -L "$hub/memory" ] && [ ! -e "$case_dir/sync-called" ]; then
      pass "invalid memory repository $invalid_repo cannot create a link ($report_mode)"
    else fail "invalid memory repository $invalid_repo cannot create a link ($report_mode)"; fi
  done

  new_fixture
  rm "$hub/memory"
  mkdir "$case_dir/elsewhere"
  mv "$memory" "$case_dir/elsewhere/memory-fixture"
  ln -s "$case_dir/elsewhere/memory-fixture" "$memory"
  run_pull
  if report_is 1 '⚠ unlinked: invalid memory_repo' '.memory.action == "unlinked" and .memory.note == "invalid memory_repo"' \
     && [ ! -e "$hub/memory" ] && [ ! -L "$hub/memory" ] && [ ! -e "$case_dir/sync-called" ]; then
    pass "sibling memory symlink resolving outside the checkout parent is refused ($report_mode)"
  else fail "sibling memory symlink resolving outside the checkout parent is refused ($report_mode)"; fi

  new_fixture
  rm "$hub/memory"
  mkdir "$hub/memory"
  run_pull
  if report_is 1 '⚠ skipped: memory is not a git checkout' '.memory.action == "skipped" and .memory.note == "memory is not a git checkout"' \
     && [ ! -e "$case_dir/sync-called" ]; then
    pass "ordinary memory directory cannot inherit the framework Git checkout ($report_mode)"
  else fail "ordinary memory directory cannot inherit the framework Git checkout ($report_mode)"; fi

  new_fixture
  rm "$hub/bin/agent.sh"
  commit_fixture "$hub" 'Remove Runtime bridge'
  run_pull
  expect_report 'missing Runtime bridge is reported' 1 '✗ failed: bin/agent.sh missing' '.memory.action == "failed" and .memory.note == "bin/agent.sh missing"'

  new_fixture
  printf '%s\n' local > "$hub/local-main.txt"
  commit_fixture "$hub" 'Diverge local main'
  advance_base
  before=$(fixture_git -C "$hub" rev-parse HEAD)
  run_pull
  if report_is 0 '⚠ skipped: diverged from origin/main' '.branch.action == "skipped" and .branch.note == "diverged from origin/main"' \
     && [ "$before" = "$(fixture_git -C "$hub" rev-parse HEAD)" ] && [ -f "$case_dir/sync-called" ]; then
    pass "diverged base branch remains untouched ($report_mode)"
  else fail "diverged base branch remains untouched ($report_mode)"; fi

  new_fixture
  fixture_git -C "$hub" switch -c release/topic >/dev/null 2>&1
  advance_base
  run_pull
  expect_report 'other branch names skip rebasing' 0 '⚠ skipped: not a task branch' '.branch.action == "skipped" and .branch.note == "not a task branch"'

  new_fixture
  if [ "$report_mode" = json ]; then
    capture fixture_run "$hub" bin/pull.sh --json --unexpected
  else
    capture fixture_run "$hub" bin/pull.sh --unexpected
  fi
  expect_fatal 'unsupported arguments fail with no stdout' 'pull:'

  new_fixture
  rm -rf "$hub/.git"
  run_pull
  expect_fatal 'non-checkout fails with no stdout' 'pull:'

  new_fixture
  printf '%s\n' '{"base_branch":42}' > "$hub/egregore.json"
  run_pull
  expect_fatal 'base resolver errors propagate with no stdout' 'config: base_branch'

  new_fixture
  fixture_git -C "$hub" update-ref -d refs/remotes/origin/main
  run_pull
  expect_report 'initial fetch with no prior tracking ref counts zero new commits' 0 '✓ up to date' '.base.new_commits == 0 and .branch.action == "up-to-date"'
done

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
