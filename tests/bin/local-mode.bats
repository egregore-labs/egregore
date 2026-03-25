#!/usr/bin/env bats
# Tests that all scripts handle local mode gracefully.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$SCRIPT_DIR/tests/bin/test_helpers.bash"
  TEST_ENV=$(create_test_env)

  # Copy bin/ scripts into test env
  cp -r "$SCRIPT_DIR/bin/"*.sh "$TEST_ENV/bin/"
  cp -r "$SCRIPT_DIR/bin/lib/" "$TEST_ENV/bin/lib/" 2>/dev/null || true
}

teardown() {
  destroy_test_env "$TEST_ENV"
}

@test "graph.sh returns empty results in local mode" {
  run bash "$TEST_ENV/bin/graph.sh" query "MATCH (n) RETURN n"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.results == []'
}

@test "graph.sh schema returns empty in local mode" {
  run bash "$TEST_ENV/bin/graph.sh" schema
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "graph.sh test returns offline status in local mode" {
  run bash "$TEST_ENV/bin/graph.sh" test
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "offline"'
}

@test "notify.sh returns offline in local mode" {
  run bash "$TEST_ENV/bin/notify.sh" test
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "offline"'
}

@test "graph-op.sh returns empty results in local mode" {
  run bash "$TEST_ENV/bin/graph-op.sh" mark-read "test-sid"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.results == []'
}

@test "telemetry.sh status works in local mode" {
  run bash "$TEST_ENV/bin/telemetry.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Telemetry status"* ]]
}

@test "telemetry.sh respects env var opt-out" {
  EGREGORE_NO_TELEMETRY=1 run bash "$TEST_ENV/bin/telemetry.sh" emit "bats_opt_out_test" '{"test":true}'
  [ "$status" -eq 0 ]
  # Event should NOT appear in the buffer
  ! grep -q "bats_opt_out_test" "$HOME/.egregore/telemetry.jsonl" 2>/dev/null
}
