"""Reviewed affected-test domains; incomplete evidence requests full coverage.

This inventory records dependencies, rather than inferring them from test names
or source text. The caller owns execution and expands ``full`` to its complete
test inventory. Empty selections are never an instruction to expand implicitly.
"""
from __future__ import annotations

from functools import lru_cache
import fnmatch
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
_LIST_FIELDS = ("patterns", "groups", "shell_suites", "python_suites")


def _path(value: object, *, pattern: bool = False) -> bool:
    if not isinstance(value, str) or not value or "\\" in value:
        return False
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        return False
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    if ":" in parts[0]:
        return False
    if not pattern and any(char in value for char in "*?[]"):
        return False
    return not any("**" in part and part != "**" for part in parts)


def matches(path: str, pattern: str) -> bool:
    """Match POSIX path segments: * cannot swallow a slash, ** can."""
    parts, patterns = path.split("/"), pattern.split("/")

    @lru_cache(maxsize=None)
    def visit(index: int, pattern_index: int) -> bool:
        if pattern_index == len(patterns):
            return index == len(parts)
        if patterns[pattern_index] == "**":
            return visit(index, pattern_index + 1) or (
                index < len(parts) and visit(index + 1, pattern_index))
        return (index < len(parts)
                and fnmatch.fnmatchcase(parts[index], patterns[pattern_index])
                and visit(index + 1, pattern_index + 1))

    return visit(0, 0)


def _present(root: Path, path: str) -> bool:
    candidate = root / path
    # Deleted inputs and out-of-tree symlinks cannot authorize reduced tests.
    return candidate.is_file() and candidate.resolve().is_relative_to(root)


def load_domains(root: Path | str = ROOT) -> dict:
    """Load a complete valid inventory, or raise ValueError without partial data."""
    root = Path(root).resolve()
    try:
        inventory = json.loads((root / "bin/ci-domains.json").read_text())
        policy = json.loads((root / ".github/ci-policy.json").read_text())
        groups = {group for workflow in policy["workflows"].values()
                  for group in workflow["jobs"]}
        if (set(inventory) != {"version", "unknown", "domains", "historical_replays"}
                or type(inventory["version"]) is not int or inventory["version"] != 1
                or inventory["unknown"] != "full"
                or not isinstance(inventory["domains"], dict)
                or not inventory["domains"]):
            raise ValueError
        all_patterns: set[str] = set()
        for name, domain in inventory["domains"].items():
            if (not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9-]*", name)
                    or not isinstance(domain, dict)
                    or set(domain) != {*_LIST_FIELDS, "rationale"}
                    or not isinstance(domain["rationale"], str) or not domain["rationale"].strip()):
                raise ValueError
            for field in _LIST_FIELDS:
                values = domain[field]
                if (not isinstance(values, list)
                        or any(not isinstance(value, str) for value in values)
                        or len(set(values)) != len(values)):
                    raise ValueError
            if (not domain["patterns"] or not set(domain["groups"]) <= groups
                    or any(not _path(pattern, pattern=True) for pattern in domain["patterns"])
                    or all_patterns.intersection(domain["patterns"])):
                raise ValueError
            all_patterns.update(domain["patterns"])
            for field, suffix in (("shell_suites", ".sh"), ("python_suites", ".py")):
                for suite in domain[field]:
                    if (not _path(suite) or not suite.endswith(suffix)
                            or not _present(root, suite)):
                        raise ValueError
                    if field == "shell_suites" and not (
                            suite.startswith("tests/") and len(suite.split("/")) == 2
                            or suite.startswith("bin/tests/") and len(suite.split("/")) == 3):
                        raise ValueError
                    if suite == "tests/run-all.sh":
                        raise ValueError
        replays = inventory["historical_replays"]
        if not isinstance(replays, list):
            raise ValueError
        seen_prs: set[int] = set()
        for replay in replays:
            if (not isinstance(replay, dict) or set(replay) != {"pr", "paths", "domains"}
                    or type(replay["pr"]) is not int or replay["pr"] <= 0
                    or replay["pr"] in seen_prs
                    or not isinstance(replay["paths"], list) or not replay["paths"]
                    or any(not _path(path) for path in replay["paths"])
                    or not isinstance(replay["domains"], list)
                    or any(not isinstance(name, str) for name in replay["domains"])
                    or not set(replay["domains"]) <= set(inventory["domains"])):
                raise ValueError
            seen_prs.add(replay["pr"])
        return inventory
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError) as error:
        raise ValueError("Invalid or unavailable CI domain inventory") from error


def select_domains(paths: list[str] | None, root: Path | str = ROOT) -> dict:
    """Return a sorted union of reviewed owners, or an explicit full fallback."""
    result = {"full": True, "domains": [], "groups": [], "shell_suites": [],
              "python_suites": [], "reason": "No trustworthy changed-file inventory; full coverage"}
    if not isinstance(paths, list) or not paths:
        return result
    root = Path(root).resolve()
    try:
        inventory = load_domains(root)
        selected: set[str] = set()
        for path in paths:
            if not _path(path) or not _present(root, path):
                result["reason"] = "Invalid, deleted or unavailable changed input; full coverage"
                return result
            found = {name for name, domain in inventory["domains"].items()
                     if any(matches(path, pattern) for pattern in domain["patterns"])}
            if not found:
                result["reason"] = "Shared or unmapped input; full coverage"
                return result
            selected.update(found)
        result.update(full=False, domains=sorted(selected), reason="Reviewed affected-test domains")
        for field in ("groups", "shell_suites", "python_suites"):
            result[field] = sorted({value for name in selected
                                    for value in inventory["domains"][name][field]})
        return result
    except (OSError, ValueError, TypeError, RuntimeError, RecursionError):
        result["reason"] = "Invalid or unavailable CI domain inventory; full coverage"
        return result
