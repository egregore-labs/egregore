#!/usr/bin/env bash
# Personal controls and batch actions for session records.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
[ -n "${HOME:-}" ] || exit 0
# The organization's vitals read the records and the gate ledger only.
[ "${1:-}" = vitals ] && shift && exec python3 "$SCRIPT_DIR/bin/lib/session_record.py" vitals --root "$SCRIPT_DIR" "$@"
[ "${1:-}" = retrieval ] && shift && exec python3 "$SCRIPT_DIR/bin/lib/retrieval_scorecard.py" --root "$SCRIPT_DIR" "$@"
exec python3 "$SCRIPT_DIR/bin/lib/session_record.py" records --root "$SCRIPT_DIR" "$@"
