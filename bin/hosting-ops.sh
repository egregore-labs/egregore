#!/usr/bin/env bash
# Retained as an inert compatibility entry point for older installations.
set -euo pipefail
set +vx

printf '%s\n' 'Hosted Coder workspaces have been retired. Use Egregore from your local workspace.' >&2
case "${1-}" in
  --help|-h) exit 0 ;;
esac
exit 1
