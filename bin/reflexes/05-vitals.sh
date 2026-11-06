#!/usr/bin/env bash
# The organization's pulse: sessions by harness, cost, friction and the merge
# gate's decisions over the last seven days beside the seven before, from the
# session records and memory/sessions/gate.jsonl. Silent under two sessions.
# Writes nothing. Contract: bin/reflexes/README.md.
set -uo pipefail
root="${EGREGORE_ROOT:-}"
[ -n "$root" ] && [ -f "$root/bin/lib/session_record.py" ] && command -v python3 >/dev/null 2>&1 || exit 0
exec python3 "$root/bin/lib/session_record.py" vitals-line --root "$root" --memory "${EGREGORE_MEMORY:-$root/memory}"
