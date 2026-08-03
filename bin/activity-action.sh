#!/usr/bin/env bash
set -euo pipefail

# Recipient-scoped lifecycle actions used by /activity.
# Usage: bash bin/activity-action.sh <read|done|expire|reopen> <session-id>
#        [--user HANDLE]

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:-}"
SID="${2:-}"
shift 2 2>/dev/null || true
USER_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_REF="${2:?missing user}"; shift 2 ;;
    *) jq -n --arg option "$1" '{error:"unknown option",option:$option}'; exit 2 ;;
  esac
done

case "$ACTION" in
  read|done|expire|reopen) ;;
  *) jq -n '{error:"action must be read, done, expire, or reopen"}'; exit 2 ;;
esac
[[ -n "$SID" ]] || { jq -n '{error:"missing session id"}'; exit 2; }

MODE="$(jq -r '.mode // "connected"' "$SCRIPT_DIR/egregore.json" 2>/dev/null || echo connected)"
if [[ "$MODE" == "local" ]]; then
  jq -n '{
    applied:false,
    availability:"unavailable_in_this_configuration",
    reason:"handoff lifecycle state is graph-backed"
  }'
  exit 0
fi

if [[ -z "$USER_REF" ]]; then
  USER_REF="$(jq -r '.github_username // empty' "$SCRIPT_DIR/.egregore-state.json" 2>/dev/null || true)"
fi
if [[ -z "$USER_REF" ]]; then
  USER_REF="$(git -C "$SCRIPT_DIR" config user.name 2>/dev/null || true)"
fi
[[ -n "$USER_REF" ]] || { jq -n '{error:"could not resolve current user"}'; exit 2; }

case "$ACTION" in
  read) OP="mark-read"; EXPECTED="read" ;;
  done) OP="mark-done"; EXPECTED="done" ;;
  expire) OP="mark-expired"; EXPECTED="expired" ;;
  reopen) OP="reopen-handoff"; EXPECTED="pending" ;;
esac

RESULT="$(bash "$SCRIPT_DIR/bin/graph-op.sh" "$OP" "$SID" "$USER_REF")"
if ! printf '%s\n' "$RESULT" | jq -e '.values[0][0] != null' >/dev/null 2>&1; then
  jq -n \
    --arg action "$ACTION" \
    --arg id "$SID" \
    --arg user "$USER_REF" \
    '{applied:false,action:$action,id:$id,user:$user,
      error:"handoff not found, not addressed to this user, or transition not allowed"}'
  exit 3
fi

printf '%s\n' "$RESULT" | jq \
  --arg action "$ACTION" \
  --arg expected "$EXPECTED" \
  --arg user "$USER_REF" '
    {
      applied:true,
      action:$action,
      id:.values[0][0],
      topic:(.values[0][1] // ""),
      status:(.values[0][2] // $expected),
      user:$user
    }
  '
