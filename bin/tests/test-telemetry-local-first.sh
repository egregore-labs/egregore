#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export EGREGORE_TELEMETRY_DIR="$TEST_TMP/device-state"
export EGREGORE_STATE_FILE="$TEST_TMP/project/.egregore-state.json"
export EGREGORE_CONFIG_FILE="$TEST_TMP/project/egregore.json"
export EGREGORE_ENV_FILE="$TEST_TMP/project/.env"
export EGREGORE_ACTOR_ID="actor_test"
export EGREGORE_ORG_ID="org_test"
export EGREGORE_SESSION_ID="session_test"
mkdir -p "$HOME" "$TEST_TMP/project" "$TEST_TMP/fakebin"
printf '{"telemetry":true}\n' > "$EGREGORE_STATE_FILE"
printf '{"org_id":"org_test"}\n' > "$EGREGORE_CONFIG_FILE"
printf 'EGREGORE_API_KEY=must-not-leak\n' > "$EGREGORE_ENV_FILE"

CALLS="$TEST_TMP/curl.calls"
SHARED="$TEST_TMP/shared.jsonl"
export CALLS SHARED
cat > "$TEST_TMP/fakebin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
for arg in "$@"; do
  case "$arg" in
    @*) cp "${arg#@}" "$SHARED" ;;
  esac
done
printf '204'
CURL
chmod +x "$TEST_TMP/fakebin/curl"
export PATH="$TEST_TMP/fakebin:$PATH"

TELEMETRY="$ROOT/bin/telemetry.sh"
BUFFER="$EGREGORE_TELEMETRY_DIR/telemetry.jsonl"
ENDPOINT="https://telemetry.example.test/v1/events"

echo "Testing: local-first telemetry CLI"

bash "$TELEMETRY" emit retrieval_completed \
  '{"retrieval_type":"lex+vec","latency_ms":304,"artifact_ids":["artifact_1"]}'
jq -e '
  .schema_version == "egregore.telemetry/v1" and
  .actor_id == "actor_test" and
  .metrics.retrieval_type == "lex+vec" and
  .artifact_ids == ["artifact_1"] and
  .shared == false
' "$BUFFER" >/dev/null

before_count=$(wc -l < "$BUFFER")
bash "$TELEMETRY" emit unsafe '{"prompt":"private roadmap"}' 2>/dev/null
bash "$TELEMETRY" emit unsafe '{"source":"memory/private/roadmap.md"}' 2>/dev/null
bash "$TELEMETRY" emit unsafe '{"lex_fingerprint":"secret123"}' 2>/dev/null
after_count=$(wc -l < "$BUFFER")
[ "$before_count" = "$after_count" ]

bash "$TELEMETRY" flush 2>/dev/null
[ ! -e "$CALLS" ]
status_output=$(bash "$TELEMETRY" status)
grep -q 'local only (never shared automatically)' <<< "$status_output"

EXPORT="$TEST_TMP/exported.jsonl"
bash "$TELEMETRY" export "$EXPORT" >/dev/null
cmp "$BUFFER" "$EXPORT"

proposal=$(bash "$TELEMETRY" share --endpoint "$ENDPOINT")
[ ! -e "$CALLS" ]
grep -q 'nothing sent' <<< "$proposal"
grep -q 'Dataset SHA-256:' <<< "$proposal"
token=$(printf '%s\n' "$proposal" | sed -n "s/.*--confirm '\([^']*\)'.*/\1/p")
[ -n "$token" ]
dir_mode=$(stat -c '%a' "$EGREGORE_TELEMETRY_DIR" 2>/dev/null || stat -f '%Lp' "$EGREGORE_TELEMETRY_DIR")
file_mode=$(stat -c '%a' "$BUFFER" 2>/dev/null || stat -f '%Lp' "$BUFFER")
[ "$dir_mode" = "700" ]
[ "$file_mode" = "600" ]

if bash "$TELEMETRY" share --confirm wrong-token 2>/dev/null; then
  echo "wrong confirmation token unexpectedly shared" >&2
  exit 1
fi
[ ! -e "$CALLS" ]

bash "$TELEMETRY" share --confirm "$token" >/dev/null
[ "$(wc -l < "$CALLS")" -eq 1 ]
! grep -q 'must-not-leak' "$CALLS"
jq -e '.data.shared == true and .data.artifact_ids == ["artifact_1"]' "$SHARED" >/dev/null
[ "$(wc -l < "$BUFFER")" -eq 1 ]

# Events emitted between proposal and confirm must not invalidate the share:
# the confirm sends exactly the staged snapshot the proposal disclosed.
proposal=$(bash "$TELEMETRY" share --endpoint "$ENDPOINT")
token=$(printf '%s\n' "$proposal" | sed -n "s/.*--confirm '\([^']*\)'.*/\1/p")
bash "$TELEMETRY" emit artifact_opened '{"artifact_ids":["artifact_1"],"opened_count":1}'
bash "$TELEMETRY" share --confirm "$token" >/dev/null
[ "$(wc -l < "$CALLS")" -eq 2 ]
[ "$(wc -l < "$SHARED")" -eq 1 ]
jq -e '.data.shared == true and (.data | has("opened_count") | not)' "$SHARED" >/dev/null
[ "$(wc -l < "$BUFFER")" -eq 2 ]

proposal_json=$(bash "$TELEMETRY" share --endpoint "$ENDPOINT" --json)
printf '%s' "$proposal_json" | jq -e '.proposal == true and .sent == false and .events == 2 and (.token | length > 0) and (.dataset_sha256 | length == 64)' >/dev/null
[ "$(wc -l < "$CALLS")" -eq 2 ]
token=$(printf '%s' "$proposal_json" | jq -r '.token')
bash "$TELEMETRY" share --confirm "$token" >/dev/null
[ "$(wc -l < "$CALLS")" -eq 3 ]

bash "$TELEMETRY" disable >/dev/null
count_disabled=$(wc -l < "$BUFFER")
bash "$TELEMETRY" emit command '{"command":"save"}'
[ "$(wc -l < "$BUFFER")" -eq "$count_disabled" ]
bash "$TELEMETRY" inspect 1 | grep >/dev/null 'artifact_opened'

printf '%s\n' "  ✓ local emit + v1 envelope"
printf '%s\n' "  ✓ content-bearing metrics rejected"
printf '%s\n' "  ✓ flush performs no network I/O"
printf '%s\n' "  ✓ export remains local"
printf '%s\n' "  ✓ share requires disclosed, dataset-bound confirmation"
printf '%s\n' "  ✓ staged snapshot survives events emitted between proposal and confirm"
printf '%s\n' "  ✓ machine-readable proposal completes the same consent protocol"
printf '%s\n' "  ✓ disabled collection preserves local inspection"
