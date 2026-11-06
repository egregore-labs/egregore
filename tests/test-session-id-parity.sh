#!/usr/bin/env bash
# Every harness maps its own session to the Egregore session id it starts,
# and resolves that id for commit trailers. Each harness's real entry chain
# runs in a fixture: Claude's SessionStart stdin, Codex's first-prompt hook,
# Pi's and Prime's extension binding through their start wrappers. Then
# bin/session-id.sh, under that harness's tool-command environment, must
# print the id the start minted after a later start rewrote the shared file.
# The spec surfaces must send agents to the resolver, and every runtime
# bundle must ship it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; FAIL=$((FAIL + 1)); }

echo "test-session-id-parity"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-session-parity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset EGREGORE_NATIVE_SESSION_ID EGREGORE_NATIVE_HARNESS CLAUDE_CODE_SESSION_ID \
  CODEX_THREAD_ID EGREGORE_START_HARNESS EGREGORE_SESSION_ID EGREGORE_ROOT CLAUDE_ENV_FILE
mkdir -p "$HOME" "$WORK/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$WORK/fakebin/gh"
chmod +x "$WORK/fakebin/gh"
export PATH="$WORK/fakebin:$PATH"
export IDENTITY="$ROOT/bin/lib/identity.sh"

FIX="$WORK/instance"
mkdir -p "$FIX/bin"
git -C "$FIX" init -q
git -C "$FIX" config user.name tester
printf '{"github_username":"tester","github_name":"tester"}\n' > "$FIX/.egregore-state.json"
for f in session-id.sh pi-session-start.sh prime-session-start.sh; do cp "$ROOT/bin/$f" "$FIX/bin/$f"; done
# The identity step of bin/codex-session-start.sh, which the Codex launcher
# and both Pi wrappers run: identity.sh sourced in the instance.
cat > "$FIX/bin/codex-session-start.sh" <<'EOF'
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR" || exit 1
STATE_FILE="$SCRIPT_DIR/.egregore-state.json"; ENV_FILE="$SCRIPT_DIR/.env"; HEALTH_GITHUB=""
. "$IDENTITY" >/dev/null 2>&1
printf '%s\n' "$EGREGORE_SESSION_ID"
EOF
grep -q 'source "$SCRIPT_DIR/bin/lib/identity.sh"' "$ROOT/bin/codex-session-start.sh" \
  && ok "the Codex/Pi/Prime start sources identity.sh, as the fixture does" \
  || bad "bin/codex-session-start.sh no longer sources identity.sh"

later_start() { # a later session elsewhere rewrites the shared file
  bash "$FIX/bin/codex-session-start.sh" >/dev/null
}
resolve_as() { # env assignments…
  env -u EGREGORE_NATIVE_SESSION_ID -u EGREGORE_NATIVE_HARNESS -u CLAUDE_CODE_SESSION_ID \
    -u CODEX_THREAD_ID "$@" bash "$ROOT/bin/session-id.sh" --root "$FIX"
}
check_own() { # harness minted env… — after a later start, the harness resolves its own id
  local harness="$1" minted="$2" got; shift 2
  later_start
  [ "$(cat "$FIX/.egregore-session-id")" != "$minted" ] || { bad "$harness: the later start did not rewrite the shared file"; return; }
  got="$(resolve_as "$@")"
  if [ -n "$minted" ] && [ "$got" = "$minted" ]; then
    ok "$harness resolves the id its own start minted"
  else
    bad "$harness resolves another session's id" "minted '$minted', resolved '$got'"
  fi
}

echo "Claude: SessionStart hook stdin"
if jq -e '[.hooks.SessionStart[] | select(.matcher == "startup") | .hooks[].command
    | select(test("bin/session-start.sh"))] | length == 1' "$ROOT/.claude/settings.json" >/dev/null; then
  ok "the startup SessionStart hook runs bin/session-start.sh"
else
  bad "the startup SessionStart hook does not run bin/session-start.sh"
fi
# The real stdin block of bin/session-start.sh, then identity.sh as it follows.
BLOCK="$WORK/claude-start.sh"
{
  echo 'SCRIPT_DIR="$1"; cd "$SCRIPT_DIR" || exit 1'
  awk '/^# Claude Code hands this hook its own session id on stdin/ { on = 1 }
       on && /^source "\$SCRIPT_DIR\/bin\/lib\/identity.sh"/ { exit }
       on { print }' "$ROOT/bin/session-start.sh"
  echo 'STATE_FILE="$SCRIPT_DIR/.egregore-state.json"; ENV_FILE="$SCRIPT_DIR/.env"; HEALTH_GITHUB=""'
  echo '. "$IDENTITY" >/dev/null 2>&1'
  echo 'printf "%s %s %s\n" "$EGREGORE_SESSION_ID" "${EGREGORE_NATIVE_HARNESS:-}" "${EGREGORE_START_HARNESS:-}"'
} > "$BLOCK"
grep -q 'session_id' "$BLOCK" || bad "bin/session-start.sh lost its stdin block before identity.sh"
CLAUDE_ID=6c1f4e0a-2b3d-4e5f-8a9b-0c1d2e3f4a5b
HOOK_JSON="{\"session_id\":\"$CLAUDE_ID\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
# Claude Code sets CLAUDE_ENV_FILE for SessionStart hooks only.
out="$(printf '%s' "$HOOK_JSON" | CLAUDE_ENV_FILE="$WORK/claude-env" bash "$BLOCK" "$FIX")"
set -- $out
[ "${2:-}" = claude ] && [ "${3:-}" = claude ] \
  && ok "the hook's session_id binds the Claude session before identity.sh" || bad "Claude binding" "$out"
check_own claude "${1:-}" EGREGORE_NATIVE_HARNESS=claude EGREGORE_NATIVE_SESSION_ID="$CLAUDE_ID" \
  CLAUDE_CODE_SESSION_ID="$CLAUDE_ID"
out="$(CLAUDE_ENV_FILE="$WORK/claude-env" bash "$BLOCK" "$FIX" < /dev/null)"
set -- $out
[ -z "${2:-}" ] && [ -z "${3:-}" ] && ok "a hook run without input binds nothing" || bad "empty stdin bound" "$out"
out="$(printf '%s' "$HOOK_JSON" | bash "$BLOCK" "$FIX")"
set -- $out
[ -z "${2:-}" ] && [ -z "${3:-}" ] && ok "a run outside the hook ignores stdin" || bad "non-hook run read stdin" "$out"
# A non-hook run whose stdin stays open and silent never waits on it.
started=$SECONDS
( sleep 5 | bash "$BLOCK" "$FIX" > "$WORK/silent.out" ) &
waiter=$!
while kill -0 "$waiter" 2>/dev/null && [ ! -s "$WORK/silent.out" ] && [ $((SECONDS - started)) -lt 5 ]; do sleep 0.2; done
[ -s "$WORK/silent.out" ] && [ $((SECONDS - started)) -lt 3 ] \
  && ok "a run outside the hook never waits on an open stdin" || bad "non-hook run waited on stdin" "$((SECONDS - started))s"
wait "$waiter" 2>/dev/null

echo "Codex: launcher start, then the first prompt"
grep -q 'observe-context.sh\\" codex' "$ROOT/.codex/hooks.json" \
  && ok "Codex's UserPromptSubmit hook runs the codex prompt hook" || bad "Codex prompt hook missing"
CODEX_MINTED="$(bash "$FIX/bin/codex-session-start.sh")"
CODEX_ID=019a0d4e-1f2a-7b3c-8d4e-5f6a7b8c9d0e
EGREGORE_ROOT="$FIX" PYTHONSAFEPATH=1 PYTHONPATH="$ROOT" python3 - "$CODEX_ID" <<'PY' >/dev/null 2>&1
import argparse, io, json, sys
from egregore_runtime import harness_cli
sys.stdin = io.StringIO(json.dumps({"prompt": "hello", "session_id": sys.argv[1]}))
try:
    harness_cli._prompt_hook(argparse.Namespace(harness="codex", limit=6))
except Exception:
    pass  # the fixture has no Runtime; the bind runs before it is needed
PY
[ -f "$HOME/.egregore/sessions/codex-$CODEX_ID.id" ] \
  && ok "the first prompt maps the Codex thread" || bad "the Codex prompt hook recorded no map"
check_own codex "$CODEX_MINTED" CODEX_THREAD_ID="$CODEX_ID"
EGREGORE_ROOT="$FIX" PYTHONSAFEPATH=1 PYTHONPATH="$ROOT" python3 - <<'PY' >/dev/null 2>&1
import argparse, io, json, sys
from egregore_runtime import harness_cli
sys.stdin = io.StringIO(json.dumps({"prompt": "hello", "session_id": "claude-prompt-only"}))
try:
    harness_cli._prompt_hook(argparse.Namespace(harness="claude", limit=6))
except Exception:
    pass
PY
[ ! -e "$HOME/.egregore/sessions/claude-claude-prompt-only.id" ] \
  && ok "Claude's prompt hook leaves mapping to its session start" || bad "Claude prompt hook mapped"

for harness in pi prime; do
  echo "${harness}: extension binding through bin/${harness}-session-start.sh"
  case "$harness" in
    pi) ext="$ROOT/.pi/extensions/egregore.ts" ;;
    prime) ext="$ROOT/.prime/agent/extensions/egregore.ts" ;;
  esac
  handler="$(awk '/pi.on\("session_start"/ { on = 1 } on { print } on && /^  }\);/ { exit }' "$ext")"
  bind_line="$(printf '%s\n' "$handler" | grep -n "bindNativeSession(ctx, \"$harness\", root)" | head -1 | cut -d: -f1)"
  card_line="$(printf '%s\n' "$handler" | grep -n 'renderGreeting(' | head -1 | cut -d: -f1)"
  if [ -n "$bind_line" ] && [ -n "$card_line" ] && [ "$bind_line" -lt "$card_line" ]; then
    ok "$harness's session_start binds its session before the card renders"
  else
    bad "$harness's session_start does not bind before renderGreeting"
  fi
  # The extension's binding, then its card command, as Pi runs them.
  minted="$(cd "$ROOT" && node --input-type=module -e '
    import { bindNativeSession } from "./bin/pi-observe-context.mjs";
    import { spawnSync } from "node:child_process";
    const [harness, root] = process.argv.slice(1);
    const id = bindNativeSession({ sessionManager: { getSessionFile: () => `${root}/${harness}.jsonl` } }, harness, root);
    const card = spawnSync("bash", [`${root}/bin/${harness}-session-start.sh`, "--card"], { encoding: "utf8" });
    process.stdout.write(`${card.stdout.trim()} ${id} ${process.env.EGREGORE_NATIVE_HARNESS}`);
  ' "$harness" "$FIX")"
  set -- $minted
  [ "${3:-}" = "$harness" ] && [ -n "${2:-}" ] \
    && ok "$harness binds EGREGORE_NATIVE_SESSION_ID under its own harness name" || bad "$harness binding" "$minted"
  check_own "$harness" "${1:-}" EGREGORE_NATIVE_HARNESS="$harness" EGREGORE_NATIVE_SESSION_ID="${2:-}"
done

echo "Spec surfaces send agents to the resolver"
SURFACES=(CLAUDE.md AGENTS.md .pi/APPEND_SYSTEM.md .prime/agent/APPEND_SYSTEM.md
  .claude/context/commit-format.md .claude/skills/commit/SKILL.md)
for runtime in claude codex pi prime; do
  for f in AGENTS.md .pi/APPEND_SYSTEM.md .prime/agent/APPEND_SYSTEM.md \
      .claude/context/commit-format.md .claude/skills/commit/SKILL.md; do
    [ -f "$ROOT/packages/create-egregore/runtime/$runtime/$f" ] \
      && SURFACES+=("packages/create-egregore/runtime/$runtime/$f")
  done
done
for f in "${SURFACES[@]}"; do
  if grep -q 'bin/session-id.sh' "$ROOT/$f" \
     && ! grep -q 'Egregore-Session: <id>` from `.egregore-session-id`' "$ROOT/$f" \
     && ! grep -qx '  cat .egregore-session-id' "$ROOT/$f"; then
    ok "$f names bin/session-id.sh for the trailer"
  else
    bad "$f still sends agents to .egregore-session-id for the trailer"
  fi
done

echo "Runtime wrappers resolve memory-commit ids, every harness alike"
stale="$(cd "$ROOT" && grep -l 'EGREGORE_SESSION_ID:-$(cat ' bin/*.sh 2>/dev/null | tr '\n' ' ')"
[ -z "$stale" ] && ok "no bin wrapper takes EGREGORE_SESSION_ID from the shared file first" \
  || bad "wrappers still read the shared file first: $stale"

echo "Runtime bundles ship the resolver"
for runtime in claude codex pi prime; do
  bundle="$ROOT/packages/create-egregore/runtime/$runtime"
  if cmp -s "$ROOT/bin/session-id.sh" "$bundle/bin/session-id.sh" \
     && cmp -s "$ROOT/bin/lib/git-message.sh" "$bundle/bin/lib/git-message.sh"; then
    ok "$runtime bundle carries bin/session-id.sh and git-message.sh"
  else
    bad "$runtime bundle is missing the resolver (npm run build:runtime --prefix packages/create-egregore)"
  fi
done

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
