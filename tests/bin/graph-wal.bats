#!/usr/bin/env bats
# Tests for graph-wal.sh — WAL append, drain, status.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$SCRIPT_DIR/tests/bin/test_helpers.bash"
  TEST_ENV=$(create_test_env)
  cp -r "$SCRIPT_DIR/bin/"*.sh "$TEST_ENV/bin/"
  cp -r "$SCRIPT_DIR/bin/lib/" "$TEST_ENV/bin/lib/" 2>/dev/null || true

  # Clean any existing WAL for test isolation
  PROJ_HASH=$(echo -n "$TEST_ENV" | md5 2>/dev/null || echo -n "$TEST_ENV" | md5sum 2>/dev/null | cut -d' ' -f1)
  rm -f "$HOME/.egregore/graph-wal-${PROJ_HASH}.jsonl"
  rm -rf "$HOME/.egregore/graph-wal-${PROJ_HASH}.lock"
}

teardown() {
  # Clean up WAL files
  PROJ_HASH=$(echo -n "$TEST_ENV" | md5 2>/dev/null || echo -n "$TEST_ENV" | md5sum 2>/dev/null | cut -d' ' -f1)
  rm -f "$HOME/.egregore/graph-wal-${PROJ_HASH}.jsonl"
  rm -rf "$HOME/.egregore/graph-wal-${PROJ_HASH}.lock"
  destroy_test_env "$TEST_ENV"
}

@test "graph-wal.sh status returns zero pending on empty WAL" {
  run bash "$TEST_ENV/bin/graph-wal.sh" status
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.pending == 0'
}

@test "graph-wal.sh append writes a valid JSONL entry" {
  run bash "$TEST_ENV/bin/graph-wal.sh" append "MATCH (n) RETURN n" '{"key":"value"}'
  [ "$status" -eq 0 ]

  run bash "$TEST_ENV/bin/graph-wal.sh" status
  echo "$output" | jq -e '.pending == 1'
}

@test "graph-wal.sh append handles special characters in cypher" {
  run bash "$TEST_ENV/bin/graph-wal.sh" append \
    'MATCH (n) WHERE n.name = $name RETURN n' \
    '{"name":"test \"quoted\" value"}'
  [ "$status" -eq 0 ]

  run bash "$TEST_ENV/bin/graph-wal.sh" status
  echo "$output" | jq -e '.pending == 1'
}

@test "graph-wal.sh multiple appends accumulate" {
  bash "$TEST_ENV/bin/graph-wal.sh" append "Q1" '{}'
  bash "$TEST_ENV/bin/graph-wal.sh" append "Q2" '{}'
  bash "$TEST_ENV/bin/graph-wal.sh" append "Q3" '{}'

  run bash "$TEST_ENV/bin/graph-wal.sh" status
  echo "$output" | jq -e '.pending == 3'
}
