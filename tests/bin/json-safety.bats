#!/usr/bin/env bats
# Tests that JSON construction is safe across all scripts.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

@test "no manual JSON construction in bin/ scripts" {
  # The pattern {\"key\":\"$VAR\"} is unsafe — should use jq -n instead
  result=$(grep -rn '"{\\\"' "$SCRIPT_DIR/bin/" --include='*.sh' 2>/dev/null | grep -v 'test-' || true)
  [ -z "$result" ]
}

@test "no source .env in bin/ scripts" {
  result=$(grep -rn 'source.*\.env' "$SCRIPT_DIR/bin/" --include='*.sh' 2>/dev/null | grep -v 'test-' | grep -v '#' || true)
  [ -z "$result" ]
}

@test "all scripts pass bash -n syntax check" {
  local failures=""
  for f in "$SCRIPT_DIR"/bin/*.sh; do
    if ! bash -n "$f" 2>/dev/null; then
      failures="$failures $(basename "$f")"
    fi
  done
  [ -z "$failures" ]
}

@test "all lib scripts pass bash -n syntax check" {
  local failures=""
  for f in "$SCRIPT_DIR"/bin/lib/*.sh; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
      failures="$failures $(basename "$f")"
    fi
  done
  [ -z "$failures" ]
}
