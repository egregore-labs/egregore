"""Hand-overs to the map viewer: one immutable generation per publish, served only when complete.

A hub slot ``~/.egregore/mind/hub/<installation key>/`` holds one egregore's hand-over for the
person on this machine::

    stamp.json     which installation owns the slot; a foreign stamp is refused
    require.json   the holds and grant a served generation must carry
    current.json   names the generation to serve; renamed into place, the one swap
    seen.json      the source fingerprint and start time of the last publish, for the stale check
    gen/<rev>/     manifest.json, needs.json, memory/ and vectors.f32, never changed once written; two are kept

The manifest carries everything else the map's exporter reads (export.py --projection), so it
reads nothing from a checkout: the config slice, people, the person, and each file's id, sha,
source mtime (kept on the copy too), history dates and row in ``vectors.f32``. A file has a
search vector only when redaction left its bytes as read; export imputes the rest.

A withdrawal fails closed. When the holds or the grant change, ``require.json`` is renamed into
place before the build, so a killed or failed build leaves the slot dark, never on the previous
generation. ``admit`` is every reader's gate and re-reads both files each time.

A non-admin copy is redacted by ``held.Redactor``, the one redaction Runtime reads use too: it
loses the paths, file names, distinctive slugs, artifact ids and long titles of every document the
hand-over holds.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, replace
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import struct
import subprocess
import sys
import time
from typing import Any, Iterator, Mapping

from . import held
from .optional_modules import optional_module
from .access import ROOT_MARKER, AuthorizationInputs, _git, authorization_inputs, committed_memory, projection_root
from .adapters.qmd import read_document_vectors, vectors_receipt
from .artifacts import artifact_id_from_path
from .contracts import ActorContext, Permission, PolicyDecision
from .errors import EgregoreRuntimeError
from .installation import installation_key, installation_root
from .policy import bytes_held, check, committed_settings, is_admin, policy_for

VERSION = "egregore-projection/2"
REDACTION_VERSION = "projection-redaction/3"
DIMENSION = 256  # export.py's default --dimension
REQUIRE_FIELDS = ("holds_epoch", "held_digest", "grant_digest")
ORPHAN_SECONDS = 30 * 86400
JSON_CAP, MANIFEST_CAP, FILE_CAP = 1 << 16, 1 << 27, 1 << 27
_REV = re.compile(r"[0-9a-f]{24}")


class ProjectionError(EgregoreRuntimeError):
    pass


def hub_root() -> Path:
    return Path.home() / ".egregore" / "mind" / "hub"


def _digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def grant_digest(decision: PolicyDecision) -> str:
    """Who holds the grant, whether it stands, its audience, policy and every action's prefixes."""
    return _digest(["grant/1", decision.allowed, decision.actor_id, decision.org_id, decision.audience,
                    decision.scope, decision.policy_epoch, sorted(decision.read_prefixes),
                    sorted(decision.append_prefixes), sorted(decision.write_prefixes)])


def operator(root: Path, *, harness: str = "mind", session_id: str = "mind-publish") -> ActorContext:
    from .identity import LocalIdentityResolver
    return LocalIdentityResolver(root).resolve(session_id=session_id, harness=harness)


def hand_over(root: Path, actor: ActorContext) -> PolicyDecision:
    """The operator's read decision in the hand-over scope; nothing is handed over from a read scope."""
    decision = policy_for(authorization_inputs(root)).authorize_action(actor, Permission.READ)
    return replace(decision, scope="hand-over")


# ---- sources -------------------------------------------------------------------------------

@dataclass(frozen=True, slots=True)
class _Source:
    canonical: str
    data: bytes
    sha: str
    mtime_ns: int
    held: int | None
    shown: bool
    title: str
    artifact_id: str
    aliases: tuple[str, ...]  # every declared id, slug or session id


def _raise(error: OSError) -> None:
    raise error


def _walk(memory: Path) -> Iterator[tuple[str, Path, os.stat_result]]:
    """Regular Markdown files; a link to a file or a folder is skipped, never followed."""
    for folder, folders, files in os.walk(memory, onerror=_raise):
        folders[:] = sorted(name for name in folders if name != ".git")
        for name in sorted(files):
            path = Path(folder, name)
            info = os.lstat(path)
            if name.lower().endswith(".md") and stat.S_ISREG(info.st_mode):  # as export's inventory
                yield "memory/" + path.relative_to(memory).as_posix(), path, info


def _read(path: Path, cap: int = FILE_CAP, *, private: bool = False) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > cap:
            raise OSError(f"not a regular file within the size cap: {path.name}")
        if private and (info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077):
            raise OSError(f"not a private, single-link file: {path.name}")
        chunks = []
        while chunk := os.read(descriptor, 1 << 20):
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def fingerprint(root: Path, found: list | None = None) -> str:
    """What a publish reads, by stat only: the stale check, cheap enough for every Runtime call."""
    from . import needs
    found = list(_walk((root / "memory").resolve())) if found is None else found
    rows: list[Any] = [VERSION, REDACTION_VERSION, held.HELD_RULES_VERSION, needs.VERSION,
                       time.strftime("%Y-%m-%d", time.gmtime())]  # needs.json windows by day
    rows += [(c, i.st_mtime_ns, i.st_ctime_ns, i.st_size, i.st_ino) for c, _, i in found]
    # A commit moves the history dates and a finished vector build the vectors, files unchanged.
    marks = [root / "egregore.json", root / ".egregore-state.json", root / needs.BOARD, vectors_receipt(root),
             *_heads(root / "memory")]
    for path in marks:
        try:
            info = os.stat(path)
            rows.append((path.name, info.st_mtime_ns, info.st_ctime_ns, info.st_size, info.st_ino))
        except OSError:
            rows.append((path.name, None))
    return _digest(rows)


def _heads(memory: Path) -> list[Path]:
    """Where the memory history's head is kept, in a clone or a linked worktree: HEAD and its ref,
    and the shallow list (history reads nothing from a shallow clone until it is deepened)."""
    git = common = memory / ".git"
    try:
        if os.path.isfile(git):  # a linked worktree: its own HEAD, the refs in the shared git dir
            git = common = (memory / _read(git, JSON_CAP).decode().strip().removeprefix("gitdir:").strip()).resolve()
            if os.path.isfile(git / "commondir"):
                common = (git / _read(git / "commondir", JSON_CAP).decode().strip()).resolve()
        head = _read(git / "HEAD", JSON_CAP).decode()
    except (OSError, ValueError):
        return [git / "HEAD"]
    return [git / "HEAD", common / "packed-refs", common / "shallow",
            *([common / head[5:].strip()] if head.startswith("ref: refs/") else [])]


# ---- build ---------------------------------------------------------------------------------

@dataclass(frozen=True, slots=True)
class _Scan:
    decision: PolicyDecision
    sources: tuple[_Source, ...]
    redactor: held.Redactor | None  # None for an admin, who sees held material
    held_digest: str
    revision: str  # the redaction revision, half of every file's reuse key
    root: Path

    @property
    def shown(self) -> list[_Source]:
        return [source for source in self.sources if source.shown]

    def require(self) -> dict[str, str]:
        return {"holds_epoch": self.decision.holds_epoch, "held_digest": self.held_digest,
                "grant_digest": grant_digest(self.decision)}


def _documents(decision: PolicyDecision, memory: Path) -> Iterator[tuple[str, bytes, int]]:
    """(path, bytes, mtime) of each Markdown document a hand-over reads: as walked for the operator, as committed at
    the decision's revision for anyone else, so no working-tree byte reaches them. A link is skipped, as the walk
    skips one; a committed document's time is its revision's."""
    if not decision.memory_revision:
        yield from ((canonical, _read(path), info.st_mtime_ns) for canonical, path, info in _walk(memory))
        return
    committed = committed_memory(memory, decision.memory_revision)
    names = sorted(name for name, (mode, _oid) in committed.entries.items()
                   if mode in {"100644", "100755"} and name.lower().endswith(".md"))
    committed.prefetch(names)
    when = int(_git(memory, "log", "-1", "--format=%ct", decision.memory_revision).decode().strip()) * 1_000_000_000
    yield from (("memory/" + name, committed.read(name), when) for name in names)


def _scan(decision: PolicyDecision, root: Path) -> _Scan:
    if decision.scope != "hand-over":
        raise ProjectionError("a hand-over is built only from a hand-over decision")
    memory = (root / "memory").resolve()
    sources = []
    for canonical, data, mtime_ns in _documents(decision, memory):
        # Held by the bytes this generation would carry, under every class the hand-over applies, or by the
        # file as checked now: a rewrite between the read and the check can never ship bytes held when read.
        verdict = check(decision, canonical, "read", root=memory) if decision.allowed else None
        number = (bytes_held(decision, canonical, data, root=memory) if decision.allowed and not is_admin(decision)
                  else next(iter(held.blob_classes(data)), None))
        if number is None and verdict is not None and verdict.reason.startswith("held:"):
            number = int(verdict.reason.removeprefix("held:"))
        shown = verdict is not None and verdict.allowed and (number is None or is_admin(decision))
        sources.append(_Source(canonical, data, hashlib.sha256(data).hexdigest(), mtime_ns,
                               number, shown, *held.describe(canonical, data)))
    held_docs = [s for s in sources if s.held is not None]
    held_digest = _digest([held.HELD_RULES_VERSION,
                           [(s.canonical, s.held, s.title, s.artifact_id, s.aliases) for s in held_docs]])
    shown = [s for s in sources if s.shown]
    redactor = None if is_admin(decision) else held.Redactor(
        [(s.canonical, s.title, s.artifact_id, s.aliases) for s in held_docs],
        [s.canonical for s in shown], [s.title for s in shown])
    # Releases (access.release) arrive with the held rules and join this digest there.
    revision = _digest([REDACTION_VERSION, decision.holds_epoch, held_digest, grant_digest(decision),
                        decision.audience, redactor.revision() if redactor else "admin"])
    return _Scan(decision, tuple(sources), redactor, held_digest, revision, root)


def derive(scan: _Scan, source: _Source) -> bytes:
    """A file's hand-over bytes, from its source: unchanged for an admin, redacted for anyone else."""
    if scan.redactor is None:
        return source.data
    return scan.redactor.redact(source.data.decode("utf-8", "surrogateescape")).encode("utf-8", "surrogateescape")


def _mkdir(path: Path) -> None:
    try:
        os.mkdir(path, 0o700)
        os.chmod(path, 0o700)
    except FileExistsError:
        pass
    _private_dir(path)


def _write(path: Path, data: bytes, mtime_ns: int | None = None) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        view = memoryview(data)
        while view:
            view = view[os.write(descriptor, view):]
    finally:
        os.close(descriptor)
    if mtime_ns is not None:
        os.utime(path, ns=(mtime_ns, mtime_ns), follow_symlinks=False)


def _write_json(path: Path, value: Mapping[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp")
    _write(temporary, json.dumps(value, sort_keys=True).encode())
    os.replace(temporary, path)


@dataclass(frozen=True, slots=True)
class _Inputs:
    """What the exporter reads besides the files: each shown file's history dates and search vector."""
    versions: Mapping[str, list]  # path -> [first ISO date, last ISO date, content-changing commits]
    vectors: Mapping[str, list]  # path -> the vector QMD holds for exactly the bytes scanned
    fingerprint: str

    def header(self) -> dict[str, Any]:
        digest = hashlib.sha256()
        for path in sorted(self.vectors):
            digest.update(path.encode() + b"\0" + _pack(self.vectors[path]))
        return {"dimension": DIMENSION, "fingerprint": self.fingerprint, "digest": digest.hexdigest()}


def _pack(vector: list) -> bytes:
    return struct.pack(f"<{DIMENSION}f", *vector)


def _inputs(scan: _Scan, root: Path) -> _Inputs:
    from . import history
    shown = {source.canonical: source.sha for source in scan.shown}
    memory = (root / "memory").resolve()
    cache = Path.home() / ".egregore" / "runtime" / "history" / f"{_digest(str(memory))[:16]}.json"
    try:  # optional: without an index export falls back to its own representation
        read = read_document_vectors(root, sorted(shown), DIMENSION, hashes=shown)
    except (OSError, ValueError):
        read = {"vectors": {}, "fingerprint": ""}
    return _Inputs(history.document_dates(memory, sorted(shown), cache), read["vectors"], read["fingerprint"])


def _materialize(scan: _Scan, dest: Path, previous: Admission | None, inputs: _Inputs) -> list[dict[str, Any]]:
    """Write ``dest/memory``: a file whose (source sha256, redaction revision) matches the previous
    generation is copied from it, every other file is derived again from its source."""
    old = {}
    if previous and previous.manifest.get("redaction_revision") == scan.revision:
        old = {entry["path"]: entry for entry in previous.manifest["files"]}
    _mkdir(dest / "memory")
    made, entries = {dest, dest / "memory"}, []
    for source in scan.shown:
        target = folder = dest
        for part in source.canonical.split("/"):
            folder, target = target, target / part
            if folder not in made:
                _mkdir(folder)
                made.add(folder)
        data, entry = None, old.get(source.canonical)
        if entry and entry["sha"] == source.sha:
            try:
                data = _read(previous.generation / source.canonical, private=True)
                data = data if hashlib.sha256(data).hexdigest() == entry["bytes_sha"] else None
            except OSError:
                data = None
        if data is None:
            data = derive(scan, source)
        _write(target, data, source.mtime_ns)
        versions, ident = inputs.versions.get(source.canonical), source.artifact_id
        if scan.redactor is not None and scan.redactor.spans(ident):  # a declared id that spells a held name
            ident = artifact_id_from_path(source.canonical.removeprefix("memory/"))
        entries.append({"path": source.canonical, "id": ident, "sha": source.sha,
                        "bytes_sha": hashlib.sha256(data).hexdigest(), "size": len(data),
                        "mtime_ns": source.mtime_ns, **({"held": source.held} if source.held else {}),
                        **({"versions": versions} if versions else {})})
    held_paths = {s.canonical for s in scan.sources if s.held is not None}
    if scan.redactor is not None and any(entry["path"] in held_paths for entry in entries):
        raise ProjectionError("leak check failed: a held path is in the hand-over")
    return entries


def _generation(scan: _Scan, dest: Path, header: Mapping[str, Any], previous: Admission | None,
                inputs: _Inputs, *, with_needs: bool = True) -> None:
    _mkdir(dest)
    files = _materialize(scan, dest, previous, inputs)
    rows = []
    for entry in files:  # a vector describes the bytes it was read for: a redacted copy gets none
        if entry["path"] in inputs.vectors and entry["bytes_sha"] == entry["sha"]:
            entry["vector"] = len(rows)
            rows.append(_pack(inputs.vectors[entry["path"]]))
    _write(dest / "vectors.f32", b"".join(rows))
    manifest = {**header, "generation": dest.name, "files": files}
    # A shown file's path is held to the hand-over by identity above; every other value by every held
    # name, one at a time. Field names are this module's words, not memory's, except map.names', which
    # are what people wrote.
    scanned = [{k: v for k, v in manifest.items() if k != "files"},
               [{k: v for k, v in entry.items() if k != "path"} for entry in files]]
    if scan.redactor is not None and any(scan.redactor.spans(text) for text in
                                         (*_strings(scanned, False), *_strings(manifest["config"]["map"]["names"], True))):
        raise ProjectionError("leak check failed: a held name is in the manifest")
    if with_needs:
        from . import needs
        needs.write(scan, dest)  # what needs the person, before the manifest that completes the generation
    _write(dest / "manifest.json", json.dumps(manifest, sort_keys=True).encode())


def _strings(value: Any, keys: bool) -> Iterator[str]:
    if isinstance(value, dict):
        for key, item in value.items():
            yield from (str(key),) if keys else ()
            yield from _strings(item, keys)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item, keys)
    elif isinstance(value, str):
        yield value


def read_vectors(generation: Path, manifest: Mapping[str, Any]) -> dict[str, Any]:
    """An admitted generation's vectors in ``read_document_vectors``'s shape, for export.py --projection."""
    meta, width = manifest["vectors"], DIMENSION * 4
    rows = {entry["path"]: entry["vector"] for entry in manifest["files"] if "vector" in entry}
    data = _read(Path(generation) / "vectors.f32", FILE_CAP, private=True)
    if meta.get("dimension") != DIMENSION or len(data) != len(rows) * width or sorted(rows.values()) != list(range(len(rows))):
        raise ProjectionError("the generation's vectors do not match its manifest")
    return {"vectors": {path: list(struct.unpack_from(f"<{DIMENSION}f", data, row * width)) for path, row in rows.items()},
            "fingerprint": meta.get("fingerprint", ""), "dimension": DIMENSION}


def build(decision: PolicyDecision, dest: Path, *, root: Path, previous: Admission | None = None) -> None:
    """One generation at ``dest`` for a hand-over decision: a slot, and later a root or a snapshot."""
    root = Path(root).resolve()
    scan = _scan(decision, root)
    if not decision.allowed:
        raise ProjectionError("this decision hands nothing over")
    inputs = _inputs(scan, root)
    _generation(scan, Path(dest), _header(scan, root, inputs), previous, inputs)


def _header(scan: _Scan, root: Path, inputs: _Inputs, settings: AuthorizationInputs | None = None) -> dict[str, Any]:
    """``settings``: another principal's committed inputs; the operator's are the working tree's."""
    from .identity import organization_member_presentations
    try:
        config = json.loads(settings.settings if settings else (root / "egregore.json").read_text(encoding="utf-8"))
        config = config if isinstance(config, dict) else {}
    except (OSError, ValueError):
        config = {}
    names = config.get("map") if isinstance(config.get("map"), dict) else {}
    sliced = {"org_name": config.get("org_name"), "slug": config.get("slug"), "repos": config.get("repos", []),
              "github_org": config.get("github_org"), "repo_name": config.get("repo_name"),
              "map": {"names": names.get("names")}, "removed": sorted((settings or authorization_inputs(root)).removed)}
    shown = {source.canonical: source.data for source in scan.shown}  # the profiles as scanned, never re-read
    people = [{"person_id": m.person_id, "display_name": m.display_name, "aliases": list(m.aliases)}
              for m in organization_member_presentations(root, decision=None, sources=shown,
                                                         removed=settings.removed if settings else None)]
    return {"version": VERSION, "complete": True, "principal": scan.decision.actor_id,
            "audience": scan.decision.audience, **scan.require(), "redaction_revision": scan.revision,
            "source_revision": _digest([(s.canonical, s.sha) for s in scan.shown]), "vectors": inputs.header(),
            "config": scan.redactor.scrub(sliced) if scan.redactor else sliced,
            "people": scan.redactor.scrub(people) if scan.redactor else people}


# ---- the slot ------------------------------------------------------------------------------

def _private_dir(path: Path) -> None:
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise OSError(f"not a private folder: {path.name}")


def _quiet_json(path: Path) -> dict | None:
    try:
        value = json.loads(_read(path, JSON_CAP, private=True))
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


@contextmanager
def _locked(path: Path, *, wait: bool = True) -> Iterator[bool]:
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        yield True
    finally:
        os.close(descriptor)


def _stamp(root: Path) -> dict[str, str]:
    key = installation_key(root)
    org_id = str(json.loads((root / "egregore.json").read_text(encoding="utf-8")).get("org_id")).strip()
    return {"key": key, "org_id": org_id, "installation": str(installation_root(root))}


def _claim(slot: Path, stamp: Mapping[str, str]) -> None:
    try:
        _mkdir(slot)
        if not os.path.lexists(slot / "stamp.json"):
            _write_json(slot / "stamp.json", stamp)
    except OSError as exc:
        raise ProjectionError(f"the map slot cannot be used: {exc}") from exc
    if _quiet_json(slot / "stamp.json") != stamp:
        raise ProjectionError("this map slot belongs to another installation")


def _sweep(hub: Path, own: str) -> None:
    """An orphan tile ages out: a slot whose installation is gone and untouched for 30 days."""
    cutoff = time.time() - ORPHAN_SECONDS
    for entry in os.scandir(hub):
        if entry.name == own or not entry.is_dir(follow_symlinks=False):
            continue
        slot = Path(entry.path)
        try:
            installation = (_quiet_json(slot / "stamp.json") or {}).get("installation")
            if os.lstat(slot).st_uid != os.getuid() or (isinstance(installation, str) and os.path.isdir(installation)):
                continue
            touched = [os.lstat(p).st_mtime for p in (slot, slot / "current.json", slot / "require.json",
                                                         slot / "stamp.json") if os.path.lexists(p)]
            if max(touched) < cutoff:
                shutil.rmtree(slot)
        except OSError:
            continue


@dataclass(frozen=True, slots=True)
class Admission:
    state: str  # "ready" or "dark"
    reason: str
    generation: Path | None = None
    manifest: Mapping[str, Any] | None = None

    @property
    def ready(self) -> bool:
        return self.state == "ready"


def admit(slot: Path) -> Admission:
    """The generation to serve, or dark. Nothing is cached: call it on every request."""
    slot = Path(slot)
    try:
        _private_dir(slot)
        _private_dir(slot / "gen")
        pointer = json.loads(_read(slot / "current.json", JSON_CAP, private=True))
        require = json.loads(_read(slot / "require.json", JSON_CAP, private=True))
        rev = pointer.get("generation")
        if not isinstance(rev, str) or not _REV.fullmatch(rev):
            return Admission("dark", "no generation")
        generation = slot / "gen" / rev
        _private_dir(generation)
        manifest = json.loads(_read(generation / "manifest.json", MANIFEST_CAP, private=True))
        if manifest.get("complete") is not True or manifest.get("generation") != rev or manifest.get("key") != slot.name:
            return Admission("dark", "incomplete generation")
        stamp = json.loads(_read(slot / "stamp.json", JSON_CAP, private=True))
        if stamp.get("key") != slot.name or stamp.get("org_id") != manifest.get("org_id"):
            return Admission("dark", "another installation's slot")
        if any(not require.get(field) or manifest.get(field) != require.get(field) for field in REQUIRE_FIELDS):
            return Admission("dark", "being rebuilt")
        found = {}
        memory = generation / "memory"
        _private_dir(memory)
        for folder, folders, files in os.walk(memory, onerror=_raise):
            for name in folders:
                _private_dir(Path(folder, name))
            for name in files:
                info = os.lstat(Path(folder, name))
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                        or info.st_mode & 0o077 or info.st_size > FILE_CAP):
                    return Admission("dark", "a file is not private")
                found["memory/" + Path(folder, name).relative_to(memory).as_posix()] = info.st_size
        if found != {entry["path"]: entry["size"] for entry in manifest["files"]}:
            return Admission("dark", "files differ from the manifest")
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return Admission("dark", "unreadable")
    return Admission("ready", "admitted", generation, manifest)


# ---- publish -------------------------------------------------------------------------------

def publish(root: Path, *, wait: bool = True) -> str:
    """Hand the operator's view over to the slot; a no-op until the viewer creates the hub.

    Returns "no-hub", "busy", "denied", "superseded", "unchanged" or "published".
    """
    root = installation_root(Path(root).resolve())  # every worktree hands over the installation's view
    if projection_root(root):  # a read-only copy hands nothing over, whatever its settings name
        return "denied"
    hub = hub_root()
    if not os.path.isdir(hub) or os.path.islink(hub):
        return "no-hub"
    stamp = _stamp(root)
    slot = hub / stamp["key"]
    _claim(slot, stamp)
    with _locked(slot / ".build.lock", wait=wait) as locked:
        if not locked:
            return "busy"
        seen: dict[str, Any] = {}
        try:
            return _publish(root, slot, stamp, seen)
        finally:
            if seen and (_quiet_json(slot / "seen.json") or {}).get("fingerprint") != seen["fingerprint"]:
                _write_json(slot / "seen.json", seen)


def _publish(root: Path, slot: Path, stamp: Mapping[str, str], seen: dict[str, Any]) -> str:
    from . import needs
    before = _quiet_json(slot / "require.json")
    actor = operator(root)  # resolved after ``before``: a later identity change voids this publish
    decision = hand_over(root, actor)
    if before is None or any(before.get(k) != v for k, v in _pair(decision).items()):
        with _locked(slot / ".require.lock"):  # a known withdrawal is recorded before anything can fail
            if _quiet_json(slot / "require.json") != before:
                return "superseded"
            before = _pending(decision)
            _write_json(slot / "require.json", before)
    last = _quiet_json(slot / "seen.json") or {}
    if before.get("held_digest") != "pending" and not is_admin(decision) \
            and _held_changed(_walked(root), last.get("since", 0), decision, (root / "memory").resolve()):
        with _locked(slot / ".require.lock"):  # held since the last publish: dark before a scan can fail
            if _quiet_json(slot / "require.json") != before:
                return "superseded"
            before = _pending(decision)
            _write_json(slot / "require.json", before)
    seen.update(since=time.time_ns(), fingerprint=fingerprint(root))
    _sweep(slot.parent, slot.name)
    pointer = _quiet_json(slot / "current.json") or {}
    scan = _scan(decision, root)
    require = scan.require()
    with _locked(slot / ".require.lock"):
        now = _quiet_json(slot / "require.json")
        if now != before:
            return "superseded"  # a withdrawal landed after this publish read its inputs
        if now != require:
            _write_json(slot / "require.json", require)
    if not scan.decision.allowed:
        return "denied"
    current = admit(slot)
    inputs = _inputs(scan, root)
    header = {**_header(scan, root, inputs), "key": stamp["key"], "org_id": stamp["org_id"],
              "person": {"actor_id": actor.actor.actor_id, "display_name": actor.actor.display_name,
                         "handle": actor.actor.aliases.get("github.username"), "account_id": actor.actor.account_id,
                         "person_id": actor.actor.aliases.get("legacy.person")}}
    if current.ready and {k: v for k, v in current.manifest.items() if k not in ("generation", "files")} == header \
            and {e["path"]: (e["sha"], e["mtime_ns"], e.get("versions")) for e in current.manifest["files"]} \
            == {s.canonical: (s.sha, s.mtime_ns, inputs.versions.get(s.canonical)) for s in scan.shown} \
            and needs.fresh(scan, current.generation):
        return "unchanged"
    _mkdir(slot / "gen")
    rev = f"{time.time_ns():016x}{secrets.token_hex(4)}"
    generation = slot / "gen" / rev
    try:
        _generation(scan, generation, header, current if current.ready else None, inputs)
        with _locked(slot / ".require.lock"):
            if _quiet_json(slot / "require.json") != require:
                raise _Superseded()
            _write_json(slot / "current.json", {"generation": rev})
    except _Superseded:
        shutil.rmtree(generation, ignore_errors=True)
        return "superseded"
    except BaseException:
        shutil.rmtree(generation, ignore_errors=True)
        raise
    keep = {rev, pointer.get("generation")}
    for entry in os.scandir(slot / "gen"):
        if entry.name not in keep and entry.is_dir(follow_symlinks=False):
            shutil.rmtree(entry.path, ignore_errors=True)
    return "published"


class _Superseded(Exception):
    pass


# ---- the Runtime observer ------------------------------------------------------------------

def _pair(decision: PolicyDecision) -> dict[str, str]:
    return {"holds_epoch": decision.holds_epoch, "grant_digest": grant_digest(decision)}


def _pending(decision: PolicyDecision) -> dict[str, str]:
    """A dark requirement no manifest matches. Each one is unique, so a publish comparing
    require.json against what it read sees every withdrawal, even a repeated one."""
    return {**_pair(decision), "held_digest": "pending", "withdrawal": secrets.token_hex(8)}


def refresh(root: Path, *, harness: str = "mind", session_id: str = "mind-publish") -> str:
    """Synchronous publish on a withdrawal, a detached one when the slot is stale, else nothing."""
    if any(optional_module(name) is None for name in (".mind_cli", ".needs", ".history")):
        return "disabled"
    root = installation_root(Path(root).resolve())
    stamp = _stamp(root)
    slot = hub_root() / stamp["key"]
    _claim(slot, stamp)
    actor = operator(root, harness=harness, session_id=session_id)
    decision = hand_over(root, actor)
    pair = _pair(decision)
    with _locked(slot / ".require.lock"):  # the grant first: nothing below can lose it
        require = _quiet_json(slot / "require.json")
        withdrawn = require is not None and any(require.get(k) != v for k, v in pair.items())
        if withdrawn:
            _write_json(slot / "require.json", _pending(decision))
    seen = _quiet_json(slot / "seen.json") or {}
    found = _walked(root)
    stale = found is None or seen.get("fingerprint") != fingerprint(root, found)
    if (not withdrawn and stale and require is not None and not is_admin(decision)
            and _held_changed(found, seen.get("since", 0), decision, (root / "memory").resolve())):
        with _locked(slot / ".require.lock"):  # unconditional: it also voids a publish in flight
            _write_json(slot / "require.json", _pending(decision))
        withdrawn = True
    if withdrawn:
        return publish(root, wait=True)
    if stale:
        return "started" if _spawn(root, slot) else "running"
    return "fresh"


def _walked(root: Path) -> list | None:
    """Every Markdown file of memory, or None when memory moved under the walk or a folder cannot be read."""
    try:
        return list(_walk((root / "memory").resolve()))
    except OSError:
        return None


def _held_changed(found: list | None, since: int, decision: PolicyDecision, memory: Path) -> bool:
    """A document changed since the last publish began and the hand-over holds it now, under any class.
    It may be served, or in a publish still running, so it is treated as a withdrawal. So is a walk
    that failed, or a changed document that cannot be read: neither can show that nothing turned held."""
    if found is None:
        return True
    margin = since - 2_000_000_000  # coarse file-system clocks

    def held_now(canonical: str, path: Path) -> bool:
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            return False  # gone: the stale fingerprint republishes without it
        except OSError:
            return True
        return bytes_held(decision, canonical, data, root=memory) is not None
    return any(info.st_ctime_ns >= margin and held_now(canonical, path) for canonical, path, info in found)


def _spawn(root: Path, slot: Path) -> bool:
    """Start one detached publish. The child inherits the slot's launch lease and holds it until it
    exits, so Runtime calls arriving meanwhile start nothing more."""
    lease = os.open(slot / ".launch.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        env = {**os.environ, "EGREGORE_ROOT": str(root), "PYTHONSAFEPATH": "1",
               "PYTHONPATH": str(Path(__file__).resolve().parents[1])}
        subprocess.Popen([sys.executable, "-m", f"{__package__}.harness_cli", "mind", "publish", "--detached"],
                         cwd=root, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True, pass_fds=(lease,))
        return True
    finally:
        os.close(lease)


def observer(root: Path):
    """The Runtime's projection observer. It refreshes once as the Runtime is composed, so every
    Runtime call checks the slot before it answers (a denied or empty one included), and again after
    each authorized operation. Nothing happens until the map viewer creates the hub."""
    root = Path(root)
    if projection_root(root):  # a read-only copy hands nothing over
        return lambda event=None: None

    def notice(event=None) -> None:
        if os.path.isdir(hub_root()):
            refresh(root, harness=getattr(event, "harness", "mind"),
                    session_id=getattr(event, "session_id", "mind-publish"))
    try:
        notice()
    except Exception:
        pass  # as _notify isolates observers: the Runtime call goes on
    return notice


# ---- a projection root ---------------------------------------------------------------------

READ_ONLY = "This is a read-only copy; writing back comes with linked egregores"
REBUILDING = "this read-only copy is being rebuilt; try again shortly"
ROOT_VERSION = "egregore-projection-root/1"
_GENERATIONS = ("a" * 24, "b" * 24)  # two fixed names, so a Runtime and its search index over the copy keep a path
_SERVES: dict[str, tuple[float, bool]] = {}


def serves(memory: Path) -> bool:
    """Whether ``memory`` (``DIR/gen/<rev>/memory``) is the generation its projection root admits: false while the
    root is dark, rebuilt or serving another, and for a generation of anything but a projection root (a map slot).
    Judged again after ``held.FRESH_SECONDS``, so a process that outlives a withdrawal stops reading the generation
    it began on."""
    memory, now = Path(memory).resolve(), time.monotonic()
    seen = _SERVES.get(str(memory))
    if seen is None or now - seen[0] >= held.FRESH_SECONDS:
        generation = memory.parent
        found = admit(generation.parent.parent) if memory.name == "memory" and generation.parent.name == "gen" \
            and projection_root(generation.parent.parent) else None
        seen = _SERVES[str(memory)] = (now, bool(found and found.ready and found.generation == generation))
    return seen[1]


def materialize(root: Path, decision: PolicyDecision, dest: Path) -> tuple[str, int]:
    """``access materialize --as P --to DIR``: an outside principal's committed read grant as a read-only copy.

    DIR is built as a slot is: ``require.json`` first, one generation, ``current.json`` naming it and the same reuse
    key; ``DIR/memory`` links to it for a Runtime started over DIR, which finds the marker and reads only the
    generation DIR admits (``access.authorization_inputs``, ``policy.check``), so no reader pays for the holds again.
    The sources are memory at the decision's committed revision and the committed settings, judged with no hint or
    index, and no vectors or needs: of what DIR's reader can write, only a previous copy is read back, for a file
    whose source and redaction revision are unchanged. Anything that may withdraw (another revision of memory,
    another grant or hold set, or a refused principal) empties DIR before the build: no link, no generation, so a
    killed re-run leaves it dark. Returns "published" or "unchanged", and the documents served.
    """
    root, dest = Path(root).resolve(), Path(os.path.abspath(dest))
    if decision.audience != "outside" or decision.scope != "hand-over":
        raise ProjectionError("a read-only copy is made only from another principal's committed grant")
    if not decision.allowed or not decision.memory_revision:
        _revoke(root, decision, dest)
        raise ProjectionError("; ".join(decision.reasons))
    handle = decision.actor_id.removeprefix("principal:")
    dest = _place(dest)
    stamp = _owner(root, decision, dest)
    _claim(dest, stamp)
    _write_json(dest / ROOT_MARKER, {"version": ROOT_VERSION, "principal": handle, "note": READ_ONLY})
    with _locked(dest / ".build.lock"):
        if _quiet_json(dest / "stamp.json") != stamp:
            raise ProjectionError("this folder holds another copy")
        settings = committed_settings(root, decision)  # under the lock: a run decided earlier never lands later
        if settings is None:
            raise ProjectionError("the committed settings moved while this ran; run it again")
        _purge(dest)
        pair = {**_pair(decision), "memory_revision": decision.memory_revision}
        before, mark = _quiet_json(dest / "require.json"), _watermark(stamp)
        if not all(_descends(root, (seen or {}).get("memory_revision"), decision.memory_revision)
                   for seen in (before, _quiet_json(mark))):
            raise ProjectionError("this checkout's memory is behind the copy's; fetch memory and run again")
        if before is None or any(before.get(k) != v for k, v in pair.items()):
            _withdraw(dest, {**_pending(decision), **pair})  # it may withdraw: dark before anything can fail
        os.makedirs(mark.parent, mode=0o700, exist_ok=True)
        _write_json(mark, {"memory_revision": decision.memory_revision})
        scan = _scan(decision, root)
        require = {**scan.require(), "memory_revision": decision.memory_revision}
        if _quiet_json(dest / "require.json") != require:
            _withdraw(dest, require)  # held, released or renamed since: nothing served survives
        inputs, current = _Inputs({}, {}, ""), admit(dest)
        header = {**_header(scan, root, inputs, settings), "key": dest.name, "org_id": decision.org_id,
                  "memory_revision": decision.memory_revision}
        config = header["config"]
        _write_json(dest / "egregore.json", {"org_name": config.get("org_name") or "Egregore",
                                              "slug": config.get("slug") or "copy", "mode": "local"})
        if not os.path.lexists(dest / ".egregore-state.json"):
            _write_json(dest / ".egregore-state.json", {"github_username": handle, "display_name": handle})
        if current.ready and {k: v for k, v in current.manifest.items() if k not in ("generation", "files")} == header \
                and {e["path"]: e["sha"] for e in current.manifest["files"]} == {s.canonical: s.sha for s in scan.shown}:
            _serve(dest, current.generation.name)
            return "unchanged", len(scan.shown)
        # The generation served is kept for readers mid-read; one emptied away is built again under its own name,
        # so a Runtime and its search index over the copy keep their path.
        pointer = (_quiet_json(dest / "current.json") or {}).get("generation")
        rev = pointer if pointer in _GENERATIONS and not os.path.lexists(dest / "gen" / pointer) \
            else _GENERATIONS[pointer == _GENERATIONS[0]]
        _mkdir(dest / "gen")
        _remove(dest / "gen" / rev)
        try:
            _generation(scan, dest / "gen" / rev, header, current if current.ready else None, inputs, with_needs=False)
            _write_json(dest / "current.json", {"generation": rev})
        except BaseException:
            _remove(dest / "gen" / rev)
            raise
        _serve(dest, rev)
    return "published", len(scan.shown)


def _place(dest: Path) -> Path:
    """DIR: a new or empty folder, or an earlier copy, outside every Git work tree and the map's hub."""
    parent = dest.parent.resolve()
    if not dest.name or not parent.is_dir():
        raise ProjectionError("the folder's parent must exist")
    dest = parent / dest.name
    try:
        inside = bool(_git(parent, "rev-parse", "--git-dir"))  # a work tree or a Git folder: either is a repository
    except subprocess.CalledProcessError:
        inside = False
    if inside or dest.is_relative_to(hub_root().resolve()):
        raise ProjectionError("choose a folder outside every Git repository and the map's hub")
    if os.path.lexists(dest) and not projection_root(dest) and (os.path.islink(dest) or not os.path.isdir(dest)
                                                                 or os.listdir(dest)):
        raise ProjectionError("choose an empty folder, or one an earlier copy made")
    return dest


def _owner(root: Path, decision: PolicyDecision, dest: Path) -> dict[str, str]:
    """The stamp a copy carries: this installation's, for this principal of this organization."""
    return {"key": dest.name, "org_id": decision.org_id, "principal": decision.actor_id,
            "installation": str(installation_root(root))}


def _revoke(root: Path, decision: PolicyDecision, dest: Path) -> None:
    """A refused principal's earlier copy from this installation goes dark before the refusal is reported."""
    try:
        dest = dest.parent.resolve() / dest.name
        _private_dir(dest)
        if not projection_root(dest):
            return
    except OSError:
        return
    with _locked(dest / ".build.lock"):
        if _quiet_json(dest / "stamp.json") == _owner(root, decision, dest):
            _withdraw(dest, _pending(decision))


def _watermark(stamp: Mapping[str, str]) -> Path:
    """Where the sponsor records the newest memory revision it copied for this principal, to any folder however
    spelled: outside DIR, so DIR's reader can neither delete nor rewind it (``require.json`` is the reader's)."""
    owner = {field: stamp[field] for field in ("org_id", "principal", "installation")}
    return Path.home() / ".egregore" / "runtime" / "copies" / f"{_digest(owner)[:24]}.json"


def _descends(root: Path, served: object, revision: str) -> bool:
    """Whether memory at ``revision`` is the copy's ``served`` revision or newer, so a sponsor whose memory is
    behind never rolls the copy back. A value this module did not write could only come from DIR's reader."""
    if not isinstance(served, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", served):
        return True
    try:
        _git((root / "memory").resolve(), "merge-base", "--is-ancestor", served, revision)
    except subprocess.CalledProcessError:
        return False
    return True


def _withdraw(dest: Path, require: Mapping[str, str]) -> None:
    """Dark at once: every generation leaves DIR in one rename, then the requirement none meets is recorded and the
    link goes; the generations are deleted outside DIR, so a killed run leaves none in it to read."""
    if os.path.lexists(dest / "gen"):
        os.rename(dest / "gen", dest.parent / f".{dest.name}.withdrawn.{secrets.token_hex(6)}")
    _write_json(dest / "require.json", require)
    _unlink(dest / "memory")
    _purge(dest)


def _purge(dest: Path) -> None:
    """Delete generations an earlier, killed withdrawal moved beside DIR."""
    for name in os.listdir(dest.parent):
        if name.startswith(f".{dest.name}.withdrawn."):
            _remove(dest.parent / name)


def _serve(dest: Path, rev: str) -> None:
    """``DIR/memory`` names the generation served, and no other generation stays to be read. The others are removed
    through DIR/gen opened without following a link, so a link planted there removes nothing outside DIR."""
    link, target = dest / "memory", f"gen/{rev}/memory"
    if not (os.path.islink(link) and os.readlink(link) == target):
        _unlink(link)
        os.symlink(target, link)
    generations = os.open(dest / "gen", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for entry in os.listdir(generations):
            if entry == rev:
                continue
            if stat.S_ISDIR(os.lstat(entry, dir_fd=generations).st_mode):
                shutil.rmtree(entry, dir_fd=generations)
            else:
                os.unlink(entry, dir_fd=generations)
    finally:
        os.close(generations)


def _unlink(link: Path) -> None:
    if os.path.islink(link):
        os.unlink(link)
    elif os.path.lexists(link):
        raise ProjectionError("DIR/memory is not the copy's link; move it away and run again")


def _remove(path: Path) -> None:
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    elif os.path.lexists(path):
        os.unlink(path)
