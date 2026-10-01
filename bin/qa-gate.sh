#!/usr/bin/env bash
set -uo pipefail
# Repository selection belongs to this script, never to inherited Git overrides.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# The deterministic framework gate: every check CI runs on a source instance
# that can also run locally, in one command, so a change is proven before it
# is committed rather than after it is pushed. Each step runs to completion
# even when an earlier one fails; the summary names every failure and its log.
#
# Usage:
#   bash bin/qa-gate.sh                       # run every step
#   bash bin/qa-gate.sh --only syntax,audit   # a subset, in gate order
#   bash bin/qa-gate.sh --skip package-tests  # everything but these
#   bash bin/qa-gate.sh --scope --all         # arguments passed to test-changes.sh
#   bash bin/qa-gate.sh --list                # step names, one per line
#
# Exit 0 = every step passed or was skipped for a documented reason
# Exit 1 = at least one step failed
# Exit 2 = usage error (unknown step name or option)
#
# Steps whose inputs an installed instance does not ship (the distribution
# engine, the package tests, the migration registry) report `skipped` there
# and count as passed; the gate is the same command on every instance.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${QA_GATE_LOGS:-$ROOT/tmp/qa-gate}"

STEPS=(syntax oss-strings env-source json-literal local-mode static secret-hygiene audit validate codex-sync migration package-tests diff-check)

ONLY=""
SKIP=""
SCOPE=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list) printf '%s\n' "${STEPS[@]}"; exit 0 ;;
    --only) [ $# -ge 2 ] || { echo "qa-gate: --only needs a value" >&2; exit 2; }; ONLY="$2"; shift 2 ;;
    --skip) [ $# -ge 2 ] || { echo "qa-gate: --skip needs a value" >&2; exit 2; }; SKIP="$2"; shift 2 ;;
    --scope) shift; while [ $# -gt 0 ] && [ "${1#--only}" = "$1" ] && [ "${1#--skip}" = "$1" ]; do SCOPE+=("$1"); shift; done ;;
    -h|--help) sed -n '6,26p' "$0"; exit 0 ;;
    *) echo "qa-gate: unknown option: $1" >&2; exit 2 ;;
  esac
done

known_step() {
  local s
  for s in "${STEPS[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}
check_names() {
  local name
  [ -n "$1" ] || return 0
  IFS=',' read -r -a names <<< "$1"
  for name in "${names[@]}"; do
    known_step "$name" || { echo "qa-gate: unknown step: $name (see --list)" >&2; exit 2; }
  done
}
check_names "$ONLY"
check_names "$SKIP"

listed() {
  [ -n "$1" ] || return 1
  case ",$1," in *",$2,"*) return 0 ;; esac
  return 1
}
selected() {
  if [ -n "$ONLY" ]; then listed "$ONLY" "$1" || return 1; fi
  listed "$SKIP" "$1" && return 1
  return 0
}

# Shell scripts under bin/ that CI's OSS validation inspects: not test files.
bin_scripts() {
  find "$ROOT/bin" -name '*.sh' -type f ! -name 'test-*' ! -path "$ROOT/bin/tests/*" | sort
}

# Each step prints its diagnostics to stdout/stderr (captured to a log) and
# returns 0 = ok, 1 = failed, 3 = skipped with the reason on stdout.
step_syntax() {
  local f rc=0
  for f in "$ROOT"/bin/*.sh "$ROOT"/bin/lib/*.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>&1 || { echo "FAIL: ${f#"$ROOT"/}"; rc=1; }
  done
  return $rc
}

step_oss_strings() {
  # CI greps bin/ for the organization's GitHub name in its hyphenated and
  # flattened spellings. The gate derives the same patterns from egregore.json,
  # so no instance name is written into this file and the check is the same
  # on every instance.
  local cfg="$ROOT/egregore.json" org lower flat found
  [ -f "$cfg" ] || { echo "no egregore.json"; return 3; }
  command -v jq >/dev/null 2>&1 || { echo "jq not on PATH"; return 3; }
  org=$(jq -r '.github_org // empty' "$cfg" 2>/dev/null)
  [ -n "$org" ] && [ "$org" != "local" ] || { echo "no github_org to scan for"; return 3; }
  lower=$(printf '%s' "$org" | tr '[:upper:]' '[:lower:]')
  flat=$(printf '%s' "$lower" | tr -d '_-')
  found=$(bin_scripts | xargs grep -niF -e "$lower" -e "$flat" 2>/dev/null || true)
  [ -z "$found" ] || { echo "internal references in bin/ scripts:"; echo "$found"; return 1; }
  return 0
}

# The next two patterns are assembled from pieces so this script does not
# match the checks it replays.
step_env_source() {
  local pat found
  pat=$(printf '%s%s' 'source.*\.e' 'nv')
  found=$(bin_scripts | xargs grep -n "$pat" 2>/dev/null | grep -v '#' || true)
  [ -z "$found" ] || { echo "unsafe .env sourcing (read keys with grep | cut):"; echo "$found"; return 1; }
  return 0
}

step_json_literal() {
  local pat found
  pat=$(printf '%s%s' '"{' '\"')
  found=$(bin_scripts | xargs grep -nF "$pat" 2>/dev/null || true)
  [ -z "$found" ] || { echo "manual JSON construction (use jq -n):"; echo "$found"; return 1; }
  return 0
}

step_local_mode() {
  local s rc=0
  for s in graph.sh notify.sh graph-op.sh; do
    [ -f "$ROOT/bin/$s" ] || continue
    grep -q '"local"' "$ROOT/bin/$s" 2>/dev/null || { echo "FAIL: bin/$s missing local mode handling"; rc=1; }
  done
  return $rc
}

step_static() {
  [ -f "$ROOT/bin/test-changes.sh" ] || { echo "no bin/test-changes.sh"; return 3; }
  bash "$ROOT/bin/test-changes.sh" ${SCOPE[@]+"${SCOPE[@]}"} 2>&1
  local rc=$?
  [ $rc -eq 0 ] || return 1
  return 0
}

step_secret_hygiene() {
  [ -f "$ROOT/bin/tests/secret-hygiene.manifest" ] || { echo "no secret-hygiene manifest in this instance"; return 3; }
  bash "$ROOT/bin/tests/test-secret-hygiene.sh" 2>&1
}

have_engine() {
  [ -f "$ROOT/bin/capability-distribution.mjs" ] && [ -f "$ROOT/capability-distribution.json" ]
}

step_audit() {
  have_engine || { echo "no distribution engine in this instance"; return 3; }
  bash "$ROOT/bin/node-run.sh" "$ROOT/bin/capability-distribution.mjs" runtime-skill-audit --root "$ROOT" --strict-contract 2>&1
}

step_validate() {
  have_engine || { echo "no distribution engine in this instance"; return 3; }
  bash "$ROOT/bin/node-run.sh" "$ROOT/bin/capability-distribution.mjs" validate --root "$ROOT" 2>&1
}

step_codex_sync() {
  [ -f "$ROOT/bin/codex-sync-skills.sh" ] || { echo "no bin/codex-sync-skills.sh"; return 3; }
  bash "$ROOT/bin/codex-sync-skills.sh" --check 2>&1
}

step_migration() {
  [ -f "$ROOT/tests/test-runtime-skill-migration.sh" ] || { echo "no migration test in this instance"; return 3; }
  bash "$ROOT/tests/test-runtime-skill-migration.sh" 2>&1
}

step_package_tests() {
  local dir="$ROOT/packages/create-egregore/test"
  [ -d "$dir" ] || { echo "no package tests in this instance"; return 3; }
  # Some package tests read skill bodies through constants, so a path grep
  # cannot select them; the gate always runs the whole set.
  # PTY fixtures need predictable startup time even on a busy developer host.
  # Keep the same one-file concurrency as CI's narrower test:package corpus.
  (cd "$ROOT" && bash bin/node-run.sh --test --test-concurrency=1 packages/create-egregore/test/*.js 2>&1)
}

step_diff_check() {
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git checkout"; return 3; }
  git -C "$ROOT" diff --check 2>&1 && git -C "$ROOT" diff --cached --check 2>&1
}

mkdir -p "$LOG_DIR"
ok=0; failed=0; skipped=0
for step in "${STEPS[@]}"; do
  selected "$step" || continue
  fn="step_${step//-/_}"
  log="$LOG_DIR/$step.log"
  start=$(date +%s)
  "$fn" > "$log" 2>&1
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  case $rc in
    0) ok=$((ok + 1)); printf '✓ %s (%ss)\n' "$step" "$elapsed" ;;
    3) skipped=$((skipped + 1)); printf '– %s skipped: %s\n' "$step" "$(head -n 1 "$log")" ;;
    *) failed=$((failed + 1)); printf '✗ %s (%ss) → %s\n' "$step" "$elapsed" "${log#"$ROOT"/}"
       # The first lines of the log are the diagnosis; show them inline.
       head -n 12 "$log" | sed 's/^/    /' ;;
  esac
done

printf 'qa-gate: %s ok · %s failed · %s skipped\n' "$ok" "$failed" "$skipped"
[ "$failed" -eq 0 ] || exit 1
exit 0
