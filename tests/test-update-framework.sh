#!/usr/bin/env bash
# Local upstream fixtures exercise the overlay without fetching the network or
# changing this repository. Linked-worktree operations below are fixture-only.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/egregore-update-framework.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0
check() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL: %s — expected %s, got %s\n' "$1" "$2" "$3" >&2
    exit 1
  fi
  PASS=$((PASS + 1))
  printf '  ✓ %s\n' "$1"
}
init_repo() {
  git init --quiet --initial-branch=develop "$1"
  git -C "$1" config user.name 'Framework Fixture'
  git -C "$1" config user.email 'framework@example.test'
}
expect_failure() {
  local label="$1" expected="$2" status=0
  shift 2
  "$@" >"$TMP/stdout" 2>"$TMP/stderr" || status=$?
  check "$label status" "$expected" "$status"
  check "$label prints no stdout" '' "$(cat "$TMP/stdout")"
  check "$label reports one stderr line" 1 "$(awk 'END { print NR }' "$TMP/stderr")"
}

echo test-update-framework
upstream="$TMP/upstream"
target="$TMP/target's checkout"
linked="$TMP/other worktree"
init_repo "$upstream"
git -C "$upstream" branch -m main
init_repo "$target"

# The retired commands directory is intentionally absent from upstream. All
# other framework roots must update; unrelated and instance-owned files stay.
for path in bin .claude/skills .claude/hooks .claude/context .claude/agents .pi .prime loom skills; do
  mkdir -p "$upstream/$path" "$target/$path"
  printf 'upstream %s\n' "$path" >"$upstream/$path/fixture.txt"
  printf 'downstream %s\n' "$path" >"$target/$path/fixture.txt"
done
printf 'upstream CLAUDE\n' >"$upstream/CLAUDE.md"
printf 'downstream CLAUDE\n' >"$target/CLAUDE.md"
printf 'instance config\n' >"$target/egregore.json"
printf 'unrelated\n' >"$target/README.md"
mkdir -p "$target/.claude/commands"
printf 'local command\n' >"$target/.claude/commands/local.md"
git -C "$upstream" add .
git -C "$upstream" commit --quiet -m 'Upstream framework'
git -C "$target" add .
git -C "$target" commit --quiet -m 'Downstream framework'
git -C "$target" remote add upstream "$upstream"
git -C "$target" fetch --quiet upstream main
git -C "$target" worktree add --quiet -b feature/unrelated "$linked"
before_head=$(git -C "$target" rev-parse HEAD)
before_linked=$(git -C "$linked" status --porcelain)

# Contradictory merge/rebase preferences cannot affect a path checkout.
git -C "$target" config pull.rebase true
git -C "$target" config pull.ff only
git -C "$target" config branch.develop.rebase false
git -C "$target" config merge.ff false
git -C "$target" config rebase.autoStash true
(
  cd "$linked"
  GIT_DIR="$linked/.git" GIT_WORK_TREE="$linked" GIT_INDEX_FILE="$TMP/foreign-index" \
    bash "$ROOT/bin/update-framework.sh" --main-dir "$target"
) >"$TMP/stdout" 2>"$TMP/stderr"
check 'successful overlay prints no stdout' '' "$(cat "$TMP/stdout")"
check 'missing upstream path is reported exactly once' \
  'update-framework: skipped .claude/commands/ (absent from upstream/main or checkout failed)' \
  "$(cat "$TMP/stderr")"
for path in bin .claude/skills .claude/hooks .claude/context .claude/agents .pi .prime loom skills; do
  check "$path receives upstream content" "upstream $path" "$(cat "$target/$path/fixture.txt")"
  check "$path remains unchanged in the other worktree" "downstream $path" "$(cat "$linked/$path/fixture.txt")"
done
check 'CLAUDE.md receives upstream content' 'upstream CLAUDE' "$(cat "$target/CLAUDE.md")"
check 'missing upstream root preserves the downstream file' 'local command' "$(cat "$target/.claude/commands/local.md")"
check 'instance configuration stays unchanged' 'instance config' "$(cat "$target/egregore.json")"
check 'unrelated files stay unchanged' unrelated "$(cat "$target/README.md")"
check 'target branch stays selected' develop "$(git -C "$target" branch --show-current)"
check 'target HEAD does not move' "$before_head" "$(git -C "$target" rev-parse HEAD)"
check 'other worktree branch stays selected' feature/unrelated "$(git -C "$linked" branch --show-current)"
check 'other worktree HEAD does not move' "$before_head" "$(git -C "$linked" rev-parse HEAD)"
check 'other worktree index and working tree stay unchanged' "$before_linked" "$(git -C "$linked" status --porcelain)"
check 'inherited index override is ignored' false "$([ -e "$TMP/foreign-index" ] && echo true || echo false)"

# A directory inside the requested checkout uses that checkout's root paths.
root_overlay_tree=$(git -C "$target" write-tree)
git -C "$target" checkout HEAD -- .
bash "$ROOT/bin/update-framework.sh" --main-dir "$target/bin" >"$TMP/stdout" 2>"$TMP/stderr"
check 'nested target produces the same tree as the checkout root' \
  "$root_overlay_tree" "$(git -C "$target" write-tree)"
check 'nested target working tree matches the staged overlay' '' "$(git -C "$target" diff --name-only)"
check 'nested target reports only the same absent upstream path' \
  'update-framework: skipped .claude/commands/ (absent from upstream/main or checkout failed)' \
  "$(cat "$TMP/stderr")"

# Without --main-dir the command operates on cwd, even when the script itself
# lives elsewhere. It never discovers or redirects to the common main checkout.
(
  cd "$linked"
  bash "$ROOT/bin/update-framework.sh"
) >"$TMP/stdout" 2>"$TMP/stderr"
check 'default target is the current worktree' 'upstream bin' "$(cat "$linked/bin/fixture.txt")"
check 'default overlay still leaves HEAD selected' feature/unrelated "$(git -C "$linked" branch --show-current)"
check 'default overlay does not move HEAD' "$before_head" "$(git -C "$linked" rev-parse HEAD)"

empty="$TMP/no-upstream"
init_repo "$empty"
printf 'keep\n' >"$empty/CLAUDE.md"
git -C "$empty" add .
git -C "$empty" commit --quiet -m 'No upstream'
empty_head=$(git -C "$empty" rev-parse HEAD)
empty_root=$(git -C "$empty" rev-parse --show-toplevel)
expect_failure 'absent upstream' 1 bash "$ROOT/bin/update-framework.sh" --main-dir "$empty"
check 'absent upstream explanation' \
  "update-framework: upstream remote is missing in $empty_root" "$(cat "$TMP/stderr")"
git -C "$empty" remote add upstream "$upstream"
expect_failure 'unfetched upstream main' 1 bash "$ROOT/bin/update-framework.sh" --main-dir "$empty"
check 'unfetched upstream explanation' \
  "update-framework: upstream/main is missing in $empty_root; fetch upstream main first" "$(cat "$TMP/stderr")"

no_main="$TMP/upstream-without-main"
init_repo "$no_main"
printf 'no main\n' >"$no_main/CLAUDE.md"
git -C "$no_main" add .
git -C "$no_main" commit --quiet -m 'Develop only'
git -C "$empty" remote set-url upstream "$no_main"
git -C "$empty" fetch --quiet upstream
expect_failure 'upstream has no main' 1 bash "$ROOT/bin/update-framework.sh" --main-dir "$empty"
check 'failed prerequisites preserve HEAD' "$empty_head" "$(git -C "$empty" rev-parse HEAD)"
check 'failed prerequisites preserve working tree and index' '' "$(git -C "$empty" status --porcelain)"
expect_failure 'missing target directory' 1 bash "$ROOT/bin/update-framework.sh" --main-dir "$TMP/missing"
expect_failure 'non-repository directory' 1 bash "$ROOT/bin/update-framework.sh" --main-dir "$TMP"
expect_failure 'unknown option' 2 bash "$ROOT/bin/update-framework.sh" --unknown
expect_failure 'missing option value' 2 bash "$ROOT/bin/update-framework.sh" --main-dir
expect_failure 'empty option value' 2 bash "$ROOT/bin/update-framework.sh" --main-dir ''
expect_failure 'extra argument' 2 bash "$ROOT/bin/update-framework.sh" --main-dir "$empty" extra

printf '%s passed, 0 failed\n' "$PASS"
