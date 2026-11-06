#!/usr/bin/env bash
# The first Claude launch of a day starts from the last saved card.
#
# Every full startup saves its card; the next launch shows it at once and
# refreshes in the background (bin/lib/card-delivery.sh). A card counted only
# if saved the same day under the same framework version, so the first launch
# each day and the first after a version bump ran the full startup in front of
# the user. Now a card from the last three days stands in, labelled with its
# day, under any version, and the quick pass catches the checkout and its managed
# repos up to the last fetch, since the background refresh leaves working
# trees alone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
# The background refresh may still be writing here: retry once after it settles.
cleanup() { rm -rf "$TMP" 2>/dev/null || { sleep 2; rm -rf "$TMP" 2>/dev/null; } || true; }
trap cleanup EXIT
PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
GIT=(git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main)

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required: the saved card exists only in Claude's card delivery" >&2
  exit 1
fi

# repo <name>: a bare remote, a clone on main and an updater clone.
repo() {
  "${GIT[@]}" init --bare -q "$TMP/$1.git"
  "${GIT[@]}" clone -q "$TMP/$1.git" "$TMP/$1" 2>/dev/null
  "${GIT[@]}" -C "$TMP/$1" checkout -qb main
}
publish() {  # publish <repo>: push a new commit from its updater clone
  printf '%s\n' "$RANDOM" >> "$TMP/$1-updater/CHANGES"
  "${GIT[@]}" -C "$TMP/$1-updater" add CHANGES
  "${GIT[@]}" -C "$TMP/$1-updater" commit -qm "change $1"
  "${GIT[@]}" -C "$TMP/$1-updater" push -q origin main 2>/dev/null
}

CHECKOUT="$TMP/instance"
repo instance
# No attendant: its daemon would outlive the fixture. `tool` is a managed repo,
# a sibling of the instance.
printf '%s\n' '{"base_branch":"main","mode":"local","upstream_url":"none","features":{"attendant":false},"repos":[{"name":"tool","base_branch":"main"}]}' \
  > "$CHECKOUT/egregore.json"
mkdir -p "$CHECKOUT/bin"
cp -R "$ROOT/bin/." "$CHECKOUT/bin/"
# The real ignore rules: startup rewrites its state file and caches, and a
# tracked copy would leave the checkout dirty and stop fast-forwards.
cp "$ROOT/.gitignore" "$CHECKOUT/.gitignore"
printf '%s\n' '{"github_username":"testuser","onboarding_complete":true}' > "$CHECKOUT/.egregore-state.json"
"${GIT[@]}" -C "$CHECKOUT" add egregore.json bin .gitignore
"${GIT[@]}" -C "$CHECKOUT" commit -qm init
"${GIT[@]}" -C "$CHECKOUT" push -qu origin main 2>/dev/null
"${GIT[@]}" clone -q "$TMP/instance.git" "$TMP/instance-updater" 2>/dev/null

repo tool
printf '%s\n' tool > "$TMP/tool/README.md"
"${GIT[@]}" -C "$TMP/tool" add README.md
"${GIT[@]}" -C "$TMP/tool" commit -qm init
"${GIT[@]}" -C "$TMP/tool" push -qu origin main 2>/dev/null
"${GIT[@]}" clone -q "$TMP/tool.git" "$TMP/tool-updater" 2>/dev/null

CARDS="$TMP/home/.egregore"
mkdir -p "$CARDS"
VERSION=$(sed -n 's/^FRAMEWORK_VERSION="\([^"]*\)".*/\1/p' "$ROOT/bin/session-start.sh" | head -1)

launch() {  # one Claude launch: the SessionStart hook with no prompt on stdin
  : > "$TMP/claude-env"
  local began=$SECONDS
  env HOME="$TMP/home" DO_NOT_TRACK=1 CLAUDE_ENV_FILE="$TMP/claude-env" \
    bash "$CHECKOUT/bin/session-start.sh" > "$TMP/out" 2> "$TMP/err" < /dev/null || true
  LAUNCH_SECONDS=$((SECONDS - began))
}
age_line() { jq -r '.systemMessage | split("\n") | map(select(test("◦ card from")))[0] // ""' "$TMP/out" 2>/dev/null; }
card() { find "$CARDS" -maxdepth 1 -name "startup-card-v$1-*.json" | head -1; }
head_of() { "${GIT[@]}" -C "$1" rev-parse "${2:-HEAD}"; }
at() {  # epoch of <days ago> <hour> <minute>, local time
  python3 -c 'import datetime as d, sys; t = d.date.today() - d.timedelta(int(sys.argv[1])); print(int(d.datetime.combine(t, d.time(int(sys.argv[2]), int(sys.argv[3]))).timestamp()))' "$@"
}

echo "The first launch of a day starts from the last saved card"

# 1. No saved card yet: the full startup runs in front and saves its card.
launch
FULL_SECONDS=$LAUNCH_SECONDS
if jq -e '.systemMessage | type == "string"' "$TMP/out" >/dev/null 2>&1 && [ -z "$(age_line)" ]; then
  ok "a launch with no saved card runs the full startup (${FULL_SECONDS}s)"
else
  bad "no full-startup card: $(head -c 300 "$TMP/out")"
fi
SAVED=$(card "$VERSION")
[ -n "$SAVED" ] && ok "the full startup saved its card under version $VERSION" \
  || bad "no saved card under version $VERSION"

# 2. Next morning, after a version bump: the card was saved yesterday at
#    18:40 under an older version, and yesterday's refresh fetched commits
#    nobody has merged yet, in the instance and in its managed repo.
OLDER="$CARDS/startup-card-v0-${SAVED##*-}"
jq --argjson at "$(at 1 18 40)" --arg day "$(python3 -c 'import datetime as d; print(d.date.today() - d.timedelta(1))')" \
  '.saved_at = $at | .day = $day' "$SAVED" > "$OLDER"
rm -f "$SAVED"
publish instance
publish tool
"${GIT[@]}" -C "$CHECKOUT" fetch -q origin
"${GIT[@]}" -C "$TMP/tool" fetch -q origin
REFRESH_FROM=$(date +%s)
launch
[ "$(age_line)" = "  ◦ card from yesterday 18:40 · updating in the background" ] \
  && ok "yesterday's card from an older version shows at once (${LAUNCH_SECONDS}s), named by its day" \
  || bad "the launch did not start from yesterday's card: $(age_line) $(head -c 300 "$TMP/out")"
jq -e '.hookSpecificOutput.additionalContext | startswith("<!-- startup-context-age: saved yesterday 18:40; its dates (today, yesterday, ago) are as of then;")' "$TMP/out" >/dev/null 2>&1 \
  && ok "the model is told when its startup context was saved" || bad "no saved time in the model context"
[ "$(head_of "$CHECKOUT")" = "$(head_of "$CHECKOUT" origin/main)" ] \
  && ok "the quick pass fast-forwarded the instance to the last fetch" || bad "the instance stayed behind its fetch"
[ "$(head_of "$TMP/tool")" = "$(head_of "$TMP/tool" origin/main)" ] \
  && ok "the quick pass fast-forwarded the managed repo to the last fetch" || bad "the managed repo stayed behind its fetch"
# The background refresh saves today's card under the current version.
for _ in $(seq 1 120); do
  NEW=$(card "$VERSION")
  if [ -n "$NEW" ] && jq -e --argjson from "$REFRESH_FROM" '.saved_at >= $from' "$NEW" >/dev/null 2>&1; then break; fi
  NEW=""
  sleep 1
done
[ -n "$NEW" ] && ok "the background refresh saved a new card under version $VERSION" \
  || bad "the background refresh saved no card under version $VERSION"

# 3. A card older than three days no longer stands in.
if [ -n "$NEW" ]; then
  jq '.saved_at -= 4 * 86400' "$NEW" > "$NEW.tmp" && mv "$NEW.tmp" "$NEW"
  launch
  if jq -e '.systemMessage | type == "string"' "$TMP/out" >/dev/null 2>&1 && [ -z "$(age_line)" ]; then
    ok "a card older than three days gives way to the full startup"
  else
    bad "a 4-day-old card stood in: $(age_line)"
  fi
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
