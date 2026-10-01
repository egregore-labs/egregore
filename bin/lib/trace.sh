#!/usr/bin/env bash
# trace.sh — opt-in monotonic startup phase tracing.
#
# Enabled only when EGREGORE_STARTUP_TRACE=1. Traces are written to a local
# runtime path outside the repository ($HOME/.egregore/runtime/startup-traces)
# and never touch normal startup output. Timestamps are monotonic
# milliseconds (Time::HiRes via the system perl — macOS date lacks %N), so
# phases are comparable within one trace; wall-clock is recorded once in the
# header for correlation.
#
# Usage (sourced):
#   source bin/lib/trace.sh
#   egregore_trace_begin "session-start"
#   egregore_trace_mark "identity"
#   ...
#   egregore_trace_mark "greeting-rendered"
#   egregore_trace_end
#
# Each mark logs: <total-ms-since-begin> <delta-ms-since-previous> <label>

_EGREGORE_TRACE_FILE=""
_EGREGORE_TRACE_T0=0
_EGREGORE_TRACE_LAST=0

_egregore_now_ms() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
    'printf("%d\n", clock_gettime(CLOCK_MONOTONIC()) * 1000)' 2>/dev/null || echo 0
}

egregore_trace_begin() {
  [ "${EGREGORE_STARTUP_TRACE:-0}" = "1" ] || return 0
  local name dir
  name=$(printf '%s' "${1:-trace}" | tr -cd 'A-Za-z0-9_.-')
  dir="$HOME/.egregore/runtime/startup-traces"
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 700 "$dir" 2>/dev/null || true
  _EGREGORE_TRACE_FILE="$dir/$(date +%Y%m%dT%H%M%S)-${name}-$$.trace"
  _EGREGORE_TRACE_T0=$(_egregore_now_ms)
  _EGREGORE_TRACE_LAST=$_EGREGORE_TRACE_T0
  {
    printf '# egregore startup trace: %s\n' "$name"
    printf '# wall: %s · pid: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$"
    printf '# columns: total_ms delta_ms phase\n'
  } >> "$_EGREGORE_TRACE_FILE" 2>/dev/null || _EGREGORE_TRACE_FILE=""
}

egregore_trace_mark() {
  [ -n "$_EGREGORE_TRACE_FILE" ] || return 0
  local now total delta
  now=$(_egregore_now_ms)
  total=$((now - _EGREGORE_TRACE_T0))
  delta=$((now - _EGREGORE_TRACE_LAST))
  _EGREGORE_TRACE_LAST=$now
  printf '%8d %8d  %s\n' "$total" "$delta" "${1:-mark}" >> "$_EGREGORE_TRACE_FILE" 2>/dev/null || true
}

egregore_trace_end() {
  [ -n "$_EGREGORE_TRACE_FILE" ] || return 0
  egregore_trace_mark "end"
  _EGREGORE_TRACE_FILE=""
}
