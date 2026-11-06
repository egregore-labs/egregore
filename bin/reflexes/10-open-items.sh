#!/usr/bin/env bash
# Open items carried from the session records: how many, and the oldest. An
# ownerless item past three days adds the count and the oldest's age; past
# seven days the line ends with the command that drafts an issue for it.
# Reads the records of the last fourteen days and the open-items ledger;
# writes nothing. Contract: bin/reflexes/README.md.
set -uo pipefail
root="${EGREGORE_ROOT:-}"
[ -n "$root" ] && [ -f "$root/bin/lib/session_record.py" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
exec python3 "$root/bin/lib/session_record.py" open-items-line --root "$root" \
  --memory "${EGREGORE_MEMORY:-$root/memory}"
