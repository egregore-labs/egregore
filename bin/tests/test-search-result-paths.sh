#!/usr/bin/env bash
set -euo pipefail

# Exercise the real shell/Runtime path against isolated canonical documents.
# QMD ranking, source normalization and worker behavior are covered separately
# by tests/qmd_scoped_backend.test.mjs and tests/test_qmd_retriever.py.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
mkdir -p "$FIXTURE/bin" "$FIXTURE/memory-repo/knowledge/decisions"
cp "$ROOT/bin/search.sh" "$FIXTURE/bin/search.sh"
ln -s "$FIXTURE/memory-repo" "$FIXTURE/memory"
printf '%s\n' '{"org_name":"Fixture","github_org":"fixture","slug":"fixture","mode":"local"}' > "$FIXTURE/egregore.json"
printf '%s\n' '{"account_id":"acct_fixture","actor_id":"actor_fixture","membership_id":"membership_fixture","display_name":"Fixture","membership_status":"active"}' > "$FIXTURE/.egregore-state.json"
printf '%s\n' 'session-fixture' > "$FIXTURE/.egregore-session-id"
printf '%s\n' '# Absolute result' > "$FIXTURE/memory-repo/knowledge/decisions/absolute.md"
printf '%s\n' '# URI result' > "$FIXTURE/memory-repo/knowledge/decisions/with space.md"
# Literal discovery and canonical reads must work without provisioning QMD.
cat > "$FIXTURE/qmd-unavailable" <<'SH'
#!/bin/sh
exit 127
SH
chmod +x "$FIXTURE/qmd-unavailable"
COMMON_ENV=(PYTHONPATH="$ROOT" EGREGORE_ROOT="$FIXTURE" EGREGORE_SEARCH_NO_WARM=1
  EGREGORE_QMD_RUNTIME_DIR="$FIXTURE/runtime" EGREGORE_QMD_PERSISTENT=0
  EGREGORE_QMD_BIN="$FIXTURE/qmd-unavailable")
# This shell fixture deliberately has no native harness session inherited from
# the test runner. Its prompt and commands bind to the fixture session instead.
unset CODEX_THREAD_ID EGREGORE_NATIVE_SESSION_ID EGREGORE_NATIVE_HARNESS EGREGORE_EPISODE_ID
printf '%s\n' '{"prompt":"hello"}' | env "${COMMON_ENV[@]}" \
  python3 -m egregore_runtime.harness_cli prompt-hook --harness shell >/dev/null

HELP=$(bash "$FIXTURE/bin/search.sh" --help)
grep -Fq 'handoffs --mine --status open' <<< "$HELP" || fail 'typed handoff route missing from help'
OUTPUT=$(env "${COMMON_ENV[@]}" bash "$FIXTURE/bin/search.sh" find result --kind literal)
grep -Fq 'memory/knowledge/decisions/absolute.md' <<< "$OUTPUT" || fail 'canonical source missing'
grep -Fq 'memory/knowledge/decisions/with space.md' <<< "$OUTPUT" || fail 'source with spaces missing'
if grep -Fq "$FIXTURE/memory-repo" <<< "$OUTPUT"; then
  fail 'sibling memory path leaked'
fi

# No optional arguments: this previously failed with OPEN_BINDING[@] unbound
# on the macOS Bash 3.2 shell before Runtime received the request.
OPENED=$(env "${COMMON_ENV[@]}" bash "$FIXTURE/bin/search.sh" open memory/knowledge/decisions/absolute.md)
[ "$OPENED" = '# Absolute result' ] || fail 'single source body changed'
BATCH=$(env "${COMMON_ENV[@]}" bash "$FIXTURE/bin/search.sh" open \
  memory/knowledge/decisions/absolute.md 'memory/knowledge/decisions/with space.md')
grep -Fq 'Source: memory/knowledge/decisions/with space.md' <<< "$BATCH" || fail 'batch split a source argument'
grep -Fq '# Absolute result' <<< "$BATCH" || fail 'first batch source missing'
grep -Fq '# URI result' <<< "$BATCH" || fail 'second batch source missing'
WINDOW=$(env "${COMMON_ENV[@]}" bash "$FIXTURE/bin/search.sh" open memory/knowledge/decisions/absolute.md --offset 2 --length 8)
grep -Fq 'Absolute' <<< "$WINDOW" || fail 'source window incorrect'
grep -Fq -- '--offset 10' <<< "$WINDOW" || fail 'source continuation missing'

VISIBLE=$(env "${COMMON_ENV[@]}" bash "$FIXTURE/bin/search.sh" find result --kind literal --context-packet)
grep -Fq 'memory/knowledge/decisions/absolute.md' <<< "$VISIBLE" || fail 'shell evidence hidden in unsupported attachment'
if env "${COMMON_ENV[@]}" bash "$FIXTURE/bin/search.sh" open memory/missing.md >"$FIXTURE/error" 2>&1; then
  fail 'missing source returned success'
fi
[ -s "$FIXTURE/error" ] || fail 'missing source error hidden'
echo 'PASS: shell discovery, canonical paths, batches, windows and error delivery'
