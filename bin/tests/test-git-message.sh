#!/usr/bin/env bash
# The shared commit helper keeps every trailer in one block. A message that
# already ends with Co-Authored-By and Refs lines gets the session trailer
# added to that block, so git parses all three as trailers; a message with
# no trailers gets the session trailer as its own final paragraph; and with
# no session id the message is committed unchanged.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-git-message.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; HUB="$WORK/hub"
mkdir -p "$REPO" "$HUB"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" config commit.gpgsign false
printf 'session-one\n' > "$HUB/.egregore-session-id"

# shellcheck source=../lib/git-message.sh
. "$ROOT/bin/lib/git-message.sh"

trailers() { git -C "$REPO" log -1 --format='%(trailers:only,unfold)' | sed '/^$/d'; }
subject() { git -C "$REPO" log -1 --format='%s'; }

printf 'one\n' > "$REPO/a.txt"; git -C "$REPO" add a.txt
egregore_commit "$REPO" "$HUB" 'feat(x): add a

Body paragraph.

Refs: #1
Co-Authored-By: Someone <someone@example.com>' --quiet
got="$(trailers)"
if [ "$(printf '%s\n' "$got" | wc -l | tr -d ' ')" = "3" ] \
   && grep -q '^Egregore-Session: session-one$' <<< "$got" \
   && grep -q '^Co-Authored-By: Someone <someone@example.com>$' <<< "$got" \
   && grep -q '^Refs: #1$' <<< "$got"; then
  pass "a message ending in trailers keeps them all in one trailer block"
else fail "trailers split" "$got"; fi
[ "$(subject)" = "feat(x): add a" ] && pass "the subject is untouched" || fail "subject changed" "$(subject)"

printf 'two\n' > "$REPO/b.txt"; git -C "$REPO" add b.txt
egregore_commit "$REPO" "$HUB" 'fix(y): plain message

Just a body.' --quiet
got="$(trailers)"
[ "$got" = "Egregore-Session: session-one" ] \
  && pass "a message without trailers gets the session trailer as its own block" \
  || fail "plain message trailer" "$got"
body="$(git -C "$REPO" log -1 --format='%b')"
case "$body" in
  "Just a body."*"Egregore-Session: session-one") pass "the body keeps its paragraph before the trailer" ;;
  *) fail "body shape" "$body" ;;
esac

printf 'three\n' > "$REPO/c.txt"; git -C "$REPO" add c.txt
egregore_commit "$REPO" "$WORK/no-hub" 'chore(z): no session id' --quiet
[ -z "$(trailers)" ] && pass "no session id, no trailer" || fail "trailer without id" "$(trailers)"
[ "$(subject)" = "chore(z): no session id" ] && pass "subject kept without a session id" || fail "subject" "$(subject)"

printf 'four\n' > "$REPO/d.txt"; git -C "$REPO" add d.txt
egregore_commit "$REPO" "$HUB" 'feat(w): subject only' --quiet
[ "$(trailers)" = "Egregore-Session: session-one" ] \
  && pass "a subject-only message still carries the session trailer" \
  || fail "subject-only trailer" "$(trailers)"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
