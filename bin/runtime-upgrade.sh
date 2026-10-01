#!/usr/bin/env bash
# runtime-upgrade.sh — deterministic bridge for the per-instance Runtime
# upgrade. The launcher's Settings surface and advanced callers drive the
# transactional engine through these verbs; the Python Runtime owns all
# state, staging, gates, activation, and rollback. Output is JSON for
# renderers — this script is an internal surface, not the user experience.
#
# Verbs:
#   status [--fetch]        durable upgrade + team-sync state
#   capabilities           side-effect-free engine protocol advertisement
#   init --candidate <ver>  stage stable X.Y.Z or X.Y.Z-runtime-mvp.N (>=0.21.0)
#   prepare                 start/resume the detached preparation worker
#   activate                atomic activation; refuses unless every gate passed
#   cancel                  request cancellation; previous Runtime untouched
#   rollback                restore the recorded previous Runtime version
#   team-sync [--fetch]     canonical memory sync state only
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# EGREGORE_INSTANCE_ROOT lets the packaged launcher bridge drive an instance
# that predates this script: engine code always comes from this script's own
# tree, while the target instance is set explicitly — never inferred.
INSTANCE_ROOT="${EGREGORE_INSTANCE_ROOT:-$SCRIPT_DIR}"

# Activation and rollback can replace this script. Hand off the process so
# Bash never resumes reading changed bytes after the Runtime returns.
_runtime() {
  EGREGORE_ROOT="$INSTANCE_ROOT" \
    PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    exec python3 -m egregore_runtime.harness_cli "$@"
}

_ensure_identity() {
  # Pre-Runtime instances can predate stable organization identity. Resolve it
  # through the existing verified Local/Connected migration before computing
  # the instance-scoped upgrade key; never infer identity from path or slug.
  if jq -e '
    .org_id | type == "string" and length > 0 and (startswith("legacy-org:") | not)
  ' "$INSTANCE_ROOT/egregore.json" >/dev/null 2>&1; then
    return 0
  fi
  EGREGORE_INSTANCE_ROOT="$INSTANCE_ROOT" \
    PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    bash "$SCRIPT_DIR/bin/runtime-identity.sh" ensure
}

_run_upgrade() {
  _ensure_identity || {
    echo "Runtime update could not resolve this Egregore's stable identity." >&2
    return 1
  }
  _runtime upgrade "$@"
}

case "${1:-}" in
  capabilities) printf '%s\n' '{"upgrade_protocol":1,"stable_candidates":true}' ;;
  status)   shift; _run_upgrade status "$@" ;;
  init)     shift; _run_upgrade init "$@" ;;
  prepare)  shift; _run_upgrade prepare "$@" ;;
  activate) shift; _run_upgrade activate "$@" ;;
  cancel)   shift; _run_upgrade cancel "$@" ;;
  rollback) shift; _run_upgrade rollback "$@" ;;
  team-sync) shift; _runtime team-sync "$@" ;;
  *)
    echo "usage: bash bin/runtime-upgrade.sh {status|init --candidate <version>|prepare|activate|cancel|rollback|team-sync}" >&2
    exit 2
    ;;
esac
