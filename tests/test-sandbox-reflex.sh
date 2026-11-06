#!/usr/bin/env bash
# The sandbox reflex: a sandbox marker prints a line naming what will not
# work and the remedy, and the line follows the write probe. With writable
# per-user state, search and browser checks will not work; with refused
# state, search runs degraded on the workspace copy, and a second line says
# the state is read-only. No marker prints nothing, on every harness. Every
# state directory here is temporary; the real per-user state is never used.
# Usage: bash tests/test-sandbox-reflex.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$REPO_ROOT/bin/reflexes/20-sandbox.sh"
RUNNER="$REPO_ROOT/bin/lib/reflexes.py"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
skip() { echo "  - $1 skipped: the current user bypasses directory permissions"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-sandbox-reflex.XXXXXX")" || exit 1
cleanup() {
  chflags -R nouappnd "$WORK" 2>/dev/null
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
# The physical path, spelled the way Python resolves it.
WORK="$(cd "$WORK" && pwd -P)" || exit 1
HOME_DIR="$WORK/home"
ROOT="$WORK/root"
SEARCH="$WORK/search"
TELEMETRY="$WORK/telemetry"
mkdir -p "$HOME_DIR" "$ROOT/memory" "$SEARCH" "$TELEMETRY"

# Writable per-user state: no fallback, and the sandbox refuses the query
# worker's loopback port.
# shellcheck disable=SC2016  # the backticks are part of the line
LINE='this session runs in a sandbox: search and browser checks will not work · start through `egregore` to lift it'
# Refused per-user state: the workspace copy, and the fact on its own line.
# shellcheck disable=SC2016  # the backticks are part of the line
DEGRADED_LINE='this session runs in a sandbox: search runs degraded, telemetry stays in the workspace and browser checks will not work · start through `egregore` to lift it'
STATE_LINE='per-user state is read-only here'
READ_ONLY="$DEGRADED_LINE"$'\n'"$STATE_LINE"

# The caller's markers and state directories never reach the probe; each
# case passes its own as NAME=value arguments.
clean_env() {
  env -u CODEX_SANDBOX -u APP_SANDBOX_CONTAINER_ID -u EGREGORE_QMD_RUNTIME_DIR \
    -u EGREGORE_TELEMETRY_DIR -u EGREGORE_HARNESS \
    HOME="$HOME_DIR" EGREGORE_ROOT="$ROOT" EGREGORE_MEMORY="$ROOT/memory" "$@"
}

# expect LABEL EXPECTED [NAME=value ...]: the probe exits 0 and prints EXPECTED.
# It runs from PROBE_CWD when that is set, from here otherwise.
PROBE_CWD=""
expect() {
  local label="$1" expected="$2" out status
  shift 2
  out="$(cd "${PROBE_CWD:-$PWD}" && clean_env "$@" bash "$PROBE" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ] && [ "$out" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (exit $status, got: ${out:-<nothing>})"
  fi
}

OVERRIDES=("EGREGORE_QMD_RUNTIME_DIR=$SEARCH" "EGREGORE_TELEMETRY_DIR=$TELEMETRY")

echo "=== sandbox reflex ==="
for harness in claude codex pi prime; do
  expect "no marker prints nothing ($harness)" "" "EGREGORE_HARNESS=$harness" "${OVERRIDES[@]}"
done
for value in "" none None false FALSE 0; do
  expect "CODEX_SANDBOX='$value' is not a marker" "" "CODEX_SANDBOX=$value" "${OVERRIDES[@]}"
done
expect "an empty APP_SANDBOX_CONTAINER_ID is not a marker" "" "APP_SANDBOX_CONTAINER_ID=" "${OVERRIDES[@]}"
# The launcher starts Codex with --sandbox danger-full-access, which sets no marker.
expect "a launcher-started Codex session prints nothing" "" "EGREGORE_HARNESS=codex" "${OVERRIDES[@]}"

expect "CODEX_SANDBOX=workspace-write with writable state: search will not work" "$LINE" \
  "CODEX_SANDBOX=workspace-write" "EGREGORE_HARNESS=codex" "${OVERRIDES[@]}"
expect "CODEX_SANDBOX=seatbelt prints the line" "$LINE" "CODEX_SANDBOX=seatbelt" "${OVERRIDES[@]}"
expect "APP_SANDBOX_CONTAINER_ID prints the line" "$LINE" \
  "APP_SANDBOX_CONTAINER_ID=com.example.app" "${OVERRIDES[@]}"
expect "the markers decide, not the harness (claude)" "$LINE" \
  "CODEX_SANDBOX=workspace-write" "EGREGORE_HARNESS=claude" "${OVERRIDES[@]}"

# Read-only state directories named by the runtime's override variables.
chmod 555 "$SEARCH"
if [ ! -w "$SEARCH" ]; then
  expect "a read-only search state directory: search runs degraded, and the read-only line" "$READ_ONLY" \
    "CODEX_SANDBOX=workspace-write" "${OVERRIDES[@]}"
  expect "the read-only line under the claude harness too" "$READ_ONLY" \
    "CODEX_SANDBOX=workspace-write" "EGREGORE_HARNESS=claude" "${OVERRIDES[@]}"
  expect "a read-only directory without a marker still prints nothing" "" "${OVERRIDES[@]}"
else
  skip "read-only search state"
fi
chmod 755 "$SEARCH"
chmod 555 "$TELEMETRY"
if [ ! -w "$TELEMETRY" ]; then
  expect "a read-only telemetry state directory adds the read-only line" "$READ_ONLY" \
    "CODEX_SANDBOX=workspace-write" "${OVERRIDES[@]}"
else
  skip "read-only telemetry state"
fi
chmod 755 "$TELEMETRY"

# Default per-user locations, keyed like the runtime by the resolved memory
# checkout: only the exact leaf refuses, so a probe of a parent would miss it.
DIGEST="$(python3 -c 'import hashlib, os, sys; print(hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).hexdigest())' "$ROOT/memory")"
SEARCH_STATE="$HOME_DIR/.egregore/runtime/qmd/${DIGEST:0:16}"
TELEMETRY_STATE="$HOME_DIR/.egregore/telemetry/${DIGEST:0:20}"
# The same two directories, as the runtime itself resolves them.
RESOLVED="$(clean_env PYTHONPATH="$REPO_ROOT" python3 - "$ROOT" <<'PY' 2>&1
import os
import sys
from pathlib import Path
from egregore_runtime.adapters.qmd import QmdLocalRetriever
from egregore_runtime.telemetry import LocalTelemetrySink
root = Path(sys.argv[1])
memory = (root / "memory").resolve()
environment = {"HOME": os.environ["HOME"], "PATH": os.environ.get("PATH", "")}
print(QmdLocalRetriever(repository_root=root, memory_root=memory, environment=environment)._runtime_root())
print(LocalTelemetrySink(state_file=root / ".egregore-state.json", instance_root=memory).storage_dir)
PY
)"
if [ "$RESOLVED" = "$SEARCH_STATE"$'\n'"$TELEMETRY_STATE" ]; then
  pass "the probe's directories are the runtime's own"
else
  fail "runtime resolved: $RESOLVED"
fi
mkdir -p "$SEARCH_STATE" "$TELEMETRY_STATE"
expect "writable per-user state prints the line alone" "$LINE" "CODEX_SANDBOX=workspace-write"
for state in "$SEARCH_STATE" "$TELEMETRY_STATE"; do
  chmod 555 "$state"
  if [ ! -w "$state" ]; then
    expect "the probe tests the runtime's own directory (${state#"$HOME_DIR"/})" "$READ_ONLY" \
      "CODEX_SANDBOX=workspace-write"
  else
    skip "read-only ${state#"$HOME_DIR"/}"
  fi
  chmod 755 "$state"
done

# A fresh machine: no per-user state yet, so the probe tests the home itself.
rm -rf "$HOME_DIR/.egregore"
expect "absent per-user state in a writable home prints the line alone" "$LINE" "CODEX_SANDBOX=workspace-write"
chmod 555 "$HOME_DIR"
if [ ! -w "$HOME_DIR" ]; then
  expect "a home that refuses per-user state adds the read-only line" "$READ_ONLY" "CODEX_SANDBOX=workspace-write"
else
  skip "read-only home"
fi
chmod 755 "$HOME_DIR"
if [ ! -e "$HOME_DIR/.egregore" ]; then pass "the probe creates no directory"; else fail "the probe created $HOME_DIR/.egregore"; fi
RESIDUE="$(find "$WORK" -name '.egregore-write-probe*' 2>/dev/null)"
if [ -z "$RESIDUE" ]; then pass "the write probe leaves nothing behind"; else fail "probe residue: $RESIDUE"; fi

# A folder that takes a file but refuses to remove it (macOS append-only, a
# real create-allowed, delete-denied policy): the file it keeps fails the probe.
mkdir -p "$SEARCH_STATE"
if [ "$(uname -s)" = Darwin ] && chflags uappnd "$SEARCH_STATE" 2>/dev/null; then
  expect "a probe file the folder keeps fails the probe" "$READ_ONLY" "CODEX_SANDBOX=workspace-write"
  chflags nouappnd "$SEARCH_STATE"
  find "$SEARCH_STATE" -name '.egregore-write-probe*' -delete
else
  echo "  - delete-denied folder skipped: needs macOS chflags"
fi

# Audit round 2, finding 2: under an inherited errexit (exported SHELLOPTS),
# the exit trap's retry of a removal that keeps failing must not fail the
# probe, or the runner drops both lines. An rm that always fails stands in
# for the refusal, on every platform.
SHIM="$WORK/rm-refuses"
mkdir -p "$SHIM"
printf '#!/bin/sh\nexit 1\n' > "$SHIM/rm"
chmod +x "$SHIM/rm"
expect "under errexit, a removal the trap retries in vain still prints both lines" "$READ_ONLY" \
  "SHELLOPTS=errexit" "PATH=$SHIM:$PATH" "CODEX_SANDBOX=workspace-write" "${OVERRIDES[@]}"
find "$SEARCH" "$TELEMETRY" -name '.egregore-write-probe*' -delete

# Audit round 2, finding 3: a relative override is relative to the current
# directory, so the walk reaches that directory and tests it.
RELATIVE=("EGREGORE_QMD_RUNTIME_DIR=missing/qmd" "EGREGORE_TELEMETRY_DIR=missing/telemetry")
LOCKED="$WORK/locked-cwd"
mkdir -p "$LOCKED"
PROBE_CWD="$LOCKED"
expect "relative overrides from a writable current directory print the line alone" "$LINE" \
  "CODEX_SANDBOX=workspace-write" "${RELATIVE[@]}"
chmod 555 "$LOCKED"
if [ ! -w "$LOCKED" ]; then
  expect "relative overrides from an unwritable current directory: degraded, read-only" "$READ_ONLY" \
    "CODEX_SANDBOX=workspace-write" "${RELATIVE[@]}"
else
  skip "unwritable current directory"
fi
chmod 755 "$LOCKED"
PROBE_CWD=""

# Through the runner: the probe alone in a directory, within its budget, and
# each line intact under the sigil (the runner cuts a line past 160
# characters, so an exact match proves neither line was cut).
PROBES="$WORK/probes"
mkdir -p "$PROBES"
cp "$PROBE" "$PROBES/"
run() { clean_env "$@" python3 "$RUNNER" --root "$ROOT" --dir "$PROBES" --memory "$ROOT/memory" 2>&1; }
OUT="$(run "CODEX_SANDBOX=workspace-write" "${OVERRIDES[@]}")"
if [ "$OUT" = "  ◦ $LINE" ]; then pass "the runner prints the line under the sigil, uncut"; else fail "runner printed: ${OUT:-<nothing>}"; fi
chmod 555 "$SEARCH"
if [ ! -w "$SEARCH" ]; then
  OUT="$(run "CODEX_SANDBOX=workspace-write" "${OVERRIDES[@]}")"
  if [ "$OUT" = "  ◦ $DEGRADED_LINE"$'\n'"  ◦ $STATE_LINE" ]; then
    pass "the runner prints both read-only lines under the sigil, uncut"
  else
    fail "runner printed: ${OUT:-<nothing>}"
  fi
else
  skip "read-only lines through the runner"
fi
chmod 755 "$SEARCH"
OUT="$(run "${OVERRIDES[@]}")"
if [ -z "$OUT" ]; then pass "the runner prints nothing without a marker"; else fail "runner printed without a marker: $OUT"; fi

echo "sandbox reflex: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
