"""Runtime-owned lifecycle for living Scroll documents.

Scrolls are mutable papers backed by append-only version/turn/review events.
Their ledger is a disposable fold, and publication is a separately authorized,
actor-bound SHARE effect against one exact HTML revision.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from typing import Any, Callable, Mapping, Sequence
import unicodedata

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalDocument,
    content_digest,
    parse_canonical_markdown,
    render_canonical_markdown,
)
from .contracts import ActorContext, ArtifactRelationship, CanonicalArtifact, Permission, WritebackEvent, WritebackStatus
from .errors import AuthorizationDenied
from .policy import scope_allows_path
from .runtime import EgregoreRuntime


SCROLL_SCHEMA_VERSION = "egregore-scroll/v1"
SCROLL_EVENT_SCHEMA_VERSION = "egregore-scroll-event/v1"
SCROLL_SHARE_SCHEMA_VERSION = "egregore-scroll-share-plan/v1"
EXACT_SHARE_CONFIRMATION = "APPROVE_EXACT_SHARE"
SCROLL_EVENT_TYPES = frozenset(
    {"version-published", "turn-received", "turn-reviewed", "share-published"}
)


class ScrollError(ValueError):
    """A Scroll event, review, version, or share request is invalid."""


def _slug(value: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")[:50]
    if not normalized:
        raise ScrollError("scroll slug must contain a letter or number")
    return normalized


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _normalize(value: Any) -> Any:
    if isinstance(value, str):
        return unicodedata.normalize("NFC", value.replace("\r\n", "\n").replace("\r", "\n"))
    if isinstance(value, list):
        return [_normalize(item) for item in value]
    if isinstance(value, tuple):
        return [_normalize(item) for item in value]
    if isinstance(value, Mapping):
        return {_normalize(str(key)): _normalize(item) for key, item in value.items()}
    return value


def _fnv1a32(text: str) -> str:
    value = 0x811C9DC5
    for byte in text.encode("utf-8"):
        value ^= byte
        value = (value * 0x01000193) & 0xFFFFFFFF
    return f"{value:08x}"


def scroll_turn_id(turn: Mapping[str, Any]) -> str:
    """Return the cross-runtime Scroll turn id defined by the v1 grammar."""

    normalized = _normalize(dict(turn))
    respondent = str(normalized.get("respondent") or "")
    base_version = str(normalized.get("base_version") or "")
    date = str(normalized.get("date") or "")
    if not respondent or not base_version or not date:
        raise ScrollError("turn requires respondent, base_version, and date")
    answers = []
    for answer in sorted(normalized.get("answers") or (), key=lambda row: str(row.get("fork") or "")):
        fork = str(answer.get("fork") or "")
        mode = str(answer.get("mode") or "single")
        note = str(answer.get("note") or "")
        if not fork:
            raise ScrollError("every turn answer requires a fork id")
        if mode == "multi":
            picks = sorted(str(item) for item in answer.get("picks") or answer.get("pick") or ())
            answers.append([fork, picks, note])
        elif mode == "rank":
            tiers = [sorted(str(item) for item in tier) for tier in answer.get("ranks") or ()]
            answers.append([fork, tiers, note])
        elif mode == "spectrum":
            answers.append([fork, answer.get("position", "UNDECIDED"), note])
        else:
            answers.append([fork, answer.get("pick", "UNDECIDED"), note])
    opens = [
        [str(row.get("prompt") or ""), row.get("text", "UNDECIDED")]
        for row in sorted(normalized.get("opens") or (), key=lambda row: str(row.get("prompt") or ""))
    ]
    digest_input = [respondent, base_version, date, answers, opens]
    encoded = json.dumps(digest_input, ensure_ascii=False, separators=(",", ":"))
    return f"{respondent}|{base_version}|{date}|{_fnv1a32(encoded)}"


@dataclass(frozen=True, slots=True)
class ScrollSnapshot:
    slug: str
    title: str
    creator_id: str
    trusted_actor_ids: tuple[str, ...]
    respondents: tuple[str, ...]
    version: int
    storage_key: str
    source_html: str
    published_url: str | None
    document: CanonicalDocument

    @property
    def revision(self) -> str:
        return self.document.artifact.revision


@dataclass(frozen=True, slots=True)
class ScrollEventReceipt:
    scroll: ScrollSnapshot
    event_id: str
    disposition: str
    receipts: tuple[WritebackEvent, ...]


@dataclass(frozen=True, slots=True)
class ScrollSharePlan:
    schema_version: str
    plan_id: str
    digest: str
    actor_id: str
    session_id: str
    slug: str
    expected_revision: str
    html_path: str
    html_hash: str
    title: str
    description: str
    created_at: str
    available: bool = True
    reason: str | None = None
    published_url: str | None = None
    published_at: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "plan_id": self.plan_id,
            "digest": self.digest,
            "actor_id": self.actor_id,
            "session_id": self.session_id,
            "slug": self.slug,
            "expected_revision": self.expected_revision,
            "html_path": self.html_path,
            "html_hash": self.html_hash,
            "title": self.title,
            "description": self.description,
            "created_at": self.created_at,
            "available": self.available,
            "reason": self.reason,
            "published_url": self.published_url,
            "published_at": self.published_at,
        }


@dataclass(frozen=True, slots=True)
class ScrollShareReceipt:
    plan_id: str
    slug: str
    url: str
    writeback: tuple[WritebackEvent, ...]


def parse_scroll_markdown(markdown: str, *, slug: str, org_id: str) -> ScrollSnapshot:
    normalized = _slug(slug)
    document = parse_canonical_markdown(
        markdown,
        canonical_path=f"scrolls/{normalized}.md",
        default_org_id=org_id,
    )
    if document.artifact.artifact_type != "scroll":
        raise ScrollError("canonical Scroll record has the wrong artifact type")
    fields = document.legacy_fields
    creator = str(fields.get("creator_id") or fields.get("creator") or "").strip()
    if not creator:
        raise ScrollError("scroll creator is unresolved; backfill one stable actor id before tending")
    trusted = fields.get("trusted_actor_ids") or fields.get("trusted") or ()
    respondents = fields.get("respondents") or ()
    if isinstance(trusted, str):
        trusted = [trusted]
    if isinstance(respondents, str):
        respondents = [respondents]
    version = int(fields.get("version") or 0)
    if version < 1:
        raise ScrollError("scroll version must be positive")
    storage_key = str(fields.get("storage_key") or "").strip()
    source_html = str(fields.get("source_html") or "").strip()
    if not storage_key or not source_html:
        raise ScrollError("scroll requires a storage key and durable HTML source path")
    return ScrollSnapshot(
        slug=normalized,
        title=document.artifact.title,
        creator_id=creator,
        trusted_actor_ids=tuple(dict.fromkeys(str(item) for item in trusted if str(item).strip())),
        respondents=tuple(dict.fromkeys(str(item) for item in respondents if str(item).strip())),
        version=version,
        storage_key=storage_key,
        source_html=source_html,
        published_url=str(fields["published_url"]) if fields.get("published_url") else None,
        document=document,
    )


class CanonicalScrollService:
    """Own the Scroll write-ahead log, creator gate, fold, and SHARE seam."""

    def __init__(
        self,
        runtime: EgregoreRuntime,
        root: Path,
        *,
        clock: Callable[[], datetime] | None = None,
        publisher: Callable[[ScrollSnapshot, Path, str], str] | None = None,
        state_root: Path | None = None,
    ) -> None:
        self.runtime = runtime
        self.root = root.resolve()
        self.memory_root = (self.root / "memory").resolve()
        self.clock = clock or (lambda: datetime.now(UTC))
        self.publisher = publisher or self._publish
        instance = hashlib.sha256(str(self.memory_root).encode("utf-8")).hexdigest()[:16]
        private_root = state_root or (Path.home() / ".egregore" / "runtime")
        self.plan_root = private_root.resolve() / "share-plans" / instance

    @staticmethod
    def canonical_path(slug: str) -> str:
        return f"memory/scrolls/{_slug(slug)}.md"

    def _path(self, slug: str) -> Path:
        return self.memory_root / "scrolls" / f"{_slug(slug)}.md"

    def _authorize(self, actor: ActorContext, permission: Permission, resource: str, path: str) -> None:
        decision = self.runtime.authorize(actor, permission, (resource,))
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons) or f"scroll {permission.value} denied")
        if permission in {Permission.READ, Permission.WRITE} and not scope_allows_path(path, decision.scopes):
            raise AuthorizationDenied("scroll path is outside the actor's authorized scope")

    def _source_path(self, value: str | Path) -> Path:
        path = Path(value)
        if not path.is_absolute():
            path = self.root / path
        resolved = path.resolve()
        if resolved != self.root and self.root not in resolved.parents:
            raise ScrollError("scroll source must remain inside the active Egregore workspace")
        return resolved

    def read(self, actor: ActorContext, slug: str) -> ScrollSnapshot:
        normalized = _slug(slug)
        canonical = self.canonical_path(normalized)
        self._authorize(actor, Permission.READ, f"scroll:{normalized}", canonical)
        path = self._path(normalized)
        if not path.is_file():
            raise ScrollError(f"scroll does not exist: {normalized}")
        return parse_scroll_markdown(
            path.read_text(encoding="utf-8"), slug=normalized, org_id=actor.profile.org_id
        )

    def _event_document(
        self,
        actor: ActorContext,
        snapshot: ScrollSnapshot | None,
        slug: str,
        event: Mapping[str, Any],
        now: datetime,
    ) -> CanonicalDocument:
        event_id = str(event.get("id") or "").strip()
        if not event_id:
            raise ScrollError("scroll event requires a deterministic id")
        event_key = hashlib.sha256(event_id.encode("utf-8")).hexdigest()[:24]
        normalized = _normalize(dict(event))
        encoded = json.dumps(normalized, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        body = f"# Scroll event: {event['type']}\n\n```json\n{encoded}\n```\n"
        target_id = snapshot.document.artifact.artifact_id if snapshot else f"scroll:{slug}"
        return CanonicalDocument(
            artifact=CanonicalArtifact(
                schema_version=ARTIFACT_SCHEMA_VERSION,
                artifact_id=f"scroll-event:{slug}:{event_key}",
                org_id=actor.profile.org_id,
                artifact_type="lifecycle-event",
                title=f"scroll {event['type']}: {slug}",
                created_at=now,
                created_by=actor.actor.actor_id,
                status="accepted",
                canonical_path=f"scrolls/.events/{slug}/{event_key}.md",
                revision=f"sha256:{content_digest(body)[:16]}",
                content_hash=content_digest(body),
                relationships=(ArtifactRelationship("transitions", target_id),),
            ),
            body=body,
            legacy_fields={
                "lifecycle_action": f"scroll-{event['type']}",
                "target_artifact_id": target_id,
                "target_path": f"memory/scrolls/{slug}.md",
                "domain_event_schema": SCROLL_EVENT_SCHEMA_VERSION,
                "domain_event_id": event_id,
                "domain_event": normalized,
            },
        )

    @staticmethod
    def _request_digest(event: Mapping[str, Any], face: str | None, source: str | None) -> str:
        """Bind an immutable event to all inputs that change canonical state."""
        request = _normalize({"event": event, "face": face, "source_html": source})
        encoded = json.dumps(request, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        return hashlib.sha256(encoded.encode("utf-8")).hexdigest()

    def create(
        self,
        actor: ActorContext,
        *,
        title: str,
        face_markdown: str,
        source_html: str,
        version_event: Mapping[str, Any],
        slug: str | None = None,
        storage_key: str,
        respondents: Sequence[str] = (),
        trusted_actor_ids: Sequence[str] = (),
        review_after_days: int = 7,
        attention_ttl_days: int = 30,
        supersedes: Sequence[str] = (),
    ) -> tuple[ScrollSnapshot, tuple[WritebackEvent, ...]]:
        clean_title = " ".join(title.split()).strip()
        if not clean_title or not face_markdown.strip():
            raise ScrollError("scroll title and explanatory face are required")
        normalized = _slug(slug or clean_title)
        canonical = self.canonical_path(normalized)
        self._authorize(actor, Permission.WRITE, f"scroll:{normalized}", canonical)
        if self._path(normalized).exists():
            raise ScrollError(f"scroll already exists: {normalized}")
        html = self._source_path(source_html)
        if not html.is_file():
            raise ScrollError("scroll HTML source does not exist")
        if min(review_after_days, attention_ttl_days) < 1:
            raise ScrollError("scroll lifecycle windows must be positive days")
        event = _normalize(dict(version_event))
        event["type"] = "version-published"
        event["id"] = "v1"
        event["slug"] = normalized
        event["storage_key"] = storage_key.strip()
        event["respondents"] = list(dict.fromkeys(str(item) for item in respondents if str(item).strip()))
        version = event.get("version") if isinstance(event.get("version"), Mapping) else event
        if int(version.get("v") or 0) != 1:
            raise ScrollError("initial Scroll event must publish v1")
        now = self.clock().astimezone(UTC)
        request_digest = self._request_digest(
            event, face_markdown, html.relative_to(self.root).as_posix())
        event_document = self._event_document(actor, None, normalized, event, now)
        event_path = self.memory_root / event_document.artifact.canonical_path
        recovering = None
        if event_path.exists():
            try:
                actual_path = event_path.resolve().relative_to(self.memory_root)
            except ValueError as exc:
                raise ScrollError("Scroll creation event escapes canonical memory") from exc
            self._authorize(actor, Permission.READ, event_document.artifact.artifact_id,
                            f"memory/{actual_path.as_posix()}")
            recovering = parse_canonical_markdown(
                event_path.read_text(encoding="utf-8"),
                canonical_path=event_document.artifact.canonical_path,
                default_org_id=actor.profile.org_id,
            )
            if (recovering.artifact.artifact_id != event_document.artifact.artifact_id
                    or recovering.artifact.org_id != actor.profile.org_id
                    or _normalize(recovering.legacy_fields.get("domain_event")) != event
                    or recovering.legacy_fields.get("scroll_request_digest") != request_digest):
                raise ScrollError("Scroll creation retry differs from the recorded v1 request; reconcile the existing event and retry the original face and source path, or choose a new slug")
            now = recovering.artifact.created_at
        body = face_markdown
        digest = content_digest(body)
        artifact = CanonicalArtifact(
            schema_version=ARTIFACT_SCHEMA_VERSION,
            artifact_id=f"scroll:{normalized}",
            org_id=actor.profile.org_id,
            artifact_type="scroll",
            title=clean_title,
            created_at=now,
            created_by=actor.actor.actor_id,
            status="active",
            canonical_path=f"scrolls/{normalized}.md",
            revision=f"sha256:{digest[:16]}",
            content_hash=digest,
            supersedes=tuple(dict.fromkeys(item for item in supersedes if item)),
        )
        document = CanonicalDocument(
            artifact=artifact,
            body=body,
            policy_hints={"living_document": True, "publication_requires_share": True},
            legacy_fields={
                "scroll_schema": SCROLL_SCHEMA_VERSION,
                "slug": normalized,
                "creator_id": actor.actor.actor_id,
                "creator_alias": actor.actor.display_name,
                "trusted_actor_ids": list(dict.fromkeys(item for item in trusted_actor_ids if item)),
                "respondents": event["respondents"],
                "version": 1,
                "storage_key": storage_key.strip(),
                "source_html": html.relative_to(self.root).as_posix(),
                "review_at": _iso(now + timedelta(days=review_after_days)),
                "attention_expires_at": _iso(now + timedelta(days=attention_ttl_days)),
                "last_event_id": "v1",
                "applied_event_ids": ["v1"],
            },
        )
        snapshot = ScrollSnapshot(
            normalized,
            clean_title,
            actor.actor.actor_id,
            tuple(dict.fromkeys(item for item in trusted_actor_ids if item)),
            tuple(event["respondents"]),
            1,
            storage_key.strip(),
            html.relative_to(self.root).as_posix(),
            None,
            document,
        )
        result_digest = content_digest(render_canonical_markdown(document))
        if recovering is not None:
            if recovering.legacy_fields.get("scroll_result_digest") != result_digest:
                raise ScrollError("Scroll creation retry differs from the recorded v1 result; reconcile the existing event and retry the original creation inputs, or choose a new slug")
            event_document = recovering
        else:
            event_document = replace(event_document, legacy_fields={
                **event_document.legacy_fields,
                "scroll_request_digest": request_digest,
                "scroll_result_digest": result_digest,
            })
        receipts = self.runtime.write_documents(actor, (event_document, document))
        self._require_persisted(receipts)
        return replace(snapshot, document=document), receipts

    @staticmethod
    def _require_persisted(receipts: Sequence[WritebackEvent]) -> None:
        if any(row.status is WritebackStatus.REJECTED for row in receipts):
            raise ScrollError("Scroll canonical persistence failed; partial writes may remain: " +
                              "; ".join(w for row in receipts for w in row.warnings))

    @staticmethod
    def _applied_event_ids(snapshot: ScrollSnapshot) -> tuple[str, ...]:
        """Read acknowledgements committed with the canonical Scroll state.

        An event file alone does not prove the second write in its batch
        succeeded. Older snapshots can attest only to their last event; never
        seed this set from the ledger, which may contain interrupted writes.
        """
        fields = snapshot.document.legacy_fields
        recorded = fields.get("applied_event_ids")
        if recorded is None:
            last = fields.get("last_event_id")
            return (last,) if isinstance(last, str) and last else ()
        if not isinstance(recorded, (list, tuple)) or any(
            not isinstance(item, str) or not item for item in recorded
        ):
            raise ScrollError("Scroll applied-event acknowledgements are malformed")
        return tuple(dict.fromkeys(recorded))

    def _event_documents(self, actor: ActorContext, slug: str) -> tuple[CanonicalDocument, ...]:
        snapshot = self.read(actor, slug)
        directory = self.memory_root / "scrolls" / ".events" / snapshot.slug
        decision = self.runtime.authorize(
            actor, Permission.READ, (f"scroll-events:{snapshot.slug}",)
        )
        if not decision.allowed:
            raise AuthorizationDenied(
                "; ".join(decision.reasons) or "Scroll event collection read denied"
            )
        rows = []
        if directory.is_dir():
            for path in sorted(directory.glob("*.md")):
                canonical = path.relative_to(self.memory_root).as_posix()
                if not scope_allows_path(f"memory/{canonical}", decision.scopes):
                    raise AuthorizationDenied(
                        "Scroll event collection is outside the actor's authorized scope"
                    )
                document = parse_canonical_markdown(
                    path.read_text(encoding="utf-8"),
                    canonical_path=canonical,
                    default_org_id=actor.profile.org_id,
                )
                event = document.legacy_fields.get("domain_event")
                if isinstance(event, Mapping):
                    rows.append(document)
        return tuple(rows)

    def _events(self, actor: ActorContext, slug: str) -> tuple[dict[str, Any], ...]:
        return tuple(dict(document.legacy_fields["domain_event"])
                     for document in self._event_documents(actor, slug))

    def append_event(
        self,
        actor: ActorContext,
        *,
        slug: str,
        event: Mapping[str, Any],
        expected_revision: str,
        face_markdown: str | None = None,
        source_html: str | None = None,
    ) -> ScrollEventReceipt:
        current = self.read(actor, slug)
        self._authorize(actor, Permission.WRITE, f"scroll:{current.slug}", self.canonical_path(current.slug))
        if current.revision != expected_revision:
            raise ScrollError("scroll revision changed; rebuild from the event ledger before tending")
        row = _normalize(dict(event))
        kind = str(row.get("type") or "")
        if kind not in SCROLL_EVENT_TYPES - {"share-published"}:
            raise ScrollError("unsupported Scroll lifecycle event")
        now = self.clock().astimezone(UTC)
        disposition = "recorded"
        request_face = None
        request_source = None
        existing = None
        if kind == "turn-received":
            turn = dict(row.get("turn")) if isinstance(row.get("turn"), Mapping) else dict(row)
            turn["id"] = scroll_turn_id(turn)
            turn["merged_into"] = "pending"
            row = {"type": kind, "id": turn["id"], "turn": turn, "submitted_by": actor.actor.actor_id}
            disposition = (
                "trusted"
                if actor.actor.actor_id in {current.creator_id, *current.trusted_actor_ids}
                else "creator-review-required"
            )
        elif kind == "turn-reviewed":
            if actor.actor.actor_id != current.creator_id:
                raise AuthorizationDenied("only the stable creator actor id may review Scroll turns")
            turn_id = str(row.get("turn") or "").strip()
            if not turn_id:
                raise ScrollError("turn review requires a turn id")
            review_id = f"review|{turn_id}"
            existing = {str(item.legacy_fields["domain_event"].get("id") or ""): item
                        for item in self._event_documents(actor, current.slug)}
            recorded = existing.get(review_id)
            recorded_review = (
                recorded.legacy_fields["domain_event"].get("review", {})
                if recorded is not None else {}
            )
            # An omitted date is defaulted once per stable review event, not
            # per attempt. Restore it before content comparison/fingerprinting.
            default_date = (
                recorded_review.get("date", now.date().isoformat())
                if isinstance(recorded_review, Mapping) else now.date().isoformat()
            )
            review = dict(row.get("review")) if isinstance(row.get("review"), Mapping) else dict(row)
            review["by"] = actor.actor.actor_id
            review.setdefault("date", default_date)
            review.pop("type", None)
            review.pop("id", None)
            review.pop("turn", None)
            if review.get("disposition") not in {"accepted", "declined"}:
                raise ScrollError("turn review disposition must be accepted or declined")
            overrides = review.get("answers") if isinstance(review.get("answers"), Mapping) else {}
            has_decline = review["disposition"] == "declined" or "declined" in overrides.values()
            if has_decline and not str(review.get("note") or "").strip():
                raise ScrollError("a declined Scroll turn or answer requires a nonblank reason")
            row = {"type": kind, "id": review_id, "turn": turn_id, "review": review}
        else:
            if actor.actor.actor_id not in {current.creator_id, *current.trusted_actor_ids}:
                raise AuthorizationDenied("Scroll version publication requires creator or trusted actor authority")
            version = row.get("version") if isinstance(row.get("version"), Mapping) else row
            next_version = int(version.get("v") or 0)
            row["id"] = f"v{next_version}"
            row["type"] = "version-published"
            row["slug"] = current.slug
            row["storage_key"] = current.storage_key
            row["respondents"] = list(current.respondents)
            if face_markdown is None or not face_markdown.strip():
                raise ScrollError("a Scroll version requires its complete rewritten face")
            if source_html is None:
                raise ScrollError("a Scroll version requires its HTML source path")
            html = self._source_path(source_html)
            request_face = face_markdown
            request_source = html.relative_to(self.root).as_posix()
        request_digest = self._request_digest(row, request_face, request_source)
        event_id = str(row.get("id") or "")
        if existing is None:
            existing = {str(item.legacy_fields["domain_event"].get("id") or ""): item
                        for item in self._event_documents(actor, current.slug)}
        recovering = None
        if event_id in existing:
            recorded = existing[event_id]
            if _normalize(recorded.legacy_fields["domain_event"]) != row:
                raise ScrollError("Scroll event id already exists with different content")
            recorded_request = recorded.legacy_fields.get("scroll_request_digest")
            if recorded_request is not None and recorded_request != request_digest:
                raise ScrollError("Scroll event retry differs from its recorded request; use the original event, face, and source path")
            if kind == "version-published" and recorded_request is None:
                raise ScrollError("legacy Scroll version has no request fingerprint; reconcile its face and source against the current Scroll before submitting a new version")
            if event_id in self._applied_event_ids(current):
                return ScrollEventReceipt(current, event_id, disposition, ())
            if recorded.legacy_fields.get("scroll_base_revision") != current.revision:
                raise ScrollError("Scroll partial batch has no matching base revision; inspect the recorded event and current Scroll, then submit a new event against the current revision")
            recovering = recorded
            now = recorded.artifact.created_at
        if kind == "version-published":
            if next_version != current.version + 1:
                raise ScrollError("Scroll versions must advance exactly once from the current ledger")
            if not html.is_file():
                raise ScrollError("updated Scroll HTML source does not exist")
        fields = dict(current.document.legacy_fields)
        fields["last_event_id"] = event_id
        fields["applied_event_ids"] = [*self._applied_event_ids(current), event_id]
        body = current.document.body
        source_path = current.source_html
        version_number = current.version
        if kind == "version-published":
            body = face_markdown or body
            source_path = self._source_path(source_html or current.source_html).relative_to(self.root).as_posix()
            version_number = current.version + 1
            fields["version"] = version_number
            fields["source_html"] = source_path
            fields["reviewed_at"] = _iso(now)
        digest = content_digest(body)
        event_hash = hashlib.sha256(event_id.encode("utf-8")).hexdigest()[:8]
        document = CanonicalDocument(
            artifact=replace(
                current.document.artifact,
                revision=f"sha256:{digest[:16]}-{event_hash}",
                content_hash=digest,
            ),
            body=body,
            policy_hints=current.document.policy_hints,
            legacy_fields=fields,
            migrated_from=current.document.migrated_from,
            warnings=current.document.warnings,
        )
        result_digest = content_digest(render_canonical_markdown(document))
        if recovering is not None:
            if recovering.legacy_fields.get("scroll_result_digest") != result_digest:
                raise ScrollError("Scroll partial batch retry differs from its recorded result; retry with the original face and source path")
            event_document = recovering
        else:
            event_document = self._event_document(actor, current, current.slug, row, now)
            event_document = replace(event_document, legacy_fields={
                **event_document.legacy_fields,
                "scroll_base_revision": current.revision,
                "scroll_result_digest": result_digest,
                "scroll_request_digest": request_digest,
            })
        receipts = self.runtime.write_documents(actor, (event_document, document))
        self._require_persisted(receipts)
        updated = replace(
            current,
            version=version_number,
            source_html=source_path,
            document=document,
        )
        return ScrollEventReceipt(updated, event_id, disposition, receipts)

    def project_ledger(self, actor: ActorContext, slug: str) -> Mapping[str, Any]:
        """Fold authorized canonical events through the existing deterministic engine."""

        current = self.read(actor, slug)
        events = self._events(actor, current.slug)
        fold = self.root / ".claude" / "skills" / "scroll" / "assets" / "fold.mjs"
        if not fold.is_file():
            raise ScrollError("Scroll fold engine is unavailable")
        node_runner = self.root / "bin" / "node-run.sh"
        command = (
            ["bash", str(node_runner), str(fold)]
            if node_runner.is_file()
            else ["node", str(fold)]
        )
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".jsonl", delete=False) as handle:
            event_file = Path(handle.name)
            os.chmod(event_file, 0o600)
            for event in events:
                handle.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
        try:
            result = subprocess.run(
                [*command, str(event_file)],
                cwd=self.root,
                text=True,
                capture_output=True,
                check=False,
            )
        finally:
            event_file.unlink(missing_ok=True)
        if result.returncode != 0:
            raise ScrollError(result.stderr.strip() or "Scroll ledger fold failed")
        ledger = json.loads(result.stdout)
        state_dir = self.root / ".egregore" / "runtime" / "scrolls" / current.slug
        state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        projection = state_dir / "ledger.json"
        projection.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.chmod(projection, 0o600)
        return ledger

    def _connected(self) -> bool:
        try:
            config = json.loads((self.root / "egregore.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return False
        return config.get("mode") == "connected" and bool(config.get("api_url"))

    def plan_share(
        self,
        actor: ActorContext,
        *,
        slug: str,
        html_path: str | None = None,
        description: str = "",
    ) -> ScrollSharePlan:
        current = self.read(actor, slug)
        self._authorize(actor, Permission.SHARE, f"scroll:{current.slug}", self.canonical_path(current.slug))
        html = self._source_path(html_path or current.source_html)
        if not html.is_file():
            raise ScrollError("Scroll HTML source does not exist")
        now = self.clock().astimezone(UTC)
        html_hash = hashlib.sha256(html.read_bytes()).hexdigest()
        material = {
            "actor_id": actor.actor.actor_id,
            "session_id": actor.session_id,
            "slug": current.slug,
            "expected_revision": current.revision,
            "html_path": str(html),
            "html_hash": html_hash,
            "title": current.title,
            "description": description,
            "created_at": _iso(now),
        }
        digest = hashlib.sha256(
            json.dumps(material, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        available = self._connected()
        plan = ScrollSharePlan(
            SCROLL_SHARE_SCHEMA_VERSION,
            f"share-{digest[:20]}",
            digest,
            actor.actor.actor_id,
            actor.session_id,
            current.slug,
            current.revision,
            str(html),
            html_hash,
            current.title,
            description,
            _iso(now),
            available,
            None if available else "Local mode keeps the Scroll at its workspace source path.",
        )
        if available:
            self.plan_root.mkdir(parents=True, exist_ok=True, mode=0o700)
            plan_path = self.plan_root / f"{plan.plan_id}.json"
            plan_path.write_text(json.dumps(plan.to_dict(), sort_keys=True) + "\n", encoding="utf-8")
            os.chmod(plan_path, 0o600)
        return plan

    def dispatch_share(
        self,
        actor: ActorContext,
        *,
        plan_id: str,
        digest: str,
        confirmation: str,
    ) -> ScrollShareReceipt:
        if confirmation != EXACT_SHARE_CONFIRMATION:
            raise ScrollError("Scroll publication requires exact SHARE confirmation")
        plan_path = self.plan_root / f"{plan_id}.json"
        try:
            payload = json.loads(plan_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ScrollError("Scroll SHARE plan is missing or invalid; create a fresh plan") from exc
        plan = ScrollSharePlan(**payload)
        if plan.digest != digest or plan.plan_id != plan_id:
            raise ScrollError("Scroll SHARE approval does not match the exact plan")
        if plan.actor_id != actor.actor.actor_id or plan.session_id != actor.session_id:
            raise AuthorizationDenied("Scroll SHARE plan belongs to another actor or session")
        current = self.read(actor, plan.slug)
        self._authorize(actor, Permission.SHARE, f"scroll:{current.slug}", self.canonical_path(current.slug))
        shared_revision = f"{plan.expected_revision}-shared-{plan.digest[:8]}"
        recovering = bool(plan.published_url and plan.published_at)
        if current.revision != plan.expected_revision and not (
            recovering and current.revision == shared_revision and current.published_url == plan.published_url
        ):
            raise ScrollError("Scroll changed after preview; create and approve a fresh SHARE plan")
        if not recovering:
            html = self._source_path(plan.html_path)
            if hashlib.sha256(html.read_bytes()).hexdigest() != plan.html_hash:
                raise ScrollError("Scroll HTML changed after preview; create and approve a fresh SHARE plan")
            url = self.publisher(current, html, plan.description).strip()
            if not url:
                raise ScrollError("Scroll publisher returned no stable URL")
            plan = replace(plan, published_url=url, published_at=_iso(self.clock().astimezone(UTC)))
            # Retain the external result before canonical persistence. Recovery
            # completes this exact publication, even if the HTML later changes.
            temporary = plan_path.with_suffix(".tmp")
            with temporary.open("w", encoding="utf-8") as handle:
                os.chmod(temporary, 0o600)
                json.dump(plan.to_dict(), handle, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            temporary.replace(plan_path)
        url = plan.published_url
        now = datetime.fromisoformat(plan.published_at.replace("Z", "+00:00"))
        event = {
            "type": "share-published",
            "id": f"share|{plan.digest}",
            "url": url,
            "scroll_revision": plan.expected_revision,
            "by": actor.actor.actor_id,
            "date": _iso(now),
        }
        event_document = self._event_document(actor, current, current.slug, event, now)
        fields = dict(current.document.legacy_fields)
        fields.update({"published_url": url, "last_shared_revision": plan.expected_revision})
        fields["applied_event_ids"] = list(dict.fromkeys((*self._applied_event_ids(current), event["id"])))
        document = CanonicalDocument(
            artifact=replace(
                current.document.artifact,
                revision=shared_revision,
            ),
            body=current.document.body,
            policy_hints=current.document.policy_hints,
            legacy_fields=fields,
        )
        receipts = self.runtime.write_documents(actor, (event_document, document))
        if all(row.status is not WritebackStatus.REJECTED for row in receipts):
            plan_path.unlink(missing_ok=True)
        return ScrollShareReceipt(plan.plan_id, current.slug, url, receipts)

    def _publish(self, snapshot: ScrollSnapshot, html: Path, description: str) -> str:
        result = subprocess.run(
            [
                "bash",
                str(self.root / "bin" / "publish-artifact.sh"),
                "document",
                str(html),
                "--raw-html",
                "--id",
                snapshot.slug,
                "--title",
                snapshot.title,
                "--author",
                snapshot.creator_id,
                "--description",
                description,
            ],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            raise ScrollError(result.stderr.strip() or "Scroll publication failed")
        return result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
