"""Read-only facts about a host-selected outgoing canonical Git history.

This module neither authorizes publication nor proves remote freshness. It reads
the complete selected ancestry, newly reachable objects and changed tree paths.
Manual Git and transports which do not call it remain outside this prerequisite.
"""
from __future__ import annotations

from dataclasses import dataclass
from contextlib import contextmanager
from contextvars import ContextVar
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import time
import unicodedata

from .record_subject import classify_record


@dataclass(frozen=True)
class HistoryLimits:
    commits: int = 256
    objects: int = 4096
    object_bytes: int = 256 * 1024
    total_bytes: int = 16 * 1024 * 1024
    tree_entries: int = 8192
    seconds: float = 20


DEFAULT_LIMITS = HistoryLimits()
OID = re.compile(r"(?:[a-f0-9]{40}|[a-f0-9]{64})\Z")
_CONTAINED_GIT = ContextVar("egregore_host_contained_git", default=False)


@contextmanager
def contained_git_children():
    """Fixed detached host owns the outer process group, including Git helpers.

    Private native host workers opt in directly; no environment or public CLI
    input selects this. Generic managed/history callers keep detached children.
    The host must terminate its whole outer group even after normal completion.
    """
    if os.getpgrp() != os.getpid():
        raise ValueError("contained Git requires a detached process-group owner")
    token = _CONTAINED_GIT.set(True)
    try:
        yield
    finally:
        _CONTAINED_GIT.reset(token)


class _Unknown(Exception):
    pass


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _ref(value, *, head=False):
    if head and value == "HEAD":
        return True
    return (isinstance(value, str) and len(value) <= 240
            and value.startswith(("refs/heads/", "refs/remotes/"))
            and not re.search(r"[\x00-\x20\x7f~^:?*\[\\]", value)
            and ".." not in value and "@{" not in value
            and all(part and not part.startswith(".") and not part.endswith((".", ".lock")) for part in value.split("/")))


def _regular(path, limit=65536):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
        raise _Unknown("unsupported_repository")
    with path.open("rb") as handle:
        value = handle.read(limit + 1)
    if len(value) > limit:
        raise _Unknown("unsupported_repository")
    return value


def _repository(repository, deadline):
    def remaining():
        if time.monotonic() >= deadline:
            raise _Unknown("time_limit")
    remaining()
    root = Path(repository)
    if not root.is_absolute() or root != root.resolve() or not root.is_dir() or any(ord(c) < 32 for c in str(root)):
        raise _Unknown("unsupported_repository")
    dot = root / ".git"
    git_dir = dot if dot.is_dir() else root
    if dot.exists() and (dot.is_symlink() or not dot.is_dir()):
        raise _Unknown("unsupported_repository")  # Linked worktrees need a separate host binding.
    config = _regular(git_dir / "config")
    _regular(git_dir / "HEAD")
    if (git_dir / "commondir").exists() or re.search(rb"(?im)^\s*\[\s*include(?:if)?\b|\b(?:partialclone|promisor)\s*=", config):
        raise _Unknown("unsupported_repository")
    for name in ("shallow", "info/grafts", "objects/info/alternates", "objects/info/http-alternates"):
        target = git_dir / name
        for parent in target.parents:
            if parent == git_dir:
                break
            if parent.is_symlink():
                raise _Unknown("unsupported_repository")
        if target.exists() or target.is_symlink():
            if _regular(target).strip():
                raise _Unknown("incomplete_repository")
    objects = git_dir / "objects"
    if not objects.is_dir() or objects.is_symlink():
        raise _Unknown("unsupported_repository")
    # Git may consult pack indexes and commit graphs without naming each file
    # in its output. Do not allow those metadata paths to lead to another repo.
    metadata_entries = 0
    def metadata_tree(directory, depth=0):
        nonlocal metadata_entries
        with os.scandir(directory) as stream:
            for entry in stream:
                remaining()
                metadata_entries += 1
                if metadata_entries > 512 or entry.is_symlink():
                    raise _Unknown("unsupported_repository")
                if entry.is_dir(follow_symlinks=False):
                    if depth >= 2:
                        raise _Unknown("unsupported_repository")
                    metadata_tree(Path(entry.path), depth + 1)
                elif not entry.is_file(follow_symlinks=False):
                    raise _Unknown("unsupported_repository")
    with os.scandir(objects) as stream:
        for index, entry in enumerate(stream):
            remaining()
            if index >= 258 or entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                raise _Unknown("unsupported_repository")
            if entry.name in {"info", "pack"}:
                metadata_tree(Path(entry.path))
            elif not re.fullmatch(r"[a-f0-9]{2}", entry.name):
                raise _Unknown("unsupported_repository")
    return root, git_dir


class _Git:
    def __init__(self, root, deadline):
        self.root, self.deadline = root, deadline
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0",
                        GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1", LC_ALL="C")

    def start(self, args, *, stdin=False):
        self.remaining()
        contained = _CONTAINED_GIT.get()
        process = subprocess.Popen(["git", "--no-replace-objects", "-c", "protocol.allow=never",
                                 "-c", "core.fsmonitor=false", "-c", "core.hooksPath=" + os.devnull,
                                 "-C", str(self.root), *args],
                                stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=self.env, start_new_session=not contained, bufsize=0)
        process._egregore_contained = contained
        return process

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise _Unknown("time_limit")
        return remaining

    @staticmethod
    def close(process):
        if process.poll() is None:
            try:
                if getattr(process, "_egregore_contained", False):
                    process.kill()
                else:
                    os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                # Some hosts prohibit process-group signals while permitting
                # termination of this exact child. These plumbing commands do
                # not launch filters, hooks, pagers or transport helpers.
                process.kill()
        process.wait()
        if process.stdin:
            process.stdin.close()
        process.stdout.close()

    def read(self, process, count):
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            if not selector.select(self.remaining()):
                raise _Unknown("time_limit")
        return os.read(process.stdout.fileno(), count)

    def run(self, *args, limit=262144, allowed=(0,)):
        process = self.start(args)
        output = bytearray()
        try:
            while True:
                chunk = self.read(process, min(65536, limit + 1 - len(output)))
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > limit:
                    raise _Unknown("inventory_limit")
            code = process.wait(timeout=self.remaining())
            if code not in allowed:
                raise _Unknown("git_evidence_unavailable")
            return bytes(output), code
        finally:
            self.close(process)


class _Objects:
    """One size-aware cat-file protocol process; never buffer an unlimited body."""
    def __init__(self, git, git_dir, limits, counts):
        self.git, self.git_dir, self.limits, self.counts = git, git_dir, limits, counts
        self.process = git.start(["cat-file", "--batch"], stdin=True)
        self.buffer, self.cache = bytearray(), {}

    def exact(self, size):
        while len(self.buffer) < size:
            chunk = self.git.read(self.process, min(65536, size - len(self.buffer)))
            if not chunk:
                raise _Unknown("object_unavailable")
            self.buffer.extend(chunk)
        value = bytes(self.buffer[:size]); del self.buffer[:size]
        return value

    def get(self, oid):
        self.git.remaining()
        if oid in self.cache:
            return self.cache[oid]
        if len(self.cache) >= self.limits.objects:
            raise _Unknown("object_limit")
        loose = self.git_dir / "objects" / oid[:2] / oid[2:]
        if loose.is_symlink():
            raise _Unknown("unsupported_repository")
        self.process.stdin.write(oid.encode() + b"\n")
        header = bytearray()
        while not header.endswith(b"\n"):
            if len(header) >= 128:
                raise _Unknown("object_unavailable")
            header.extend(self.exact(1))
        fields = header.split()
        if len(fields) != 3 or fields[0].decode("ascii") != oid or fields[1] not in (b"commit", b"tree", b"blob"):
            raise _Unknown("object_unavailable")
        size = int(fields[2])
        if size < 0 or size > self.limits.object_bytes:
            raise _Unknown("object_byte_limit")
        if self.counts["bytes"] + size > self.limits.total_bytes:
            raise _Unknown("total_byte_limit")
        value = self.exact(size)
        if self.exact(1) != b"\n":
            raise _Unknown("object_unavailable")
        algorithm = hashlib.sha1 if len(oid) == 40 else hashlib.sha256
        if algorithm(fields[1] + b" " + str(size).encode() + b"\0" + value).hexdigest() != oid:
            raise _Unknown("object_corrupt")
        self.counts["objects"] += 1; self.counts["bytes"] += size
        result = fields[1].decode(), value
        self.cache[oid] = result
        return result

    def close(self):
        self.git.close(self.process)


def _tree(value, oid_bytes):
    offset, names, entries = 0, set(), {}
    while offset < len(value):
        end = value.find(b"\0", offset)
        if end < 0 or end + 1 + oid_bytes > len(value):
            raise _Unknown("malformed_tree")
        prefix = value[offset:end]
        mode, sep, raw_name = prefix.partition(b" ")
        if not sep or mode not in (b"40000", b"100644", b"100755"):
            raise _Unknown("unsupported_tree_entry")
        name = raw_name.decode("utf-8")
        folded = unicodedata.normalize("NFC", name).casefold()
        if (not name or name in (".", "..") or folded == ".git" or "/" in name or "\\" in name
                or len(raw_name) > 255 or any(ord(c) < 32 or ord(c) == 127 for c in name)
                or name != unicodedata.normalize("NFC", name) or folded in names):
            raise _Unknown("ambiguous_tree_path")
        entries[name] = (mode.decode(), value[end + 1:end + 1 + oid_bytes].hex())
        names.add(folded); offset = end + 1 + oid_bytes
    return entries


def _commit(value, oid_length):
    header, sep, _ = value.partition(b"\n\n")
    if not sep or b"\0" in header:
        raise _Unknown("malformed_commit")
    lines = header.splitlines()
    trees = [line[5:] for line in lines if line.startswith(b"tree ")]
    parents = [line[7:] for line in lines if line.startswith(b"parent ")]
    if len(trees) != 1 or not lines or lines[0] != b"tree " + trees[0]:
        raise _Unknown("malformed_commit")
    refs = [oid.decode("ascii") for oid in trees + parents]
    if any(not OID.fullmatch(oid) or len(oid) != oid_length for oid in refs):
        raise _Unknown("malformed_commit")
    return refs[0], refs[1:]


def _subject(value):
    # Native canonical records start with frontmatter. Arbitrary prose or body
    # code examples are not a native record marker and are never promoted here.
    if not value.startswith((b"---", b"\xef\xbb\xbf---")):
        return None
    text = value.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n").removeprefix("\ufeff")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    fields, closed, malformed, marked, block_indent = {}, False, False, False, None
    container = False
    for line in lines[1:]:
        if line == "---":
            closed = True; break
        indent = len(line) - len(line.lstrip(" "))
        if block_indent is not None:
            parent_indent, content_indent = block_indent
            if not line.strip():
                continue
            if content_indent is None and indent > parent_indent:
                content_indent = indent
                block_indent = (parent_indent, content_indent)
            if content_indent is not None and indent >= content_indent:
                continue  # An explicit YAML block scalar is prose, not fields.
            block_indent = None
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, sep, raw = line.partition(":")
        if sep and classify_record({key: raw.strip().strip("\"'")}) != "human-session":
            marked = True
        if indent or line.startswith("-"):
            # Common YAML lists and nested values are valid human frontmatter.
            # A marker with malformed indentation still remains native-marked.
            if not container or "\t" in line[:indent + 1]:
                malformed = True
            continue
        if not sep or key in fields or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*|\"[^\"\n]+\"|'[^'\n]+'", key):
            malformed = True
        if sep:
            scalar_text = raw.strip()
            container = not scalar_text or scalar_text.startswith(("[", "{"))
            if re.fullmatch(r"[|>][1-9]?[+-]?(?:\s+#.*)?|[|>][+-][1-9](?:\s+#.*)?", scalar_text):
                explicit = re.search(r"[1-9]", scalar_text.split("#", 1)[0])
                block_indent = (indent, indent + int(explicit[0]) if explicit else None)
            try:
                scalar = json.loads(scalar_text)
            except ValueError:
                scalar = scalar_text
            fields[key] = scalar
    subject = classify_record(fields)
    if marked and subject == "human-session":
        subject = "unsupported-native"
    if subject != "human-session":
        return subject if closed and not malformed else "unsupported-native"
    if not closed or malformed:
        raise _Unknown("ambiguous_record_header")
    return None


def inspect_outgoing_history(repository, *, base_oid, head_oid, base_ref, head_ref, limits=DEFAULT_LIMITS):
    """Inspect exact local selections. A returned fact is never a SHARE grant.

    Every newly reachable ancestor blob remains inspected even if the tip later
    replaces, renames or deletes its path. Changed paths in every outgoing
    commit are also inspected on both sides, including blobs reused from base.
    Unchanged base subtrees are excluded. Local ref equality is checked twice;
    a transport must still obtain fresh destination and source-CAS admission.
    An explicitly absent base (both base fields None) scans all head history;
    it does not prove a remote branch is absent.
    """
    initial = base_oid is None and base_ref is None
    object_base = base_oid is not None and base_ref is None
    binding = {"repository_fingerprint": None, "base_oid": base_oid if isinstance(base_oid, str) and OID.fullmatch(base_oid) else None,
               "head_oid": head_oid if isinstance(head_oid, str) and OID.fullmatch(head_oid) else None,
               "base_ref": base_ref if _ref(base_ref) else None, "head_ref": head_ref if _ref(head_ref, head=True) else None,
               "object_format": None, "range_kind": "initial-history" if initial else "outgoing-range",
               "base_witness": "absent-selection" if initial else "object-only" if object_base else "local-ref"}
    counts = {"commits": 0, "objects": 0, "bytes": 0, "tree_entries": 0, "path_checks": 0, "native_blobs": 0}
    native, reasons, objects, classified = [], [], None, set()
    try:
        if (not isinstance(limits, HistoryLimits) or any(type(getattr(limits, key)) is not int or not 1 <= getattr(limits, key) <= getattr(DEFAULT_LIMITS, key)
                for key in ("commits", "objects", "object_bytes", "total_bytes", "tree_entries"))
                or type(limits.seconds) not in (float, int) or not 0 < limits.seconds <= DEFAULT_LIMITS.seconds):
            raise _Unknown("invalid_limits")
        required = ("head_oid", "head_ref") if initial else ("base_oid", "head_oid", "head_ref") if object_base else ("base_oid", "head_oid", "base_ref", "head_ref")
        if any(binding[key] is None for key in required) or not initial and len(base_oid) != len(head_oid):
            raise _Unknown("invalid_selection")
        deadline = time.monotonic() + limits.seconds
        root, git_dir = _repository(repository, deadline)
        binding["repository_fingerprint"] = _digest({"repository": str(root), "git_dir": str(git_dir)})
        git = _Git(root, deadline)
        def check_refs():
            selections = [(head_ref, head_oid)] if initial or object_base else [(base_ref, base_oid), (head_ref, head_oid)]
            for ref, expected in selections:
                # Follow only bounded, validated symbolic-ref spellings before
                # asking Git to resolve them. HEAD must not hide a ref symlink.
                target, seen = ref, set()
                while True:
                    if target in seen or len(seen) >= 8:
                        raise _Unknown("ambiguous_range")
                    seen.add(target)
                    parts = ("HEAD",) if target == "HEAD" else tuple(target.split("/"))
                    selected = git_dir
                    for part in parts:
                        selected /= part
                        if selected.is_symlink():
                            raise _Unknown("unsupported_repository")
                    if not selected.exists():
                        break  # Git may find this exact ref in packed-refs.
                    value = _regular(selected, 1024).strip()
                    if not value.startswith(b"ref: "):
                        break
                    target = value[5:].decode("ascii")
                    if not _ref(target):
                        raise _Unknown("ambiguous_range")
                if (git_dir / "packed-refs").is_symlink():
                    raise _Unknown("unsupported_repository")
                raw, _ = git.run("rev-parse", "--verify", ref, limit=256)
                if raw.strip().decode("ascii") != expected:
                    raise _Unknown("stale_ref_binding")
        check_refs()
        fmt, _ = git.run("rev-parse", "--show-object-format", limit=32)
        binding["object_format"] = fmt.strip().decode("ascii")
        if binding["object_format"] != ("sha1" if len(head_oid) == 40 else "sha256"):
            raise _Unknown("invalid_selection")
        objects = _Objects(git, git_dir, limits, counts)
        if any(objects.get(oid)[0] != "commit" for oid in ([head_oid] if initial else [base_oid, head_oid])):
            raise _Unknown("invalid_selection")
        if not initial:
            _, code = git.run("merge-base", "--is-ancestor", base_oid, head_oid, allowed=(0, 1), limit=0)
            if code:
                raise _Unknown("non_ancestor_base")
        selected_range = [head_oid] if initial else [head_oid, "^" + base_oid]
        raw, _ = git.run("rev-list", f"--max-count={limits.commits + 1}", *selected_range, "--",
                         limit=(limits.commits + 1) * (len(head_oid) + 1))
        commits = raw.decode("ascii").splitlines()
        if len(commits) > limits.commits:
            raise _Unknown("commit_limit")
        if any(not OID.fullmatch(oid) or len(oid) != len(head_oid) for oid in commits) or len(set(commits)) != len(commits):
            raise _Unknown("ambiguous_range")
        counts["commits"] = len(commits)
        try:
            raw, _ = git.run("rev-list", "--objects", "--no-object-names", *selected_range, "--",
                             limit=(limits.objects + 1) * (len(head_oid) + 1))
        except _Unknown as exc:
            if str(exc) == "inventory_limit":
                raise _Unknown("object_limit") from exc
            raise
        outgoing = raw.decode("ascii").splitlines()
        if len(outgoing) > limits.objects:
            raise _Unknown("object_limit")
        if len(set(outgoing)) != len(outgoing) or any(not OID.fullmatch(oid) or len(oid) != len(head_oid) for oid in outgoing) or not set(commits) <= set(outgoing):
            raise _Unknown("ambiguous_range")
        trees, commit_trees = {}, {}

        def inspect_blob(oid):
            if oid in classified:
                return
            kind, value = objects.get(oid)
            if kind != "blob":
                raise _Unknown("malformed_tree")
            classified.add(oid)
            subject = _subject(value)
            if subject:
                counts["native_blobs"] += 1
                if len(native) < 32:
                    native.append({"oid": oid, "subject_kind": subject})

        def tree(oid):
            if oid is None:
                return {}
            if oid not in trees:
                kind, value = objects.get(oid)
                if kind != "tree":
                    raise _Unknown("malformed_tree")
                entries = _tree(value, len(oid) // 2)
                counts["tree_entries"] += len(entries)
                if counts["tree_entries"] > limits.tree_entries:
                    raise _Unknown("tree_entry_limit")
                trees[oid] = entries
            return trees[oid]

        def commit(oid):
            if oid not in commit_trees:
                kind, value = objects.get(oid)
                if kind != "commit":
                    raise _Unknown("malformed_commit")
                commit_trees[oid] = _commit(value, len(oid))
            return commit_trees[oid]

        for oid in outgoing:
            kind, value = objects.get(oid)
            if kind == "tree":
                tree(oid)
            elif kind == "blob":
                inspect_blob(oid)
            elif kind == "commit":
                commit(oid)
        # Object exclusion alone misses a new path which reuses a base blob.
        # Compare each selected commit with its first parent, but enumerate ALL
        # selected ancestry above. Side-branch ancestors therefore still count.
        # This is intentionally conservative about removed/renamed preimages.
        for oid in commits:
            after, parents = commit(oid)
            before = commit(parents[0])[0] if parents else None
            stack = [(before, after, "")]
            while stack:
                git.remaining()
                old_oid, new_oid, prefix = stack.pop()
                if old_oid == new_oid:
                    continue
                old, new = tree(old_oid), tree(new_oid)
                for name in sorted(old.keys() | new.keys()):
                    counts["path_checks"] += 1
                    if counts["path_checks"] > limits.tree_entries:
                        raise _Unknown("path_check_limit")
                    left, right = old.get(name), new.get(name)
                    if left == right:
                        continue
                    path = prefix + name
                    if len(path.encode()) > 4096 or path.count("/") >= 256:
                        raise _Unknown("ambiguous_tree_path")
                    for entry in (left, right):
                        if entry and entry[0] != "40000":
                            inspect_blob(entry[1])
                    left_tree = left[1] if left and left[0] == "40000" else None
                    right_tree = right[1] if right and right[0] == "40000" else None
                    if left_tree != right_tree:
                        stack.append((left_tree, right_tree, path + "/"))
        check_refs()
    except _Unknown as exc:
        reasons.append(str(exc))
    except (OSError, ValueError, UnicodeError, TypeError, OverflowError, RecursionError, subprocess.TimeoutExpired):
        reasons.append("git_evidence_unavailable")
    finally:
        if objects:
            objects.close()
    result = {"schema": "egregore.native-outgoing-history/v1", "status": "unknown" if reasons else "present" if native else "none",
              "complete": not reasons, "binding": binding, "counts": counts, "native_blobs": sorted(native, key=lambda row: row["oid"]),
              "examples_truncated": counts["native_blobs"] > len(native), "reasons": reasons,
              "remote_freshness": "not_checked", "publication_authority": False}
    return {**result, "digest": _digest(result)}
