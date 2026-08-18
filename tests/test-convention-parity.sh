#!/usr/bin/env bash
# test-convention-parity.sh — the convention paragraphs (### Pull request
# format / ### Commit format) must stay byte-identical across every runtime
# spec surface, and the type set must match between the two format specs.
# The paragraphs are hand-copied onto nine surfaces; this test is what
# catches drift. Specs: .claude/context/pr-format.md, commit-format.md.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0; fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); echo "  ✓ $1"
  else
    fail=$((fail + 1)); echo "  ✗ $1 — expected '$2', got '$3'"
  fi
}

SURFACES=(
  CLAUDE.md
  AGENTS.md
  .pi/APPEND_SYSTEM.md
  .prime/agent/APPEND_SYSTEM.md
  packages/create-egregore/runtime/codex/AGENTS.md
  packages/create-egregore/runtime/pi/AGENTS.md
  packages/create-egregore/runtime/pi/.pi/APPEND_SYSTEM.md
  packages/create-egregore/runtime/prime/.prime/agent/APPEND_SYSTEM.md
  packages/create-egregore/runtime/prime/AGENTS.md
)

# extract <file> <heading-title> — paragraph body between the heading and
# the next heading, blank lines dropped.
extract() {
  awk -v h="### $2" '
    $0 == h { grab = 1; next }
    grab && /^#/ { exit }
    grab { print }
  ' "$1" | sed '/^[[:space:]]*$/d'
}

# A paragraph absent everywhere is skipped (lets this test land before the
# paragraph does); present anywhere, it must be present and byte-identical
# everywhere.
para_parity() { # heading-title
  local h="$1" found=0 variants=0 first="" missing="" f p
  for f in "${SURFACES[@]}"; do
    [ -f "$f" ] || { missing="$missing $f(absent)"; continue; }
    p="$(extract "$f" "$h")"
    if [ -n "$p" ]; then
      found=$((found + 1))
      if [ -z "$first" ]; then
        first="$p"
      elif [ "$p" != "$first" ]; then
        variants=$((variants + 1))
      fi
    else
      missing="$missing $f"
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "  ○ '### $h' absent on every surface — skipped"
    return 0
  fi
  check "'### $h' present on all surfaces" "" "$missing"
  check "'### $h' byte-identical across surfaces" "0" "$variants"
}

echo "test-convention-parity"
para_parity "Pull request format (all harnesses)"
para_parity "Commit format (all harnesses)"

# The two source specs must state the same type set (they share the grammar;
# copy-parity across surfaces cannot catch the sources diverging from each
# other).
if [ -f .claude/context/commit-format.md ]; then
  TYPES='`feat` `fix` `docs` `refactor` `chore` `test` `perf` `ci`'
  a=0; b=0
  grep -qF "$TYPES" .claude/context/pr-format.md && a=1
  grep -qF "$TYPES" .claude/context/commit-format.md && b=1
  check "type set stated identically in both format specs" "1 1" "$a $b"
fi

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
