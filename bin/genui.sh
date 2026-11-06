#!/usr/bin/env bash
# Stable harness adapter for generated-interface taste: record what people
# like or dislike in an interface an agent made, and read it back as words.
# Identity, authorization, the event files and Git stay behind the Runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export EGREGORE_ROOT="${EGREGORE_ROOT:-$ROOT}"
export EGREGORE_SESSION_ID="${EGREGORE_SESSION_ID:-$(bash "$ROOT/bin/session-id.sh" --root "$ROOT" 2>/dev/null || cat "$ROOT/.egregore-session-id" 2>/dev/null || true)}"
# A reaction is one line the person just said: commit it locally and deliver
# it to the remote in the background so the conversation never waits on push.
export EGREGORE_ASYNC_REMOTE_PUSH="${EGREGORE_ASYNC_REMOTE_PUSH:-1}"
export PYTHONSAFEPATH=1 PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"

# Runtime code reaches an existing workspace through the launcher's Runtime
# update, never through /update, which carries bin/ but not the Runtime. The
# entry sits outside the Runtime package so a missing or older Runtime gets one
# line naming that update, not a Python traceback.
exec python3 "$ROOT/bin/lib/genui-entry.py" "$@"
