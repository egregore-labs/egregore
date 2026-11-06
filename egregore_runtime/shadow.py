"""roster-v1-shadow: serve all-access and count where roster-v1 would hold.

Counts are kept by surface (the Runtime module that asked) and held class,
never by path, title or person, in a private per-user folder (0700, files
0600, never through a link). A process adds its counts once, when it exits.

No read waits for a tree to be built. ``policy.check`` holds a shadow read by
class 1 alone and hands the rest here (``defer``): the class roster-v1 would
hold comes from this user's verdict index when it matches the walk in effect.
Otherwise the read is bound to that walk and judged at exit by a detached
settler, which builds the tree and adds the count only while memory is still
as walked. Until it does, the read counts as ``pending``; a read nothing
could judge counts as ``unjudged``. The counts are complete or say they are
partial, never silently short.
"""

from __future__ import annotations

import atexit
from collections import Counter
from functools import lru_cache
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

PENDING, UNJUDGED = "pending", "unjudged"  # reads with a settler, and reads nothing could judge

_pending: dict[str, Counter] = {}  # counts file -> "surface|class", PENDING, UNJUDGED -> reads
# (counts file, memory root, release, walk digest) -> (path as named, path as resolved, content sha256)
#   -> surface -> reads
_deferred: dict[tuple[str, str, tuple[str, ...], str], dict[tuple[str, str, str], Counter]] = {}
_settlers: list[tuple[str, str, tuple[str, ...], str, dict]] = []
_registered: list = []
_LATER = object()


def _file(memory_root: Path) -> Path:
    key = hashlib.sha256(str(Path(memory_root).resolve()).encode("utf-8")).hexdigest()[:16]
    return Path.home() / ".egregore" / "runtime" / "shadow" / f"{key}.json"


@lru_cache(maxsize=16)
def _place(memory_root: str, home: str) -> tuple[Path, str]:
    """A memory root resolved and its counts file under ``home`` ($HOME), once per process: ``defer`` runs on
    every shadow read."""
    return Path(memory_root).resolve(), str(_file(Path(memory_root)))


def _private(path: Path, flags: int) -> int:
    """Open a counts file in this user's private folder, never through a link."""
    if flags & os.O_CREAT:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder = os.lstat(path.parent)
    if not stat.S_ISDIR(folder.st_mode) or folder.st_uid != os.getuid():
        raise PermissionError(f"{path.parent} is not this user's folder")
    if stat.S_IMODE(folder.st_mode) != 0o700:
        os.chmod(path.parent, 0o700)
    descriptor = os.open(path, flags | os.O_NOFOLLOW, 0o600)
    try:
        if os.fstat(descriptor).st_uid != os.getuid():
            raise PermissionError(f"{path} is not this user's file")
        os.fchmod(descriptor, 0o600)
    except OSError:
        os.close(descriptor)
        raise
    return descriptor


def _surface() -> str:
    frame = sys._getframe(1)
    while frame is not None and frame.f_globals.get("__name__", "").rsplit(".", 1)[-1] in {"shadow", "policy"}:
        frame = frame.f_back
    return (frame.f_globals.get("__name__", "") if frame is not None else "").rsplit(".", 1)[-1] or "unknown"


def _register() -> None:
    if not _registered:
        _registered.append(atexit.register(flush, wait=False))


def note(memory_root: Path, held_class: int) -> None:
    _register()
    _pending.setdefault(str(_file(memory_root)), Counter())[f"{_surface()}|{held_class}"] += 1


def _classify(tree, root: Path, relative: str, physical: str, sha: str, deep: bool):
    """The class roster-v1 would hold for one read, 0 for none. Not ``deep``: only from what the tree already
    judged for these bytes (``Tree.known``), else _LATER. ``deep``: bytes it never judged are read again and judged, and None when
    they have changed since the read or are gone."""
    found = tree.known(relative, sha, physical)
    if found is None and not deep:
        return _LATER
    if found is None:
        try:
            raw = (root / physical).read_bytes()
        except OSError:
            return None
        if hashlib.sha256(raw).hexdigest() != sha:
            return None
        found = tree.classes(relative, raw, physical)
    return next((number for number in found if number != 1), 0)


def defer(memory_root: Path, release, relative: str, physical: str, data: bytes) -> None:
    """A read served under roster-v1-shadow that class 1 did not hold. The class roster-v1 would hold is taken
    from this user's verdict index when it matches the walk in effect (one walk per FRESH_SECONDS; no document
    is read and nothing is built). Otherwise the read is judged off the read path, against that walk or not at
    all."""
    from . import held

    _register()
    root, counts = _place(str(memory_root), os.environ.get("HOME", ""))
    release, surface = tuple(sorted(set(release))), _surface()
    read = (relative, physical, hashlib.sha256(data).hexdigest())
    try:
        tree, walk = held.current(root, release, trust_cache=True, build=False)
        would = _classify(tree, root, *read, deep=False) if tree is not None else _LATER
    except Exception:  # noqa: BLE001 - a read bound to no walk is counted as unjudged, never dropped
        walk, would = "", _LATER
    if would is _LATER:
        _deferred.setdefault((counts, str(root), release, walk), {}).setdefault(read, Counter())[surface] += 1
    elif would:
        _pending.setdefault(counts, Counter())[f"{surface}|{would}"] += 1


def _reads(reads: dict) -> int:
    return sum(sum(surfaces.values()) for surfaces in reads.values())


def _judge(root: str, release: tuple[str, ...], walk: str, reads: dict) -> Counter:
    """Counts for reads made against ``walk``: every one unjudged unless memory is still as walked then."""
    from . import held

    judged, memory = Counter(), Path(root)
    try:
        tree, now = held.current(memory, release, trust_cache=True) if walk and memory.is_dir() else (None, "")
        if tree is None or now != walk:
            raise LookupError("memory is no longer as walked when these reads were served")
        for read, surfaces in reads.items():
            would = _classify(tree, memory, *read, deep=True)
            if would is None:
                judged[UNJUDGED] += sum(surfaces.values())
            elif would:
                for surface, count in surfaces.items():
                    judged[f"{surface}|{would}"] += count
    except Exception:  # noqa: BLE001 - a read nothing judged is counted as such
        judged = Counter({UNJUDGED: _reads(reads)})
    return judged


def settle(wait: bool = False) -> None:
    """Judge the deferred reads against the walk each was served in: now, building that tree, when ``wait``;
    otherwise (at exit) they are marked pending and go to a settler once ``flush`` has written the mark."""
    while _deferred:
        (counts, root, release, walk), reads = _deferred.popitem()
        counter = _pending.setdefault(counts, Counter())
        if wait:
            counter.update(_judge(root, release, walk, reads))
        else:
            counter[PENDING] += _reads(reads)
            _settlers.append((counts, root, release, walk, reads))


def _add(path: Path, counter: Counter) -> None:
    try:
        with os.fdopen(_private(path, os.O_RDWR | os.O_CREAT), "r+", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            handle.seek(0)
            try:
                saved = Counter({key: value for key, value in json.loads(handle.read() or "{}").items()
                                 if isinstance(value, int)})
            except (ValueError, AttributeError):
                saved = Counter()
            saved.update(counter)
            handle.seek(0)
            handle.truncate()
            json.dump({key: value for key, value in sorted(saved.items()) if value}, handle)
    except OSError:
        pass


def _payload(counts: str, root: str, release: tuple[str, ...], walk: str, reads: dict) -> bytes:
    return json.dumps({"counts": counts, "root": root, "release": list(release), "walk": walk,
                       "reads": [[*read, dict(surfaces)] for read, surfaces in reads.items()]}).encode()


def _spawn(payload: bytes) -> bool:
    """Start a detached settler (``settle_detached``) for one payload: paths and digests go through a pipe, so
    nothing a member read is written to disk."""
    package = Path(__file__).resolve().parent
    code = ("import sys;payload=sys.stdin.buffer.read();sys.path.insert(0,sys.argv[1]);"
            "import importlib;importlib.import_module(sys.argv[2]).settle_detached(payload)")
    try:
        child = subprocess.Popen([sys.executable, "-c", code, str(package.parent), __name__], stdin=subprocess.PIPE,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(package.parent),
                                 start_new_session=True, close_fds=True)
    except (OSError, ValueError):
        return False
    try:
        child.stdin.write(payload)
        child.stdin.close()
    except OSError:
        return False
    child.returncode = 0  # detached: it outlives this process, which never waits for it
    return True


def settle_detached(payload: bytes) -> None:
    """The settler: judge the reads one process handed over at exit, add their counts and take them off pending."""
    request = json.loads(payload)
    reads = {tuple(read[:3]): Counter(read[3]) for read in request["reads"]}
    judged = _judge(request["root"], tuple(request["release"]), request["walk"], reads)
    judged[PENDING] -= _reads(reads)
    _add(Path(request["counts"]), judged)


def flush(wait: bool = True) -> None:
    """Write this process's counts, judging every deferred read first. At exit (``wait=False``) nothing is
    walked or built: deferred reads go to a settler, and their pending mark is written before it starts."""
    settle(wait)
    while _pending:
        path, counter = _pending.popitem()
        if +counter or -counter:
            _add(Path(path), counter)
    while _settlers:
        counts, root, release, walk, reads = _settlers.pop()
        if not _spawn(_payload(counts, root, release, walk, reads)):
            _add(Path(counts), Counter({PENDING: -_reads(reads), UNJUDGED: _reads(reads)}))


def tally(memory_root: Path) -> tuple[dict[tuple[str, int], int], dict[str, int]]:
    """This memory's disagreements by (surface, class), and the reads they lack (``pending`` with a settler,
    ``unjudged`` judged by nothing), from one reading of the counts file."""
    flush()
    try:
        with os.fdopen(_private(_file(memory_root), os.O_RDONLY), encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_SH)
            saved = json.loads(handle.read())
    except (OSError, ValueError):
        saved = {}
    saved = saved if isinstance(saved, dict) else {}
    counted = {}
    for key, value in saved.items():
        surface, _, number = str(key).rpartition("|")
        if surface and number.isdigit() and isinstance(value, int):
            counted[(surface, int(number))] = value
    return counted, {key: saved[key] for key in (PENDING, UNJUDGED) if isinstance(saved.get(key), int) and saved[key]}


def counts(memory_root: Path) -> dict[tuple[str, int], int]:
    """Every recorded disagreement for this memory, by (surface, class)."""
    return tally(memory_root)[0]


def unsettled(memory_root: Path) -> dict[str, int]:
    """Reads the counts do not hold yet; either one makes them partial."""
    return tally(memory_root)[1]
