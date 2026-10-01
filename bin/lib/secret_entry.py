"""Small, runtime-neutral hidden credential entry for Railway and dotenv.

Only prepare/apply destinations selected by the user. Never accept a credential
as a command argument, log subprocess output, or retry a possibly completed write.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import fcntl
import getpass
import hmac
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from uuid import UUID, uuid4
import warnings

SCHEMA = "egregore-secret-entry/v1"
_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,127}\Z")
_ASSIGNMENT = re.compile(r"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*(?:=(.*)|$)")
_STAT_FIELDS = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_mode")
_INPUT_REASONS = {"sandbox", "no_display", "not_darwin", "no_tty", "unknown"}
_LOCATE_PRUNE_DIRS = {
    "node_modules", ".venv", "venv", "env", "site-packages", "dist", "build",
    "target", "out", ".cache", "__pycache__", ".tox", ".mypy_cache",
    ".pytest_cache", "vendor", ".next", ".turbo", "coverage",
}
_CONSUMER_MAX_BYTES = 1024 * 1024
_CONSUMER_MAX_MATCHES = 200
_REASONS = {
    "invalid_arguments": "Invalid arguments. Enter secret values only through hidden input.",
    "invalid_root": "Select the canonical root of the owning Git repository.",
    "invalid_key": "Choose a valid environment variable name.",
    "invalid_id": "Railway project, environment, and service must be UUIDs.",
    "unsafe_path": "The selected path must stay inside the explicit root and must not use symlinks. Resolve the actual storage path and select its owning root explicitly.",
    "not_ignored": "The selected file and secret-entry directory must be Git-ignored and untracked.",
    "command_failed": "A destination check or command failed; command output was suppressed.",
    "invalid_response": "The destination returned an unexpected response.",
    "wrong_destination": "The destination identity or access did not match the selected IDs.",
    "changed_destination": "The destination or existing-key state changed. Prepare a new plan.",
    "invalid_plan": "The secret-entry plan is invalid or is outside its expected private location.",
    "invalid_dotenv": "The dotenv file is not supported or contains duplicate keys.",
    "changed_file": "The selected file changed. Nothing was replaced; prepare a new plan.",
    "cross_device": "The selected dotenv file and private staging directory must be on the same filesystem for an atomic write.",
    "hidden_input_unavailable": "Hidden input is unavailable. Use terminal input in a real interactive terminal.",
    "cancelled": "Secret entry was cancelled.",
    "invalid_secret": "The value must be nonempty and single-line, without NUL characters.",
    "unsupported_dotenv_value": "This value is ambiguous across dotenv readers. Use a literal value without edge whitespace or quotes, interpolation, or an inline comment.",
    "verification_failed": "A write was attempted but exact read-back verification failed. Inspect the destination before preparing another write.",
    "storage_failed": "Local private state could not be stored safely.",
}


class SecretEntryError(Exception):
    def __init__(self, code, message=None, *, reason=None, diagnostic_code=None):
        self.code = code if code in _REASONS else "command_failed"
        self.reason = reason if reason in _INPUT_REASONS else (
            "unknown" if self.code == "hidden_input_unavailable" else None)
        self.diagnostic_code = diagnostic_code if type(diagnostic_code) is int else None
        super().__init__(_REASONS[self.code])


def _now():
    return datetime.now(timezone.utc).isoformat()


def _sandboxed():
    # These are positive markers, not guesses from a harness name or missing
    # DISPLAY (which is normal for native macOS applications).
    return (os.environ.get("CODEX_SANDBOX", "").lower() not in {"", "none", "false", "0"}
            or bool(os.environ.get("APP_SANDBOX_CONTAINER_ID")))


def _input_failure(stderr, returncode, *, compiling=False):
    """Inspect diagnostics in memory; retain only a reason and numeric code."""
    if not compiling and re.search(r"User canceled\.\s*\(-128\)", stderr):
        return SecretEntryError("cancelled")
    # Only the signed, trailing AppleScript error form is a diagnostic code;
    # arbitrary parenthesized text/numbers can be credential-bearing output.
    match = re.search(r"(?:syntax|compilation|compile|execution) error:?[^\n]*\((-\d{1,8})\)\s*$", stderr, re.I)
    code = int(match[1]) if match else returncode
    compile_failure = compiling or bool(re.search(r"syntax error|compilation error|compile error", stderr, re.I))
    if code in {-2740, -1728} and compile_failure and _sandboxed():
        reason = "sandbox"
    elif re.search(r"cannot connect to (?:the )?window\s*server|no (?:access to (?:the )?)?window\s*server|no display available", stderr, re.I):
        reason = "no_display"
    else:
        reason = "unknown"
    return SecretEntryError("hidden_input_unavailable", reason=reason,
                            diagnostic_code=code if reason == "unknown" else None)


def run(args, *, cwd, input=None, timeout=45, private_input=False, compiling=False):
    """Capture everything; only the fixed caller-selected receipt may be shown."""
    env = os.environ.copy()
    if args[0] == "railway":
        env.pop("RAILWAY_TOKEN", None)
        env["RAILWAY_ENV"] = "production"
    try:
        result = subprocess.run(args, cwd=cwd, input=input, capture_output=True,
                                text=True, timeout=timeout, check=False, env=env)
    except (OSError, subprocess.SubprocessError, UnicodeError) as error:
        if private_input:
            raise SecretEntryError("hidden_input_unavailable", reason="unknown",
                                   diagnostic_code=getattr(error, "errno", None)) from None
        raise SecretEntryError("command_failed") from None
    if result.returncode != 0:
        if private_input:
            raise _input_failure(result.stderr, result.returncode, compiling=compiling)
        raise SecretEntryError("command_failed")
    return result.stdout


def _decode(value):
    try:
        def unique(pairs):
            result = {}
            for key, item in pairs:
                if key in result:
                    raise ValueError()
                result[key] = item
            return result
        return json.loads(value, object_pairs_hook=unique)
    except (ValueError, TypeError, UnicodeError):
        raise SecretEntryError("invalid_response") from None


def decode_link(value):
    # Railway 4.29 prefixes this command's JSON with selection lines. Do not
    # search arbitrary stdout for a JSON-looking substring or relax other reads.
    lines = value.splitlines()
    while lines and (not lines[0].strip() or lines[0].startswith("> Select ")):
        lines.pop(0)
    return _decode("\n".join(lines))


def _uuid(value):
    try:
        normalized = str(UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise SecretEntryError("invalid_id") from None
    if not isinstance(value, str) or value.lower() != normalized:
        raise SecretEntryError("invalid_id")
    return normalized


def _safe_path(root, value):
    path = Path(value)
    if not path.is_absolute():
        path = root / path
    path = Path(os.path.abspath(path))
    try:
        relative = path.relative_to(root)
    except ValueError:
        raise SecretEntryError("unsafe_path") from None
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise SecretEntryError("unsafe_path")
    if any(ord(char) < 32 for char in str(path)):
        raise SecretEntryError("unsafe_path")
    return path


def _root(value):
    path = Path(os.path.abspath(value))
    if not path.is_dir() or path.resolve() != path:
        raise SecretEntryError("invalid_root")
    top = run(["git", "rev-parse", "--show-toplevel"], cwd=path).strip()
    if top != str(path):
        raise SecretEntryError("invalid_root")
    return path


def _ignored(root, path):
    relative = str(path.relative_to(root))
    try:
        run(["git", "check-ignore", "--quiet", "--", relative], cwd=root)
        tracked = run(["git", "ls-files", "--", relative], cwd=root)
    except SecretEntryError:
        raise SecretEntryError("not_ignored") from None
    if tracked:
        raise SecretEntryError("not_ignored")


def _private_scope(root, identifier, *, create=False):
    scope = _safe_path(root, root / ".egregore" / "secret-entry" / identifier)
    _ignored(root, scope)
    if create:
        scope.mkdir(parents=True, mode=0o700, exist_ok=False)
        os.chmod(scope, 0o700)
    if not scope.is_dir():
        raise SecretEntryError("invalid_plan")
    return scope


def _write_json(path, value):
    if path.is_symlink():
        raise SecretEntryError("unsafe_path")
    descriptor, temporary = tempfile.mkstemp(prefix=".state-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _nodes(value):
    if not isinstance(value, dict) or not isinstance(value.get("edges"), list):
        raise SecretEntryError("invalid_response")
    nodes = []
    for edge in value["edges"]:
        if not isinstance(edge, dict) or not isinstance(edge.get("node"), dict):
            raise SecretEntryError("invalid_response")
        nodes.append(edge["node"])
    return nodes


def _verify_project(project, destination):
    if not isinstance(project, dict) or project.get("id") != destination["project"]:
        raise SecretEntryError("wrong_destination")
    matches = [item for item in _nodes(project.get("environments"))
               if item.get("id") == destination["environment"]]
    if len(matches) != 1 or matches[0].get("canAccess") is not True:
        raise SecretEntryError("wrong_destination")
    instances = _nodes(matches[0].get("serviceInstances"))
    if not any(item.get("serviceId") == destination["service"] for item in instances):
        raise SecretEntryError("wrong_destination")


def _railway_variables(scope, destination):
    value = _decode(run(["railway", "variable", "list", "--service", destination["service"],
                         "--environment", destination["environment"], "--json"], cwd=scope))
    if not isinstance(value, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in value.items()):
        raise SecretEntryError("invalid_response")
    return value


def _railway_check(scope, destination, key):
    projects = _decode(run(["railway", "list", "--json"], cwd=scope))
    if not isinstance(projects, list):
        raise SecretEntryError("invalid_response")
    matches = [item for item in projects if isinstance(item, dict) and item.get("id") == destination["project"]]
    if len(matches) != 1:
        raise SecretEntryError("wrong_destination")
    _verify_project(matches[0], destination)
    linked = decode_link(run(["railway", "link", "--project", destination["project"],
                             "--environment", destination["environment"], "--service", destination["service"],
                             "--json"], cwd=scope))
    if not isinstance(linked, dict) or any(linked.get(name + "Id") != destination[name]
                                            for name in ("project", "environment", "service")):
        raise SecretEntryError("wrong_destination")
    _verify_project(_decode(run(["railway", "status", "--json"], cwd=scope)), destination)
    names = {}
    for field in ("project", "environment", "service"):
        value = linked.get(field + "Name")
        if isinstance(value, str) and 0 < len(value) <= 200 and value.isprintable():
            names[field] = value
    return key in _railway_variables(scope, destination), names


class _LocateFailure(Exception):
    """Only fixed classifications leave provider capture; never its diagnostics."""

    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


def _locate_railway_run(args, *, cwd):
    env = os.environ.copy()
    env.pop("RAILWAY_TOKEN", None)
    env["RAILWAY_ENV"] = "production"
    try:
        result = subprocess.run(["railway", *args], cwd=cwd, capture_output=True,
                                text=True, timeout=45, check=False, env=env)
    except FileNotFoundError:
        raise _LocateFailure("command_unavailable") from None
    except subprocess.TimeoutExpired:
        raise _LocateFailure("timeout") from None
    except (OSError, subprocess.SubprocessError, UnicodeError):
        raise _LocateFailure("command_failed") from None
    if result.returncode:
        # Inspect captured text only to select a fixed reason. Neither the text
        # nor an exception containing it is ever returned, printed, or stored.
        diagnostic = result.stderr + "\n" + result.stdout
        status = r"\b(?:HTTP(?:/\d(?:\.\d)?)?\s+|status(?:\s+code)?\s*[:=]?\s*)"
        if (re.search(r"\b(?:not logged in|unauthorized|login expired|session expired)\b", diagnostic, re.I)
                or re.search(status + r"401\b", diagnostic, re.I)):
            reason = "not_authenticated"
        elif (re.search(r"\b(?:forbidden|access denied)\b", diagnostic, re.I)
              or re.search(status + r"403\b", diagnostic, re.I)):
            reason = "inaccessible"
        else:
            reason = "command_failed"
        raise _LocateFailure(reason)
    return result.stdout


def _locate_name(value):
    return value if isinstance(value, str) and 0 < len(value) <= 200 and value.isprintable() else None


def _locate_matches(node, selector):
    return selector is None or selector == node.get("name") or selector.lower() == node.get("id")


def _locate_failure(failures, provider, scope, reason):
    failures.append({"provider": provider, "scope": scope, "reason": reason})


def _locate_private_base(root):
    # Check the future scope exactly as prepare does, without creating a plan
    # or requiring the private directory to exist already.
    base = _safe_path(root, root / ".egregore" / "secret-entry")
    _ignored(root, base / "locate-check")
    ancestor = base
    while not ancestor.exists():
        ancestor = ancestor.parent
    if not ancestor.is_dir():
        raise SecretEntryError("unsafe_path")
    return base, ancestor.stat().st_dev


def _locate_dotenv_name(name):
    return name == ".env" or name.startswith(".env.") or name.endswith(".env")


def _locate_dotenv_eligible(root, path):
    """Distinguish known ineligibility from a failed Git eligibility read."""
    relative = str(path.relative_to(root))
    try:
        ignored = subprocess.run(["git", "check-ignore", "--quiet", "--", relative],
                                 cwd=root, capture_output=True, text=True, timeout=45, check=False)
        if ignored.returncode == 1:
            return False
        if ignored.returncode != 0:
            raise _LocateFailure("eligibility_check_failed")
        tracked = subprocess.run(["git", "ls-files", "--", relative], cwd=root,
                                 capture_output=True, text=True, timeout=45, check=False)
        if tracked.returncode != 0:
            raise _LocateFailure("eligibility_check_failed")
        return not tracked.stdout
    except (OSError, subprocess.SubprocessError, UnicodeError):
        raise _LocateFailure("eligibility_check_failed") from None


def _locate_files(root, key, failures):
    """Return eligible existing dotenv files and path-only source consumers."""
    candidates, consumers = [], []
    try:
        private_base, private_device = _locate_private_base(root)
    except (SecretEntryError, OSError) as error:
        reason = error.code if isinstance(error, SecretEntryError) else "read_failed"
        _locate_failure(failures, "dotenv", {"root": str(root)}, reason)
        private_base, private_device = root / ".egregore" / "secret-entry", None
    reference = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(key) + r"(?![A-Za-z0-9_])")

    def unreadable(error):
        # Error filenames are chosen by the filesystem, not provider output;
        # still restrict them to a verified path under this root.
        try:
            path = _safe_path(root, error.filename)
            scope = {"file": str(path)}
        except (SecretEntryError, TypeError):
            scope = {"root": str(root)}
        _locate_failure(failures, "filesystem", scope, "read_failed")

    for directory, folders, files in os.walk(root, topdown=True, followlinks=False, onerror=unreadable):
        folder = Path(directory)
        kept = []
        for name in sorted(folders):
            child = folder / name
            if name == ".git" or name in _LOCATE_PRUNE_DIRS or child == private_base:
                continue
            try:
                if child.is_symlink():
                    continue
                # A .git file (worktree/submodule), directory, or dangling
                # symlink marks a different repo. Keep the selected root.
                marker = child / ".git"
                if marker.exists() or marker.is_symlink():
                    continue
            except OSError:
                _locate_failure(failures, "filesystem", {"file": str(child)}, "read_failed")
                continue
            kept.append(name)
        folders[:] = kept
        for name in sorted(files):
            path = folder / name
            relative = path.relative_to(root)
            if path.is_symlink():
                continue
            dotenv = _locate_dotenv_name(name)
            if dotenv and private_device is not None:
                try:
                    path = _safe_path(root, path)
                except SecretEntryError:
                    continue
                try:
                    if not _locate_dotenv_eligible(root, path):
                        continue
                    if path.parent.stat().st_dev != private_device:
                        raise SecretEntryError("cross_device")
                    snapshot = _dotenv_snapshot(path)
                    candidates.append({"provider": "dotenv", "destination": {"file": str(path)},
                                       "key_exists": key in snapshot["entries"]})
                except (_LocateFailure, SecretEntryError, OSError, UnicodeError) as error:
                    reason = (error.reason if isinstance(error, _LocateFailure)
                              else error.code if isinstance(error, SecretEntryError) else "read_failed")
                    _locate_failure(failures, "dotenv", {"file": str(path)}, reason)
            # Stored values are not source consumers. Exclude test/documentation
            # trees and common test filenames, and never follow a filesystem link.
            lower_name = name.lower()
            documentation = (path.suffix.lower() in {".md", ".markdown", ".rst", ".adoc"}
                             or re.match(r"(?:readme|changelog|contributing|license|copying|authors)(?:\.|$)", lower_name))
            test_file = (lower_name.startswith(("test_", "test-"))
                         or re.search(r"(?:_test\.(?:py|go|rb)|_spec\.rb|\.(?:test|spec)\.[cm]?[jt]sx?)$", lower_name))
            if (dotenv or documentation or test_file or len(consumers) >= _CONSUMER_MAX_MATCHES
                    or any(part.lower() in {".egregore", "test", "tests", "__tests__", "docs", "doc"}
                           for part in relative.parts)):
                continue
            try:
                state = _file_state(path)
                if state is None or state["st_size"] > _CONSUMER_MAX_BYTES:
                    continue
                with path.open("rb") as stream:
                    # Also bound the actual read if a file grows after stat.
                    content = stream.read(_CONSUMER_MAX_BYTES + 1)
                if len(content) > _CONSUMER_MAX_BYTES:
                    continue
                if reference.search(content.decode("utf-8")):
                    consumers.append(str(relative))
                    if len(consumers) == _CONSUMER_MAX_MATCHES:
                        _locate_failure(failures, "filesystem", {"root": str(root)}, "consumer_scan_truncated")
            except UnicodeError:
                pass  # Binary files are not text consumers.
            except (SecretEntryError, OSError):
                _locate_failure(failures, "filesystem", {"file": str(path)}, "read_failed")
    return candidates, sorted(consumers)


def _locate_variable_names(scope, destination):
    # Variable values exist only in this stack frame. Never persist the JSON or
    # forward it to the caller, including on decode and provider error paths.
    value = _decode(_locate_railway_run(
        ["variable", "list", "--service", destination["service"],
         "--environment", destination["environment"], "--json"], cwd=scope))
    if not isinstance(value, dict) or not all(isinstance(k, str) and isinstance(v, str)
                                            for k, v in value.items()):
        raise SecretEntryError("invalid_response")
    return set(value)


def _locate_railway(root, key, project_selector, service_selector, failures):
    candidates = []
    try:
        projects = _decode(_locate_railway_run(["list", "--json"], cwd=root))
        if not isinstance(projects, list):
            raise SecretEntryError("invalid_response")
    except (_LocateFailure, SecretEntryError) as error:
        _locate_failure(failures, "railway", {"account": "signed_in"},
                        error.reason if isinstance(error, _LocateFailure) else "invalid_response")
        return candidates
    selected_project = selected_service = False
    metadata_failure_count = len(failures)
    targets = []
    for index, project in enumerate(projects):
        scope = {"project_index": index}
        try:
            if not isinstance(project, dict):
                raise SecretEntryError("invalid_response")
            project_id = _uuid(project.get("id"))
            scope = {"project": project_id}
            if not _locate_matches(project, project_selector):
                continue
            selected_project = True
            if project.get("canAccess") is False:
                raise _LocateFailure("inaccessible")
            services = {_uuid(service.get("id")): service for service in _nodes(project.get("services"))}
            environments = _nodes(project.get("environments"))
        except (_LocateFailure, SecretEntryError) as error:
            _locate_failure(failures, "railway", scope,
                            error.reason if isinstance(error, _LocateFailure) else "invalid_response")
            continue
        for environment in environments:
            scope = {"project": project_id}
            try:
                environment_id = _uuid(environment.get("id"))
                scope["environment"] = environment_id
                if environment.get("canAccess") is False:
                    raise _LocateFailure("inaccessible")
                if environment.get("canAccess") is not True:
                    raise SecretEntryError("invalid_response")
                instances = _nodes(environment.get("serviceInstances"))
                seen = set()
                for instance in instances:
                    service_id = _uuid(instance.get("serviceId"))
                    if service_id in seen or service_id not in services:
                        raise SecretEntryError("invalid_response")
                    seen.add(service_id)
                    service = services[service_id]
                    if not _locate_matches(service, service_selector):
                        continue
                    selected_service = True
                    destination = {**scope, "service": service_id}
                    names = {field: name for field, node in (("project", project), ("environment", environment),
                                                             ("service", service))
                             if (name := _locate_name(node.get("name"))) is not None}
                    targets.append((destination, names))
            except (_LocateFailure, SecretEntryError) as error:
                _locate_failure(failures, "railway", scope,
                                error.reason if isinstance(error, _LocateFailure) else "invalid_response")
    metadata_complete = len(failures) == metadata_failure_count
    if project_selector is not None and not selected_project and metadata_complete:
        _locate_failure(failures, "railway", {"project": project_selector}, "target_not_found")
    if service_selector is not None and not selected_service and metadata_complete:
        scope = {"service": service_selector}
        if project_selector is not None:
            scope["project"] = project_selector
        _locate_failure(failures, "railway", scope, "target_not_found")
    if not targets:
        return candidates
    try:
        base, _ = _locate_private_base(root)
        base.mkdir(parents=True, mode=0o700, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="locate-", dir=base) as directory:
            scope_path = _safe_path(root, directory)
            os.chmod(scope_path, 0o700)
            _ignored(root, scope_path)
            for destination, names in targets:
                try:
                    linked = decode_link(_locate_railway_run(
                        ["link", "--project", destination["project"], "--environment", destination["environment"],
                         "--service", destination["service"], "--json"], cwd=scope_path))
                    if not isinstance(linked, dict) or any(linked.get(field + "Id") != destination[field]
                                                          for field in ("project", "environment", "service")):
                        raise SecretEntryError("wrong_destination")
                    _verify_project(_decode(_locate_railway_run(["status", "--json"], cwd=scope_path)), destination)
                    key_exists = key in _locate_variable_names(scope_path, destination)
                    if key_exists or project_selector is not None or service_selector is not None:
                        candidates.append({"provider": "railway", "destination": destination,
                                           "destination_names": names, "key_exists": key_exists})
                except (_LocateFailure, SecretEntryError) as error:
                    reason = error.reason if isinstance(error, _LocateFailure) else error.code
                    _locate_failure(failures, "railway", destination, reason)
    except (SecretEntryError, OSError) as error:
        reason = error.code if isinstance(error, SecretEntryError) else "storage_failed"
        _locate_failure(failures, "railway", {"root": str(root)}, reason)
    return candidates


def locate(root, key, *, project=None, service=None):
    """Discover metadata only; no destination is selected or authorized here."""
    root = _root(root)
    if not isinstance(key, str) or not _KEY.fullmatch(key):
        raise SecretEntryError("invalid_key")
    if any(value is not None and _locate_name(value) is None for value in (project, service)):
        raise SecretEntryError("invalid_arguments")
    failures = []
    candidates, consumers = _locate_files(root, key, failures)
    candidates.extend(_locate_railway(root, key, project, service, failures))
    return {"complete": not failures, "candidates": candidates, "failures": failures, "consumers": consumers}


def _file_state(path):
    if path.is_symlink():
        raise SecretEntryError("unsafe_path")
    try:
        info = path.stat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise SecretEntryError("unsafe_path")
    return {name: getattr(info, name) for name in _STAT_FIELDS}


def _dotenv_snapshot(path):
    before = _file_state(path)
    data = b"" if before is None else path.read_bytes()
    if before != _file_state(path):
        raise SecretEntryError("changed_file")
    try:
        text = data.decode("utf-8")
    except UnicodeError:
        raise SecretEntryError("invalid_dotenv") from None
    if any(char in text for char in "\0\v\f\x1c\x1d\x1e\x85\u2028\u2029"):
        raise SecretEntryError("invalid_dotenv")
    entries = {}
    for index, line in enumerate(text.splitlines(keepends=True)):
        match = _ASSIGNMENT.match(line.rstrip("\r\n"))
        if match:
            value = (match[2] or "").lstrip()
            if value.startswith(("'", '"')):
                quote, escaped, closed = value[0], False, False
                for char in value[1:]:
                    if escaped:
                        escaped = False
                    elif char == "\\":
                        escaped = True
                    elif char == quote:
                        closed = True
                        break
                if not closed:
                    # A line inside a multiline value can resemble KEY=value.
                    # This narrow writer must not misidentify or replace it.
                    raise SecretEntryError("invalid_dotenv")
            name = match[1]
            if name in entries:
                raise SecretEntryError("invalid_dotenv")
            entries[name] = index
    return {"state": before, "data": data, "entries": entries}


def _dotenv_check(root, destination, key):
    path = _safe_path(root, destination["file"])
    if not path.parent.is_dir() or path == root or (root / ".egregore" / "secret-entry") in path.parents:
        raise SecretEntryError("unsafe_path")
    if path.parent.stat().st_dev != (root / ".egregore" / "secret-entry").stat().st_dev:
        raise SecretEntryError("cross_device")
    _ignored(root, path)
    snapshot = _dotenv_snapshot(path)
    return key in snapshot["entries"], snapshot


def prepare(root, provider, key, *, project=None, environment=None, service=None, file=None):
    root = _root(root)
    if not isinstance(key, str) or not _KEY.fullmatch(key):
        raise SecretEntryError("invalid_key")
    if provider not in ("railway", "dotenv"):
        raise SecretEntryError("invalid_arguments")
    if provider == "railway":
        if file is not None:
            raise SecretEntryError("invalid_arguments")
        destination = {"project": _uuid(project), "environment": _uuid(environment), "service": _uuid(service)}
    else:
        if file is None or any(item is not None for item in (project, environment, service)):
            raise SecretEntryError("invalid_arguments")
        destination = {"file": str(_safe_path(root, file))}
    identifier = str(uuid4())
    scope = _private_scope(root, identifier, create=True)
    plan = {"schema_version": SCHEMA, "id": identifier, "status": "prepared", "provider": provider,
            "key": key, "root": str(root), "destination": destination, "prepared_at": _now(),
            "plan_path": str(scope / "plan.json")}
    if provider == "railway":
        plan["existing_key"], plan["destination_names"] = _railway_check(scope, destination, key)
    else:
        plan["existing_key"], snapshot = _dotenv_check(root, destination, key)
        plan["file_state"] = snapshot["state"]
    _write_json(scope / "plan.json", plan)
    return plan


def _load_plan(value):
    path = Path(os.path.abspath(value))
    if path.name != "plan.json" or not path.is_file() or path.is_symlink():
        raise SecretEntryError("invalid_plan")
    # Establish layout and scope before reading a file selected by an argument.
    identifier = _uuid(path.parent.name)
    if path.parent.parent.name != "secret-entry" or path.parent.parent.parent.name != ".egregore":
        raise SecretEntryError("invalid_plan")
    root = _root(path.parent.parent.parent.parent)
    scope = _private_scope(root, identifier)
    _safe_path(root, path)
    if path != scope / "plan.json" or path.stat().st_size > 16384:
        raise SecretEntryError("invalid_plan")
    plan = _decode(path.read_text(encoding="utf-8"))
    required = {"schema_version", "id", "status", "provider", "key", "root", "destination",
                "existing_key", "prepared_at", "plan_path"}
    if (not isinstance(plan, dict) or not required <= set(plan) or set(plan) - required - {"file_state", "destination_names"}
            or plan.get("schema_version") != SCHEMA or plan.get("status") != "prepared"
            or plan.get("id") != identifier or plan.get("root") != str(root) or plan.get("plan_path") != str(path)
            or type(plan.get("existing_key")) is not bool or not isinstance(plan.get("key"), str)
            or not _KEY.fullmatch(plan["key"]) or not isinstance(plan.get("destination"), dict)):
        raise SecretEntryError("invalid_plan")
    destination = plan["destination"]
    if plan["provider"] == "railway":
        if set(destination) != {"project", "environment", "service"} or "file_state" in plan:
            raise SecretEntryError("invalid_plan")
        for name, item in destination.items():
            if _uuid(item) != item:
                raise SecretEntryError("invalid_plan")
        # Stored display names are never authority. Refresh them from the
        # verified provider link before displaying any hidden-input prompt.
        plan["destination_names"] = {}
    elif plan["provider"] == "dotenv":
        if set(destination) != {"file"} or not isinstance(destination["file"], str) or "file_state" not in plan or "destination_names" in plan:
            raise SecretEntryError("invalid_plan")
        if str(_safe_path(root, destination["file"])) != destination["file"]:
            raise SecretEntryError("invalid_plan")
        state = plan["file_state"]
        if state is not None and (not isinstance(state, dict) or set(state) != set(_STAT_FIELDS)
                                  or any(type(v) is not int for v in state.values())):
            raise SecretEntryError("invalid_plan")
    else:
        raise SecretEntryError("invalid_plan")
    return root, scope, plan


def _destination_text(plan):
    destination = plan["destination"]
    if plan["provider"] == "dotenv":
        return "dotenv file " + destination["file"]
    names = plan.get("destination_names", {})
    return "Railway: " + " / ".join(
        f"{names[field]} ({field} {destination[field]})" if field in names
        else f"{field} {destination[field]}" for field in ("project", "environment", "service"))


def _has_tty():
    return sys.stdin.isatty() and sys.stderr.isatty()


def _dialog_script(prompt):
    escaped = prompt.replace("\\", "\\\\").replace('"', '\\"')
    return ('set resultDialog to display dialog "' + escaped + '" default answer "" with hidden answer '
            'buttons {"Cancel", "Save secret"} default button "Save secret" cancel button "Cancel" '
            'with title "Egregore secret entry"\ntext returned of resultDialog')


def _input_binary(name):
    # Explicit diagnostic/test override. This selects only an executable, never
    # command text or a secret. Platform/TTY checks cannot be overridden.
    return os.environ.get("EGREGORE_SECRET_ENTRY_" + name.upper(), "/usr/bin/" + name)


def probe(input_mode="auto"):
    """Never execute a dialog. Compilation cannot verify a visible window."""
    if input_mode not in {"auto", "dialog", "terminal"}:
        raise SecretEntryError("invalid_arguments")
    if input_mode == "terminal" or (input_mode == "auto" and sys.platform != "darwin" and _has_tty()):
        return ({"mode": "terminal", "verified": True} if _has_tty() else
                {"mode": "none", "verified": False, "reason": "no_tty"})
    if sys.platform != "darwin":
        return {"mode": "none", "verified": False, "reason": "not_darwin"}
    try:
        run([_input_binary("osacompile"), "-o", "/dev/null", "-e",
             _dialog_script("Egregore private input availability check")],
            cwd=Path.cwd(), private_input=True, compiling=True)
    except SecretEntryError as error:
        if input_mode == "auto" and _has_tty():
            return {"mode": "terminal", "verified": True}
        result = {"mode": "none", "verified": False, "reason": error.reason or "unknown"}
        if error.diagnostic_code is not None:
            result["code"] = error.diagnostic_code
        return result
    return {"mode": "dialog", "verified": False}


def read_secret(plan, input_mode):
    if input_mode not in {"auto", "dialog", "terminal"}:
        raise SecretEntryError("invalid_arguments")
    if input_mode == "auto" and sys.platform != "darwin":
        if not _has_tty():
            raise SecretEntryError("hidden_input_unavailable", reason="not_darwin")
        input_mode = "terminal"
    if input_mode == "terminal" and not _has_tty():
        raise SecretEntryError("hidden_input_unavailable", reason="no_tty")
    state = "Replace the existing value" if plan["existing_key"] else "Create this key"
    prompt = f"Save {plan['key']} to {_destination_text(plan)}. {state}. No deployment."
    if input_mode == "terminal":
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            try:
                return getpass.getpass(prompt + "\nSecret (hidden; Enter saves, Ctrl-C cancels): ")
            except EOFError:
                raise SecretEntryError("cancelled") from None
            except getpass.GetPassWarning:
                raise SecretEntryError("hidden_input_unavailable", reason="unknown" if _has_tty() else "no_tty") from None
            except OSError as error:
                raise SecretEntryError("hidden_input_unavailable", reason="unknown",
                                       diagnostic_code=error.errno) from None
    if sys.platform != "darwin":
        raise SecretEntryError("hidden_input_unavailable", reason="not_darwin")
    value = run([_input_binary("osascript"), "-e", _dialog_script(prompt)],
                cwd=Path(plan["root"]), timeout=600, private_input=True)
    # osascript contributes one output newline; preserve the actual input.
    return value[:-1] if value.endswith("\n") else value


def _receipt(plan, status, reason=None, code=None):
    result = {"id": plan["id"], "provider": plan["provider"], "key": plan["key"],
              "destination": plan["destination"], "timestamp": _now(), "status": status}
    if reason is not None:
        result["reason"] = reason
    if reason == "unknown" and type(code) is int:
        result["code"] = code
    return result


def _same_file(path, snapshot):
    if _file_state(path) != snapshot["state"]:
        return False
    return (b"" if snapshot["state"] is None else path.read_bytes()) == snapshot["data"]


def _dotenv_save(root, destination, key, secret, snapshot, mark_attempt, staging):
    # Existing Egregore readers consume the literal text after '='. Quoting or
    # shell escaping would alter credentials even for ordinary API tokens.
    if (secret != secret.strip() or secret.startswith(("'", '"')) or secret.endswith(("'", '"'))
            or "${" in secret or re.search(r"\s#", secret)):
        raise SecretEntryError("unsupported_dotenv_value")
    path = _safe_path(root, destination["file"])
    _ignored(root, path)
    lines = snapshot["data"].decode("utf-8").splitlines(keepends=True)
    # grep/cut based readers preserve CR. Only the written key uses LF;
    # unrelated existing lines retain their exact original line endings.
    newline = "\n"
    replacement = f"{key}={secret}"
    if key in snapshot["entries"]:
        index = snapshot["entries"][key]
        suffix = "\n" if lines[index].endswith(("\r", "\n")) else ""
        lines[index] = replacement + suffix
    else:
        if lines and not lines[-1].endswith(("\n", "\r")):
            lines[-1] += newline
        lines.append(replacement + newline)
    data = "".join(lines).encode("utf-8")
    staging = _safe_path(root, staging)
    if path.parent.stat().st_dev != staging.stat().st_dev:
        raise SecretEntryError("cross_device")
    # A killed process can leave this file behind. Keep all secret-bearing
    # temporary data inside the same ignored, private plan scope.
    descriptor, temporary = tempfile.mkstemp(prefix="dotenv-", dir=staging)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            _ignored(root, Path(temporary))
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        _safe_path(root, path)
        if not _same_file(path, snapshot):
            raise SecretEntryError("changed_file")
        mark_attempt()
        # Persisting the attempt is another I/O window; check again after it.
        _safe_path(root, path)
        if not _same_file(path, snapshot):
            raise SecretEntryError("changed_file")
        if snapshot["state"] is None:
            os.link(temporary, path)  # Atomic create; never replace a newly appeared file.
            os.unlink(temporary)
        else:
            os.replace(temporary, path)
        if path.is_symlink() or path.read_bytes() != data or stat.S_IMODE(path.stat().st_mode) != 0o600:
            raise SecretEntryError("verification_failed")
        # Read the literal value exactly; never source, eval, unquote or expand.
        stored = _dotenv_snapshot(path)
        line = stored["data"].decode("utf-8").splitlines()[stored["entries"][key]]
        value = line.split("=", 1)[1]
        if not hmac.compare_digest(value.encode("utf-8"), secret.encode("utf-8")):
            raise SecretEntryError("verification_failed")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply(plan_path, *, input_mode="auto"):
    root, scope, plan = _load_plan(plan_path)
    if input_mode not in ("auto", "dialog", "terminal"):
        raise SecretEntryError("invalid_arguments")
    lock_paths = [scope / "apply.lock"]
    if plan["provider"] == "dotenv":
        # Plans share this lock so two writers cannot both replace a snapshot
        # of the same dotenv file. The second revalidates after the first saves.
        lock_paths.append(scope.parent / "dotenv.lock")
    with ExitStack() as locks:
        for candidate in lock_paths:
            lock_path = _safe_path(root, candidate)
            _ignored(root, lock_path)
            descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            lock = locks.enter_context(os.fdopen(descriptor, "a"))
            fcntl.flock(lock, fcntl.LOCK_EX)
        root, scope, plan = _load_plan(plan_path)
        receipt_path = _safe_path(root, scope / "receipt.json")
        if receipt_path.exists():
            previous = _decode(receipt_path.read_text(encoding="utf-8"))
            if (not isinstance(previous, dict)
                    or set(previous) - {"id", "provider", "key", "destination", "timestamp", "status", "reason", "code"}
                    or previous.get("status") not in {"saved", "not_written", "write_attempted_unverified"}
                    or any(previous.get(key) != plan[key] for key in ("id", "provider", "key", "destination"))
                    or not isinstance(previous.get("timestamp"), str)
                    or ("reason" in previous and previous["reason"] not in _REASONS.keys() | _INPUT_REASONS)
                    or ("code" in previous and (type(previous["code"]) is not int or previous.get("reason") != "unknown"))):
                raise SecretEntryError("invalid_plan")
            try:
                datetime.fromisoformat(previous["timestamp"])
            except ValueError:
                raise SecretEntryError("invalid_plan") from None
            # The only fallback is an unavailable private input before a write.
            # Cancellation and uncertain writes must never open another prompt.
            if previous["status"] != "not_written" or previous.get("reason") not in _INPUT_REASONS | {"hidden_input_unavailable"}:
                return previous
        attempted = False

        def mark_attempt():
            nonlocal attempted
            _write_json(receipt_path, _receipt(plan, "write_attempted_unverified", "verification_failed"))
            attempted = True

        try:
            if plan["provider"] == "railway":
                existing, plan["destination_names"] = _railway_check(scope, plan["destination"], plan["key"])
                snapshot = None
            else:
                existing, snapshot = _dotenv_check(root, plan["destination"], plan["key"])
                if snapshot["state"] != plan["file_state"]:
                    raise SecretEntryError("changed_file")
            if existing != plan["existing_key"]:
                raise SecretEntryError("changed_destination")
            secret = read_secret(plan, input_mode)
            if not isinstance(secret, str) or not secret or any(char in secret for char in "\0\r\n\v\f\x1c\x1d\x1e\x85\u2028\u2029"):
                raise SecretEntryError("invalid_secret")
            if plan["provider"] == "railway":
                destination = plan["destination"]
                # A hidden-input dialog may stay open for several minutes.
                # Revalidate again before the write while holding this plan lock.
                fresh_existing, fresh_names = _railway_check(scope, destination, plan["key"])
                if fresh_existing != plan["existing_key"] or fresh_names != plan["destination_names"]:
                    raise SecretEntryError("changed_destination")
                mark_attempt()
                run(["railway", "variable", "set", plan["key"], "--service", destination["service"],
                     "--environment", destination["environment"], "--stdin", "--skip-deploys", "--json"],
                    cwd=scope, input=secret)
                stored = _railway_variables(scope, destination).get(plan["key"])
                if not isinstance(stored, str) or not hmac.compare_digest(stored.encode("utf-8"), secret.encode("utf-8")):
                    raise SecretEntryError("verification_failed")
            else:
                _dotenv_save(root, plan["destination"], plan["key"], secret, snapshot, mark_attempt, scope)
            receipt = _receipt(plan, "saved")
        except KeyboardInterrupt:
            receipt = _receipt(plan, "write_attempted_unverified" if attempted else "not_written",
                               "verification_failed" if attempted else "cancelled")
        except (SecretEntryError, OSError, UnicodeError, ValueError) as error:
            reason = (error.reason or error.code) if isinstance(error, SecretEntryError) else "storage_failed"
            receipt = _receipt(plan, "write_attempted_unverified" if attempted else "not_written",
                               "verification_failed" if attempted else reason,
                               error.diagnostic_code if isinstance(error, SecretEntryError) and not attempted else None)
        try:
            _write_json(receipt_path, receipt)
        except (SecretEntryError, OSError, UnicodeError, ValueError):
            # An earlier durable attempted receipt blocks accidental repetition.
            # Never report "not written" merely because final receipt storage failed.
            return _receipt(plan, "write_attempted_unverified" if attempted else "not_written",
                            "verification_failed" if attempted else "storage_failed")
        return receipt


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally echoes unknown arguments; never echo a mistakenly
        # supplied --value SECRET or positional credential.
        raise SecretEntryError("invalid_arguments")


def main(argv=None):
    parser = _Parser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True, parser_class=_Parser)
    probing = commands.add_parser("probe", help="Check private input availability without opening a dialog")
    probing.add_argument("--input", choices=("auto", "dialog", "terminal"), default="auto")
    locating = commands.add_parser("locate", help="Discover non-secret destinations and consumers; never authorize a write")
    locating.add_argument("--key", required=True)
    locating.add_argument("--root", default=os.getcwd())
    locating.add_argument("--project")
    locating.add_argument("--service")
    preparing = commands.add_parser("prepare", help="Verify and record a non-secret destination plan")
    preparing.add_argument("--provider", required=True, choices=("railway", "dotenv"))
    preparing.add_argument("--key", required=True)
    preparing.add_argument("--root", default=os.getcwd())
    for name in ("project", "environment", "service", "file"):
        preparing.add_argument("--" + name)
    applying = commands.add_parser("apply", help="Revalidate, prompt privately, save and verify")
    applying.add_argument("--plan", required=True)
    applying.add_argument("--input", choices=("auto", "dialog", "terminal"), default="auto")
    try:
        args = parser.parse_args(argv)
        if args.command == "probe":
            result = probe(args.input)
        elif args.command == "locate":
            result = locate(args.root, args.key, project=args.project, service=args.service)
        elif args.command == "prepare":
            result = prepare(args.root, args.provider, args.key, project=args.project,
                             environment=args.environment, service=args.service, file=args.file)
        else:
            result = apply(args.plan, input_mode=args.input)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        if args.command == "probe":
            return 0 if result["mode"] != "none" else 1
        if args.command == "locate":
            return 0 if result["complete"] else 1
        return 0 if result["status"] in ("prepared", "saved") else 1
    except (SecretEntryError, OSError, UnicodeError, ValueError, KeyboardInterrupt) as error:
        code = error.code if isinstance(error, SecretEntryError) else "cancelled" if isinstance(error, KeyboardInterrupt) else "storage_failed"
        reason = (error.reason or code) if isinstance(error, SecretEntryError) else code
        result = {"status": "not_written", "reason": reason, "message": _REASONS[code]}
        if isinstance(error, SecretEntryError) and error.diagnostic_code is not None:
            result["code"] = error.diagnostic_code
        print(json.dumps(result))
        return 1
