#!/usr/bin/env bash
set -uo pipefail

# Test: every Runtime launcher runs the package next to itself, never the one
# in the working directory.
#
# `python3 -m egregore_runtime.<cli>` puts the working directory first on
# sys.path, ahead of PYTHONPATH. A harness loads its hooks from the instance
# root but runs them with the session's working directory, so a session in a
# task worktree behind develop ran the root's hook against the worktree's older
# package (2026-09-20: `invalid choice: 'result-hook'` on every tool call).
# The invariant: each launcher sets PYTHONPATH to its own checkout and
# PYTHONSAFEPATH=1, so PYTHONPATH wins. Section 1 audits every launch line in
# the source tree and the packaged runtimes; section 2 proves it with a decoy
# package in the working directory.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: runtime launch path"
echo ""

# ============================================================
# 1. Static audit: every launch line carries the safe-path setting
# ============================================================
echo "— launch lines —"
# A launch line passes when PYTHONSAFEPATH=1 appears on it, within the six
# lines above it (a multi-line env prefix), or in an earlier `export` in the
# same file. Test suites and the eval record are not launchers.
audit_file() {
  awk '
    /export[^#]*PYTHONSAFEPATH=1/ { exported = 1 }
    { window[NR] = $0 }
    /python3 -m egregore_runtime/ {
      ok = exported
      for (i = NR - 6; i <= NR; i++) if (i > 0 && index(window[i], "PYTHONSAFEPATH=1")) ok = 1
      if (!ok) { printf "%s:%d: %s\n", FILENAME, NR, $0; bad = 1 }
    }
    END { exit bad }
  ' "$1"
}
LAUNCH_FILES=$(grep -rl 'python3 -m egregore_runtime' \
  bin .claude .codex .pi .prime packages/create-egregore/runtime 2>/dev/null \
  | grep -v '/tests/\|/test-\|/node_modules/' | sort)
TOTAL=0
UNSAFE=""
for f in $LAUNCH_FILES; do
  TOTAL=$((TOTAL + 1))
  out=$(audit_file "$f") || UNSAFE="$UNSAFE
$out"
done
[ "$TOTAL" -gt 20 ] \
  && pass "found $TOTAL launch files across source tree and packaged runtimes" \
  || fail "expected more than 20 launch files, found $TOTAL (grep pattern rot?)"
[ -z "$UNSAFE" ] \
  && pass "every launch line sets PYTHONSAFEPATH=1 (inline, within six lines, or exported)" \
  || fail "launch lines without PYTHONSAFEPATH=1:" "$UNSAFE"

# Each of the four packaged runtimes carries at least one launcher, so a bundle
# build that dropped them would not pass the audit vacuously.
for runtime in claude codex pi prime; do
  n=$(printf '%s\n' "$LAUNCH_FILES" | grep -c "^packages/create-egregore/runtime/$runtime/")
  [ "$n" -gt 0 ] \
    && pass "packaged $runtime runtime: $n launch files audited" \
    || fail "packaged $runtime runtime: no launch files found"
done

# Launchers that set the safe path must also set PYTHONPATH, or the package
# next to the script is no longer on the path at all.
MISSING_PATH=""
for f in $LAUNCH_FILES; do
  case "$f" in *.md) continue ;; esac
  grep -q 'PYTHONPATH=' "$f" || MISSING_PATH="$MISSING_PATH $f"
done
[ -z "$MISSING_PATH" ] \
  && pass "every script launcher also sets PYTHONPATH" \
  || fail "launchers with PYTHONSAFEPATH but no PYTHONPATH:$MISSING_PATH"

# ============================================================
# 2. Behavioral: a decoy package in the working directory loses
# ============================================================
echo ""
echo "— decoy package —"
DECOY=$(mktemp -d "${TMPDIR:-/tmp}/egregore-launch-decoy.XXXXXX")
mkdir -p "$DECOY/egregore_runtime"
: > "$DECOY/egregore_runtime/__init__.py"
for cli in thread_cli issue_cli harness_cli; do
  printf 'import sys\nprint("DECOY-PACKAGE %s")\nsys.exit(9)\n' "$cli" > "$DECOY/egregore_runtime/$cli.py"
done

# Python's own behaviour, so a failure below is attributable. (The decoy exits
# non-zero, so its output is captured rather than piped under pipefail.)
control=$(cd "$DECOY" && PYTHONPATH="$SCRIPT_DIR" python3 -m egregore_runtime.thread_cli --help 2>/dev/null)
if grep -q DECOY-PACKAGE <<< "$control"; then
  pass "control: without the safe path, python3 -m imports the decoy from the working directory"
else
  pass "control: this Python does not put the working directory first (nothing to defend against)"
fi

for launcher in bin/thread.sh bin/issue.sh; do
  out=$(cd "$DECOY" && bash "$SCRIPT_DIR/$launcher" --help 2>&1)
  rc=$?
  if grep -q DECOY-PACKAGE <<< "$out"; then
    fail "$launcher run from a decoy directory imported the decoy package"
  elif [ "$rc" -eq 0 ] && grep -q '^usage:' <<< "$out"; then
    pass "$launcher run from a decoy directory runs the package next to itself"
  else
    fail "$launcher --help from a decoy directory: exit $rc" "$(printf '%s' "$out" | head -3)"
  fi
done

# The PostToolUse hook is the launcher that failed in the wild: it ran from the
# instance root while the session stood in a worktree.
hook_out=$(cd "$DECOY" && printf '{"tool_name":"Read","tool_input":{}}' \
  | CLAUDE_PROJECT_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/.claude/hooks/retrieval-context.sh" 2>&1)
grep -q DECOY-PACKAGE <<< "$hook_out" \
  && fail "retrieval-context.sh run from a decoy directory imported the decoy package" \
  || pass "retrieval-context.sh run from a decoy directory runs the instance root's package"

rm -rf "$DECOY"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
