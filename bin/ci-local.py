#!/usr/bin/env python3
"""Run the checks CI would select for this branch, here, before it goes ready.

bin/ci-plan.py chooses the groups from every change against the merge base
with origin/<base>, including uncommitted and untracked files. bin/ci-local.json
lists the commands each CI job runs; steps only CI can run are reported as left
to CI, never as failures. The first failed group stops the run. Exit 0 when
nothing failed, 1 when a check failed, 2 when no plan could be made.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
STEP_TIMEOUT = 30 * 60
# Harness, credential and Git variables never reach a CI job; keep them out.
SCRUBBED = ("EGREGORE_", "CLAUDE", "CODEX_", "ANTHROPIC_", "OPENAI_", "GIT_", "GH_", "GITHUB_")


def git(root: Path, *args: str, raw: bool = False):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=True, timeout=60)
    return result.stdout if raw else result.stdout.decode().strip()


def changed_paths(root: Path, merge_base: str) -> list[str]:
    """Everything a save would push: commits, staged, unstaged and untracked files."""
    tracked = git(root, "diff", "--name-only", "--no-renames", "-z", merge_base, "--", raw=True)
    untracked = git(root, "ls-files", "-z", "--others", "--exclude-standard", raw=True)
    return sorted({p.decode() for p in (tracked + b"\0" + untracked).split(b"\0") if p})


def plan_for(root: Path, base: str) -> dict:
    merge_base = git(root, "merge-base", f"origin/{base}", "HEAD")
    paths = changed_paths(root, merge_base)
    plan = {"merge_base": merge_base, "paths": paths, "groups": [], "baseline_suites": [],
            "baseline_strict": False, "reason": "no changes"}
    if paths:
        spec = importlib.util.spec_from_file_location("ci_plan", root / "bin/ci-plan.py")
        planner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(planner)
        event = {"pull_request": {"base": {"sha": merge_base, "ref": base},
                                  "head": {"sha": git(root, "rev-parse", "HEAD")}}}
        made = planner.make_plan(root, "all", "pull_request", event, paths=paths, env={}, allow_reuse=False)
        plan.update({k: made[k] for k in ("groups", "baseline_suites", "baseline_strict", "reason")})
    return plan


def requirement_names(path: Path) -> list[str]:
    names = []
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line.startswith("-r "):
            names += requirement_names(path.parent / line[3:].strip())
        elif match := re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", line):
            names.append(match.group(0))
    return names


def missing(root: Path, needs: list[str], env: dict) -> list[str]:
    """Return what a step needs but this machine has not installed."""
    absent = [need for need in needs if not need.startswith("pip:") and not (root / need).exists()]
    wanted = []
    for need in needs:
        if need.startswith("pip:-r "):
            wanted += requirement_names(root / need[len("pip:-r "):])
        elif need.startswith("pip:"):
            wanted.append(need[len("pip:"):])
    if wanted:
        probe = ("import importlib.metadata as m, sys\nfor n in sys.argv[1:]:\n"
                 "    try: m.distribution(n)\n    except Exception: print(n)\n")
        try:
            result = subprocess.run(["python", "-c", probe, *wanted], env=env, capture_output=True,
                                    text=True, timeout=60)
            absent += [f"python {name}" for name in result.stdout.split()] if result.returncode == 0 else ["python"]
        except (OSError, subprocess.SubprocessError):
            absent.append("python")
    return absent


def run(command: list[str], cwd: Path, env: dict, log, stdin=subprocess.DEVNULL) -> int:
    log.flush()
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
                               stdin=stdin, start_new_session=True)
    try:
        return process.wait(timeout=STEP_TIMEOUT)
    except subprocess.TimeoutExpired:
        log.write(f"\nci-local: stopped after {STEP_TIMEOUT // 60} minutes\n".encode())
        return 124
    finally:
        # Like the end of a CI job: nothing the step started outlives it.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        process.wait()


def run_group(root: Path, group: str, jobs: dict, plan: dict, env: dict, log) -> tuple[int, list[str], list[str]]:
    """Run one group's local steps; return how many ran, which failed and what CI keeps."""
    ran, failed, left, absent_here = 0, [], [], []
    for job_id, job in jobs.items():
        if job["group"] != group:
            continue
        if isinstance(job.get("left_to_ci"), str):
            left.append(job["left_to_ci"])
            continue
        job_env = {**env, **job.get("env", {})}
        for name, step in job.get("steps", {}).items():
            step = {"run": step} if isinstance(step, str) else step
            absent = missing(root, step.get("needs", []), job_env)
            if absent:
                absent_here += absent
                continue
            log.write(f"\n$ [{job_id}] {name}\n".encode())
            if "baseline" in step:
                args = step["baseline"].split() + ["--base", plan["merge_base"]]
                args += ["--strict-head"] if plan["baseline_strict"] else []
                with tempfile.TemporaryFile() as suites:
                    suites.write("".join(f"{s}\n" for s in plan["baseline_suites"]).encode())
                    suites.seek(0)
                    code = run(["bash", "bin/test-baseline.sh", *args, "-"], root,
                               {**job_env, "TMPDIR": env["RUNNER_TEMP"]}, log, stdin=suites)
            else:
                code = run(["bash", "--noprofile", "--norc", "-e", "-c", step["run"]],
                           root / step.get("cwd", "."), job_env, log)
            log.write(f"$ exit {code}\n".encode())
            ran += 1
            if code != 0 and "baseline" in step:
                # Name the suites that regressed or could not finish, not the step.
                log.flush()
                report = Path(log.name).read_text(errors="replace")
                failed += re.findall(r"^  (?:regression|blocked) +(\S+)", report, re.M) or [name]
            elif code != 0:
                failed.append(name)
        left += job.get("left_to_ci", {}).values()
    if absent_here:
        left.append(f"not installed here: {', '.join(dict.fromkeys(absent_here))}")
    return ran, failed, list(dict.fromkeys(left))


def clock(seconds: float) -> str:
    seconds = round(seconds)
    return f"{seconds // 60}m {seconds % 60:02d}s" if seconds >= 60 else f"{seconds}s"


def environment(run_dir: Path) -> dict:
    env = {k: v for k, v in os.environ.items() if not k.startswith(SCRUBBED)}
    env["RUNNER_TEMP"] = str(run_dir / "runner-temp")
    Path(env["RUNNER_TEMP"]).mkdir()
    # CI's setup-python provides `python`; many Macs only have python3.
    if shutil.which("python", path=env.get("PATH")) is None and shutil.which("python3"):
        (run_dir / "bin").mkdir()
        (run_dir / "bin/python").symlink_to(shutil.which("python3"))
        env["PATH"] = f"{run_dir / 'bin'}{os.pathsep}{env.get('PATH', '')}"
    return env


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="integration branch (default: bin/base-branch.sh)")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    # A harness that gives up on this run must not leave its checks running.
    for stop in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(stop, lambda number, _: sys.exit(128 + number))
    try:
        base = args.base or subprocess.run(["bash", str(root / "bin/base-branch.sh")], capture_output=True,
                                           text=True, check=True).stdout.strip()
        plan = plan_for(root, base)
        jobs = json.loads((root / "bin/ci-local.json").read_text())["jobs"]
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"ci-local: could not plan the checks: {error}", file=sys.stderr)
        return 2
    if not plan["groups"]:
        print(f"ci-local: CI would run nothing for this branch ({plan['reason']}).")
        return 0
    order = list(dict.fromkeys(job["group"] for job in jobs.values()))
    groups = [g for g in order if g in plan["groups"]] + [g for g in plan["groups"] if g not in order]
    print(f"ci-local: {len(plan['paths'])} changed files against origin/{base}; CI would run "
          f"{', '.join(groups)} ({plan['reason']}).", flush=True)
    run_dir = Path(tempfile.mkdtemp(prefix="ci-local."))
    env = environment(run_dir)
    started, failed_groups, left_groups = time.monotonic(), [], []
    for group in groups:
        if failed_groups:
            print(f"  {group:<15} not run (stopped after a failure)")
            continue
        began = time.monotonic()
        log_path = run_dir / f"{group}.log"
        with log_path.open("wb") as log:
            ran, failed, left = run_group(root, group, jobs, plan, env, log)
        status = "failed" if failed else "passed" if ran else "left to CI"
        notes = [f"{len(plan['baseline_suites'])} suites"] if group == "baseline" and ran else []
        if left:
            notes.append(f"left to CI: {'; '.join(left)}" if ran else "; ".join(left))
        detail = f"{'; '.join(failed)} (log: {log_path})" if failed else "; ".join(notes)
        print(f"  {group:<15} {status:<10} {clock(time.monotonic() - began):>7}"
              + (f"  {detail}" if detail else ""), flush=True)
        if failed:
            failed_groups.append(group)
        elif not ran:
            left_groups.append(group)
    took = clock(time.monotonic() - started)
    if failed_groups:
        print(f"ci-local: failed in {took}: {', '.join(failed_groups)}. Logs: {run_dir}. "
              f"After fixing, run again: python3 bin/ci-local.py")
        return 1
    shutil.rmtree(run_dir, ignore_errors=True)
    if len(left_groups) == len(groups):
        print(f"ci-local: nothing here could run these checks; CI will run {', '.join(left_groups)}.")
    else:
        print(f"ci-local: passed in {took}" + (f"; left to CI: {', '.join(left_groups)}" if left_groups else "") + ".")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
