#!/usr/bin/env bash
set -euo pipefail

# Exercise CI ownership validation without executing suites or contacting CI.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
passed = 0
failed = 0
invalid_ownership = "suite-shard: invalid CI test ownership"


def check(label, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  PASS: {label}")
    else:
        failed += 1
        print(f"  FAIL: {label}" + (f" ({detail})" if detail else ""))


def run(root, exclude=True):
    command = ["bash", str(root / "bin/suite-shard.sh")]
    if exclude:
        command.append("--exclude-owned")
    return subprocess.run(command + ["0", "1"], cwd=root, text=True, capture_output=True, timeout=15)


def corpus(root):
    return sorted(str(path.relative_to(root)) for pattern in ("tests/*.sh", "bin/tests/*.sh")
                  for path in root.glob(pattern) if path.is_file() and str(path.relative_to(root)) != "tests/run-all.sh")


mapping = {"suite": "tests/owned.sh", "workflow": ".github/workflows/strict.yml", "job": "strict"}
manifest = {"version": 1, "excluded_from_baseline": [mapping]}
default_workflow = """name: Strict tests
on: [push]
jobs:
  strict:
    runs-on: ubuntu-latest
    steps:
      - name: Execute suite
        run: bash tests/owned.sh
  other:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/other.sh
"""

print("=== CI test ownership tests ===")
with tempfile.TemporaryDirectory(prefix="test-ci-test-ownership.") as temporary:
    root = Path(temporary)
    for directory in ("bin/tests", "tests/nested", ".github/workflows", "packages/tool"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / "bin/suite-shard.sh", root / "bin/suite-shard.sh")
    for suite in ("tests/owned.sh", "tests/other.sh", "bin/tests/extra.sh", "tests/run-all.sh", "tests/nested/hidden.sh"):
        (root / suite).write_text("#!/bin/bash\nexit 97\n")
    (root / "tests/directory.sh").mkdir()
    manifest_path = root / "bin/ci-test-ownership.json"
    workflow_path = root / ".github/workflows/strict.yml"

    def reset(value=manifest, workflow=default_workflow):
        manifest_path.write_text(json.dumps(value))
        workflow_path.write_text(workflow)

    def rejected(label, value=manifest, workflow=default_workflow):
        reset(value, workflow)
        result = run(root)
        check(label, result.returncode == 2 and result.stdout == "" and result.stderr.strip() == invalid_ownership,
              f"exit={result.returncode}, stdout={result.stdout!r}" if result.returncode != 2 or result.stdout else "")

    reset()
    result = run(root)
    check("valid direct owner omits only its suite", result.returncode == 0 and result.stdout.splitlines() == [
        "bin/tests/extra.sh", "tests/other.sh"])
    result = run(root, exclude=False)
    check("default local corpus still includes owned suites", result.returncode == 0 and result.stdout.splitlines() == corpus(root))

    reset({"version": 1, "excluded_from_baseline": []})
    result = run(root)
    check("an empty valid manifest preserves the complete corpus", result.returncode == 0 and result.stdout.splitlines() == corpus(root))
    manifest_path.unlink()
    result = run(root)
    check("explicit exclusions require an ownership manifest", result.returncode == 2 and result.stdout == ""
          and result.stderr.strip() == invalid_ownership)
    manifest_path.write_text("{broken json")
    result = run(root)
    check("malformed JSON fails without publishing a partial corpus", result.returncode == 2 and result.stdout == ""
          and result.stderr.strip() == invalid_ownership)

    for label, value in [
        ("non-object manifest", []),
        ("missing version", {"excluded_from_baseline": []}),
        ("unknown version", {"version": 2, "excluded_from_baseline": []}),
        ("boolean version", {"version": True, "excluded_from_baseline": []}),
        ("string version", {"version": "1", "excluded_from_baseline": []}),
        ("missing exclusions", {"version": 1}),
        ("non-list exclusions", {"version": 1, "excluded_from_baseline": {}}),
        ("null entry", {"version": 1, "excluded_from_baseline": [None]}),
        ("non-object entry", {"version": 1, "excluded_from_baseline": ["tests/owned.sh"]}),
    ]:
        rejected(label, value)
    for field in ("suite", "workflow", "job"):
        value = copy.deepcopy(manifest)
        del value["excluded_from_baseline"][0][field]
        rejected(f"missing {field} field", value)
        for invalid in (None, 42, ""):
            value = copy.deepcopy(manifest)
            value["excluded_from_baseline"][0][field] = invalid
            rejected(f"invalid {field} value {invalid!r}", value)
    value = copy.deepcopy(manifest)
    value["excluded_from_baseline"][0]["reason"] = "not in the schema"
    rejected("unknown entry fields are rejected", value)

    for other in (mapping, {**mapping, "job": "other"}):
        rejected("duplicate suite mappings are rejected regardless of owner", {
            "version": 1, "excluded_from_baseline": [mapping, other]})
    for suite in ("tests/missing.sh", "tests/run-all.sh", "tests/nested/hidden.sh", "tests/directory.sh",
                  "../tests/owned.sh", str(root / "tests/owned.sh")):
        rejected(f"suite must exist in the baseline corpus: {suite}", {
            "version": 1, "excluded_from_baseline": [{**mapping, "suite": suite}]})
    for workflow in (".github/workflows/missing.yml", "../strict.yml", str(workflow_path)):
        rejected(f"workflow must be a repository workflow: {workflow}", {
            "version": 1, "excluded_from_baseline": [{**mapping, "workflow": workflow}]})
    rejected("owning job must exist", {"version": 1, "excluded_from_baseline": [{**mapping, "job": "missing"}]})
    rejected("a valid earlier entry cannot emit output before a later invalid entry", {
        "version": 1, "excluded_from_baseline": [mapping, {**mapping, "suite": "tests/missing.sh"}]})

    for label, replacement in [
        ("comment mention does not execute a suite", "# run: bash tests/owned.sh"),
        ("echo mention does not execute a suite", 'run: echo "bash tests/owned.sh"'),
        ("a command prefix is not the exact suite", "run: bash tests/owned.sh.extra"),
        ("step name is not execution", "name: bash tests/owned.sh"),
        ("multiline text cannot establish ownership", "run: |\n          bash tests/owned.sh"),
        ("heredoc body cannot establish ownership", "run: |\n          cat <<'TEXT'\n          bash tests/owned.sh\n          TEXT"),
        ("a skipped step cannot own a suite", "if: false\n        run: bash tests/owned.sh"),
    ]:
        rejected(label, workflow=default_workflow.replace("run: bash tests/owned.sh", replacement))
    rejected("execution in a different job does not establish ownership", workflow=default_workflow.replace(
        "run: bash tests/owned.sh", "run: echo setup").replace("run: bash tests/other.sh", "run: bash tests/owned.sh"))
    rejected("a skipped owning job cannot establish coverage", workflow=default_workflow.replace(
        "  strict:\n", "  strict:\n    if: false\n"))
    rejected("a skipped step remains skipped when if is its first field", workflow=default_workflow.replace(
        "      - name: Execute suite\n", "      - if: false\n"))
    rejected("job-level continue-on-error cannot own a required suite", workflow=default_workflow.replace(
        "  strict:\n", "  strict:\n    continue-on-error: true\n"))
    rejected("step-level continue-on-error cannot own a required suite", workflow=default_workflow.replace(
        "        run: bash tests/owned.sh", "        continue-on-error: true\n        run: bash tests/owned.sh"))

    reset(workflow=default_workflow.replace("        run: bash tests/owned.sh",
        "        if: ${{ !cancelled() }}\n        run: bash tests/owned.sh"))
    result = run(root)
    check("non-cancelled strict owner steps remain valid", result.returncode == 0 and "tests/owned.sh" not in result.stdout.splitlines())

    reset(workflow=default_workflow.replace("        run: bash tests/owned.sh",
        "        if: ${{ !cancelled() && needs.plan.result == 'success' }}\n        run: bash tests/owned.sh"))
    result = run(root)
    check("successful-plan strict owner steps remain valid", result.returncode == 0 and "tests/owned.sh" not in result.stdout.splitlines())
    rejected("a failure-only plan condition cannot own normal suite coverage", workflow=default_workflow.replace(
        "        run: bash tests/owned.sh",
        "        if: ${{ !cancelled() && needs.plan.result == 'failure' }}\n        run: bash tests/owned.sh"))
    rejected("an extra output condition cannot narrow strict ownership", workflow=default_workflow.replace(
        "        run: bash tests/owned.sh",
        "        if: ${{ !cancelled() && needs.plan.result == 'success' && needs.plan.outputs.optional == 'true' }}\n        run: bash tests/owned.sh"))

    indirect = default_workflow.replace("        run: bash tests/owned.sh",
        "        working-directory: packages/tool\n        run: npm run test:runtime")
    package = root / "packages/tool/package.json"
    package.write_text(json.dumps({"scripts": {"test:runtime": "bash ../../tests/owned.sh && node test.js"}}))
    reset(workflow=indirect)
    result = run(root)
    check("literal npm script resolves bash suite relative to its working directory",
          result.returncode == 0 and result.stdout.splitlines() == ["bin/tests/extra.sh", "tests/other.sh"])
    package.write_text(json.dumps({"scripts": {"test:runtime": 'echo "bash ../../tests/owned.sh" && node test.js'}}))
    rejected("echo inside npm scripts does not prove shell suite coverage", workflow=indirect)
    package.write_text(json.dumps({"scripts": {"test:runtime": "exit 0 && bash ../../tests/owned.sh"}}))
    rejected("early successful exit cannot claim a later npm suite", workflow=indirect)

# The real manifest remains data-driven: do not pin a growing list in this test.
real_manifest = json.loads((source / "bin/ci-test-ownership.json").read_text())
owned = {entry["suite"] for entry in real_manifest["excluded_from_baseline"]}
result = run(source)
check("repository ownership manifest validates against its actual jobs", result.returncode == 0, result.stderr.strip())
check("repository exclusions are exactly the manifest set",
      result.returncode == 0 and result.stdout.splitlines() == sorted(set(corpus(source)) - owned))
result = run(source, exclude=False)
check("repository default retains every shell suite", result.returncode == 0 and result.stdout.splitlines() == corpus(source))

# Convenience groups must stay outside discovery; their leaves keep strict
# owners. Run the real group against cheap sentinel leaves to verify relocation
# and failure propagation without executing the expensive suites again.
loom_leaves = ["bin/tests/" + name for name in (
    "test-loom.sh", "test-loom-truth.sh", "test-loom-evals.sh",
    "test-loom-learner.sh", "test-loom-replay.sh", "test-loom-scenarios.sh",
    "test-loom-dashboard.sh",
)]
group = "bin/test-groups/loom-matrix.sh"
check("Loom convenience group is outside shell-suite discovery",
      (source / group).is_file() and group not in corpus(source)
      and not (source / "bin/tests/test-loom-matrix.sh").exists())
workflow = (source / ".github/workflows/ci.yml").read_text()
check("each Loom leaf has one strict owner and one direct CI invocation",
      all([entry for entry in real_manifest["excluded_from_baseline"] if entry["suite"] == suite]
          == [{"suite": suite, "workflow": ".github/workflows/ci.yml", "job": "shell-contracts"}]
          and len(re.findall(r"^\s*run: bash " + re.escape(suite) + r"$", workflow, re.M)) == 1
          for suite in loom_leaves))
with tempfile.TemporaryDirectory(prefix="test-loom-group.") as temporary:
    root = Path(temporary)
    (root / "bin/test-groups").mkdir(parents=True)
    (root / "bin/tests").mkdir()
    shutil.copyfile(source / group, root / group)
    for suite in loom_leaves:
        (root / suite).write_text(f"printf '%s\\n' 'LEAF:{suite}'\n")
    result = subprocess.run(["bash", str(root / group)], cwd=root / "bin",
                            text=True, capture_output=True, timeout=10)
    check("relocated Loom group invokes every leaf once from another directory",
          result.returncode == 0 and [line for line in result.stdout.splitlines() if line.startswith("LEAF:")]
          == ["LEAF:" + suite for suite in loom_leaves])
    (root / loom_leaves[1]).write_text("exit 37\n")
    result = subprocess.run(["bash", str(root / group)], cwd=root / "bin",
                            text=True, capture_output=True, timeout=10)
    check("relocated Loom group fails on the first failing leaf",
          result.returncode == 37 and [line for line in result.stdout.splitlines() if line.startswith("LEAF:")]
          == ["LEAF:" + loom_leaves[0]])

result = run(source)
check("baseline retains canonical release and unique queue suites once",
      result.returncode == 0 and result.stdout.splitlines().count("bin/tests/test-release-candidate.sh") == 1
      and result.stdout.splitlines().count("tests/test-release-queue.sh") == 1
      and not (source / "tests/test-release-candidate.sh").exists())
with tempfile.TemporaryDirectory(prefix="test-release-queue-owner.") as temporary:
    root = Path(temporary)
    for directory in ("tests", "bin/tests", "mock-bin"):
        (root / directory).mkdir(parents=True)
    shutil.copyfile(source / "tests/test-release-queue.sh", root / "tests/test-release-queue.sh")
    (root / "bin/tests/test-release-candidate.sh").write_text("exit 97\n")
    node = root / "mock-bin/node"
    node.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    node.chmod(0o755)
    result = subprocess.run(["bash", str(root / "tests/test-release-queue.sh")], cwd=root,
                            env={**os.environ, "PATH": str(node.parent) + os.pathsep + os.environ["PATH"]},
                            text=True, capture_output=True, timeout=10)
    check("release queue invokes its unique Node suite without repeating the canonical shell suite",
          result.returncode == 0 and result.stdout.splitlines()
          == ["--test", str(root / "bin/tests/release-queue.test.mjs")])
print(f"Results: {passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
PY
