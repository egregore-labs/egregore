#!/usr/bin/env bash
# Sweep this checkout's tmp through the shared Python containment policy.
# Codex has no session-end event; shell runtimes sweep on wrap and prune on
# session start. Two live sessions on one checkout share tmp/: the end sweep
# of one can remove a fresh helper response of the other. Scratch is
# regenerable and model-written bodies are consumed by helpers immediately;
# the exposure is a helper output between its write and the model's read.
# The 60-minute start prune reduces this exposure but does not eliminate it.
SCRATCH_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || exit 0
# This adapter accepts only the documented sweep options. Its checkout root
# cannot be overridden by a caller's environment or an extra CLI argument.
scratch_args=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --older-than)
      [ "$#" -ge 2 ] || { printf 'Usage: scratch-sweep.sh [--older-than MINUTES] [--dry-run]\n' >&2; exit 2; }
      shift 2 ;;
    --dry-run) shift ;;
    *) printf 'Usage: scratch-sweep.sh [--older-than MINUTES] [--dry-run]\n' >&2; exit 2 ;;
  esac
done
PYTHONSAFEPATH=1 PYTHONPATH="$SCRATCH_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m egregore_runtime.scratch sweep --root "$SCRATCH_ROOT" "${scratch_args[@]}"
scratch_status=$?
case "$scratch_status" in
  0) exit 0 ;;
  2) exit 2 ;;
  *) printf 'scratch-sweep: removed 0 entries\n' >&2; exit 0 ;;
esac
