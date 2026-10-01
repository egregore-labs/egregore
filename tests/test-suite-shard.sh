#!/usr/bin/env bash
set -euo pipefail

# Corpus partition and argument tests for the repository CI shard printer.
# Usage: bash tests/test-suite-shard.sh
# Exit 0 = all cases passed, Exit 1 = a case failed

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
scratch=$(mktemp -d /tmp/test-suite-shard.XXXXXX)
trap 'rm -rf "$scratch"' EXIT

capture() {
  EXIT_CODE=0
  "$@" > "$scratch/stdout" 2> "$scratch/stderr" || EXIT_CODE=$?
  OUTPUT=$(cat "$scratch/stdout")
}
corpus() (
  cd "$1"
  for suite in tests/*.sh bin/tests/*.sh; do
    [ -f "$suite" ] || continue
    [ "$suite" != tests/run-all.sh ] || continue
    printf '%s\n' "$suite"
  done | LC_ALL=C sort
)
partition_is_exact() {
  local root=$1 shard
  corpus "$root" > "$scratch/corpus"
  : > "$scratch/union"
  for shard in 0 1 2 3; do
    bash "$root/bin/suite-shard.sh" "$shard" 4 > "$scratch/shard" || return 1
    awk -v shard="$shard" '(NR - 1) % 4 == shard' "$scratch/corpus" > "$scratch/expected-shard"
    cmp -s "$scratch/expected-shard" "$scratch/shard" || return 1
    cat "$scratch/shard" >> "$scratch/union"
  done
  LC_ALL=C sort "$scratch/union" > "$scratch/sorted-union"
  cmp -s "$scratch/corpus" "$scratch/sorted-union"
}
invalid() {
  capture bash "$SCRIPT_DIR/bin/suite-shard.sh" "$@"
  if [ "$EXIT_CODE" -eq 2 ] && [ ! -s "$scratch/stdout" ] \
     && grep -Fxq 'Usage: bash bin/suite-shard.sh [--exclude-owned] [--selected FILE] <index> <count>' "$scratch/stderr"; then
    pass "invalid arguments ($*) exit 2 with usage and empty stdout"
  else fail "invalid arguments ($*)"; fi
}

echo '=== suite-shard.sh tests ==='

if partition_is_exact "$SCRIPT_DIR"; then
  pass 'four sorted modulo shards partition the corpus exactly once'
else fail 'four sorted modulo shards partition the corpus exactly once'; fi

corpus "$SCRIPT_DIR" > "$scratch/corpus"
bash "$SCRIPT_DIR/bin/suite-shard.sh" 0 1 > "$scratch/all"
if cmp -s "$scratch/corpus" "$scratch/all"; then
  pass 'shard 0 of 1 equals the whole sorted corpus'
else fail 'shard 0 of 1 equals the whole sorted corpus'; fi

all_exist=true
while IFS= read -r suite; do
  if [ ! -f "$SCRIPT_DIR/$suite" ]; then all_exist=false; fi
done < "$scratch/all"
if $all_exist && ! grep -Fxq tests/run-all.sh "$scratch/all"; then
  pass 'every listed path exists and tests/run-all.sh is excluded'
else fail 'every listed path exists and tests/run-all.sh is excluded'; fi

# Grammar cases use a valid file so missing-input errors cannot mask accepted flags.
printf '%s\n' '["tests/test-suite-shard.sh"]' > "$scratch/selected.json"
invalid a 4
invalid 4 4
invalid -1 4
invalid 0 0
invalid
invalid 0
invalid 0 4 extra
invalid '' 4
invalid 0 a
invalid 0 -1
invalid 99999999999999999999999999999999 4
invalid 0 4 --exclude-owned
invalid --unknown 0 4
invalid --exclude-owned
invalid --exclude-owned 0
invalid --exclude-owned --exclude-owned 0 4
invalid --selected
invalid --selected "$scratch/selected.json"
invalid --selected "$scratch/selected.json" 0
invalid --selected --exclude-owned 0 4
invalid --selected "$scratch/selected.json" --selected "$scratch/selected.json" 0 4
invalid --exclude-owned --selected "$scratch/selected.json" --exclude-owned 0 4
invalid --selected "$scratch/selected.json" 0 4 --exclude-owned
invalid 0 4 --selected "$scratch/selected.json"

bash "$SCRIPT_DIR/bin/suite-shard.sh" 0 4 > "$scratch/from-root"
(cd "$scratch" && bash "$SCRIPT_DIR/bin/suite-shard.sh" 0 4) > "$scratch/from-away"
if cmp -s "$scratch/from-root" "$scratch/from-away"; then
  pass 'invocation from another cwd returns the same slice'
else fail 'invocation from another cwd returns the same slice'; fi

fixture="$scratch/fixture"
mkdir -p "$fixture/bin/tests" "$fixture/tests/dir.sh"
cp "$SCRIPT_DIR/bin/suite-shard.sh" "$fixture/bin/suite-shard.sh"
: > "$fixture/tests/one suite.sh"
: > "$fixture/bin/tests/z-last.sh"
: > "$fixture/bin/tests/a-first.sh"
: > "$fixture/tests/run-all.sh"
printf '%s\n' bin/tests/a-first.sh bin/tests/z-last.sh 'tests/one suite.sh' > "$scratch/three"
bash "$fixture/bin/suite-shard.sh" 0 1 > "$scratch/fixture-all"
if cmp -s "$scratch/three" "$scratch/fixture-all"; then
  pass 'fixture lists only three regular suites and preserves a space on one line'
else fail 'fixture lists only three regular suites and preserves a space on one line'; fi

if partition_is_exact "$fixture"; then
  pass 'fixture corpus partitions exactly with a filename containing a space'
else fail 'fixture corpus partitions exactly with a filename containing a space'; fi

mkdir -p "$fixture/.github/workflows"
cat > "$fixture/.github/workflows/owned.yml" <<'EOF'
name: Strict suite owner
jobs:
  strict:
    runs-on: ubuntu-latest
    steps:
      - run: bash bin/tests/z-last.sh
EOF
cat > "$fixture/bin/ci-test-ownership.json" <<'EOF'
{"version":1,"excluded_from_baseline":[{"suite":"bin/tests/z-last.sh","workflow":".github/workflows/owned.yml","job":"strict"}]}
EOF
bash "$fixture/bin/suite-shard.sh" 0 1 > "$scratch/fixture-default"
if cmp -s "$scratch/three" "$scratch/fixture-default"; then
  pass 'ownership leaves the default local corpus unchanged'
else fail 'ownership leaves the default local corpus unchanged'; fi

printf '%s\n' bin/tests/a-first.sh 'tests/one suite.sh' > "$scratch/unowned"
bash "$fixture/bin/suite-shard.sh" --exclude-owned 0 1 > "$scratch/fixture-unowned"
if cmp -s "$scratch/unowned" "$scratch/fixture-unowned"; then
  pass 'explicit ownership mode omits only the mapped suite'
else fail 'explicit ownership mode omits only the mapped suite'; fi

filtered_exact=true
: > "$scratch/filtered-union"
for shard in 0 1 2 3; do
  bash "$fixture/bin/suite-shard.sh" --exclude-owned "$shard" 4 > "$scratch/filtered-shard"
  awk -v shard="$shard" '(NR - 1) % 4 == shard' "$scratch/unowned" > "$scratch/expected-filtered-shard"
  if ! cmp -s "$scratch/expected-filtered-shard" "$scratch/filtered-shard"; then filtered_exact=false; fi
  cat "$scratch/filtered-shard" >> "$scratch/filtered-union"
done
LC_ALL=C sort "$scratch/filtered-union" > "$scratch/filtered-union-sorted"
if $filtered_exact && cmp -s "$scratch/unowned" "$scratch/filtered-union-sorted"; then
  pass 'ownership filtering precedes sharding and retains every unowned suite exactly once'
else fail 'ownership filtering precedes sharding and retains every unowned suite exactly once'; fi

selected="$scratch/selected suites.json"
printf '%s\n' '["tests/one suite.sh", "bin/tests/z-last.sh"]' > "$selected"
printf '%s\n' bin/tests/z-last.sh 'tests/one suite.sh' > "$scratch/selected-expected"
capture bash "$fixture/bin/suite-shard.sh" --selected "$selected" 0 1
if [ "$EXIT_CODE" -eq 0 ] && cmp -s "$scratch/selected-expected" "$scratch/stdout"; then
  pass 'selection keeps only requested suites, sorts them, and preserves spaces in paths'
else fail 'selection keeps only requested suites, sorts them, and preserves spaces in paths'; fi

selected_exact=true
: > "$scratch/selected-union"
for shard in 0 1 2 3; do
  capture bash "$fixture/bin/suite-shard.sh" --selected "$selected" "$shard" 4
  awk -v shard="$shard" '(NR - 1) % 4 == shard' "$scratch/selected-expected" > "$scratch/selected-shard-expected"
  if [ "$EXIT_CODE" -ne 0 ] || ! cmp -s "$scratch/selected-shard-expected" "$scratch/stdout"; then selected_exact=false; fi
  cat "$scratch/stdout" >> "$scratch/selected-union"
done
LC_ALL=C sort "$scratch/selected-union" > "$scratch/selected-union-sorted"
if $selected_exact && cmp -s "$scratch/selected-expected" "$scratch/selected-union-sorted"; then
  pass 'selection precedes sorted modulo partition and each requested suite appears exactly once'
else fail 'selection precedes sorted modulo partition and each requested suite appears exactly once'; fi

printf '%s\n' 'tests/one suite.sh' > "$scratch/selected-unowned-expected"
for order in owned-first selected-first; do
  if [ "$order" = owned-first ]; then
    selection_flags=(--exclude-owned --selected "$selected")
  else
    selection_flags=(--selected "$selected" --exclude-owned)
  fi
  combined_exact=true
  for shard in 0 1 2 3; do
    capture bash "$fixture/bin/suite-shard.sh" "${selection_flags[@]}" "$shard" 4
    awk -v shard="$shard" '(NR - 1) % 4 == shard' "$scratch/selected-unowned-expected" > "$scratch/combined-shard-expected"
    if [ "$EXIT_CODE" -ne 0 ] || ! cmp -s "$scratch/combined-shard-expected" "$scratch/stdout"; then combined_exact=false; fi
  done
  if $combined_exact; then
    pass "selection and ownership filter before partition with $order flags"
  else fail "selection and ownership filter before partition with $order flags"; fi
done

printf '%s\n' '[]' > "$selected"
capture bash "$fixture/bin/suite-shard.sh" --selected "$selected" 0 1
if [ "$EXIT_CODE" -eq 0 ] && [ ! -s "$scratch/stdout" ]; then
  pass 'an explicit empty selection never expands to the full corpus'
else fail 'an explicit empty selection never expands to the full corpus'; fi
capture bash "$fixture/bin/suite-shard.sh" --exclude-owned --selected "$selected" 0 1
if [ "$EXIT_CODE" -eq 0 ] && [ ! -s "$scratch/stdout" ]; then
  pass 'an explicit empty selection remains empty with ownership enabled'
else fail 'an explicit empty selection remains empty with ownership enabled'; fi
printf '%s\n' '["bin/tests/z-last.sh"]' > "$selected"
capture bash "$fixture/bin/suite-shard.sh" --selected "$selected" --exclude-owned 0 1
if [ "$EXIT_CODE" -eq 0 ] && [ ! -s "$scratch/stdout" ]; then
  pass 'a selection containing only owned suites succeeds with an empty result'
else fail 'a selection containing only owned suites succeeds with an empty result'; fi

invalid_selection() {
  local label=$1 value=$2
  printf '%s' "$value" > "$selected"
  capture bash "$fixture/bin/suite-shard.sh" --selected "$selected" 0 1
  if [ "$EXIT_CODE" -eq 2 ] && [ ! -s "$scratch/stdout" ]; then
    pass "invalid selection ($label) exits 2 without publishing suites"
  else fail "invalid selection ($label) exits 2 without publishing suites"; fi
}
invalid_selection 'empty file' ''
invalid_selection 'malformed JSON' '[broken'
invalid_selection 'object instead of array' '{}'
invalid_selection 'string instead of array' '"tests/one suite.sh"'
invalid_selection 'null instead of array' 'null'
invalid_selection 'non-string element' '["bin/tests/a-first.sh", 7]'
invalid_selection 'null element' '[null]'
invalid_selection 'empty string' '[""]'
invalid_selection 'duplicate suite' '["tests/one suite.sh", "tests/one suite.sh"]'
invalid_selection 'missing suite after valid suite' '["bin/tests/a-first.sh", "tests/missing.sh"]'
invalid_selection 'directory rather than regular file' '["tests/dir.sh"]'
invalid_selection 'run-all excluded from corpus' '["tests/run-all.sh"]'
mkdir -p "$fixture/tests/nested"
: > "$fixture/tests/nested/hidden.sh"
: > "$fixture/bin/not-a-suite.sh"
invalid_selection 'nested file outside corpus' '["tests/nested/hidden.sh"]'
invalid_selection 'existing source outside corpus' '["bin/not-a-suite.sh"]'
invalid_selection 'internal traversal' '["tests/../tests/one suite.sh"]'
invalid_selection 'parent traversal' '["../outside.sh"]'
invalid_selection 'absolute path' "[\"$fixture/tests/one suite.sh\"]"
: > "$scratch/outside.sh"
ln -s "$scratch/outside.sh" "$fixture/tests/outside-link.sh"
invalid_selection 'symlink escapes repository' '["tests/outside-link.sh"]'
rm "$fixture/tests/outside-link.sh"
newline_suite=$'tests/line\nbreak.sh'
: > "$fixture/$newline_suite"
invalid_selection 'existing filename contains newline' '["tests/line\nbreak.sh"]'
rm "$fixture/$newline_suite"
invalid_selection 'carriage return in path' '["tests/line\rbreak.sh"]'

capture bash "$fixture/bin/suite-shard.sh" --selected "$scratch/missing-selection.json" 0 1
if [ "$EXIT_CODE" -eq 2 ] && [ ! -s "$scratch/stdout" ]; then
  pass 'a missing selection file fails without falling back to the full corpus'
else fail 'a missing selection file fails without falling back to the full corpus'; fi
capture bash "$fixture/bin/suite-shard.sh" --selected "$fixture/tests" 0 1
if [ "$EXIT_CODE" -eq 2 ] && [ ! -s "$scratch/stdout" ]; then
  pass 'a selection path that is a directory fails without printing suites'
else fail 'a selection path that is a directory fails without printing suites'; fi

mkdir -p "$scratch/no-python"
printf '#!/usr/bin/env bash\nexit 65\n' > "$scratch/no-python/python3"
chmod +x "$scratch/no-python/python3"
printf '%s\n' '["tests/one suite.sh"]' > "$selected"
capture env PATH="$scratch/no-python:$PATH" bash "$fixture/bin/suite-shard.sh" --selected "$selected" 0 1
if [ "$EXIT_CODE" -eq 2 ] && [ ! -s "$scratch/stdout" ]; then
  pass 'selection fails closed when its Python validator is unavailable'
else fail 'selection fails closed when its Python validator is unavailable'; fi
printf '{malformed ownership\n' > "$fixture/bin/ci-test-ownership.json"
capture env PATH="$scratch/no-python:$PATH" bash "$fixture/bin/suite-shard.sh" 0 1
printf '%s\n' "$OUTPUT" > "$scratch/no-python-output"
if [ "$EXIT_CODE" -eq 0 ] && cmp -s "$scratch/three" "$scratch/no-python-output"; then
  pass 'default mode needs no Python and ignores invalid ownership metadata'
else fail 'default mode needs no Python and ignores invalid ownership metadata'; fi

capture bash "$fixture/bin/suite-shard.sh" 3 4
if [ "$EXIT_CODE" -eq 0 ] && [ -z "$OUTPUT" ]; then
  pass 'an empty slice succeeds with empty stdout'
else fail 'an empty slice succeeds with empty stdout'; fi

capture bash "$fixture/bin/suite-shard.sh" 0002 0004
if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = 'tests/one suite.sh' ]; then
  pass 'leading zeroes use decimal shard numbers'
else fail 'leading zeroes use decimal shard numbers'; fi

capture bash "$fixture/bin/suite-shard.sh" 0 99999999999999999999999999999999
if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = bin/tests/a-first.sh ]; then
  pass 'a count beyond machine integer range remains valid'
else fail 'a count beyond machine integer range remains valid'; fi
capture bash "$fixture/bin/suite-shard.sh" 99999999999999999999999999999998 99999999999999999999999999999999
if [ "$EXIT_CODE" -eq 0 ] && [ -z "$OUTPUT" ]; then
  pass 'a large valid index yields an empty slice without overflow'
else fail 'a large valid index yields an empty slice without overflow'; fi

: > "$fixture/tests/new-suite.sh"
if partition_is_exact "$fixture"; then
  pass 'adding a suite between runs preserves the exact partition'
else fail 'adding a suite between runs preserves the exact partition'; fi
rm "$fixture/bin/tests/a-first.sh"
if partition_is_exact "$fixture"; then
  pass 'removing a suite between runs preserves the exact partition'
else fail 'removing a suite between runs preserves the exact partition'; fi

rm "$fixture/tests/one suite.sh" "$fixture/tests/new-suite.sh" "$fixture/bin/tests/z-last.sh"
capture bash "$fixture/bin/suite-shard.sh" 0 1
if [ "$EXIT_CODE" -eq 0 ] && [ -z "$OUTPUT" ]; then
  pass 'an empty corpus succeeds without listing unmatched globs'
else fail 'an empty corpus succeeds without listing unmatched globs'; fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
