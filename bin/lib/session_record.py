"""Session-record lifecycle and personal controls; transcript parsing is in session_trail.

All content writes use capture-run.sh. Record captures and batch publication share
one lock keyed by the physical memory repository. No pull, merge, or rebase runs.
Native hook admission reads only a bounded header; parsing and model calls run
in the detached worker.
"""
from __future__ import annotations

import argparse
import atexit
from collections import Counter
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import string
import subprocess
import sys
import tempfile
import textwrap
import time
import unicodedata
from uuid import UUID

import session_trail as st

SELF = Path(__file__).resolve()
SAFE_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")

# Public presentation code has no private producer dependency. Older partial
# installations can still render human records; unknown native data stays out.
_subject_path = SELF.parents[2] / "egregore_runtime/record_subject.py"
_subject = None
if _subject_path.is_file():
    _spec = importlib.util.spec_from_file_location("egregore_record_subject", _subject_path)
    _subject = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_subject)


def classify_record(meta):
    if _subject is not None:
        return _subject.classify_record(meta)
    marked = any(isinstance(key, str) and key.strip().strip("\"'").casefold() in
                 {"producer", "producer_principal_id", "producer_identity", "record_owner_actor_id", "subject_kind"}
                 and (key != "subject_kind" or value != "human-session") for key, value in meta.items())
    return "unsupported-native" if marked else "human-session"


def record_subject(meta, text=""):
    return _subject.record_subject(meta, text) if _subject else {"subject_kind": classify_record(meta)}


def native_record_reader(ctx):
    """Read-only Runtime authority for new native presentation; no identity migration."""
    try:
        sys.path.insert(0, str(SELF.parents[2]))
        from egregore_runtime.identity import LocalIdentityResolver
        from egregore_runtime.access import authorization_inputs
        from egregore_runtime.contracts import Permission
        from egregore_runtime.policy import policy_for, check
        actor = LocalIdentityResolver(ctx.root, persist_migrations=False).resolve(session_id="records-view", harness="shell")
        state = read_json(ctx.state_path)
        if (actor.actor.actor_id != state.get("actor_id") or not actor.membership
                or actor.membership.membership_id != state.get("membership_id")
                or actor.membership.actor_id != actor.actor.actor_id or actor.membership.status != "active"
                or actor.membership.org_id != actor.profile.org_id):
            return "", None
        decision = policy_for(authorization_inputs(ctx.root)).authorize_action(actor, Permission.READ)
        def reader(path, meta):
            verdict = check(decision, "memory/" + Path(path).relative_to(ctx.memory).as_posix(), root=ctx.memory)
            if not verdict.allowed:
                return "held" if verdict.reason.startswith("held:") else False
            return "held" if native_record_held(ctx, str(meta.get("session", ""))) else True
        return actor.actor.actor_id, reader
    except (ImportError, OSError, ValueError, TypeError, KeyError):
        return "", None


def _native_control_directory(path, *, optional=True):
    try:
        info = path.lstat()
    except FileNotFoundError:
        if optional:
            return False
        raise ValueError("native record control coverage unavailable")
    if not stat.S_ISDIR(info.st_mode) or not info.st_mode & 0o444 or not info.st_mode & 0o111:
        raise ValueError("native record control coverage unavailable")
    return True


def _native_control_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("native record control coverage unavailable")
        value[key] = item
    return value


def _native_control_inventory(ctx, *, deadline_monotonic=None):
    """Strict read-only control coverage; no transcript or canonical inventory.

    At most 4096 visited trail-directory entries, 64 instance trail roots,
    4096 hold entries and 4096 alias rows are admitted. Pi/Prime alias files
    are each at most 1 MiB; every selected root
    must satisfy the existing instance-folder authority. Unknown or damaged
    controls refuse coverage rather than silently meaning 'unheld'.
    """
    def current():
        if deadline_monotonic is not None and time.monotonic() >= deadline_monotonic:
            raise ValueError("native record control coverage unavailable")
    current()
    parent, trails = ctx.home / ".egregore", ctx.home / ".egregore/trails"
    if not _native_control_directory(parent) or not _native_control_directory(trails):
        return set(), []
    names = {ctx.prefix, ctx.folder, *(ctx.prefix + "--" + name for name in ("codex", "pi", "prime"))}
    with os.scandir(trails) as folders:
        for visited, folder in enumerate(folders, 1):
            current()
            if visited > 4096:
                raise ValueError("native record control coverage unavailable")
            if folder.name.startswith(ctx.prefix + "--"):
                names.add(folder.name)
                if len(names) > 64:
                    raise ValueError("native record control coverage unavailable")
    markers, rows, seen_hashes, entries = set(), [], {}, 0
    for name in sorted(names):
        current()
        if "/" in name or name not in {ctx.prefix, ctx.folder} and not name.startswith(ctx.prefix + "--"):
            raise ValueError("native record control coverage unavailable")
        base = trails / name
        if not _native_control_directory(base):
            continue
        known = {ctx.prefix, *(ctx.prefix + "--" + name for name in ("codex", "pi", "prime"))}
        if name in known:
            if not st.valid_trail_folder(base, ctx.projects, ctx.prefix):
                raise ValueError("native record control coverage unavailable")
        else:
            # Exact legacy counterpart, using the same within-instance owner
            # predicate as valid_trail_folder, without enumerating transcripts.
            project = ctx.projects / name
            if (base.resolve().parent != trails.resolve() or not _native_control_directory(project, optional=False)
                    or not st.within_instance(project, ctx.projects, ctx.prefix)):
                raise ValueError("native record control coverage unavailable")
        holds = base / "holds"
        if _native_control_directory(holds):
            with os.scandir(holds) as found:
                for marker in found:
                    current()
                    entries += 1
                    info = marker.stat(follow_symlinks=False)
                    if entries > 4096 or not SAFE_ID.fullmatch(marker.name) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                        raise ValueError("native record control coverage unavailable")
                    markers.add(marker.name)
        aliases_path = base / "aliases.jsonl"
        try:
            info = aliases_path.lstat()
        except FileNotFoundError:
            continue
        if (name not in {ctx.prefix + "--pi", ctx.prefix + "--prime"} or not stat.S_ISREG(info.st_mode)
                or not info.st_mode & 0o444 or info.st_nlink != 1 or info.st_size > 1024 * 1024):
            raise ValueError("native record control coverage unavailable")
        descriptor = os.open(aliases_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_ino != info.st_ino or before.st_dev != info.st_dev:
                raise ValueError("native record control coverage unavailable")
            data = stream.read(1024 * 1024 + 1)
            after = os.fstat(stream.fileno())
        if len(data) > 1024 * 1024 or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns) or len(data) != before.st_size:
            raise ValueError("native record control coverage unavailable")
        for line in data.decode("utf-8").splitlines():
            current()
            row = json.loads(line, object_pairs_hook=_native_control_object)
            if (not isinstance(row, dict) or not isinstance(row.get("path"), str) or len(row["path"]) > 4096
                    or not isinstance(row.get("hash"), str) or not re.fullmatch(r"[a-f0-9]{64}", row["hash"])
                    or not isinstance(row.get("session"), str) or not SAFE_ID.fullmatch(row["session"])
                    or row["hash"] in seen_hashes and seen_hashes[row["hash"]] != row["session"]):
                raise ValueError("native record control coverage unavailable")
            seen_hashes[row["hash"]] = row["session"]
            rows.append(row)
            if len(rows) > 4096:
                raise ValueError("native record control coverage unavailable")
    current()
    return markers, rows


def native_record_holds(ctx, sids, *, deadline_monotonic=None):
    """One strict, bounded personal-control inventory for selected native IDs."""
    if (not isinstance(sids, (tuple, list, set, frozenset)) or len(sids) > 64
            or any(not isinstance(sid, str) or not SAFE_ID.fullmatch(sid) for sid in sids)
            or deadline_monotonic is not None and (type(deadline_monotonic) not in (int, float)
                                                  or not math.isfinite(deadline_monotonic))):
        raise ValueError("native record control coverage unavailable")
    def current():
        if deadline_monotonic is not None and time.monotonic() >= deadline_monotonic:
            raise ValueError("native record control coverage unavailable")
    current()
    markers, rows = _native_control_inventory(ctx, deadline_monotonic=deadline_monotonic)
    current()
    # Same transitive session/hash graph as native_record_held; never interpret
    # a failed inventory as an empty set of holds or recover from transcripts.
    related = {}
    for row in rows:
        current()
        left, right = row["session"], row["hash"]
        related.setdefault(left, set()).add(right)
        related.setdefault(right, set()).add(left)
    held_ids = set()
    for sid in set(sids):
        pending, seen = [sid], set()
        while pending:
            current()
            item = pending.pop()
            if item in seen:
                continue
            seen.add(item)
            if item in markers:
                held_ids.add(sid)
                break
            pending.extend(related.get(item, ()) - seen if item in related else ())
    current()
    return frozenset(held_ids)


def native_record_held(ctx, sid, *, strict=False):
    """Native control/alias holds only; never recover aliases from transcripts."""
    if not SAFE_ID.fullmatch(sid):
        if strict:
            raise ValueError("native record control coverage unavailable")
        return False
    if strict:
        return sid in native_record_holds(ctx, (sid,))
    identities = {sid}
    rows = list(aliases(ctx))
    while True:
        related = {value for row in rows if row["session"] in identities or row["hash"] in identities
                   for value in (row["session"], row["hash"])}
        if related <= identities:
            break
        identities.update(related)
    for base in trail_bases(ctx):
        directory = base / "holds"
        try:
            if not stat.S_ISDIR(directory.lstat().st_mode) or directory.resolve().parent != base.resolve():
                continue
            if any(SAFE_ID.fullmatch(sid) and stat.S_ISREG((directory / sid).lstat().st_mode) for sid in identities if (directory / sid).exists()):
                return True
        except OSError:
            continue
    return False


def read_json(path, default=None):
    try:
        value = json.loads(Path(path).read_text())
        return value if isinstance(value, dict) else ({} if default is None else default)
    except (OSError, ValueError):
        return {} if default is None else default


def private_dir(path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def atomic(path, text, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".record-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return int(pid) > 0
    except PermissionError:
        return True
    except (ValueError, OSError, TypeError):
        return False


class Lock:
    """mkdir lock, explicit ownership, atomic owner handover, stale recovery."""
    def __init__(self, path, mode="write"):
        self.path, self.mode = Path(path), mode

    def owner(self):
        try:
            return int((self.path / "owner").read_text())
        except (OSError, ValueError):
            return None

    def stale(self):
        owner = self.owner()
        if owner is not None:
            return not alive(owner)
        try:
            return not (self.path / "owner").exists() and time.time() - self.path.stat().st_mtime > 60
        except OSError:
            return False

    def acquire(self, wait=0):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        until = time.monotonic() + wait
        while True:
            for attempt in range(2):
                try:
                    self.path.mkdir(mode=0o700)
                    atomic(self.path / "owner", str(os.getpid()))
                    atomic(self.path / "mode", self.mode)
                    atomic(self.path / "since", str(time.time()))
                    atexit.register(self.release)
                    return True
                except FileExistsError:
                    # Give an entrant time to initialize owner after mkdir;
                    # a crash in that gap becomes recoverable after one minute.
                    if attempt == 0 and self.stale():
                        recovery = self.path.with_name(self.path.name + ".recovering")
                        try:
                            recovery.mkdir()
                        except OSError:
                            break
                        try:
                            if self.stale():
                                shutil.rmtree(self.path)
                        except OSError:
                            pass
                        finally:
                            recovery.rmdir()
                        continue
                    break
            if time.monotonic() >= until:
                return False
            time.sleep(0.05)

    def release(self):
        if self.owner() == os.getpid():
            shutil.rmtree(self.path, ignore_errors=True)

    def handover(self, pid):
        if self.owner() != os.getpid():
            raise RuntimeError("session lock ownership changed")
        atomic(self.path / "owner", str(pid))


class Context:
    def __init__(self, root, folder=None):
        self.root = Path(root).resolve()
        self.home = Path(os.environ["HOME"])
        self.projects = self.home / ".claude/projects"
        self.prefix = st.instance_prefix(self.root)
        self.folder = folder or self.prefix
        self.base = self.home / ".egregore/trails" / self.folder
        self.memory = (self.root / "memory").resolve()
        self.state_path = self.root / ".egregore-state.json"
        self.reload()

    def reload(self):
        self.config = read_json(self.root / "egregore.json")
        self.policy = self.config.get("features", {}).get("session_records", {})
        if not isinstance(self.policy, dict):
            self.policy = {}
        self.state = read_json(self.state_path)
        self.actor_id = self.state.get("actor_id")
        self.author = re.sub(r"[^a-zA-Z0-9_-]", "", self.state.get("github_username", ""))
        self.display = self.state.get("display_name", self.author)
        return self

    def identities(self):
        """The names this person is known by in the records, casefolded: the
        GitHub username and the display name."""
        return {str(value).casefold() for value in (self.author, self.display) if value}

    def enabled(self):
        self.reload()
        return self.policy.get("enabled", False) is True and self.state.get("session_records_enabled", True) is True

    def held(self, sid, path=None):
        identities = {sid}
        markers = set()
        for base in trail_bases(self):
            directory = base / "holds"
            try:
                if (not stat.S_ISDIR(directory.lstat().st_mode)
                        or directory.resolve().parent != base.resolve()):
                    continue
                markers.update(item.name for item in directory.iterdir()
                               if SAFE_ID.fullmatch(item.name) and stat.S_ISREG(item.lstat().st_mode))
            except OSError:
                continue
        if not markers:
            return False
        if path is not None:
            info = transcript_info(self, path)
            if info:
                identities.add(info[1])
                if info[0] in ("pi", "prime"):
                    identities.update(path_identity(value) for value in (path, Path(path).resolve()))
        # Aliases connect a producer's original spelling with the durable native
        # id. Resolve the complete equivalence class regardless of line order.
        rows = list(aliases(self))
        while True:
            related = {value for row in rows
                       if row["session"] in identities or row["hash"] in identities
                       for value in (row["session"], row["hash"])}
            if related <= identities:
                break
            identities.update(related)
        if identities & markers:
            return True
        # Older Pi sessions may predate alias capture. Publications only carry
        # the native id, so recover physical-path hashes from admitted headers
        # when a hash hold exists. No Codex index or transcript body is needed.
        hashes = {value for value in markers if re.fullmatch(r"[a-f0-9]{64}", value)}
        if path is None and hashes:
            for harness in ("pi", "prime"):
                base = self.home / ("." + harness) / "agent/sessions"
                for directory, dirs, files in os.walk(base, followlinks=False):
                    if len(Path(directory).relative_to(base).parts) >= 3:
                        dirs[:] = []
                    for name in files:
                        candidate = Path(directory) / name
                        if candidate.suffix != ".jsonl" or not regular(candidate):
                            continue
                        try:
                            values = {path_identity(candidate), path_identity(candidate.resolve())}
                        except (OSError, RuntimeError):
                            continue
                        if not values & hashes:
                            continue
                        info = transcript_info(self, candidate)
                        if info and info[0] in ("pi", "prime") and info[1] in identities:
                            return True
        return False

    def safe_base(self):
        if self.base.exists() or self.base.is_symlink():
            return st.valid_trail_folder(self.base, self.projects, self.prefix)
        names = {self.prefix, *(self.prefix + "--" + h for h in ("codex", "pi", "prime")),
                 *(p.name for p in st.transcript_folders(self.projects, self.prefix))}
        return self.folder in names and self.base.parent == self.home / ".egregore/trails"

    def model_enabled(self):
        self.reload()
        return self.policy.get("model", "haiku") != "none" and self.state.get("session_records_model_call", True) is not False

    def lock(self, sid, mode="write"):
        return Lock(self.base / "locks" / sid, mode)

    def error(self, reason):
        if not self.safe_base():
            return
        private_dir(self.base)
        path = self.base / "errors.log"
        try:
            old = path.read_text()[-900_000:] if path.exists() else ""
            atomic(path, (old + f"{datetime.now(timezone.utc).isoformat()} {reason}\n")[-1_000_000:])
        except OSError:
            pass

    def set_state(self, key, value):
        # A worktree links the checkout's state file (bin/worktree-create.sh):
        # the write follows the link, so the installation keeps one state and
        # no answer given in a worktree is stranded in a copy that replaced it.
        target = self.state_path.resolve()
        lock = Lock(target.with_name(".egregore-record-settings.lock"))
        if not lock.acquire(wait=10):
            raise RuntimeError("personal settings are busy")
        try:
            state = read_json(target)
            state[key] = value
            atomic(target, json.dumps(state, indent=2) + "\n")
        finally:
            lock.release()
        self.reload()

    def memory_lock(self):
        key = hashlib.sha256(str(self.memory).encode()).hexdigest()[:16]
        return Lock(self.home / ".egregore/locks" / ("memory-" + key))


def metadata(text):
    result = {}
    front = text.split("---", 2)
    if text.startswith("---\n") and len(front) == 3:
        for line in front[1].splitlines():
            key, sep, value = line.partition(":")
            if sep:
                value = value.strip()
                try:
                    value = json.loads(value)
                except ValueError:
                    pass
                result[key] = value
    for key, value in re.findall(r"^\*\*([^*]+)\*\*:\s*(.*)$", text, re.M):
        if key == "Date":
            result["started_at"] = value
        result.setdefault(key.lower(), value)
    return result


def sessions_directory(memory):
    """Authorize the physical memory root before traversing any session path."""
    try:
        root = Path(memory).resolve(strict=True)
        sessions = root / "sessions"
        if stat.S_ISDIR(sessions.lstat().st_mode) and sessions.resolve(strict=True).is_relative_to(root):
            return sessions
    except (OSError, RuntimeError):
        pass
    return None


def dated_record_paths(sessions, start, end):
    """Records live at sessions/YYYY-MM/DD-*.md, named by their UTC date. Keep
    the month folders and day names within a day of the window, so a local date
    near midnight is never missed; a name without a day prefix is kept."""
    first, last = start - timedelta(days=1), end + timedelta(days=1)
    month = date(first.year, first.month, 1)
    while month <= last:
        try:
            paths = sorted((sessions / month.strftime("%Y-%m")).glob("*.md"))
        except OSError:
            paths = []
        for path in paths:
            day = re.match(r"(\d{2})-", path.name)
            try:
                when = month.replace(day=int(day[1])) if day else None
            except ValueError:
                when = None
            if when is None or first <= when <= last:
                yield path
        month = (month + timedelta(days=32)).replace(day=1)


def record_files(memory, start=None, end=None):
    """Every record, or with a window only the files named inside it."""
    sessions = sessions_directory(memory)
    if sessions is None:
        return
    paths = sorted(sessions.glob("**/*.md")) if start is None else dated_record_paths(sessions, start, end or start)
    for path in paths:
        try:
            if stat.S_ISREG(path.lstat().st_mode) and path.resolve().is_relative_to(sessions):
                with path.open("rb") as stream:
                    text = stream.read(256 * 1024).decode("utf-8", errors="replace")
                yield path, metadata(text), text
        except (OSError, UnicodeError):
            continue


def all_records(ctx):
    yield from record_files(ctx.memory)


def digest_key(line):
    return " ".join("".join(c for c in line.casefold()
                            if c not in string.punctuation and not unicodedata.category(c).startswith("P")).split())


def digest_lines(text):
    """Only the three record sections participate; prompt/detail sections do not.
    A placeholder line is skipped only when it is the whole line, so a real
    item that begins "None recorded for the failed restore" is read."""
    section = None
    seen = set()
    for raw in text.splitlines():
        heading = re.fullmatch(r"##\s+(.+?)\s*", raw)
        if heading:
            name = heading[1]
            if name in ("Prompts", "Said"):
                break
            section = name if name in ("Decided", "Open", "Risks") and name not in seen else None
            seen.add(name)
            continue
        line = raw.strip()
        bullet = re.match(r"^[-*+]\s+", line)
        if not section or not line or (section != "Risks" and not bullet):
            continue
        if bullet:
            line = line[bullet.end():].strip()
        if st.PLACEHOLDER_RE.fullmatch(line):
            continue
        yield section, line


# Open items. An item's id is the first six hex digits of the SHA-256 of its
# digest key, the normalised line without its owner, so two records raising
# the same item share one id. The ledger beside the records holds events of
# ids and states only, never item text, and the last event for an id wins.
# Resolution and relevance are separate. A mention is evidence, never an
# instruction to reopen or renew an item. Open items become stale fourteen
# days after their first observation or explicit reactivation. Stale items
# remain discoverable but leave the active carry; terminal events stay terminal
# until an explicit reactivation. Reads never append events.
CARRY_DAYS = 14
STALE_DAYS = 14
EXPIRE_DAYS = STALE_DAYS  # Compatibility for callers; no history expires.
LEDGER = "open-items.jsonl"
ITEM_STATES = ("closed", "filed", "expired", "active", "stale", "superseded", "dismissed")
ITEM_ID = re.compile(r"[0-9a-f]{6}")
# Records often write the absence of an owner in place of one.
NO_OWNER = re.compile(
    r"^(?:owner\s*:?\s*)?(?:unstated|unowned|unassigned|unknown|unclear|tbd|none|nobody|no one)\b"
    r"|\b(?:no owner|owners? (?:unstated|unknown|unclear|tbd|to decide|not stated)|unstated owner"
    r"|ownership (?:pending|unclear|unstated))\b", re.I)
ISSUE_FLAGS = ("--kind", "improvement", "--area", "other", "--severity", "normal")
ISSUE_LABELS = ["kind:improvement", "area:other", "severity:normal"]
# The reflex runner cuts a probe line at this length (bin/lib/reflexes.py).
REFLEX_LINE = 160


def item_id(key):
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:6]


def open_owner(line):
    """An Open bullet's item, its owner as written, and whether it names none."""
    item, sep, written = line.rpartition(" — ")
    item, written = (item.strip(), " ".join(written.split())) if sep else (line, "")
    owner = re.sub(r"^owner\s*:\s*", "", written, flags=re.I).rstrip(" .")
    return item, owner, not owner or bool(NO_OWNER.search(written))


def clip(value, limit):
    value = " ".join(str(value).split())
    return value if len(value) <= limit else value[:max(1, limit - 1)] + "…"


def record_day(meta):
    """A record's local date and start, from its offset timestamp or its date."""
    try:
        started = datetime.fromisoformat(str(meta.get("started_at", "")).replace("Z", "+00:00"))
        if started.tzinfo is not None:
            stamp = started.astimezone()
            return stamp.date(), stamp
    except ValueError:
        pass
    try:
        return date.fromisoformat(str(meta.get("date", ""))[:10]), None
    except ValueError:
        return None, None


def default_owner(owner, ownerless, author):
    """The owner an Open line names, else the author of the record that left
    it: a thread nobody named belongs to the person whose session raised it.
    A record without an author leaves it unowned, as before."""
    if not ownerless:
        return owner
    return author if author and author != "unstated" else "unowned"


def note_raise(raised, ident, order, item, owner, ownerless, topic, author=""):
    """Keep an item's first date, its newest wording, its newest named owner
    and the author of its newest raise."""
    info = raised.setdefault(ident, {"first": order[0], "latest": None, "owner": None})
    info["first"] = min(info["first"], order[0])
    if info["latest"] is None or order > info["latest"][0]:
        info["latest"] = (order, item, topic, author)
    if not ownerless and (info["owner"] is None or order > info["owner"][0]):
        info["owner"] = (order, owner)


def raised_row(ident, info, today):
    order, item, topic, author = info["latest"]
    named = info["owner"]
    return {"id": ident, "line": item, "topic": topic, "path": order[2],
            "age": (today - info["first"]).days, "first": info["first"].isoformat(),
            "ownerless": named is None, "owner": default_owner(named[1] if named else "", named is None, author)}


def owner_label(row, default=" by default"):
    """An owner as the digest and the table show it: named, or the record's
    author marked as a default."""
    return row["owner"] + (default if row["ownerless"] and row["owner"] != "unowned" else "")


def mine(rows, identities):
    """The rows whose owner is one of the person's identities."""
    return [row for row in rows if row["owner"].casefold() in identities]


def ledger_lines(memory, name):
    """Stream complete history with bounded lines; malformed large lines are skipped."""
    sessions = sessions_directory(memory)
    if sessions is None:
        return
    try:
        descriptor = os.open(sessions / name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                return
            while True:
                line = stream.readline(65537)
                if not line:
                    break
                if len(line) > 65536:
                    while line and not line.endswith(b"\n"):
                        line = stream.readline(65537)
                    continue
                yield line.decode("utf-8", errors="replace")
    except OSError:
        return


def ledger_events(memory):
    """The latest explicit disposition, without losing old closures to a read window."""
    latest = {}
    for index, line in enumerate(ledger_lines(memory, LEDGER)):
        try:
            event = json.loads(line)
        except (ValueError, RecursionError):
            continue
        if (not isinstance(event, dict) or not isinstance(event.get("id"), str)
                or not ITEM_ID.fullmatch(event["id"]) or event.get("state") not in ITEM_STATES):
            continue
        order = (event_time(event.get("at")) or 0.0, index)
        if event["id"] not in latest or order >= latest[event["id"]][0]:
            latest[event["id"]] = (order, event)
    return {ident: event for ident, (_, event) in latest.items()}


def gate_flakes(memory, session):
    """The CI jobs that flaked on the merges a session made, in ledger order.

    The merge gate appends one line per decision to sessions/gate.jsonl; a
    merge names the session that ran it and the jobs that failed once and
    passed on a re-run. Blank, malformed and unknown lines are skipped, never
    fatal, and the aggregate `Full CI result` job is never a flake. A name
    that cannot be written as UTF-8 is skipped, so no line stops the record.
    """
    jobs, seen = [], set()
    for line in ledger_lines(memory, GATE_LEDGER) if session else ():
        try:
            event = json.loads(line)
        except (ValueError, RecursionError):
            continue
        if not isinstance(event, dict) or event.get("kind") != "merge" or event.get("session") != session:
            continue
        flaked = event.get("flaked")
        for name in flaked if isinstance(flaked, list) else ():
            name = " ".join(name.split()) if isinstance(name, str) else ""
            if (not name or len(name) > 120 or name.startswith("Full CI result")
                    or re.search(r"[\x00-\x1f\x7f]", name) or name in seen):
                continue
            try:
                name.encode("utf-8")
            except UnicodeEncodeError:
                continue
            seen.add(name)
            jobs.append(name)
    return jobs


def raise_is_open(event, raised_at):
    """Repeated evidence cannot reopen a resolved item."""
    return event is None or event.get("state") in ("active", "stale")


def collect_digest(memory, *, author="", person="", days=1, since=None, today=None, records=None,
                   carry_days=CARRY_DAYS, events=None, actor_id="", native_reader=None):
    """Project open resolution and active/stale relevance from append-only history.

    Original age never resets. Only an explicit active event renews relevance;
    reading or mentioning an old item cannot reactivate it. carry_days=0 skips
    the historical projection for callers that only need recent record facts.
    """
    today = today or datetime.now().date()
    if isinstance(today, str):
        today = date.fromisoformat(today)
    start = date.fromisoformat(since) if isinstance(since, str) else since
    start = start or today - timedelta(days=max(0, days))
    carry_days = max(0, min(int(carry_days), STALE_DAYS))
    earliest = date.min if carry_days else start
    result = {"since": start.isoformat(), "today": today.isoformat(), "sessions": 0, "yours": 0,
              "others": 0, "decided": [], "open": [], "risks": [], "carried": [], "stale": [],
              "spirit_intents": 0, "your_spirit_intents": 0, "spirit_records": [],
              "unsupported_native": 0, "held_records": 0,
              "spirit_coverage": "bounded" if native_reader else "unavailable"}
    identities = {str(value).casefold() for value in (author, person) if value}
    seen = {section: set() for section in ("Decided", "Open", "Risks")}
    events = ledger_events(memory) if events is None else events
    raised = {}
    rows = (record_files(memory, start=None if carry_days else earliest, end=today) if records is None
            else sorted(records, key=lambda row: str(row[0])))
    for path, meta, text in rows:
        if meta.get("kind") != "session-record":
            continue
        recorded, local_stamp = record_day(meta)
        if recorded is None or not earliest <= recorded <= today:
            continue
        window = start <= recorded
        subject = classify_record(meta)
        if subject != "human-session":
            access = native_reader(path, meta) if native_reader and window else False
            if not access:
                continue
            projection = record_subject(meta, text)
            if access == "held" or projection.get("held"):
                result["held_records"] += 1
            elif subject == "unsupported-native":
                result["unsupported_native"] += 1
            else:
                result["spirit_intents"] += 1
                result["your_spirit_intents"] += bool(actor_id and projection["record_owner_actor_id"] == actor_id)
                if len(result["spirit_records"]) < 40:
                    result["spirit_records"].append(projection)
            continue
        who = " ".join(str(meta.get("from") or meta.get("author") or "unstated").split())
        if window:
            result["sessions"] += 1
            if who.casefold() in identities:
                result["yours"] += 1
        topic = " ".join(str(meta.get("topic") or "session").split())
        stamp = local_stamp.strftime("%m-%d %H:%M") if local_stamp is not None else recorded.strftime("%m-%d") + " 00:00"
        relative = str(Path(path).relative_to(Path(memory).resolve()))
        # The record's own time; a record with only a date counts from its local midnight.
        raised_at = (local_stamp.timestamp() if local_stamp is not None
                     else datetime(recorded.year, recorded.month, recorded.day).astimezone().timestamp())
        order = (recorded, raised_at, relative)
        for section, line in digest_lines(text):
            if section == "Open":
                item, owner, ownerless = open_owner(line)
                key = digest_key(item)
                if not key:
                    continue
                ident = item_id(key)
                live = raise_is_open(events.get(ident), raised_at)
                if carry_days and live:
                    note_raise(raised, ident, order, item, owner, ownerless, topic, who)
                if window and live and key not in seen["Open"]:
                    seen["Open"].add(key)
                    result["open"].append({"id": ident, "line": item, "topic": topic, "path": relative,
                                           "owner": default_owner(owner, ownerless, who), "ownerless": ownerless})
                continue
            if not window:
                continue
            row = {"line": line, "topic": topic, "path": relative}
            if section == "Decided":
                attribution = re.search(r"\s+—\s*([^—]+?),\s*((?:\d{2}-\d{2}\s+)?\d{2}:\d{2})\s*$", line)
                row.update(who=who, time=stamp)
                if attribution:
                    own_time = attribution[2]
                    row.update(line=line[:attribution.start()].strip(), who=attribution[1].strip(),
                               time=own_time if len(own_time) > 5 else recorded.strftime("%m-%d ") + own_time)
            key = digest_key(row["line"])
            if not key or key in seen[section]:
                continue
            seen[section].add(key)
            result[section.lower()].append(row)
    result["others"] = result["sessions"] - result["yours"]
    for ident, info in raised.items():
        row = raised_row(ident, info, today)
        event = events.get(ident)
        renewed = event_time(event.get("at")) if event and event.get("state") == "active" else None
        relevant_since = (datetime.fromtimestamp(renewed).date()
                          if renewed is not None else info["first"])
        row["relevance_age"] = max(0, (today - relevant_since).days)
        row["relevance_since"] = relevant_since.isoformat()
        stale = (event is not None and event.get("state") == "stale") or row["relevance_age"] > STALE_DAYS
        row["relevance"] = "stale" if stale else "active"
        row["resolution"] = "open"
        if stale:
            result["stale"].append(row)
        elif row["relevance_age"] <= carry_days:
            result["carried"].append(row)
    for section in ("carried", "stale"):
        result[section].sort(key=lambda row: (-row["age"], row["path"], row["line"]))
    if carry_days:
        active = {row["id"] for row in result["carried"]}
        result["open"] = [row for row in result["open"] if row["id"] in active]
    return result


def digest(ctx, argv):
    parser = argparse.ArgumentParser(prog="records.sh digest")
    window = parser.add_mutually_exclusive_group()
    window.add_argument("--days", type=int, default=1)
    window.add_argument("--since")
    parser.add_argument("--all", action="store_true", help="include all authors (the default)")
    try:
        args = parser.parse_args(argv)
        actor_id, reader = native_record_reader(ctx)
        data = collect_digest(ctx.memory, author=ctx.author, person=ctx.display,
                              days=args.days, since=args.since, actor_id=actor_id, native_reader=reader)
    except SystemExit:
        return 0
    except (ValueError, OSError, OverflowError) as exc:
        print("Session digest unavailable: " + str(exc))
        return 0
    # Still open and currently relevant, including before the display window.
    shown = {row["id"] for row in data["open"]}
    carried = [row for row in data["carried"] if row["id"] not in shown] if data["since"] <= data["today"] else []
    if any(data[section] for section in ("decided", "open", "risks")):
        others = f", {data['others']} others" if data["others"] else ""
        print(f"Since {data['since']} · {data['sessions']} sessions ({data['yours']} yours{others})")
    elif not any(data[key] for key in ("spirit_intents", "unsupported_native", "held_records")):
        print(f"Nothing recorded since {data['since']}.")
    if data["spirit_intents"]:
        noun = "intent" if data["spirit_intents"] == 1 else "intents"
        print(f"Spirit records · {data['spirit_intents']} {noun} ({data['your_spirit_intents']} yours) · partial coverage")
        for row in data["spirit_records"][:8]:
            state = row.get("state") or {}
            print(f"  - {row['control_id']} · {row['producer_principal_id']} · {state.get('execution', 'unknown')} · outcome {state.get('outcome', 'unknown')} · verification {state.get('verification', 'unknown')} · through {row.get('through') or 'unknown'}")
    if data["unsupported_native"]:
        print(f"{data['unsupported_native']} unsupported spirit records · metadata unavailable")
    if data["held_records"]:
        print(f"{data['held_records']} held records · details withheld")
    for section, cap in (("Decided", 8), ("Open", 8), ("Carried", 8), ("Risks", 4)):
        rows = carried if section == "Carried" else data[section.lower()]
        if not rows:
            continue
        print(section)
        for row in rows[:cap]:
            if section in ("Open", "Carried"):
                age = f"{row['age']}d " if section == "Carried" else ""
                line = f"  - {row['id']} {age}{row['line']} — {owner_label(row)}"
            else:
                line = "  - " + row["line"]
                if section == "Decided":
                    line += f" — {row['who']}, {row['time']}"
            line += " · " + row["topic"]
            suffix = " · " + row["path"]
            room = max(1, 180 - len(suffix))
            print((line if len(line) <= room else line[:room - 1] + "…") + suffix)
        if section == "Carried" and len(rows) > cap:
            print(f"  … {len(rows) - cap} more · /records open")
    return 0


def item_argument(value):
    ident = str(value).strip().lower()
    if not ITEM_ID.fullmatch(ident):
        raise ValueError("an open item id is six hex digits, as records.sh open prints it")
    return ident


def find_item(ctx, ident):
    """The item behind an id: as carried, or else from every record that raised it."""
    today = datetime.now().date()
    carried = collect_digest(ctx.memory, days=0, today=today, events={})["carried"]
    found = next((row for row in carried if row["id"] == ident), None)
    if found is not None:
        return found
    raised = {}
    for path, meta, text in record_files(ctx.memory):
        if meta.get("kind") != "session-record" or classify_record(meta) != "human-session":
            continue
        recorded, local_stamp = record_day(meta)
        if recorded is None or recorded > today:
            continue
        order = (recorded, local_stamp.timestamp() if local_stamp is not None else 0.0,
                 str(Path(path).relative_to(ctx.memory)))
        topic = " ".join(str(meta.get("topic") or "session").split())
        who = " ".join(str(meta.get("from") or meta.get("author") or "unstated").split())
        for section, line in digest_lines(text):
            if section == "Open":
                item, owner, ownerless = open_owner(line)
                key = digest_key(item)
                if key and item_id(key) == ident:
                    note_raise(raised, ident, order, item, owner, ownerless, topic, who)
    return raised_row(ident, raised[ident], today) if ident in raised else None


def append_ledger(ctx, name, event, message, validate=None):
    """Append one JSON object to the ledger memory/sessions/<name> under the
    memory lock and commit it like every records write. Writers only ever
    append; the union merge rule beside the ledger keeps both sides' lines when
    two people's histories meet."""
    if name not in (LEDGER, GATE_LEDGER, "outcomes.jsonl", "interventions.jsonl"):
        raise ValueError("unknown records ledger; nothing was written")
    sessions = sessions_directory(ctx.memory)
    if sessions is None:
        candidate = ctx.memory / "sessions"
        if (name in ("outcomes.jsonl", "interventions.jsonl") and ctx.memory.is_dir()
                and not candidate.exists() and not candidate.is_symlink()):
            sessions = candidate
        else:
            raise ValueError("this egregore has no session records; nothing was written")
    label = name.removesuffix(".jsonl")
    ledger, attributes = sessions / name, sessions / ".gitattributes"
    lock = ctx.memory_lock()
    if not lock.acquire(wait=120):
        raise RuntimeError("memory writer busy; nothing was written")
    try:
        # Recheck permissions and the expected previous event under the same
        # lock as the append. False means an idempotent retry already exists.
        if validate is not None and validate() is False:
            return event
        # A first outcome may precede the first completed session record.
        # Create its directory only after policy validation, under the lock.
        sessions.mkdir(mode=0o755, exist_ok=True)
        if sessions_directory(ctx.memory) != sessions:
            raise ValueError("the session records directory is unavailable; nothing was written")
        data = (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8")
        if len(data) > 65536:
            raise ValueError("records event exceeds the ledger limit; nothing was written")
        try:
            descriptor = os.open(ledger, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644)
        except OSError as exc:
            raise ValueError(f"the {label} ledger cannot be opened; nothing was written") from exc
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError(f"the {label} ledger is not a regular file; nothing was written")
            if info.st_size and os.pread(descriptor, 1, info.st_size - 1) != b"\n":
                data = b"\n" + data
            os.write(descriptor, data)
        finally:
            os.close(descriptor)
        paths = [ledger]
        rule = name + " merge=union"
        try:
            current = attributes.read_text(encoding="utf-8") if stat.S_ISREG(attributes.lstat().st_mode) else None
        except FileNotFoundError:
            current = ""
        if current is not None:
            if rule not in current.splitlines():
                atomic(attributes, current + ("\n" if current and not current.endswith("\n") else "") + rule + "\n", 0o644)
            paths.append(attributes)
        commit(ctx, paths, message)
    finally:
        lock.release()
    return event


def append_event(ctx, ident, state, message, issue=None):
    """One open-items event: the id, its state, who and when, and a filed item's issue."""
    if not ctx.actor_id:
        raise ValueError("Runtime actor identity is unavailable; nothing was written")
    event = {"id": ident, "state": state, "by": ctx.actor_id,
             "at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    if issue:
        event["issue"] = issue
    return append_ledger(ctx, LEDGER, event, message)


# The merge gate's decisions (bin/merge-gate.sh): one line per merge and per
# refusal of red checks without a receipt, beside the open-items ledger.
GATE_LEDGER = "gate.jsonl"
GATE_KINDS = ("merge", "refuse")
# CI's aggregate job fails whenever another job does, so it is never a flake.
GATE_AGGREGATE = re.compile(r"Full CI result(?: — .*)?")
GATE_JOB_NAME = 120
GATE_COUNT = re.compile(r"0|[1-9][0-9]{0,8}")
GATE_POSITIVE = re.compile(r"[1-9][0-9]{0,8}")


def harness_session_id():
    """The running harness's own session id, the one its session record carries."""
    return (os.environ.get("EGREGORE_NATIVE_SESSION_ID") or os.environ.get("CLAUDE_CODE_SESSION_ID")
            or os.environ.get("CODEX_THREAD_ID"))


def gate_session(root, flag=None):
    """Only a native session can join a decision to a session record."""
    if flag is not None:
        if not SAFE_ID.fullmatch(flag):
            raise ValueError("--session takes a session id; nothing was written")
        return flag
    session = harness_session_id()
    return session if session and SAFE_ID.fullmatch(session) else None


class LedgerArguments(argparse.ArgumentParser):
    """An argument error as one line, the reason the gate prints, not a usage text."""
    def error(self, message):
        raise ValueError(message + "; nothing was written")


def gate_event(argv):
    """Append one merge-gate decision to the gate ledger and print the line."""
    parser = LedgerArguments(prog="session_record.py gate-event", add_help=False)
    for flag in ("--root", "--kind", "--pr", "--head", "--base", "--repo", "--green", "--neutral", "--red"):
        parser.add_argument(flag, required=True)
    for flag in ("--memory", "--attempts", "--session"):
        parser.add_argument(flag)
    parser.add_argument("--flaked", action="append")
    parser.add_argument("--recovered", action="append")
    parser.add_argument("--receipt", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    checks = {name: getattr(args, name) for name in ("green", "neutral", "red")}
    flaked = [job for job in args.flaked or [] if not GATE_AGGREGATE.fullmatch(job)]
    recovered = [job for job in args.recovered or [] if not GATE_AGGREGATE.fullmatch(job)]
    if args.kind not in GATE_KINDS:
        raise ValueError("--kind is merge or refuse; nothing was written")
    if not GATE_POSITIVE.fullmatch(args.pr):
        raise ValueError("--pr takes a pull request number; nothing was written")
    if not re.fullmatch(r"[0-9a-f]{40}", args.head):
        raise ValueError("--head takes the full 40-hex commit; nothing was written")
    if not re.fullmatch(r"\S{1,255}", args.base):
        raise ValueError("--base takes a branch name; nothing was written")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,100}/(?!\.\.?\Z)[A-Za-z0-9_.-]{1,100}", args.repo):
        raise ValueError("--repo takes OWNER/NAME; nothing was written")
    if not all(GATE_COUNT.fullmatch(value) for value in checks.values()):
        raise ValueError("--green, --neutral and --red take counts; nothing was written")
    if args.attempts is not None and not GATE_POSITIVE.fullmatch(args.attempts):
        raise ValueError("--attempts takes a positive count; nothing was written")
    if any(not job.strip() or len(job) > GATE_JOB_NAME for job in flaked + recovered):
        raise ValueError(f"--flaked and --recovered take a job name of 1 to {GATE_JOB_NAME} characters; "
                         "nothing was written")
    ctx = Context(args.root)
    if args.memory:
        ctx.memory = Path(args.memory).resolve()
    event = {"at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "kind": args.kind,
             "pr": int(args.pr), "head": args.head, "base": args.base, "repo": args.repo,
             "checks": {name: int(value) for name, value in checks.items()}}
    if args.attempts is not None:
        event["attempts"] = int(args.attempts)
    event["flaked"] = list(dict.fromkeys(flaked))
    # A job is one or the other: a failure in an earlier attempt is proof and
    # a cancel is not, so a job named in both flaked.
    event["recovered"] = [job for job in dict.fromkeys(recovered) if job not in event["flaked"]]
    event["receipt"] = args.receipt
    if not ctx.actor_id:
        raise ValueError("Runtime actor identity is unavailable; nothing was written")
    event["by"] = ctx.actor_id
    session = gate_session(ctx.root, args.session)
    # A decision made outside a harness session is still recorded, without a
    # session, so it joins no record; records off or a held session withhold it.
    if not ctx.enabled() or (session and ctx.held(session)):
        print("record controls withhold this gate event", file=sys.stderr)
        return 3
    if session:
        event["session"] = session
    if not args.dry_run:
        append_ledger(ctx, GATE_LEDGER, event, f"chore(sessions): record gate verdict for #{event['pr']}")
    print(json.dumps(event, ensure_ascii=False))
    return 0


def open_items(ctx, argv):
    parser = argparse.ArgumentParser(prog="records.sh open")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--stale", action="store_true")
    selection.add_argument("--all", action="store_true")
    parser.add_argument("--mine", action="store_true", help="only the items you own, named or by default")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    data = collect_digest(ctx.memory, author=ctx.author, person=ctx.display, days=0)
    rows = data["stale"] if args.stale else data["carried"]
    if args.all:
        rows = sorted(data["carried"] + data["stale"], key=lambda row: (-row["age"], row["id"]))
    if args.mine:
        rows = mine(rows, ctx.identities())
    if args.json:
        print(json.dumps({"active_count": len(data["carried"]), "stale_count": len(data["stale"]),
                          "items": rows}, ensure_ascii=False))
        return 0
    label = "open but stale" if args.stale else ("open" if args.all else "active open")
    label += " items of yours" if args.mine else " items"
    if not rows:
        print(f"No {label}.")
        return 0
    print(f"{len(rows)} {label}, oldest first")
    width = max(len(clip(owner_label(row, " (default)"), 24)) for row in rows)
    for row in rows:
        status = f"  [{row['relevance']}]" if args.all or args.stale else ""
        print(f"{row['id']}  {row['age']:>2}d{status}  {clip(owner_label(row, ' (default)'), 24):<{width}}  "
              f"{clip(row['line'], 160)} · {row['path']}")
    if not args.stale and data["stale"]:
        print(f"{len(data['stale'])} open but stale · /records open --stale")
    print("Close one with /records close <id>; draft an issue for one with /records file <id>.")
    return 0


def relevance_item(ctx, argv, state):
    parser = argparse.ArgumentParser(prog="records.sh " + ("reactivate" if state == "active" else "stale"))
    parser.add_argument("id")
    ident = item_argument(parser.parse_args(argv).id)
    item = find_item(ctx, ident)
    if item is None:
        raise ValueError(f"no open item {ident} in the session records; nothing was written")
    previous = ledger_events(ctx.memory).get(ident)
    if previous and previous.get("state") == "filed":
        raise ValueError("this item is filed; continue in its linked issue instead of reactivating the carry")
    if state == "stale" and previous and previous.get("state") not in ("active", "stale"):
        raise ValueError("this item is resolved; only explicit reactivation can reopen it")
    append_event(ctx, ident, state, f"chore(sessions): {'reactivate' if state == 'active' else 'mark stale'} open item {ident}")
    print(f"{'Reactivated' if state == 'active' else 'Marked stale'} {ident}; original age {item['age']}d · {item['path']}")
    return 0


def close_item(ctx, argv):
    parser = argparse.ArgumentParser(prog="records.sh close")
    parser.add_argument("id")
    ident = item_argument(parser.parse_args(argv).id)
    item = find_item(ctx, ident)
    if item is None:
        raise ValueError(f"no open item {ident} in the session records; nothing was written")
    before = ledger_events(ctx.memory).get(ident)
    append_event(ctx, ident, "closed", f"chore(sessions): close open item {ident}")
    again = " (already closed)" if before and before.get("state") == "closed" else ""
    print(f"Closed {ident}{again} · {item['line']} · {item['path']}")
    return 0


def issue_text(ident, item):
    """The draft's title and description: the item line, record path, owner and age."""
    days = item["age"]
    return clip(item["line"], 200), "\n".join((
        item["line"], "",
        f"Open item {ident} from the session records.",
        f"Record: memory/{item['path']}",
        f"Owner: {owner_label(item, ' (by default)')}",
        f"Open for {days} day{'s' if days != 1 else ''}, since {item['first']}."))


def run_issue(ctx, arguments):
    """One call into the issue flow; its JSON receipt, or its own error."""
    env = dict(clean_env(), EGREGORE_ROOT=str(ctx.root))
    try:
        result = subprocess.run(["bash", str(ctx.root / "bin/issue.sh"), *arguments], env=env, cwd=ctx.root,
                                capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("the issue flow did not answer; nothing was written") from exc
    if result.returncode:
        detail = (result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}").splitlines()
        raise RuntimeError(detail[-1] + "; nothing was written")
    try:
        receipt = json.loads(result.stdout)
    except ValueError:
        receipt = None
    if not isinstance(receipt, dict):
        raise RuntimeError("the issue flow returned no receipt; nothing was written")
    return receipt


def issue_draft(ctx, request, ident):
    """The issue flow's durable draft for a request, refused unless it is this item's."""
    try:
        valid = str(UUID(request)) == request
    except ValueError:
        valid = False
    if not valid:
        raise ValueError("--confirm takes the request id that records.sh file printed; nothing was filed")
    path = ctx.root / ".egregore/runtime/issues/requests" / (request + ".json")
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
            raise ValueError
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ValueError(f"no issue draft {request} on this machine; nothing was filed") from None
    payload = state.get("payload") if isinstance(state, dict) else None
    if (not isinstance(payload, dict) or state.get("request_id") != request or state.get("operation") != "create"
            or not isinstance(payload.get("title"), str) or not isinstance(payload.get("body"), str)
            or payload.get("labels") != ISSUE_LABELS
            or f"Open item {ident} from the session records." not in payload["body"].splitlines()):
        raise ValueError(f"request {request} is not the issue draft for open item {ident}; nothing was filed")
    return payload


def file_item(ctx, argv):
    """Prepare an issue draft; file it only on --confirm with the draft's request id."""
    parser = argparse.ArgumentParser(prog="records.sh file")
    parser.add_argument("id")
    parser.add_argument("--confirm", metavar="REQUEST_ID")
    args = parser.parse_args(argv)
    ident = item_argument(args.id)
    if not ctx.author:
        raise ValueError("your GitHub username is not in .egregore-state.json; nothing was drafted")
    item = find_item(ctx, ident)
    if item is None:
        raise ValueError(f"no open item {ident} in the session records; nothing was drafted")
    last = ledger_events(ctx.memory).get(ident)
    if last and last.get("state") == "filed":
        print(f"{ident} is already filed" + (": " + last["issue"] if isinstance(last.get("issue"), str) else ""))
        return 0
    if args.confirm is None:
        title, description = issue_text(ident, item)
        receipt = run_issue(ctx, ["create", "--title", title, "--description", description, *ISSUE_FLAGS, "--draft"])
        request = receipt.get("request_id")
        if receipt.get("status") != "draft" or not isinstance(request, str):
            raise RuntimeError("the issue flow prepared no draft; nothing was written")
        print(f"Issue draft for open item {ident} · nothing is filed yet")
        if isinstance(receipt.get("repo"), str):
            print("  tracker: " + receipt["repo"])
        print("  title: " + title)
        print("  description:")
        for line in description.splitlines():
            print(("    " + line).rstrip())
        print("  request: " + request)
        print(f"Once the person confirms this draft: bash bin/records.sh file {ident} --confirm {request}")
        return 0
    payload = issue_draft(ctx, args.confirm, ident)
    receipt = run_issue(ctx, ["create", "--title", payload["title"], "--description", payload["body"],
                              *ISSUE_FLAGS, "--request-id", args.confirm])
    url = receipt.get("github_url")
    if receipt.get("status") != "submitted" or not isinstance(url, str) or not url.startswith("https://github.com/"):
        raise RuntimeError(f"the issue was not filed ({receipt.get('status', 'no status')}); nothing was written")
    try:
        append_event(ctx, ident, "filed", f"chore(sessions): file open item {ident} as an issue", issue=url)
    except (ValueError, RuntimeError, OSError) as exc:
        # The same request id reconciles without a second issue, then records the event.
        print(f"Filed {ident} as {url}, but its ledger event was not recorded ({exc}). "
              "Run the same command again to record it.")
        return 1
    print(f"Filed {ident} as {url}")
    return 0


def open_items_line(memory, today=None, identities=()):
    """Keep current work bounded while making retained stale obligations
    visible. With the person's identities, the line counts the items that are
    theirs and a second line names their oldest three, so a thread left
    behind reaches the one who left it."""
    data = collect_digest(memory, days=0, today=today)
    rows, stale = data["carried"], data["stale"]
    tail = f" · {len(stale)} open but stale · /records open --stale" if stale else ""
    if not rows:
        return tail.lstrip(" ·")
    yours = mine(rows, identities)
    pointer = f" · {len(yours)} yours · /records open --mine" if yours else ""
    head = f"{len(rows)} open item{'s' if len(rows) != 1 else ''} carried (oldest {rows[0]['age']}d: \""
    room = min(60, REFLEX_LINE - len(head) - len('\")') - len(pointer) - len(tail))
    first = head + clip(rows[0]["line"], max(10, room)) + '\")' + pointer + tail
    if not yours:
        return first
    oldest = yours[:3]
    lead = "yours, oldest: "
    fixed = len(lead) + sum(len(f"{row['id']} {row['age']}d \"\"") for row in oldest) + 3 * (len(oldest) - 1)
    each = max(10, min(60, (REFLEX_LINE - fixed) // len(oldest)))
    second = lead + " · ".join(f"{row['id']} {row['age']}d \"{clip(row['line'], each)}\"" for row in oldest)
    return first + "\n" + second


# Vitals: the organization's pulse over the last VITALS_DAYS days, today
# included, beside the VITALS_DAYS before them. Sessions, harnesses, cost and
# friction come from the records, read once and dated as the digest dates
# them; merges, refusals, flaked jobs and receipts come from the merge gate's
# ledger beside them. A held stub is a session with a cost and no friction.
VITALS_DAYS = 7
VITALS_MAX_DAYS = 366
FRICTION_HEADING = re.compile(r"^##[ \t]+Friction[ \t\r]*$", re.M)
FRICTION_COUNTS = re.compile(r"- (tool errors|non-zero exits|worktree-guard refusals|recall failures): (.*)")
FRICTION_COUNT = re.compile(r"(?:^|\s)(\d{1,9})$")


def record_friction(text):
    """The counts on a record's tool-error, non-zero-exit, worktree-guard and
    recall-failure lines. The last Friction heading is the writer's, since a
    full record's prompt excerpts come before it; each counter counts once."""
    headings = list(FRICTION_HEADING.finditer(text))
    if not headings:
        return None
    section = text[headings[-1].end():]
    end = re.search(r"^##[ \t]", section, re.M)
    total, seen = 0, set()
    for line in section[:end.start() if end else None].splitlines():
        match = FRICTION_COUNTS.fullmatch(line.strip())
        if match is None or match[1] in seen:
            continue
        counts = [int(found[1]) for found in (FRICTION_COUNT.search(part.strip()) for part in match[2].split(","))
                  if found]
        if counts:
            seen.add(match[1])
            total += sum(counts)
    return total if seen else None


def vitals_cost(value):
    """A finite, nonnegative cost; unavailable is distinct from measured zero."""
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) and number >= 0 else None


def gate_observations(memory):
    """The merge gate's merge and refuse events, read through ledger_lines.
    Coverage describes the file read, not historical capture: partial when a
    non-blank line does not parse or a line too long to read was skipped.
    A blank, malformed or unknown line is skipped, never fatal."""
    sessions = sessions_directory(memory)
    if sessions is None:
        return [], "missing"
    try:
        info = (sessions / GATE_LEDGER).lstat()
    except FileNotFoundError:
        return [], "missing"
    except OSError:
        return [], "unavailable"
    if not stat.S_ISREG(info.st_mode):
        return [], "unavailable"
    events, coverage, read = [], "complete", 0
    for line in ledger_lines(memory, GATE_LEDGER):
        read += len(line.encode("utf-8"))
        try:
            event = json.loads(line)
        except (ValueError, RecursionError):
            if line.strip():
                coverage = "partial"
            continue
        if isinstance(event, dict) and event.get("kind") in GATE_KINDS:
            events.append(event)
    # ledger_lines skips a line past its bound and yields nothing it cannot open.
    if read < info.st_size:
        coverage = "partial" if read else "unavailable"
    return events, coverage


def vitals(memory, *, days=VITALS_DAYS, today=None):
    """The last ``days`` days to today as ``now``, beside the ``days`` before
    them as ``before``. A record counts on its local date, as in the digest; a
    gate event counts on the local date of its time. Writes nothing."""
    today = today or datetime.now().date()
    if isinstance(today, str):
        today = date.fromisoformat(today)
    days = max(1, min(int(days), VITALS_MAX_DAYS))
    start = today - timedelta(days=days - 1)
    earliest = start - timedelta(days=days)
    tally = {name: {"sessions": 0, "by_harness": Counter(), "cost": 0.0, "priced": 0, "friction": 0, "detailed": 0,
                    "merges": 0, "refused": 0, "flaked": 0, "receipts": 0,
                    "retried": 0, "retry_observations": 0} for name in ("now", "before")}
    for _, meta, text in record_files(memory, start=earliest, end=today):
        recorded = record_day(meta)[0] if meta.get("kind") == "session-record" else None
        if recorded is None or not earliest <= recorded <= today:
            continue
        period = tally["now" if recorded >= start else "before"]
        harness = meta.get("harness")
        period["sessions"] += 1
        period["by_harness"][" ".join(harness.split()).lower() if isinstance(harness, str) and harness.strip()
                             else "unknown"] += 1
        cost = vitals_cost(meta.get("cost_usd")) if meta.get("cost_source") != "unavailable" else None
        if cost is not None:
            period["cost"] += cost
            period["priced"] += 1
        if meta.get("detail") != "stub":
            friction = record_friction(text)
            if friction is not None:
                period["detailed"] += 1
                period["friction"] += friction
    events, gate_coverage = gate_observations(memory)
    for event in events:
        stamp = event_time(event.get("at"))
        try:
            day = datetime.fromtimestamp(stamp).date() if stamp is not None else None
        except (OverflowError, OSError, ValueError):
            day = None
        if day is None or not earliest <= day <= today:
            if day is None:
                gate_coverage = "partial"
            continue
        period = tally["now" if day >= start else "before"]
        attempts = event.get("attempts")
        if isinstance(attempts, int) and not isinstance(attempts, bool) and attempts >= 1:
            period["retry_observations"] += 1
            period["retried"] += attempts > 1
        if event["kind"] == "refuse":
            period["refused"] += 1
            continue
        flaked = event["flaked"] if isinstance(event.get("flaked"), list) else []
        period["merges"] += 1
        period["flaked"] += sum(isinstance(job, str) and bool(job.strip()) for job in flaked)
        period["receipts"] += event.get("receipt") is True
    result = {"days": days, "today": today.isoformat(), "gate_coverage": gate_coverage,
              "gate_capture_coverage": "unknown", "gate_counts_basis": "observed_events"}
    for name, period in tally.items():
        result[name] = {"sessions": period["sessions"],
                        "by_harness": dict(sorted(period["by_harness"].items(), key=lambda item: (-item[1], item[0]))),
                        "cost_usd": round(period["cost"], 2) if period["priced"] else None,
                        "priced_sessions": period["priced"],
                        "friction": round(period["friction"] / period["detailed"], 1) if period["detailed"] else None,
                        "friction_sessions": period["detailed"],
                        "retried_decisions": period["retried"] if period["retry_observations"] else None,
                        "retry_observations": period["retry_observations"],
                        **{key: int(period[key]) if gate_coverage in ("complete", "partial") else None
                           for key in ("merges", "refused", "flaked", "receipts")}}
    result["unit_economics"] = {
        "status": "unavailable", "cost_per_accepted_outcome_usd": None,
        "accepted_outcomes": None, "joined_sessions": None,
        "reason": "Verified accepted outcomes are not joined to native sessions and their complete costs.",
    }
    result["findings"] = vitals_findings(result)
    return result


def vitals_findings(data):
    """Deterministic proposals from aggregate evidence. No inference of intent,
    acceptance or savings; no reads, writes, subprocesses or model calls."""
    now, before = data["now"], data["before"]
    findings = []

    def add(code, severity, observation, coverage, action, verification):
        findings.append({"code": code, "severity": severity, "observation": observation,
                         "coverage": coverage, "action": action, "verification": verification})

    if not now["sessions"]:
        add("records_missing", "warning", "No session records are available in the current period.",
            {"sessions": 0, "days": data["days"]},
            "Check eligible record capture before using this period as a baseline.",
            "An eligible unheld session produces a current record; no activity is inferred from missing records.")
    priced = {name: {"observed": period["priced_sessions"], "total": period["sessions"]}
              for name, period in (("now", now), ("before", before))}
    if any(row["observed"] < row["total"] for row in priced.values()):
        add("cost_coverage_gap", "warning",
            f"Cost is available for {now['priced_sessions']}/{now['sessions']} current records "
            f"and {before['priced_sessions']}/{before['sessions']} previous records.",
            priced,
            "Repair cost-source coverage for eligible records and keep unpriced sessions visible.",
            "Each total names its priced denominator; an unpriced session never contributes a measured zero.")
    unknown = {name: period["by_harness"].get("unknown", 0) for name, period in (("now", now), ("before", before))}
    if any(unknown.values()):
        add("harness_coverage_gap", "warning",
            f"Harness is unknown for {unknown['now']} current and {unknown['before']} previous records.",
            {"unknown": unknown, "held_policy": "Do not recover metadata withheld by a hold."},
            "Preserve verified harness metadata in future unheld records; keep held and legacy omissions unknown.",
            "Unheld records name their verified harness; held stubs remain unchanged and count as unknown.")
    measured = {name: {"observed": period["friction_sessions"], "total": period["sessions"]}
                for name, period in (("now", now), ("before", before))}
    if any(row["observed"] < row["total"] for row in measured.values()):
        add("friction_coverage_gap", "info",
            "Some records have no measured friction counters.",
            measured,
            "Keep unobserved and held records outside the friction denominator.",
            "Missing counters remain null, and each comparison names its measured-record count.")
    if now["friction"] is not None:
        previous = f"{before['friction']:.1f}" if before["friction"] is not None else "unavailable"
        add("friction_signal", "warning" if now["friction"] > 0 else "info",
            f"Friction counters average {now['friction']:.1f} per measured current record; previous: {previous}.",
            {**measured, "limitation": "Counters overlap; this is not a unique-error rate or proof of improvement."},
            "Inspect repeated failure classes and verify one repair against comparable records.",
            "The repaired failure no longer reproduces; compare the same counter definitions and report coverage.")
    gate = data["gate_coverage"]
    if gate != "complete":
        add("gate_coverage_gap", "warning",
            f"Merge-gate ledger read coverage is {gate}.",
            {"ledger": gate, "merges": now["merges"], "refusals": now["refused"]},
            "Verify gate-ledger capture and bounded-read coverage before interpreting merge or refusal counts.",
            "An isolated merge and refusal each leave one valid event; missing and partial evidence stay labelled.")
    add("gate_capture_coverage_gap", "warning",
        "Gate counts include observed events only; capture coverage over both periods is unknown.",
        {"temporal": data["gate_capture_coverage"], "counts_basis": data["gate_counts_basis"], "ledger": gate,
         "limitation": "A complete ledger read does not prove continuous capture or that all eligible decisions were recorded."},
        "Establish and verify a prospective capture window while retaining unknown historical coverage.",
        "Check eligible decisions within that window; zero observed events never asserts zero actual decisions, "
        "and the first event does not establish capture start.")
    if now["retried_decisions"]:
        add("ci_retries_observed", "warning",
            f"{now['retried_decisions']} gate decisions observed CI attempts above one.",
            {"observed_decisions": now["retry_observations"], "ledger": gate,
             "limitation": "Repeated decisions may refer to the same head; this is not a count of unique reruns."},
            "Identify the repeated jobs and fix their deterministic failure or flake without broadening reruns.",
            "The affected job passes its targeted repeat check and a later measured head needs one CI attempt.")
    if now["refused"]:
        add("gate_refusals_observed", "warning",
            f"The gate recorded {now['refused']} refusals in the current period.",
            {"ledger": gate, "refusals": now["refused"]},
            "Inspect refusal reasons and repair the failing check or invalid submission; preserve the merge gate.",
            "The original refusal is reproduced, then a corrected submission passes the unchanged gate.")
    if now["flaked"]:
        add("ci_flakes_observed", "warning",
            f"Merged decisions name {now['flaked']} flaked-job observations.",
            {"ledger": gate, "limitation": "The same job can appear on more than one merge."},
            "Reproduce the named flaky jobs with isolated fixtures and repair the cause.",
            "Focused repeated runs pass without treating an aggregate result as a flaky job.")
    add("accepted_outcome_link_missing", "info",
        "Cost per accepted outcome is unavailable.",
        {"status": "unavailable", "accepted_outcomes": None, "joined_sessions": None,
         "limitation": "Record-date costs and merge counts do not establish accepted outcomes or task costs."},
        "Join verified accepted outcomes to native sessions and complete task costs before calculating unit cost.",
        "Acceptance, native-session attribution and cost coverage are verified together; merges alone are never the denominator.")
    return findings


def vitals_findings_text(data):
    """Render the explicit scorecard with the shared terminal width."""
    rows = ["◦ RECORDS SCORECARD"]
    for finding in data["findings"]:
        rows.append(None)
        rows.extend(textwrap.wrap(("● " if finding["severity"] == "warning" else "◦ ")
                                  + finding["observation"], width=68))
        rows.extend(textwrap.wrap("→ " + finding["action"], width=68))
        rows.extend(textwrap.wrap("Verify: " + finding["verification"], width=68))
        for reference in finding.get("evidence", [])[:3]:
            rows.extend(textwrap.wrap("Evidence: " + reference, width=68))
        limitation = finding["coverage"].get("limitation")
        if limitation:
            rows.extend(textwrap.wrap("Coverage: " + limitation, width=68))
    return "\n".join(["┌" + "─" * 70 + "┐",
                      *("├" + "─" * 70 + "┤" if row is None else f"│  {row:<68}│" for row in rows),
                      "└" + "─" * 70 + "┘"])


def vitals_text(label, period, gate, per):
    """One period's line: its sessions, the harnesses when more than one has
    records, cost, friction, and the gate events when either period has any."""
    def count(number, noun):
        return f"{number} {noun}{'' if number == 1 else 's'}"
    cost = period["cost_usd"]
    money = "cost unavailable"
    if cost is not None:
        cost = round(cost, 2)
        money = f"${cost:,.0f}" if cost >= 10 else f"${cost:.2f}" if cost > 0 else "$0"
        if period.get("priced_sessions", period["sessions"]) < period["sessions"]:
            money += f" ({period['priced_sessions']}/{period['sessions']} priced)"
    friction = period["friction"]
    tail = f" · {money} · friction " + (f"{friction:.1f}{per}" if friction is not None else "unavailable")
    if gate:
        tail += " · observed " + count(period["merges"], "merge") + "".join(
            ", " + text for number, text in ((period["flaked"], f"{period['flaked']} flaked"),
                                             (period["refused"], f"{period['refused']} refused"),
                                             (period["receipts"], count(period["receipts"], "receipt"))) if number)
        if gate == "partial":
            tail += " (partial)"
    head = f"{label} {count(period['sessions'], 'session')}"
    if len(period["by_harness"]) > 1:
        line = head + " (" + ", ".join(f"{number} {name}" for name, number in period["by_harness"].items()) + ")" + tail
        if len(line) <= REFLEX_LINE:
            return line
    return clip(head + tail, REFLEX_LINE)


def vitals_line(data, quiet=True):
    """The vitals in two lines of at most REFLEX_LINE characters. Quiet, as the
    startup card prints them: nothing under two sessions in the period, and no
    before line when the period before it had none."""
    now, before = data["now"], data["before"]
    if quiet and now["sessions"] < 2:
        return ""
    gate = any(period["merges"] or period["refused"] for period in (now, before))
    if gate and data.get("gate_coverage") == "partial":
        gate = "partial"
    lines = [vitals_text(f"{data['days']} day{'' if data['days'] == 1 else 's'}:", now, gate, " a session"),
             vitals_text("before:", before, gate, "")]
    if quiet and not before["sessions"]:
        lines.pop()
    return "\n".join(lines)


def existing(ctx, sid):
    return next((r for r in all_records(ctx) if r[1].get("session") == sid), None)


def native_record_adapter(required=True):
    """Private producer is optional in public bundles; absence never grants access."""
    try:
        import session_record_producers
        return session_record_producers
    except ImportError as exc:
        if required:
            raise ValueError("native spirit records are unsupported in this installation") from exc
        return None


def owned_record(ctx, meta):
    if meta.get("producer"):
        adapter = native_record_adapter(required=False)
        return bool(adapter and adapter.owned(ctx, meta))
    identities = {str(value).casefold() for value in (ctx.author, ctx.display) if value}
    return any(str(meta.get(key, "")).casefold() in identities for key in ("from", "author"))


def clean_env():
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def git(ctx, *args, check=False):
    result = subprocess.run(["git", "-C", str(ctx.memory), *args], env=clean_env(),
                            capture_output=True, text=True, timeout=60)
    if check and result.returncode:
        raise RuntimeError("memory write failed: " + result.stderr.strip()[:1000])
    return result


def head_record_text(ctx, path):
    """Read only the bounded metadata window of a record stored in HEAD."""
    name = str(Path(path).relative_to(ctx.memory))
    error = "memory write failed: cannot read HEAD:" + name
    try:
        process = subprocess.Popen(["git", "-C", str(ctx.memory), "show", "HEAD:" + name],
                                   env=clean_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError as exc:
        raise RuntimeError(error) from exc
    try:
        limit = 256 * 1024
        raw = process.stdout.read(limit + 1)
        if len(raw) > limit:
            return raw[:limit].decode("utf-8", errors="replace")
        try:
            status = process.wait(timeout=5)
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(error) from exc
        if status:
            raise RuntimeError(error)
        return raw.decode("utf-8", errors="replace")
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def deleted_record_rows(ctx):
    """Read deleted session metadata without opening any working-tree path."""
    result = git(ctx, "diff", "--name-only", "-z", "--diff-filter=D", "--no-renames",
                 "HEAD", "--", "sessions/")
    if result.returncode:
        # A new memory repository has no historical paths to recover. Other
        # diff failures still stop publication rather than hiding deletions.
        if (git(ctx, "rev-parse", "--is-inside-work-tree").stdout.strip() == "true"
                and git(ctx, "rev-parse", "--verify", "--quiet", "HEAD").returncode):
            return
        raise RuntimeError("memory write failed: " + result.stderr.strip()[:1000])
    names = result.stdout.split("\0")
    for name in filter(None, names):
        path = ctx.memory / name
        text = head_record_text(ctx, path)
        yield path, metadata(text), text


def deleted_records(ctx, sid):
    """Recover this session's deletion side after an interrupted held rename."""
    return [path for path, meta, _ in deleted_record_rows(ctx) if meta.get("session") == sid]


def redaction_record(ctx, sid):
    old = existing(ctx, sid)
    if old:
        return old
    return next((row for row in deleted_record_rows(ctx) if row[1].get("session") == sid), None)


def waiting_path(ctx):
    key = hashlib.sha256(str(ctx.memory).encode()).hexdigest()[:16]
    return ctx.home / ".egregore/trails" / ("pending-" + key + ".json")


def push(ctx):
    pending = waiting_path(ctx)
    if git(ctx, "remote", "get-url", "origin").returncode:
        return True
    # Every outgoing ancestor is checked by the shared transport owner. The
    # human path cannot publish an earlier native checkpoint hidden at the tip.
    try:
        sys.path.insert(0, str(SELF.parents[2]))
        from egregore_runtime.memory_push import push_memory
        branch = git(ctx, "symbolic-ref", "--quiet", "--short", "HEAD").stdout.strip()
        result = push_memory(ctx.memory, branch=branch)
    except (ImportError, OSError, ValueError, RuntimeError):
        result = {"status": "unknown", "cause": "guard_unavailable"}
    if result.get("status") not in {"pushed", "already-current"}:
        previous = read_json(pending)
        previous["waiting_push"] = max(1, previous.get("waiting_push", 0))
        atomic(pending, json.dumps(previous))
        ctx.error("guarded publication pending; commit remains local: " + str(result.get("cause", "unknown")))
        return False
    previous = read_json(pending)
    if previous.get("native_publication"):
        # A human-only push/retry cannot acknowledge or discard a separate
        # native owner's exact pending attempt (including a lost receipt).
        previous["waiting_push"] = 0
        atomic(pending, json.dumps(previous))
    else:
        pending.unlink(missing_ok=True)
    return True


def require_human_publication(ctx, paths):
    """The human publication path cannot adopt private native checkpoints."""
    selected = {Path(path) for path in paths}
    for path in selected:
        if not path.is_relative_to(ctx.memory) or not path.resolve().is_relative_to(ctx.memory) or path.is_symlink():
            raise ValueError("record publication path is outside canonical memory")
        if path.is_file():
            with path.open("rb") as stream:
                meta = metadata(stream.read(256 * 1024).decode("utf-8", errors="replace"))
            if meta.get("producer"):
                raise ValueError("native record publication requires its own fresh admission")
    if any(path in selected and meta.get("producer") for path, meta, _ in deleted_record_rows(ctx)):
        raise ValueError("native record deletion requires its own fresh publication admission")


def commit(ctx, paths, message, before_publish=None):
    """Caller holds the memory lock, which also serializes every hold marker."""
    require_human_publication(ctx, paths)
    identity = []
    for key, default in (("user.name", ctx.display or ctx.author),
                         ("user.email", f"{ctx.author}@users.noreply.github.com")):
        if not git(ctx, "config", "--get", key).stdout.strip():
            identity += ["-c", key + "=" + default]

    def stage():
        require_human_publication(ctx, paths)
        # A hold may rename a selected record before publication. Stage both
        # sides of that change in the same commit, including callback additions.
        relative = list(dict.fromkeys(str(Path(p).relative_to(ctx.memory)) for p in paths))
        if not relative:
            return []
        tracked = set(git(ctx, "ls-files", "-z", "--", *relative, check=True).stdout.split("\0"))
        selected = [name for name in relative if (ctx.memory / name).exists() or name in tracked]
        if selected:
            git(ctx, "add", "--", *selected, check=True)
        # Staged deletions disappear from ls-files but still need the pathspec.
        tracked.update(git(ctx, "diff", "--cached", "--name-only", "--no-renames", "-z", "--", *relative,
                           check=True).stdout.split("\0"))
        return [name for name in relative if (ctx.memory / name).exists() or name in tracked]

    if before_publish is not None and not before_publish():
        return
    selected = stage()
    if selected and git(ctx, "diff", "--cached", "--quiet", "--", *selected).returncode:
        # Holds cannot change under this lock. Re-check personal/org settings
        # immediately before the commit as well, and stage any resulting stub.
        if before_publish is not None and not before_publish():
            return
        selected = stage()
        if selected and git(ctx, "diff", "--cached", "--quiet", "--", *selected).returncode:
            git(ctx, *identity, "commit", "--quiet", "-m", message, "--", *selected, check=True)
    push(ctx)


def publish_held_deletions(ctx, sid):
    """Finish an interrupted no-stub hold without rebuilding the transcript."""
    lock = ctx.memory_lock()
    if not lock.acquire(wait=120):
        raise RuntimeError("memory writer busy")
    try:
        ctx.reload()
        if not ctx.held(sid) or ctx.state.get("session_records_hold_stub", True) is not False:
            return
        removed = [path for path, meta, _ in deleted_record_rows(ctx)
                   if meta.get("session") == sid and not meta.get("producer")]
        if removed:
            commit(ctx, removed, "chore(sessions): remove held record")
    finally:
        lock.release()


def regular(path):
    try:
        return path.is_file() and bool(path.stat().st_mode & 0o444)
    except OSError:
        return False


def staging_directory(ctx, path, create=False):
    """Validate every directory component before creating or reading staging."""
    path = Path(path)
    if not ctx.safe_base():
        raise ValueError("invalid backfill staging folder")
    try:
        parts = path.relative_to(ctx.base).parts
        if not parts or any(part in (".", "..") for part in parts):
            raise ValueError("invalid backfill staging folder")
        if create:
            private_dir(ctx.base)
        current = ctx.base
        for part in parts:
            current = current / part
            if create and not current.exists() and not current.is_symlink():
                current.mkdir(mode=0o700)
            if not stat.S_ISDIR(current.lstat().st_mode) or not current.resolve().is_relative_to(ctx.base.resolve()):
                raise ValueError("invalid backfill staging folder")
    except OSError as exc:
        raise ValueError("invalid backfill staging folder") from exc
    return path


def staging_file(ctx, stage, path):
    stage = staging_directory(ctx, stage)
    path = Path(path)
    try:
        if not path.is_relative_to(stage) or not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError("invalid backfill staging file")
        if not path.resolve().is_relative_to(stage.resolve()):
            raise ValueError("invalid backfill staging file")
        staging_directory(ctx, path.parent)
    except OSError as exc:
        raise ValueError("invalid backfill staging file") from exc
    return path


def staged_records(ctx, stage):
    stage = staging_directory(ctx, stage)
    # os.walk never descends symlinks. Refuse an invalid entry before reading
    # any staged record through it, even if its target is inside this folder.
    for directory, dirs, files in os.walk(stage, followlinks=False):
        for name in dirs:
            staging_directory(ctx, Path(directory) / name)
        for name in files:
            path = staging_file(ctx, stage, Path(directory) / name)
            if path.suffix == ".md":
                text = path.read_text()
                yield path, metadata(text), text


def path_identity(path):
    # Exactly the producer's sha256(String(sessionFile)), without normalization.
    return hashlib.sha256(str(path).encode()).hexdigest()


def trail_bases(ctx):
    bases = {ctx.base, ctx.home / ".egregore/trails" / ctx.prefix}
    bases.update((ctx.home / ".egregore/trails").glob(ctx.prefix + "--*"))
    return [base for base in bases if st.valid_trail_folder(base, ctx.projects, ctx.prefix)]


def aliases(ctx):
    for base in trail_bases(ctx):
        if base.name not in (ctx.prefix + "--pi", ctx.prefix + "--prime"):
            continue
        path = base / "aliases.jsonl"
        try:
            if not stat.S_ISREG(path.lstat().st_mode) or path.stat().st_size > 1024 * 1024:
                continue
            with path.open() as stream:
                for line in stream:
                    try:
                        row = json.loads(line)
                        if (isinstance(row, dict) and isinstance(row.get("path"), str)
                                and isinstance(row.get("hash"), str) and re.fullmatch(r"[a-f0-9]{64}", row["hash"])
                                and isinstance(row.get("session"), str) and SAFE_ID.fullmatch(row["session"])):
                            yield row
                    except (ValueError, TypeError):
                        continue
        except OSError:
            continue


def codex_human_root(header):
    payload = header.get("payload", {}) if isinstance(header, dict) else {}
    return (isinstance(payload, dict) and payload.get("originator") in ("codex-tui", "Codex Desktop")
            and payload.get("source") in ("cli", "vscode") and not st.parent_of(header))


def pi_session_paths(ctx):
    for harness in ("pi", "prime"):
        base = ctx.home / ("." + harness) / "agent/sessions"
        for directory, dirs, files in os.walk(base, followlinks=False):
            if len(Path(directory).relative_to(base).parts) >= 3:
                dirs[:] = []
            for name in sorted(files):
                path = Path(directory) / name
                if path.suffix == ".jsonl":
                    yield path


def recover_pi_alias(ctx, identifier):
    """Recover a producer hash from bounded native roots, never from content."""
    if not re.fullmatch(r"[a-f0-9]{64}", identifier):
        return None
    for path in pi_session_paths(ctx):
        for spelling in dict.fromkeys((str(path), str(path.resolve()))):
            if path_identity(spelling) != identifier:
                continue
            info = transcript_info(ctx, path)
            if info and info[0] in ("pi", "prime"):
                return {"hash": identifier, "path": spelling, "session": info[1]}
    return None


def remember_pi_alias(ctx, row):
    """Share the producer's bounded alias ledger; a hold does not depend on IO success."""
    lock = ctx.base / ".aliases.lock"
    acquired = False
    try:
        if not ctx.safe_base():
            return
        private_dir(ctx.base)
        for attempt in range(2):
            try:
                lock.mkdir(mode=0o700)
                acquired = True
                break
            except FileExistsError:
                if attempt == 0 and stat.S_ISDIR(lock.lstat().st_mode) and time.time() - lock.stat().st_mtime > 60:
                    lock.rmdir()
                else:
                    return
        path = ctx.base / "aliases.jsonl"
        descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        with os.fdopen(descriptor, "r+") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
                return
            lines = stream.read(1024 * 1024 + 1).splitlines()
            for line in lines:
                try:
                    known = json.loads(line)
                    if isinstance(known, dict) and known.get("hash") == row["hash"]:
                        return
                except ValueError:
                    pass
            encoded = json.dumps(row) + "\n"
            if info.st_size + len(encoded.encode()) <= 1024 * 1024:
                stream.write(encoded)
    except (OSError, ValueError):
        pass
    finally:
        if acquired:
            try:
                lock.rmdir()
            except OSError:
                pass


def inspect_transcript(ctx, path, header_result=None, headers_only=False):
    """Return an admitted identity or an exact, nonexception skip reason."""
    path = Path(path)
    if not regular(path):
        return None, "unreadable header"
    if st.within_instance(path, ctx.projects, ctx.prefix):
        if not SAFE_ID.fullmatch(path.stem):
            return None, "unsupported"
        header, readable = st.read_header_result(path)
        if headers_only:
            # Counting opens first lines only. A Claude transcript may begin with
            # a summary or metadata entry, so path admission decides unless the
            # first line is unmistakably another harness's header.
            native = st._header_format(header)
            kind = native if native in ("codex", "pi") else ("claude" if readable else None)
        else:
            kind = st.probe_format(path, ctx.projects, ctx.prefix)
        if kind != "claude":
            return None, "unsupported" if readable else "unreadable header"
        return ("claude", path.stem, header if isinstance(header, dict) else {}), None
    header, readable = st.read_header_result(path) if header_result is None else header_result
    if not readable:
        return None, "unreadable header"
    if not isinstance(header, dict):
        return None, "unsupported"
    kind = header.get("type")
    if kind == "session_meta":
        payload = header.get("payload", {})
        if not isinstance(payload, dict):
            return None, "unsupported"
        harness = "codex"
    elif kind == "session" and type(header.get("version")) is int:
        payload = header
        harness = "prime" if (ctx.home / ".prime/agent/sessions") in path.parents or (ctx.home / ".prime/agent/sessions").resolve() in path.resolve().parents else "pi"
    else:
        return None, "unsupported"
    sid, cwd = payload.get("id"), payload.get("cwd")
    if not isinstance(sid, str) or not SAFE_ID.fullmatch(sid) or not isinstance(cwd, str):
        return None, "unsupported"
    if not st.within_instance_cwd(cwd, ctx.root):
        return None, "other project"
    return (harness, sid, header), None


def transcript_info(ctx, path):
    return inspect_transcript(ctx, path)[0]


def folder_for(ctx, path):
    if st.within_instance(path, ctx.projects, ctx.prefix):
        return Path(path).resolve().relative_to(ctx.projects.resolve()).parts[0]
    info = transcript_info(ctx, path)
    if not info:
        raise ValueError("transcript is outside this instance")
    return ctx.prefix + "--" + info[0]


def event_time(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError, OverflowError):
        return None


def codex_header_index(ctx, skipped=None):
    """One complete, admitted family inventory; unchanged headers are cached."""
    owner = Context(ctx.root, ctx.prefix + "--codex")
    if not owner.safe_base():
        return {}
    cache_path = owner.base / "header-index.json"
    cache = {}
    try:
        if stat.S_ISREG(cache_path.lstat().st_mode) and cache_path.stat().st_size <= 16 * 1024 * 1024:
            cache = read_json(cache_path)
    except OSError:
        pass
    result = {}
    base = ctx.home / ".codex/sessions"
    for directory, dirs, files in os.walk(base, followlinks=False):
        dirs.sort(reverse=True)
        for name in sorted(files):
            if not name.startswith("rollout-") or not name.endswith(".jsonl"):
                continue
            path = Path(directory) / name
            if not regular(path):
                if skipped is not None:
                    skipped["unreadable header"] += 1
                continue
            try:
                info = path.stat()
                key = [str(path.resolve()), info.st_size, info.st_mtime_ns]
                saved = cache.get(str(path), {})
                saved_header = saved.get("header", {}) if isinstance(saved, dict) else {}
                saved_payload = saved_header.get("payload", {}) if isinstance(saved_header, dict) else {}
                valid_cache = (isinstance(saved, dict) and isinstance(saved_header, dict) and isinstance(saved_payload, dict)
                               and saved_header.get("type") == "session_meta"
                               and isinstance(saved_payload.get("cwd"), str)
                               and saved_payload.get("id") == saved.get("id")
                               and saved.get("version") == 2
                               and isinstance(saved.get("id"), str) and SAFE_ID.fullmatch(saved["id"])
                               and (saved.get("parent") is None or isinstance(saved["parent"], str))
                               and isinstance(saved.get("mtime"), (float, int))
                               and (saved.get("last_event") is None or
                                    isinstance(saved["last_event"], (float, int)) and math.isfinite(saved["last_event"])))
                if valid_cache and saved.get("key") == key:
                    row = saved
                else:
                    info_result, reason = inspect_transcript(ctx, path)
                    if not info_result or info_result[0] != "codex":
                        if skipped is not None:
                            skipped[reason or "unsupported"] += 1
                        continue
                    _, sid, header = info_result
                    payload = header["payload"]
                    parent = st.parent_of(header)
                    row = {"id": sid, "parent": parent, "mtime": info.st_mtime,
                           "last_event": None,
                           "key": key, "version": 2,
                           "header": {"type": "session_meta", "timestamp": header.get("timestamp") or payload.get("timestamp"),
                                      "payload": {"id": sid, "cwd": payload["cwd"],
                                                  "originator": payload.get("originator"),
                                                  "source": payload.get("source") if isinstance(payload.get("source"), str) else None,
                                                  "parent_thread_id": parent}}}
                if not st.within_instance_cwd(row.get("header", {}).get("payload", {}).get("cwd"), ctx.root):
                    if skipped is not None:
                        skipped["other project"] += 1
                    continue
                result[str(path)] = row
            except Exception as exc:
                if skipped is not None:
                    skipped["failed"] += 1
                owner.error("header index failed: " + str(exc))
                continue
    private_dir(owner.base)
    atomic(cache_path, json.dumps(result))
    return result


def family_rows(index, path):
    root = index.get(str(path))
    if not root:
        return []
    rows, seen = [(str(path), root)], {root["id"]}
    pending = [root["id"]]
    children = {}
    for name, row in index.items():
        children.setdefault(row.get("parent"), []).append((name, row))
    while pending:
        for name, row in children.get(pending.pop(), []):
            if row["id"] in seen:
                continue
            seen.add(row["id"])
            rows.append((name, row))
            pending.append(row["id"])
    return rows


def family_watermark(ctx, index, path):
    """Read missing event watermarks only after a family passes admission."""
    family = family_rows(index, path)
    changed = False
    for name, row in family:
        if row.get("last_event") is None:
            info = transcript_info(ctx, name)
            if not info or info[0] != "codex":
                raise ValueError("family transcript changed after admission")
            row["last_event"] = st.last_event_time(name, info[2]) or row["mtime"]
            changed = True
    if changed:
        owner = Context(ctx.root, ctx.prefix + "--codex")
        if owner.safe_base():
            atomic(private_dir(owner.base) / "header-index.json", json.dumps(index))
    return max((row["last_event"] for _, row in family), default=Path(path).stat().st_mtime)


def discover_paths(ctx, codex_index=None, skipped=None):
    for folder in st.transcript_folders(ctx.projects, ctx.prefix):
        for path in Path(folder).glob("*.jsonl"):
            if st.within_instance(path, ctx.projects, ctx.prefix) and regular(path):
                yield path
    index = codex_header_index(ctx, skipped=skipped) if codex_index is None else codex_index
    for name, row in index.items():
        if not row.get("parent"):
            yield Path(name)
    for harness in ("pi", "prime"):
        base = ctx.home / ("." + harness) / "agent/sessions"
        for directory, dirs, files in os.walk(base, followlinks=False):
            if len(Path(directory).relative_to(base).parts) >= 3:
                dirs[:] = []
            for name in sorted(files):
                path = Path(directory) / name
                if path.suffix != ".jsonl":
                    continue
                try:
                    info, reason = inspect_transcript(ctx, path)
                    if info:
                        yield path
                    elif skipped is not None:
                        skipped[reason] += 1
                except Exception as exc:
                    if skipped is not None:
                        skipped["failed"] += 1
                    ctx.error("discovery failed: " + str(exc))


def refresh_index(ctx, codex_index=None, rows=None):
    if rows is None:
        rows, _ = candidates(ctx, ctx.policy.get("retroactive_days", 90), include_live=True, codex_index=codex_index)
    oldest = min((row[0] for row in rows), default=None)
    data = {"unrecorded_count": len(rows),
            "oldest_date": datetime.fromtimestamp(oldest, timezone.utc).date().isoformat() if oldest else None,
            "days": max(0, int((time.time() - oldest) / 86400)) if oldest else 0,
            "waiting_push": read_json(waiting_path(ctx)).get("waiting_push", 0)}
    main = Context(ctx.root)
    if main.safe_base():
        base = private_dir(main.base)
        atomic(base / "index.json", json.dumps(data))
    return data


def probe(path, ctx=None):
    return st.probe_format(path, projects_dir=ctx.projects if ctx else None,
                           prefix=ctx.prefix if ctx else None) is not None


def cli_flags(ctx):
    """Once per CLI version establish *every* isolation flag, never trust defaults."""
    executable = shutil.which("claude")
    if not executable:
        return None, "claude unavailable"
    env = clean_env()
    for key in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "NODE_OPTIONS", "TRACEPARENT"):
        env.pop(key, None)
    # Explicit /tmp ignores TMPDIR, which may point inside the project.
    with tempfile.TemporaryDirectory(prefix="egregore-record-cli-", dir="/tmp") as empty:
        try:
            version_run = subprocess.run([executable, "--version"], cwd=empty, env=env,
                                         capture_output=True, text=True, timeout=5)
            if version_run.returncode or not version_run.stdout.strip():
                return None, "claude version check failed"
            version = re.sub(r"[^a-zA-Z0-9_.-]", "-", version_run.stdout.strip())[:120]
            cache = ctx.home / ".egregore/trails" / ("cli-" + version + ".json")
            checked = read_json(cache)
            if checked.get("executable") != executable or checked.get("version") != version or checked.get("isolation_revision") != 2:
                help_run = subprocess.run([executable, "--help"], cwd=empty, env=env,
                                          capture_output=True, text=True, timeout=5)
                if help_run.returncode:
                    return None, "claude --help check failed"
                flags = set(re.findall(r"--[a-zA-Z][a-zA-Z-]*", help_run.stdout))
                required = {"--strict-mcp-config", "--mcp-config", "--setting-sources",
                            "--model", "--output-format"}
                missing = sorted(required - flags)
                if "--tools" not in flags:
                    # A historical deny list cannot prove completeness for an
                    # unfamiliar CLI version. Require the empty allowlist flag.
                    missing.append("--tools")
                checked = {"version": version, "executable": executable, "missing": missing, "isolation_revision": 2}
                private_dir(cache.parent)
                atomic(cache, json.dumps(checked))
            if checked.get("missing"):
                return None, "model skipped: missing " + ", ".join(checked["missing"])
        except (OSError, subprocess.TimeoutExpired):
            return None, "claude isolation check could not run"
    return [executable, "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--setting-sources", ""], None


def model_call(ctx, sid, trail):
    if not ctx.enabled() or ctx.held(sid):
        return None, "held or disabled during build"
    if not ctx.model_enabled():
        return None, "model call disabled"
    flags, reason = cli_flags(ctx)
    if flags is None:
        return None, reason
    # Re-check after capability discovery, immediately before starting the call.
    if not ctx.enabled() or ctx.held(sid) or not ctx.model_enabled():
        return None, "held or disabled during build"
    trail, truncation_reason = st.trim_trail(trail)
    env = clean_env()
    for key in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "NODE_OPTIONS", "TRACEPARENT"):
        env.pop(key, None)
    timeout = float(os.environ.get("EGREGORE_RECORD_MODEL_TIMEOUT_S", ctx.policy.get("model_timeout_s", 240)))
    prompt = (SELF.parent / "session-record-prompt.txt").read_text().replace("PERSON_NAME", ctx.display or ctx.author)
    args = flags + ["-p", prompt,
                    "--model", str(ctx.policy.get("model", "haiku")), "--output-format", "text"]
    with tempfile.TemporaryDirectory(prefix="egregore-record-model-", dir="/tmp") as empty:
        child = subprocess.Popen(args, cwd=empty, env=env, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            output, _ = child.communicate(trail, timeout=max(0.1, timeout))
            if child.returncode:
                return None, f"model unavailable (exit {child.returncode})" + ("; " + truncation_reason if truncation_reason else "")
            if not re.search(r"(?m)^## (Asked|Decided|Open|Risks)\s*$", output):
                return None, "model returned no record sections" + ("; " + truncation_reason if truncation_reason else "")
            return output, truncation_reason
        except subprocess.TimeoutExpired:
            # The model is its own process group; kill children too (no orphaned sleep/tools).
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.communicate()
            return None, "model timed out" + ("; " + truncation_reason if truncation_reason else "")


def stub_data(data):
    data = dict(data)
    if data.get("producer"):
        data.update(topic="held", branch="", detail="stub", summary="held spirit record · metrics unavailable", body="")
        return data
    data["topic"] = "held"
    data["branch"] = "held"
    data["date"] = data["date"][:10]
    data["detail"] = "stub"
    data["summary"] = f"held session · {data.get('duration', 'unknown')} · ${float(data.get('cost_usd', 0)):.2f}"
    data["body"] = ""
    return data


def record_text(data):
    if data.get("producer"):
        return native_record_adapter().render_record(data)
    stub = data.get("detail") == "stub"
    if stub:
        data = stub_data(data)
    fields = {"kind": "session-record",
              "from": data["author"], "date": data["date"][:10],
              "session": data["session"], "detail": data["detail"], "status": data["status"],
              "record_revision": data["record_revision"], "cost_usd": data.get("cost_usd", 0),
              "cost_source": data.get("cost_source", "estimate"), "duration": data.get("duration", "unknown")}
    if not stub:
        # Active time sits beside the wall clock; a held stub keeps its whitelist.
        if data.get("active"):
            fields["active"] = data["active"]
        fields.update(capture_schema="egregore-capture/v1", capture_mode="baseline", topic=data["topic"])
        if data.get("harness"):
            fields["harness"] = data["harness"]
        if data.get("through"):
            fields["through"] = data["through"]
        for key in ("cost_coverage", "cost_sessions"):
            if key in data:
                fields[key] = data[key]
    if not stub and data.get("backfill"):
        fields["backfill"] = True
    # Simple scalar YAML with human-readable enum values; JSON quoting for arbitrary text.
    literal = {"kind", "detail", "status", "cost_source", "capture_schema", "capture_mode"}
    lines = ["---"] + [f"{k}: {v if k in literal else json.dumps(v, ensure_ascii=False)}" for k, v in fields.items()] + ["---", "", f"# Session: {data['topic']}", ""]
    if stub:
        return "\n".join(lines) + "\n## Summary\n\n" + data["summary"] + "\n"
    for key, val in (("Capture Schema", "egregore-capture/v1"), ("Capture Mode", "baseline"),
                     ("Date", data["date"]), ("Author", data["author"]), ("To", data["author"]),
                     ("Branch", data["branch"]), ("Session", data["session"]), ("Duration", data["duration"]),
                     *((("Active", data["active"]),) if data.get("active") else ())):
        lines.append(f"**{key}**: {val}")
    return "\n".join(lines) + "\n\n## Summary\n\n" + data["summary"] + "\n\n" + data.get("body", "").strip() + "\n"


def output_path(ctx, data):
    old = existing(ctx, data["session"])
    date = data["date"][:10]
    if data.get("detail") == "stub":
        month = old[0].parent if old else ctx.memory / "sessions" / date[:7]
        stem = f"{date[8:10]}-{data['author'].lower()}-held-"
        choices = [month / (stem + identifier + ".md")
                   for identifier in dict.fromkeys((data["session"][:8], data["session"]))]
        # Keep a previous full-ID fallback even if its short name becomes free.
        if old and old[0] in choices:
            return old[0]
        for path in choices:
            if not path.exists() and not path.is_symlink():
                return path
            if not path.is_symlink() and stat.S_ISREG(path.lstat().st_mode):
                with path.open("rb") as stream:
                    meta = metadata(stream.read(256 * 1024).decode("utf-8", errors="replace"))
                if meta.get("session") == data["session"]:
                    return path
        raise ValueError("held record filename is already in use")
    if old:
        return old[0]
    slug = re.sub(r"[^a-z0-9]+", "-", data["topic"].lower()).strip("-")[:50] or "session"
    path = ctx.memory / "sessions" / date[:7] / f"{date[8:10]}-{data['author'].lower()}-{slug}.md"
    if path.exists():
        path = path.with_name(path.stem + "-" + data["session"] + ".md")
    return path


def apply_record_hold(ctx, path, meta, force=False):
    """Sanitize an unpublished working file while the memory lock is held."""
    ctx.reload()
    sid = str(meta.get("session", ""))
    if not force and not ctx.held(sid):
        return [path]
    deleted = deleted_records(ctx, sid)
    if not path.exists():
        return [path, *deleted]
    if ctx.state.get("session_records_hold_stub", True) is False:
        path.unlink(missing_ok=True)
    else:
        held = dict(meta, author=meta.get("from", ctx.author), session=sid,
                    topic=meta.get("topic", "session"),
                    date=meta.get("started_at", meta.get("date", datetime.now(timezone.utc).isoformat())),
                    branch=meta.get("branch", "session"), status=meta.get("status", "in progress"),
                    record_revision=int(meta.get("record_revision", 0)) + (meta.get("detail") != "stub"))
        held = stub_data(held)
        target = output_path(ctx, held)
        text = record_text(held)
        if target != path:
            path.unlink()
        # If writing the neutral file is interrupted, HEAD identifies the
        # deleted side for the next hold/build to recover. Never leave both.
        atomic(target, text, 0o644)
        return [target, *deleted]
    return [path, *deleted]


def pending_records(ctx):
    """Own working records left behind by earlier sessions; never other authors."""
    dirty = set(git(ctx, "diff", "--name-only", "-z", "HEAD", "--", "sessions", check=True).stdout.split("\0"))
    dirty.update(git(ctx, "ls-files", "--others", "--exclude-standard", "-z", "--", "sessions", check=True).stdout.split("\0"))
    for path, meta, text in all_records(ctx):
        if meta.get("producer"):
            continue  # Native checkpoints need their own fresh publication admission.
        if not text.startswith("---\n") or not re.search(r"(?m)^from:", text.split("---", 2)[1]):
            continue
        if str(path.relative_to(ctx.memory)) not in dirty or not owned_record(ctx, {"from": meta.get("from")}):
            continue
        sid = str(meta.get("session", ""))
        if SAFE_ID.fullmatch(sid):
            target = resolve_context(ctx, sid)[0]
            yield target, path, meta


def publish_record(ctx, data, target, removed=(), meta=None):
    if data.get("producer") or meta and meta.get("producer"):
        raise ValueError("native record publication requires its own fresh admission")
    selected = [(ctx, target, meta if meta is not None else metadata(record_text(data)))]
    if data["mode"] == "end":
        selected.extend(row for row in pending_records(ctx) if row[1] != target)

    paths = [path for _, path, _ in selected] + list(removed)
    require_human_publication(ctx, paths)

    def before_publish():
        for owner, path, meta in selected:
            paths.extend(item for item in apply_record_hold(owner, path, meta, force=data["mode"] == "redact")
                         if item not in paths)
        return data["mode"] == "redact" or ctx.enabled()

    commit(ctx, paths, f"chore(sessions): record {data['topic']}",
           before_publish=before_publish)


def capture(ctx, data, staging=None, *, _native=None):
    """Canonical writer: capture-run for transcripts; typed host permit for native facts.

    Native permits are in-process only and rechecked under the same memory lock.
    Standalone JSON cannot enter that path or publish a native checkpoint.
    """
    if data.get("producer") or _native is not None:
        adapter = native_record_adapter()
        if not isinstance(_native, adapter._NativeCapture) or staging:
            raise ValueError("native records require a registered host source resolver")
    if not ctx.safe_base():
        return None
    if staging:
        staging_directory(ctx, staging)
    lock = ctx.memory_lock()
    if not staging and not lock.acquire(wait=0 if _native else 120):
        raise RuntimeError("memory writer busy")
    try:
        ctx.reload()
        old = existing(ctx, data["session"])
        if old and old[1].get("producer") and _native is None:
            raise ValueError("native record replacement requires host admission")
        if _native is not None:
            data = _native.prepare(ctx, old)
            if data is None:
                return _native.target
        held = ctx.held(data["session"]) or data["mode"] == "redact"
        if old:
            if not owned_record(ctx, old[1]):
                raise ValueError("that record belongs to another person")
            revision = int(old[1].get("record_revision", 0))
            stale = data["record_revision"] <= revision
            final = old[1].get("status") == "final" and data["mode"] not in ("end", "redact", "sweep", "backfill") and data.get("harness") not in ("codex", "pi", "prime")
            if stale or final:
                removed = deleted_records(ctx, data["session"]) if held and not staging else []
                if removed and _native is None:
                    publish_record(ctx, stub_data(data), old[0], removed, meta=old[1])
                return old[0] if _native is not None else None
        if data["mode"] != "redact" and not ctx.enabled():
            return None
        if held:
            if ctx.state.get("session_records_hold_stub", True) is False:
                if not staging:
                    if _native is not None:
                        _native.recheck(ctx, data)
                    if old:
                        old[0].unlink()
                    removed = deleted_records(ctx, data["session"])
                    if (old or removed) and data["mode"] != "checkpoint" and _native is None:
                        publish_record(ctx, stub_data(data), old[0] if old else removed[0], removed)
                return None
            data = stub_data(data)
        target = _native.target if _native is not None else output_path(ctx, data)
        if staging:
            # A queued end can derive a new topic before a batch publishes.
            # Keep that session's first staging path, just as memory does.
            target = next((p for p, meta, _ in staged_records(ctx, staging)
                           if meta.get("session") == data["session"]),
                          Path(staging) / target.relative_to(ctx.memory))
            # Distinct sessions can share a date and topic within one batch.
            if target.exists() and metadata(staging_file(ctx, staging, target).read_text()).get("session") != data["session"]:
                target = target.with_name(target.stem + "-" + data["session"] + ".md")
            staging_directory(ctx, target.parent, create=True)
            if target.exists() or target.is_symlink():
                staging_file(ctx, staging, target)
        if _native is None:
            destination_root = Path(staging).resolve() if staging else ctx.memory
            if target.is_symlink() or not target.resolve().is_relative_to(destination_root):
                raise ValueError("record destination is outside its admitted root")
            if target.is_file():
                with target.open("rb") as stream:
                    destination = metadata(stream.read(256 * 1024).decode("utf-8", errors="replace"))
                if destination.get("producer"):
                    raise ValueError("native record replacement requires host admission")
        text = record_text(data)
        if _native is not None:
            _native.recheck(ctx, data)
        removed = []
        if not staging and old and old[0] != target:
            old[0].unlink()
            removed.append(old[0])
        atomic(target, text, 0o644)
        if not staging and held:
            removed.extend(deleted_records(ctx, data["session"]))
        if not staging and _native is None and (data["mode"] != "checkpoint" or removed):
            publish_record(ctx, data, target, removed)
        return target
    finally:
        lock.release()


def capture_via_engine(ctx, data, staging=None):
    command = ["bash", str(ctx.root / "bin/capture-run.sh"), "--mode", "baseline", "--author", data["author"],
               "--display-name", ctx.display, "--topic", data["topic"], "--summary", data["summary"],
               "--session-id", data["session"], "--branch", data["branch"], "--date", data["date"],
               "--duration", data["duration"], "--replace-session", "--record-metadata", json.dumps({k: v for k, v in data.items() if k != "body"}),
               "--project-root", str(ctx.root), "--record-folder", ctx.folder, "--no-reconcile", "--async-push"]
    if staging:
        command += ["--staging", str(staging)]
    result = subprocess.run(command, input=data.get("body", ""), text=True, capture_output=True, env=clean_env())
    if result.returncode:
        raise RuntimeError("capture failed: " + result.stderr[-1000:])
    return result.stdout.strip()


def redact_locked(ctx, sid):
    old = redaction_record(ctx, sid)
    if not old:
        return "none yet"
    path, meta, _ = old
    adapter = native_record_adapter() if meta.get("producer") else None
    if not owned_record(ctx, meta):
        raise ValueError("that record belongs to another person")
    if adapter is not None:
        return adapter.withdraw_locked(ctx, sid)
    data = {"author": ctx.author, "session": sid, "topic": meta.get("topic", "session"),
            "date": meta.get("started_at", meta.get("date", datetime.now(timezone.utc).isoformat())),
            "branch": meta.get("branch", "session"), "duration": meta.get("duration", "unknown"),
            "cost_usd": meta.get("cost_usd", 0), "cost_source": meta.get("cost_source", "estimate"),
            "status": meta.get("status", "final"), "record_revision": int(meta.get("record_revision", 0)) + 1,
            "detail": "stub", "mode": "redact", "body": "", "summary": "held session"}
    capture_via_engine(ctx, stub_data(data))
    return "stubbed" if ctx.state.get("session_records_hold_stub", True) is not False else "removed"


def repository_history(ctx, facts):
    """Read-only enrichment at runtime; fixture suites can prohibit project Git."""
    if os.environ.get("EGREGORE_RECORD_NO_PROJECT_GIT") == "1" or not (ctx.root / ".git").exists():
        return None
    if not facts.get("first") or not facts.get("last"):
        return None
    start = datetime.fromtimestamp(facts["first"], timezone.utc).isoformat()
    end = datetime.fromtimestamp(facts["last"], timezone.utc).isoformat()
    # Parallel sessions share one author and overlapping hours, so a time window
    # alone credits every session with every commit. Read only the branches this
    # session's transcript ran on.
    refs = session_refs(ctx, facts)
    if not refs:
        return None
    try:
        result = subprocess.run(["git", "-C", str(ctx.root), "log", "--format=%h %s",
                                 "--author=" + ctx.author, "--since=" + start, "--until=" + end,
                                 "--end-of-options", *refs, "--"],
                                env=clean_env(), capture_output=True, text=True, timeout=5)
        return result.stdout if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


SAFE_BRANCH = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")


def session_refs(ctx, facts):
    """Each branch the session ran on, as a local ref or else its origin copy."""
    refs = []
    for branch in sorted(set(facts.get("branches") or []) | {facts.get("branch") or ""}):
        if not SAFE_BRANCH.match(branch) or branch.startswith("-") or ".." in branch:
            continue
        for ref in ("refs/heads/" + branch, "refs/remotes/origin/" + branch):
            try:
                found = subprocess.run(["git", "-C", str(ctx.root), "rev-parse", "--verify", "--quiet",
                                        ref + "^{commit}"], env=clean_env(), capture_output=True,
                                       text=True, timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                return []
            if found.returncode == 0:
                refs.append(ref)
                break
    return refs


# The live cost line. A checkpoint build prices the running session with the
# record's own outline; the first time the session passes a mark it leaves one
# line beside the session's debounce stamp, and the next Stop hook prints it.
COST_MARK_USD = 200.0
CODEX_MARK_INPUT_TOKENS = 10_000_000


def _compact(count):
    value, unit = float(count), ""
    for name in ("K", "M", "B"):
        if round(value, 1) < 1000:
            break
        value, unit = value / 1000, name
    return (f"{value:.1f}".removesuffix(".0") if unit else str(int(count))) + unit


def cost_marks(harness, cost, source, input_tokens):
    """The marks a running session has passed: priced cost, or Codex input tokens."""
    marks = []
    if source != "unavailable" and cost >= COST_MARK_USD:
        marks.append("usd-200")
    if harness == "codex" and input_tokens >= CODEX_MARK_INPUT_TOKENS:
        marks.append("codex-input-10m")
    return marks


def cost_line(harness, cost, source, input_tokens, model_calls):
    priced = source != "unavailable" and round(cost, 2) > 0
    if priced:
        head = f"this session has cost ${cost:,.2f}" + (" at list price" if source == "list price" else "") + " so far"
    else:
        head = f"this session has used {_compact(input_tokens)} input tokens so far"
    detail = f"{model_calls} model calls"
    if harness == "codex" and priced:
        detail = f"{_compact(input_tokens)} input tokens, {detail}"
    return f"{head} ({detail}) · consider a handoff or a fresh session"


def queue_cost_line(ctx, sid, facts, outline):
    """Leave one line for the next stop when the session passes a mark it has not passed."""
    try:
        calls = [call for call in facts.get("calls", {}).values() if isinstance(call, dict)]
        harness = facts.get("harness") or "claude"
        cost, source = float(outline.get("cost") or 0), outline.get("cost_source")
        inputs = sum(call.get("input") or 0 for call in calls)
        marks = cost_marks(harness, cost, source, inputs)
        if not marks:
            return None
        stamps = ctx.base / "stamps"
        ledger = stamps / (sid + ".cost")
        announced = read_json(ledger).get("announced")
        announced = [mark for mark in announced if isinstance(mark, str)] if isinstance(announced, list) else []
        if set(marks) <= set(announced):
            return None
        line = cost_line(harness, cost, source, inputs, outline.get("model_calls", len(calls)))
        # The line before the ledger: an interrupted write repeats a line, never loses one.
        atomic(stamps / (sid + ".cost-line"), line + "\n")
        atomic(ledger, json.dumps({"announced": sorted(set(announced) | set(marks))}))
        return line
    except Exception:
        return None


def take_cost_line(ctx, sid):
    """The pending cost line, at most once: concurrent stops race on one rename."""
    pending = ctx.base / "stamps" / (sid + ".cost-line")
    taken = pending.with_name(f"{pending.name}.{os.getpid()}")
    try:
        os.replace(pending, taken)
    except OSError:
        return None
    text = ""
    try:
        with taken.open("rb") as stream:
            text = stream.read(512).decode("utf-8", errors="replace")
    except OSError:
        pass
    try:
        taken.unlink()
    except OSError:
        pass
    return " ".join(re.sub(r"[\x00-\x1f\x7f]", " ", text).split()) or None


def say(fd, line):
    """One line on the hook's stdout; session-record.sh keeps it on this descriptor."""
    if line:
        try:
            os.write(fd, (line + "\n").encode("utf-8"))
        except (OSError, ValueError, OverflowError):
            pass


def build(ctx, args):
    sid = args.session_id
    path = Path(args.transcript)
    info = transcript_info(ctx, path)
    if not info:
        return "failed"
    harness, native, header = info
    if harness != "claude":
        sid = args.session_id = native
    if harness == "codex" and not codex_human_root(header):
        return "skipped"
    ctx.reload()
    index = getattr(args, "codex_index", None)
    if index is None:
        index = codex_header_index(ctx) if harness == "codex" else {}
    family = family_rows(index, path)
    modified = max((Path(member).stat().st_mtime for member, _ in family), default=path.stat().st_mtime)
    idle = time.time() - modified
    # The caller owns this session's lock; every descendant must still be idle.
    if args.mode in ("backfill", "sweep") and idle < 600:
        return "live"
    if args.mode in ("backfill", "sweep") and ctx.held(sid, args.transcript):
        return "skipped"
    old = existing(ctx, sid)
    if old and old[1].get("producer"):
        return "skipped"  # Native facts are never reconstructed as a human transcript.
    if not old and ctx.held(sid, args.transcript) and ctx.state.get("session_records_hold_stub", True) is False:
        if args.mode == "end" and ctx.safe_base():
            publish_held_deletions(ctx, sid)
        return "skipped"
    if args.staging:
        staged = next((row for row in staged_records(ctx, args.staging)
                       if row[1].get("session") == sid), None)
        if staged and (old is None or int(staged[1].get("record_revision", 0)) > int(old[1].get("record_revision", 0))):
            old = staged
    if old and old[1].get("status") == "final" and args.mode != "end" and harness == "claude":
        return "skipped"
    if not ctx.safe_base() or not ctx.enabled() or not ctx.author or not ctx.memory.is_dir():
        return "skipped"
    if not getattr(args, "probed", False) and not probe(path, ctx):
        return "failed"
    # The shared module owns main and gated subagent parsing.
    facts = st.load_session(path, projects_dir=ctx.projects, prefix=ctx.prefix, root=ctx.root,
                            codex_index=index if harness == "codex" else None, require_root_prompts=True)
    if st.skip_reason(facts):
        return "skipped"
    trail = st.render_trail(facts)
    private_dir(ctx.base)
    atomic(ctx.base / (sid + ".md"), trail)
    output, reason = (None, "held session") if ctx.held(sid, args.transcript) else model_call(ctx, sid, trail)
    if not ctx.enabled():
        return "skipped"
    requested = args.detail or ctx.state.get("session_records_detail", ctx.policy.get("default_detail", "outline"))
    branch = facts.get("branch") or next(iter(sorted(facts.get("branches", []))), "")
    topic = re.sub(r"^(?:dev/[^/]+/|feature/|bugfix/)", "", branch).replace("-", " ")
    if not branch or branch.casefold() in {"head", "(detached)"} or branch in {ctx.config.get("base_branch", "develop"), "develop", "main", "master"}:
        # Only *guarded* model output can supply the file name.
        preliminary = st.outline(facts, repo=ctx.root, model_output=output, topic="session",
                                 person=ctx.display or ctx.author, friction_reason=reason)
        first_asked = preliminary["sections"].get("Asked", "")
        if isinstance(first_asked, list):
            first_asked = "\n".join(first_asked)
        first_asked = first_asked.strip().splitlines()[0] if first_asked.strip() else ""
        topic = "-".join(re.findall(r"[a-z0-9]+", first_asked.lower())[:4]) if output and not first_asked.startswith(("(withheld", "not derived")) else "session"
    history = repository_history(ctx, facts)
    outline = st.outline(facts, repo=ctx.root, model_output=output, detail=requested, topic=topic, author=ctx.author,
                         person=ctx.display or ctx.author,
                         friction_reason=reason, git_log=history, flaked=gate_flakes(ctx.memory, sid))
    if args.mode == "checkpoint":
        queue_cost_line(ctx, sid, facts, outline)
    stamp = outline.get("first") or time.time()
    date = datetime.fromtimestamp(stamp, timezone.utc).isoformat() if isinstance(stamp, (int, float)) else stamp
    body = outline["body"]
    sections = outline["sections"]
    summary = sections.get("Summary", "")
    if isinstance(summary, list):
        summary = "\n".join(summary)
    if body.startswith("## Summary"):
        body = body.partition("\n## ")[2]
        body = "## " + body if body else ""
    status = "in progress" if args.mode == "checkpoint" else "final"
    if harness != "claude":
        status = ("final" if args.mode == "end" or idle >= 86400
                  or (old and old[1].get("status") == "final") else "in progress")
    through = (family_watermark(ctx, index, path) if harness == "codex" else
               round(modified, 6) if harness in ("pi", "prime") else facts.get("last") or stamp)
    data = {"author": args.author or ctx.author, "session": sid, "topic": topic or "session", "date": date,
            "harness": harness, "through": datetime.fromtimestamp(through, timezone.utc).isoformat(),
            "branch": branch, "duration": outline["duration"], "active": outline["active"], "cost_usd": outline["cost"],
            "cost_source": outline["cost_source"], "cost_coverage": outline["cost_coverage"],
            "cost_sessions": outline["cost_sessions"], "status": status,
            "record_revision": int(old[1].get("record_revision", 0)) + 1 if old else 1,
            "detail": outline["detail"], "mode": args.mode, "body": body, "summary": summary,
            "backfill": args.mode == "backfill" or bool(args.staging)}
    if not ctx.enabled():
        return "skipped"
    if ctx.held(sid, args.transcript):
        data = stub_data(data)
    result = capture_via_engine(ctx, data, args.staging)
    atomic(ctx.base / "stamps" / sid, str(time.time()))
    if not args.staging:
        refresh_index(ctx)
    return "built" if result else "skipped"


def finish_session(ctx, lock, args=None):
    """Every session-lock holder drains final requests before giving up ownership."""
    prior = redaction_record(ctx, lock.path.name)
    if prior and prior[1].get("producer"):
        lock.release()
        return
    marker = lock.path.with_name(lock.path.name + ".end-requested")
    while lock.owner() == os.getpid():
        while marker.exists():
            pending = argparse.Namespace(**vars(args)) if args is not None else None
            if pending is None or not pending.transcript:
                _, sid, transcript = resolve_context(ctx, lock.path.name)
                if not transcript:
                    break
                pending = record_parser().parse_args(["--root", str(ctx.root), "--mode", "end",
                                                     "--session-id", sid, "--transcript", str(transcript)])
            marker.unlink(missing_ok=True)
            pending.mode = "end"
            pending.probed = False
            try:
                build(ctx, pending)
            except Exception as exc:
                ctx.error(str(exc))
        unresolved = marker.exists()
        lock.release()
        if unresolved or not marker.exists() or not lock.acquire():
            return


def run_worker(ctx, args, lock):
    try:
        # Entry hands over owner before returning; no transcript opens before this.
        until = time.monotonic() + 5
        while lock.owner() != os.getpid():
            if time.monotonic() > until:
                return 0
            time.sleep(0.01)
        if not probe(Path(args.transcript), ctx):
            return 0
        args.probed = True
        marker = lock.path.with_name(lock.path.name + ".end-requested")
        while True:
            if marker.exists():
                marker.unlink(missing_ok=True)
                args.mode = "end"
            try:
                build(ctx, args)
            except Exception as exc:
                ctx.error(str(exc))
            if marker.exists():
                continue
            lock.release()
            # Close the release/request race. The end entrant also retries after
            # depositing its marker; exactly one can acquire the next lock.
            if marker.exists() and lock.acquire():
                continue
            break
    finally:
        finish_session(ctx, lock, args)
    return 0


def record(args):
    ctx = Context(args.project_root or args.root, args.folder)
    if args.mode == "sweep" and not args.transcript:
        return sweep(ctx, args)
    if args.mode == "redact":
        if not args.session_id or not SAFE_ID.fullmatch(args.session_id):
            return 0
        ctx = resolve_context(ctx, args.session_id)[0]
        if not ctx.safe_base():
            return 0
        lock = ctx.lock(args.session_id, "redact")
        if not lock.acquire(wait=120):
            ctx.error("redact timed out waiting for session worker")
            return 1
        native_record = redaction_record(ctx, args.session_id)
        native_record = bool(native_record and native_record[1].get("producer"))
        try:
            redact_locked(ctx, args.session_id)
            if not native_record:
                refresh_index(ctx)
        finally:
            if native_record:
                lock.release()  # A durable intent owns no human transcript-end request.
            else:
                finish_session(ctx, lock, args)
        return 0
    if not args.transcript:
        try:
            hook = json.load(sys.stdin)
        except (ValueError, OSError):
            return 0
        args.transcript = hook.get("transcript_path")
        args.session_id = hook.get("session_id")
    if not args.transcript:
        return 0
    path = Path(args.transcript)
    # Native formats must expose an admitted cwd before any body is opened.
    info = transcript_info(ctx, path)
    if not info:
        # An interrupted hold's deletion needs no transcript content. Keep this
        # cleanup separate from admission to build any new record.
        if (args.mode == "end" and args.session_id == path.stem
                and SAFE_ID.fullmatch(path.stem) and regular(path)
                and st.within_instance(path, ctx.projects, ctx.prefix)):
            target = Context(ctx.root, folder_for(ctx, path))
            if (target.safe_base() and target.enabled() and target.author and target.memory.is_dir()
                    and target.held(args.session_id) and target.state.get("session_records_hold_stub", True) is False):
                publish_held_deletions(target, args.session_id)
        return 0
    if info[0] != "claude":
        args.session_id = info[1]
    if info[0] == "codex" and not codex_human_root(info[2]):
        return 0
    if not args.session_id or not SAFE_ID.fullmatch(args.session_id):
        return 0
    ctx = Context(ctx.root, folder_for(ctx, path))
    if not ctx.safe_base():
        return 0
    lock = ctx.lock(args.session_id, args.mode)
    if args.worker:
        return run_worker(ctx, args, lock)
    if not ctx.enabled() or not regular(path) or not ctx.author or not ctx.memory.is_dir():
        return 0
    if args.mode == "checkpoint" and getattr(args, "notice_fd", None) is not None:
        # The one line a checkpoint prints: a cost mark the last build passed.
        say(args.notice_fd, take_cost_line(ctx, args.session_id))
    if ctx.held(args.session_id, args.transcript) and ctx.state.get("session_records_hold_stub", True) is False:
        if args.mode == "end":
            publish_held_deletions(ctx, args.session_id)
        return 0
    acquired = lock.acquire()
    marker = lock.path.with_name(lock.path.name + ".end-requested")
    if not acquired:
        if args.mode != "end":
            return 0
        atomic(marker, "end")
        acquired = lock.acquire()
        if not acquired:
            return 0
    try:
        if marker.exists():
            marker.unlink(missing_ok=True)
            args.mode = "end"
        stamp = ctx.base / "stamps" / args.session_id
        if args.mode == "checkpoint" and stamp.exists() and time.time() - stamp.stat().st_mtime < args.debounce:
            return 0
        atomic(stamp, str(time.time()))
        if args.mode in ("backfill", "sweep") or args.staging:
            return 0 if build(ctx, args) == "built" else 1
        command = [sys.executable, str(SELF), "record", "--root", str(ctx.root), "--project-root", str(ctx.root),
                   "--mode", args.mode, "--transcript", str(args.transcript), "--session-id", args.session_id,
                   "--folder=" + ctx.folder, "--worker"]
        if args.detail:
            command += ["--detail", args.detail]
        if args.author:
            command += ["--author", args.author]
        if args.display_name:
            command += ["--display-name", args.display_name]
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        lock.handover(child.pid)
    finally:
        finish_session(ctx, lock, args)
    return 0


def resolve_context(ctx, identifier):
    if not SAFE_ID.fullmatch(identifier):
        raise ValueError("invalid session id")
    matches = {}
    alias_ids = {row["session"] for row in aliases(ctx) if row["hash"] == identifier}
    for path in discover_paths(ctx):
        info = transcript_info(ctx, path)
        if info and (info[1].startswith(identifier) or info[1] in alias_ids
                     or (info[0] in ("pi", "prime") and identifier in (path_identity(path), path_identity(path.resolve())))):
            matches[info[1]] = (Context(ctx.root, folder_for(ctx, path)), path)
    live_owned = set()
    for rows, deleted in ((all_records(ctx), False), (deleted_record_rows(ctx), True)):
        for _, meta, _ in rows:
            sid = str(meta.get("session", ""))
            if sid.startswith(identifier) and SAFE_ID.fullmatch(sid):
                if meta.get("producer"):
                    native_record_adapter()
                if not (deleted and sid in live_owned) and not owned_record(ctx, meta):
                    raise ValueError("that record belongs to another person")
                if not deleted:
                    live_owned.add(sid)
                matches.setdefault(sid, (ctx, None))
    for folder in (ctx.home / ".egregore/trails").glob(ctx.prefix + "*"):
        if not st.valid_trail_folder(folder, ctx.projects, ctx.prefix):
            continue
        for path in folder.glob(identifier + "*.md"):
            if SAFE_ID.fullmatch(path.stem):
                if path.stem not in matches or matches[path.stem][1] is None:
                    matches[path.stem] = (Context(ctx.root, folder.name), None)
    if len(matches) > 1:
        raise ValueError("session prefix is ambiguous")
    if matches:
        sid, (found_ctx, path) = next(iter(matches.items()))
        return found_ctx, sid, path
    return ctx, identifier, None


def hold(ctx, identifier, exact=False):
    if not SAFE_ID.fullmatch(identifier):
        raise ValueError("invalid session id")
    pi_hold = os.environ.get("EGREGORE_NATIVE_HARNESS") in ("pi", "prime")
    alias = next((row for row in aliases(ctx) if row["hash"] == identifier), None)
    if pi_hold and alias is None:
        alias = recover_pi_alias(ctx, identifier)
    if pi_hold and alias:
        info = transcript_info(ctx, alias["path"])
        harness = info[0] if info and info[0] in ("pi", "prime") else os.environ["EGREGORE_NATIVE_HARNESS"]
        target, sid = Context(ctx.root, ctx.prefix + "--" + harness), alias["session"]
    else:
        target, sid, _ = resolve_context(ctx, identifier)
        if exact and sid != identifier:
            target, sid = ctx, identifier
    old = redaction_record(target, sid)
    if old and not owned_record(ctx, old[1]):
        raise ValueError("that record belongs to another person")
    if not target.safe_base():
        raise ValueError("personal trail folder is outside this instance")
    if not exact and not old and not resolve_context(ctx, identifier)[2] and not (target.base / (sid + ".md")).is_file():
        raise ValueError("no session for that id in this instance")
    # A hold takes effect between publications, never during one. Release the
    # memory lock before waiting on the session lock to avoid lock inversion.
    memory_lock = target.memory_lock()
    if not memory_lock.acquire(wait=120):
        raise RuntimeError("memory writer busy; no hold was written")
    try:
        old = redaction_record(target, sid)
        if old and not owned_record(target, old[1]):
            raise ValueError("that record belongs to another person")
        had_record = old is not None
        private_dir(target.base / "holds")
        atomic(target.base / "holds" / sid, datetime.now(timezone.utc).isoformat())
        if pi_hold:
            atomic(target.base / "holds" / identifier, datetime.now(timezone.utc).isoformat())
            if alias:
                atomic(target.base / "holds" / alias["session"], datetime.now(timezone.utc).isoformat())
                remember_pi_alias(target, alias)
    finally:
        memory_lock.release()
    result = subprocess.run(["bash", str(ctx.root / "bin/session-record.sh"), "--mode", "redact",
                             "--session-id", sid, "--project-root", str(ctx.root)],
                            env=clean_env(), capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("hold saved; existing record is busy, retry records redact " + sid)
    if pi_hold and alias is None and exact and not had_record:
        print("Hold recorded for this session's identity; its existing record could not be located. "
              "The hook identity will apply at the next publication.")
        return
    after = existing(target, sid)
    outcome = "stubbed" if after else "removed" if had_record else "none yet"
    print("Session held · existing record " + outcome)


def enroll(ctx):
    """Keep the first time this person answered the past-session offer."""
    since = event_time(ctx.state.get("session_records_since"))
    if since is None:
        now = datetime.now(timezone.utc)
        ctx.set_state("session_records_since", now.isoformat())
        since = now.timestamp()
    return since


def history_since(ctx):
    """The earliest session start the sweep may newly publish, or None once the
    person accepted past sessions with `backfill --yes`. Seeing the offer is not
    acceptance, and neither is an existing record: an install that answered
    before enrollment existed is enrolled at its first sweep."""
    if ctx.state.get("session_records_backfill") == "accepted":
        return None
    return enroll(ctx)


def candidates(ctx, days, include_live=False, codex_index=None, discovery_skipped=None, since=None):
    """With `since`, a session without a record qualifies only when it began at
    or after that time; an unknown start never qualifies. Existing records keep
    their refresh and finalization."""
    recorded = {m.get("session"): m for _, m, _ in all_records(ctx) if m.get("kind") == "session-record"}
    result, skipped = [], Counter(discovery_skipped or {})
    now = time.time()
    index = codex_header_index(ctx, skipped=skipped) if codex_index is None else codex_index
    for path in discover_paths(ctx, codex_index=index, skipped=skipped):
        try:
            cached = index.get(str(path))
            info, reason = inspect_transcript(ctx, path,
                header_result=(cached["header"], True) if cached else None, headers_only=include_live)
            if not info:
                skipped[reason] += 1
                continue
            harness, sid, header = info
            if harness == "codex" and not codex_human_root(header):
                skipped["agent-driven"] += 1
                continue
            target = Context(ctx.root, folder_for(ctx, path) if harness == "claude" else ctx.prefix + "--" + harness)
            if target.held(sid, path if harness in ("pi", "prime") else None):
                skipped["held"] += 1
                continue
            old = recorded.get(sid)
            if old and old.get("detail") == "stub":
                skipped["already recorded"] += 1
                continue
            family = family_rows(index, path) if harness == "codex" else []
            modified = max((row["mtime"] for _, row in family), default=path.stat().st_mtime)
            idle = now - modified
            finalizing = bool(old and old.get("status") == "in progress" and idle >= 86400)
            # A Claude record is finished by its own SessionEnd hook. A killed tab
            # never runs it, so the sweep finishes only a record left in progress
            # for a day, the rule the native harnesses already follow.
            if old and harness == "claude" and not finalizing:
                skipped["already recorded"] += 1
                continue
            if idle < 600 and not include_live:
                skipped["live"] += 1
                continue
            through = max((row.get("last_event") if row.get("last_event") is not None else row["mtime"]
                           for _, row in family), default=round(modified, 6))
            known = harness != "codex" or all(row.get("last_event") is not None for _, row in family)
            # Cached watermarks decide unchanged records before any body read.
            if old and known and not finalizing and through <= (event_time(old.get("through")) or 0):
                skipped["already recorded"] += 1
                continue
            start = event_time(header.get("timestamp")) or modified
            if include_live:
                if modified < now - days * 86400 and not finalizing:
                    skipped["outside the window"] += 1
                    continue
                duration = max(0, modified - start)
                result.append((modified, path, {"duration_seconds": duration,
                               "duration": f"{int(duration // 60)}m", "cost": 0, "commits": 0}, 0))
                continue
            enrolled = since is not None and not old
            begun = event_time(header.get("timestamp"))
            if enrolled and begun is not None and begun < since:
                skipped["before enrollment"] += 1
                continue
            if harness != "claude" and through < now - days * 86400 and not finalizing:
                skipped["outside the window"] += 1
                continue
            if harness == "codex":
                through = family_watermark(ctx, index, path)
            if old and not finalizing and through <= (event_time(old.get("through")) or 0):
                skipped["already recorded"] += 1
                continue
            if harness != "claude" and through < now - days * 86400 and not finalizing:
                skipped["outside the window"] += 1
                continue
            if not probe(path, ctx):
                _, readable = st.read_header_result(path)
                skipped["unsupported" if readable else "unreadable header"] += 1
                continue
            facts = st.load_session(path, projects_dir=ctx.projects, prefix=ctx.prefix, root=ctx.root,
                                    codex_index=index if harness == "codex" else None, require_root_prompts=True)
            skip = st.skip_reason(facts)
            if skip:
                skipped[skip] += 1
                continue
            if enrolled:
                starts = [value for value in (begun, facts.get("first")) if value is not None]
                if not starts:
                    skipped["start unknown"] += 1
                    continue
                if min(starts) < since:
                    skipped["before enrollment"] += 1
                    continue
            start = facts.get("first") or path.stat().st_mtime
            activity = through if harness != "claude" else start
            if activity < now - days * 86400 and not finalizing:
                skipped["outside the window"] += 1
                continue
            out = st.outline(facts, repo=ctx.root)
            if not old and out["duration_seconds"] < 120 and out["commits"] == 0:
                skipped["shorter than 2 minutes with no commits"] += 1
                continue
            result.append((through if harness != "claude" else start, path, out, len(facts["prompts"])))
        except Exception as exc:
            skipped["failed"] += 1
            ctx.error("candidate failed: " + str(exc))
    return sorted(result, key=lambda r: (-r[0], str(r[1]))), skipped


def publish_batch(ctx, staged, skipped, failed, sources=None, codex_index=None):
    lock = ctx.memory_lock()
    if not lock.acquire(wait=120):
        raise RuntimeError("memory writer busy; staged records retained")
    paths, dates, published_contexts = [], [], []
    native_blocked = False
    locks = []
    try:
        for target_ctx, path in staged:
            try:
                text = staging_file(target_ctx, target_ctx.base / "backfill-staging", path).read_text()
            except (ValueError, OSError) as exc:
                failed += 1
                target_ctx.error(str(exc))
                continue
            data = metadata(text)
            sid = data["session"]
            old = existing(ctx, sid)
            if data.get("producer") or old and old[1].get("producer"):
                skipped["native producer"] += 1
                native_blocked = True
                continue  # Never claim/drain a native intent as a human session.
            session_lock = target_ctx.lock(sid, "backfill-publish")
            # Never wait while holding the memory lock: a live worker can be
            # waiting for it. Retry that session on the next batch instead.
            if not session_lock.acquire():
                skipped["busy"] += 1
                continue
            locks.append((target_ctx, session_lock))
            old = existing(ctx, sid)
            replace_legacy = old and old[1].get("kind") != "session-record" and owned_record(target_ctx, old[1])
            native = data.get("harness") in ("codex", "pi", "prime")
            source = (sources or {}).get(sid)
            if native and source:
                info = transcript_info(target_ctx, source)
                if not info:
                    skipped["failed"] += 1
                    continue
                if info[0] == "codex":
                    index = codex_index if codex_index is not None else codex_header_index(ctx)
                    family = family_rows(index, source)
                    modified = max((Path(name).stat().st_mtime for name, _ in family), default=source.stat().st_mtime)
                    latest = family_watermark(ctx, index, source)
                else:
                    modified = source.stat().st_mtime
                    latest = round(modified, 6)
                if time.time() - modified < 600 or latest > (event_time(data.get("through")) or 0):
                    skipped["live"] += 1
                    path.unlink(missing_ok=True)
                    continue
            # A Claude record replaced here is one a killed tab left in progress.
            finishing = (data.get("harness") == "claude" and old and old[1].get("status") == "in progress"
                         and data.get("status") == "final")
            newer = (native or finishing) and old and int(data.get("record_revision", 0)) > int(old[1].get("record_revision", 0))
            if not target_ctx.enabled() or target_ctx.held(sid) or (old and not replace_legacy and not newer):
                skipped["held" if target_ctx.held(sid) else "already recorded or disabled"] += 1
                path.unlink(missing_ok=True)
                continue
            target = old[0] if old else ctx.memory / "sessions" / data["date"][:7] / path.name
            if target.exists() and not old:
                target = target.with_name(target.stem + "-" + sid + ".md")
            if target.is_symlink() or not target.resolve().is_relative_to(ctx.memory):
                skipped["invalid destination"] += 1
                continue
            if target.is_file():
                with target.open("rb") as stream:
                    destination = metadata(stream.read(256 * 1024).decode("utf-8", errors="replace"))
                if destination.get("producer"):
                    skipped["native producer"] += 1
                    native_blocked = True
                    continue
                if not old:
                    skipped["occupied destination"] += 1
                    continue
            target.parent.mkdir(parents=True, exist_ok=True)
            os.replace(path, target)
            paths.append(target)
            dates.append(data["date"][:10])
            published_contexts.append((target_ctx, target, data))
        if paths:
            message = f"chore(sessions): record {len(paths)} past sessions ({min(dates)} → {max(dates)})"
            message += f"\n\nBuilt: {len(paths)}\nSkipped: " + ", ".join(f"{k}={v}" for k, v in sorted(skipped.items())) + f"\nFailed: {failed}"
            def before_publish():
                for target_ctx, target, meta in published_contexts:
                    paths.extend(item for item in apply_record_hold(target_ctx, target, meta) if item not in paths)
                    if not target_ctx.held(meta["session"]) and not target_ctx.enabled():
                        return False
                return True
            commit(ctx, paths, message, before_publish=before_publish)
            ctx.set_state("session_records_backfilled_through", max(dates))
        elif not native_blocked:
            push(ctx)
    finally:
        lock.release()
        for target_ctx, session_lock in locks:
            finish_session(target_ctx, session_lock)
    return len(published_contexts), failed


def sweep(ctx, args):
    """Always count in a detached worker; consent gates publication only."""
    ctx = Context(ctx.root)
    if not ctx.safe_base():
        return 0
    lock = ctx.lock("sweep", "sweep")
    stamp = ctx.base / "sweep.stamp"
    if not args.worker:
        if not lock.acquire():
            return 0
        try:
            command = [sys.executable, str(SELF), "record", "--root", str(ctx.root),
                       "--mode", "sweep", "--worker"]
            if args.force:
                command.append("--force")
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
            lock.handover(child.pid)
        finally:
            lock.release()
        return 0
    try:
        until = time.monotonic() + 5
        while lock.owner() != os.getpid():
            if time.monotonic() > until:
                return 0
            time.sleep(0.01)
        discovery_skipped = Counter()
        index = codex_header_index(ctx, skipped=discovery_skipped)
        counted, skipped = candidates(ctx, ctx.policy.get("retroactive_days", 90), include_live=True,
                                     codex_index=index, discovery_skipped=discovery_skipped)
        refresh_index(ctx, codex_index=index, rows=counted)
        if (not ctx.enabled() or not ctx.author or not ctx.memory.is_dir()
                or ctx.state.get("session_records_noticed") is not True):
            return 0
        since = history_since(ctx)
        if not args.force and stamp.exists() and time.time() - stamp.stat().st_mtime < 6 * 3600:
            return 0
        atomic(stamp, str(time.time()))
        rows, skipped = candidates(ctx, ctx.policy.get("retroactive_days", 90),
                                   codex_index=index, discovery_skipped=discovery_skipped, since=since)
        staged, failed, sources = [], skipped.pop("failed", 0), {}
        for _, path, _, _ in rows[:20]:
            ctx.reload()
            if not ctx.enabled() or ctx.state.get("session_records_noticed") is not True:
                break
            info, reason = inspect_transcript(ctx, path)
            if not info:
                skipped[reason] += 1
                continue
            sid = info[1]
            target = Context(ctx.root, folder_for(ctx, path))
            if not target.safe_base():
                skipped["invalid trail folder"] += 1
                continue
            stage = target.base / "backfill-staging"
            arguments = record_parser().parse_args(["--root", str(ctx.root), "--mode", "sweep",
                         "--session-id", sid, "--transcript", str(path), "--staging", str(stage)])
            arguments.codex_index = index
            sources[sid] = path
            session_lock = target.lock(sid, "sweep")
            if not session_lock.acquire():
                skipped["busy"] += 1
                continue
            try:
                staging_directory(target, stage, create=True)
                status = build(target, arguments)
                if status == "built":
                    found = next((p for p, meta, _ in staged_records(target, stage)
                                  if meta.get("session") == sid), None)
                    if found:
                        staged.append((target, found))
                    else:
                        failed += 1
                elif status == "failed":
                    failed += 1
                else:
                    skipped[status] += 1
            except Exception as exc:
                failed += 1
                target.error(str(exc))
            finally:
                finish_session(target, session_lock, arguments)
        index = codex_header_index(ctx)
        if ctx.enabled() and ctx.state.get("session_records_noticed") is True:
            publish_batch(ctx, staged, skipped, failed, sources=sources, codex_index=index)
        refresh_index(ctx, codex_index=index)
    except Exception as exc:
        ctx.error("sweep failed: " + str(exc))
    finally:
        lock.release()
    return 0


def show_native_record(ctx, identifier):
    """Return False for human IDs. Native viewing never discovers transcripts."""
    if not SAFE_ID.fullmatch(identifier):
        raise ValueError("invalid session id")
    candidates = []
    for index, (path, meta, text) in enumerate(all_records(ctx)):
        if index >= 4096:
            raise ValueError("record inventory exceeds the viewing bound")
        if str(meta.get("session", "")).startswith(identifier):
            candidates.append((path, meta, text))
    native = [row for row in candidates if classify_record(row[1]) != "human-session"]
    if not native:
        if identifier.startswith("spirit-"):
            raise ValueError("no spirit record for that id in this instance")
        return False
    if len(candidates) != 1:
        raise ValueError("record prefix is ambiguous")
    path, meta, text = native[0]
    actor_id, reader = native_record_reader(ctx)
    if not reader or meta.get("record_owner_actor_id") != actor_id:
        raise ValueError("that spirit record is not available to this owner")
    access = reader(path, meta)
    if not access:
        raise ValueError("spirit record read is not permitted")
    projection = record_subject(meta, text)
    if access == "held" or projection.get("held"):
        projection = {"subject_kind": "durable-intent", "held": True}
    print(json.dumps(projection, indent=2, ensure_ascii=False))
    return True


def records(ctx, argv):
    action = argv[0] if argv else "status"
    rest = argv[1:]
    if action in ("outcome", "intervention"):
        import record_outcomes
        return record_outcomes.command(sys.modules[__name__], ctx, rest, kind=action)
    if action == "digest":
        return digest(ctx, rest)
    if action == "open":
        return open_items(ctx, rest)
    if action == "close":
        return close_item(ctx, rest)
    if action in ("reactivate", "stale"):
        return relevance_item(ctx, rest, "active" if action == "reactivate" else "stale")
    if action == "file":
        return file_item(ctx, rest)
    if action in ("on", "off", "noticed"):
        ctx.set_state("session_records_noticed" if action == "noticed" else "session_records_enabled", action != "off")
        if action == "noticed":
            enroll(ctx)
        print("Session records: " + action)
    elif action == "detail":
        if not rest or rest[0] not in ("outline", "full"):
            raise ValueError("usage: records.sh detail outline|full")
        ctx.set_state("session_records_detail", rest[0])
        print("Session record detail: " + rest[0])
    elif action == "hold":
        sid = harness_session_id()
        if not sid:
            print("Session could not be identified; no hold was written.")
            return 1
        hold(ctx, sid, exact=True)
    elif action == "redact":
        if not rest:
            raise ValueError("usage: records.sh redact <id-or-prefix>")
        hold(ctx, rest[0])
    elif action == "show":
        if not rest:
            raise ValueError("usage: records.sh show <id-or-prefix>")
        if show_native_record(ctx, rest[0]):
            return 0
        target, sid, path = resolve_context(ctx, rest[0])
        if not target.safe_base():
            raise ValueError("personal trail folder is outside this instance")
        trail_path = target.base / (sid + ".md")
        if path and not transcript_info(ctx, path):
            raise ValueError("no transcript for that session in this instance")
        if not trail_path.resolve().is_relative_to(target.base.resolve()):
            raise ValueError("personal trail is outside this instance")
        if not trail_path.exists():
            if not path:
                raise ValueError("no transcript for that session in this instance")
            if not probe(path, ctx):
                raise ValueError("session transcript could not be read")
            private_dir(target.base)
            atomic(trail_path, st.render_trail(st.load_session(path, projects_dir=ctx.projects, prefix=ctx.prefix, root=ctx.root,
                                                            codex_index=codex_header_index(ctx))))
        print(trail_path.read_text(), end="")
    elif action == "status":
        if "--push" in rest:
            lock = ctx.memory_lock()
            if lock.acquire(wait=120):
                try:
                    push(ctx)
                finally:
                    lock.release()
        index = refresh_index(ctx)
        print("org policy: " + ("on" if ctx.policy.get("enabled") is True else "off"))
        own = ctx.state.get("session_records_enabled", "inherit")
        print("yours: " + ("inherit" if own == "inherit" else "on" if own else "off"))
        print("detail: " + str(ctx.state.get("session_records_detail", ctx.policy.get("default_detail", "outline"))))
        print("hold stub: " + str(ctx.state.get("session_records_hold_stub", True)).lower())
        print("backfilled through: " + str(ctx.state.get("session_records_backfilled_through", "never")))
        print(f"{index['unrecorded_count']} unrecorded sessions on this machine")
        if index["waiting_push"]:
            print(f"{index['waiting_push']} commit waiting to push")
    elif action == "sweep":
        args = record_parser().parse_args(["--root", str(ctx.root), "--mode", "sweep", *rest])
        return sweep(ctx, args)
    elif action == "backfill":
        parser = argparse.ArgumentParser(prog="records.sh backfill")
        parser.add_argument("--days", type=int, default=ctx.policy.get("retroactive_days", 90))
        parser.add_argument("--dry-run", action="store_true")
        parser.add_argument("--yes", action="store_true")
        args = parser.parse_args(rest)
        discovery_skipped = Counter()
        index = codex_header_index(ctx, skipped=discovery_skipped)
        rows, skipped = candidates(ctx, args.days, codex_index=index, discovery_skipped=discovery_skipped)
        calls = len(rows) if rows and ctx.enabled() and ctx.model_enabled() and cli_flags(ctx)[0] is not None else 0
        print("date        session       prompts  duration  cost")
        for start, path, out, prompts in rows:
            print(f"{datetime.fromtimestamp(start, timezone.utc):%Y-%m-%d}  {path.stem[:12]:12}  {prompts:7}  {out['duration']:8}  ${out['cost']:.2f}")
        print(f"{calls} model calls")
        for reason in ("held", "shorter than 2 minutes with no commits", "already recorded", "outside the window", "live",
                       "agent-driven", "no prompts", "unreadable header", "other project", "unsupported"):
            print(f"skipped {reason}: {skipped[reason]}")
        if not args.yes or args.dry_run:
            print(f"failed: {skipped['failed']}")
            refresh_index(ctx)
            return 0
        # The one acceptance of past sessions; the sweep reads it, never infers it.
        ctx.set_state("session_records_backfill_accepted_at", datetime.now(timezone.utc).isoformat())
        ctx.set_state("session_records_backfill", "accepted")
        staged, failed, sources = [], skipped.pop("failed", 0), {}
        for _, path, _, _ in rows:
            target = Context(ctx.root, folder_for(ctx, path))
            if not target.safe_base():
                skipped["invalid trail folder"] += 1
                continue
            sid = transcript_info(target, path)[1]
            stage = target.base / "backfill-staging"
            arguments = record_parser().parse_args(["--root", str(ctx.root), "--mode", "backfill", "--transcript", str(path), "--session-id", sid, "--staging", str(stage)])
            arguments.codex_index = index
            sources[sid] = path
            lock = target.lock(sid, "backfill")
            if not lock.acquire():
                skipped["busy"] += 1
                continue
            try:
                if time.time() - path.stat().st_mtime < 600:
                    skipped["live"] += 1
                    continue
                staging_directory(target, stage, create=True)
                status = build(target, arguments)
                if status == "built":
                    found = next((p for p, meta, _ in staged_records(target, stage) if meta.get("session") == sid), None)
                    if found:
                        staged.append((target, found))
                    else:
                        failed += 1
                elif status == "failed":
                    failed += 1
                elif status == "live":
                    skipped["live"] += 1
                else:
                    skipped["held or disabled"] += 1
            except Exception as exc:
                failed += 1
                target.error(str(exc))
            finally:
                finish_session(target, lock, arguments)
        index = codex_header_index(ctx)
        built, failed = publish_batch(ctx, staged, skipped, failed, sources=sources, codex_index=index)
        refresh_index(ctx, codex_index=index)
        print(f"skipped live: {skipped['live']}")
        print(f"built: {built}; skipped: {sum(skipped.values())}; failed: {failed}")
    else:
        raise ValueError("usage: records.sh status|on|off|detail|hold|redact|noticed|backfill|sweep|show|digest|open|close|stale|reactivate|file|outcome|intervention")
    return 0


def record_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--project-root")
    parser.add_argument("--mode", choices=("end", "checkpoint", "backfill", "redact", "sweep"), required=True)
    parser.add_argument("--debounce", type=float, default=0)
    parser.add_argument("--transcript")
    parser.add_argument("--session-id")
    parser.add_argument("--author")
    parser.add_argument("--display-name")
    parser.add_argument("--detail", choices=("outline", "full"))
    parser.add_argument("--staging")
    parser.add_argument("--folder")
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--notice-fd", type=int)
    return parser


def main():
    if sys.argv[1] == "probe":
        return 0 if st.probe_format(Path(sys.argv[2])) is not None else 1
    if sys.argv[1] == "record":
        args = record_parser().parse_args(sys.argv[2:])
        try:
            return record(args)
        except Exception as exc:
            if args.worker or args.mode == "redact":
                Context(args.project_root or args.root, args.folder).error(str(exc))
            return 1 if args.mode == "redact" else 0
    if sys.argv[1] == "capture":
        parser = argparse.ArgumentParser()
        parser.add_argument("--root", required=True)
        parser.add_argument("--folder")
        parser.add_argument("--data")
        for field in ("author", "topic", "summary", "session-id", "branch", "date", "duration"):
            parser.add_argument("--" + field)
        parser.add_argument("--staging")
        args = parser.parse_args(sys.argv[2:])
        ctx = Context(args.root, args.folder)
        if args.data:
            data = json.loads(args.data)
        else:
            if not args.author or not args.session_id or not SAFE_ID.fullmatch(args.session_id):
                raise ValueError("--replace-session requires author and session id")
            old = existing(ctx, args.session_id)
            data = dict(author=args.author, session=args.session_id, topic=args.topic or "session",
                        summary=args.summary or args.topic or "session", branch=args.branch or "session",
                        date=args.date or datetime.now(timezone.utc).isoformat(), duration=args.duration or "unknown",
                        status="final", detail="outline-deterministic", mode="end", cost_usd=0, cost_source="estimate",
                        record_revision=int(old[1].get("record_revision", 0)) + 1 if old else 1)
        data["body"] = sys.stdin.read()
        result = capture(ctx, data, args.staging)
        if result:
            print(result)
        return 0
    if sys.argv[1] == "gate-event":
        # The merge gate's ledger line (bin/merge-gate.sh). A refusal is one
        # line on stderr, the reason the gate prints.
        try:
            return gate_event(sys.argv[2:])
        except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
            print(str(exc), file=sys.stderr)
            return 1
    if sys.argv[1] == "open-items-line":
        # The reflex probe (bin/reflexes/10-open-items.sh), silent while the
        # organization has session records off.
        parser = argparse.ArgumentParser(prog="session_record.py open-items-line")
        parser.add_argument("--root", required=True)
        parser.add_argument("--memory")
        args = parser.parse_args(sys.argv[2:])
        root = Path(args.root)
        features = read_json(root / "egregore.json").get("features")
        policy = features.get("session_records") if isinstance(features, dict) else None
        if not isinstance(policy, dict) or policy.get("enabled") is not True:
            return 0
        line = open_items_line(Path(args.memory) if args.memory else root / "memory",
                               identities=Context(root).identities())
        if line:
            print(line)
        return 0
    if sys.argv[1] in ("vitals", "vitals-line"):
        # vitals prints both lines, or --json for the audit page and the Mind;
        # vitals-line is the reflex probe (bin/reflexes/05-vitals.sh), silent
        # while the organization has session records off.
        reflex = sys.argv[1] == "vitals-line"
        parser = argparse.ArgumentParser(prog="session_record.py " + sys.argv[1])
        parser.add_argument("--root", required=True)
        parser.add_argument("--memory")
        parser.add_argument("--days", type=int, default=VITALS_DAYS)
        parser.add_argument("--today", type=date.fromisoformat, help="YYYY-MM-DD; the local date by default")
        if not reflex:
            parser.add_argument("--json", action="store_true")
            parser.add_argument("--findings", action="store_true", help="show evidence, next actions and verification")
        args = parser.parse_args(sys.argv[2:])
        if not 1 <= args.days <= VITALS_MAX_DAYS:
            parser.error(f"--days takes 1 to {VITALS_MAX_DAYS}")
        root = Path(args.root)
        features = read_json(root / "egregore.json").get("features")
        policy = features.get("session_records") if isinstance(features, dict) else None
        enabled = (isinstance(policy, dict) and policy.get("enabled") is True
                   and read_json(root / ".egregore-state.json").get("session_records_enabled", True) is True)
        if not enabled:
            if not reflex:
                print(json.dumps({"status": "disabled", "reason": "session-records-off", "findings": []})
                      if args.json else "Scorecard unavailable while session recording is off.")
            return 0
        data = vitals(Path(args.memory) if args.memory else root / "memory", days=args.days, today=args.today)
        if not reflex and (args.json or args.findings):
            import record_outcomes
            details = record_outcomes.scorecard(sys.modules[__name__],
                                               Path(args.memory) if args.memory else root / "memory",
                                               ctx=Context(root))
            data["unit_economics"] = details.pop("unit_economics")
            findings = details.pop("findings")
            data["outcome_scorecard"] = details
            data["findings"] = [row for row in data["findings"] if row["code"] != "accepted_outcome_link_missing"] + findings
        text = (vitals_line(data, quiet=True) if reflex else json.dumps(data) if args.json else
                vitals_findings_text(data) if args.findings else vitals_line(data, quiet=False))
        if text:
            print(text)
        return 0
    if sys.argv[1] in ("records", "digest"):
        parser = argparse.ArgumentParser(add_help=False)
        parser.add_argument("--root", required=True)
        args, remaining = parser.parse_known_args(sys.argv[2:])
        try:
            return records(Context(args.root), (["digest"] if sys.argv[1] == "digest" else []) + remaining)
        except (ValueError, RuntimeError, OSError) as exc:
            print(str(exc))
            return 0 if sys.argv[1] == "digest" or remaining[:1] == ["digest"] else 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
