from dataclasses import dataclass, replace
import json
import hashlib
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess


PRINCIPAL_KINDS = ("person", "agent", "egregore")


@dataclass(frozen=True, slots=True)
class Principal:
    handle: str
    kind: str = ""
    identity: str = ""
    read: tuple[str, ...] = ()
    append: tuple[str, ...] = ()
    file_kb: int = 64
    per_day: int = 50
    problem: str | None = None


@dataclass(frozen=True, slots=True)
class AuthorizationInputs:
    policy: str
    admins: frozenset[str]
    removed: frozenset[str]
    memory_root: Path
    source: str = "working-tree"
    problem: str | None = None
    org_id: str = ""
    principals: tuple[Principal, ...] = ()
    principals_problem: str | None = None
    released: tuple[str, ...] = ()
    memory_revision: str = ""
    base: str = ""
    settings: str = ""  # the egregore.json text these inputs were read from


SHARED_SETTINGS_UNREADABLE = "the shared settings could not be read; nothing was handed over"
ROOT_MARKER = ".egregore-read-only"  # names a projection root (``access materialize``)
PROJECTION_ROOT = "projection-root"
_BRANCH = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,199}")


def _identity(kind: str, identity: str) -> str:
    identity = identity.strip().casefold()
    return identity.removeprefix("@") if kind in {"person", "agent"} else identity


def _principal_row(key: str, value: object, org_id: str) -> Principal:
    # policy imports access; defer this import to avoid a module initialization cycle.
    from .policy import _canonical_parts

    handle, problems, fields = key.strip().casefold(), [], {}
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,63}", handle):
        problems.append("handle is invalid")
    if not isinstance(value, dict):
        return Principal(handle, problem="; ".join([*problems, "row must be an object"]))
    if "write" in value:
        problems.append("outside principals cannot hold write; use append")
    for name in sorted(value.keys() - {"kind", "identity", "read", "append", "limits", "write"}):
        problems.append(f"unknown field {name}")
    kind = value.get("kind", "")
    fields["kind"] = kind if isinstance(kind, str) else ""
    if kind not in PRINCIPAL_KINDS:
        problems.append("kind must be person, agent or egregore")
    identity = value.get("identity")
    fields["identity"] = _identity(fields["kind"], identity) if isinstance(identity, str) else ""
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.:-]{0,127}", fields["identity"]):
        problems.append("identity must be a nonempty valid identity")
    elif kind == "egregore" and (fields["identity"].startswith("legacy-org:") or fields["identity"] == org_id.casefold()):
        problems.append("identity must be another organization's stable org id")
    for name in ("read", "append"):
        prefixes = value.get(name, [])
        canonical = []
        if not isinstance(prefixes, list):
            problems.append(f"{name} must be a list of memory prefixes")
        else:
            for prefix in prefixes:
                parts = _canonical_parts(prefix) if isinstance(prefix, str) else None
                if not parts or parts[0] != "memory" or _canonical_parts("/".join(parts)) != parts:
                    problems.append(f"{name} contains an invalid memory prefix")
                elif (normalized := "/".join(parts)) not in canonical:
                    canonical.append(normalized)
        fields[name] = tuple(canonical)
    limits = value.get("limits", {})
    if not isinstance(limits, dict):
        problems.append("limits must be an object")
    else:
        for name, limit in limits.items():
            if name not in {"file_kb", "per_day"}:
                problems.append(f"unknown limits field {name}")
            elif type(limit) is not int or limit <= 0:
                problems.append(f"limits.{name} must be a positive integer")
            else:
                fields[name] = limit
    return Principal(handle, **fields, problem="; ".join(dict.fromkeys(problems)) or None)


def _principals(config: dict, org_id: str, admins: frozenset[str]) -> tuple[tuple[Principal, ...], str | None]:
    access = config.get("access", {})
    rows = access.get("principals", {}) if isinstance(access, dict) else None
    if not isinstance(rows, dict):
        return (), "the access settings could not be read"
    parsed = tuple(_principal_row(key, value, org_id) for key, value in sorted(rows.items()))
    result = []
    for row in parsed:
        problems = [row.problem] if row.problem else []
        if sum(other.handle == row.handle for other in parsed) > 1:
            problems.append("handle is defined more than once")
        if row.identity and sum((other.kind, other.identity) == (row.kind, row.identity) for other in parsed) > 1:
            problems.append("identity is claimed by more than one principal")
        if row.handle in admins:
            problems.append("handle is also an admin")
        result.append(replace(row, problem="; ".join(problems) or None))
    return tuple(result), None


def principal(inputs: AuthorizationInputs, handle: str) -> Principal | None:
    if inputs.principals_problem:
        return None
    return next((row for row in inputs.principals if row.handle == handle.strip().casefold()), None)


def principal_by_identity(inputs: AuthorizationInputs, kind: str, identity: str) -> Principal | None:
    if inputs.principals_problem:
        return None
    normalized = _identity(kind, identity)
    return next((row for row in inputs.principals if row.kind == kind and row.identity == normalized), None)


def _released(config: dict) -> tuple[str, ...]:
    from .policy import _canonical_parts

    access = config.get("access", {})
    rows = access.get("release", []) if isinstance(access, dict) else []
    parts = [_canonical_parts(row) for row in (rows if isinstance(rows, list) else []) if isinstance(row, str)]
    # An invalid entry releases nothing: releases only lift holds, so dropping one fails closed.
    return tuple(dict.fromkeys("/".join(part) for part in parts if part and part[0] == "memory"))


def _parse(text: str, memory_root: Path, problem: str, **fields) -> AuthorizationInputs:
    policy, admins, removed, released = "all-access-v1", frozenset(), frozenset(), ()
    org_id, principals, principals_problem = "", (), None
    try:
        config = json.loads(text)
        profile = config.get("profile", {})
        policy = profile.get("default_policy", "all-access-v1")
        if not isinstance(policy, str) or not policy.strip():
            raise ValueError("policy must be a nonempty string")
        removed_rows = config.get("people_removed", [])
        if not isinstance(removed_rows, list) or any(not isinstance(row, str) for row in removed_rows):
            raise ValueError("removed people must be a string list")
        removed = frozenset(row.strip().casefold() for row in removed_rows if row.strip())
        admin_rows = config.get("admins", [])
        if isinstance(admin_rows, list):
            admins = frozenset(row.strip().casefold() for row in admin_rows if isinstance(row, str) and row.strip())
        # Match profile.load_profile's org-id resolution without its unrelated validation.
        org_id = str(config.get("org_id") or "").strip() or f"legacy-org:{str(config.get('slug') or '').strip()}"
        principals, principals_problem = _principals(config, org_id, admins)
        released, problem = _released(config), None
    except (OSError, ValueError, AttributeError):
        policy, admins, released = "all-access-v1", frozenset(), ()
    return AuthorizationInputs(policy, admins, removed, memory_root, problem=problem, org_id=org_id, principals=principals,
                               principals_problem=principals_problem, released=released, settings=text, **fields)


def _git(cwd: Path, *args: str, stdin: bytes | None = None) -> bytes:
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    return subprocess.run(["git", "-C", str(cwd), *args], input=stdin, capture_output=True, check=True, timeout=60,
                          env={**environment, "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"}).stdout


_ABSENT = object()


def _repository(url: str) -> str:
    """A clone URL as compared for identity.

    On github.com the scheme, the SSH form, case and a trailing .git name one
    repository, so they are ignored. Elsewhere only an HTTP user or token is
    dropped and the scheme and host are case-folded: the path keeps its case and
    suffix, and scp-style and ssh:// spellings stay apart, so two spellings that
    may name different repositories never match. A different spelling of the
    same repository refuses the hand-over, which fails closed.
    """
    url = url.strip().rstrip("/")
    if match := re.match(r"^([A-Za-z][A-Za-z0-9+.-]*://)([^@/]*@)?([^/]*)(.*)$", url):
        scheme, user, host, path = match[1].casefold(), match[2] or "", match[3].casefold(), match[4]
        if host == "github.com":
            return "github.com/" + path.lstrip("/").removesuffix(".git").casefold()
        return f"{scheme}{'' if scheme in ('http://', 'https://') else user}{host}{path}"
    if (match := re.match(r"^[^@/:]+@([^:/]+):(.*)$", url)) and match[1].casefold() == "github.com":
        return "github.com/" + match[2].lstrip("/").removesuffix(".git").casefold()
    return url


def committed_revision(memory_root: Path, memory_repo: object = _ABSENT, *, read_budget=None) -> str:
    """The memory repository's origin/main commit.

    Memory must be its own repository and, when the committed settings name
    ``memory_repo`` (any value, null included), a clone of that repository: a
    memory link to another organization's clone hands nothing over.
    """
    run = (lambda *args: _bounded_git(memory_root, args, read_budget, limit=8192)) if read_budget is not None else (lambda *args: _git(memory_root, *args))
    top = run("rev-parse", "--show-toplevel").decode().strip()
    if Path(top).resolve() != memory_root.resolve():
        raise ValueError("memory is not its own repository")
    if memory_repo is not _ABSENT:
        origin = (run("config", "--local", "--get", "remote.origin.url") if read_budget is not None
                  else run("config", "--get", "remote.origin.url")).decode().strip()
        if not isinstance(memory_repo, str) or not memory_repo.strip() or _repository(origin) != _repository(memory_repo):
            raise ValueError("memory is not the organization's memory repository")
    return run("rev-parse", "--verify", "--end-of-options", "refs/remotes/origin/main^{commit}").decode().strip()


def _declared_base(text: str) -> str:
    base = json.loads(text).get("base_branch") or "develop"
    if not isinstance(base, str) or not _BRANCH.fullmatch(base) or ".." in base:
        raise ValueError("base_branch is invalid")
    return base


def projection_root(root: Path) -> bool:
    """Whether ``root`` is a read-only copy: its marker is this user's private file, never one Git checked out."""
    try:
        info = os.lstat(Path(root) / ROOT_MARKER)
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077


def authorization_inputs(root: Path, principal: str | None = None, *, read_budget=None) -> AuthorizationInputs:
    """Read every authorization input from one source.

    The operator (``principal`` None) reads the working tree. Anyone else reads
    the committed base: ``origin/{base}:egregore.json`` and memory at the memory
    repository's ``origin/main``, so an uncommitted grant, policy switch,
    release, roster or hold-marker edit widens no one else. ``{base}`` comes from
    the working tree but must equal the base the committed file itself declares.
    Either source unreadable refuses every hand-over.

    A projection root decides from nothing it holds: its settings and identity
    are its reader's to edit, so it reads only the generation its slot admits
    (``policy.policy_for``) and acts for no one else.
    """
    memory_root = (root / "memory").resolve()
    if read_budget is not None:
        from .held import _read_budget
        _read_budget(read_budget)
    if projection_root(root):
        from .projection import REBUILDING, serves
        own = memory_root.parent.parent.parent == Path(root).resolve()  # DIR/memory names DIR's generation, no other
        problem = "a read-only copy acts for no one else" if principal is not None else None if own and serves(
            memory_root) else REBUILDING
        return AuthorizationInputs("all-access-v1", frozenset(), frozenset(), memory_root, source=PROJECTION_ROOT,
                                   problem=problem)
    if principal is None:
        try:
            text = (_bounded_settings(root / "egregore.json", read_budget).decode("utf-8") if read_budget is not None
                    else (root / "egregore.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            text = ""
        if read_budget is not None:
            read_budget.bind_authority((str(root.resolve()), "operator"), hashlib.sha256(text.encode()).hexdigest())
        return _parse(text, memory_root, "the organization settings could not be read")
    try:
        try:
            local = (_bounded_settings(root / "egregore.json", read_budget).decode("utf-8") if read_budget is not None
                     else (root / "egregore.json").read_text(encoding="utf-8"))
            base = _declared_base(local)
        except (OSError, json.JSONDecodeError, AttributeError):
            base = "develop"
        if read_budget is None:
            text = _git(root, "cat-file", "blob", f"refs/remotes/origin/{base}:egregore.json").decode("utf-8")
        else:
            base_oid = _bounded_git(root, ("rev-parse", "--verify", f"refs/remotes/origin/{base}^{{commit}}"), read_budget, limit=128).decode().strip()
            text = _bounded_git(root, ("cat-file", "blob", f"{base_oid}:egregore.json"), read_budget,
                                limit=read_budget.limits.settings_bytes).decode("utf-8")
            read_budget.charge("total_settings_bytes", len(text.encode()))
        if _declared_base(text) != base:
            raise ValueError("the committed settings declare another base")
        revision = committed_revision(memory_root, json.loads(text).get("memory_repo", _ABSENT), read_budget=read_budget)
        if read_budget is not None:
            read_budget.bind_authority((str(root.resolve()), "principal", principal),
                (base, base_oid, hashlib.sha256(text.encode()).hexdigest(), str(memory_root), revision))
        inputs = _parse(text, memory_root, SHARED_SETTINGS_UNREADABLE, source="committed", base=base,
                        memory_revision=revision)
        if not inputs.problem:
            return inputs
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
        pass
    return AuthorizationInputs("all-access-v1", frozenset(), frozenset(), memory_root, source="committed",
                               problem=SHARED_SETTINGS_UNREADABLE, principals_problem=SHARED_SETTINGS_UNREADABLE)


def _bounded_settings(path, budget):
    from .held import _read_budget
    _read_budget(budget)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb", buffering=0) as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or not before.st_mode & 0o444 or before.st_size > budget.limits.settings_bytes:
            budget.fail()
        budget.charge("total_settings_bytes", before.st_size)
        data = stream.read(before.st_size + 1)
        after = os.fstat(stream.fileno())
        if len(data) != before.st_size or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            budget.fail()
        budget.remaining()
        return data


def _start_bounded_git(root, args, budget, *, stdin=False):
    from .held import _read_budget
    _read_budget(budget)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0",
                       GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1", LC_ALL="C")
    return subprocess.Popen(["git", "--no-replace-objects", "-c", "protocol.allow=never", "-c", "core.fsmonitor=false",
                             "-c", "core.hooksPath=" + os.devnull, "-C", str(root), *args],
                            stdin=subprocess.PIPE if stdin else subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=environment, start_new_session=True, bufsize=0)


def _close_bounded_git(process):
    # Fixed local plumbing does not launch filters/hooks/transport helpers. Kill
    # its owned group even when the leader has already exited, then reap it.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    finally:
        process.wait()
        if process.stdin:
            process.stdin.close()
        process.stdout.close()


def _bounded_git_read(process, count, budget):
    with selectors.DefaultSelector() as selected:
        selected.register(process.stdout, selectors.EVENT_READ)
        if not selected.select(budget.remaining()):
            budget.fail()
    return os.read(process.stdout.fileno(), min(count, 65536))


def _bounded_git(root, args, budget, *, limit):
    process = _start_bounded_git(root, args, budget)
    output = bytearray()
    try:
        while True:
            chunk = _bounded_git_read(process, limit + 1 - len(output), budget)
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > limit:
                budget.fail()
        if process.wait(timeout=budget.remaining()) != 0:
            budget.fail()
        budget.remaining()
        return bytes(output)
    except (OSError, ValueError, subprocess.SubprocessError):
        budget.fail()
    finally:
        _close_bounded_git(process)


class _BoundedCommittedMemory:
    """Read-only fixed source owner; complete inventory and size-first blobs."""
    def __init__(self, root, revision, budget):
        from .held import _file_identity, _read_budget
        self.root, self.revision, self.budget = Path(root), revision, _read_budget(budget)
        self.entries, self.folders, self._blobs, self._process = {}, set(), {}, None
        if (not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision) or not self.root.is_absolute()
                or self.root != self.root.resolve(strict=True)):
            budget.fail()
        self.identity = _file_identity(self.root.stat())
        git_dir = self.root / ".git"
        if git_dir.is_symlink() or not git_dir.is_dir():
            budget.fail()  # Canonical memory owns its repository, not another worktree's object store.
        self._git_identity = _file_identity(git_dir.stat())[:4]
        config = _bounded_settings(git_dir / "config", budget)
        if re.search(rb"(?im)^\s*\[\s*include(?:if)?\b|\b(?:partialclone|promisor)\s*=", config):
            budget.fail()
        for name in ("commondir", "shallow", "info/grafts", "objects/info/alternates", "objects/info/http-alternates"):
            selected = git_dir / name
            for parent in selected.parents:
                if parent == git_dir:
                    break
                if parent.is_symlink():
                    budget.fail()
            if selected.exists() or selected.is_symlink():
                budget.fail()
        if (git_dir / "objects").is_symlink():
            budget.fail()
        # Local Git may consult packs, loose objects and refs without exposing
        # their filesystem paths. Refuse indirect stores before any Git read.
        def metadata(directory, depth=0):
            budget.remaining()
            with os.scandir(directory) as found:
                for entry in found:
                    budget.charge("entries")
                    budget.charge("inventory_bytes", len(os.fsencode(entry.name)) + 1)
                    info = entry.stat(follow_symlinks=False)
                    if stat.S_ISLNK(info.st_mode):
                        budget.fail()
                    if stat.S_ISDIR(info.st_mode):
                        if depth >= 8:
                            budget.fail()
                        child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                        try:
                            if _file_identity(os.fstat(child)) != _file_identity(info):
                                budget.fail()
                            metadata(child, depth + 1)
                        finally:
                            os.close(child)
                    elif not stat.S_ISREG(info.st_mode):
                        budget.fail()
        for name in ("objects", "refs"):
            if (git_dir / name).exists():
                descriptor = os.open(git_dir / name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    metadata(descriptor)
                finally:
                    os.close(descriptor)
        for name in ("HEAD", "packed-refs"):
            path = git_dir / name
            if path.is_symlink() or path.exists() and not stat.S_ISREG(path.lstat().st_mode):
                budget.fail()
        output = _bounded_git(root, ("ls-tree", "-r", "-t", "-z", "--full-tree", "--end-of-options", revision), budget,
                              limit=budget.limits.inventory_bytes - budget.counts.get("inventory_bytes", 0))
        budget.charge("inventory_bytes", len(output))
        for row in output.split(b"\0"):
            if not row:
                continue
            budget.charge("entries")
            meta, sep, path = row.partition(b"\t")
            if not sep or len(path) > budget.limits.path_bytes:
                budget.fail()
            mode, kind, oid = meta.decode("ascii").split(" ")
            name = path.decode("utf-8", "surrogateescape")
            if (not name or any(part in {"", ".", ".."} for part in name.split("/"))
                    or not re.fullmatch(r"[a-f0-9]{40}|[a-f0-9]{64}", oid) or len(oid) != len(revision)
                    or name in self.entries or name in self.folders):
                budget.fail()
            if kind == "tree" and mode == "040000":
                self.folders.add(name)
            elif kind in {"blob", "commit"}:
                self.entries[name] = (mode, oid)
            else:
                budget.fail()
        self.fingerprint = hashlib.sha256(output).hexdigest()

    def _exact(self, count):
        value = bytearray()
        while len(value) < count:
            chunk = _bounded_git_read(self._process, count - len(value), self.budget)
            if not chunk:
                self.budget.fail()
            value.extend(chunk)
        return bytes(value)

    def read(self, relative):
        budget = self.budget
        budget.remaining()
        mode, oid = self.entries[relative]
        if mode not in {"100644", "100755", "120000"}:
            budget.fail()
        if oid in self._blobs:
            return self._blobs[oid]
        if self._process is None:
            self._process = _start_bounded_git(self.root, ("cat-file", "--batch"), budget, stdin=True)
        self._process.stdin.write(oid.encode() + b"\n")
        header = bytearray()
        while not header.endswith(b"\n"):
            if len(header) >= 128:
                budget.fail()
            header.extend(self._exact(1))
        values = header.split()
        if len(values) != 3 or values[0] != oid.encode() or values[1] != b"blob" or not values[2].isdigit():
            budget.fail()
        size = int(values[2])
        limit = min(budget.limits.dependency_bytes, budget.limits.path_bytes) if mode == "120000" else budget.limits.dependency_bytes
        if size > limit:
            budget.fail()
        budget.charge("total_bytes", size)
        data = self._exact(size)
        if self._exact(1) != b"\n":
            budget.fail()
        algorithm = hashlib.sha1 if len(oid) == 40 else hashlib.sha256
        if algorithm(b"blob " + str(size).encode() + b"\0" + data).hexdigest() != oid:
            budget.fail()
        self._blobs[oid] = data
        return data

    def hold_documents(self):
        from .held import committed_target
        documents, identities = {}, {}
        try:
            for name, (mode, _oid) in sorted(self.entries.items()):
                self.budget.remaining()
                if mode not in {"100644", "100755", "120000"} or not name.lower().endswith(".md") or any(p.startswith(".") for p in name.split("/")):
                    continue
                target = name if mode != "120000" else committed_target(self, name)
                if target is None:
                    continue
                if len(documents) >= self.budget.limits.documents:
                    self.budget.fail()
                documents[name] = (target, self.read(target))
                identities[name] = None
            self.budget.remaining()
            return self.identity, self.fingerprint, documents, identities
        finally:
            if self._process is not None:
                _close_bounded_git(self._process)
                self._process = None

    def recheck(self):
        from .held import _file_identity
        self.budget.remaining()
        if self.root != self.root.resolve(strict=True) or _file_identity(self.root.stat()) != self.identity:
            self.budget.fail()
        directory = self.root / ".git"
        if directory.is_symlink() or _file_identity(directory.stat())[:4] != self._git_identity:
            self.budget.fail()
        if _bounded_git(self.root, ("rev-parse", "--verify", "--end-of-options", self.revision + "^{commit}"), self.budget, limit=128).decode().strip() != self.revision:
            self.budget.fail()
        inventory = _bounded_git(self.root, ("ls-tree", "-r", "-t", "-z", "--full-tree", "--end-of-options", self.revision),
                                 self.budget, limit=self.budget.limits.inventory_bytes - self.budget.counts.get("inventory_bytes", 0))
        self.budget.charge("inventory_bytes", len(inventory))
        if hashlib.sha256(inventory).hexdigest() != self.fingerprint:
            self.budget.fail()


def bounded_committed_memory(memory_root, revision, *, budget):
    from .held import _read_budget
    _read_budget(budget)
    try:
        return _BoundedCommittedMemory(memory_root, revision, budget)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError):
        budget.fail()


class CommittedMemory:
    """Memory exactly as committed at one revision (``git ls-tree`` and ``git cat-file --batch``)."""

    def __init__(self, root: Path, revision: str):
        self.root, self.revision, self.entries, self.folders, self._blobs = root, revision, {}, set(), {}
        for row in _git(root, "ls-tree", "-r", "-t", "-z", "--full-tree", "--end-of-options", revision).split(b"\0"):
            if row:
                meta, _, path = row.partition(b"\t")
                mode, kind, oid = meta.decode().split(" ")
                name = path.decode("utf-8", "surrogateescape")
                if kind == "tree":
                    self.folders.add(name)
                else:
                    self.entries[name] = (mode, oid)

    def kind(self, relative: str) -> str | None:
        """file, folder, link or other for the path, or for the first committed non-folder above it; None if absent."""
        parts = relative.split("/")
        for depth in range(1, len(parts) + 1):
            if entry := self.entries.get("/".join(parts[:depth])):
                if entry[0] == "120000":
                    return "link"
                return "file" if entry[0] in {"100644", "100755"} and depth == len(parts) else "other"
        return "folder" if relative in self.folders else None

    def prefetch(self, relatives) -> None:
        """Read many blobs through one ``git cat-file --batch``."""
        oids = [oid for oid in dict.fromkeys(self.entries[r][1] for r in relatives if r in self.entries) if oid not in self._blobs]
        if not oids:
            return
        output, offset = _git(self.root, "cat-file", "--batch", stdin=("\n".join(oids) + "\n").encode()), 0
        for oid in oids:
            end = output.index(b"\n", offset)
            header = output[offset:end].split(b" ")
            if len(header) != 3 or header[0].decode() != oid or header[1] != b"blob":
                raise ValueError("committed memory could not be read")
            size = int(header[2])
            self._blobs[oid], offset = output[end + 1:end + 1 + size], end + 2 + size

    def read(self, relative: str) -> bytes:
        self.prefetch([relative])
        return self._blobs[self.entries[relative][1]]


_TREES: dict[tuple[str, str], CommittedMemory] = {}


def committed_memory(memory_root: Path, revision: str) -> CommittedMemory:
    """One cached reader per memory repository and revision (the last four)."""
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision):
        raise ValueError("a committed revision is required")
    key = (str(memory_root.resolve()), revision)
    if key not in _TREES:
        while len(_TREES) >= 4:
            _TREES.pop(next(iter(_TREES)))
        _TREES[key] = CommittedMemory(memory_root, revision)
    return _TREES[key]
