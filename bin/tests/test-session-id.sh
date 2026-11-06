#!/usr/bin/env bash
# Parallel sessions keep their own Egregore session id. Each session start
# (bin/lib/identity.sh) mints an id and writes the shared .egregore-session-id
# that every worktree links to, so the latest start owns it. Two sessions
# with different native ids start in parallel, a Codex thread binds at its
# first prompt, and a fourth session starts after them; each session's
# resolver and commit trailer, run from a linked worktree, still name its
# own id. Maps never apply to another repository, and bad names never
# become paths.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-session-id.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset EGREGORE_NATIVE_SESSION_ID EGREGORE_NATIVE_HARNESS CLAUDE_CODE_SESSION_ID \
  CODEX_THREAD_ID EGREGORE_START_HARNESS EGREGORE_SESSION_ID
mkdir -p "$HOME" "$WORK/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$WORK/fakebin/gh"   # identity.sh's gh check stays offline
chmod +x "$WORK/fakebin/gh"
export PATH="$WORK/fakebin:$PATH"

MAIN="$WORK/main"; WT="$WORK/wt"; MAPS="$HOME/.egregore/sessions"
mkdir -p "$MAIN/bin"
cp "$ROOT/bin/session-id.sh" "$MAIN/bin/session-id.sh"
git -C "$MAIN" init -q
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name tester
git -C "$MAIN" config commit.gpgsign false
printf '{"github_username":"tester","github_name":"tester"}\n' > "$MAIN/.egregore-state.json"
printf '.egregore-session-id\n.egregore-state.json\n' > "$MAIN/.gitignore"
git -C "$MAIN" add .gitignore bin/session-id.sh
git -C "$MAIN" commit -qm "chore: seed fixture"
git -C "$MAIN" worktree add -q "$WT" -b work
# What bin/lib/worktree-links.sh does: the worktree shares the main file.
ln -s "$MAIN/.egregore-session-id" "$WT/.egregore-session-id"

# One session start, as bin/session-start.sh and bin/codex-session-start.sh
# run it: identity.sh sourced in the checkout, its own process per session.
cat > "$WORK/start.sh" <<'EOF'
set -u
cd "$1" || exit 1
STATE_FILE="$1/.egregore-state.json"; ENV_FILE="$1/.env"; SCRIPT_DIR="$1"; HEALTH_GITHUB=""
. "$IDENTITY" >/dev/null 2>&1
printf '%s\n' "$EGREGORE_SESSION_ID"
EOF
export IDENTITY="$ROOT/bin/lib/identity.sh"
start() { # out harness native — empty harness = no native id (Codex's launcher start)
  if [ -n "$2" ]; then
    EGREGORE_START_HARNESS="$2" EGREGORE_NATIVE_HARNESS="$2" EGREGORE_NATIVE_SESSION_ID="$3" \
      bash "$WORK/start.sh" "$MAIN" > "$WORK/$1"
  else
    bash "$WORK/start.sh" "$MAIN" > "$WORK/$1"
  fi
}
resolve_as() { # env assignments… — the resolver as a commit in the worktree runs it
  env -u EGREGORE_NATIVE_SESSION_ID -u EGREGORE_NATIVE_HARNESS -u CLAUDE_CODE_SESSION_ID \
    -u CODEX_THREAD_ID "$@" bash "$ROOT/bin/session-id.sh" --root "$WT"
}

echo "1. two sessions start in parallel"
start a.out claude 3f1c2a9e-0d4b-4c51-9a77-aaaaaaaaaaaa &
start b.out pi 9b2f00d1c0ffee5aa1e5b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2 &
wait
A="$(cat "$WORK/a.out")"; B="$(cat "$WORK/b.out")"
[ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ] \
  && pass "each start mints its own Egregore id" || fail "ids" "A=$A B=$B"
shared="$(cat "$MAIN/.egregore-session-id")"
{ [ "$shared" = "$A" ] || [ "$shared" = "$B" ]; } \
  && pass "the shared file holds whichever start wrote last" || fail "shared file" "$shared"

echo "2. a Codex session starts, then binds its thread at the first prompt"
start c.out "" ""
C="$(cat "$WORK/c.out")"
CODEX_THREAD_ID=019a0c3e-7d21-7c11-b000-cccccccccccc \
  bash "$ROOT/bin/session-id.sh" bind codex 019a0c3e-7d21-7c11-b000-cccccccccccc --root "$WT"
[ -f "$MAPS/codex-019a0c3e-7d21-7c11-b000-cccccccccccc.id" ] \
  && pass "the first prompt records the Codex thread's map" || fail "codex bind wrote no map"

echo "3. a fourth session starts after them all"
start d.out claude 77aa0e10-1111-4222-8333-dddddddddddd
D="$(cat "$WORK/d.out")"
[ "$(cat "$MAIN/.egregore-session-id")" = "$D" ] \
  && pass "the latest start owns the shared file" || fail "shared file not D"

echo "4. each session resolves its own id from the worktree"
CLAUDE_A=(EGREGORE_NATIVE_HARNESS=claude EGREGORE_NATIVE_SESSION_ID=3f1c2a9e-0d4b-4c51-9a77-aaaaaaaaaaaa
  CLAUDE_CODE_SESSION_ID=3f1c2a9e-0d4b-4c51-9a77-aaaaaaaaaaaa)
PI_B=(EGREGORE_NATIVE_HARNESS=pi EGREGORE_NATIVE_SESSION_ID=9b2f00d1c0ffee5aa1e5b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2)
CODEX_C=(CODEX_THREAD_ID=019a0c3e-7d21-7c11-b000-cccccccccccc)
got="$(resolve_as "${CLAUDE_A[@]}")"; [ "$got" = "$A" ] && pass "Claude session A → A" || fail "Claude A" "got $got want $A"
got="$(resolve_as "${PI_B[@]}")"; [ "$got" = "$B" ] && pass "Pi session B → B" || fail "Pi B" "got $got want $B"
got="$(resolve_as "${CODEX_C[@]}")"; [ "$got" = "$C" ] && pass "Codex thread C → C" || fail "Codex C" "got $got want $C"
got="$(resolve_as CLAUDE_CODE_SESSION_ID=77aa0e10-1111-4222-8333-dddddddddddd)"
[ "$got" = "$D" ] && pass "Claude session D → D (CLAUDE_CODE_SESSION_ID alone)" || fail "Claude D" "got $got want $D"
got="$(resolve_as "${CLAUDE_A[@]}" CODEX_THREAD_ID=019a0c3e-7d21-7c11-b000-eeeeeeeeeeee)"
[ "$got" = "$A" ] && pass "a Codex worker started from session A resolves to A" || fail "worker" "got $got want $A"
got="$(resolve_as CLAUDE_CODE_SESSION_ID=00000000-0000-4000-8000-000000000000)"
[ "$got" = "$D" ] && pass "an unmapped native id falls back to the shared file" || fail "fallback" "got $got"
got="$(resolve_as)"
[ "$got" = "$D" ] && pass "no native id falls back to the shared file" || fail "no native" "got $got"

echo "5. commits from the worktree carry their own session's trailer"
# shellcheck source=../lib/git-message.sh
. "$ROOT/bin/lib/git-message.sh"
commit_as() { # file env… — one commit in the worktree under a session's environment
  local file="$1"; shift
  printf '%s\n' "$file" > "$WT/$file"; git -C "$WT" add "$file"
  ( unset EGREGORE_NATIVE_SESSION_ID EGREGORE_NATIVE_HARNESS CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
    for assignment in "$@"; do export "${assignment?}"; done
    egregore_commit "$WT" "$WT" "test(fixture): commit $file" --quiet )
  git -C "$WT" log -1 --format='%(trailers:key=Egregore-Session,valueonly)' | sed '/^$/d'
}
got="$(commit_as a.txt "${CLAUDE_A[@]}")"; [ "$got" = "$A" ] && pass "session A's commit names A" || fail "commit A" "$got"
got="$(commit_as b.txt "${PI_B[@]}")"; [ "$got" = "$B" ] && pass "session B's commit names B" || fail "commit B" "$got"
got="$(commit_as c.txt "${CODEX_C[@]}")"; [ "$got" = "$C" ] && pass "thread C's commit names C" || fail "commit C" "$got"

echo "5b. Runtime wrappers hand memory commits the session's own id"
# Each wrapper's real export line feeds egregore_runtime/sync.py's trailer.
mkdir -p "$WT/bin"; cp "$ROOT/bin/session-id.sh" "$WT/bin/session-id.sh"
for wrapper in artifact-writeback genui ingest-item issue knowledge quest scroll thread todo; do
  line="$(grep '^export EGREGORE_SESSION_ID=' "$ROOT/bin/$wrapper.sh")"
  got_a="$(env -u EGREGORE_SESSION_ID "${CLAUDE_A[@]}" ROOT="$WT" LINE="$line" bash -c 'eval "$LINE"; printf %s "$EGREGORE_SESSION_ID"')"
  got_b="$(env -u EGREGORE_SESSION_ID "${PI_B[@]}" ROOT="$WT" LINE="$line" bash -c 'eval "$LINE"; printf %s "$EGREGORE_SESSION_ID"')"
  got_none="$(env -u EGREGORE_SESSION_ID ROOT="$WORK/no-resolver" LINE="$line" bash -c 'mkdir -p "$ROOT"; printf "old-shared\n" > "$ROOT/.egregore-session-id"; eval "$LINE"; printf %s "$EGREGORE_SESSION_ID"')"
  if [ "$got_a" = "$A" ] && [ "$got_b" = "$B" ] && [ "$got_none" = "old-shared" ]; then
    pass "bin/$wrapper.sh exports each session's own id (shared file without the resolver)"
  else
    fail "bin/$wrapper.sh" "A=$got_a B=$got_b none=$got_none"
  fi
done

echo "6. parallel commits under the shared file keep their own ids"
( export "${CLAUDE_A[@]}"; for i in 1 2 3 4 5; do egregore_session_trailer "$WT"; echo; done ) > "$WORK/ta.out" &
( export "${PI_B[@]}"; for i in 1 2 3 4 5; do egregore_session_trailer "$WT"; echo; done ) > "$WORK/tb.out" &
for i in 1 2 3; do start "e$i.out" claude "eeee000$i-0000-4000-8000-000000000000" & done
wait
[ "$(sort -u "$WORK/ta.out")" = "Egregore-Session: $A" ] \
  && pass "A's trailers stay A while other sessions start" || fail "A trailers" "$(sort -u "$WORK/ta.out" | tr '\n' ' ')"
[ "$(sort -u "$WORK/tb.out")" = "Egregore-Session: $B" ] \
  && pass "B's trailers stay B while other sessions start" || fail "B trailers" "$(sort -u "$WORK/tb.out" | tr '\n' ' ')"

echo "7. maps are scoped, kept, checked and pruned"
OTHER="$WORK/fixture"; mkdir -p "$OTHER"; git -C "$OTHER" init -q
printf 'fixture-session\n' > "$OTHER/.egregore-session-id"
got="$(env "${CLAUDE_A[@]}" bash "$ROOT/bin/session-id.sh" --root "$OTHER")"
[ "$got" = "fixture-session" ] && pass "a map never applies to another repository" || fail "scope" "got $got"
CODEX_THREAD_ID=019a0c3e-7d21-7c11-b000-cccccccccccc \
  bash "$ROOT/bin/session-id.sh" bind codex 019a0c3e-7d21-7c11-b000-cccccccccccc --root "$WT"
got="$(resolve_as "${CODEX_C[@]}")"; [ "$got" = "$C" ] && pass "a second bind keeps the first map" || fail "bind kept" "got $got"
before="$(find "$WORK" -name '*.id' | sort)"
for bad in "../escape" "a/b" ".hidden" "has space" ""; do
  bash "$ROOT/bin/session-id.sh" record claude "$bad" "x-1" --root "$WT" 2>/dev/null && fail "accepted native id '$bad'"
done
bash "$ROOT/bin/session-id.sh" record "Claude" "abc" "x-1" --root "$WT" 2>/dev/null && fail "accepted harness 'Claude'"
bash "$ROOT/bin/session-id.sh" record claude "abc" "$(printf 'x\ny')" --root "$WT" 2>/dev/null && fail "accepted a two-line id"
[ "$(find "$WORK" -name '*.id' | sort)" = "$before" ] \
  && pass "unsafe names and ids are refused without writing" || fail "unsafe input wrote a file"
printf 'moved-session\n/nowhere/.git\n' > "$MAPS/codex-019a0c3e-7d21-7c11-b000-ffffffffffff.id"
CODEX_THREAD_ID=019a0c3e-7d21-7c11-b000-ffffffffffff \
  bash "$ROOT/bin/session-id.sh" bind codex 019a0c3e-7d21-7c11-b000-ffffffffffff --root "$WT"
got="$(sed -n 1p "$MAPS/codex-019a0c3e-7d21-7c11-b000-ffffffffffff.id")"
[ "$got" = "$(cat "$MAIN/.egregore-session-id")" ] \
  && [ "$(sed -n 2p "$MAPS/codex-019a0c3e-7d21-7c11-b000-ffffffffffff.id")" = "$(cd "$MAIN/.git" && pwd -P)" ] \
  && pass "a bind replaces a map recorded for a moved checkout" || fail "moved-checkout bind" "map says $got"
touch -t 202001010000 "$MAPS/claude-77aa0e10-1111-4222-8333-dddddddddddd.id"
touch -t 202001010000 "$MAPS/claude-3f1c2a9e-0d4b-4c51-9a77-aaaaaaaaaaaa.id"
resolve_as "${CLAUDE_A[@]}" >/dev/null   # session A commits again: its map is in use
start f.out claude ffff0000-0000-4000-8000-000000000000
[ ! -e "$MAPS/claude-77aa0e10-1111-4222-8333-dddddddddddd.id" ] \
  && pass "a session start prunes maps unused for 30 days" || fail "old map kept"
[ -f "$MAPS/claude-3f1c2a9e-0d4b-4c51-9a77-aaaaaaaaaaaa.id" ] \
  && pass "an old map still in use survives the prune" || fail "in-use map pruned"
[ -f "$MAPS/pi-9b2f00d1c0ffee5aa1e5b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2.id" ] \
  && pass "recent maps survive the prune" || fail "recent map pruned"
[ "$(wc -l < "$MAPS/claude-3f1c2a9e-0d4b-4c51-9a77-aaaaaaaaaaaa.id" | tr -d ' ')" = "2" ] \
  && pass "a map is two lines" || fail "map shape"
# A prune that removes a map while a lookup is refreshing it must not leave an
# empty map behind: the refresh never creates a file.
grep -q 'touch -c "$file"' "$ROOT/bin/session-id.sh" \
  && pass "the in-use refresh never recreates a pruned map" || fail "refresh can create an empty map"
EGREGORE_START_HARNESS=pi EGREGORE_NATIVE_HARNESS=claude EGREGORE_NATIVE_SESSION_ID=abcabc \
  bash "$WORK/start.sh" "$MAIN" >/dev/null
[ ! -e "$MAPS/pi-abcabc.id" ] && [ ! -e "$MAPS/claude-abcabc.id" ] \
  && pass "a start never maps a native id inherited from another harness" || fail "inherited id mapped"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
