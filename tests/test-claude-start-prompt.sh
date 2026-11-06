#!/usr/bin/env bash
# Shell launchers submit Claude's `start` prompt only when the first screen
# needs a model turn. The SessionStart hook shows the startup card itself once
# onboarding is done; pending onboarding, an older framework or a missing jq
# still need the model to act before the user types.
#
# Covers claude_needs_start_prompt in the npm shell launcher fallback and the
# hosted-workspace bootstrap written by bin/workspace-init.sh. The JavaScript
# launcher and installer are covered in
# packages/create-egregore/test/runtime-selection.test.js.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

extract() {
  awk '/^claude_needs_start_prompt\(\) \{/{on=1} on{print} on && /^\}/{exit}' "$1"
}

LAUNCHER_FN="$(extract "$ROOT/packages/create-egregore/assets/egregore-launcher.sh")"
BOOTSTRAP_FN="$(extract "$ROOT/bin/workspace-init.sh")"
[ -n "$LAUNCHER_FN" ] && pass "launcher defines claude_needs_start_prompt" || fail "launcher lost claude_needs_start_prompt"
[ "$LAUNCHER_FN" = "$BOOTSTRAP_FN" ] && pass "workspace bootstrap decides identically" || fail "workspace bootstrap drifted from the launcher"
grep -Fq 'claude_needs_start_prompt "$target_path" && claude_args=("start")' \
  "$ROOT/packages/create-egregore/assets/egregore-launcher.sh" \
  && pass "launcher submits start only through the decision" || fail "launcher no longer gates start"
[ "$(grep -c 'claude_needs_start_prompt "$HOME/egregore" &&' "$ROOT/bin/workspace-init.sh")" = 2 ] \
  && pass "both bootstrap launch paths gate start" || fail "a bootstrap launch path submits start unconditionally"

eval "$LAUNCHER_FN"

instance() {  # instance <card-delivery yes|no> [state-json]; runs in $(), so no shared counter
  local dir
  dir="$(mktemp -d "$TMP/instance.XXXXXX")"
  mkdir -p "$dir/bin/lib"
  [ "$1" = yes ] && : > "$dir/bin/lib/card-delivery.sh"
  [ $# -ge 2 ] && printf '%s\n' "$2" > "$dir/.egregore-state.json"
  printf '%s\n' "$dir"
}
expect() {  # expect <start|none> <label> <dir>
  local got=none
  if claude_needs_start_prompt "$3"; then got=start; fi
  [ "$got" = "$1" ] && pass "$2" || fail "$2 (got $got)"
}

if command -v jq >/dev/null 2>&1; then
  expect none "an onboarded member opens straight to the card" "$(instance yes '{"onboarding_complete":true}')"
  expect none "no state file counts as onboarded" "$(instance yes)"
  expect none "an unreadable state file counts as onboarded" "$(instance yes 'not json')"
  expect start "pending onboarding needs a model turn" "$(instance yes '{"onboarding_complete":false}')"
  expect start "a state file without the flag is pending onboarding" "$(instance yes '{}')"
  expect start "an older framework hands the card to the model" "$(instance no '{"onboarding_complete":true}')"
else
  fail "jq is required for this suite"
fi

ONBOARDED="$(instance yes '{"onboarding_complete":true}')"
# shellcheck disable=SC2123  # an empty PATH stands in for a machine without jq
if (PATH="$TMP/empty-path"; claude_needs_start_prompt "$ONBOARDED"); then
  pass "without jq the card falls back to text, so start is submitted"
else
  fail "without jq the card falls back to text, so start is submitted"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
