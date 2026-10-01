#!/usr/bin/env bash
set -euo pipefail
# Live: reads this instance's live state file. Opt in with EGREGORE_LIVE_INTEGRATION=1; otherwise report a skip.
if [ "${EGREGORE_LIVE_INTEGRATION:-}" != 1 ]; then echo "SKIP: reads this instance's live state file; set EGREGORE_LIVE_INTEGRATION=1 to run"; exit 0; fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/fakebin"

# Shell adapters execute exactly one Runtime snapshot command.
cat > "$TMPD/fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
printf '%s\n' '{"schema_version":"egregore-status-snapshot/v1","handoffs":[],"handoffs_to_me":[]}'
SH
chmod +x "$TMPD/fakebin/python3"

CALL_LOG="$TMPD/activity.calls" PATH="$TMPD/fakebin:$PATH" \
  bash "$ROOT/bin/activity-data.sh" >/dev/null
CALL_LOG="$TMPD/dashboard.calls" PATH="$TMPD/fakebin:$PATH" \
  bash "$ROOT/bin/dashboard-data.sh" P7D >/dev/null

[ "$(wc -l < "$TMPD/activity.calls" | tr -d ' ')" = "1" ]
[ "$(wc -l < "$TMPD/dashboard.calls" | tr -d ' ')" = "1" ]
grep -Fq -- '-m egregore_runtime.status_cli activity' "$TMPD/activity.calls"
grep -Fq -- '-m egregore_runtime.status_cli dashboard' "$TMPD/dashboard.calls"

# Default reads must not touch network helpers, even for a Connected checkout.
cat > "$TMPD/fakebin/curl" <<'SH'
#!/usr/bin/env bash
echo curl >> "$NETWORK_LOG"
exit 99
SH
cat > "$TMPD/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo gh >> "$NETWORK_LOG"
exit 99
SH
chmod +x "$TMPD/fakebin/curl" "$TMPD/fakebin/gh"
rm -f "$TMPD/fakebin/python3"

NETWORK_LOG="$TMPD/network.calls" PATH="$TMPD/fakebin:$PATH" \
  bash "$ROOT/bin/activity-data.sh" > "$TMPD/activity.json"
NETWORK_LOG="$TMPD/network.calls" PATH="$TMPD/fakebin:$PATH" \
  bash "$ROOT/bin/dashboard-data.sh" P7D > "$TMPD/dashboard.json"

[ ! -e "$TMPD/network.calls" ]
jq -e '.schema_version == "egregore-status-snapshot/v1"' "$TMPD/activity.json" >/dev/null
jq -e '.schema_version == "egregore-status-snapshot/v1"' "$TMPD/dashboard.json" >/dev/null
jq -e '.lifecycle.authority == "canonical_markdown" and .lifecycle.graph_dependency == false' \
  "$TMPD/dashboard.json" >/dev/null

# Skills are thin consumers; no implementation-specific calls or hidden sync.
for skill in \
  "$ROOT/.claude/skills/activity/SKILL.md" \
  "$ROOT/.codex/skills/activity/SKILL.md" \
  "$ROOT/.claude/skills/dashboard/SKILL.md" \
  "$ROOT/.codex/skills/dashboard/SKILL.md"; do
  ! grep -Eq '^[[:space:]]*(bash[[:space:]]+)?bin/(graph|graph-op|graph-batch|search)\.sh' "$skill"
  ! grep -Eq '^[[:space:]]*(git[[:space:]]+(fetch|pull)|gh[[:space:]]|curl[[:space:]])' "$skill"
done

echo "PASS: status rituals use one bounded canonical Runtime snapshot"
