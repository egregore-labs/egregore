#!/usr/bin/env bash
# Show: this installation's memory lookups and the organization's session reach
# over seven days. Silent below two lookups or when organization records are off.
# One line, at most 160 characters; writes nothing. Contract: README.md.
set -uo pipefail
root="${EGREGORE_ROOT:-}"
[ -n "$root" ] && [ -f "$root/bin/lib/retrieval_scorecard.py" ] && command -v python3 >/dev/null 2>&1 || exit 0
exec python3 "$root/bin/lib/retrieval_scorecard.py" line --root "$root" --memory "${EGREGORE_MEMORY:-$root/memory}"
