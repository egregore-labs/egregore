#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/bin" "$FIXTURE_DIR/fake-bin" \
  "$FIXTURE_DIR/memory/handoffs/2026-08"
cp "$ROOT_DIR/bin/artifact-writeback.sh" "$FIXTURE_DIR/bin/artifact-writeback.sh"

cat > "$FIXTURE_DIR/bin/capture-run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${CAPTURE_ARGS:?}"
cat > "${FIXTURE_ROOT:?}/memory/handoffs/2026-08/27-fixture.md"
jq -nc --arg absFile "${FIXTURE_ROOT}/memory/handoffs/2026-08/27-fixture.md" \
  '{absFile:$absFile,memoryStatus:"skipped",publishStatus:"disabled",notifyStatus:"skipped"}' \
  > "${TMPDIR:?}/capture-run-result.json"
SH
chmod +x "$FIXTURE_DIR/bin/capture-run.sh"

cat > "$FIXTURE_DIR/fake-bin/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "$*" "${EGREGORE_ASYNC_REMOTE_PUSH:-}" >> "${PYTHON_CALLS:?}"
case "$*" in
  *' authorize write '*) printf '%s\n' '{"allowed":true}' ;;
  *' adopt '*) printf '%s\n' '{"status":"accepted","event_id":"writeback-one"}' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FIXTURE_DIR/fake-bin/python3"

export FIXTURE_ROOT="$FIXTURE_DIR"
export CAPTURE_ARGS="$FIXTURE_DIR/capture.args"
export PYTHON_CALLS="$FIXTURE_DIR/python.calls"
export TMPDIR="$FIXTURE_DIR/tmp"
mkdir -p "$TMPDIR"

printf '%s\n' '# Handoff: fixture' | PATH="$FIXTURE_DIR/fake-bin:$PATH" \
  bash "$FIXTURE_DIR/bin/artifact-writeback.sh" capture \
    --mode addressed --author fixture --topic fixture >/dev/null

for flag in --no-push --no-publish --no-notify --no-index; do
  grep -Fxq -- "$flag" "$CAPTURE_ARGS"
done
[ "$(grep -c 'writeback_cli authorize write' "$PYTHON_CALLS")" -eq 1 ]
[ "$(grep -c 'writeback_cli adopt' "$PYTHON_CALLS")" -eq 1 ]
grep -q 'writeback_cli adopt .*|1$' "$PYTHON_CALLS"
jq -e '.writeback.status == "accepted"' "$TMPDIR/capture-run-result.json" >/dev/null

echo "PASS: Runtime capture owns one canonical writeback transaction"
