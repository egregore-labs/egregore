#!/usr/bin/env bats
# Unit tests for the Pi branch-guard heuristic (bin/pi-branch-policy.mjs).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

@test "isMutatingBash case table passes" {
  run node "$SCRIPT_DIR/tests/bin/pi-branch-policy.test.mjs"
  [ "$status" -eq 0 ]
}
