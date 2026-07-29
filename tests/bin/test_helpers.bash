#!/usr/bin/env bash
# BATS test suite helpers — shared setup/teardown for bin/ tests.
#
# Usage: source this in your .bats file via setup_file/teardown_file,
# or use the individual helpers directly.
#
# Requires: bats-core (brew install bats-core)

# Create a temp directory with a minimal egregore environment
create_test_env() {
  TEST_ENV=$(mktemp -d)
  mkdir -p "$TEST_ENV/bin/lib" "$TEST_ENV/.claude" "$TEST_ENV/memory"

  # Minimal egregore.json (local mode — no API calls)
  cat > "$TEST_ENV/egregore.json" << 'JSON'
{
  "mode": "local",
  "org_name": "test-org",
  "github_org": "test-org",
  "slug": "testorg",
  "repo_name": "test-repo",
  "repos": []
}
JSON

  # Minimal state file (onboarding complete, telemetry enabled so tests can validate opt-out)
  cat > "$TEST_ENV/.egregore-state.json" << 'JSON'
{
  "github_username": "testuser",
  "github_name": "Test User",
  "name": "testuser",
  "onboarding_complete": true,
  "telemetry": true
}
JSON

  # Empty .env
  touch "$TEST_ENV/.env"

  # Init git repo so git commands don't fail
  git -C "$TEST_ENV" init --quiet 2>/dev/null
  git -C "$TEST_ENV" config user.name "testuser" 2>/dev/null
  git -C "$TEST_ENV" config user.email "test@test.com" 2>/dev/null

  echo "$TEST_ENV"
}

# Clean up test environment
destroy_test_env() {
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] && rm -rf "$dir"
}
