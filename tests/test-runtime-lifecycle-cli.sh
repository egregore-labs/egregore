#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d -t runtime-lifecycle-cli-XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/egregore_runtime"
cp "$ROOT/bin/handoff-lifecycle.sh" "$FIXTURE/bin/"
cp "$ROOT/bin/activity-action.sh" "$FIXTURE/bin/"
touch "$FIXTURE/egregore_runtime/__init__.py"

cat > "$FIXTURE/egregore_runtime/lifecycle_cli.py" <<'PY'
import json
import os
import sys

with open(os.environ["RUNTIME_LOG"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
print('{"applied":true,"status":"done","authority":"canonical_markdown"}')
PY
cat > "$FIXTURE/bin/graph-op.sh" <<'SH'
#!/usr/bin/env bash
echo invoked >> "$GRAPH_LOG"
exit 99
SH
cat > "$FIXTURE/bin/graph.sh" <<'SH'
#!/usr/bin/env bash
echo invoked >> "$GRAPH_LOG"
exit 99
SH
chmod +x "$FIXTURE/bin/"*.sh
export RUNTIME_LOG="$FIXTURE/runtime.log"
export GRAPH_LOG="$FIXTURE/graph.log"

(
  cd "$FIXTURE"
  bash bin/handoff-lifecycle.sh scan --managed-only >/dev/null
  bash bin/activity-action.sh "done" handoff-1 \
    --expected-revision sha256:visible >/dev/null
)

if [[ -e "$GRAPH_LOG" ]]; then
  echo "not ok - default lifecycle path invoked graph" >&2
  exit 1
fi

if ! sed -n '1p' "$RUNTIME_LOG" | grep -F >/dev/null '["scan", "--managed-only"]'; then
  echo "not ok - lifecycle scan did not use Runtime adapter" >&2
  exit 1
fi
if ! sed -n '2p' "$RUNTIME_LOG" | grep -F >/dev/null \
  '["action", "done", "handoff-1", "--reason", "explicit_user_action", "--expected-revision", "sha256:visible"]'; then
  echo "not ok - activity action did not preserve optimistic revision" >&2
  exit 1
fi

echo "ok 1 - default lifecycle and activity actions use Runtime, not graph"
