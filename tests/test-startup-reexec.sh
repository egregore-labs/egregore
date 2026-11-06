#!/usr/bin/env bash
# A startup whose own sync pulls a newer startup finishes on the new script.
#
# Bash keeps reading the copy of a startup script it opened, while every
# library it sources after the sync is the pulled version. Without a restart
# the first launch after an update ran an old script on new libraries (the
# Nov 4 launch: legacy text card, 52 s hook). Each fixture version of a script
# appends its own letter to a marker file, so the marker records which
# versions ran, in order. Covers bin/lib/startup-restart.sh through the Claude
# startup (bin/session-start.sh) and the Codex, Pi and Prime startup
# (bin/codex-session-start.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
# Detached startup jobs may still be writing here: retry once after they settle.
cleanup() { rm -rf "$TMP" 2>/dev/null || { sleep 2; rm -rf "$TMP" 2>/dev/null; } || true; }
trap cleanup EXIT
PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
GIT=(git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main)

# stamp <script> <letter>: the script appends <letter> when STARTUP_MARK is set,
# right after it changes into the checkout.
stamp() {
  python3 - "$1" "$2" <<'EOF'
import re, sys
path, letter = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
line = f'[ -n "${{STARTUP_MARK:-}}" ] && echo {letter} >> "$STARTUP_MARK"\n'
text = re.sub(r'(?m)^\[ -n "\$\{STARTUP_MARK:-\}" \] && echo \w+ >> "\$STARTUP_MARK"\n', "", text)
text, count = re.subn(r'(?m)^(cd "\$SCRIPT_DIR".*\n)', lambda m: m.group(1) + line, text, count=1)
assert count == 1, path
open(path, "w", encoding="utf-8").write(text)
EOF
}

REMOTE="$TMP/origin.git"
CHECKOUT="$TMP/instance"
UPDATER="$TMP/updater"
"${GIT[@]}" init --bare -q "$REMOTE"
"${GIT[@]}" clone -q "$REMOTE" "$CHECKOUT" 2>/dev/null
"${GIT[@]}" -C "$CHECKOUT" checkout -qb main
printf '%s\n' base > "$CHECKOUT/README.md"
# No attendant: its daemon would outlive the fixture, and its fresh-refs
# marker makes later launches skip the fetch this test depends on.
printf '%s\n' '{"base_branch":"main","mode":"local","upstream_url":"none","features":{"attendant":false}}' > "$CHECKOUT/egregore.json"
mkdir -p "$CHECKOUT/bin"
cp -R "$ROOT/bin/." "$CHECKOUT/bin/"
# The real ignore rules: startup rewrites its state file and caches, and a
# tracked copy would leave the checkout dirty and stop later fast-forwards.
cp "$ROOT/.gitignore" "$CHECKOUT/.gitignore"
stamp "$CHECKOUT/bin/session-start.sh" A
stamp "$CHECKOUT/bin/codex-session-start.sh" x
printf '%s\n' '{"github_username":"testuser","onboarding_complete":true}' > "$CHECKOUT/.egregore-state.json"
"${GIT[@]}" -C "$CHECKOUT" add README.md egregore.json bin .gitignore
"${GIT[@]}" -C "$CHECKOUT" commit -qm init
"${GIT[@]}" -C "$CHECKOUT" push -qu origin main 2>/dev/null
"${GIT[@]}" clone -q "$REMOTE" "$UPDATER" 2>/dev/null

publish() {  # publish <message>: commit the updater's changes and push them
  "${GIT[@]}" -C "$UPDATER" commit -qam "$1"
  "${GIT[@]}" -C "$UPDATER" push -q origin main 2>/dev/null
}
start() {  # start <marker> [extra env...]: one Claude launch of the instance
  : > "$1"
  local marker="$1"; shift
  env HOME="$TMP/home" STARTUP_MARK="$marker" DO_NOT_TRACK=1 "$@" \
    bash "$CHECKOUT/bin/session-start.sh" > "$TMP/out" 2> "$TMP/err" < /dev/null || true
}
start_codex() {  # start_codex <marker>: one Codex, Pi or Prime launch
  : > "$1"
  env HOME="$TMP/home" STARTUP_MARK="$1" DO_NOT_TRACK=1 \
    bash "$CHECKOUT/bin/codex-session-start.sh" --card > "$TMP/out" 2> "$TMP/err" < /dev/null || true
}
runs() { tr '\n' ' ' < "$1" | sed 's/ $//'; }
mkdir -p "$TMP/home"

echo "Startup restarts on a startup its own sync pulled"

# 1. The update changes the startup script: the old one restarts on the new.
stamp "$UPDATER/bin/session-start.sh" B
publish "update the startup"
start "$TMP/mark1"
[ "$(runs "$TMP/mark1")" = "A B" ] && ok "plain launch finishes on the pulled script (A B)" \
  || bad "plain launch ran: $(runs "$TMP/mark1") (want A B)"
[ "$("${GIT[@]}" -C "$CHECKOUT" rev-parse HEAD)" = "$("${GIT[@]}" -C "$UPDATER" rev-parse HEAD)" ] \
  && ok "the checkout reached the pushed revision" || bad "the checkout did not fast-forward"

# 2. The update touches only other files: one run, no restart.
printf '%s\n' changed > "$UPDATER/README.md"
publish "change the readme"
start "$TMP/mark2"
[ "$(runs "$TMP/mark2")" = "B" ] && ok "an update outside the startup runs once (B)" \
  || bad "a non-startup update ran: $(runs "$TMP/mark2") (want B)"
[ "$(cat "$CHECKOUT/README.md")" = changed ] && ok "that update was pulled" \
  || bad "the non-startup update was not pulled"

# 3. Nothing to pull: one run.
start "$TMP/mark3"
[ "$(runs "$TMP/mark3")" = "B" ] && ok "a launch with nothing to pull runs once (B)" \
  || bad "an idle launch ran: $(runs "$TMP/mark3") (want B)"

# 4. A library change counts as a startup change, in the card's inner pass.
#    Harness mode: the outer pass (B) runs the inner pass (B), whose sync
#    pulls C; the inner pass restarts as an inner pass, so C runs once and
#    the outer pass still prints the card envelope.
printf '\n# fixture change\n' >> "$UPDATER/bin/lib/greeting.sh"
stamp "$UPDATER/bin/session-start.sh" C
publish "update a startup library"
if command -v jq >/dev/null 2>&1; then
  : > "$TMP/claude-env"
  start "$TMP/mark4" CLAUDE_ENV_FILE="$TMP/claude-env" EGREGORE_STARTUP_FAST=off
  [ "$(runs "$TMP/mark4")" = "B B C" ] && ok "the inner card pass restarts as an inner pass (B B C)" \
    || bad "the card passes ran: $(runs "$TMP/mark4") (want B B C)"
  jq -e '.systemMessage | type == "string"' "$TMP/out" >/dev/null 2>&1 \
    && ok "the outer pass still shows the card" || bad "no card envelope after the restart: $(head -c 300 "$TMP/out")"
else
  bad "jq is required for the card-pass case"
fi

# 5. The Codex, Pi and Prime startup shares the restart.
stamp "$UPDATER/bin/codex-session-start.sh" y
printf '\n# fixture change\n' >> "$UPDATER/bin/lib/context.sh"
publish "update the codex startup"
start_codex "$TMP/mark5"
[ "$(runs "$TMP/mark5")" = "x y" ] && ok "the Codex startup finishes on the pulled script (x y)" \
  || bad "the Codex startup ran: $(runs "$TMP/mark5") (want x y)"
[ -s "$TMP/out" ] && ok "the Codex card still renders" \
  || bad "no Codex card after the restart: $(head -c 300 "$TMP/err")"

# The restart is one-shot: the guard leaves the environment of what it starts.
grep -q 'export -n _EGREGORE_STARTUP_REEXEC' "$ROOT/bin/lib/startup-restart.sh" \
  && ok "the restart guard is not inherited by later startups" || bad "the restart guard leaks to child processes"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
