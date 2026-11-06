#!/usr/bin/env bash
# Reflex (show): a session inside a sandbox says what runs degraded and
# what will not work.
#
# Positive markers only, the predicate bin/lib/secret_entry.py and
# egregore_runtime/sandbox.py use: CODEX_SANDBOX set to anything but empty,
# none, false or 0, or APP_SANDBOX_CONTAINER_ID set. No marker, no line, on
# every harness; a missing DISPLAY or a failing write never names a sandbox.
# With a marker, one file is created and removed where the runtime keeps its
# per-user state (search and telemetry, resolved as egregore_runtime does).
# The line follows the result: writable state, and search and browser checks
# will not work; refused state, and search runs degraded on the workspace
# copy, with a second line saying that state is read-only here.
set -u

marker="$(printf '%s' "${CODEX_SANDBOX:-}" | tr '[:upper:]' '[:lower:]')"
case "$marker" in
  ""|none|false|0) [ -n "${APP_SANDBOX_CONTAINER_ID:-}" ] || exit 0 ;;
esac

# Create and remove one file in the nearest existing ancestor of a directory;
# fails when that location refuses the write or keeps the file. A probe file
# that outlives its test is removed again on the way out, and that retry
# never fails the probe, even under an inherited errexit.
probe_file=""
trap 'if [ -n "$probe_file" ]; then rm -f "$probe_file" 2>/dev/null || true; fi' EXIT
writable() {
  local dir="$1" parent
  case "$dir" in \~/*) dir="${HOME:-}/${dir#\~/}" ;; esac
  # A relative override is relative to the current directory, as the runtime
  # resolves it; the walk must reach that directory, never stop short of it.
  case "$dir" in /*) ;; *) dir="$PWD/$dir" ;; esac
  while [ ! -e "$dir" ]; do
    parent="${dir%/*}"
    [ -n "$parent" ] || parent=/
    [ "$parent" != "$dir" ] || break
    dir="$parent"
  done
  [ -d "$dir" ] || return 0
  probe_file="$(mktemp "$dir/.egregore-write-probe.XXXXXX" 2>/dev/null)" || { probe_file=""; return 1; }
  rm -f "$probe_file" 2>/dev/null || return 1
  probe_file=""
}

# Both stores key their per-user directory by the resolved memory checkout
# (QmdLocalRetriever._instance_hash, LocalTelemetrySink's namespace).
root="${EGREGORE_ROOT:-.}"
memory="$(cd "$root/memory" 2>/dev/null && pwd -P)" \
  || memory="$(cd "$root" 2>/dev/null && pwd -P)/memory"
digest=""
if command -v shasum >/dev/null 2>&1; then
  digest="$(printf '%s' "$memory" | LC_ALL=C shasum -a 256 2>/dev/null)"
elif command -v sha256sum >/dev/null 2>&1; then
  digest="$(printf '%s' "$memory" | sha256sum 2>/dev/null)"
fi
digest="${digest%% *}"

search_state="${EGREGORE_QMD_RUNTIME_DIR:-}"
telemetry_state="${EGREGORE_TELEMETRY_DIR:-}"
if [ -n "${HOME:-}" ]; then
  [ -n "$search_state" ] || search_state="$HOME/.egregore/runtime/qmd${digest:+/${digest:0:16}}"
  [ -n "$telemetry_state" ] || telemetry_state="$HOME/.egregore/telemetry${digest:+/${digest:0:20}}"
fi

refused=""
for state in "$search_state" "$telemetry_state"; do
  [ -n "$state" ] || continue
  if ! writable "$state"; then
    refused=1
    break
  fi
done

# shellcheck disable=SC2016  # the backticks are part of each line
if [ -n "$refused" ]; then
  # The runtime falls back to the workspace copy: lexical search, telemetry
  # kept there. The read-only fact gets its own line, because this one uses
  # 157 of the runner's 160 characters.
  printf '%s\n' 'this session runs in a sandbox: search runs degraded, telemetry stays in the workspace and browser checks will not work · start through `egregore` to lift it'
  printf '%s\n' 'per-user state is read-only here'
else
  # Per-user state stays in use, but the sandbox refuses the loopback port
  # of the query worker, so search fails instead of degrading.
  printf '%s\n' 'this session runs in a sandbox: search and browser checks will not work · start through `egregore` to lift it'
fi
