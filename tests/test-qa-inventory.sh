#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# Isolated integration tests for the executable QA inventory and base resolver.
# Usage: bash tests/test-qa-inventory.sh
# Exit 0 = all cases passed, Exit 1 = a case failed

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
scratch=$(mktemp -d /tmp/test-qa-inventory.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home"

# Never let a calling worktree's Git overrides reach fixture operations or scans.
fixture_env() {
  HOME="$scratch/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
      -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR "$@"
}
fixture_git() { fixture_env git "$@"; }
fixture_run() (
  cd "$1"
  shift
  fixture_env bash "$@"
)
scan() { fixture_run "$scratch/topic" bin/qa-inventory.sh "$@"; }
base() { fixture_run "$scratch/topic" bin/base-branch.sh "$@"; }
capture() {
  EXIT_CODE=0
  OUTPUT=$("$@" 2> "$scratch/stderr") || EXIT_CODE=$?
}
json_is() { printf '%s\n' "$OUTPUT" | jq -e "$1" >/dev/null; }
text_has() { grep -Fq -- "$1" <<< "$OUTPUT"; }
configure_author() {
  fixture_git -C "$1" config --local user.name 'QA Fixture'
  fixture_git -C "$1" config --local user.email 'qa@example.invalid'
  fixture_git -C "$1" config --local core.hooksPath /dev/null
  fixture_git -C "$1" config --local commit.gpgsign false
}

echo '=== qa-inventory.sh tests ==='
fixture_git init --bare --initial-branch=main "$scratch/origin.git" >/dev/null
fixture_git clone "$scratch/origin.git" "$scratch/topic" >/dev/null 2>&1
configure_author "$scratch/topic"
mkdir -p "$scratch/topic/bin/lib" "$scratch/topic/docs" "$scratch/topic/tests"
cp "$SCRIPT_DIR/bin/qa-inventory.sh" "$SCRIPT_DIR/bin/base-branch.sh" "$scratch/topic/bin/"
cp "$SCRIPT_DIR/bin/lib/config.sh" "$SCRIPT_DIR/bin/lib/generated-trees.sh" \
  "$SCRIPT_DIR/bin/lib/repo-paths.sh" "$scratch/topic/bin/lib/"
printf '%s\n' '{"mode":"local","base_branch":"main"}' > "$scratch/topic/egregore.json"
printf '%s\n' before > "$scratch/topic/docs/keep.md"
printf '%s\n' before > "$scratch/topic/docs/gone.md"
mkdir -p "$scratch/topic/docs/a" "$scratch/topic/docs/b" "$scratch/topic/.claude/skills/probe"
printf '%s\n' before > "$scratch/topic/docs/a/SKILL.md"
printf '%s\n' before > "$scratch/topic/docs/b/SKILL.md"
printf '%s\n' 'Fixture skill' > "$scratch/topic/.claude/skills/probe/SKILL.md"
# A suite without a trailing newline must still be found by reference.
printf '# keep.md' > "$scratch/topic/tests/test-keep.sh"
printf '# docs/gone.md' > "$scratch/topic/tests/test-gone.sh"
printf 'SKILL.md' > "$scratch/topic/tests/test-generic.sh"
printf '# docs/a/SKILL.md' > "$scratch/topic/tests/test-exact-skill.sh"
printf '# .codex/skills/probe/SKILL.md .pi/skills/probe/SKILL.md' > "$scratch/topic/tests/test-skill-views.sh"
fixture_git -C "$scratch/topic" add .
fixture_git -C "$scratch/topic" commit -qm 'Fixture baseline'
fixture_git -C "$scratch/topic" push -u origin main >/dev/null 2>&1
fixture_git -C "$scratch/topic" switch -c topic >/dev/null 2>&1
printf '%s\n' changed > "$scratch/topic/docs/keep.md"
printf '%s\n' changed > "$scratch/topic/docs/a/SKILL.md"
rm "$scratch/topic/docs/gone.md"
printf '%s\n' new > "$scratch/topic/docs/new.md"
printf '# docs/new.md' > "$scratch/topic/tests/test-topic-only.sh"
mkdir -p "$scratch/topic/packages/create-egregore/runtime/claude"
printf '%s\n' generated > "$scratch/topic/packages/create-egregore/runtime/claude/x.md"
fixture_git -C "$scratch/topic" add .
fixture_git -C "$scratch/topic" commit -qm 'Fixture topic change'
fixture_git -C "$scratch/topic" push -u origin topic >/dev/null 2>&1
topic_oid=$(fixture_git -C "$scratch/topic" rev-parse HEAD)
topic_merge_base=$(fixture_git -C "$scratch/topic" merge-base main HEAD)

fixture_git clone "$scratch/origin.git" "$scratch/advancer" >/dev/null 2>&1
configure_author "$scratch/advancer"
printf '%s\n' base-only > "$scratch/advancer/docs/base-only.md"
fixture_git -C "$scratch/advancer" add docs/base-only.md
fixture_git -C "$scratch/advancer" commit -qm 'Advance main independently'
fixture_git -C "$scratch/advancer" push origin main >/dev/null 2>&1
fixture_git -C "$scratch/topic" fetch origin >/dev/null 2>&1
printf 'untracked without a trailing newline' > "$scratch/topic/docs/untracked.sh"

# 1. Configuration is authoritative and every failure has empty stdout.
capture base
if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = main ]; then pass 'configured integration branch'; else fail 'configured integration branch'; fi
capture base --resolve
if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = origin/main ]; then pass 'remote comparison ref preferred'; else fail 'remote comparison ref preferred'; fi
printf '%s\n' '{"base_branch":"nowhere"}' > "$scratch/config.json"
capture fixture_env env CONFIG="$scratch/config.json" bash "$scratch/topic/bin/base-branch.sh" --resolve
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] \
   && grep -Fxq 'base-branch: cannot resolve origin/nowhere or nowhere; fetch it or pass a ref explicitly' "$scratch/stderr"; then
  pass 'missing base fails loudly with exit 2'
else fail 'missing base fails loudly with exit 2'; fi
printf '%s\n' '{"base_branch":42}' > "$scratch/config.json"
capture fixture_env env CONFIG="$scratch/config.json" bash "$scratch/topic/bin/base-branch.sh"
if [ "$EXIT_CODE" -eq 1 ] && [ -z "$OUTPUT" ] && grep -Fq 'config: base_branch' "$scratch/stderr"; then
  pass 'invalid configuration propagates with no stdout'
else fail 'invalid configuration propagates with no stdout'; fi
capture fixture_env env CONFIG="$scratch/missing.json" bash "$scratch/topic/bin/base-branch.sh"
if [ "$EXIT_CODE" -eq 1 ] && [ -z "$OUTPUT" ] && grep -Fq 'config: cannot read' "$scratch/stderr"; then
  pass 'missing configuration never defaults silently'
else fail 'missing configuration never defaults silently'; fi

# 2–3. Committed, staged, and unstaged content is one merge-base comparison.
capture scan
if [ "$EXIT_CODE" -eq 0 ] && text_has 'Base: origin/main (merge-base ' \
   && text_has 'M docs/keep.md' && text_has 'D docs/gone.md' && text_has 'A docs/new.md' \
   && text_has '? docs/untracked.sh (untracked)' && text_has 'Changed (6; 1 generated skipped):' \
   && text_has 'tests/test-keep.sh (docs/keep.md)' && ! text_has 'base-only.md' && ! text_has 'tests/test-gone.sh'; then
  pass 'working-tree inventory retains deletions and untracked files, excludes generated and base-only paths'
else fail 'working-tree text inventory'; fi
capture scan --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.mode == "working-tree" and (.changed | length) == 6
  and .generated_skipped == ["packages/create-egregore/runtime/claude/x.md"]
  and .affected_skills == null and (.affected_skills_note | contains("no distribution engine"))
  and (.candidate_suites | map(.suite)) == ["tests/test-exact-skill.sh", "tests/test-keep.sh", "tests/test-topic-only.sh"]' \
  && json_is ".base.merge_base == \"$topic_merge_base\""; then
  pass 'JSON inventory uses merge-base and reports the absent distribution engine'
else fail 'working-tree JSON inventory'; fi

# Local changes must appear even when the corresponding files were not committed on topic.
printf '%s\n' staged > "$scratch/topic/docs/staged.md"
fixture_git -C "$scratch/topic" add docs/staged.md
printf '%s\n' unstaged >> "$scratch/topic/tests/test-keep.sh"
capture scan --json
if [ "$EXIT_CODE" -eq 0 ] && json_is 'any(.changed[]; .path == "docs/staged.md" and .status == "A")
  and any(.changed[]; .path == "tests/test-keep.sh" and .status == "M")'; then
  pass 'staged and unstaged paths join the same changed set'
else fail 'staged and unstaged changed set'; fi
fixture_git -C "$scratch/topic" restore --staged docs/staged.md
rm "$scratch/topic/docs/staged.md"
fixture_git -C "$scratch/topic" restore tests/test-keep.sh

# 4–5. A different checkout uses the requested branch, never its working files.
fixture_git clone "$scratch/origin.git" "$scratch/main" >/dev/null 2>&1
capture fixture_run "$scratch/main" bin/qa-inventory.sh --branch topic --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.mode == "branch" and .head.ref == "origin/topic"
  and (.changed | map(.path)) == ["docs/a/SKILL.md", "docs/gone.md", "docs/keep.md", "docs/new.md", "tests/test-topic-only.sh"]
  and (.changed | map(.status)) == ["M", "D", "M", "A", "A"] and (.generated_skipped | length) == 1'; then
  pass 'branch inventory from main uses origin/topic without untracked or base-only paths'
else fail 'branch inventory from main'; fi
if [ "$EXIT_CODE" -eq 0 ] && [ ! -e "$scratch/main/tests/test-topic-only.sh" ] \
   && json_is 'any(.candidate_suites[]; .suite == "tests/test-topic-only.sh" and .matches == ["docs/new.md"])
     and .coverage_note == null'; then
  pass 'branch suite search reads committed content absent from the local checkout'
else fail 'branch-only suite coverage'; fi
# Local edits must not alter the committed suite corpus selected by --branch.
printf '# docs/new.md' > "$scratch/main/tests/test-local-only.sh"
capture fixture_run "$scratch/main" bin/qa-inventory.sh --branch topic --json
if [ "$EXIT_CODE" -eq 0 ] && json_is 'all(.candidate_suites[]; .suite != "tests/test-local-only.sh")'; then
  pass 'requested branch ignores local-only suite content'
else fail 'local content leaked into branch candidates'; fi
rm "$scratch/main/tests/test-local-only.sh"
capture scan --branch nope
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] \
   && grep -Fxq 'qa-inventory: branch nope not found locally or on origin' "$scratch/stderr"; then
  pass 'missing branch exits 2 and names the branch'
else fail 'missing branch error'; fi

# 6. Explicit paths are the entire selected set, including missing inputs.
capture scan docs/keep.md docs/absent.md nowhere/absent.md
if [ "$EXIT_CODE" -eq 0 ] && text_has 'E docs/keep.md' && text_has 'X docs/absent.md (missing)' \
   && text_has 'X nowhere/absent.md (missing)' \
   && text_has 'Changed (3; 0 generated skipped):' && ! text_has docs/new.md; then
  pass 'explicit existing and missing paths'
else fail 'explicit paths inventory'; fi

# G1–G2. Relative selection identity is lexical; containment stays physical.
capture scan ./docs/gone.md
if [ "$EXIT_CODE" -eq 0 ] && text_has 'X docs/gone.md (missing)' \
   && text_has 'tests/test-gone.sh (docs/gone.md)'; then
  pass 'deleted relative selection drops its dot prefix before reference matching'
else fail 'deleted relative selection identity'; fi
capture scan docs//keep.md docs/./keep.md docs/keep.md/. --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.changed == [{path:"docs/keep.md",status:"E",note:null}]
  and .candidate_suites == [{suite:"tests/test-keep.sh",matches:["docs/keep.md"]}]'; then
  pass 'repeated separators and dot components deduplicate to one selected entry'
else fail 'lexical relative selection normalization'; fi
capture scan ./nowhere//absent.md/. --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.changed == [{path:"nowhere/absent.md",status:"X",note:"missing"}]'; then
  pass 'missing parent directories retain the normalized missing entry'
else fail 'missing parent normalization'; fi
ln -s keep.md "$scratch/topic/docs/current.md"
printf '# docs/current.md' > "$scratch/topic/tests/test-current.sh"
capture scan docs/current.md ./docs//current.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.changed == [{path:"docs/current.md",status:"E",note:null}]
  and .candidate_suites == [{suite:"tests/test-current.sh",matches:["docs/current.md"]}]'; then
  pass 'internal relative symlink keeps its selected name and reference candidates'
else fail 'internal symlink selection identity'; fi
capture scan "$scratch/topic/docs/current.md" docs/a/../current.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.changed == [{path:"docs/keep.md",status:"E",note:null}]'; then
  pass 'absolute and parent-step selections still use physical-to-relative conversion'
else fail 'physical selection conversion'; fi
rm "$scratch/topic/docs/current.md" "$scratch/topic/tests/test-current.sh"

# Generic basenames cannot substitute for the full path, but unique ones can.
capture scan docs/a/SKILL.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.candidate_suites ==
  [{suite:"tests/test-exact-skill.sh",matches:["docs/a/SKILL.md"]}]'; then
  pass 'duplicate tracked basenames exclude generic suites while preserving full-path matches'
else fail 'duplicate basename candidate filtering'; fi
capture scan docs/keep.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.candidate_suites ==
  [{suite:"tests/test-keep.sh",matches:["docs/keep.md"]}]'; then
  pass 'unique tracked basename matches a basename-only suite'
else fail 'unique tracked basename candidate'; fi
capture scan .claude/skills/probe/SKILL.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.candidate_suites ==
  [{suite:"tests/test-runtime-skill-migration.sh",matches:["skill or bin change"]},
   {suite:"tests/test-skill-views.sh",matches:[".claude/skills/probe/SKILL.md"]}]'; then
  pass 'skill-directory pattern finds other runtime views without generic SKILL.md matches'
else fail 'cross-runtime skill-directory candidate'; fi
mkdir -p "$scratch/topic/docs/untracked-copy"
printf '%s\n' untracked > "$scratch/topic/docs/untracked-copy/keep.md"
capture scan docs/untracked-copy/keep.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.candidate_suites == []'; then
  pass 'untracked basename colliding with a tracked file does not match generic references'
else fail 'untracked basename collision'; fi
rm "$scratch/topic/docs/untracked-copy/keep.md"

# 7. PATH fixtures prove both gh delivery and absence without depending on the host.
mkdir -p "$scratch/no-gh" "$scratch/with-gh"
for command in bash env dirname git jq mktemp rm cat grep readlink; do
  ln -s "$(command -v "$command")" "$scratch/no-gh/$command"
done
cat > "$scratch/with-gh/gh" <<'EOF'
#!/bin/bash
if [ -n "${QA_PR_ERROR:-}" ]; then printf '%s\n' "$QA_PR_ERROR" >&2; exit 1; fi
if [ "$*" != 'pr view 1 --json baseRefName,headRefName,headRefOid,files' ]; then
  echo 'unexpected gh arguments' >&2
  exit 1
fi
cat "$QA_PR_RESPONSE"
EOF
chmod +x "$scratch/with-gh/gh"
jq -n --arg oid "$topic_oid" '{baseRefName:"main",headRefName:"topic",headRefOid:$oid,
  files:[{path:"docs/keep.md"},{path:"packages/create-egregore/runtime/claude/x.md"}]}' > "$scratch/pr.json"
QA_PR_RESPONSE="$scratch/pr.json"
export QA_PR_RESPONSE
capture fixture_env env PATH="$scratch/with-gh:$scratch/no-gh" bash "$scratch/topic/bin/qa-inventory.sh" --pr 1 --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.mode == "pr" and .base.ref == "origin/main"
  and .changed == [{path:"docs/keep.md",status:"P",note:null}] and (.generated_skipped | length) == 1' \
  && json_is ".head.description == \"topic@${topic_oid:0:8}\""; then
  pass 'PR inventory consumes gh file paths and excludes local changes'
else fail 'PR JSON inventory'; fi
jq '.files += [{path:"docs/new.md"}]' "$scratch/pr.json" > "$scratch/topic-pr.json"
capture fixture_env env PATH="$scratch/with-gh:$scratch/no-gh" QA_PR_RESPONSE="$scratch/topic-pr.json" \
  bash "$scratch/main/bin/qa-inventory.sh" --pr 1 --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.coverage_note == null
  and any(.candidate_suites[]; .suite == "tests/test-topic-only.sh" and .matches == ["docs/new.md"])'; then
  pass 'locally available PR head uses its committed suite corpus'
else fail 'PR committed suite coverage'; fi
capture fixture_env env PATH="$scratch/with-gh:$scratch/no-gh" bash "$scratch/topic/bin/qa-inventory.sh" --pr 1
if [ "$EXIT_CODE" -eq 0 ] && text_has "Head: topic@${topic_oid:0:8}"; then
  pass 'PR text head includes the eight-character oid'
else fail 'PR text head'; fi
capture fixture_env env PATH="$scratch/no-gh" bash "$scratch/topic/bin/qa-inventory.sh" --pr 1
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && grep -Fq gh "$scratch/stderr"; then
  pass 'missing gh exits 2 with no inventory'
else fail 'missing gh error'; fi
capture fixture_env env PATH="$scratch/with-gh:$scratch/no-gh" QA_PR_ERROR='gh: fixture PR not found' \
  bash "$scratch/topic/bin/qa-inventory.sh" --pr 1
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && grep -Fxq 'gh: fixture PR not found' "$scratch/stderr"; then
  pass 'gh error passes through stderr with exit 2'
else fail 'gh failure propagation'; fi
jq '.baseRefName = "remote-base" | .headRefOid = "0123456789012345678901234567890123456789"' \
  "$scratch/pr.json" > "$scratch/remote-pr.json"
capture fixture_env env PATH="$scratch/with-gh:$scratch/no-gh" QA_PR_RESPONSE="$scratch/remote-pr.json" \
  bash "$scratch/topic/bin/qa-inventory.sh" --pr 1
if [ "$EXIT_CODE" -eq 0 ] && text_has 'Base: remote-base (remote only) (merge-base unavailable)' \
   && text_has 'Head: topic@01234567' \
   && text_has 'Coverage: suites and skills computed from the local checkout; requested head 0123456789012345678901234567890123456789 is not fetched' \
   && grep -Fxq 'Coverage: suites and skills computed from the local checkout; requested head 0123456789012345678901234567890123456789 is not fetched' "$scratch/stderr"; then
  pass 'remote-only PR reports unavailable ancestry without fetching'
else fail 'remote-only PR inventory'; fi
capture fixture_env env PATH="$scratch/with-gh:$scratch/no-gh" QA_PR_RESPONSE="$scratch/remote-pr.json" \
  bash "$scratch/topic/bin/qa-inventory.sh" --pr 1 --base main --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.base.ref == "main" and .base.merge_base == null
  and .coverage_note == "suites and skills computed from the local checkout; requested head 0123456789012345678901234567890123456789 is not fetched"'; then
  pass 'explicit base overrides the PR base while unavailable ancestry stays null'
else fail 'PR base override'; fi

# 8–10. Empty arrays, unresolved refs, and no origin all have explicit contracts.
capture fixture_run "$scratch/main" bin/qa-inventory.sh
if [ "$EXIT_CODE" -eq 0 ] && text_has 'Nothing to QA.' && text_has 'Base: origin/main' && text_has 'Head: main'; then
  pass 'clean main prints Nothing to QA'
else fail 'empty text inventory'; fi
capture fixture_run "$scratch/main" bin/qa-inventory.sh --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.changed == [] and .candidate_suites == []'; then
  pass 'empty JSON inventory is valid'
else fail 'empty JSON inventory'; fi
capture scan --base nope
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && grep -Fq 'base nope not found' "$scratch/stderr"; then
  pass 'missing explicit base exits 2'
else fail 'explicit base error'; fi
rm "$scratch/topic/docs/untracked.sh"
capture scan --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '(.changed | length) == 5 and all(.changed[]; .status != "?")'; then
  pass 'empty untracked list is safe under set -u'
else fail 'set -u empty untracked list'; fi
fixture_git -C "$scratch/main" remote remove origin
capture fixture_run "$scratch/main" bin/base-branch.sh --resolve
if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = main ]; then pass 'no origin resolves the local base'; else fail 'no origin local base'; fi
capture fixture_run "$scratch/main" bin/qa-inventory.sh --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.base.ref == "main" and .changed == []'; then
  pass 'inventory works without an origin remote'
else fail 'inventory without origin'; fi

# Product scripts must clear repository overrides themselves, without fixture_env.
capture scan --json
expected_inventory="$OUTPUT"
capture env HOME="$scratch/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_DIR="$scratch/main/.git" GIT_WORK_TREE="$scratch/main" GIT_INDEX_FILE="$scratch/main/.git/index" \
  GIT_OBJECT_DIRECTORY="$scratch/main/.git/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$scratch/main/.git/objects" \
  GIT_COMMON_DIR="$scratch/main/.git" bash "$scratch/topic/bin/qa-inventory.sh" --json
if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = "$expected_inventory" ]; then
  pass 'direct inventory invocation ignores all six inherited repository overrides'
else fail 'direct inventory repository isolation'; fi
capture env HOME="$scratch/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_DIR="$scratch/main/.git" GIT_WORK_TREE="$scratch/main" GIT_INDEX_FILE="$scratch/main/.git/index" \
  GIT_OBJECT_DIRECTORY="$scratch/main/.git/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$scratch/main/.git/objects" \
  GIT_COMMON_DIR="$scratch/main/.git" bash "$scratch/topic/bin/base-branch.sh" --resolve
if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = origin/main ]; then
  pass 'direct base resolver ignores all six inherited repository overrides'
else fail 'direct base resolver repository isolation'; fi
printf '%s\n' '{"base_branch":"nowhere"}' > "$scratch/config.json"
capture fixture_env env CONFIG="$scratch/config.json" bash "$scratch/main/bin/qa-inventory.sh"
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && grep -Fq 'cannot resolve origin/nowhere or nowhere' "$scratch/stderr"; then
  pass 'missing default base propagates the wrapper error'
else fail 'missing default base error'; fi

# Spaces, EOF, and outside paths are preserved without inspecting outside content.
printf 'space file without a trailing newline' > "$scratch/topic/docs/with spaces.md"
printf '# with spaces.md' > "$scratch/topic/tests/test-space.sh"
capture scan 'docs/with spaces.md' --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.changed == [{path:"docs/with spaces.md",status:"E",note:null}]
  and .candidate_suites == [{suite:"tests/test-space.sh",matches:["docs/with spaces.md"]}]'; then
  pass 'spaces and no trailing newline survive explicit paths and basename matching'
else fail 'spaces or final line handling'; fi
capture scan --json
if [ "$EXIT_CODE" -eq 0 ] && json_is 'any(.changed[]; .path == "docs/with spaces.md" and .status == "?")'; then
  pass 'NUL-delimited Git inventory preserves spaces in untracked paths'
else fail 'untracked spaces'; fi
printf 'must never be read' > "$scratch/outside.md"
chmod 000 "$scratch/outside.md"
ln -s "$scratch/outside.md" "$scratch/topic/docs/outside-link.md"
capture scan ../outside.md "$scratch/outside.md" docs/outside-link.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '(.changed | length) == 3
  and all(.changed[]; .status == "X" and .note == "outside repository") and .candidate_suites == []'; then
  pass 'relative, absolute, and symlink outside paths are listed without access'
else fail 'outside path boundary'; fi
capture scan ../outside.md
if [ "$EXIT_CODE" -eq 0 ] && text_has 'X ../outside.md (outside repository)'; then
  pass 'outside path text note is explicit'
else fail 'outside path text note'; fi
chmod 644 "$scratch/outside.md"

# Suite symlinks and physically external suite directories must never reach grep.
printf '# docs/keep.md' > "$scratch/external-suite.sh"
ln -s "$scratch/external-suite.sh" "$scratch/topic/tests/escape.sh"
capture scan docs/keep.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suite_paths_skipped == 1 and .candidate_suites ==
  [{suite:"tests/test-keep.sh",matches:["docs/keep.md"]}]' \
  && grep -Fxq 'qa-inventory: skipped 1 suite path(s) outside the repository' "$scratch/stderr"; then
  pass 'symlinked suite is counted and excluded without reading its content'
else fail 'suite symlink boundary'; fi
rm "$scratch/topic/tests/escape.sh"
mkdir -p "$scratch/external/subdir"
printf '# docs/keep.md\nprintf ran > "%s/external/ran"\nexit 99\n' "$scratch" > "$scratch/external/outside.sh"
ln -s "$scratch/external/subdir" "$scratch/topic/tests/jump"
ln -s jump/../outside.sh "$scratch/topic/tests/test-jump.sh"
capture scan docs/keep.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suite_paths_skipped == 1 and .candidate_suites ==
  [{suite:"tests/test-keep.sh",matches:["docs/keep.md"]}]' \
  && grep -Fxq 'qa-inventory: skipped 1 suite path(s) outside the repository' "$scratch/stderr" \
  && [ ! -e "$scratch/external/ran" ]; then
  pass 'symlink plus parent traversal is excluded and counted in the suite corpus'
else fail 'symlink plus parent traversal corpus boundary'; fi
capture scan tests/test-jump.sh --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.changed == [{path:"tests/test-jump.sh",status:"X",note:"outside repository"}]
  and .candidate_suites == []'; then
  pass 'explicit symlink plus parent traversal uses physical containment'
else fail 'explicit symlink plus parent traversal boundary'; fi
rm "$scratch/topic/tests/test-jump.sh" "$scratch/topic/tests/jump"
mkdir -p "$scratch/external-suites"
printf '// docs/keep.md' > "$scratch/external-suites/probe.mjs"
ln -s "$scratch/external-suites" "$scratch/topic/bin/tests"
capture scan docs/keep.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.suite_paths_skipped == 1 and .candidate_suites ==
  [{suite:"tests/test-keep.sh",matches:["docs/keep.md"]}]' \
  && grep -Fxq 'qa-inventory: skipped 1 suite path(s) outside the repository' "$scratch/stderr"; then
  pass 'suite directory outside the physical repository is counted and excluded'
else fail 'suite directory boundary'; fi
rm "$scratch/topic/bin/tests"

# All seven patterns share the matcher; explicit generated paths do not leak.
capture scan packages/create-egregore/runtime/claude/x.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.changed == [] and (.generated_skipped | length) == 1'; then
  pass 'generated-only selection is empty'
else fail 'generated explicit paths'; fi
capture scan bin/base-branch.sh --json
if [ "$EXIT_CODE" -eq 0 ] && json_is 'any(.candidate_suites[]; .suite == "tests/test-runtime-skill-migration.sh"
  and (.matches | index("skill or bin change")))'; then
  pass 'bin changes add runtime skill migration suite'
else fail 'runtime migration candidate'; fi

# The migration candidate also applies when a bin entry was deleted.
fixture_git clone "$scratch/origin.git" "$scratch/deleted-bin" >/dev/null 2>&1
rm "$scratch/deleted-bin/bin/base-branch.sh"
capture fixture_run "$scratch/deleted-bin" bin/qa-inventory.sh --base main --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.changed == [{path:"bin/base-branch.sh",status:"D",note:null}]
  and .candidate_suites == [{suite:"tests/test-runtime-skill-migration.sh",matches:["skill or bin change"]}]'; then
  pass 'deleted bin paths retain the migration candidate without reference searching'
else fail 'deleted bin candidate'; fi
capture fixture_run "$scratch/deleted-bin" bin/qa-inventory.sh ./bin/base-branch.sh --base main --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.changed == [{path:"bin/base-branch.sh",status:"X",note:"missing"}]
  and .candidate_suites == [{suite:"tests/test-runtime-skill-migration.sh",matches:["skill or bin change"]}]'; then
  pass 'deleted bin selection normalizes before adding runtime migration coverage'
else fail 'normalized missing bin candidate'; fi

# A checkout without suite files exercises the other possibly-empty Bash array.
rm "$scratch/deleted-bin"/tests/*.sh
capture fixture_run "$scratch/deleted-bin" bin/qa-inventory.sh docs/keep.md --base main --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.candidate_suites == []'; then
  pass 'empty suite corpus is safe under set -u'
else fail 'empty suite corpus'; fi
fixture_git -C "$scratch/deleted-bin" switch --detach >/dev/null 2>&1
capture fixture_run "$scratch/deleted-bin" bin/qa-inventory.sh --base main --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.head.description == "HEAD + working tree"'; then
  pass 'detached working-tree inventory names HEAD'
else fail 'detached head'; fi

# Index bytes and repository overrides must stay untouched by inventory reads.
cp "$scratch/topic/.git/index" "$scratch/index.before"
GIT_DIR="$scratch/main/.git" GIT_WORK_TREE="$scratch/main" \
  GIT_INDEX_FILE="$scratch/main/.git/index" GIT_OBJECT_DIRECTORY="$scratch/main/.git/objects" \
  GIT_ALTERNATE_OBJECT_DIRECTORIES="$scratch/main/.git/objects" GIT_COMMON_DIR="$scratch/main/.git" \
  capture scan docs/keep.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.head.description == "topic"' \
   && cmp -s "$scratch/index.before" "$scratch/topic/.git/index"; then
  pass 'isolated inventory preserves index bytes with inherited repository overrides'
else fail 'isolated read-only inventory'; fi

# Managed checkouts must be registered and live beside the main checkout.
capture fixture_run "$scratch/topic" bin/base-branch.sh ghost --resolve
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] \
   && grep -Fxq 'base-branch: managed repo ghost is not registered in egregore.json' "$scratch/stderr"; then
  pass 'unregistered managed checkout exits 2'
else fail 'unregistered managed checkout'; fi
printf '%s\n' '{"repos":["ghost"]}' > "$scratch/config.json"
capture fixture_env env CONFIG="$scratch/config.json" bash "$scratch/topic/bin/base-branch.sh" ghost --resolve
if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && grep -Fq 'managed repo ghost not found at' "$scratch/stderr"; then
  pass 'absent managed checkout exits 2'
else fail 'managed checkout absence'; fi
printf '%s\n' '{"repos":[{"name":"main","base_branch":"main"}]}' > "$scratch/config.json"
capture fixture_env env CONFIG="$scratch/config.json" bash "$scratch/topic/bin/base-branch.sh" main --resolve
if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = main ]; then
  pass 'managed checkout uses its own local base'
else fail 'managed checkout resolution'; fi
fixture_git -C "$scratch/topic" worktree add --detach "$scratch/topic/.claude/worktrees/linked" HEAD >/dev/null 2>&1
capture fixture_env env CONFIG="$scratch/config.json" \
  bash "$scratch/topic/.claude/worktrees/linked/bin/base-branch.sh" main --resolve
if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = main ]; then
  pass 'linked worktree resolves managed siblings beside the main checkout'
else fail 'linked worktree managed resolution'; fi
fixture_git -C "$scratch/topic" worktree remove "$scratch/topic/.claude/worktrees/linked" >/dev/null 2>&1
printf '%s\n' '{"repos":["main"]}' > "$scratch/config.json"
capture fixture_env env CONFIG="$scratch/config.json" bash "$scratch/topic/bin/base-branch.sh" main
if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = develop ]; then
  pass 'string-form registered managed repository retains its configured default'
else fail 'string-form managed registration'; fi
for invalid_name in '../main' 'nested/main' 'nested\main' 'name..part' '-main'; do
  capture fixture_run "$scratch/topic" bin/base-branch.sh "$invalid_name" --resolve
  if [ "$EXIT_CODE" -eq 2 ] && [ -z "$OUTPUT" ] && grep -Fq 'Usage:' "$scratch/stderr"; then
    pass "managed repository name rejects $invalid_name"
  else fail "unsafe managed repository name $invalid_name"; fi
done

# A failing optional engine is visible but never turns an inventory into exit 2.
printf '%s\n' '// fixture engine' > "$scratch/topic/bin/capability-distribution.mjs"
printf '%s\n' '#!/bin/bash' 'echo "fixture engine unavailable" >&2' 'exit 1' > "$scratch/topic/bin/node-run.sh"
capture scan docs/keep.md --json
if [ "$EXIT_CODE" -eq 0 ] && json_is '.affected_skills == null
  and (.affected_skills_note | contains("fixture engine unavailable"))' \
  && grep -Fxq 'fixture engine unavailable' "$scratch/stderr"; then
  pass 'optional engine failure preserves inventory and its stderr'
else fail 'optional engine failure'; fi

# 11. Real source engine review is read-only and connects the static gate to both skills.
before=$(fixture_git -C "$SCRIPT_DIR" status --porcelain=v1 --untracked-files=all)
capture fixture_run "$SCRIPT_DIR" bin/qa-inventory.sh bin/test-changes.sh --json
after=$(fixture_git -C "$SCRIPT_DIR" status --porcelain=v1 --untracked-files=all)
if [ "$EXIT_CODE" -eq 0 ] && json_is '.affected_skills | has("qa") and has("test")' && [ "$before" = "$after" ]; then
  pass 'real engine identifies qa and test without changing the source checkout'
else fail 'real source engine path or read-only guarantee'; fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
