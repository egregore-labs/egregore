#!/usr/bin/env bash
set -euo pipefail

# Shared capture engine for the three ways an Egregore session leaves a trace.
#
#   addressed  /handoff: rich team handoff (delegates to the addressed worker)
#   personal   /wrap:    explicit personal close
#   baseline   SessionEnd: automatic, loss-prevention trace
#
# Lifecycle reconciliation is never performed on the caller's critical path.
# Connected-mode captures append idempotent graph statements to graph-wal.sh
# and optionally start capture-reconcile.sh as a detached worker.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"
CAPTURE_SCHEMA="egregore-capture/v1"

queue_handoff_completion() {
  local session_id="$1"
  [ -n "$session_id" ] || return 0
  # shellcheck disable=SC2016 # $name tokens are Cypher parameters.
  local cypher='
    MATCH (impl:Session {id: $sessionId})-[:IMPLEMENTS]->(ho:Session)
    MATCH (impl)-[:BY]->(recipient:Person)
    MATCH (ho)-[:HANDED_TO]->(recipient)
    WHERE coalesce(ho.handoffStatus, "pending") IN ["pending","read","claimed"]
      AND coalesce(ho.handoffLifecycleVersion, 0) >= 1
    WITH DISTINCT ho, size([(ho)-[:HANDED_TO]->(:Person) | 1]) AS recipientCount
    WHERE recipientCount = 1
    SET ho.handoffStatus = "done",
        ho.handoffDoneAt = coalesce(ho.handoffDoneAt, datetime()),
        ho.handoffUpdatedAt = datetime(),
        ho.handoffLifecycleReason = "single_recipient_implemented",
        ho.handoffLifecycleVersion = 1
    RETURN ho.id AS id'
  local params
  params="$(jq -nc --arg sessionId "$session_id" '{sessionId:$sessionId}')"
  GRAPH_WAL_LOCK_ATTEMPTS=1 \
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$cypher" "$params" >/dev/null 2>&1 || true
}

start_reconcile() {
  local session_id="$1"
  local author="$2"
  local summary="$3"
  [ -n "$session_id" ] || return 0
  (
    bash "$SCRIPT_DIR/bin/capture-reconcile.sh" \
      --session-id "$session_id" \
      --author "$author" \
      --summary "$summary" >/dev/null 2>&1 &
  ) >/dev/null 2>&1
}

usage() {
  cat <<'EOF'
Usage:
  capture-run.sh --mode addressed [handoff-run options] < handoff.md
  capture-run.sh --mode personal|baseline --author HANDLE --topic TOPIC
    --summary SUMMARY [--session-id ID] [--branch BRANCH] [--date ISO]
    [--duration TEXT] [--open-threads-json JSON] [--no-push]
    [--async-push] [--no-reconcile] < details.md
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

CAPTURE_MODE=""
if [ "${1:-}" = "--mode" ]; then
  CAPTURE_MODE="${2:-}"
  shift 2
fi
[ -n "$CAPTURE_MODE" ] || {
  echo "Missing --mode (addressed|personal|baseline)" >&2
  exit 1
}

case "$CAPTURE_MODE" in
  addressed)
    # Keep the mature publishing/notification worker intact behind the shared
    # entry point. It continues writing its compatibility result file.
    ADDRESSED_AUTHOR=""
    ADDRESSED_TOPIC=""
    PREV=""
    for VALUE in "$@"; do
      if [ "$PREV" = "--author" ]; then ADDRESSED_AUTHOR="$VALUE"; fi
      if [ "$PREV" = "--topic" ]; then ADDRESSED_TOPIC="$VALUE"; fi
      PREV="$VALUE"
    done

    if bash "$SCRIPT_DIR/bin/handoff-run.sh" "$@"; then
      status=0
    else
      status=$?
    fi
    old_result="${TMPDIR:-/tmp}/handoff-run-result.json"
    capture_result="${TMPDIR:-/tmp}/capture-run-result.json"
    if [ -s "$old_result" ]; then
      jq --arg schema "$CAPTURE_SCHEMA" --arg captureMode "$CAPTURE_MODE" \
        '. + {captureSchema:$schema,captureMode:$captureMode}' \
        "$old_result" > "$capture_result" 2>/dev/null || cp "$old_result" "$capture_result"
    fi

    # Addressed capture is also explicit session-close evidence. Queue the
    # same guarded transition as /wrap after the addressed worker has marked
    # the current Session handed_off.
    ADDRESSED_CONFIG_MODE="$(jq -r '.mode // "connected"' "$CONFIG" 2>/dev/null || echo connected)"
    if [ "$status" = "0" ] && [ "$ADDRESSED_CONFIG_MODE" = "connected" ]; then
      CURRENT_SID="$(cat "$SCRIPT_DIR/.egregore-session-id" 2>/dev/null || true)"
      if [ -z "$CURRENT_SID" ]; then
        PROJ_HASH="$(printf '%s' "$SCRIPT_DIR" | md5 2>/dev/null || printf '%s' "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1)"
        CURRENT_SID="$(cat "$HOME/.egregore/session-${PROJ_HASH}.id" 2>/dev/null || true)"
      fi
      queue_handoff_completion "$CURRENT_SID"
      start_reconcile "$CURRENT_SID" "$ADDRESSED_AUTHOR" "$ADDRESSED_TOPIC"
    fi
    exit "$status"
    ;;
  personal|baseline) ;;
  *)
    echo "Invalid --mode: $CAPTURE_MODE (addressed|personal|baseline)" >&2
    exit 1
    ;;
esac

AUTHOR=""
DISPLAY_NAME=""
TOPIC=""
SUMMARY=""
SESSION_ID=""
BRANCH=""
CAPTURE_DATE=""
DURATION=""
OPEN_THREADS_JSON="[]"
NO_PUSH=0
ASYNC_PUSH=0
NO_RECONCILE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --author) AUTHOR="${2:-}"; shift 2 ;;
    --display-name) DISPLAY_NAME="${2:-}"; shift 2 ;;
    --topic) TOPIC="${2:-}"; shift 2 ;;
    --summary) SUMMARY="${2:-}"; shift 2 ;;
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --date) CAPTURE_DATE="${2:-}"; shift 2 ;;
    --duration) DURATION="${2:-}"; shift 2 ;;
    --open-threads-json) OPEN_THREADS_JSON="${2:-[]}"; shift 2 ;;
    --no-push) NO_PUSH=1; shift ;;
    --async-push) ASYNC_PUSH=1; shift ;;
    --no-reconcile) NO_RECONCILE=1; shift ;;
    *) echo "Unknown capture option: $1" >&2; exit 1 ;;
  esac
done

AUTHOR="$(printf '%s' "$AUTHOR" | tr -cd 'a-zA-Z0-9_-')"
[ -n "$AUTHOR" ] || { echo "Missing --author" >&2; exit 1; }
[ -n "$TOPIC" ] || { echo "Missing --topic" >&2; exit 1; }
[ -n "$SUMMARY" ] || SUMMARY="$TOPIC"
if ! printf '%s' "$OPEN_THREADS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "Invalid --open-threads-json: expected an array" >&2
  exit 1
fi

DETAILS="$(cat /dev/stdin 2>/dev/null || true)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[ -n "$CAPTURE_DATE" ] || CAPTURE_DATE="$NOW"
DATE_ONLY="$(printf '%s' "$CAPTURE_DATE" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
[ -n "$DATE_ONLY" ] || DATE_ONLY="$(date +%Y-%m-%d)"
YYYY_MM="${DATE_ONLY%??}"
YYYY_MM="${YYYY_MM%-}"
DD="${DATE_ONLY##*-}"
[ -n "$BRANCH" ] || BRANCH="$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || true)"
[ -n "$BRANCH" ] || BRANCH="develop"

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
    | cut -c1-50
}

SLUG="$(slugify "$TOPIC")"
[ -n "$SLUG" ] || SLUG="session"
AUTHOR_LC="$(printf '%s' "$AUTHOR" | tr '[:upper:]' '[:lower:]')"

if [ "$CAPTURE_MODE" = "personal" ]; then
  REL_FILE="wraps/${YYYY_MM}/${DD}-${AUTHOR_LC}-${SLUG}.md"
  TITLE_PREFIX="Wrap"
else
  REL_FILE="sessions/${YYYY_MM}/${DD}-${AUTHOR_LC}-${SLUG}.md"
  TITLE_PREFIX="Session"
fi
ABS_FILE="$SCRIPT_DIR/memory/$REL_FILE"
mkdir -p "$(dirname "$ABS_FILE")"

# Never overwrite an existing capture. Session IDs make concurrent same-topic
# sessions deterministic while retaining the human-readable prefix.
if [ -e "$ABS_FILE" ]; then
  suffix="$(printf '%s' "${SESSION_ID:-$NOW}" | tr -cd 'a-zA-Z0-9' | tail -c 7)"
  [ -n "$suffix" ] || suffix="2"
  ABS_FILE="${ABS_FILE%.md}-${suffix}.md"
  REL_FILE="${REL_FILE%.md}-${suffix}.md"
fi

{
  printf '# %s: %s\n\n' "$TITLE_PREFIX" "$TOPIC"
  printf '**Capture Schema**: %s\n' "$CAPTURE_SCHEMA"
  printf '**Capture Mode**: %s\n' "$CAPTURE_MODE"
  printf '**Date**: %s\n' "$CAPTURE_DATE"
  printf '**Author**: %s\n' "${DISPLAY_NAME:-$AUTHOR}"
  printf '**To**: %s\n' "$AUTHOR"
  printf '**Branch**: %s\n' "$BRANCH"
  [ -n "$SESSION_ID" ] && printf '**Session**: %s\n' "$SESSION_ID"
  [ -n "$DURATION" ] && printf '**Duration**: %s\n' "$DURATION"
  printf '\n## Summary\n\n%s\n' "$SUMMARY"
  if [ -n "$DETAILS" ]; then
    if [ "$CAPTURE_MODE" = "personal" ]; then
      printf '\n## Notes\n\n%s\n' "$DETAILS"
    else
      printf '\n%s\n' "$DETAILS"
    fi
  fi
} > "$ABS_FILE"

memory_save() {
  local message="$1"
  (
    cd "$SCRIPT_DIR/memory" 2>/dev/null || exit 0
    git add "$REL_FILE" >/dev/null 2>&1 || exit 0
    git commit --only --quiet -m "$message" -- "$REL_FILE" >/dev/null 2>&1 || true
    if git remote get-url origin >/dev/null 2>&1; then
      local _
      for _ in 1 2 3; do
        git pull --rebase origin main --quiet >/dev/null 2>&1 || true
        git push origin main --quiet >/dev/null 2>&1 && exit 0
        sleep 1
      done
      exit 1
    fi
  )
}

MEMORY_STATUS="skipped"
if [ "$NO_PUSH" = "0" ]; then
  if [ "$ASYNC_PUSH" = "1" ]; then
    ( memory_save "Capture: ${AUTHOR} — ${TOPIC}" >/dev/null 2>&1 & ) >/dev/null 2>&1
    MEMORY_STATUS="queued"
  elif memory_save "Capture: ${AUTHOR} — ${TOPIC}"; then
    MEMORY_STATUS="ok"
  else
    MEMORY_STATUS="failed"
  fi
fi

GRAPH_STATUS="skipped"
MODE="$(jq -r '.mode // "connected"' "$CONFIG" 2>/dev/null || echo connected)"
if [ "$MODE" = "connected" ] && [ -n "$SESSION_ID" ]; then
  # shellcheck disable=SC2016 # $name tokens are Cypher parameters.
  CAPTURE_CYPHER='
    MERGE (s:Session {id: $sessionId})
    ON CREATE SET s.date = date($date), s.startedAt = datetime($capturedAt)
    SET s.topic = $topic,
        s.summary = $summary,
        s.filePath = $filePath,
        s.branch = $branch,
        s.captureSchema = $captureSchema,
        s.captureMode = $captureMode,
        s.captureUpdatedAt = datetime()
    FOREACH (_ IN CASE WHEN $captureMode = "personal" THEN [1] ELSE [] END |
      SET s.status = "wrapped",
          s.wrappedAt = coalesce(s.wrappedAt, datetime()),
          s.openThreads = $openThreads)
    FOREACH (_ IN CASE WHEN $captureMode = "baseline" THEN [1] ELSE [] END |
      SET s.status = CASE
            WHEN s.status IN ["wrapped","handed_off","completed"] THEN s.status
            ELSE "captured"
          END,
          s.endedAt = coalesce(s.endedAt, datetime()))
    WITH s
    OPTIONAL MATCH (p:Person)
    WHERE toLower(p.name) = toLower($author)
       OR toLower(coalesce(p.github, "")) = toLower($author)
    FOREACH (_ IN CASE WHEN p IS NOT NULL THEN [1] ELSE [] END |
      MERGE (s)-[:BY]->(p))
    RETURN s.id AS id'
  CAPTURE_PARAMS="$(jq -nc \
    --arg sessionId "$SESSION_ID" \
    --arg date "$DATE_ONLY" \
    --arg capturedAt "$NOW" \
    --arg topic "$TOPIC" \
    --arg summary "$SUMMARY" \
    --arg filePath "$REL_FILE" \
    --arg branch "$BRANCH" \
    --arg captureSchema "$CAPTURE_SCHEMA" \
    --arg captureMode "$CAPTURE_MODE" \
    --arg author "$AUTHOR_LC" \
    --argjson openThreads "$OPEN_THREADS_JSON" \
    '{sessionId:$sessionId,date:$date,capturedAt:$capturedAt,topic:$topic,
      summary:$summary,filePath:$filePath,branch:$branch,
      captureSchema:$captureSchema,captureMode:$captureMode,author:$author,
      openThreads:$openThreads}')"
  GRAPH_WAL_LOCK_ATTEMPTS=1 \
    bash "$SCRIPT_DIR/bin/graph-wal.sh" append "$CAPTURE_CYPHER" "$CAPTURE_PARAMS" >/dev/null 2>&1 || true
  GRAPH_STATUS="queued"

  # An explicit wrap is strong completion evidence. Queue the transition after
  # the Session update; do not query the graph or wait for reconciliation here.
  if [ "$CAPTURE_MODE" = "personal" ]; then
    queue_handoff_completion "$SESSION_ID"
  fi

  if [ "$NO_RECONCILE" = "0" ] && [ "$CAPTURE_MODE" = "personal" ]; then
    start_reconcile "$SESSION_ID" "$AUTHOR_LC" "$SUMMARY"
  fi
fi

RESULT_FILE="${TMPDIR:-/tmp}/capture-run-result.json"
jq -nc \
  --arg schema "$CAPTURE_SCHEMA" \
  --arg captureMode "$CAPTURE_MODE" \
  --arg file "$REL_FILE" \
  --arg absFile "$ABS_FILE" \
  --arg sessionId "$SESSION_ID" \
  --arg memoryStatus "$MEMORY_STATUS" \
  --arg graphStatus "$GRAPH_STATUS" \
  '{
    captureSchema:$schema,
    captureMode:$captureMode,
    file:$file,
    absFile:$absFile,
    sessionId:$sessionId,
    memoryStatus:$memoryStatus,
    graphStatus:$graphStatus
  }' > "$RESULT_FILE"

printf 'capture: memory/%s\n' "$REL_FILE"
