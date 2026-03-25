#!/usr/bin/env bats
# Tests that --help works on all scripts that support it.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

@test "graph.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/graph.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "graph-op.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/graph-op.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "graph-wal.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/graph-wal.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "graph-scribe.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/graph-scribe.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "notify.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/notify.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "telemetry.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/telemetry.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "worktree.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/worktree.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "enrich-graph.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/enrich-graph.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "sync-graph.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/sync-graph.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "graph-maintenance.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/graph-maintenance.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "boundary.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/boundary.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "test-oss-release.sh --help exits 0" {
  run bash "$SCRIPT_DIR/bin/test-oss-release.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}
