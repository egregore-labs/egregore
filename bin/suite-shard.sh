#!/usr/bin/env bash
set -euo pipefail

# Print a deterministic slice of the repository's shell suite corpus.
# Usage: bash bin/suite-shard.sh [--exclude-owned] [--selected FILE] <index> <count>
# Exit 0 = slice printed (including an empty slice)
# Exit 2 = invalid arguments

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export LC_ALL=C

usage() {
  echo 'Usage: bash bin/suite-shard.sh [--exclude-owned] [--selected FILE] <index> <count>' >&2
  exit 2
}

exclude_owned=false
select_suites=false
selected_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --exclude-owned)
      if $exclude_owned; then usage; fi
      exclude_owned=true
      shift
      ;;
    --selected)
      if $select_suites || [ "$#" -lt 2 ]; then usage; fi
      case "$2" in --*) usage ;; esac
      select_suites=true
      selected_file=$2
      shift 2
      ;;
    --*) usage ;;
    *) break ;;
  esac
done
[ "$#" -eq 2 ] || usage
case "$1" in ''|*[!0-9]*) usage ;; esac
case "$2" in ''|*[!0-9]*) usage ;; esac
index=$1
count=$2
# Normalize decimal arguments without octal interpretation or integer overflow.
index=${index#"${index%%[!0]*}"}
count=${count#"${count%%[!0]*}"}
index=${index:-0}
count=${count:-0}
[ "$count" != 0 ] || usage
if [ "${#index}" -gt "${#count}" ] || {
  [ "${#index}" -eq "${#count}" ] && [[ "$index" > "$count" || "$index" == "$count" ]]
}; then
  usage
fi

excluded=""
if $exclude_owned; then
  # Opt-in CI ownership only. Local callers retain the complete corpus and do
  # not acquire a Python dependency. Reject stale ownership before any output.
  excluded=$(python3 - "$SCRIPT_DIR" <<'PY'
import json
import pathlib
import re
import shlex
import sys

root = pathlib.Path(sys.argv[1]).resolve()

def fail():
    print("suite-shard: invalid CI test ownership", file=sys.stderr)
    raise SystemExit(2)

def owns_suite(text, job, suite):
    # This is deliberately a narrow proof, not a general YAML/shell evaluator:
    # owners use scalar bash/npm run steps. Ambiguous syntax is not excluded.
    match = re.search(r"^  " + re.escape(job) + r":\s*$", text, re.M)
    if not match:
        return False
    block = text[match.end():]
    next_job = re.search(r"^  [A-Za-z0-9_-]+:\s*$", block, re.M)
    if next_job:
        block = block[:next_job.start()]
    if re.search(r"^\s*continue-on-error:", block, re.M):
        return False
    if re.search(r"^    if:\s*(?:false|\$\{\{\s*false\s*\}\})\s*$", block, re.M):
        return False
    steps = re.split(r"^      - ", block, flags=re.M)[1:]
    for raw_step in steps:
        step = "        " + raw_step
        condition = re.search(r"^        if:\s*(.*)$", step, re.M)
        # Plan failure is propagated by the owner's first strict step. Once a
        # plan succeeds, this condition preserves the non-cancelled suite run.
        strict_conditions = {
            "${{ !cancelled() }}",
            "${{ !cancelled() && needs.plan.result == 'success' }}",
        }
        if condition and condition.group(1).strip() not in strict_conditions:
            continue
        run = re.search(r"^(?:        )?run: ([^\n]+)$", step, re.M)
        if not run:
            continue
        command = shlex.split(run.group(1))
        directory = re.search(r"^        working-directory: ([^\n]+)$", step, re.M)
        cwd = root / (directory.group(1).strip() if directory else ".")
        if command == ["bash", suite] and cwd.resolve() == root:
            return True
        if len(command) == 3 and command[:2] == ["npm", "run"]:
            package_path = (cwd / "package.json").resolve()
            if not package_path.is_relative_to(root):
                continue
            package = json.loads(package_path.read_text())
            script = package.get("scripts", {}).get(command[2], "")
            # Only unconditional && chains prove ownership. Shell control
            # flow, substitutions and quoted echo text cannot establish it.
            tokens = list(shlex.shlex(script, posix=True, punctuation_chars=True))
            commands = [[]]
            for token in tokens:
                if token == "&&":
                    commands.append([])
                else:
                    commands[-1].append(token)
            unsafe = {";", "||", "|", "&", "(", ")", "{", "}"}
            if any(token in unsafe or "$" in token or chr(96) in token for token in tokens):
                continue
            if any(not args or args[0] not in {"node", "bash"} for args in commands):
                continue
            for args in commands:
                if len(args) == 2 and args[0] == "bash":
                    if (cwd / args[1]).resolve() == (root / suite).resolve():
                        return True
    return False

try:
    data = json.loads((root / "bin/ci-test-ownership.json").read_text())
    if set(data) != {"version", "excluded_from_baseline"} or type(data["version"]) is not int or data["version"] != 1:
        fail()
    entries = data["excluded_from_baseline"]
    if not isinstance(entries, list):
        fail()
    corpus = {str(p.relative_to(root)) for directory in ("tests", "bin/tests")
              for p in (root / directory).glob("*.sh") if p.is_file()}
    corpus.discard("tests/run-all.sh")
    excluded = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"suite", "workflow", "job"}:
            fail()
        suite, workflow, job = (entry[key] for key in ("suite", "workflow", "job"))
        if not all(isinstance(value, str) for value in (suite, workflow, job)):
            fail()
        if suite not in corpus or suite in excluded:
            fail()
        if not (root / suite).resolve().is_relative_to(root):
            fail()
        if not re.fullmatch(r"\.github/workflows/[A-Za-z0-9_-]+\.ya?ml", workflow):
            fail()
        if not re.fullmatch(r"[A-Za-z0-9_-]+", job):
            fail()
        if not (root / workflow).resolve().is_relative_to(root):
            fail()
        if not owns_suite((root / workflow).read_text(), job, suite):
            fail()
        excluded.add(suite)
    print("\n".join(sorted(excluded)))
except (OSError, ValueError, TypeError, KeyError):
    fail()
PY
  ) || exit 2
fi

selected_suites=""
if $select_suites; then
  # A planner selection is a strict subset, including the legitimate empty
  # subset. Malformed or stale input must never silently become a full run.
  selected_suites=$(python3 - "$SCRIPT_DIR" "$selected_file" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()

def fail():
    print("suite-shard: invalid selected suite inventory", file=sys.stderr)
    raise SystemExit(2)

try:
    selected = json.loads(pathlib.Path(sys.argv[2]).read_text())
    if not isinstance(selected, list) or any(not isinstance(item, str) for item in selected):
        fail()
    if len(selected) != len(set(selected)):
        fail()
    corpus = {str(p.relative_to(root)) for directory in ("tests", "bin/tests")
              for p in (root / directory).glob("*.sh") if p.is_file()}
    corpus.discard("tests/run-all.sh")
    if any(item not in corpus or "\n" in item or "\r" in item
           or not (root / item).resolve().is_relative_to(root) for item in selected):
        fail()
    print("\n".join(sorted(selected)))
except (OSError, ValueError, TypeError):
    fail()
PY
  ) || exit 2
fi

(
  cd "$SCRIPT_DIR"
  for suite in tests/*.sh bin/tests/*.sh; do
    [ -f "$suite" ] || continue
    [ "$suite" != tests/run-all.sh ] || continue
    if $select_suites && ! grep -Fxq -- "$suite" <<< "$selected_suites"; then continue; fi
    if $exclude_owned && grep -Fxq -- "$suite" <<< "$excluded"; then continue; fi
    printf '%s\n' "$suite"
  done
) | LC_ALL=C sort | {
  position=0
  while IFS= read -r suite; do
    if [ "$position" = "$index" ]; then printf '%s\n' "$suite"; fi
    position=$((position + 1))
    # Cycling gives position modulo count without converting a huge count.
    if [ "$position" = "$count" ]; then position=0; fi
  done
}
