#!/usr/bin/env bash
set -euo pipefail

# Stable shell adapter for canonical organizational writes. Harness skills call
# this boundary; QMD, Git, telemetry, graph, and filesystem mechanics remain
# behind the Egregore Runtime.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export EGREGORE_ROOT="$ROOT"
export PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
export EGREGORE_SESSION_ID="${EGREGORE_SESSION_ID:-$(cat "$ROOT/.egregore-session-id" 2>/dev/null || true)}"

case "${1:-}" in
  capture)
    shift
    no_push=0
    for argument in "$@"; do
      [ "$argument" = "--no-push" ] && no_push=1
    done
    python3 -m egregore_runtime.writeback_cli authorize write \
      --resource "canonical-capture" >/dev/null
    # The compatibility worker is composition-only on the Runtime path.
    # Runtime owns the sole canonical Git/index/embed/telemetry transaction;
    # publication and notification are separate explicit effects.
    status=0
    EGREGORE_GRAPH_PROJECTION=0 bash "$ROOT/bin/capture-run.sh" "$@" \
      --no-push --no-publish --no-notify --no-index || status=$?
    if [ "$status" = "0" ]; then
      result_file="${TMPDIR:-/tmp}/capture-run-result.json"
      artifact_path="$(jq -r '.absFile // empty' "$result_file" 2>/dev/null || true)"
      [ -n "$artifact_path" ] || {
        echo "writeback: capture did not return a canonical artifact path" >&2
        exit 1
      }
      adopt_args=(adopt "$artifact_path")
      [ "$no_push" = "1" ] && adopt_args+=(--no-push)
      receipt="$(EGREGORE_ASYNC_REMOTE_PUSH=1 \
        python3 -m egregore_runtime.writeback_cli "${adopt_args[@]}")" || exit $?
      if jq -e . >/dev/null 2>&1 <<<"$receipt"; then
        temporary="${result_file}.writeback.$$"
        jq --argjson writeback "$receipt" '. + {writeback:$writeback}' \
          "$result_file" > "$temporary" && mv "$temporary" "$result_file"
      fi
    fi
    exit "$status"
    ;;
  adopt|commit)
    for argument in "$@"; do
      case "$argument" in
        --) break ;;
        -h|--help) exec python3 -m egregore_runtime.writeback_cli "$@" ;;
      esac
    done
    # Validate the Runtime CLI grammar before identity resolution so malformed
    # invocations consistently report usage (2), including unconfigured roots.
    python3 -c 'import sys; from egregore_runtime.writeback_cli import _parser; _parser().parse_args(sys.argv[1:])' "$@"
    python3 -m egregore_runtime.writeback_cli authorize write \
      --resource "canonical-capture" >/dev/null
    # `adopt` renders one artifact the ritual already showed the user, so the
    # transport commits locally and queues remote delivery in the background.
    # `commit` versions shared ledgers and registries several sessions append
    # to, so its push is synchronous: a remote that moved first is rebased and
    # retried, and a delivery that still fails is named in the receipt instead
    # of disappearing into a detached process. `--no-push` overrides both.
    if [ "$1" = "commit" ]; then
      export EGREGORE_ASYNC_REMOTE_PUSH=0
    else
      export EGREGORE_ASYNC_REMOTE_PUSH=1
    fi
    exec python3 -m egregore_runtime.writeback_cli "$@"
    ;;
  authorize|create)
    exec python3 -m egregore_runtime.writeback_cli "$@"
    ;;
  *)
    echo 'usage: bin/artifact-writeback.sh {capture --mode ...|create --path PATH --input FILE|adopt MEMORY-RELATIVE-PATH [--replace] [--no-push]|commit --path MEMORY-RELATIVE-PATH [--path ...] --message TEXT [--no-push]|authorize PERMISSION}' >&2
    exit 2
    ;;
esac
