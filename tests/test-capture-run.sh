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
  CAPTURE_TEST_WAL="$WAL" TMPDIR="$TMPD" bash "$CONNECTED/bin/capture-run.sh" \
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

if grep -q 'capture-run.sh' "$ROOT/.claude/skills/wrap/SKILL.md" &&
   grep -q -- '--mode personal' "$ROOT/.claude/skills/wrap/SKILL.md" &&
   grep -q 'capture-run.sh' "$ROOT/.claude/skills/handoff/SKILL.md" &&
   grep -q -- '--verify-fidelity' "$ROOT/.claude/skills/handoff/SKILL.md" &&
   grep -q 'sourceMap' "$ROOT/.claude/skills/handoff/SKILL.md" &&
   ! grep -q '^## Step 0.5: Triage mode' "$ROOT/.claude/skills/handoff/SKILL.md" &&
   grep -q 'capture-run.sh' "$ROOT/bin/session-log.sh" &&
   grep -q -- '--mode baseline' "$ROOT/bin/session-log.sh" &&
   grep -q 'capture-run.sh --mode addressed' "$ROOT/.codex/skills/handoff/SKILL.md" &&
   grep -q -- '--verify-fidelity' "$ROOT/.codex/skills/handoff/SKILL.md" &&
   grep -q 'sourceMap' "$ROOT/.codex/skills/handoff/SKILL.md" &&
   grep -q "yaml_extract 'addressed_to'" "$ROOT/bin/index-handoff.sh" &&
   grep -q 'restore missing source content' "$ROOT/bin/render-card.sh" &&
   grep -q 'capture-run.sh --mode personal' "$ROOT/.codex/skills/wrap/SKILL.md" &&
   grep -q 'capture-run.sh' "$ROOT/bin/pi-product-workflows.mjs" &&
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

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
