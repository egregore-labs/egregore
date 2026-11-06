#!/usr/bin/env python3
"""Bind caller-recorded local checks to a PR commit while hosted CI is unavailable.

generate --records FILE accepts a JSON array of {suite, command, exit_code, log}.
It copies logs beside the receipt and hashes them. validate checks identity,
Git trees and retained log integrity; it does not execute commands or certify
that the caller actually ran them. Authorization belongs to the merge caller.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

SCHEMA = "local-ci/v1"
REASON = "GitHub Actions credits exhausted"
MAX_JSON = 1024 * 1024
MAX_LOG = 64 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"[0-9a-f]{64}")


class Invalid(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


def read_file(path, limit):
    """Read a bounded regular file without following its final symlink."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_size <= limit, "invalid evidence file")
        value = stream.read(limit + 1)
        require(len(value) <= limit, "evidence file exceeds limit")
        return value


def read_log(root, relative):
    """A receipt can read regular log descendants only, without symlink hops."""
    require(isinstance(relative, str) and relative, "missing retained log path")
    path = Path(relative)
    require(path.parts and not path.is_absolute() and all(p not in (".", "..") for p in path.parts),
            "retained log must stay beside the receipt")
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0), dir_fd=fd)
            os.close(fd)
            fd = child
        leaf = os.open(path.parts[-1], os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0), dir_fd=fd)
        with os.fdopen(leaf, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_size <= MAX_LOG, "invalid retained log")
            content = stream.read(MAX_LOG + 1)
            require(len(content) <= MAX_LOG, "retained log exceeds limit")
            return content
    finally:
        os.close(fd)


def document(path):
    value = json.loads(read_file(path, MAX_JSON))
    require(isinstance(value, dict), "receipt must be an object")
    return value


def git(checkout, *args, failure="Git identity is unavailable"):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_NOSYSTEM="1", GIT_NO_REPLACE_OBJECTS="1")
    result = subprocess.run(["git", "-c", "core.fsmonitor=false", "-C", str(checkout), *args], env=env,
                            capture_output=True, text=True, timeout=15)
    require(result.returncode == 0, failure)
    return result.stdout.strip()


def text(value, label, limit=4096):
    require(isinstance(value, str) and 0 < len(value) <= limit
            and all(ord(c) >= 32 or c in "\n\t" for c in value), f"invalid {label}")
    return value


def identity(row):
    require(row.get("schema") == SCHEMA, "unsupported local CI receipt schema")
    require(isinstance(row.get("repo"), str) and
            re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", row["repo"]), "invalid repository")
    require(type(row.get("pr")) is int and row["pr"] > 0, "invalid PR number")
    for key in ("head", "base_sha", "tree_sha"):
        require(isinstance(row.get(key), str) and SHA.fullmatch(row[key]), f"invalid {key}")
    text(row.get("base"), "base ref", 200)
    require("\n" not in row["base"] and "\t" not in row["base"] and not row["base"].startswith("-"),
            "invalid base ref")
    text(row.get("checkout"), "checkout")
    require(Path(row["checkout"]).is_absolute(), "checkout must be absolute")
    require(row.get("unavailable_reason") == REASON, "unsupported hosted CI exception")


def validate(path, *, repo, pr, head, base, base_sha):
    row = document(path)
    identity(row)
    for key, wanted in (("repo", repo), ("pr", pr), ("head", head), ("base", base), ("base_sha", base_sha)):
        require(row[key] == wanted, f"receipt {key} does not match current PR")
    require(git(row["checkout"], "rev-parse", "--verify", row["head"] + "^{tree}") == row["tree_sha"],
            "tested tree does not match PR head")
    require(git(row["checkout"], "rev-parse", "--verify", row["base_sha"] + "^{commit}") == row["base_sha"],
            "base commit is unavailable")
    git(row["checkout"], "merge-base", "--is-ancestor", row["base_sha"], row["head"],
        failure="tested head does not contain the current base")
    suites = row.get("required_suites")
    require(isinstance(suites, list) and 0 < len(suites) <= 100, "required suites are missing")
    for suite in suites:
        text(suite, "suite name", 200)
    require(len(set(suites)) == len(suites), "required suites are duplicated")
    results = row.get("results")
    require(isinstance(results, list) and len(results) == len(suites), "required suite results are incomplete")
    seen = set()
    for result in results:
        require(isinstance(result, dict), "invalid suite result")
        suite = result.get("suite")
        require(isinstance(suite, str) and suite in suites and suite not in seen,
                "unexpected or duplicate suite result")
        seen.add(suite)
        text(result.get("command"), "recorded command", 16384)
        require(type(result.get("exit_code")) is int and result["exit_code"] == 0,
                f"required suite did not pass: {suite}")
        require(isinstance(result.get("sha256"), str) and DIGEST.fullmatch(result["sha256"]),
                "invalid log digest")
        log = read_log(Path(path).resolve().parent, result.get("log"))
        require(hashlib.sha256(log).hexdigest() == result["sha256"], f"log changed: {suite}")
    failed = row.get("failed_checks")
    require(isinstance(failed, list) and len(failed) <= 100, "failed_checks must be a list")
    named = set()
    for check in failed:
        require(isinstance(check, dict), "invalid hosted check explanation")
        name = text(check.get("name"), "hosted check name", 300)
        text(check.get("reason"), "hosted check reason")
        require(name not in named, "duplicate hosted check explanation")
        named.add(name)
    return row


def quoted(value):
    """Single-line Markdown code, including hostile backticks, without HTML."""
    value = " ".join(str(value).split())
    runs = re.findall(r"`+", value)
    fence = "`" * (1 + max(map(len, runs), default=0))
    return f"{fence} {value} {fence}"


def markdown(row):
    lines = ["## Local CI receipt", "",
             f"Repository {quoted(row['repo'])}, PR #{row['pr']}.",
             f"Head {quoted(row['head'])}; base {quoted(row['base'])} at {quoted(row['base_sha'])}.",
             f"Tested tree {quoted(row['tree_sha'])}.",
             f"Caller-reported hosted CI exception: {REASON}.", "",
             "The caller recorded these checks. Validation verified commit identity and retained log hashes; "
             "it did not independently execute or attest the commands. The receipt does not grant merge authorization.",
             ""]
    for result in row["results"]:
        lines.append(f"- {quoted(result['suite'])}: recorded exit 0; {quoted(result['command'])}; "
                     f"log SHA256 {quoted(result['sha256'])}.")
    if row["failed_checks"]:
        lines.extend(["", "Hosted checks covered by this local exception:", ""])
        for check in row["failed_checks"]:
            lines.append(f"- {quoted(check['name'])}: {quoted(check['reason'])}.")
    return "\n".join(lines) + "\n"


def generate(args):
    checkout = Path(args.checkout).resolve()
    tree = args.tree
    if tree is None:
        require(git(checkout, "rev-parse", "HEAD") == args.head, "checkout is not at the tested head")
        require(not git(checkout, "status", "--porcelain", "--untracked-files=no"), "tracked checkout is dirty")
        tree = git(checkout, "rev-parse", "HEAD^{tree}")
    row = {"schema": SCHEMA, "repo": args.repo, "pr": args.pr, "head": args.head,
           "base": args.base, "base_sha": args.base_sha, "tree_sha": tree,
           "checkout": str(checkout), "unavailable_reason": args.unavailable_reason,
           "required_suites": args.required_suite, "results": [],
           "failed_checks": json.loads(read_file(args.failed_checks, MAX_JSON)) if args.failed_checks else []}
    identity(row)
    records = json.loads(read_file(args.records, MAX_JSON))
    require(isinstance(records, list), "records must be a JSON array")
    output = Path(args.output).absolute()
    require(not output.exists(), "receipt output already exists")
    output.parent.mkdir(parents=True, exist_ok=True)
    log_root = output.parent / (output.name + ".logs")
    log_root.mkdir(mode=0o700)
    for index, result in enumerate(records):
        require(isinstance(result, dict), "invalid caller record")
        content = read_file(Path(args.records).resolve().parent / result["log"], MAX_LOG)
        target = log_root / f"{index + 1:03d}.log"
        with target.open("xb") as stream:
            stream.write(content)
        target.chmod(0o600)
        row["results"].append({key: result.get(key) for key in ("suite", "command", "exit_code")} |
                              {"log": str(target.relative_to(output.parent)),
                               "sha256": hashlib.sha256(content).hexdigest()})
    with output.open("x", encoding="utf-8") as stream:
        json.dump(row, stream, indent=2)
        stream.write("\n")
    output.chmod(0o600)
    validate(output, repo=args.repo, pr=args.pr, head=args.head, base=args.base, base_sha=args.base_sha)
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("generate", "validate"):
        command = sub.add_parser(action)
        for flag in ("repo", "head", "base", "base-sha"):
            command.add_argument("--" + flag, required=True)
        command.add_argument("--pr", type=int, required=True)
        if action == "validate":
            command.add_argument("--receipt", type=Path, required=True)
        else:
            command.add_argument("--output", type=Path, required=True)
            command.add_argument("--checkout", type=Path, required=True)
            command.add_argument("--records", type=Path, required=True)
            command.add_argument("--required-suite", action="append", required=True)
            command.add_argument("--unavailable-reason", required=True)
            command.add_argument("--failed-checks", type=Path, help="JSON array of hosted {name, reason} explanations")
            command.add_argument("--tree", help="explicit tested Git tree, for checks run before committing that tree")
    args = parser.parse_args(argv)
    try:
        if args.action == "generate":
            print(generate(args))
        else:
            print(markdown(validate(args.receipt, repo=args.repo, pr=args.pr, head=args.head,
                                    base=args.base, base_sha=args.base_sha)), end="")
    except (Invalid, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"local-ci: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
