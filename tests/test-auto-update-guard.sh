#!/usr/bin/env bash
# Regression test for the auto-update opt-out.
#
# History: `jq -r '.auto_update // true'` was used to read the flag. jq's `//`
# returns its right-hand side when the left is null OR false, so a config
# saying {"auto_update": false} resolved to the string "true" and the guard
# `[ "$_AUTO_UPDATE" = "false" ]` could never fire. The documented opt-out
# disabled nothing, for anyone, and a downstream instance lost 22 locally
# edited framework files to an auto-update it had explicitly turned off.
#
# These tests pin both halves of the fix: the flag must be read correctly, and
# it must fail closed when the config cannot be read at all.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi
}

echo "test-auto-update-guard"

# --- Load the resolver in isolation -----------------------------------------
# git-sync.sh executes git operations top to bottom, so it cannot be sourced.
# Extract just the function under test.
FN=$(sed -n '/^_read_auto_update() {/,/^}/p' "$ROOT/bin/lib/git-sync.sh")
if [ -z "$FN" ]; then
  echo "  ✗ _read_auto_update not found in bin/lib/git-sync.sh" >&2
  exit 1
fi
eval "$FN"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

resolve() { # resolve <json-body|--none>
  local dir="$TMP/case"
  rm -rf "$dir"; mkdir -p "$dir"
  [ "$1" = "--none" ] || printf '%s' "$1" > "$dir/egregore.json"
  SCRIPT_DIR="$dir" _read_auto_update
}

# --- The bug that cost a user 22 files --------------------------------------
check "auto_update:false disables the update" \
  "false" "$(resolve '{"auto_update": false}')"

# --- Default stays on -------------------------------------------------------
check "absent key leaves auto-update on" \
  "true" "$(resolve '{"slug": "acme"}')"
check "auto_update:true keeps it on" \
  "true" "$(resolve '{"auto_update": true}')"

# --- Fail closed ------------------------------------------------------------
check "malformed json does not authorize an overwrite" \
  "false" "$(resolve '{"auto_update": tru')"
check "missing egregore.json does not authorize an overwrite" \
  "false" "$(resolve --none)"
check "string \"false\" is honored, not ignored" \
  "false" "$(resolve '{"auto_update": "false"}')"
check "unexpected type does not authorize an overwrite" \
  "false" "$(resolve '{"auto_update": {"nested": 1}}')"
# A *string* "true" is not a parsed boolean true. Under a bare `jq -r` read it
# renders as bare `true` and slips through — a fail-open hole inside a
# fail-closed resolver. Caught in review of the upstream port.
check "string \"true\" does not authorize an overwrite" \
  "false" "$(resolve '{"auto_update": "true"}')"
check "a number does not authorize an overwrite" \
  "false" "$(resolve '{"auto_update": 1}')"

# --- The bug class, repo-wide -----------------------------------------------
# `// true` is only safe for a flag whose false is meaningless. Any boolean
# opt-out read that way silently ignores the user turning it off.
OFFENDERS=$(grep -rn "jq -r '\.[a-zA-Z_.]* // true'" "$ROOT/bin" --include="*.sh" \
  | grep -v '/packages/' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [ -z "$OFFENDERS" ]; then
  ok "no boolean opt-out is read through jq's // true"
else
  bad "jq '// true' reintroduced — false collapses to true here:"
  printf '%s\n' "$OFFENDERS" >&2
fi

# --- Runtime parity ---------------------------------------------------------
# Codex and Pi installations ship generated copies of these shared scripts.
# A root-only fix leaves new installs exposed to the original bug.
for runtime in codex pi prime; do
  for rel in bin/attendant.sh bin/lib/git-sync.sh bin/lib/greeting.sh; do
    bundled="$ROOT/packages/create-egregore/runtime/$runtime/$rel"
    if cmp -s "$ROOT/$rel" "$bundled"; then
      ok "$runtime runtime mirrors $rel"
    else
      bad "$runtime runtime drifted from $rel"
    fi
  done
done

# --- Late read --------------------------------------------------------------
# The flag must be resolved inside _apply_framework_update, after
# setup_develop() has switched branches — egregore.json can differ between the
# branch the session opened on and develop.
if grep -q '_AUTO_UPDATE=$(_read_auto_update)' "$ROOT/bin/lib/git-sync.sh"; then
  ok "flag is resolved at apply time, not at source time"
else
  bad "flag is no longer resolved inside _apply_framework_update"
fi

# --- Overwrite is visible ---------------------------------------------------
if grep -q 'FRAMEWORK_UPDATED_COUNT' "$ROOT/bin/lib/greeting.sh"; then
  ok "greeting reports how many files an update replaced"
else
  bad "greeting no longer reports what the update overwrote"
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
