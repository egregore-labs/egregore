#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bin/transcript-attach.sh"
WORKDIR="$(mktemp -d)"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

munge_path() {
  printf '%s' "$1" | sed 's#[/.]#-#g'
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq "$needle" "$file"; then
    pass "$label"
  else
    fail "$label" "$needle not found"
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq "$needle" "$file"; then
    fail "$label" "unexpected planted value was present"
  else
    pass "$label"
  fi
}

echo "Testing: transcript attach"
echo ""

# ============================================================
# 1. Scrub with .env values and token patterns
# ============================================================
echo "1. scrub: env values + token patterns"

SCRUB_REPO="$WORKDIR/scrub-repo"
SCRUB_INPUT="$WORKDIR/input/session.jsonl"
SCRUB_OUT="$WORKDIR/scrubbed"
PLAIN_LINE='{"type":"user","message":"plain content stays unchanged","n":1}'
ENV_SECRET='p+ss/w0rd$ecret123'

mkdir -p "$SCRUB_REPO" "$(dirname "$SCRUB_INPUT")" "$SCRUB_OUT"
{
  printf 'SECRET=%s\n' "$ENV_SECRET"
  printf 'SHORT=abcde\n'
  printf 'QUOTED="quoted-secret"\n'
  printf 'COMMENT=comment-secret # fixture inline comment\n'
  printf 'TRAILING = trailing-secret \t \n'
  printf 'LOOP=REDACTED123\n'
} > "$SCRUB_REPO/.env"

cat > "$SCRUB_INPUT" <<EOF
$PLAIN_LINE
{"type":"assistant","message":"env $ENV_SECRET and again $ENV_SECRET"}
{"type":"user","message":"short abcde remains; wrapped xx${ENV_SECRET}yy"}
{"type":"assistant","message":"quoted-secret comment-secret trailing-secret REDACTED123"}
sk-ant-ABCDEFGH ghp_ABCDEFGH gho_HIJKLMNO github_pat_ABCDEFGH ek_ABCDEFGH
{"message":"xoxb-ABCDEFGH AKIA1234567890ABCDEF Bearer abcdefgh eyJabcdefghij.klmnopqrst.uvwxyz"}
{"message":"escaped quote: \\\"sk-ant-IJKLMNOP\\\" then ghp_QRSTUVWX"}
ghp_LINEEND1
{"message":"sk-proj-ABCDEFGH sk-ABCDEFGHIJKLMNOPQRST ghs_ABCDEFGH ghu_ABCDEFGH ghr_ABCDEFGH AIzaABCDEFGHIJ glpat-ABCDEFGHIJ npm_ABCDEFGHIJ bearer lowerabc"}
EOF

summary="$(TRANSCRIPT_ATTACH_REPO_ROOT="$SCRUB_REPO" "$SCRIPT" scrub "$SCRUB_OUT" "$SCRUB_INPUT")"
SCRUBBED_FILE="$SCRUB_OUT/$(basename "$SCRUB_INPUT")"

if printf '%s' "$summary" | grep -Fq '"files":1' \
  && printf '%s' "$summary" | grep -Fq '"env_value":7' \
  && printf '%s' "$summary" | grep -Fq '"token":21'; then
  pass "scrub summary reports correct files and redaction counts"
else
  fail "scrub summary reports correct files and redaction counts" "$summary"
fi

for planted in \
  "$ENV_SECRET" \
  "quoted-secret" \
  "comment-secret" \
  "trailing-secret" \
  "REDACTED123" \
  "sk-ant-ABCDEFGH" \
  "sk-proj-ABCDEFGH" \
  "sk-ABCDEFGHIJKLMNOPQRST" \
  "ghp_ABCDEFGH" \
  "gho_HIJKLMNO" \
  "ghs_ABCDEFGH" \
  "ghu_ABCDEFGH" \
  "ghr_ABCDEFGH" \
  "github_pat_ABCDEFGH" \
  "ek_ABCDEFGH" \
  "AIzaABCDEFGHIJ" \
  "glpat-ABCDEFGHIJ" \
  "npm_ABCDEFGHIJ" \
  "xoxb-ABCDEFGH" \
  "AKIA1234567890ABCDEF" \
  "Bearer abcdefgh" \
  "bearer lowerabc" \
  "eyJabcdefghij.klmnopqrst.uvwxyz" \
  "sk-ant-IJKLMNOP" \
  "ghp_QRSTUVWX" \
  "ghp_LINEEND1"; do
  assert_not_contains "$SCRUBBED_FILE" "$planted" "scrubbed output removes planted secret"
done

first_line="$(sed -n '1p' "$SCRUBBED_FILE")"
if [ "$first_line" = "$PLAIN_LINE" ]; then
  pass "non-secret line survives byte-identical"
else
  fail "non-secret line survives byte-identical" "$first_line"
fi

assert_contains "$SCRUBBED_FILE" "abcde" ".env values under 6 chars are not redacted"
assert_not_contains "$SCRUBBED_FILE" "[REDACTED:SHORT]" "short .env values do not produce redaction markers"
assert_contains "$SCRUBBED_FILE" "Bearer [REDACTED:token]" "Bearer credential is redacted while preserving scheme"
assert_contains "$SCRUBBED_FILE" "xx[REDACTED:SECRET]yy" ".env value is redacted as a fixed substring"
assert_contains "$SCRUBBED_FILE" "[REDACTED:LOOP]" ".env replacement cursor handles values resembling redaction markers"

# ============================================================
# 2. Scrub without .env
# ============================================================
echo ""
echo "2. scrub: no .env"

NOENV_REPO="$WORKDIR/noenv-repo"
NOENV_INPUT="$WORKDIR/noenv/session.jsonl"
NOENV_OUT="$WORKDIR/noenv-out"
mkdir -p "$NOENV_REPO" "$(dirname "$NOENV_INPUT")" "$NOENV_OUT"
printf '%s\n' '{"message":"token ghp_NOENV1234 only"}' > "$NOENV_INPUT"

noenv_summary="$(TRANSCRIPT_ATTACH_REPO_ROOT="$NOENV_REPO" "$SCRIPT" scrub "$NOENV_OUT" "$NOENV_INPUT")"
NOENV_SCRUBBED="$NOENV_OUT/$(basename "$NOENV_INPUT")"

if printf '%s' "$noenv_summary" | grep -Fq '"env_value":0' \
  && printf '%s' "$noenv_summary" | grep -Fq '"token":1'; then
  pass "scrub works without .env and reports token-only counts"
else
  fail "scrub works without .env and reports token-only counts" "$noenv_summary"
fi
assert_not_contains "$NOENV_SCRUBBED" "ghp_NOENV1234" "token-only scrub removes planted token"

# ============================================================
# 3. Scrub partial batch failure
# ============================================================
echo ""
echo "3. scrub: atomic partial batch failure"

ATOMIC_REPO="$WORKDIR/atomic-repo"
ATOMIC_INPUT_DIR="$WORKDIR/atomic-input"
ATOMIC_OUT="$WORKDIR/atomic-out"
ATOMIC_ONE="$ATOMIC_INPUT_DIR/one.jsonl"
ATOMIC_TWO="$ATOMIC_INPUT_DIR/two.jsonl"
mkdir -p "$ATOMIC_REPO" "$ATOMIC_INPUT_DIR"
printf '%s\n' '{"message":"first file would be valid"}' > "$ATOMIC_ONE"
printf '%s\n' '{"message":"second file is unreadable"}' > "$ATOMIC_TWO"
chmod 000 "$ATOMIC_TWO"

set +e
atomic_summary="$(TRANSCRIPT_ATTACH_REPO_ROOT="$ATOMIC_REPO" "$SCRIPT" scrub "$ATOMIC_OUT" "$ATOMIC_ONE" "$ATOMIC_TWO" 2>"$WORKDIR/atomic.err")"
atomic_status=$?
set -e
chmod 600 "$ATOMIC_TWO"

if [ "$atomic_status" -ne 0 ]; then
  pass "scrub exits nonzero when any file in a batch fails"
else
  fail "scrub exits nonzero when any file in a batch fails" "$atomic_summary"
fi

if [ ! -d "$ATOMIC_OUT" ] || [ -z "$(find "$ATOMIC_OUT" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  pass "failed scrub batch publishes nothing to out_dir"
else
  fail "failed scrub batch publishes nothing to out_dir" "$(find "$ATOMIC_OUT" -mindepth 1 -maxdepth 1 -print 2>/dev/null)"
fi

# ============================================================
# 4. Scrub duplicate basenames
# ============================================================
echo ""
echo "4. scrub: duplicate basenames"

DUP_REPO="$WORKDIR/dup-repo"
DUP_A="$WORKDIR/dup-a/same.jsonl"
DUP_B="$WORKDIR/dup-b/same.jsonl"
DUP_OUT="$WORKDIR/dup-out"
mkdir -p "$DUP_REPO" "$(dirname "$DUP_A")" "$(dirname "$DUP_B")"
printf '%s\n' '{"message":"first duplicate basename"}' > "$DUP_A"
printf '%s\n' '{"message":"second duplicate basename"}' > "$DUP_B"

set +e
dup_summary="$(TRANSCRIPT_ATTACH_REPO_ROOT="$DUP_REPO" "$SCRIPT" scrub "$DUP_OUT" "$DUP_A" "$DUP_B" 2>"$WORKDIR/dup.err")"
dup_status=$?
set -e

if [ "$dup_status" -ne 0 ] && grep -Fqi "duplicate transcript basename" "$WORKDIR/dup.err"; then
  pass "scrub rejects duplicate basenames before processing"
else
  fail "scrub rejects duplicate basenames before processing" "status=$dup_status output=$dup_summary err=$(cat "$WORKDIR/dup.err" 2>/dev/null || true)"
fi

if [ ! -d "$DUP_OUT" ] || [ -z "$(find "$DUP_OUT" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  pass "duplicate-basename failure publishes nothing"
else
  fail "duplicate-basename failure publishes nothing" "$(find "$DUP_OUT" -mindepth 1 -maxdepth 1 -print 2>/dev/null)"
fi

# ============================================================
# 5. Scrub publish failure rollback
# ============================================================
echo ""
echo "5. scrub: publish failure rollback"

ROLL_REPO="$WORKDIR/rollback-repo"
ROLL_INPUT_DIR="$WORKDIR/rollback-input"
ROLL_OUT="$WORKDIR/rollback-out"
ROLL_ONE="$ROLL_INPUT_DIR/one.jsonl"
ROLL_TWO="$ROLL_INPUT_DIR/two.jsonl"
mkdir -p "$ROLL_REPO" "$ROLL_INPUT_DIR" "$ROLL_OUT/two.jsonl"
printf '%s\n' '{"message":"first publish should roll back"}' > "$ROLL_ONE"
printf '%s\n' '{"message":"second publish should fail"}' > "$ROLL_TWO"
chmod 555 "$ROLL_OUT/two.jsonl"

set +e
rollback_summary="$(TRANSCRIPT_ATTACH_REPO_ROOT="$ROLL_REPO" "$SCRIPT" scrub "$ROLL_OUT" "$ROLL_ONE" "$ROLL_TWO" 2>"$WORKDIR/rollback.err")"
rollback_status=$?
set -e
chmod 755 "$ROLL_OUT/two.jsonl" 2>/dev/null || true

if [ "$rollback_status" -ne 0 ]; then
  pass "scrub exits nonzero on publish failure"
  if [ ! -e "$ROLL_OUT/one.jsonl" ] && [ ! -e "$ROLL_OUT/two.jsonl/two.jsonl" ]; then
    pass "publish failure removes already-installed outputs"
  else
    fail "publish failure removes already-installed outputs" "$(find "$ROLL_OUT" -mindepth 1 -maxdepth 2 -print 2>/dev/null)"
  fi
else
  rm -f "$ROLL_OUT/one.jsonl" "$ROLL_OUT/two.jsonl/two.jsonl" 2>/dev/null || true
  pass "publish failure rollback skipped: platform allowed blocked destination"
fi

# ============================================================
# 6. Locate worktree and main-repo transcript dirs
# ============================================================
echo ""
echo "6. locate: worktree + main repo"

PROJECTS_DIR="$WORKDIR/projects"
MAIN_REPO="$WORKDIR/main.repo"
WORKTREE="$MAIN_REPO/.claude/worktrees/issue-transcript-attach"
WORK_KEY="$(munge_path "$WORKTREE")"
MAIN_KEY="$(munge_path "$MAIN_REPO")"
WORK_PROJECT="$PROJECTS_DIR/$WORK_KEY"
MAIN_PROJECT="$PROJECTS_DIR/$MAIN_KEY"

mkdir -p "$WORKTREE" "$WORK_PROJECT" "$MAIN_PROJECT"
printf '%s\n' '{"older":true}' > "$WORK_PROJECT/older.jsonl"
printf '%s\n' '{"current":true}' > "$WORK_PROJECT/current.jsonl"
printf '%s\n' '{"main":true}' > "$MAIN_PROJECT/main.jsonl"
touch -t 202607060810 "$WORK_PROJECT/older.jsonl"
touch -t 202607060830 "$WORK_PROJECT/current.jsonl"
touch -t 202607060820 "$MAIN_PROJECT/main.jsonl"

set +e
locate_output="$(cd "$WORKTREE" && CLAUDE_PROJECTS_DIR="$PROJECTS_DIR" "$SCRIPT" locate 3 2>"$WORKDIR/locate.err")"
locate_status=$?
set -e

if [ "$locate_status" -eq 0 ]; then
  pass "locate exits 0 when fixture transcripts exist"
else
  fail "locate exits 0 when fixture transcripts exist" "$(cat "$WORKDIR/locate.err" 2>/dev/null || true)"
fi

line_count="$(printf '%s\n' "$locate_output" | grep -c '^{' || true)"
if [ "$line_count" -eq 3 ]; then
  pass "locate returns requested transcript count"
else
  fail "locate returns requested transcript count" "$locate_output"
fi

first_locate_line="$(printf '%s\n' "$locate_output" | sed -n '1p')"
second_locate_line="$(printf '%s\n' "$locate_output" | sed -n '2p')"
third_locate_line="$(printf '%s\n' "$locate_output" | sed -n '3p')"

if printf '%s' "$first_locate_line" | grep -Fq "$WORK_PROJECT/current.jsonl" \
  && printf '%s' "$first_locate_line" | grep -Fq '"current":true'; then
  pass "locate marks newest transcript as current"
else
  fail "locate marks newest transcript as current" "$first_locate_line"
fi

if printf '%s' "$second_locate_line" | grep -Fq "$MAIN_PROJECT/main.jsonl" \
  && printf '%s' "$second_locate_line" | grep -Fq '"current":false'; then
  pass "locate merges main-repo transcript directory for worktrees"
else
  fail "locate merges main-repo transcript directory for worktrees" "$locate_output"
fi

if printf '%s' "$third_locate_line" | grep -Fq "$WORK_PROJECT/older.jsonl" \
  && printf '%s' "$third_locate_line" | grep -Fq '"current":false'; then
  pass "locate orders transcripts by mtime descending"
else
  fail "locate orders transcripts by mtime descending" "$locate_output"
fi

# ============================================================
# 7. Locate no transcripts
# ============================================================
echo ""
echo "7. locate: no transcripts"

EMPTY_PROJECTS="$WORKDIR/empty-projects"
EMPTY_CWD="$WORKDIR/empty-repo"
mkdir -p "$EMPTY_PROJECTS" "$EMPTY_CWD"

set +e
empty_output="$(cd "$EMPTY_CWD" && CLAUDE_PROJECTS_DIR="$EMPTY_PROJECTS" "$SCRIPT" locate 2 2>"$WORKDIR/empty.err")"
empty_status=$?
set -e

if [ "$empty_status" -eq 1 ]; then
  pass "locate exits 1 when no transcripts exist"
else
  fail "locate exits 1 when no transcripts exist" "status=$empty_status output=$empty_output"
fi

if grep -Fqi "No Claude Code transcripts" "$WORKDIR/empty.err"; then
  pass "locate prints clear no-transcripts message"
else
  fail "locate prints clear no-transcripts message" "$(cat "$WORKDIR/empty.err" 2>/dev/null || true)"
fi

echo ""
echo "─────────────────────────────"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
