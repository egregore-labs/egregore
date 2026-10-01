#!/usr/bin/env bash
# Render real status surfaces with compatibility payloads; only labels change.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER="$ROOT/bin/codex-skill-render.mjs"
render() { printf '%s\n' "$2" | bash "$ROOT/bin/node-run.sh" "$RENDER" "$1" -; }
assert_copy() {
  local output="$1" expected="$2"
  grep -q "$expected" <<< "$output"
  if grep -iq 'graph' <<< "$output"; then
    printf 'Legacy storage wording leaked: %s\n' "$output" >&2
    exit 1
  fi
}
payload='{"mode":"connected","connected_enrichment":true,"graph_status":"offline","graph_reason":"unreachable"}'
for surface in activity-card dashboard-card; do
  assert_copy "$(render "$surface" "$payload")" 'hosted index: offline'
done
assert_copy "$(render handoff-card '{"topic":"Release","graphStatus":"ok","memoryStatus":"ok"}')" 'hosted index=ok'
assert_copy "$(render classify-graph '{"graph_status":"connected"}')" 'Optional hosted index connected'
assert_copy "$(render classify-graph '{"mode":"local"}')" 'Local mode uses memory files'
assert_copy "$(render activity-card '{"mode":"connected","connected_enrichment":true,"graph_status":"disabled","graph_reason":"graph_projection_disabled"}')" 'disabled by choice'
echo 'Runtime product copy: 6 rendered cases passed'
