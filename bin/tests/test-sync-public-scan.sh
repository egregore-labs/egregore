#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/sync-public.sh"
TMP_ROOT="$(mktemp -d)"
UNREADABLE_DIR=""
cleanup() {
  if [ -n "$UNREADABLE_DIR" ] && [ -d "$UNREADABLE_DIR" ]; then
    chmod 700 "$UNREADABLE_DIR"
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
export SYNC_PUBLIC_REPO_ROOT="$TMP_ROOT/source's checkout"
# Fixture names stand in for the private .syncnames list.
export SYNC_PUBLIC_SCAN_NAMES="$TMP_ROOT/names"
printf '%s\n' '# fixture names' '' 'zorblax' 'quuxcorp' > "$SYNC_PUBLIC_SCAN_NAMES"
PUBLISH_WT="$SYNC_PUBLIC_REPO_ROOT/.claude/worktrees/_sync-public-oss"
SCAN_OUTPUT="$TMP_ROOT/scan.out"
SCAN_ERROR="$TMP_ROOT/scan.err"
SCAN_STATUS=0
PASS=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; exit 1; }

scan() {
  if bash "$SCRIPT" scan "$@" >"$SCAN_OUTPUT" 2>"$SCAN_ERROR"; then
    SCAN_STATUS=0
  else
    SCAN_STATUS=$?
  fi
}

expect_status() {
  [ "$SCAN_STATUS" -eq "$1" ] || fail "scan exited $SCAN_STATUS instead of $1"
}

reset_tree() {
  rm -rf "$PUBLISH_WT"
  mkdir -p "$PUBLISH_WT/.git"
}

# A real Git work tree whose HEAD plays the public base.
git_fixture() {
  git -C "$PUBLISH_WT" -c user.name=fixture -c user.email=fixture@example.com \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
reset_git_tree() {
  rm -rf "$PUBLISH_WT"
  mkdir -p "$PUBLISH_WT"
  git_fixture init -q
}
commit_base() {
  git_fixture add -A
  git_fixture commit -q -m base
}

section_count() {
  awk -v wanted="$1" '
    /^(SECRETS|INTERNAL_REFS|INTERNAL_URLS|NAMES)$/ { section = $0; next }
    /^[A-Z_]+:/ { section = "" }
    section == wanted && NF { count++ }
    END { print count + 0 }
  ' "$SCAN_OUTPUT"
}

echo "Testing: sync-public safety scan"
echo

scan
expect_status 1
[ ! -s "$SCAN_OUTPUT" ] || fail "missing worktree printed findings or clean headers"
[ "$(wc -l < "$SCAN_ERROR" | tr -d ' ')" -eq 1 ] ||
  fail "missing worktree must print exactly one stderr line"
grep -Fxq "Error: prepared OSS worktree is missing: $PUBLISH_WT" "$SCAN_ERROR" ||
  fail "missing worktree error did not identify the prepared path"
pass "missing worktree fails closed with one stderr line"

mkdir -p "$PUBLISH_WT"
scan
expect_status 1
[ ! -s "$SCAN_OUTPUT" ] || fail "non-worktree directory was scanned"
pass "a directory without its Git marker also fails closed"

reset_tree
scan
expect_status 0
cat > "$TMP_ROOT/empty-expected" <<'EOF'
SECRETS

INTERNAL_REFS

INTERNAL_URLS

NAMES

EOF
cmp -s "$TMP_ROOT/empty-expected" "$SCAN_OUTPUT" ||
  fail "empty scan did not print its four category headers"
[ ! -s "$SCAN_ERROR" ] || fail "empty scan printed an error"
pass "empty worktree exits zero with four empty categories"

scan --unknown
expect_status 2
grep -q '^Usage:' "$SCAN_ERROR" || fail "unknown scan option did not print usage"
[ ! -s "$SCAN_OUTPUT" ] || fail "unknown scan option printed scan sections"
pass "unknown scan options exit two with usage on stderr"

if [ "$(id -u)" -eq 0 ]; then
  echo "  - unreadable directory check skipped when running as root"
else
  UNREADABLE_DIR="$PUBLISH_WT/unreadable"
  mkdir -p "$UNREADABLE_DIR"
  printf '%s\n' 'ghp_fixture' > "$UNREADABLE_DIR/secret.js"
  chmod 000 "$UNREADABLE_DIR"
  scan
  expect_status 1
  grep -Fxq 'sync-public: scan failed for SECRETS' "$SCAN_ERROR" ||
    fail "unreadable scan did not identify the failed category"
  [ ! -s "$SCAN_OUTPUT" ] || fail "unreadable scan printed section headers"
  chmod 700 "$UNREADABLE_DIR"
  rm -rf "$UNREADABLE_DIR"
  UNREADABLE_DIR=""
  pass "unreadable directory fails closed before printing scan sections"
fi

cat > "$PUBLISH_WT/secrets.md" <<'EOF'
gho_fixture
ghp_fixture
sk-fixture
ek_fixture
Bearer fixture
password = fixture
EOF
cat > "$PUBLISH_WT/references.js" <<'EOF'
Curve-Labs
curve-labs
curvelabs
oguzhan
cemdagdelen
fcdagdelen
EOF
cat > "$PUBLISH_WT/urls.json" <<'EOF'
fixture.railway.app
fixture.supabase.co
neo4j+s://fixture
EOF
cat > "$PUBLISH_WT/people.txt" <<'EOF'
Zorblax said yes
quuxcorp's renewal
zorblaxian is a different word
EOF
scan
expect_status 1
[ "$(section_count SECRETS)" -eq 6 ] || fail "one or more secret patterns were lost"
[ "$(section_count INTERNAL_REFS)" -eq 6 ] || fail "one or more internal-reference patterns were lost"
[ "$(section_count INTERNAL_URLS)" -eq 3 ] || fail "one or more URL patterns were lost"
[ "$(section_count NAMES)" -eq 2 ] || fail "names must match whole words in any case"
! grep -q 'zorblaxian' "$SCAN_OUTPUT" || fail "a name matched inside a longer word"
grep -Fxq "$PUBLISH_WT/secrets.md:6:password = fixture" "$SCAN_OUTPUT" ||
  fail "findings must retain path, line number, and matched text"
[ ! -s "$SCAN_ERROR" ] || fail "matching scan printed an error"
pass "all existing patterns and path:line:match findings are preserved"

reset_tree
for extension in sh js json md txt py mjs html yml; do
  printf '%s\n' 'ghp_fixture Curve-Labs fixture.railway.app zorblax' > "$PUBLISH_WT/include.$extension"
done
printf 'ghp_fixture Curve-Labs fixture.railway.app zorblax\0binary\n' > "$PUBLISH_WT/blob.bin"
scan
expect_status 1
for category in SECRETS INTERNAL_REFS INTERNAL_URLS NAMES; do
  [ "$(section_count "$category")" -eq 9 ] || fail "$category did not read every text file type"
done
! grep -q 'blob.bin:' "$SCAN_OUTPUT" || fail "a binary file was scanned as text"
pass "every category reads every text file, whatever its extension, and skips binaries"

reset_tree
mkdir -p "$PUBLISH_WT/docs/zorblax-notes"
printf '%s\n' 'clean text' > "$PUBLISH_WT/docs/zorblax-notes/readme.md"
scan
expect_status 1
grep -Fxq "$PUBLISH_WT/docs/zorblax-notes/readme.md:0:(file name)" "$SCAN_OUTPUT" ||
  fail "a name in a file path was not reported"
[ "$(section_count NAMES)" -eq 1 ] || fail "a name in a path was reported more than once"
pass "a name in a file or directory name is reported"

reset_tree
mkdir -p "$PUBLISH_WT/node_modules" "$PUBLISH_WT/.git/objects"
for path in node_modules/ignored.js .git/objects/ignored.js; do
  printf '%s\n' 'ghp_fixture Curve-Labs fixture.railway.app' > "$PUBLISH_WT/$path"
done
printf '%s\n' 'ghp_fixture Curve-Labs fixture.railway.app node_modules' > "$PUBLISH_WT/ignored-line.js"
printf '%s\n' 'ghp_fixture Curve-Labs fixture.railway.app /.git/' >> "$PUBLISH_WT/ignored-line.js"
scan
expect_status 0
cmp -s "$TMP_ROOT/empty-expected" "$SCAN_OUTPUT" || fail "excluded findings escaped the filters"
pass "node_modules and /.git/ exclusions retain their line-filter semantics"

reset_tree
for ((index = 1; index <= 1000; index++)); do
  printf 'ghp_fixture Curve-Labs fixture.railway.app zorblax %s\n' "$index"
done > "$PUBLISH_WT/many.js"
scan
expect_status 1
for category in SECRETS INTERNAL_REFS INTERNAL_URLS NAMES; do
  [ "$(section_count "$category")" -eq 10 ] || fail "$category is not bounded to 10 findings"
done
! grep -q 'many.js:11:' "$SCAN_OUTPUT" || fail "scan printed beyond the first ten findings"
grep -Fxq 'MORE: SECRETS=990 INTERNAL_REFS=990 INTERNAL_URLS=990 NAMES=990' "$SCAN_OUTPUT" ||
  fail "the hidden findings were not counted"
pass "each category prints at most ten findings and counts the rest"

scan --all
expect_status 1
for category in SECRETS INTERNAL_REFS INTERNAL_URLS NAMES; do
  [ "$(section_count "$category")" -eq 1000 ] || fail "--all did not list every $category finding"
done
! grep -q '^MORE:' "$SCAN_OUTPUT" || fail "--all still reported hidden findings"
pass "scan --all lists every finding"

reset_git_tree
printf '%s\n' 'ghp_old Curve-Labs fixture.railway.app' > "$PUBLISH_WT/old.md"
commit_base
scan
expect_status 0
for category in SECRETS INTERNAL_REFS INTERNAL_URLS NAMES; do
  [ "$(section_count "$category")" -eq 0 ] || fail "an already-public $category finding was listed"
done
grep -Fxq 'ALREADY_PUBLIC: SECRETS=1 INTERNAL_REFS=1 INTERNAL_URLS=1' "$SCAN_OUTPUT" ||
  fail "already-public findings were not counted"
pass "findings already on the public base are counted, not listed"

printf '%s\n%s\n' 'new first line' 'ghp_old Curve-Labs fixture.railway.app' > "$PUBLISH_WT/old.md"
printf '%s\n' 'ghp_new' > "$PUBLISH_WT/new.md"
scan
expect_status 1
[ "$(section_count SECRETS)" -eq 1 ] || fail "only the new secret should be listed"
grep -Fxq "$PUBLISH_WT/new.md:1:ghp_new" "$SCAN_OUTPUT" || fail "the new finding was not listed"
grep -Fxq 'ALREADY_PUBLIC: SECRETS=1 INTERNAL_REFS=1 INTERNAL_URLS=1' "$SCAN_OUTPUT" ||
  fail "a line that only moved was treated as new"
pass "new findings are listed; a public line that only moved stays counted"

reset_git_tree
printf '%s\n' 'quuxcorp case study' > "$PUBLISH_WT/case.md"
commit_base
scan
expect_status 1
grep -Fxq "$PUBLISH_WT/case.md:1:quuxcorp case study" "$SCAN_OUTPUT" ||
  fail "an already-public name was not listed"
pass "a name already on the public base still fails the scan"

for path in .env .egregore-state.json .egregore-session-id egregore.json; do
  reset_tree
  : > "$PUBLISH_WT/$path"
  scan
  expect_status 1
  grep -Fxq "LEAKED_FILES: $path" "$SCAN_OUTPUT" || fail "private state file was not reported: $path"
done
pass "each private state file still requires safety review"

reset_tree
for path in .env .egregore-state.json .egregore-session-id egregore.json; do
  : > "$PUBLISH_WT/$path"
done
scan
expect_status 1
grep -Fxq 'LEAKED_FILES: .env .egregore-state.json .egregore-session-id egregore.json' "$SCAN_OUTPUT" ||
  fail "multiple private state files were not reported together"
pass "all leaked state files are reported together in stable order"

echo
echo "$PASS passed, 0 failed"
