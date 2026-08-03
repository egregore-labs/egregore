#!/usr/bin/env bash
# Real-repository regression for /handoff's detached core-repo save helper.
#
# A main-only instance used to lose both paths:
#   1. clean topic commits: origin/develop was missing, the failed rev-list was
#      converted to AHEAD=0, and the helper exited without pushing;
#   2. dirty main: branch creation still targeted origin/develop and exited.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t egregore-handoff-base-XXXXXX)"
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

echo "test-handoff-base-branch"

make_repo() {
  local name="$1"
  local dir="$TMP/$name"
  local origin="$dir/origin.git"
  local repo="$dir/repo"

  mkdir -p "$dir"
  git init --bare --initial-branch=main --quiet "$origin"
  git init --initial-branch=main --quiet "$repo"
  git -C "$repo" config user.name "Handoff Base Test"
  git -C "$repo" config user.email "handoff-base@example.test"
  printf '{"mode":"local","slug":"handoff-base-test","base_branch":"main","repos":[]}\n' \
    > "$repo/egregore.json"
  printf 'base\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -m "Seed main-only instance" --quiet
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -u origin main --quiet
  printf '%s\n' "$repo"
}

SHIM="$TMP/shim"
GH_LOG="$TMP/gh.log"
GH_BODY="$TMP/gh-bodies.log"
mkdir -p "$SHIM"
cat > "$SHIM/gh" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$1 \$2" in
  "pr list")   printf '\\n' ;;
  "pr create")
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--body" ]; then
        printf '%s\n' "\$2" >> "$GH_BODY"
        break
      fi
      shift
    done
    printf 'https://github.com/example/instance/pull/77\\n'
    ;;
  "pr merge")  exit 0 ;;
esac
exit 0
SHIM
chmod +x "$SHIM/gh"

run_helper() {
  local repo="$1"
  local ledger="$2"
  PATH="$SHIM:$PATH" EGREGORE_AUTOSAVE_LOG="$ledger" \
    bash "$ROOT/bin/handoff-save-egregore.sh" tester "main-only save" \
      --repo-dir "$repo" --publish gate
}

# --- Dirty protected base: branch, commit, push, and target main -------------
dirty_repo="$(make_repo dirty)"
mkdir -p "$dirty_repo/docs"
printf 'dirty handoff work\n' > "$dirty_repo/docs/handoff.md"
dirty_ledger="$TMP/dirty-ledger.log"
run_helper "$dirty_repo" "$dirty_ledger"
dirty_branch="$(git -C "$dirty_repo" branch --show-current)"

case "$dirty_branch" in
  dev/tester/handoff-*) ok "dirty main moves to a handoff topic branch" ;;
  *) bad "dirty main moves to a handoff topic branch — got '$dirty_branch'" ;;
esac
check "dirty main work is committed" \
  "Handoff: main-only save" "$(git -C "$dirty_repo" log -1 --format=%s)"
check "dirty main worktree is clean" \
  "" "$(git -C "$dirty_repo" status --porcelain)"
check "dirty main branch is pushed" \
  "1" "$(git ls-remote --heads "$TMP/dirty/origin.git" "$dirty_branch" | grep -c . || true)"
check "dirty main PR targets configured main" \
  "1" "$(grep -c '^pr create --base main ' "$GH_LOG" || true)"
check "helper never creates a develop branch" \
  "0" "$(git ls-remote --heads "$TMP/dirty/origin.git" develop | grep -c . || true)"
check "dirty save is recorded in the ledger" \
  "1" "$(grep -c '|handoff|.*|77|staged|1$' "$dirty_ledger" || true)"

# --- Clean topic commit: do not mistake a missing develop ref for AHEAD=0 ----
clean_repo="$(make_repo clean)"
git -C "$clean_repo" switch -c dev/tester/existing --quiet
mkdir -p "$clean_repo/docs"
printf 'committed handoff work\n' > "$clean_repo/docs/handoff.md"
git -C "$clean_repo" add docs/handoff.md
git -C "$clean_repo" commit -m "Existing topic work" --quiet
clean_ledger="$TMP/clean-ledger.log"
run_helper "$clean_repo" "$clean_ledger"

check "clean topic commit is pushed instead of silently skipped" \
  "1" "$(git ls-remote --heads "$TMP/clean/origin.git" dev/tester/existing | grep -c . || true)"
check "clean topic PR also targets configured main" \
  "2" "$(grep -c '^pr create --base main ' "$GH_LOG" || true)"
check "clean topic save is recorded in the ledger" \
  "1" "$(grep -c '|handoff|.*dev/tester/existing|77|staged|1$' "$clean_ledger" || true)"
check "main remains the only remote base branch" \
  "0" "$(git ls-remote --heads "$TMP/clean/origin.git" develop | grep -c . || true)"
check "background PR bodies satisfy the What/Why/Verification gate" \
  "2/2/2" "$(printf '%s/%s/%s' \
    "$(grep -c '^## What$' "$GH_BODY" || true)" \
    "$(grep -c '^## Why$' "$GH_BODY" || true)" \
    "$(grep -c '^## Verification$' "$GH_BODY" || true)")"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
