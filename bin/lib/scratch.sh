#!/usr/bin/env bash
# Shell readers hand their supplied input to the one Python containment policy.
# The checkout is the shim's checkout, never an inherited EGREGORE_ROOT.
scratch_consume() {
  local scratch_path="${1:-}" scratch_root scratch_message scratch_display
  scratch_display="${scratch_path//$'\n'/\\n}"
  scratch_display="${scratch_display//$'\r'/\\r}"
  if [ -n "$scratch_path" ]; then
    case "$scratch_path" in
      /*) ;;
      *) scratch_path="$PWD/$scratch_path" ;;
    esac
  fi
  if ! scratch_root="$( { cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd; } 2>/dev/null)"; then
    printf 'scratch: could not remove %s\n' "$scratch_display" >&2
    return 0
  fi
  if scratch_message="$(PYTHONSAFEPATH=1 PYTHONPATH="$scratch_root${PYTHONPATH:+:$PYTHONPATH}" \
      python3 -m egregore_runtime.scratch consume "$scratch_path" --root "$scratch_root" 2>&1)"; then
    # The consumer emits at most one diagnostic; stdout stays empty.
    [ -z "$scratch_message" ] || printf '%s\n' "${scratch_message%%$'\n'*}" >&2
  else
    printf 'scratch: could not remove %s\n' "$scratch_display" >&2
  fi
  return 0
}
