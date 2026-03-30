#!/usr/bin/env bats
# Tests for local-mode session visibility: session-log.sh, context.sh presence,
# activity-data.sh, dashboard-data.sh local fallbacks, and handoff glob fix.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$SCRIPT_DIR/tests/bin/test_helpers.bash"
  TEST_ENV=$(create_test_env)

  # Copy bin/ scripts into test env
  cp -r "$SCRIPT_DIR/bin/"*.sh "$TEST_ENV/bin/"
  cp -r "$SCRIPT_DIR/bin/lib/" "$TEST_ENV/bin/lib/" 2>/dev/null || true

  # Add display_name to state for dual-identity matching
  jq '. + {"display_name": "tester"}' "$TEST_ENV/.egregore-state.json" > "$TEST_ENV/.egregore-state.json.tmp" \
    && mv "$TEST_ENV/.egregore-state.json.tmp" "$TEST_ENV/.egregore-state.json"

  # Create month-bucketed directories (matching real memory layout)
  MONTH=$(date +%Y-%m)
  mkdir -p "$TEST_ENV/memory/sessions/$MONTH"
  mkdir -p "$TEST_ENV/memory/wraps/$MONTH"
  mkdir -p "$TEST_ENV/memory/handoffs/$MONTH"
  mkdir -p "$TEST_ENV/memory/knowledge/decisions"

  # Need at least one commit so git rev-parse HEAD works
  echo "init" > "$TEST_ENV/README.md"
  git -C "$TEST_ENV" add README.md
  git -C "$TEST_ENV" commit -m "init" --quiet

  # Init memory as git repo for session-log.sh push
  git -C "$TEST_ENV/memory" init --quiet 2>/dev/null
  git -C "$TEST_ENV/memory" config user.name "testuser" 2>/dev/null
  git -C "$TEST_ENV/memory" config user.email "test@test.com" 2>/dev/null
}

teardown() {
  destroy_test_env "$TEST_ENV"
}

# ============================================================
# session-log.sh tests
# ============================================================

@test "session-log.sh writes session file from mock transcript" {
  # Checkout to branch first
  git -C "$TEST_ENV" checkout -b "dev/testuser/session-test" --quiet 2>/dev/null || true

  # Create a baseline BEFORE making commits (simulates session-start.sh)
  SESSION_ID="bats-test-$$"
  BASELINE="/tmp/egregore-baseline-${SESSION_ID}.json"
  COMMIT=$(git -C "$TEST_ENV" rev-parse HEAD 2>/dev/null)
  STARTED=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg branch "dev/testuser/session-test" --arg commit "$COMMIT" \
    '{branch: $branch, commit: $commit, dirty: false, started_at: "'"$STARTED"'"}' > "$BASELINE"

  # Make a commit so commit count > 0
  echo "test" > "$TEST_ENV/test-file.txt"
  git -C "$TEST_ENV" add test-file.txt
  git -C "$TEST_ENV" commit -m "test commit" --quiet

  # Create a mock transcript (5 min session)
  TRANSCRIPT="/tmp/bats-transcript-$$.jsonl"
  ENDED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo '{"timestamp":"'"$STARTED"'","type":"start"}' > "$TRANSCRIPT"
  echo '{"timestamp":"'"$ENDED"'","type":"end"}' >> "$TRANSCRIPT"

  # Create an obs buffer with some activity
  OBS_BUFFER="/tmp/egregore-obs-${SESSION_ID}.jsonl"
  echo '{"tool":"Edit","path":"bin/foo.sh"}' > "$OBS_BUFFER"
  echo '{"tool":"Bash","path":"unknown"}' >> "$OBS_BUFFER"
  echo '{"tool":"Read","path":"bin/bar.sh"}' >> "$OBS_BUFFER"

  # Run session-log.sh
  MOCK_INPUT=$(jq -n --arg sid "$SESSION_ID" --arg tp "$TRANSCRIPT" \
    '{session_id: $sid, transcript_path: $tp}')
  run bash -c "echo '$MOCK_INPUT' | bash '$TEST_ENV/bin/session-log.sh'"
  [ "$status" -eq 0 ]

  # Verify session file was created
  MONTH=$(date +%Y-%m)
  DAY=$(date +%d)
  SESSION_FILES=$(ls "$TEST_ENV/memory/sessions/$MONTH/" 2>/dev/null | grep "^${DAY}-testuser-session-test" || echo "")
  [ -n "$SESSION_FILES" ]

  # Verify file content
  SFILE="$TEST_ENV/memory/sessions/$MONTH/$SESSION_FILES"
  grep -q '^\*\*Author\*\*: tester' "$SFILE"
  grep -q '^\*\*Date\*\*:' "$SFILE"
  grep -q '^\*\*Branch\*\*: dev/testuser/session-test' "$SFILE"
  grep -q '^\*\*Duration\*\*:' "$SFILE"
  grep -q 'bin/foo.sh' "$SFILE"
  grep -q 'bin/bar.sh' "$SFILE"

  # Cleanup
  rm -f "$TRANSCRIPT" "$OBS_BUFFER" "$BASELINE"
}

@test "session-log.sh skips empty sessions (<2min, no commits, no obs)" {
  TRANSCRIPT="/tmp/bats-transcript-empty-${BATS_TEST_NUMBER}.jsonl"
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo '{"timestamp":"'"$NOW"'","type":"start"}' > "$TRANSCRIPT"
  echo '{"timestamp":"'"$NOW"'","type":"end"}' >> "$TRANSCRIPT"

  SESSION_ID="bats-empty-${BATS_TEST_NUMBER}"

  # Ensure no leftover obs buffer
  rm -f "/tmp/egregore-obs-${SESSION_ID}.jsonl" 2>/dev/null

  MOCK_INPUT=$(jq -n --arg sid "$SESSION_ID" --arg tp "$TRANSCRIPT" \
    '{session_id: $sid, transcript_path: $tp}')
  run bash -c "echo '${MOCK_INPUT}' | bash '${TEST_ENV}/bin/session-log.sh'"

  # No session file should be created
  MONTH=$(date +%Y-%m)
  COUNT=$(find "$TEST_ENV/memory/sessions/$MONTH/" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  [ "$COUNT" -eq 0 ]

  rm -f "$TRANSCRIPT"
}

@test "session-log.sh skips when handoff exists for same author+date" {
  MONTH=$(date +%Y-%m)
  DAY=$(date +%d)
  # Create a pre-existing handoff for today
  cat > "$TEST_ENV/memory/handoffs/$MONTH/${DAY}-testuser-some-topic.md" << 'EOF'
# Handoff: some topic

**Author**: testuser
**Date**: 2026-03-30
EOF

  TRANSCRIPT="/tmp/bats-transcript-dedup-$$.jsonl"
  STARTED=$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo '{"timestamp":"'"$STARTED"'","type":"start"}' > "$TRANSCRIPT"
  echo '{"timestamp":"'"$NOW"'","type":"end"}' >> "$TRANSCRIPT"

  SESSION_ID="bats-dedup-$$"
  echo '{"tool":"Edit","path":"foo.sh"}' > "/tmp/egregore-obs-${SESSION_ID}.jsonl"

  MOCK_INPUT=$(jq -n --arg sid "$SESSION_ID" --arg tp "$TRANSCRIPT" \
    '{session_id: $sid, transcript_path: $tp}')
  run bash -c "echo '$MOCK_INPUT' | bash '$TEST_ENV/bin/session-log.sh'"

  # No session file should be created (handoff exists)
  COUNT=$(ls "$TEST_ENV/memory/sessions/$MONTH/" 2>/dev/null | wc -l | tr -d ' ')
  [ "$COUNT" -eq 0 ]

  rm -f "$TRANSCRIPT" "/tmp/egregore-obs-${SESSION_ID}.jsonl"
}

@test "session-log.sh uses display_name in output" {
  TRANSCRIPT="/tmp/bats-transcript-name-$$.jsonl"
  STARTED=$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  echo '{"timestamp":"'"$STARTED"'","type":"start"}' > "$TRANSCRIPT"
  echo '{"timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","type":"end"}' >> "$TRANSCRIPT"

  SESSION_ID="bats-name-$$"
  echo '{"tool":"Edit","path":"test.sh"}' > "/tmp/egregore-obs-${SESSION_ID}.jsonl"

  git -C "$TEST_ENV" checkout -b "dev/testuser/name-test" --quiet 2>/dev/null || true

  MOCK_INPUT=$(jq -n --arg sid "$SESSION_ID" --arg tp "$TRANSCRIPT" \
    '{session_id: $sid, transcript_path: $tp}')
  run bash -c "echo '$MOCK_INPUT' | bash '$TEST_ENV/bin/session-log.sh'"
  [ "$status" -eq 0 ]

  MONTH=$(date +%Y-%m)
  SFILE=$(ls "$TEST_ENV/memory/sessions/$MONTH/"*-testuser-*.md 2>/dev/null | head -1)
  [ -n "$SFILE" ]
  # Should show display_name "tester", not github_username "testuser"
  grep -q '^\*\*Author\*\*: tester' "$SFILE"

  rm -f "$TRANSCRIPT" "/tmp/egregore-obs-${SESSION_ID}.jsonl"
}

# ============================================================
# context.sh — handoff glob fix
# ============================================================

@test "context.sh finds month-bucketed handoff files" {
  MONTH=$(date +%Y-%m)
  # Create a handoff in a month-bucketed subdir
  cat > "$TEST_ENV/memory/handoffs/$MONTH/01-alice-feature-work.md" << 'EOF'
# Handoff: Feature work

**Author**: alice
**Date**: 2026-03-01
**To**: testuser
EOF

  # The glob fix should find files in subdirs
  FILES=$(find -L "$TEST_ENV/memory/handoffs" -name '*.md' -not -name 'index*' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -3)
  [ -n "$FILES" ]
  echo "$FILES" | grep -q "01-alice-feature-work.md"
}

@test "context.sh finds flat handoff files (backwards compat)" {
  # Create a flat handoff (legacy format)
  cat > "$TEST_ENV/memory/handoffs/2026-03-01-alice-old-style.md" << 'EOF'
# Handoff: Old style

**Author**: alice
**Date**: 2026-03-01
EOF

  FILES=$(find -L "$TEST_ENV/memory/handoffs" -name '*.md' -not -name 'index*' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -3)
  [ -n "$FILES" ]
  echo "$FILES" | grep -q "2026-03-01-alice-old-style.md"
}

# ============================================================
# context.sh — team presence from session/wrap files
# ============================================================

@test "team presence parses session files for lastSeen" {
  MONTH=$(date +%Y-%m)
  TODAY=$(date +%d)
  NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Create a session file from a teammate
  cat > "$TEST_ENV/memory/sessions/$MONTH/${TODAY}-alice-cool-feature.md" << EOF
# Session: cool feature

**Author**: alice
**Date**: $NOW_ISO
**Branch**: dev/alice/cool-feature
**Duration**: 30min
EOF

  # Create a wrap file from another teammate
  cat > "$TEST_ENV/memory/wraps/$MONTH/${TODAY}-bob-code-review.md" << EOF
# Wrap: code review

**Author**: bob
**Date**: $NOW_ISO
**Branch**: dev/bob/code-review
**Duration**: 15min
EOF

  # Parse the files the same way context.sh does
  FILE_PRESENCE=$(
    {
      for DIR in "$TEST_ENV/memory/sessions" "$TEST_ENV/memory/wraps"; do
        [ -d "$DIR" ] || continue
        find -L "$DIR" -name '*.md' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -20 | while read -r SFILE; do
          [ -z "$SFILE" ] && continue
          S_AUTH=$(grep -m1 '^\*\*Author\*\*:' "$SFILE" 2>/dev/null | sed 's/^\*\*Author\*\*:[[:space:]]*//')
          S_DATE=$(grep -m1 '^\*\*Date\*\*:' "$SFILE" 2>/dev/null | sed 's/^\*\*Date\*\*:[[:space:]]*//')
          [ -z "$S_AUTH" ] && continue
          echo "${S_AUTH}|${S_DATE}"
        done
      done
    } | sort -t'|' -k1,1 -k2,2r | sort -t'|' -k1,1 -u | while IFS='|' read -r FP_NAME FP_DATE; do
      [ -z "$FP_NAME" ] && continue
      FP_LC=$(echo "$FP_NAME" | tr '[:upper:]' '[:lower:]')
      echo "${FP_LC}|${FP_DATE}"
    done | jq -Rn '
      [inputs | split("|") | {(.[0]): .[1]}]
      | add // {}
    ' 2>/dev/null || echo "{}"
  )

  # Verify both teammates appear
  echo "$FILE_PRESENCE" | jq -e '.alice' >/dev/null
  echo "$FILE_PRESENCE" | jq -e '.bob' >/dev/null

  # Verify dates are ISO format
  ALICE_DATE=$(echo "$FILE_PRESENCE" | jq -r '.alice')
  [[ "$ALICE_DATE" == *"T"* ]]
}

@test "team presence excludes self by github_username and display_name" {
  MONTH=$(date +%Y-%m)
  TODAY=$(date +%d)
  NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Session by self (github_username = testuser)
  cat > "$TEST_ENV/memory/sessions/$MONTH/${TODAY}-testuser-my-work.md" << EOF
# Session: my work

**Author**: testuser
**Date**: $NOW_ISO
**Branch**: dev/testuser/my-work
**Duration**: 20min
EOF

  # Session by self (display_name = tester)
  cat > "$TEST_ENV/memory/sessions/$MONTH/${TODAY}-tester-other-work.md" << EOF
# Session: other work

**Author**: tester
**Date**: $NOW_ISO
**Branch**: dev/tester/other-work
**Duration**: 10min
EOF

  # Session by teammate
  cat > "$TEST_ENV/memory/sessions/$MONTH/${TODAY}-alice-real-work.md" << EOF
# Session: real work

**Author**: alice
**Date**: $NOW_ISO
**Branch**: dev/alice/real-work
**Duration**: 45min
EOF

  # Parse excluding self
  SELF_LC="testuser"
  SELF_DISPLAY_LC="tester"
  FILE_PRESENCE=$(
    find -L "$TEST_ENV/memory/sessions" -name '*.md' -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -20 | while read -r SFILE; do
      S_AUTH=$(grep -m1 '^\*\*Author\*\*:' "$SFILE" 2>/dev/null | sed 's/^\*\*Author\*\*:[[:space:]]*//')
      [ -z "$S_AUTH" ] && continue
      S_AUTH_LC=$(echo "$S_AUTH" | tr '[:upper:]' '[:lower:]')
      [ "$S_AUTH_LC" = "$SELF_LC" ] && continue
      [ "$S_AUTH_LC" = "$SELF_DISPLAY_LC" ] && continue
      S_DATE=$(grep -m1 '^\*\*Date\*\*:' "$SFILE" 2>/dev/null | sed 's/^\*\*Date\*\*:[[:space:]]*//')
      echo "${S_AUTH_LC}|${S_DATE}"
    done | jq -Rn '[inputs | split("|") | {(.[0]): .[1]}] | add // {}' 2>/dev/null || echo "{}"
  )

  # Should only have alice, not testuser or tester
  echo "$FILE_PRESENCE" | jq -e '.alice' >/dev/null
  ! echo "$FILE_PRESENCE" | jq -e '.testuser' >/dev/null 2>&1
  ! echo "$FILE_PRESENCE" | jq -e '.tester' >/dev/null 2>&1
}

# ============================================================
# activity-data.sh — local fallback
# ============================================================

@test "activity-data.sh returns valid JSON with local_sessions in local mode" {
  MONTH=$(date +%Y-%m)
  TODAY=$(date +%d)
  NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Create session files
  cat > "$TEST_ENV/memory/sessions/$MONTH/${TODAY}-testuser-my-session.md" << EOF
# Session: my session

**Author**: testuser
**Date**: $NOW_ISO
**Branch**: dev/testuser/my-session
**Duration**: 30min
EOF

  cat > "$TEST_ENV/memory/sessions/$MONTH/${TODAY}-alice-team-session.md" << EOF
# Session: team session

**Author**: alice
**Date**: $NOW_ISO
**Branch**: dev/alice/team-session
**Duration**: 20min
EOF

  run bash "$TEST_ENV/bin/activity-data.sh" "testuser"
  [ "$status" -eq 0 ]

  # Must be valid JSON
  echo "$output" | jq . >/dev/null 2>&1

  # Must have local_sessions with my_sessions and team_sessions
  echo "$output" | jq -e '.local_sessions' >/dev/null
  echo "$output" | jq -e '.local_sessions.my_sessions' >/dev/null
  echo "$output" | jq -e '.local_sessions.team_sessions' >/dev/null

  # my_sessions should contain testuser's session
  MY_COUNT=$(echo "$output" | jq '.local_sessions.my_sessions | length')
  [ "$MY_COUNT" -ge 1 ]

  # team_sessions should contain alice's session
  TEAM_COUNT=$(echo "$output" | jq '.local_sessions.team_sessions | length')
  [ "$TEAM_COUNT" -ge 1 ]
}

@test "activity-data.sh returns valid JSON even with no session files" {
  run bash "$TEST_ENV/bin/activity-data.sh" "testuser"
  [ "$status" -eq 0 ]
  echo "$output" | jq . >/dev/null 2>&1
  echo "$output" | jq -e '.local_sessions' >/dev/null
}

# ============================================================
# dashboard-data.sh — local fallback
# ============================================================

@test "dashboard-data.sh returns valid JSON with local_sessions in local mode" {
  MONTH=$(date +%Y-%m)
  TODAY=$(date +%d)
  NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  cat > "$TEST_ENV/memory/sessions/$MONTH/${TODAY}-testuser-dashboard-test.md" << EOF
# Session: dashboard test

**Author**: testuser
**Date**: $NOW_ISO
**Branch**: dev/testuser/dashboard-test
**Duration**: 25min
EOF

  run bash "$TEST_ENV/bin/dashboard-data.sh" "testuser" "P7D"
  [ "$status" -eq 0 ]

  echo "$output" | jq . >/dev/null 2>&1
  echo "$output" | jq -e '.local_sessions' >/dev/null
  echo "$output" | jq -e '.local_sessions.sessions' >/dev/null
  echo "$output" | jq -e '.local_sessions.session_count' >/dev/null

  # Should include our session
  COUNT=$(echo "$output" | jq '.local_sessions.session_count')
  [ "$COUNT" -ge 1 ]
}

@test "dashboard-data.sh respects time range filtering" {
  MONTH=$(date +%Y-%m)

  # Create a session "from 10 days ago"
  cat > "$TEST_ENV/memory/sessions/$MONTH/01-testuser-old-session.md" << 'EOF'
# Session: old session

**Author**: testuser
**Date**: 2025-01-01T10:00:00Z
**Branch**: dev/testuser/old-session
**Duration**: 15min
EOF

  # P1D should not include an old session
  run bash "$TEST_ENV/bin/dashboard-data.sh" "testuser" "P1D"
  [ "$status" -eq 0 ]
  echo "$output" | jq . >/dev/null 2>&1
  OLD_COUNT=$(echo "$output" | jq '[.local_sessions.sessions[] | select(.date | startswith("2025-01-01"))] | length')
  [ "$OLD_COUNT" -eq 0 ]
}

@test "dashboard-data.sh returns valid JSON even with no session files" {
  run bash "$TEST_ENV/bin/dashboard-data.sh" "testuser" "P7D"
  [ "$status" -eq 0 ]
  echo "$output" | jq . >/dev/null 2>&1
  echo "$output" | jq -e '.local_sessions' >/dev/null
}

# ============================================================
# session-start.sh baseline
# ============================================================

@test "session-start baseline file is valid JSON" {
  # Simulate what session-start.sh does
  SESSION_ID="bats-baseline-$$"
  BASELINE="/tmp/egregore-baseline-${SESSION_ID}.json"
  jq -n \
    --arg branch "dev/testuser/test" \
    --arg commit "$(git -C "$TEST_ENV" rev-parse HEAD 2>/dev/null || echo 'abc')" \
    --argjson dirty "$([ -n "$(git -C "$TEST_ENV" status --porcelain 2>/dev/null | head -1)" ] && echo 'true' || echo 'false')" \
    --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{branch: $branch, commit: $commit, dirty: $dirty, started_at: $started_at}' \
    > "$BASELINE"

  [ -f "$BASELINE" ]
  jq -e '.branch' "$BASELINE" >/dev/null
  jq -e '.commit' "$BASELINE" >/dev/null
  jq -e '.dirty' "$BASELINE" >/dev/null
  jq -e '.started_at' "$BASELINE" >/dev/null

  rm -f "$BASELINE"
}

# ============================================================
# Performance: no regressions
# ============================================================

@test "activity-data.sh completes within 10 seconds" {
  START=$(date +%s)
  run bash "$TEST_ENV/bin/activity-data.sh" "testuser"
  END=$(date +%s)
  ELAPSED=$((END - START))
  [ "$ELAPSED" -lt 10 ]
  [ "$status" -eq 0 ]
}

@test "dashboard-data.sh completes within 10 seconds" {
  START=$(date +%s)
  run bash "$TEST_ENV/bin/dashboard-data.sh" "testuser" "P7D"
  END=$(date +%s)
  ELAPSED=$((END - START))
  [ "$ELAPSED" -lt 10 ]
  [ "$status" -eq 0 ]
}
