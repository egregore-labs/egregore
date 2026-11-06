#!/usr/bin/env bash
set -Eeuo pipefail
# A stop under set -e is otherwise silent: name the command and its status (-E: inside functions too).
trap 'echo "  stopped at line $LINENO (status $?): $BASH_COMMAND" >&2' ERR

# Test: the memory map's two notices (experiments/egregore-mind/AGENT-SPEC.md
# §3.6 and §9.4) behave the same from Claude Code, Codex and Pi. Both are
# written by egregore_runtime/harness_cli.py; this drives them only through
# each runtime's own entry points:
#   question asked: the shipped prompt hook (bin/observe-context.sh, which
#     runs harness_cli prompt-hook) through Claude Code's settings command,
#     Codex's hooks.json command, and Pi's registerObserveHook in
#     bin/pi-observe-context.mjs.
#   Runtime notice: the shipped bin/search.sh find and open under each
#     runtime's session variables.
#   Delivery: Claude's evidence travels as an attachment, so its own
#     PostToolUse hook (.claude/hooks/retrieval-context.sh, as settings runs
#     it) confirms each one it attached.
# A fixture instance and a stand-in map door (door.json naming the checkout it
# serves, plus a heartbeat) replace the organization and the map; nothing
# reads real memory.
# Checks: inert without a live map, with a stale heartbeat, or with a map that
# serves another checkout; one notice per call from every entry, identical
# across runtimes apart from who and when; no prompt, query or document text;
# hook and search output unchanged; a Codex worker started from a Claude shell
# is one agent in its question and its search. The instance door (trail CONTRACT §1, a
# map opened with serve.py --instance) takes notices from the main checkout
# and a linked task workspace, and nothing from another instance, through a
# link below the instance root, or from a checkout with a forged .git file;
# a map without it still gets nothing from another checkout.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
OUTSIDE="$(mktemp -d)"
BEATER=
# Only the test's own shell cleans up: some bash builds run this trap in a killed background loop too.
cleanup() { [ "${BASHPID:-$$}" = "$$" ] || return 0; [ -n "$BEATER" ] && kill "$BEATER" 2>/dev/null; rm -rf "$FIXTURE" "$OUTSIDE"; }
trap cleanup EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; return 0; }

echo "Testing: memory map notices across Claude Code, Codex and Pi"
echo ""

# --- fixture instance -------------------------------------------------------
mkdir -p "$FIXTURE/bin" "$FIXTURE/.claude/hooks" "$FIXTURE/memory-repo/knowledge/decisions"
cp "$ROOT/bin/search.sh" "$ROOT/bin/observe-context.sh" "$ROOT/bin/pi-observe-context.mjs" "$FIXTURE/bin/"
cp "$ROOT/.claude/hooks/retrieval-context.sh" "$FIXTURE/.claude/hooks/"
ln -s "$FIXTURE/memory-repo" "$FIXTURE/memory"
printf '%s\n' '{"org_name":"Fixture","github_org":"fixture","slug":"fixture","mode":"local"}' > "$FIXTURE/egregore.json"
printf '%s\n' '{"account_id":"acct_fixture","actor_id":"actor_fixture","membership_id":"membership_fixture","display_name":"Fixture","membership_status":"active"}' > "$FIXTURE/.egregore-state.json"
printf '%s\n' 'session-fixture' > "$FIXTURE/.egregore-session-id"
printf -- '---\ntitle: Striped animals\ndate: 2026-09-01\n---\nzebra. The quartz walrus sentence lives only in the body.\n' \
  > "$FIXTURE/memory-repo/knowledge/decisions/zebra-notes.md"
printf '#!/bin/sh\nexit 127\n' > "$FIXTURE/qmd-unavailable"
chmod +x "$FIXTURE/qmd-unavailable"
git -C "$FIXTURE" init -q   # Codex's hook command finds the root with git rev-parse

unset CODEX_THREAD_ID EGREGORE_NATIVE_SESSION_ID EGREGORE_NATIVE_HARNESS EGREGORE_EPISODE_ID \
  EGREGORE_SESSION_ID EGREGORE_ROOT EGREGORE_RUNTIME MIND_HOME CLAUDE_PROJECT_DIR
export PYTHONPATH="$ROOT" EGREGORE_SEARCH_NO_WARM=1 EGREGORE_QMD_PERSISTENT=0 \
  EGREGORE_QMD_RUNTIME_DIR="$FIXTURE/.qmd-runtime" EGREGORE_QMD_BIN="$FIXTURE/qmd-unavailable"
# The Runtime keeps lifecycle and telemetry under ~/.egregore: a run must not leave them in the real home.
mkdir -p "$FIXTURE/home"
export HOME="$FIXTURE/home"

CLAUDE_HOOK="$(jq -r '.hooks.UserPromptSubmit[].hooks[].command | select(contains("observe-context.sh"))' "$ROOT/.claude/settings.json")"
CLAUDE_RESULT_HOOK="$(jq -r '.hooks.PostToolUse[].hooks[].command | select(contains("retrieval-context.sh"))' "$ROOT/.claude/settings.json")"
CODEX_HOOK="$(jq -r '.hooks.UserPromptSubmit[].hooks[].command | select(contains("observe-context.sh"))' "$ROOT/.codex/hooks.json")"
PROMPT='PROMPTMARK where did our attention go'
DOC=memory/knowledge/decisions/zebra-notes.md
PI_DRIVER='
const [module, root, prompt, session] = process.argv.slice(1);
const { registerObserveHook } = await import(module);
let handler;
registerObserveHook({ on(_name, value) { handler = value; } }, { root, harness: "pi" });
const result = await handler({ prompt }, { sessionManager: { getSessionFile: () => `${root}/pi-${session}.jsonl` } });
process.stdout.write(String(result?.message?.content ?? ""));
'
pi_native() { printf '%s' "${AT:-$FIXTURE}/pi-$1.jsonl" | shasum -a 256 | cut -d' ' -f1; }

# The checkout an agent runs in: the fixture's main checkout unless AT names another.
# hook <runtime> <session>: the runtime's own prompt-hook entry, prompt on stdin.
hook() {
  local payload at="${AT:-$FIXTURE}"
  payload="$(printf '{"session_id":"%s","prompt":"%s"}' "$2" "$PROMPT")"
  case "$1" in
    claude) printf '%s\n' "$payload" | (cd "$at" && env CLAUDE_PROJECT_DIR="$at" \
      EGREGORE_NATIVE_SESSION_ID="$2" EGREGORE_NATIVE_HARNESS=claude bash -c "$CLAUDE_HOOK") ;;
    codex) printf '%s\n' "$payload" | (cd "$at" && env CODEX_THREAD_ID="$2" bash -c "$CODEX_HOOK") ;;
    pi) (cd "$at" && node --input-type=module -e "$PI_DRIVER" "$at/bin/pi-observe-context.mjs" "$at" "$PROMPT" "$2") ;;
  esac
}

# search <runtime> <session> <search.sh args…>: the agent's own Runtime call.
search() {
  local runtime="$1" session="$2" at="${AT:-$FIXTURE}"
  shift 2
  case "$runtime" in
    claude) (cd "$at" && env EGREGORE_NATIVE_SESSION_ID="$session" EGREGORE_NATIVE_HARNESS=claude \
      EGREGORE_RUNTIME=claude-code bash bin/search.sh "$@") ;;
    codex) (cd "$at" && env CODEX_THREAD_ID="$session" EGREGORE_RUNTIME=codex bash bin/search.sh "$@") ;;
    pi) (cd "$at" && env EGREGORE_NATIVE_SESSION_ID="$(pi_native "$session")" EGREGORE_NATIVE_HARNESS=pi \
      EGREGORE_RUNTIME=pi bash bin/search.sh "$@") ;;
  esac
}

# Per-prompt ids and attachment receipts differ between any two runs.
normalize() { sed -E 's/ep_[0-9a-f]{32}/ep_<id>/g; s/"id":"[0-9a-f]{32}"/"id":"<id>"/g'; }
expected_actor() {
  case "$1" in claude) echo "claude/$2" ;; codex) echo "codex/$2" ;; pi) echo "pi/$(pi_native "$2")" ;; esac
}

HOME_DEFAULT="$FIXTURE/experiments/egregore-mind/.mind"
SERVED="$(cd "$FIXTURE" && pwd -P)"
# open_map <home> [checkout]: a stand-in map with a heartbeat kept fresh, as serve.py does;
# its door.json names the checkout it serves (default the fixture, "" for none).
open_map() {
  local serves="${2-$SERVED}"
  mkdir -p "$1/door"
  chmod 700 "$1/door"
  if [ -n "$serves" ]; then
    printf '{\n "port": 1,\n "door": "%s",\n "root": "%s"\n}\n' "$1/door" "$serves" > "$1/door.json"
  else
    printf '{\n "port": 1,\n "door": "%s"\n}\n' "$1/door" > "$1/door.json"
  fi
  beat "$1/door"
}
beat() {   # beat <door>: keep its heartbeat fresh, as serve.py does
  touch "$1/heartbeat"
  stop_beat
  ( trap - EXIT ERR; while :; do touch "$1/heartbeat"; sleep 0.5; done ) &
  BEATER=$!
}
# open_instance_map <instance> [named]: a stand-in map opened with serve.py --instance; its door
# sits under <instance>/.egregore/runtime/mind and its door.json names an installation (default
# <instance> itself), never a checkout.
open_instance_map() {
  local home="$1/.egregore/runtime/mind" named
  named="${2:-$(cd "$1" && pwd -P)}"
  mkdir -p "$home/door"
  chmod 700 "$home/door"
  printf '{\n "instance": "%s",\n "run": "i",\n "port": 1,\n "door": "%s",\n "started": "s"\n}\n' \
    "$named" "$home/door" > "$home/door.json"
  beat "$home/door"
}
stop_beat() { if [ -n "$BEATER" ]; then kill "$BEATER" 2>/dev/null || true; wait "$BEATER" 2>/dev/null || true; BEATER=; fi; }
count() { { find "$1" -maxdepth 1 -name "$2" -type f 2>/dev/null || true; } | wc -l | tr -d ' '; }
# take <door> <pattern> <destination>: move the one notice a call left, or fail.
take() {
  local found
  found="$(find "$1" -maxdepth 1 -name "$2" -type f)"
  if [ -n "$found" ] && [ "$(count "$1" "$2")" = 1 ]; then mv "$found" "$3"; return 0; fi
  : > "$3"
  return 1
}

RUNTIMES="claude codex pi"
FIND=(find zebra --kind literal -n 6 --context-packet)   # literal needs no search index
OPEN=(open "$DOC" --context-packet)

# --- 1. No map: nothing is written and no folder appears ----------------------
for runtime in $RUNTIMES; do
  hook "$runtime" "$runtime-a" | normalize > "$OUTSIDE/hook-none-$runtime"
  search "$runtime" "$runtime-a" "${FIND[@]}" | normalize > "$OUTSIDE/find-none-$runtime"
  search "$runtime" "$runtime-a" "${OPEN[@]}" | normalize > "$OUTSIDE/open-none-$runtime"
done
if [ ! -e "$FIXTURE/experiments" ]; then
  pass "no map: three hooks, three finds and three opens wrote nothing and made no folder"
else
  fail "no map: something was written" "$(find "$FIXTURE/experiments" | head -5)"
fi

# --- 2. Stale heartbeat: a map that stopped beating gets nothing --------------
open_map "$HOME_DEFAULT"
stop_beat
touch -t 202001010000 "$HOME_DEFAULT/door/heartbeat"
for runtime in $RUNTIMES; do
  hook "$runtime" "$runtime-s" > /dev/null
  search "$runtime" "$runtime-s" "${FIND[@]}" > /dev/null
done
if [ "$(count "$HOME_DEFAULT/door" 'asked-*')$(count "$HOME_DEFAULT/door" 'seen-*')" = 00 ]; then
  pass "stale heartbeat: nothing written"
else
  fail "stale heartbeat: notices were written" "$(ls "$HOME_DEFAULT/door")"
fi

# --- 3. Live map: one notice per call, identical across runtimes --------------
rm -rf "$FIXTURE/experiments"
open_map "$HOME_DEFAULT"
DOOR="$HOME_DEFAULT/door"
mkdir -p "$OUTSIDE/notices"
one=1
for runtime in $RUNTIMES; do
  hook "$runtime" "$runtime-b" | normalize > "$OUTSIDE/hook-live-$runtime"
  take "$DOOR" 'asked-*' "$OUTSIDE/notices/asked-$runtime" && [ "$(count "$DOOR" 'seen-*')" = 0 ] || one=0
  for call in find open; do
    if [ "$call" = find ]; then args=("${FIND[@]}"); else args=("${OPEN[@]}"); fi
    search "$runtime" "$runtime-b" "${args[@]}" | normalize > "$OUTSIDE/$call-live-$runtime"
    take "$DOOR" 'seen-*' "$OUTSIDE/notices/seen-$call-$runtime" && [ "$(count "$DOOR" 'asked-*')" = 0 ] || one=0
  done
done
stop_beat
if [ "$one" = 1 ] && [ "$(count "$DOOR" '.seen-*')" = 0 ]; then
  pass "live map: each hook left one asked notice, each find and open one Runtime notice"
else
  fail "live map: a call left no notice, or more than one" "$(ls -A "$DOOR" "$OUTSIDE/notices")"
fi

for runtime in $RUNTIMES; do
  if cmp -s "$OUTSIDE/hook-none-$runtime" "$OUTSIDE/hook-live-$runtime" &&
     cmp -s "$OUTSIDE/find-none-$runtime" "$OUTSIDE/find-live-$runtime" &&
     cmp -s "$OUTSIDE/open-none-$runtime" "$OUTSIDE/open-live-$runtime" &&
     [ -s "$OUTSIDE/hook-live-$runtime" ] && [ -s "$OUTSIDE/find-live-$runtime" ]; then
    pass "$runtime: hook, find and open output unchanged by a live map"
  else
    fail "$runtime: output changed with a live map" \
      "$(diff "$OUTSIDE/find-none-$runtime" "$OUTSIDE/find-live-$runtime" | head -4)"
  fi
  asked="$(jq -c '{harness, actor}' "$OUTSIDE/notices/asked-$runtime" 2>/dev/null || true)"
  want="$(jq -cn --arg h "$runtime" --arg a "$(expected_actor "$runtime" "$runtime-b")" '{harness: $h, actor: $a}')"
  if [ "$asked" = "$want" ]; then
    pass "$runtime hook: asked notice names its harness and session"
  else
    fail "$runtime hook: asked notice has the wrong harness or session" "got $asked, want $want"
  fi
  seen_actor="$(jq -r .actor "$OUTSIDE/notices/seen-find-$runtime" 2>/dev/null || true)"
  if [ "$seen_actor" = "$(expected_actor "$runtime" "$runtime-b")" ]; then
    pass "$runtime search: Runtime notice names the same session as the hook"
  else
    fail "$runtime search: Runtime notice names another session" "$seen_actor"
  fi
done

identical() {   # identical <label> <file stem> <jq filter>
  local first='' same=1 runtime shape
  for runtime in $RUNTIMES; do
    shape="$(jq -cS "$3" "$OUTSIDE/notices/$2-$runtime" 2>/dev/null || true)"
    [ -z "$first" ] && first="$shape"
    [ "$shape" = "$first" ] && [ -n "$shape" ] || same=0
  done
  if [ "$same" = 1 ]; then pass "$1"; else fail "$1" "$first"; fi
}
# Who and when differ by design; so does delivery (Claude's evidence travels as an attachment).
WHO='del(.t, .actor, .harness, .episode, .invocation, .delivery, .packet)'
identical "asked notices identical from all three entry points" asked "del(.t, .actor, .harness)"
identical "find notices identical from all three runtimes" seen-find "$WHO"
identical "open notices identical from all three runtimes" seen-open "$WHO"

note="$OUTSIDE/notices/seen-find-codex"
if jq -e --arg doc "$DOC" '.v == 2 and .k == "seen" and .call == "find" and .kind == "literal"
    and .workspace == "main" and (has("query") | not) and (has("root") | not)
    and .paths == [$doc] and .opened == [] and (.searches_left | type) == "number"
    and (.coverage | has("degraded") and has("absent_or_stale") and has("more") and has("reach"))
    and .ok == true' "$note" > /dev/null; then
  pass "find notice carries kind, paths, budget, coverage and workspace; no query words or root"
else
  fail "find notice is missing a field" "$(cat "$note")"
fi
if jq -e --arg doc "$DOC" '.call == "open" and .opened == [$doc] and (.reads_left | type) == "number"' \
    "$OUTSIDE/notices/seen-open-codex" > /dev/null; then
  pass "open notice carries the opened path and reads left"
else
  fail "open notice is missing a field" "$(cat "$OUTSIDE/notices/seen-open-codex")"
fi
if grep -rqE 'PROMPTMARK|quartz|walrus|Striped animals|"zebra"' "$OUTSIDE/notices"; then
  fail "a notice carries prompt, query or document text" "$(grep -rlE 'PROMPTMARK|quartz|walrus|Striped|"zebra"' "$OUTSIDE/notices")"
else
  pass "no prompt text, query words, document text or title in any notice"
fi
modes="$(find "$OUTSIDE/notices" -type f -size +0 \( -perm -040 -o -perm -004 \) | wc -l | tr -d ' ')"
if [ "$modes" = 0 ]; then pass "notices are readable by their owner only"; else fail "$modes notices readable by others"; fi

# --- 3b. A Codex worker started from a Claude shell is one agent ------------------
# Claude's session-env exports EGREGORE_NATIVE_* into every Bash command, so a Codex worker
# started there (a minion, codex:rescue) carries them beside its own CODEX_THREAD_ID. Its prompt
# hook (Codex's hooks.json command) and its search.sh find must both name codex/<thread>.
rm -rf "$FIXTURE/experiments"
open_map "$HOME_DEFAULT"
hook claude claude-w > /dev/null   # the parent Claude session asked first
take "$DOOR" 'asked-*' "$OUTSIDE/worker-parent-asked" || true
worker() { env EGREGORE_NATIVE_SESSION_ID=claude-w EGREGORE_NATIVE_HARNESS=claude CODEX_THREAD_ID=codex-w "$@"; }
printf '{"session_id":"codex-w","prompt":"%s"}\n' "$PROMPT" | (cd "$FIXTURE" && worker bash -c "$CODEX_HOOK") > /dev/null
take "$DOOR" 'asked-*' "$OUTSIDE/notices/worker-asked" || true
(cd "$FIXTURE" && worker env EGREGORE_RUNTIME=codex bash bin/search.sh "${FIND[@]}") > /dev/null
take "$DOOR" 'seen-*' "$OUTSIDE/notices/worker-seen" || true
stop_beat
worker_actors="$(jq -r .actor "$OUTSIDE/notices/worker-asked" "$OUTSIDE/notices/worker-seen" 2>/dev/null | tr '\n' ' ')"
if [ "$worker_actors" = "codex/codex-w codex/codex-w " ]; then
  pass "Codex worker under a Claude shell: its question and its search name one agent"
else
  fail "Codex worker under a Claude shell: question and search name different agents" "got: $worker_actors"
fi

# --- 4. A home named with MIND_HOME is used wherever it is ---------------------
rm -rf "$FIXTURE/experiments"
open_map "$OUTSIDE/named"
export MIND_HOME="$OUTSIDE/named"
hook claude claude-n > /dev/null
search claude claude-n "${FIND[@]}" > /dev/null
unset MIND_HOME
stop_beat
if [ "$(count "$OUTSIDE/named/door" 'asked-*')$(count "$OUTSIDE/named/door" 'seen-*')" = 11 ] && [ ! -e "$FIXTURE/experiments" ]; then
  pass "MIND_HOME: both notices go to the named home"
else
  fail "MIND_HOME: notices missing from the named home" "$(ls "$OUTSIDE/named/door")"
fi

# --- 4b. A named home whose map serves another checkout gets nothing --------------
# A MIND_HOME left set in a shell profile must not pull every checkout's questions,
# queries and paths into one map (§3.3: nothing is written outside the agent's workspace).
mkdir -p "$OUTSIDE/elsewhere"
for serves in "$(cd "$OUTSIDE/elsewhere" && pwd -P)" ""; do
  rm -rf "$OUTSIDE/foreign"
  open_map "$OUTSIDE/foreign" "$serves"
  export MIND_HOME="$OUTSIDE/foreign"
  for runtime in $RUNTIMES; do
    hook "$runtime" "$runtime-f" > /dev/null
    search "$runtime" "$runtime-f" "${FIND[@]}" > /dev/null
  done
  unset MIND_HOME
  stop_beat
  label="${serves:+another checkout}"
  if [ "$(ls -A "$OUTSIDE/foreign/door")" = heartbeat ] && [ ! -e "$FIXTURE/experiments" ]; then
    pass "MIND_HOME map serving ${label:-no named checkout}: three hooks and three finds wrote nothing"
  else
    fail "MIND_HOME map serving ${label:-no named checkout}: notices crossed into it" "$(ls "$OUTSIDE/foreign/door")"
  fi
done

# --- 5. A default home that leaves the checkout, or a door others can read ----
mkdir -p "$FIXTURE/experiments/egregore-mind"
open_map "$OUTSIDE/linked"
ln -s "$OUTSIDE/linked" "$HOME_DEFAULT"
hook claude claude-l > /dev/null
search claude claude-l "${FIND[@]}" > /dev/null
stop_beat
if [ "$(count "$OUTSIDE/linked/door" 'asked-*')$(count "$OUTSIDE/linked/door" 'seen-*')" = 00 ]; then
  pass "a default home linked outside the checkout gets nothing"
else
  fail "notices followed a link out of the checkout" "$(ls "$OUTSIDE/linked/door")"
fi
rm -f "$HOME_DEFAULT"
open_map "$HOME_DEFAULT"
chmod 755 "$HOME_DEFAULT/door"
hook pi pi-o > /dev/null
search pi pi-o "${FIND[@]}" > /dev/null
stop_beat
if [ "$(count "$HOME_DEFAULT/door" 'asked-*')$(count "$HOME_DEFAULT/door" 'seen-*')" = 00 ]; then
  pass "a door others can read gets nothing"
else
  fail "notices written into a door others can read" "$(ls "$HOME_DEFAULT/door")"
fi

# --- 6. A writer that stalls holds nothing up -----------------------------------
# The Runtime as search.sh runs it, with only the notice writer replaced by one that
# sleeps for 5 s (a stalled filesystem): same output, nothing on stderr, exit 0, and
# the process ends without waiting for the writer.
rm -rf "$FIXTURE/experiments"
open_map "$HOME_DEFAULT"
hook codex codex-x > /dev/null
STALL='import sys, time
from egregore_runtime import harness_cli
harness_cli._mind_write = lambda *args: time.sleep(5)
sys.argv = ["egregore", *sys.argv[1:]]
raise SystemExit(harness_cli.main())'
started="$(python3 -c 'import time; print(time.time())')"
code=0
(cd "$FIXTURE" && env CODEX_THREAD_ID=codex-x EGREGORE_RUNTIME=codex EGREGORE_ROOT="$FIXTURE" PYTHONSAFEPATH=1 \
  python3 -c "$STALL" find zebra --kind literal -n 6 --private-result) > "$OUTSIDE/stall.out" 2> "$OUTSIDE/stall.err" || code=$?
elapsed="$(python3 -c "import time; print(round(time.time() - $started, 2))")"
stop_beat
if [ "$code" = 0 ] && cmp -s "$OUTSIDE/stall.out" "$OUTSIDE/find-none-codex" && [ ! -s "$OUTSIDE/stall.err" ] &&
   python3 -c "import sys; sys.exit(0 if $elapsed < 2 else 1)"; then
  pass "a stalled writer: same output, empty stderr, exit 0, process ended in ${elapsed}s"
else
  fail "a stalled writer changed the call" "exit $code, ${elapsed}s, stderr: $(head -c 200 "$OUTSIDE/stall.err")"
fi

# --- 7. Claude's attachment counts once its own hook attaches it -----------------
# The find only prepares the evidence; the PostToolUse hook settings runs attaches it.
# A delivered notice names the same packet as the find's notice; a refused one leaves none.
rm -rf "$FIXTURE/experiments"
open_map "$HOME_DEFAULT"
hook claude claude-d > /dev/null
attach() {   # attach <session>: the settings PostToolUse command consuming the last find's receipt
  jq -cn --arg out "$(cat "$OUTSIDE/attach.out")" --arg s "$1" \
    '{tool_name: "Bash", tool_input: {command: "bash bin/search.sh find zebra --kind literal --context-packet"},
      tool_response: {stdout: $out}, session_id: $s}' |
    (cd "${AT:-$FIXTURE}" && env CLAUDE_PROJECT_DIR="${AT:-$FIXTURE}" bash -c "$CLAUDE_RESULT_HOOK")
}
delivered=()
for consumer in claude-d claude-other; do
  search claude claude-d "${FIND[@]}" > "$OUTSIDE/attach.out"
  attach "$consumer" > "$OUTSIDE/attach-$consumer.json"
  take "$DOOR" 'seen-*' "$OUTSIDE/notices/attach-seen-$consumer" || true
  if take "$DOOR" 'delivered-*' "$OUTSIDE/notices/attach-delivered-$consumer"; then delivered+=("$consumer"); fi
done
stop_beat
packet="$(jq -r .packet "$OUTSIDE/notices/attach-seen-claude-d" 2>/dev/null || true)"
if grep -q EGREGORE_RETRIEVAL_CONTEXT_V1 "$OUTSIDE/attach-claude-d.json" &&
   grep -q 'could not be attached' "$OUTSIDE/attach-claude-other.json" &&
   [ "${delivered[*]-}" = claude-d ] && [ -n "$packet" ] && [ "$packet" != null ] &&
   jq -e --arg p "$packet" '.k == "delivered" and .packet == $p and .actor == "claude/claude-d"' \
     "$OUTSIDE/notices/attach-delivered-claude-d" > /dev/null; then
  pass "Claude: the attached result is confirmed by its packet; a refused one stays unconfirmed"
else
  fail "Claude: delivery not confirmed, or confirmed when refused" \
    "delivered for: ${delivered[*]-none}; seen packet $packet; $(head -c 160 "$OUTSIDE/attach-claude-other.json")"
fi
receipt="$(sed -n 's/^EGREGORE_RUNTIME_PACKET=//p' "$OUTSIDE/attach.out" | jq -r .id)"
if [ -n "$receipt" ] && ! grep -rq "$receipt" "$OUTSIDE/notices"; then
  pass "no notice carries the attachment receipt itself"
else
  fail "a notice carries the attachment receipt" "$receipt"
fi

# --- 8. The instance door: one map sees every checkout of its installation -------
# A map opened with serve.py --instance keeps a door at <instance>/.egregore/runtime/mind whose
# door.json names the installation, never a checkout (trail CONTRACT §1). Through each runtime's
# own entry points: the main checkout and a linked task workspace land there; another instance's
# map gets nothing, even through a stale MIND_HOME; a map without that door gets nothing from
# another checkout; a link below the instance root, or a forged .git file, gets nothing.
stop_beat
rm -rf "$FIXTURE/experiments"
git -C "$FIXTURE" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null commit -q --allow-empty --no-verify -m fixture
TASK="$FIXTURE/.claude/worktrees/topic"
git -C "$FIXTURE" -c core.hooksPath=/dev/null worktree add -q --detach "$TASK"
populate() {   # populate <checkout>: the files a checkout of the fixture instance carries
  mkdir -p "$1/bin" "$1/.claude/hooks"
  cp "$ROOT/bin/search.sh" "$ROOT/bin/observe-context.sh" "$ROOT/bin/pi-observe-context.mjs" "$1/bin/"
  cp "$ROOT/.claude/hooks/retrieval-context.sh" "$1/.claude/hooks/"
  cp "$FIXTURE/egregore.json" "$FIXTURE/.egregore-state.json" "$FIXTURE/.egregore-session-id" "$1/"
  ln -sfn "$FIXTURE/memory-repo" "$1/memory"
}
populate "$TASK"
INSTANCE_DOOR="$FIXTURE/.egregore/runtime/mind/door"
nothing_in() { [ "$(ls -A "$1" 2>/dev/null)" = heartbeat ]; }
# agents <checkout> <session suffix>: each runtime's hook, find and open, run in that checkout.
# A call the Runtime itself refuses (its state must not leave the instance) still counts: it wrote nothing.
agents() {
  local runtime
  for runtime in $RUNTIMES; do
    AT="$1" hook "$runtime" "$runtime-$2" > "$OUTSIDE/agents-hook-$runtime" || true
    AT="$1" search "$runtime" "$runtime-$2" "${FIND[@]}" > /dev/null 2>&1 || true
    AT="$1" search "$runtime" "$runtime-$2" "${OPEN[@]}" > /dev/null 2>&1 || true
  done
}
ran_hooks() { local r; for r in $RUNTIMES; do [ -s "$OUTSIDE/agents-hook-$r" ] || return 1; done; }

# 8a/8b. The main checkout and a task workspace land, each notice naming its workspace.
for where in main topic; do
  if [ "$where" = main ]; then at="$FIXTURE" label="main checkout"; else at="$TASK" label="task workspace"; fi
  rm -rf "$FIXTURE/.egregore/runtime/mind"
  open_instance_map "$FIXTURE"
  mkdir -p "$OUTSIDE/instance-$where"
  landed=1
  for runtime in $RUNTIMES; do
    AT="$at" hook "$runtime" "$runtime-$where" > /dev/null
    take "$INSTANCE_DOOR" 'asked-*' "$OUTSIDE/instance-$where/asked-$runtime" || landed=0
    AT="$at" search "$runtime" "$runtime-$where" "${FIND[@]}" > /dev/null
    take "$INSTANCE_DOOR" 'seen-*' "$OUTSIDE/instance-$where/seen-find-$runtime" || landed=0
    AT="$at" search "$runtime" "$runtime-$where" "${OPEN[@]}" > /dev/null
    take "$INSTANCE_DOOR" 'seen-*' "$OUTSIDE/instance-$where/seen-open-$runtime" || landed=0
  done
  AT="$at" search claude "claude-$where" "${FIND[@]}" > "$OUTSIDE/attach.out"
  AT="$at" attach "claude-$where" > /dev/null
  take "$INSTANCE_DOOR" 'seen-*' "$OUTSIDE/instance-$where/attach-seen" || landed=0
  take "$INSTANCE_DOOR" 'delivered-*' "$OUTSIDE/instance-$where/attach-delivered" || landed=0
  stop_beat
  right=1
  for runtime in $RUNTIMES; do
    want="$(AT="$at" expected_actor "$runtime" "$runtime-$where")"
    for file in asked-$runtime seen-find-$runtime seen-open-$runtime; do
      jq -e --arg w "$where" --arg a "$want" '.v == 2 and .workspace == $w and .actor == $a and .run == "i"
          and (has("root") | not) and (has("query") | not)' "$OUTSIDE/instance-$where/$file" > /dev/null || right=0
    done
  done
  packet="$(jq -r .packet "$OUTSIDE/instance-$where/attach-seen" 2>/dev/null || true)"
  jq -e --arg w "$where" --arg p "$packet" '.k == "delivered" and .workspace == $w and .packet == $p' \
    "$OUTSIDE/instance-$where/attach-delivered" > /dev/null 2>&1 || right=0
  if [ "$landed" = 1 ] && [ "$right" = 1 ] && nothing_in "$INSTANCE_DOOR" && [ ! -e "$at/experiments" ]; then
    pass "instance door, agents in the $label: three hooks, finds and opens and Claude's delivery landed as workspace \"$where\""
  else
    fail "instance door, agents in $where: a notice missing or wrong" \
      "landed=$landed right=$right; $(ls -A "$INSTANCE_DOOR" | head -3); $(head -c 200 "$OUTSIDE/instance-$where/seen-find-codex")"
  fi
done
if grep -rqE 'PROMPTMARK|quartz|walrus|Striped animals|"zebra"' "$OUTSIDE/instance-main" "$OUTSIDE/instance-topic" ||
   grep -rqF "$SERVED" "$OUTSIDE/instance-main" "$OUTSIDE/instance-topic"; then
  fail "an instance-door notice carries prompt, query or document text, or a folder path"
else
  pass "instance-door notices carry no prompt text, query words, document text or folder path"
fi

# 8c. Another instance's map gets nothing, even with MIND_HOME naming its door.
OTHER="$OUTSIDE/other-instance"
mkdir -p "$OTHER"
git -C "$OTHER" init -q
rm -rf "$FIXTURE/.egregore/runtime/mind"
open_instance_map "$OTHER"
export MIND_HOME="$OTHER/.egregore/runtime/mind"
agents "$FIXTURE" x
agents "$TASK" x
unset MIND_HOME
stop_beat
if nothing_in "$OTHER/.egregore/runtime/mind/door" && [ ! -e "$FIXTURE/.egregore/runtime/mind" ] && ran_hooks; then
  pass "another instance's map, named by a stale MIND_HOME: hooks, finds and opens from both checkouts wrote nothing"
else
  fail "notices crossed into another instance's map" "$(ls -A "$OTHER/.egregore/runtime/mind/door")"
fi
# A door at this instance's path whose door.json names another instance (a copied instance folder).
open_instance_map "$FIXTURE" "$(cd "$OTHER" && pwd -P)"
agents "$FIXTURE" w
stop_beat
if nothing_in "$INSTANCE_DOOR" && ran_hooks; then
  pass "a door here naming another instance: hooks, finds and opens wrote nothing"
else
  fail "notices went into a door naming another instance" "$(ls -A "$INSTANCE_DOOR")"
fi
rm -rf "$FIXTURE/.egregore/runtime/mind"

# 8d. A map without the instance door gets nothing from another checkout, either way round.
TASK_SERVED="$(cd "$TASK" && pwd -P)"
open_map "$TASK/experiments/egregore-mind/.mind" "$TASK_SERVED"
agents "$FIXTURE" y
stop_beat
ran_hooks && into_task="$(ls -A "$TASK/experiments/egregore-mind/.mind/door")" || into_task='hooks did not run'
rm -rf "$TASK/experiments"   # its heartbeat stays fresh for 3 s, and agents in its own checkout may use it
open_map "$HOME_DEFAULT"
agents "$TASK" y
stop_beat
if [ "$into_task" = heartbeat ] && nothing_in "$HOME_DEFAULT/door" &&
   [ ! -e "$FIXTURE/.egregore/runtime/mind" ] && ran_hooks; then
  pass "a map without the instance door: nothing from the main checkout into the task workspace's map, or back"
else
  fail "notices crossed checkouts without an instance door" "into the task workspace: $into_task; back: $(ls -A "$HOME_DEFAULT/door")"
fi
rm -rf "$FIXTURE/experiments" "$TASK/experiments"

# 8e. A link below the instance root gets nothing: the whole .egregore folder, or only the door.
LINKED="$OUTSIDE/linked-instance"
mkdir -p "$FIXTURE/.egregore"
mv "$FIXTURE/.egregore" "$OUTSIDE/egregore-aside"   # the Runtime's own state, put back after this row
open_instance_map "$LINKED" "$SERVED"   # it names this instance: only the link leads there
ln -s "$LINKED/.egregore" "$FIXTURE/.egregore"
agents "$FIXTURE" z
stop_beat
rm "$FIXTURE/.egregore"
mv "$OUTSIDE/egregore-aside" "$FIXTURE/.egregore"
first="$(ls -A "$LINKED/.egregore/runtime/mind/door")"
rm -rf "$LINKED"
open_instance_map "$LINKED" "$SERVED"
mkdir -p "$FIXTURE/.egregore/runtime/mind"
cp "$LINKED/.egregore/runtime/mind/door.json" "$FIXTURE/.egregore/runtime/mind/door.json"
ln -s "$LINKED/.egregore/runtime/mind/door" "$INSTANCE_DOOR"
agents "$TASK" z
stop_beat
if [ "$first" = heartbeat ] && nothing_in "$LINKED/.egregore/runtime/mind/door" && ran_hooks; then
  pass "a link below the instance root (.egregore, or the door): hooks, finds and opens wrote nothing"
else
  fail "notices followed a link below the instance root" "$first / $(ls -A "$LINKED/.egregore/runtime/mind/door")"
fi
rm -rf "$FIXTURE/.egregore/runtime/mind" "$LINKED"

# 8f. A forged .git file gets nothing: it names the task workspace's real git dir, which links back
# to the task workspace, not to the forger. The task workspace itself still lands.
FORGED="$OUTSIDE/forged"
mkdir -p "$FORGED"
populate "$FORGED"
printf 'gitdir: %s\n' "$(sed -n 's/^gitdir: //p' "$TASK/.git")" > "$FORGED/.git"
open_instance_map "$FIXTURE"
agents "$FORGED" f
forged_hooks=0
ran_hooks && forged_hooks=1
AT="$TASK" hook codex codex-real > /dev/null
stop_beat
landed="$(count "$INSTANCE_DOOR" 'asked-*')$(count "$INSTANCE_DOOR" 'seen-*')$(count "$INSTANCE_DOOR" 'delivered-*')"
if [ "$landed" = 100 ] && [ "$forged_hooks" = 1 ] &&
   jq -e '.actor == "codex/codex-real" and .workspace == "topic"' "$INSTANCE_DOOR"/asked-* > /dev/null; then
  pass "a forged .git file: hooks, finds and opens from it wrote nothing; the real task workspace still lands"
else
  fail "a forged .git file reached the instance door" "$(ls -A "$INSTANCE_DOOR")"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
