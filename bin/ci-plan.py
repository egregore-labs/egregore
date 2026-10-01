#!/usr/bin/env python3
"""Conservative CI routing; exact-tree reuse is optional and fails open to tests.

Unknown inputs select every group. This inventory assigns jobs, not a heuristic
dependency search. A successful plan is only evidence after its owning workflow
and every named required job have actually succeeded.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SHA = re.compile(r"^[0-9a-f]{40}$")
OWNER_GROUPS = {"shell-contracts": "shell_contracts", "runtime-parity": "runtime",
                "postgres-proofs": "api_postgres", "artifacts-tests": "artifacts"}


def git(root: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                            text=True, check=True, timeout=30)
    return result.stdout.strip()


def load_policy(root: Path) -> dict:
    policy = json.loads((root / ".github/ci-policy.json").read_text())
    if policy.get("version") != 1 or not policy.get("workflows"):
        raise ValueError("unsupported CI policy")
    groups = {g for w in policy["workflows"].values() for g in w["jobs"]}
    for rule in policy["rules"]:
        if not set(rule["groups"]) <= groups:
            raise ValueError("routing rule names an unknown group")
    if not set(policy["baseline_owners"]) <= groups:
        raise ValueError("baseline owner names an unknown group")
    for workflow in policy["workflows"].values():
        if "push_groups" in workflow:
            push_groups = workflow["push_groups"]
            if (not isinstance(push_groups, list)
                    or any(not isinstance(group, str) for group in push_groups)
                    or not set(push_groups) <= set(workflow["jobs"])):
                raise ValueError("push_groups must name groups owned by that workflow")
    return policy


def matches(path: str, pattern: str) -> bool:
    # fnmatch's **/ requires a slash: explicitly include files at the root of a
    # recursive directory, rather than silently missing docs/plans/example.md.
    return fnmatch.fnmatchcase(path, pattern) or (
        "**/" in pattern and fnmatch.fnmatchcase(path, pattern.replace("**/", "")))


def select_groups(paths: list[str] | None, policy: dict) -> tuple[list[str], str]:
    all_groups = {g for w in policy["workflows"].values() for g in w["jobs"]}
    if not paths:
        return sorted(all_groups), "No trustworthy changed-file inventory; full coverage"
    selected: set[str] = set()
    reasons: set[str] = set()
    for path in paths:
        if (not isinstance(path, str) or not path or "\n" in path or "\r" in path
                or PurePosixPath(path).is_absolute() or ".." in PurePosixPath(path).parts):
            return sorted(all_groups), "Unrecognized changed path; full coverage"
        rule = next((r for r in policy["rules"] if any(matches(path, p) for p in r["patterns"])), None)
        if rule is None:
            return sorted(all_groups), "Shared or unmapped input; full coverage"
        selected.update(rule["groups"])
        reasons.add(rule["name"])
    if "baseline" in selected:
        selected.update(policy["baseline_owners"])
    return sorted(selected), "; ".join(sorted(reasons))


def changed_paths(root: Path, event_name: str, event: dict) -> list[str] | None:
    if event_name == "pull_request":
        base = event.get("pull_request", {}).get("base", {}).get("sha", "")
    elif event_name == "push":
        base = event.get("before", "")
    elif event_name == "merge_group":
        base = event.get("merge_group", {}).get("base_sha", "")
    else:
        return None
    if not SHA.fullmatch(base) or base == "0" * 40:
        return None
    try:
        result = subprocess.run(["git", "-C", str(root), "diff", "--name-only", "--no-renames",
                                 "-z", base, "HEAD", "--"], capture_output=True, check=True, timeout=30)
        return [p.decode("utf-8", errors="strict") for p in result.stdout.split(b"\0") if p]
    except (subprocess.SubprocessError, UnicodeError):
        return None


def environment() -> dict:
    versions = {}
    for name, command in (("node", ["node", "--version"]), ("npm", ["npm", "--version"])):
        try:
            versions[name] = subprocess.check_output(command, text=True, stderr=subprocess.STDOUT, timeout=10).strip()
        except (OSError, subprocess.SubprocessError):
            versions[name] = "unavailable"
    return {"image_os": os.environ.get("ImageOS", ""), "image_version": os.environ.get("ImageVersion", ""),
            "runner_os": os.environ.get("RUNNER_OS", ""), "runner_arch": os.environ.get("RUNNER_ARCH", ""),
            "timezone": os.environ.get("TZ", ""), "locale": os.environ.get("LC_ALL", ""),
            "node_env": os.environ.get("NODE_ENV", ""), "node_options": os.environ.get("NODE_OPTIONS", ""),
            **versions}


def full_required(event_name: str, event: dict, mode: str) -> bool:
    """Release and scheduled checks cannot be downgraded by a caller input."""
    if mode not in {"affected", "full"}:
        raise ValueError("unknown CI mode")
    if mode == "full" or event_name == "schedule":
        return True
    if event_name == "pull_request":
        return event.get("pull_request", {}).get("base", {}).get("ref") in (None, "", "main")
    if event_name == "merge_group":
        return event.get("merge_group", {}).get("base_ref") in (None, "", "refs/heads/main")
    return event_name not in {"push", "workflow_dispatch"}


def select_coverage(root: Path, policy: dict, paths: list[str] | None, *, full: bool) -> dict:
    """Expand reviewed domains into real owners and an exact baseline corpus."""
    # The sharder verifies that every excluded suite has an unconditional owner.
    # A stale or malformed inventory fails planning, rather than skipping tests.
    result = subprocess.run(["bash", str(root / "bin/suite-shard.sh"), "--exclude-owned", "0", "1"],
                            capture_output=True, text=True, check=True, timeout=30)
    corpus = result.stdout.splitlines()
    if not corpus or len(corpus) != len(set(corpus)):
        raise ValueError("empty or duplicate baseline corpus")
    all_groups = {g for w in policy["workflows"].values() for g in w["jobs"]}
    selection = {"full": True, "reason": "Full verification requested", "domains": []}
    if not full:
        # Import from this checkout, including when loaded by an offline test.
        import importlib.util
        spec = importlib.util.spec_from_file_location("ci_domains", root / "bin/ci_domains.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        selection = module.select_domains(paths, root)
    groups = set(selection.get("groups", []))
    if not groups <= all_groups:
        raise ValueError("domain selected an unknown test owner")
    if selection.get("python_suites"):
        raise ValueError("standalone Python suites require an explicit workflow owner")
    selected = set(selection.get("shell_suites", []))
    ownership = json.loads((root / "bin/ci-test-ownership.json").read_text())
    owners = {row["suite"]: OWNER_GROUPS[row["job"]] for row in ownership["excluded_from_baseline"]}
    if not selected <= set(corpus) | set(owners):
        raise ValueError("domain selected an unknown shell suite")
    if selection["full"]:
        groups = all_groups
        suites = corpus
    else:
        groups.update(owners[suite] for suite in selected if suite in owners)
        suites = sorted(selected & set(corpus))
        if "baseline" in groups and not suites:
            raise ValueError("baseline group requires explicit suites")
        if suites:
            groups.add("baseline")
    return {"groups": sorted(groups), "baseline_suites": suites,
            "domains": selection.get("domains", []),
            "mode": "full" if selection["full"] else "affected",
            "reason": selection["reason"]}


def fingerprint(root: Path) -> str:
    paths = sorted((root / ".github/workflows").glob("*.yml"))
    paths += [root / p for p in (".github/ci-policy.json", "bin/ci-plan.py", "bin/ci_reuse.py",
                                "bin/ci-test-ownership.json", "bin/ci-domains.json",
                                "bin/ci_domains.py", "bin/suite-shard.sh")]
    digest = hashlib.sha256()
    for path in paths:
        digest.update(str(path.relative_to(root)).encode() + b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def make_plan(root: Path, key: str, event_name: str, event: dict, *, paths=None,
              env=None, finder=None, allow_reuse=True, mode="affected") -> dict:
    policy = load_policy(root)
    actual_paths = paths if paths is not None else changed_paths(root, event_name, event)
    selection = None
    if key == "all":
        workflow = {"path": ".github/workflows/ci.yml", "reuse": False,
                    "jobs": {g: jobs for w in policy["workflows"].values() for g, jobs in w["jobs"].items()}}
        selection = select_coverage(root, policy, actual_paths, full=full_required(event_name, event, mode))
        groups, reason = selection["groups"], selection["reason"]
    else:
        workflow = policy["workflows"][key]
        groups, reason = select_groups(actual_paths, policy)
    coverage = sorted(set(groups) & set(workflow["jobs"]))
    if event_name == "push" and "push_groups" in workflow:
        # Post-merge ownership does not imply adding every PR-only API check
        # to pushes. Retain only this workflow's explicitly declared owners.
        coverage = sorted(set(coverage) & set(workflow["push_groups"]))
        reason += "; configured push-owner scope"
    required = sorted({j for g in coverage for j in workflow["jobs"][g]})
    runtime = ({} if key == "all" else environment()) if env is None else env
    checkout = git(root, "rev-parse", "HEAD")
    tree = git(root, "rev-parse", "HEAD^{tree}")
    pr = event.get("pull_request", {})
    plan = {"version": 1, "workflow_path": workflow["path"], "workflow": key,
            "tree": tree, "checkout_sha": checkout, "fingerprint": fingerprint(root),
            "environment": runtime, "groups": coverage, "requested_groups": coverage,
            "required_jobs": required,
            "run_id": int(os.environ.get("GITHUB_RUN_ID", "0")),
            "run_attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
            "pr_head_sha": pr.get("head", {}).get("sha", ""),
            "pr_base_sha": pr.get("base", {}).get("sha", ""),
            "execute": bool(coverage), "reason": reason, "reused": None}
    if selection is not None:
        suites = selection["baseline_suites"]
        # Amortize checkout/tool setup for small affected selections. Full
        # coverage retains its parallelism; no timing database is required.
        shard_count = (min(4, len(suites)) if selection["mode"] == "full"
                       else min(4, (len(suites) + 3) // 4))
        plan.update(mode=selection["mode"], domains=selection["domains"], baseline_suites=suites,
                    baseline_shards=list(range(shard_count)), baseline_shard_count=shard_count,
                    baseline_strict=full_required(event_name, event, mode))
        plan["required_jobs"] = [j for j in required if not j.startswith("Suite baseline ")]
        plan["required_jobs"] += [f"Suite baseline — shard {i}" for i in range(shard_count)]
    # Only post-merge pushes may reuse PR evidence. Manual and merge-queue
    # invocations always execute their selected checks. No reuse from local runs.
    ready = all(runtime.get(k) and runtime[k] != "unavailable" for k in
                ("image_os", "image_version", "runner_os", "runner_arch", "node", "npm", "timezone", "locale"))
    eligible = sorted(set(coverage) & set(workflow.get("reuse_groups", [])))
    # History/startup-sensitive checks deliberately have no reuse eligibility.
    # Tree-pure package tests require a clean index and an integrity lockfile.
    if "artifacts" in eligible and not (root / "packages/egregore-artifacts/package-lock.json").is_file():
        eligible.remove("artifacts")
    if eligible and git(root, "status", "--porcelain", "--untracked-files=normal"):
        eligible = []
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if (allow_reuse and eligible and workflow["reuse"] and event_name == "push" and ready
            and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo)
            and event.get("ref") in ("refs/heads/develop", "refs/heads/main")):
        if finder is None:
            from ci_reuse import find_verified_run
            finder = find_verified_run
        verified = {}
        for group in eligible:
            try:
                previous = finder(repo=repo, workflow_path=workflow["path"], tree=tree,
                                  fingerprint=plan["fingerprint"], groups=[group], environment=runtime,
                                  required_jobs=workflow["jobs"][group],
                                  artifact_name=f"ci-result-{key}-{group}", max_age_hours=policy["reuse_hours"])
            except Exception:
                # An unavailable proof costs another test run, never a false pass.
                previous = None
            if previous:
                verified[group] = previous
        if verified:
            remaining = sorted(set(coverage) - set(verified))
            plan.update(execute=bool(remaining), groups=remaining,
                        required_jobs=sorted({j for g in remaining for j in workflow["jobs"][g]}),
                        reused=verified,
                        reason="Reused completed checks: " + ", ".join(sorted(verified)) +
                               "; " + ", ".join(sorted({v["url"] for v in verified.values()})))
    return plan


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", required=True, choices=("all", "tests", "baseline", "runtime", "api", "shellcheck"))
    parser.add_argument("--mode", choices=("affected", "full"), default="affected")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME", "workflow_dispatch"))
    parser.add_argument("--event-file", type=Path, default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--no-reuse", action="store_true")
    parser.add_argument("--complete-group", choices=("artifacts", "multiplayer"))
    parser.add_argument("--start-group", choices=("artifacts", "multiplayer"))
    parser.add_argument("--start-receipt", type=Path)
    args = parser.parse_args(argv)
    if args.start_group and args.complete_group:
        parser.error("start and completion are separate steps")
    event = json.loads(args.event_file.read_text()) if args.event_file else {}
    plan = make_plan(args.root, args.workflow, args.event_name, event,
                     allow_reuse=not args.no_reuse and not (args.complete_group or args.start_group), mode=args.mode)
    if args.complete_group or args.start_group:
        group = args.complete_group or args.start_group
        workflow = load_policy(args.root)["workflows"][args.workflow]
        eligible = (group in workflow.get("reuse_groups", [])
                    and group in plan["groups"]
                    and not git(args.root, "status", "--porcelain", "--untracked-files=normal"))
        if group == "artifacts":
            eligible = eligible and (args.root / "packages/egregore-artifacts/package-lock.json").is_file()
        owner = os.environ.get("GITHUB_JOB", "")
        eligible = eligible and owner in workflow["jobs"][group]
        plan.update(owner_job=owner, groups=[group], required_jobs=workflow["jobs"][group])
        if args.complete_group:
            try:
                initial = json.loads(args.start_receipt.read_text()) if args.start_receipt else {}
            except (OSError, ValueError):
                initial = {}
            fields = ("checkout_sha", "tree", "fingerprint", "run_id", "run_attempt", "owner_job",
                      "workflow_path", "groups", "required_jobs", "environment")
            eligible = eligible and initial.get("started") is True and all(initial.get(k) == plan[k] for k in fields)
            plan["start_environment"] = initial.get("environment")
        if not eligible:
            print("No reusable completion receipt: checkout or dependency proof unavailable")
            if args.github_output:
                with args.github_output.open("a") as output:
                    output.write("receipt=false\n")
            return 0
        plan.update(completion=bool(args.complete_group), started=bool(args.start_group), execute=True, reused=None)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(plan, indent=2) + "\n")
    if args.github_output:
        if args.complete_group or args.start_group:
            with args.github_output.open("a") as output:
                output.write("receipt=true\n")
            return 0
        all_groups = {g for w in load_policy(args.root)["workflows"].values() for g in w["jobs"]}
        values = {"run": str(plan["execute"]).lower(), "reason": plan["reason"]}
        if args.workflow == "all":
            values.update(mode=plan["mode"], baseline_suites=json.dumps(plan["baseline_suites"], separators=(",", ":")),
                          baseline_shards=json.dumps(plan["baseline_shards"]),
                          baseline_shard_count=str(plan["baseline_shard_count"]),
                          baseline_strict=str(plan["baseline_strict"]).lower())
        values.update({g: str(plan["execute"] and g in plan["groups"]).lower() for g in sorted(all_groups)})
        with args.github_output.open("a") as output:
            for key, value in values.items():
                if "\n" in value or "\r" in value:
                    raise ValueError("invalid multiline action output")
                output.write(f"{key}={value}\n")
    print(f"CI {args.workflow}: {'run' if plan['execute'] else 'skip'} — {plan['reason']}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as output:
            output.write(f"### CI plan: {args.workflow}\n\n{plan['reason']}\n\n")
            output.write("Groups: " + (", ".join(plan["groups"]) or "no affected checks") + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
