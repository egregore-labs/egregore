"""Record what people like in generated interfaces and read it back as words.

Only deliberate human acts are recorded: liked, disliked, chose (one interface
over another), adopted (make this my default) and retracted. Nothing is
inferred from what a page happened to use, and nothing is scored: the summary
is plain counts plus the person's own words, dated.

Events carry words only. A target is never opened, so no page source or client
text enters memory. A registry id, hosted URL or claude.ai artifact link is
stored as given; a local file is stored relative to the repository when it is
inside it and by its file name otherwise, so shared memory never holds a home
directory or the folders around it. Each event is one immutable JSON file,
``memory/taste/<month>/<actor folder>/<time>-<kind>-<event id>.json``, created
once through the Runtime writeback: a new file cannot be replaced by a rebase,
and two machines never write the same path. The name carries the kind and id,
so finding an event, retracting it and resolving defaults read every file by
name; only the reactions ``taste`` shows are bounded. Search indexes Markdown
only, so taste adds no search hits.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
from typing import Any, Callable, Iterable, Mapping
from urllib.parse import unquote, urlsplit
import uuid

from .taste_rules import EGREGORE_RULES
from .artifacts import ArtifactConflictError
from .contracts import ActorContext, CanonicalFilesWritebackEvent, Permission, PolicyDecision, WritebackStatus
from .errors import AuthorizationDenied
from .policy import allows, action_for


TASTE_SCHEMA = "egregore.taste/v1"
SUMMARY_SCHEMA = "egregore.taste-summary/v1"
EVENT_KINDS = frozenset({"liked", "disliked", "chose", "adopted", "retracted"})
ADOPT_KINDS = ("palette", "pattern", "principle")
ADOPT_SCOPES = ("person", "org")
WHOLE_THING = "the whole thing"
READING_NOTE = "Words to consider, never a template to copy."

MAX_WORDS = 1000
MAX_TARGET = 2048
MAX_FIELD = 200
MAX_ABOUT = 8
MAX_ABOUT_CHARS = 60
TOP_PATTERNS = 12
# Palettes and patterns are defaults (the latest wins); principles are rules
# that accumulate until someone retracts one.
DEFAULT_KINDS = ("palette", "pattern")
HOUSE_RULES = 24
# A pattern the organization named on this many different pages is part of
# its emergent taste.
EMERGENT_PAGES = 2
LAYER_NOTE = (
    "Read in this order; a later layer wins where they conflict, and the must-pass "
    "checks (contrast, accessibility, colours from tokens) always hold."
)
LAST_QUOTES = 8
LAST_CHOICES = 8
QUOTE_CHARS = 240
MAX_EVENT_FILES = 10000  # reactions ``taste`` shows; lifecycle and shared ids read every file
MAX_EVENT_BYTES = 64 * 1024
LIFECYCLE_KINDS = frozenset({"adopted", "retracted"})
TEXT_FIELDS = ("words", "region", "task", "audience", "form", "scope", "runtime")
_EVENT_NAME = re.compile(
    r"(?P<time>\d{8}T\d{6}Z)-(?P<kind>liked|disliked|chose|adopted|retracted)-"
    r"(?P<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.json"
)

_RUNTIMES = {"claude": "claude", "claude-code": "claude", "codex": "codex", "pi": "pi"}
_COMMIT_MESSAGES = {
    "liked": "docs(taste): record a liked interface",
    "disliked": "docs(taste): record a disliked interface",
    "chose": "docs(taste): record an interface choice",
    "adopted": "docs(taste): record an adopted default",
    "retracted": "docs(taste): retract a taste event",
}


class TasteError(ValueError):
    """A taste event or query is invalid."""


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(value).casefold()).strip("-")


def _iso(moment: datetime) -> str:
    return moment.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def actor_folder(actor_id: str) -> str:
    """The folder holding one actor's events, named from the Runtime actor id.

    An id the Runtime issues (lowercase letters, digits and '_') is used as it
    is. Any other id becomes a slug plus a digest of the exact id, so ids that
    slug alike ("Renç", "Ren") never share a folder, even on a disk that
    ignores case; the '-' keeps the two forms apart.
    """

    if re.fullmatch(r"[a-z0-9_]{1,64}", actor_id):
        return actor_id
    digest = hashlib.sha256(actor_id.encode("utf-8")).hexdigest()[:16]
    return f"{_slug(actor_id)[:40] or 'actor'}-{digest}"


def _serialize(event: Mapping[str, Any]) -> str:
    return json.dumps(event, ensure_ascii=False, sort_keys=True, indent=2) + "\n"


def _reaction(event: Mapping[str, Any]) -> dict[str, Any]:
    """What a retry must repeat: the event without when, where and by whom."""

    return {key: value for key, value in event.items() if key not in {"ts", "actor", "runtime"}}


def runtime_name(harness: str, environ: Mapping[str, str] | None = None) -> str:
    """Name the runtime that recorded an event: claude, codex, pi or unknown."""

    known = _RUNTIMES.get(str(harness or "").strip().casefold())
    if known:
        return known
    environment = os.environ if environ is None else environ
    if environment.get("CLAUDECODE") == "1":
        return "claude"
    if environment.get("CODEX_THREAD_ID"):
        return "codex"
    return "unknown"


def target_kind(ref: str) -> str:
    """Classify a target as given, without opening it."""

    if ref.casefold().startswith(("http://", "https://")):
        parts = urlsplit(ref)
        host = (parts.hostname or "").casefold()
        if (host == "claude.ai" or host.endswith(".claude.ai")) and "/artifact" in parts.path:
            return "claude-artifact"
        return "url"
    if "/" in ref or "\\" in ref or ref.startswith((".", "~")) or re.search(r"\.[A-Za-z0-9]{1,5}$", ref):
        return "path"
    return "registry"


def clean_target(ref: str | None, *, label: str = "target") -> str:
    value = (ref or "").strip()
    if not value:
        raise TasteError(
            f"{label} is required: a registry id, hosted URL, local path or claude.ai artifact link"
        )
    # A target names the interface. Markup, line breaks or a very long value
    # mean page contents were passed instead, and those never enter memory.
    if len(value) > MAX_TARGET or any(mark in value for mark in ("\n", "\r", "<", ">")):
        raise TasteError(f"{label} must name the interface (id, URL or path), not carry its contents")
    return value


def shareable_path(ref: str, *, repository_root: Path, cwd: Path) -> str:
    """A local file as shared memory may hold it: relative to the repository
    when inside it, otherwise its file name alone. A full path would carry an
    OS user name and the client folders around the file."""

    value = ref
    if value.casefold().startswith("file:"):
        value = unquote(urlsplit(value).path) or value
    windows = PureWindowsPath(value)
    if os.sep == "/" and ("\\" in value or windows.drive):
        if windows.drive or windows.root:
            # C:\x, C:x, \x and \\host\share\x never name a file in this checkout.
            return windows.name or "file"
        value = windows.as_posix()  # ..\x is ../x, contained like any relative path
    path = Path(os.path.expanduser(value))
    if not path.is_absolute():
        path = cwd / path
    resolved = path.resolve()
    if resolved.is_relative_to(repository_root):
        return resolved.relative_to(repository_root).as_posix() or "."
    return Path(os.path.normpath(path)).name or "file"


def clean_words(words: str | None, *, required: bool) -> str | None:
    if words is None or not words.strip():
        if required:
            raise TasteError("--words is required: what the person said, verbatim")
        return None
    if len(words) > MAX_WORDS:
        raise TasteError(f"--words holds what the person said, up to {MAX_WORDS} characters")
    return words.strip()


def clean_about(values: Iterable[str] | None) -> list[str]:
    phrases: list[str] = []
    for raw in values or ():
        phrase = " ".join(str(raw).split()).casefold()
        if not phrase:
            continue
        if len(phrase) > MAX_ABOUT_CHARS:
            raise TasteError(f"--about takes short phrases of {MAX_ABOUT_CHARS} characters or fewer")
        if phrase not in phrases:
            phrases.append(phrase)
    if len(phrases) > MAX_ABOUT:
        raise TasteError(f"name at most {MAX_ABOUT} patterns with --about")
    return phrases


def clean_field(value: str | None, name: str, *, label: str | None = None) -> str | None:
    """A short plain description on one line. ``>`` is allowed (a CSS child
    selector, "clarity > decoration"); ``<`` is not, since markup starts there."""

    if value is None:
        return None
    text = " ".join(value.split())
    if not text:
        return None
    field = label or f"--{name}"
    if "<" in text:
        raise TasteError(f"{field} cannot contain '<': describe the part in words, without markup")
    if len(text) > MAX_FIELD:
        raise TasteError(f"{field} is {len(text)} characters; keep it to {MAX_FIELD} or fewer")
    return text


def _optional_text(value: Any) -> bool:
    return value is None or isinstance(value, str)


def _reference(value: Any) -> bool:
    return isinstance(value, dict) and isinstance(value.get("ref"), str) and _optional_text(value.get("ref_kind"))


def valid_event(value: Any) -> bool:
    """One taste event whose every field the reader uses has the type it
    expects: JSON that parses but carries a list where a word belongs is
    skipped like a torn file, never left to break a read."""

    if not (isinstance(value, dict) and value.get("schema") == TASTE_SCHEMA):
        return False
    actor, about = value.get("actor"), value.get("about")
    if not (
        isinstance(value.get("id"), str)
        and isinstance(value.get("kind"), str)
        and value["kind"] in EVENT_KINDS
        and isinstance(actor, dict)
        and isinstance(actor.get("id"), str)
        and _optional_text(actor.get("name"))
        and _reference(value.get("target"))
        and (value.get("over") is None or _reference(value["over"]))
        and (about is None or (isinstance(about, list) and all(isinstance(phrase, str) for phrase in about)))
        and all(_optional_text(value.get(field)) for field in TEXT_FIELDS)
        and isinstance(value.get("ts"), str)
    ):
        return False
    try:
        _parse_ts(value["ts"])
    except (ValueError, OverflowError, OSError):
        return False
    return True


@dataclass(frozen=True, slots=True)
class EventFile:
    """An event file as its name describes it; nothing has been read yet."""

    path: Path
    relative: str
    time: str
    kind: str
    id: str


@dataclass(frozen=True, slots=True)
class TasteReceipt:
    event: Mapping[str, Any]
    duplicate: bool
    writeback: CanonicalFilesWritebackEvent

    @property
    def recorded(self) -> bool:
        """The event is committed to canonical memory on this machine."""
        return (
            self.writeback.status is not WritebackStatus.REJECTED
            and self.writeback.git_revision is not None
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "event": dict(self.event),
            "duplicate": self.duplicate,
            "writeback": self.writeback.to_dict(),
        }


class TasteService:
    """Record taste events through the Runtime and read them back as words."""

    def __init__(
        self,
        runtime,
        *,
        clock: Callable[[], datetime] | None = None,
        id_factory: Callable[[], str] | None = None,
        environ: Mapping[str, str] | None = None,
        warn: Callable[[str], None] | None = None,
    ) -> None:
        if runtime.canonical_root is None:
            raise RuntimeError("taste needs canonical memory")
        self.runtime = runtime
        self.memory_root = Path(runtime.canonical_root).resolve()
        # Local file targets are stored relative to this checkout.
        instance = getattr(runtime, "instance_root", None)
        self.repository_root = Path(instance or Path(runtime.canonical_root).parent).resolve()
        self.clock = clock or (lambda: datetime.now(UTC))
        self.id_factory = id_factory or (lambda: str(uuid.uuid4()))
        self.environ = environ
        self.warn = warn or (lambda _line: None)

    # --- paths and authorization ------------------------------------------

    @staticmethod
    def event_path(actor: ActorContext, event: Mapping[str, Any]) -> str:
        """One file per event, e.g. ``taste/2026-09/actor_ada/20260924T100000Z-liked-<id>.json``."""

        moment = _parse_ts(event["ts"])
        return (
            f"taste/{moment:%Y-%m}/{actor_folder(actor.actor.actor_id)}/"
            f"{moment:%Y%m%dT%H%M%SZ}-{event['kind']}-{event['id']}.json"
        )

    def _require(self, actor: ActorContext, permission: Permission, resource: str, path: str) -> PolicyDecision:
        decision = self.runtime.authorize(actor, permission, (resource,))
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons) or f"taste {permission.value} denied")
        if not allows(decision, path, action_for(decision.permission), root=self.memory_root):
            raise AuthorizationDenied("taste path is outside the actor's authorized scope")
        return decision

    def files(self, actor: ActorContext, name: str = "*.json") -> list[EventFile]:
        """Event files whose names match the glob ``name``, oldest first,
        described by their names alone: no file is opened."""

        decision = self._require(actor, Permission.READ, "taste", "memory/taste")
        root = self.memory_root / "taste"
        found: list[EventFile] = []
        for path in sorted(root.glob(f"*/*/{name}")) if root.is_dir() else ():
            relative = path.relative_to(self.memory_root).as_posix()
            if not allows(decision, f"memory/{relative}", "read", root=self.memory_root):
                continue  # each event file passes the predicate, not only its folder
            match = _EVENT_NAME.fullmatch(path.name)
            if match is None:
                self.warn(f"skipped memory/{relative}: not one taste event")
                continue
            found.append(EventFile(path, relative, *match.group("time", "kind", "id")))
        return sorted(found, key=lambda file: (file.time, file.relative))

    def read(self, files: Iterable[EventFile]) -> list[tuple[str, dict[str, Any]]]:
        """The events in ``files``, one per id, each with the file it came from.

        A file is skipped with one warning line when it does not hold one
        valid event of the kind and id its name gives. Copies of one reaction
        under an id (a retry, or the same event from two machines) count once
        silently; different reactions under one id keep the earliest, with a
        warning naming both files.
        """

        rows: list[tuple[str, dict[str, Any]]] = []
        for file in files:
            # Read a file only at its own path: a symbolic link to it or to a
            # directory above it would read files outside memory/taste.
            if file.path.resolve() != file.path or not file.path.is_file():
                continue
            try:
                if file.path.stat().st_size > MAX_EVENT_BYTES:
                    raise ValueError("too large")
                value = json.loads(file.path.read_text(encoding="utf-8"))
            except (OSError, ValueError, RecursionError):
                value = None
            if valid_event(value) and (value["kind"], value["id"]) == (file.kind, file.id):
                rows.append((file.relative, value))
            else:
                self.warn(f"skipped memory/{file.relative}: not one taste event")
        kept: dict[str, tuple[str, dict[str, Any]]] = {}
        for source, event in sorted(rows, key=lambda row: (row[1]["ts"], row[0])):
            first_source, first = kept.setdefault(event["id"], (source, event))
            if first_source != source and (
                first["actor"]["id"] != event["actor"]["id"] or _reaction(first) != _reaction(event)
            ):
                self.warn(
                    f"memory/{first_source} and memory/{source} hold different reactions under "
                    f"event {event['id']}; counting memory/{first_source}"
                )
        return list(kept.values())

    def events(self, actor: ActorContext) -> list[tuple[str, dict[str, Any]]]:
        """The events ``taste`` reads back: every adopted default and every
        retraction, and the latest ``MAX_EVENT_FILES`` reactions. Every id
        more than one file names is resolved first, reading each copy, so the
        bound decides only which words are shown, never which copy counts."""

        copies: dict[str, list[EventFile]] = {}
        for file in self.files(actor):
            copies.setdefault(file.id, []).append(file)
        shared = [file for files in copies.values() if len(files) > 1 for file in files]
        named = {file.relative: file for file in shared}
        # One entry per event: the file that counts, and its event once read.
        entries: list[tuple[EventFile, dict[str, Any] | None]] = [
            (named[source], event) for source, event in self.read(shared)
        ] + [(files[0], None) for files in copies.values() if len(files) == 1]
        reactions = sorted(
            (file for file, _ in entries if file.kind not in LIFECYCLE_KINDS),
            key=lambda file: (file.time, file.relative),
        )
        if len(reactions) > MAX_EVENT_FILES:
            self.warn(f"read the latest {MAX_EVENT_FILES} of {len(reactions)} reaction files")
            hidden = set(reactions[:-MAX_EVENT_FILES])
            entries = [(file, event) for file, event in entries if file not in hidden]
        rows = [(file.relative, event) for file, event in entries if event is not None]
        rows += self.read([file for file, event in entries if event is None])
        return sorted(rows, key=lambda row: (row[1]["ts"], row[0]))

    def event(self, actor: ActorContext, event_id: str) -> tuple[str, dict[str, Any]] | None:
        """The event with this id, found by file name among every file."""

        try:
            name = f"*-{uuid.UUID(event_id)}.json"
        except ValueError:
            return None
        rows = self.read(self.files(actor, name))
        return rows[0] if rows else None

    # --- recording ---------------------------------------------------------

    def _event(self, actor: ActorContext, kind: str, event_id: str | None) -> dict[str, Any]:
        identifier = (event_id or "").strip() or self.id_factory()
        try:
            identifier = str(uuid.UUID(identifier))  # one spelling, as file names carry it
        except ValueError as exc:
            raise TasteError("event id must be a UUID") from exc
        return {
            "schema": TASTE_SCHEMA,
            "id": identifier,
            "ts": _iso(self.clock()),
            "actor": {"id": actor.actor.actor_id, "name": actor.actor.display_name},
            "kind": kind,
            "runtime": runtime_name(actor.harness, self.environ),
        }

    def _target(self, ref: str) -> dict[str, str]:
        kind = target_kind(ref)
        if kind == "path":
            ref = shareable_path(ref, repository_root=self.repository_root, cwd=Path.cwd())
        return {"ref": ref, "ref_kind": kind}

    @staticmethod
    def _context(event: dict[str, Any], **fields: str | None) -> None:
        for name, value in fields.items():
            text = clean_field(value, name)
            if text is not None:
                event[name] = text

    def _record(self, actor: ActorContext, event: dict[str, Any], *, caller_id: bool) -> TasteReceipt:
        path = self.event_path(actor, event)
        self._require(actor, Permission.WRITE, f"taste:{actor.actor.actor_id}", f"memory/{path}")
        if caller_id:
            # A retry reuses the id its first attempt printed. That attempt may
            # have written its file without committing it, possibly in an
            # earlier month, so the retry commits the file holding the id: the
            # event counts once. A different reaction under that id is refused.
            found = self.event(actor, event["id"])
            if found is not None:
                source, stored = found
                if stored["actor"]["id"] != actor.actor.actor_id:
                    raise TasteError("that event id belongs to someone else's event")
                if _reaction(stored) != _reaction(event):
                    raise ArtifactConflictError(
                        f"event {event['id']} is already recorded as a different reaction "
                        f"(memory/{source}); record this one without --id"
                    )
                self._require(actor, Permission.WRITE, f"taste:{actor.actor.actor_id}", f"memory/{source}")
                return TasteReceipt(stored, True, self._create(actor, source, stored))
        return TasteReceipt(event, False, self._create(actor, path, event))

    def _create(self, actor: ActorContext, path: str, event: Mapping[str, Any]) -> CanonicalFilesWritebackEvent:
        # The Runtime's own writeback, as every canonical write takes it.
        return self.runtime._writeback(actor).create_file(
            actor, f"memory/{path}", _serialize(event),
            memory_root=self.memory_root, message=_COMMIT_MESSAGES[event["kind"]],
        )

    def react(
        self,
        actor: ActorContext,
        kind: str,
        target: str,
        *,
        words: str | None,
        about: Iterable[str] = (),
        region: str | None = None,
        task: str | None = None,
        audience: str | None = None,
        form: str | None = None,
        event_id: str | None = None,
    ) -> TasteReceipt:
        if kind not in {"liked", "disliked"}:
            raise TasteError("a reaction is liked or disliked")
        ref = clean_target(target)
        event = self._event(actor, kind, event_id)
        event["target"] = self._target(ref)
        event["words"] = clean_words(words, required=True)
        event["about"] = clean_about(about)
        self._context(event, region=region, task=task, audience=audience, form=form)
        return self._record(actor, event, caller_id=bool(event_id))

    def choose(
        self,
        actor: ActorContext,
        winner: str,
        loser: str,
        *,
        words: str | None = None,
        about: Iterable[str] = (),
        task: str | None = None,
        audience: str | None = None,
        form: str | None = None,
        event_id: str | None = None,
    ) -> TasteReceipt:
        chosen = clean_target(winner, label="chosen interface")
        other = clean_target(loser, label="--over")
        if chosen == other:
            raise TasteError("a choice needs two different interfaces")
        event = self._event(actor, "chose", event_id)
        event["target"] = self._target(chosen)
        event["over"] = self._target(other)
        text = clean_words(words, required=False)
        if text is not None:
            event["words"] = text
        event["about"] = clean_about(about)
        self._context(event, task=task, audience=audience, form=form)
        return self._record(actor, event, caller_id=bool(event_id))

    def adopt(
        self,
        actor: ActorContext,
        adopt_kind: str,
        value: str,
        *,
        scope: str = "person",
        words: str | None = None,
        event_id: str | None = None,
    ) -> TasteReceipt:
        if adopt_kind not in ADOPT_KINDS:
            raise TasteError("adopt a palette, pattern or principle")
        if scope not in ADOPT_SCOPES:
            raise TasteError("--scope is person or org")
        chosen = clean_field(value, adopt_kind, label=f"the {adopt_kind}")
        if chosen is None:
            raise TasteError(f"name the {adopt_kind} to adopt")
        event = self._event(actor, "adopted", event_id)
        event["target"] = {"ref": chosen, "ref_kind": adopt_kind}
        event["scope"] = scope
        text = clean_words(words, required=False)
        if text is not None:
            event["words"] = text
        return self._record(actor, event, caller_id=bool(event_id))

    def retract(
        self,
        actor: ActorContext,
        target_id: str,
        *,
        words: str | None = None,
        event_id: str | None = None,
    ) -> TasteReceipt:
        found = self.event(actor, (target_id or "").strip())
        if found is None:
            raise TasteError("no taste event has that id")
        original = found[1]
        wanted = original["id"]
        if original["actor"]["id"] != actor.actor.actor_id:
            raise TasteError("only the person who recorded an event can retract it")
        if original["kind"] == "retracted":
            raise TasteError("a retraction cannot be retracted; record the reaction again")
        event = self._event(actor, "retracted", event_id)
        # A retraction counts as its id resolves across every file sharing
        # it: a later file reusing an earlier event's id retracts nothing.
        files = self.files(actor)
        retractions = {file.id for file in files if file.kind == "retracted"}
        if any(
            row["kind"] == "retracted"
            and row["target"].get("ref") == wanted
            and row["actor"]["id"] == actor.actor.actor_id
            and row["id"] != event["id"]
            for _, row in self.read([file for file in files if file.id in retractions])
        ):
            raise TasteError("that event is already retracted")
        event["target"] = {"ref": wanted, "ref_kind": "event"}
        text = clean_words(words, required=False)
        if text is not None:
            event["words"] = text
        return self._record(actor, event, caller_id=bool(event_id))

    # --- reading back ------------------------------------------------------

    def summary(
        self,
        actor: ActorContext,
        *,
        person: str | None = None,
        task: str | None = None,
        form: str | None = None,
    ) -> dict[str, Any]:
        return summarize(
            [row for _, row in self.events(actor)], viewer=actor, person=person, task=task, form=form,
        )


def _date(event: Mapping[str, Any]) -> str:
    return str(event["ts"])[:10]


def _quote(words: Any) -> str | None:
    if not isinstance(words, str) or not words.strip():
        return None
    text = " ".join(words.split())
    return text if len(text) <= QUOTE_CHARS else text[: QUOTE_CHARS - 1].rstrip() + "…"


def _words_of(value: Any) -> set[str]:
    return {word for word in re.findall(r"[a-z0-9]+", str(value or "").casefold()) if len(word) >= 4}


def _near(query: str | None, value: Any) -> bool:
    if not query or not value:
        return False
    left, right = query.casefold().strip(), str(value).casefold().strip()
    return bool(left and right and (left in right or right in left or _words_of(left) & _words_of(right)))


def _resolve_person(
    events: list[Mapping[str, Any]], viewer: ActorContext, person: str | None
) -> tuple[str | None, str]:
    query = (person or "").strip()
    if query.casefold() in {"", "me", "myself"}:
        return viewer.actor.actor_id, viewer.actor.display_name
    wanted = query.casefold()
    viewer_names = {
        viewer.actor.actor_id.casefold(),
        viewer.actor.display_name.casefold(),
        *(str(value).casefold() for value in viewer.actor.aliases.values()),
    }
    if wanted in viewer_names:
        return viewer.actor.actor_id, viewer.actor.display_name
    names: dict[str, str] = {}
    for event in sorted(events, key=lambda row: row["ts"]):
        actor_id = event["actor"]["id"]
        name = str(event["actor"].get("name") or "")
        if wanted in {actor_id.casefold(), name.casefold()} or _slug(query) == _slug(name):
            names[actor_id] = name or actor_id
    if len(names) > 1:
        raise TasteError(f"more than one person matches {query!r}; pass their actor id")
    if names:
        actor_id, name = next(iter(names.items()))
        return actor_id, name
    return None, query


def _adopted_entry(event: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "value": event["target"].get("ref"),
        "date": _date(event),
        "by": event["actor"].get("name") or event["actor"]["id"],
        "words": _quote(event.get("words")),
        "id": event["id"],
    }


def _latest_adopted(events: Iterable[Mapping[str, Any]]) -> dict[str, dict[str, Any]]:
    """One default per kind, the latest; principles accumulate as rules instead."""

    latest: dict[str, dict[str, Any]] = {}
    for event in sorted(events, key=lambda row: row["ts"]):
        latest[str(event["target"].get("ref_kind"))] = _adopted_entry(event)
    return {kind: latest[kind] for kind in DEFAULT_KINDS if kind in latest}


def _principles(events: Iterable[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Every adopted principle is a standing rule, newest first; the same
    wording adopted twice appears once, as its latest adoption."""

    rules: dict[str, dict[str, Any]] = {}
    for event in sorted(events, key=lambda row: row["ts"]):
        if event["target"].get("ref_kind") == "principle":
            rules.pop(_phrase_key(event["target"].get("ref")), None)
            rules[_phrase_key(event["target"].get("ref"))] = _adopted_entry(event)
    return list(reversed(rules.values()))[:HOUSE_RULES]


def _phrase_key(value: Any) -> str:
    return " ".join(str(value or "").casefold().split())


def _emergent(events: Iterable[Mapping[str, Any]], kind: str) -> list[dict[str, Any]]:
    """What the whole organization keeps naming when it likes or dislikes a
    page: a pattern counts once it was named on two or more different pages.
    Computed on every read; nothing is written or approved."""

    stats: dict[str, dict[str, Any]] = {}
    for event in sorted((row for row in events if row["kind"] == kind), key=lambda row: row["ts"]):
        for phrase in event.get("about") or []:
            key = _phrase_key(phrase)
            if not key or key == WHOLE_THING:
                continue
            entry = stats.setdefault(key, {"pattern": phrase, "pages": set(), "people": set(), "last": "", "words": None})
            entry["pattern"] = phrase
            # Two sections of one page (paper#intro, paper#results) are one page.
            entry["pages"].add(str(event["target"].get("ref")).split("#", 1)[0])
            entry["people"].add(event["actor"]["id"])
            entry["last"] = event["ts"]
            entry["words"] = _quote(event.get("words")) or entry["words"]
    held = [entry for entry in stats.values() if len(entry["pages"]) >= EMERGENT_PAGES]
    held.sort(key=lambda entry: _phrase_key(entry["pattern"]))
    held.sort(key=lambda entry: entry["last"], reverse=True)
    held.sort(key=lambda entry: (len(entry["pages"]), len(entry["people"])), reverse=True)
    return [
        {
            "pattern": entry["pattern"],
            "pages": len(entry["pages"]),
            "people": len(entry["people"]),
            "last": entry["last"][:10],
            "words": entry["words"],
        }
        for entry in held[:TOP_PATTERNS]
    ]


def summarize(
    events: Iterable[Mapping[str, Any]],
    *,
    viewer: ActorContext,
    person: str | None = None,
    task: str | None = None,
    form: str | None = None,
) -> dict[str, Any]:
    """Plain counts and the person's own words, bounded, with retractions honoured."""

    unique: dict[str, Mapping[str, Any]] = {}
    for event in sorted((row for row in events if valid_event(row)), key=lambda row: row["ts"]):
        unique.setdefault(event["id"], event)
    rows = list(unique.values())
    retracted: set[str] = set()
    for event in rows:
        if event["kind"] != "retracted":
            continue
        original = unique.get(str(event["target"].get("ref")))
        if original and original["kind"] != "retracted" and original["actor"]["id"] == event["actor"]["id"]:
            retracted.add(original["id"])
    active = [row for row in rows if row["kind"] != "retracted" and row["id"] not in retracted]

    person_id, name = _resolve_person(rows, viewer, person)
    own = [row for row in active if person_id is not None and row["actor"]["id"] == person_id]
    if own:
        name = str(own[-1]["actor"].get("name") or name)

    def ranked(kind: str) -> list[dict[str, Any]]:
        stats: dict[str, dict[str, Any]] = {}
        for event in (row for row in own if row["kind"] == kind):
            for phrase in event.get("about") or [WHOLE_THING]:
                entry = stats.setdefault(phrase, {"pattern": phrase, "count": 0, "last": "", "words": None})
                entry["count"] += 1
                entry["last"] = event["ts"]
                entry["words"] = _quote(event.get("words")) or entry["words"]
        ordered = sorted(stats.values(), key=lambda entry: entry["pattern"])
        ordered.sort(key=lambda entry: entry["last"], reverse=True)
        ordered.sort(key=lambda entry: entry["count"], reverse=True)
        return [{**entry, "last": entry["last"][:10]} for entry in ordered[:TOP_PATTERNS]]

    def relevant(event: Mapping[str, Any]) -> bool:
        return _near(task, event.get("task")) or _near(form, event.get("form"))

    choices = sorted((row for row in own if row["kind"] == "chose"), key=lambda row: row["ts"], reverse=True)
    spoken = [row for row in own if row["kind"] in {"liked", "disliked", "chose"} and _quote(row.get("words"))]
    spoken.sort(key=lambda row: row["ts"], reverse=True)
    spoken.sort(key=relevant, reverse=True)
    reactions = [row for row in own if row["kind"] in {"liked", "disliked", "chose"}]
    dates = sorted(_date(row) for row in reactions)
    return {
        "schema": SUMMARY_SCHEMA,
        "person": {"id": person_id, "name": name},
        "counts": {kind: sum(1 for row in own if row["kind"] == kind) for kind in ("liked", "disliked", "chose")},
        "first": dates[0] if dates else None,
        "last": dates[-1] if dates else None,
        "task": task,
        "form": form,
        "matching": sum(1 for row in reactions if relevant(row)) if (task or form) else None,
        "liked": ranked("liked"),
        "disliked": ranked("disliked"),
        "chose": [
            {
                "date": _date(row),
                "chose": row["target"].get("ref"),
                "over": (row.get("over") or {}).get("ref"),
                "words": _quote(row.get("words")),
                "id": row["id"],
            }
            for row in choices[:LAST_CHOICES]
        ],
        "rules": {
            "egregore": [dict(rule) for rule in EGREGORE_RULES],
            "org": _principles(row for row in active if row["kind"] == "adopted" and row.get("scope") == "org"),
            "person": _principles(row for row in own if row["kind"] == "adopted" and row.get("scope") == "person"),
        },
        "emergent": {
            "liked": _emergent(active, "liked"),
            "disliked": _emergent(active, "disliked"),
        },
        "adopted": {
            "person": _latest_adopted(
                row for row in own if row["kind"] == "adopted" and row.get("scope") == "person"
            ),
            "org": _latest_adopted(
                row for row in active if row["kind"] == "adopted" and row.get("scope") == "org"
            ),
        },
        "quotes": [
            {
                "date": _date(row),
                "kind": row["kind"],
                "target": row["target"].get("ref"),
                "task": row.get("task"),
                "form": row.get("form"),
                "words": _quote(row.get("words")),
                "id": row["id"],
            }
            for row in spoken[:LAST_QUOTES]
        ],
        "note": READING_NOTE,
    }


def render_text(summary: Mapping[str, Any]) -> str:
    """Words only: what the person liked and disliked, their choices and defaults."""

    name = summary["person"]["name"]
    counts = summary["counts"]
    total = sum(counts.values())
    header = f"Taste for {name}"
    if total:
        header += (
            f" · {counts['liked']} liked · {counts['disliked']} disliked · {counts['chose']} chosen"
            f" · {summary['first']} to {summary['last']}"
        )
    lines = [header, READING_NOTE, LAYER_NOTE]
    focus = " / ".join(value for value in (summary.get("task"), summary.get("form")) if value)
    if focus and total:
        lines.append(
            f"{summary['matching']} of {total} reactions were about work like “{focus}”; "
            "their words come first below."
        )

    def said(words: str | None) -> str:
        return f" · “{words}”" if words else ""

    rules = summary["rules"]
    lines += ["", "Egregore rules (every organization)"]
    lines += [
        f"- {rule['rule']}"
        + ("" if rule["skip"] == "Never." else f" Skip it for {rule['skip'][:1].lower()}{rule['skip'][1:]}")
        for rule in rules["egregore"]
    ]
    if rules["org"]:
        lines += ["", "House rules (this organization)"]
        lines += [f"- {rule['value']} · {rule['date']} · by {rule['by']}{said(rule['words'])}" for rule in rules["org"]]
    org_defaults = summary["adopted"]["org"]
    if org_defaults:
        lines += ["", "Organization defaults"]
        lines += [
            f"- {kind}: {entry['value']} · {entry['date']} · by {entry['by']}{said(entry['words'])}"
            for kind, entry in org_defaults.items()
        ]
    for key, title in (("liked", "Your organization tends to like"), ("disliked", "Your organization tends to avoid")):
        if summary["emergent"][key]:
            lines += ["", title]
            lines += [
                f"- {entry['pattern']} · {entry['pages']} pages · {entry['people']} "
                + ("person" if entry["people"] == 1 else "people")
                + f" · last {entry['last']}{said(entry['words'])}"
                for entry in summary["emergent"][key]
            ]
    if rules["person"]:
        lines += ["", f"Rules {name} adopted"]
        lines += [f"- {rule['value']} · {rule['date']}{said(rule['words'])}" for rule in rules["person"]]
    if summary["adopted"]["person"]:
        lines += ["", f"Defaults {name} adopted"]
        lines += [
            f"- {kind}: {entry['value']} · {entry['date']}{said(entry['words'])}"
            for kind, entry in summary["adopted"]["person"].items()
        ]

    for key, title in (("liked", f"{name} liked most"), ("disliked", f"{name} disliked most")):
        if summary[key]:
            lines += ["", title]
            lines += [
                f"- {entry['pattern']} · {entry['count']}× · last {entry['last']}{said(entry['words'])}"
                for entry in summary[key]
            ]
    if summary["chose"]:
        lines += ["", "Chose"]
        lines += [
            f"- {entry['date']} · {entry['chose']} over {entry['over']}{said(entry['words'])}"
            for entry in summary["chose"]
        ]
    if summary["quotes"]:
        lines += ["", "Their words"]
        for entry in summary["quotes"]:
            about = ", ".join(value for value in (entry.get("task"), entry.get("form")) if value)
            lines.append(
                f"- {entry['date']} · {entry['kind']} {entry['target']}"
                + (f" ({about})" if about else "")
                + said(entry["words"])
            )
    if not total and not summary["adopted"]["person"] and not rules["person"]:
        lines += ["", f"No recorded taste for {name} yet."]
    return "\n".join(lines) + "\n"
