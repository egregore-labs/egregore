#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPD="$(mktemp -d -t egregore-capture-run-XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }

setup_fixture() {
  local mode="$1"
  local dir="$2"
  mkdir -p "$dir/bin" "$dir/memory/wraps" "$dir/memory/sessions"
  cp "$ROOT/bin/capture-run.sh" "$dir/bin/capture-run.sh"
  cp "$ROOT/bin/capture-reconcile.sh" "$dir/bin/capture-reconcile.sh"
  cp "$ROOT/bin/handoff-run.sh" "$dir/bin/handoff-run.sh"
  printf '{"mode":"%s"}\n' "$mode" > "$dir/egregore.json"
  git -C "$dir" init --quiet
  git -C "$dir" config user.name tester
  git -C "$dir" config user.email tester@example.test
  git -C "$dir/memory" init --quiet
  git -C "$dir/memory" config user.name tester
  git -C "$dir/memory" config user.email tester@example.test
}

echo "Testing: shared capture engine"

# A wrap body is consumed at its read, before writeback can fail and before
# the closing sweep runs. Another scratch file witnesses that distinction.
WRAP_FIXTURE="$TMPD/wrap-input"
mkdir -p "$WRAP_FIXTURE/bin/lib" "$WRAP_FIXTURE/memory" "$WRAP_FIXTURE/tmp"
cp "$ROOT/bin/agent.sh" "$WRAP_FIXTURE/bin/agent.sh"
cp "$ROOT/bin/lib/scratch.sh" "$WRAP_FIXTURE/bin/lib/scratch.sh"
cp "$ROOT/bin/lib/git-message.sh" "$WRAP_FIXTURE/bin/lib/git-message.sh"
cp -R "$ROOT/egregore_runtime" "$WRAP_FIXTURE/egregore_runtime"
cat > "$WRAP_FIXTURE/bin/artifact-writeback.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$WRAP_TEST_CAPTURE"
[ -f "$WRAP_TEST_UNREAD" ]
case "$WRAP_TEST_SOURCE_KIND" in
  scratch) [ ! -e "$WRAP_TEST_BODY" ] ;;
  document) [ -f "$WRAP_TEST_BODY" ] ;;
esac
printf 'read-time assertions passed\n' > "$WRAP_TEST_RECEIPT"
exit 17
SH
cat > "$WRAP_FIXTURE/bin/scratch-sweep.sh" <<'SH'
#!/usr/bin/env bash
printf 'unexpected sweep\n' > "$WRAP_TEST_SWEEP"
SH
export WRAP_TEST_CAPTURE="$WRAP_FIXTURE/body-captured.md"
export WRAP_TEST_UNREAD="$WRAP_FIXTURE/tmp/unread-response.json"
export WRAP_TEST_RECEIPT="$WRAP_FIXTURE/read-receipt"
export WRAP_TEST_SWEEP="$WRAP_FIXTURE/sweep-receipt"
printf 'unread response\n' > "$WRAP_TEST_UNREAD"
for WRAP_TEST_SOURCE_KIND in scratch document; do
  export WRAP_TEST_SOURCE_KIND
  if [ "$WRAP_TEST_SOURCE_KIND" = scratch ]; then
    WRAP_TEST_BODY="$WRAP_FIXTURE/tmp/body.md"
  else
    WRAP_TEST_BODY="$WRAP_FIXTURE/document.md"
  fi
  export WRAP_TEST_BODY
  printf 'Body reaches writeback.\n' > "$WRAP_TEST_BODY"
  : > "$WRAP_TEST_RECEIPT"
  WRAP_TEST_STATUS=0
  TMPDIR="$WRAP_FIXTURE/tmp" bash "$WRAP_FIXTURE/bin/agent.sh" wrap --from tester --topic scratch \
    --summary "Read-time consumption" --body-file "$WRAP_TEST_BODY" --no-push \
    > "$WRAP_FIXTURE/stdout" 2> "$WRAP_FIXTURE/stderr" || WRAP_TEST_STATUS=$?
  if [ "$WRAP_TEST_STATUS" -eq 17 ] && [ -s "$WRAP_TEST_RECEIPT" ] &&
     [ "$(cat "$WRAP_TEST_CAPTURE")" = 'Body reaches writeback.' ] &&
     [ -f "$WRAP_TEST_UNREAD" ] && [ ! -e "$WRAP_TEST_SWEEP" ]; then
    ok "wrap $WRAP_TEST_SOURCE_KIND body has correct lifetime before failed writeback and sweep"
  else
    bad "wrap $WRAP_TEST_SOURCE_KIND body consumption was deferred or changed writeback failure"
    printf '  writeback status: %s\n' "$WRAP_TEST_STATUS"
    cat "$WRAP_FIXTURE/stderr"
  fi
done

for WRAP_TEST_SOURCE_KIND in scratch document; do
  export WRAP_TEST_SOURCE_KIND
  if [ "$WRAP_TEST_SOURCE_KIND" = scratch ]; then
    WRAP_TEST_BODY="$WRAP_FIXTURE/tmp/handoff-body.md"
  else
    WRAP_TEST_BODY="$WRAP_FIXTURE/handoff-document.md"
  fi
  export WRAP_TEST_BODY
  printf 'Handoff reaches writeback.\n' > "$WRAP_TEST_BODY"
  : > "$WRAP_TEST_RECEIPT"
  HANDOFF_TEST_STATUS=0
  TMPDIR="$WRAP_FIXTURE/tmp" bash "$WRAP_FIXTURE/bin/agent.sh" handoff \
    --from tester --to teammate --topic scratch --body-file "$WRAP_TEST_BODY" \
    --no-push --no-publish --no-notify > "$WRAP_FIXTURE/stdout" \
    2> "$WRAP_FIXTURE/stderr" || HANDOFF_TEST_STATUS=$?
  if [ "$HANDOFF_TEST_STATUS" -eq 17 ] && [ -s "$WRAP_TEST_RECEIPT" ] &&
     grep -Fxq 'Handoff reaches writeback.' "$WRAP_TEST_CAPTURE"; then
    ok "handoff $WRAP_TEST_SOURCE_KIND body has correct lifetime before failed writeback"
  else
    bad "handoff $WRAP_TEST_SOURCE_KIND body consumption was deferred or changed writeback failure"
    printf '  writeback status: %s\n' "$HANDOFF_TEST_STATUS"
    cat "$WRAP_FIXTURE/stderr"
  fi
done

if python3 - "$ROOT/bin/agent.sh" <<'PY'
from pathlib import Path
import sys

body = Path(sys.argv[1]).read_text().split("cmd_wrap() {", 1)[1].split("\ncmd_handoff()", 1)[0]
assert body.index('scratch-sweep.sh') > body.index('bash "$SCRIPT_DIR/bin/session-autosave.sh"')
PY
then
  ok "wrap closes with scratch sweep after session autosave"
else
  bad "wrap scratch sweep lifecycle wiring is missing or out of order"
fi

LOCAL="$TMPD/local"
setup_fixture local "$LOCAL"

printf '## Briefing\n\nPlain prose input.\n\n## Next Steps\n\n### Command 1\n\n```bash\npwd\n```\n' |
  TMPDIR="$TMPD" bash "$LOCAL/bin/capture-run.sh" \
    --mode addressed \
    --author tester \
    --topic "metadata boundary" \
    --recipient teammate \
    --intent action \
    --no-push \
    --no-publish \
    --no-notify >/dev/null
ADDRESSED="$(jq -r '.absFile' "$TMPD/capture-run-result.json")"

if grep -q '^capture_schema: egregore-capture/v1$' "$ADDRESSED" &&
   grep -q '^from: tester$' "$ADDRESSED" &&
   grep -q '^addressed_to: teammate$' "$ADDRESSED" &&
   grep -q '^topic: metadata boundary$' "$ADDRESSED" &&
   grep -q '^intent: action$' "$ADDRESSED" &&
   grep -q '^### Command 1$' "$ADDRESSED"; then
  ok "addressed capture normalizes metadata without rewriting authored content"
else
  bad "addressed capture metadata boundary lost identity or content"
fi

printf 'Personal details\n' |
  TMPDIR="$TMPD" bash "$LOCAL/bin/capture-run.sh" \
    --mode personal \
    --author tester \
    --topic "capture parity" \
    --summary "Personal summary" \
    --session-id "session-personal" \
    --branch "dev/tester/capture" \
    --no-push >/dev/null
PERSONAL="$(jq -r '.absFile' "$TMPD/capture-run-result.json")"

printf '## Files\n\n- bin/example.sh\n' |
  TMPDIR="$TMPD" bash "$LOCAL/bin/capture-run.sh" \
    --mode baseline \
    --author tester \
    --topic "baseline parity" \
    --summary "Baseline summary" \
    --session-id "session-baseline" \
    --branch "dev/tester/capture" \
    --duration "5min" \
    --no-push >/dev/null
BASELINE="$(jq -r '.absFile' "$TMPD/capture-run-result.json")"

if grep -q '^\*\*Capture Schema\*\*: egregore-capture/v1$' "$PERSONAL" &&
   grep -q '^\*\*Capture Schema\*\*: egregore-capture/v1$' "$BASELINE" &&
   grep -q '^\*\*To\*\*: tester$' "$PERSONAL" &&
   grep -q '^\*\*To\*\*: tester$' "$BASELINE"; then
  ok "personal and baseline captures share the canonical record fields"
else
  bad "capture modes drifted from the canonical record fields"
fi

if grep -q '^\*\*Capture Mode\*\*: personal$' "$PERSONAL" &&
   grep -q '^\*\*Capture Mode\*\*: baseline$' "$BASELINE" &&
   grep -q '^## Notes$' "$PERSONAL" &&
   grep -q '^## Files$' "$BASELINE"; then
  ok "mode-specific content remains distinguishable"
else
  bad "capture mode content was not preserved"
fi

CONNECTED="$TMPD/connected"
setup_fixture connected "$CONNECTED"
cat > "$CONNECTED/bin/graph-wal.sh" <<'SH'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "append" ]; then
  params="${3:-}"
  [ -n "$params" ] || params='{}'
  jq -nc --arg cypher "${2:-}" --argjson params "$params" \
    '{cypher:$cypher,params:$params}' >> "${CAPTURE_TEST_WAL:?}"
fi
SH

WAL="$TMPD/wal.jsonl"
start_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
printf 'Connected details\n' |
  EGREGORE_GRAPH_PROJECTION=1 CAPTURE_TEST_WAL="$WAL" TMPDIR="$TMPD" bash "$CONNECTED/bin/capture-run.sh" \
    --mode personal \
    --author tester \
    --topic "queued lifecycle" \
    --summary "Explicit wrap evidence" \
    --session-id "session-connected" \
    --branch "dev/tester/capture" \
    --no-push \
    --no-reconcile >/dev/null
end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
elapsed=$((end_ms - start_ms))

if [ "$(wc -l < "$WAL" | tr -d ' ')" = "2" ] &&
   jq -s -e '.[0].params.captureMode == "personal"
     and (.[1].cypher | contains("single_recipient_implemented"))' "$WAL" >/dev/null; then
  ok "explicit wrap queues Session state and handoff completion"
else
  bad "explicit wrap did not queue both graph transitions"
fi

if [ "$elapsed" -lt 1000 ]; then
  ok "queue-only capture stays off the network critical path (${elapsed}ms)"
else
  bad "queue-only capture exceeded 1000ms (${elapsed}ms)"
fi

if grep -q 'GRAPH_WAL_LOCK_ATTEMPTS=1' "$ROOT/bin/capture-run.sh" &&
   grep -q 'GRAPH_WAL_LOCK_ATTEMPTS' "$ROOT/bin/graph-wal.sh"; then
  ok "capture queue bounds WAL lock contention"
else
  bad "capture queue can inherit the five-second WAL lock wait"
fi

if jq -s -e '.[1].cypher
    | contains("recipientCount = 1")
      and contains("handoffLifecycleVersion")
      and contains("[\"pending\",\"read\",\"claimed\"]")
      and contains("coalesce(ho.handoffDoneAt, datetime())")' "$WAL" >/dev/null; then
  ok "completion transition is scoped and idempotent"
else
  bad "completion transition lacks lifecycle safety guards"
fi

cat > "$CONNECTED/bin/capture-reconcile.sh" <<'SH'
#!/bin/bash
printf 'started\n' > "${CAPTURE_TEST_RECONCILE_MARKER:?}"
sleep 2
printf 'finished\n' > "${CAPTURE_TEST_RECONCILE_MARKER:?}"
SH
RECONCILE_MARKER="$TMPD/reconcile.marker"
start_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
printf 'Detached worker details\n' |
  EGREGORE_GRAPH_PROJECTION=1 \
  CAPTURE_TEST_WAL="$WAL" \
  CAPTURE_TEST_RECONCILE_MARKER="$RECONCILE_MARKER" \
  TMPDIR="$TMPD" bash "$CONNECTED/bin/capture-run.sh" \
    --mode personal \
    --author tester \
    --topic "detached reconciliation" \
    --summary "Worker must not block" \
    --session-id "session-detached" \
    --branch "dev/tester/capture" \
    --no-push >/dev/null
end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
detached_elapsed=$((end_ms - start_ms))

if [ "$detached_elapsed" -lt 1000 ]; then
  ok "detached reconciliation does not delay the caller (${detached_elapsed}ms)"
else
  bad "reconciliation blocked the caller for ${detached_elapsed}ms"
fi

# Canonical handoff preview/approval and no-triage policy are pinned in
# tests/test_handoff_skill_intent.py; this suite covers their capture wiring.
if grep -q 'bash bin/agent.sh wrap' "$ROOT/.claude/skills/wrap/SKILL.md" &&
   grep -q 'one writeback transaction' "$ROOT/.claude/skills/wrap/SKILL.md" &&
   grep -q 'capture-run.sh' "$ROOT/bin/session-log.sh" &&
   grep -q -- '--mode baseline' "$ROOT/bin/session-log.sh" &&
   grep -Fq 'maintained body is `.claude/skills/handoff/SKILL.md`' "$ROOT/.codex/skills/handoff/SKILL.md" &&
   grep -q "yaml_extract 'addressed_to'" "$ROOT/bin/index-handoff.sh" &&
   grep -q 'restore missing source content' "$ROOT/bin/render-card.sh" &&
   grep -Fq 'maintained body is `.claude/skills/wrap/SKILL.md`' "$ROOT/.codex/skills/wrap/SKILL.md" &&
   grep -q 'one personal canonical writeback transaction' "$ROOT/.claude/skills/wrap/SKILL.md" &&
   grep -q 'artifact-writeback.sh' "$ROOT/bin/pi-product-workflows.mjs" &&
   grep -q -- '--mode addressed' "$ROOT/bin/pi-product-workflows.mjs" &&
   grep -q '^    "capture_schema: egregore-capture/v1",$' "$ROOT/bin/pi-product-workflows.mjs" &&
   grep -q 'captureSessionEnd' "$ROOT/bin/pi-product-workflows.mjs" &&
   grep -q 'pi.on("session_shutdown"' "$ROOT/.pi/extensions/egregore.ts" &&
   grep -q 'captureSessionEnd' "$ROOT/.pi/extensions/egregore.ts" &&
   grep -q 'show my handoffs.*review or close' "$ROOT/bin/lib/greeting.sh" &&
   grep -q 'show my handoffs.*review or close' "$ROOT/bin/codex-session-start.sh"; then
  ok "Claude Code, Codex, and Pi capture doors route together"
else
  bad "cross-runtime capture routing or passive lifecycle discovery regressed"
fi

# --- session-end capture measures the session from its timestamped lines ---
# Interactive transcripts open with an untimestamped `last-prompt` record and
# may close with one; reading only the first and last lines computed a zero
# duration, tripped the empty-session guard, and dropped every capture
# (2026-08-07 → 09-23). The capture must come from the first and last lines
# that carry a timestamp, and an empty transcript must still be skipped.
SL="$TMPD/session-log"
setup_fixture local "$SL"
cp "$ROOT/bin/session-log.sh" "$SL/bin/session-log.sh"
printf '{"github_username":"tester","display_name":"Tester"}\n' > "$SL/.egregore-state.json"
printf '%s\n' \
  '{"type":"last-prompt","prompt":"hi"}' \
  '{"type":"user","timestamp":"2026-09-23T11:38:15.259Z","message":{"role":"user"}}' \
  '{"type":"assistant","timestamp":"2026-09-23T12:17:01.240Z","message":{"role":"assistant"}}' \
  '{"type":"file-history-snapshot","snapshot":{}}' > "$TMPD/transcript-real.jsonl"
printf '{"session_id":"sess-real-shape","transcript_path":"%s"}' "$TMPD/transcript-real.jsonl" |
  TMPDIR="$TMPD" bash "$SL/bin/session-log.sh" || true
REAL_CAPTURE="$(grep -rl 'sess-real-shape' "$SL/memory/sessions" 2>/dev/null | head -1 || true)"
if [ -n "$REAL_CAPTURE" ] && grep -q '^\*\*Duration\*\*: 38min$' "$REAL_CAPTURE" &&
   grep -q '^date: 2026-09-23$' "$REAL_CAPTURE"; then
  ok "session-end capture measures a real-shaped transcript from its timestamped lines"
else
  bad "session-end capture lost the session whose transcript opens without a timestamp"
fi

printf '%s\n' '{"type":"last-prompt","prompt":"hi"}' '{"type":"file-history-snapshot","snapshot":{}}' > "$TMPD/transcript-empty.jsonl"
printf '{"session_id":"sess-empty-shape","transcript_path":"%s"}' "$TMPD/transcript-empty.jsonl" |
  TMPDIR="$TMPD" bash "$SL/bin/session-log.sh" || true
if grep -rq 'sess-empty-shape' "$SL/memory/sessions" 2>/dev/null; then
  bad "session-end capture recorded a transcript with no activity"
else
  ok "session-end capture still skips a transcript with no timestamped activity"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
