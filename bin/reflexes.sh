#!/usr/bin/env bash
# The reflexes: one runner, a directory of probes. See bin/reflexes/README.md.
# Prints the probes' lines for the startup card; never fails the card.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)" || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
exec python3 "$SCRIPT_DIR/bin/lib/reflexes.py" --root "$SCRIPT_DIR" "$@"
