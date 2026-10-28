"""Deterministic manual-ingest boundary for canonical organizational state.

This does not replace connector-specific extraction.  It establishes the
shared sequence those adapters feed: normalize with provenance, quarantine,
explicit review/admission, canonical writeback, then disposable projections.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol, Sequence, runtime_checkable

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalDocument,
    content_digest,
    normalize_markdown_body,
    parse_canonical_markdown,
    render_canonical_markdown,
)
from .contracts import (
    ActionAuthorizer,
    ActorContext,
    ArtifactRelationship,
    ArtifactWriteback,
    CanonicalArtifact,
    IngestSource,
    Permission,
    SourceProvenance,
    SyncStatus,
    SyncTransport,
    TelemetryEvent,
    TelemetrySink,
    WritebackEvent,
    WritebackStatus,
)
from .telemetry import TELEMETRY_SCHEMA_VERSION


INGEST_JOURNAL_SCHEMA = "egregore-ingest-journal/v1"
INGEST_CORPUS_SCHEMA = "egregore-ingest-corpus/v1"


class IngestPhase(StrEnum):
    NORMALIZED = "normalized"
    QUARANTINED = "quarantined"
    REJECTED = "rejected"
    ADMITTING = "admitting"
    ADMITTED = "admitted"
    PARTIAL = "partial"
    TOMBSTONED = "tombstoned"


@dataclass(frozen=True, slots=True)
class NormalizedIngest:
    source: IngestSource
    document: CanonicalDocument
    raw_content_hash: str
    normalized_content_hash: str
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class IngestReview:
    approved: bool
    reviewed_by: str
    reviewed_at: datetime
    notes: str | None = None


@dataclass(frozen=True, slots=True)
class IngestReceipt:
    source_id: str
    artifact_id: str
    phase: IngestPhase
    quarantine_path: str | None = None
    writeback: WritebackEvent | None = None
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class IngestRegistrationReceipt:
    """Receipt for committing a referenceable intake manifest before indexing."""

    source_id: str
    document_count: int
    sync: SyncStatus
    manifest_revision: str


@runtime_checkable
class IngestJournal(Protocol):
    def record(self, source_id: str, phase: IngestPhase, detail: Mapping[str, Any]) -> None: ...

    def clear(self, source_id: str) -> None: ...

    def pending(self) -> Sequence[Mapping[str, Any]]: ...

    def tombstone(
        self,
        *,
        source_id: str,
        artifact_id: str,
        source_revision: str,
        content_hash: str,
    ) -> None: ...


@runtime_checkable
class IngestWorkflow(Protocol):
    def normalize_item(self, source: IngestSource, payload: bytes) -> NormalizedIngest: ...

    def quarantine(self, item: NormalizedIngest) -> IngestReceipt: ...

    def admit(
        self,
        actor: ActorContext,
        item: NormalizedIngest,
        review: IngestReview,
    ) -> IngestReceipt: ...


class CanonicalIngestRegistry:
    """Authorize and version corpus manifests without canonicalizing private bodies.

    Bulk intake bodies intentionally remain in the instance-local ingest store.
    The manifest is the canonical, referenceable organizational record that must
    reach Git before its disposable retrieval projection is refreshed.
    """

    def __init__(
        self,
        *,
        memory_root: Path,
        authorizer: ActionAuthorizer,
        sync_transport: SyncTransport,
        telemetry: TelemetrySink,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.memory_root = memory_root.resolve()
        self.authorizer = authorizer
        self.sync_transport = sync_transport
        self.telemetry = telemetry
        self.clock = clock or (lambda: datetime.now(UTC))

    def register(
        self,
        actor: ActorContext,
        *,
        source_id: str,
        manifest_path: Path,
        source_path: Path,
    ) -> IngestRegistrationReceipt:
        source_slug = _slug(source_id)
        expected_root = (self.memory_root / "ingest" / "sources" / source_slug).resolve()
        manifest = manifest_path.resolve()
        source = source_path.resolve()
        if manifest.parent != expected_root or source.parent != expected_root:
            raise ValueError("ingest manifest must be inside canonical memory/ingest")
        if manifest.name != "manifest.json" or source.name != "source.json":
            raise ValueError("ingest registration requires source.json and manifest.json")
        if manifest.is_symlink() or source.is_symlink():
            raise ValueError("ingest registration does not accept symlinked manifests")

        value = json.loads(manifest.read_text(encoding="utf-8"))
        source_value = json.loads(source.read_text(encoding="utf-8"))
        if value.get("schema") != INGEST_CORPUS_SCHEMA:
            raise ValueError("unsupported ingest corpus manifest schema")
        manifest_source = value.get("source")
        if not isinstance(manifest_source, Mapping):
            raise ValueError("ingest manifest source is missing")
        if _slug(str(manifest_source.get("id", ""))) != source_slug:
            raise ValueError("ingest manifest source id does not match registration")
        if source_value != manifest_source:
            raise ValueError("ingest source record disagrees with its manifest")
        accepted_orgs = {actor.profile.org_id, actor.profile.slug}
        if str(manifest_source.get("org", "")) not in accepted_orgs:
            raise ValueError("ingest manifest organization does not match ActorContext")
        documents = value.get("documents")
        if not isinstance(documents, list):
            raise ValueError("ingest manifest documents must be a list")

        resource_id = f"ingest-source:{source_slug}"
        decision = self.authorizer.authorize_action(actor, Permission.WRITE, (resource_id,))
        if not decision.allowed:
            raise PermissionError("; ".join(decision.reasons) or "ingest registration denied")

        digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
        sync = self.sync_transport.push(
            message=f"docs(ingest): register {source_slug}",
            paths=(str(source), str(manifest)),
        )
        try:
            self.telemetry.emit(
                TelemetryEvent(
                    schema_version=TELEMETRY_SCHEMA_VERSION,
                    event_id=f"ingest-{digest[:24]}",
                    event_type="ingest.registered",
                    occurred_at=self.clock(),
                    org_id=actor.profile.org_id,
                    actor_id=actor.actor.actor_id,
                    session_id=actor.session_id,
                    org_revision=actor.profile.revision,
                    metrics={
                        "count": len(documents),
                        "result": "registered",
                        "success": True,
                    },
                    artifact_ids=(resource_id,),
                )
            )
        except Exception:
            # Canonical Git provenance is the durable outcome; telemetry is disposable.
            pass
        return IngestRegistrationReceipt(
            source_id=source_slug,
            document_count=len(documents),
            sync=sync,
            manifest_revision=f"sha256:{digest}",
        )


def _slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    if not result:
        raise ValueError("source id must contain at least one letter or number")
    return result


def stable_ingest_artifact_id(org_id: str, source_id: str, source_path: str) -> str:
    """Preserve ``bin/ingest.py``'s org/source/path identity algorithm."""

    raw = f"{org_id}\0{_slug(source_id)}\0{source_path}".encode("utf-8")
    return hashlib.sha256(raw).hexdigest()[:24]


def _utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


class LocalIngestJournal:
    """Atomic recovery journal plus deterministic tombstones.

    The one-record-per-source shape intentionally matches ``bin/ingest.py
    journal`` so existing status/replay tooling can consume it during migration.
    """

    def __init__(self, root: Path, *, clock: Callable[[], datetime] | None = None):
        self.root = root.resolve()
        self.state_root = self.root / ".state"
        self.clock = clock or (lambda: datetime.now(UTC))

    def _path(self, source_id: str) -> Path:
        return self.state_root / f"{_slug(source_id)}.json"

    @staticmethod
    def _atomic_json(path: Path, value: Any) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        temporary.write_text(
            json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary.replace(path)

    def record(self, source_id: str, phase: IngestPhase, detail: Mapping[str, Any]) -> None:
        self._atomic_json(
            self._path(source_id),
            {
                "schema": INGEST_JOURNAL_SCHEMA,
                "source": _slug(source_id),
                "phase": phase.value,
                "detail": dict(detail),
                "updated_at": self.clock().astimezone(UTC).isoformat(),
            },
        )

    def clear(self, source_id: str) -> None:
        self._path(source_id).unlink(missing_ok=True)

    def pending(self) -> Sequence[Mapping[str, Any]]:
        if not self.state_root.exists():
            return ()
        rows: list[Mapping[str, Any]] = []
        for path in sorted(self.state_root.glob("*.json")):
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if value.get("phase") not in {IngestPhase.ADMITTED.value, IngestPhase.REJECTED.value}:
                rows.append(value)
        return tuple(rows)

    def tombstone(
        self,
        *,
        source_id: str,
        artifact_id: str,
        source_revision: str,
        content_hash: str,
    ) -> None:
        path = self.root / "sources" / _slug(source_id) / "tombstones.json"
        current: list[dict[str, Any]] = []
        if path.exists():
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, list):
                current = loaded
        row = {
            "id": artifact_id,
            "source_revision": source_revision,
            "content_hash": content_hash,
            "deleted_at": self.clock().astimezone(UTC).isoformat(),
        }
        current = [item for item in current if item.get("id") != artifact_id]
        current.append(row)
        self._atomic_json(path, sorted(current, key=lambda item: item["id"]))
        self.record(source_id, IngestPhase.TOMBSTONED, row)


class LocalQuarantine:
    """Local, non-canonical staging area excluded from organizational memory."""

    def __init__(self, root: Path):
        self.root = root.resolve()

    def put(self, item: NormalizedIngest) -> Path:
        source_id = _slug(item.source.source_id)
        target = self.root / source_id / f"{item.document.artifact.artifact_id}.md"
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
        temporary.write_text(render_canonical_markdown(item.document), encoding="utf-8")
        temporary.replace(target)
        return target

    def read(self, source_id: str, artifact_id: str, *, org_id: str) -> CanonicalDocument:
        target = self.root / _slug(source_id) / f"{artifact_id}.md"
        markdown = target.read_text(encoding="utf-8")
        fields_path = f"ingest/sources/{_slug(source_id)}/documents/{artifact_id}.md"
        return parse_canonical_markdown(markdown, canonical_path=fields_path, default_org_id=org_id)

    def remove(self, source_id: str, artifact_id: str) -> None:
        (self.root / _slug(source_id) / f"{artifact_id}.md").unlink(missing_ok=True)


class CanonicalIngestWorkflow:
    """Manual-ingest implementation with no connector, retriever, or graph details."""

    def __init__(
        self,
        *,
        org_id: str,
        writeback: ArtifactWriteback,
        journal: IngestJournal,
        quarantine_store: LocalQuarantine,
        default_actor_id: str = "service:ingest",
    ) -> None:
        self.org_id = org_id
        self.writeback = writeback
        self.journal = journal
        self.quarantine_store = quarantine_store
        self.default_actor_id = default_actor_id

    def normalize_item(self, source: IngestSource, payload: bytes) -> NormalizedIngest:
        raw_hash = hashlib.sha256(payload).hexdigest()
        if source.content_hash and source.content_hash not in {raw_hash, f"sha256:{raw_hash}"}:
            raise ValueError("ingest payload does not match source content_hash")
        text = payload.decode("utf-8", errors="replace")
        body = normalize_markdown_body(text)
        normalized_hash = content_digest(body)
        source_path = str(
            source.metadata.get("source_path") or source.source_uri or source.source_id
        )
        artifact_id = stable_ingest_artifact_id(self.org_id, source.source_id, source_path)
        source_slug = _slug(source.source_id)
        path = f"ingest/sources/{source_slug}/documents/{artifact_id}.md"
        title = source.title or Path(source_path).stem or source.source_id
        # IngestSource intentionally has no actor field.  Connector adapters can
        # supply it in metadata until a future contract revision adds one.
        created_by = str(source.metadata.get("imported_by") or self.default_actor_id)
        provenance = SourceProvenance(
            source_type=source.source_type,
            source_id=source.source_id,
            revision=source.revision,
            content_hash=raw_hash,
            observed_at=_utc(source.observed_at),
            source_uri=source.source_uri,
            imported_by=created_by,
        )
        relationships = tuple(
            ArtifactRelationship(
                relation=str(item.get("relation") or item.get("type") or "related-to"),
                target_id=str(item.get("target_id") or item.get("target") or item.get("id")),
            )
            for item in source.metadata.get("relationships", ())
            if isinstance(item, Mapping)
            and (item.get("target_id") or item.get("target") or item.get("id"))
        )
        artifact = CanonicalArtifact(
            schema_version=ARTIFACT_SCHEMA_VERSION,
            artifact_id=artifact_id,
            org_id=self.org_id,
            artifact_type="ingest-document",
            title=title,
            created_at=_utc(source.observed_at),
            created_by=created_by,
            status="unverified",
            canonical_path=path,
            revision=source.revision,
            content_hash=normalized_hash,
            workstream=(
                str(source.metadata["workstream"])
                if source.metadata.get("workstream")
                else None
            ),
            visibility=source.visibility,
            relationships=relationships,
            supersedes=tuple(str(item) for item in source.metadata.get("supersedes", ())),
            provenance=(provenance,),
        )
        document = CanonicalDocument(
            artifact=artifact,
            body=body,
            policy_hints={
                "boundaries": dict(source.metadata.get("boundaries", {})),
                "review_required": True,
            },
        )
        warnings = (
            ("payload contained invalid UTF-8 and replacement characters were used",)
            if "\ufffd" in text
            else ()
        )
        self.journal.record(
            source.source_id,
            IngestPhase.NORMALIZED,
            {
                "artifact_id": artifact_id,
                "source_revision": source.revision,
                "raw_content_hash": raw_hash,
                "normalized_content_hash": normalized_hash,
            },
        )
        return NormalizedIngest(source, document, raw_hash, normalized_hash, warnings)

    # Compatibility with the shared v1 Ingestor protocol.
    def normalize(self, source: IngestSource, payload: bytes) -> CanonicalArtifact:
        return self.normalize_item(source, payload).document.artifact

    def quarantine(self, item: NormalizedIngest) -> IngestReceipt:
        path = self.quarantine_store.put(item)
        detail = {
            "artifact_id": item.document.artifact.artifact_id,
            "quarantine_path": str(path),
            "source_revision": item.source.revision,
        }
        self.journal.record(item.source.source_id, IngestPhase.QUARANTINED, detail)
        return IngestReceipt(
            source_id=item.source.source_id,
            artifact_id=item.document.artifact.artifact_id,
            phase=IngestPhase.QUARANTINED,
            quarantine_path=str(path),
            warnings=item.warnings,
        )

    def load_quarantined(
        self,
        *,
        source_id: str,
        artifact_id: str,
    ) -> NormalizedIngest:
        """Rehydrate a staged item without re-reading the external source."""

        document = self.quarantine_store.read(
            source_id,
            artifact_id,
            org_id=self.org_id,
        )
        if document.artifact.artifact_type != "ingest-document":
            raise ValueError("quarantined artifact is not an ingest document")
        if document.artifact.status != "unverified":
            raise ValueError("quarantined artifact is not awaiting admission")
        if not document.artifact.provenance:
            raise ValueError("quarantined artifact has no source provenance")
        provenance = document.artifact.provenance[0]
        if _slug(provenance.source_id) != _slug(source_id):
            raise ValueError("quarantined source identity does not match request")
        boundaries = document.policy_hints.get("boundaries", {})
        source = IngestSource(
            source_type=provenance.source_type,
            source_id=provenance.source_id,
            revision=provenance.revision,
            content_hash=provenance.content_hash,
            observed_at=provenance.observed_at,
            title=document.artifact.title,
            source_uri=provenance.source_uri,
            visibility=document.artifact.visibility,
            metadata={
                "imported_by": provenance.imported_by,
                "boundaries": dict(boundaries) if isinstance(boundaries, Mapping) else {},
            },
        )
        return NormalizedIngest(
            source=source,
            document=document,
            raw_content_hash=provenance.content_hash,
            normalized_content_hash=document.artifact.content_hash,
            warnings=document.warnings,
        )

    def admit(
        self,
        actor: ActorContext,
        item: NormalizedIngest,
        review: IngestReview,
    ) -> IngestReceipt:
        artifact_id = item.document.artifact.artifact_id
        if review.reviewed_by != actor.actor.actor_id:
            raise ValueError("reviewer must match the active actor")
        if not review.approved:
            self.journal.record(
                item.source.source_id,
                IngestPhase.REJECTED,
                {
                    "artifact_id": artifact_id,
                    "reviewed_by": review.reviewed_by,
                    "notes": review.notes,
                },
            )
            return IngestReceipt(
                source_id=item.source.source_id,
                artifact_id=artifact_id,
                phase=IngestPhase.REJECTED,
                warnings=((review.notes,) if review.notes else ()),
            )

        self.journal.record(
            item.source.source_id,
            IngestPhase.ADMITTING,
            {"artifact_id": artifact_id, "reviewed_by": review.reviewed_by},
        )
        admitted = replace(item.document.artifact, status="admitted")
        admitted_document = replace(item.document, artifact=admitted)
        write_document = getattr(self.writeback, "write_document", None)
        if callable(write_document):
            event = write_document(actor, admitted_document)
        else:
            event = self.writeback.write(actor, admitted, item.document.body)
        if event.status is WritebackStatus.REJECTED:
            phase = IngestPhase.REJECTED
        elif event.status is WritebackStatus.PARTIAL:
            phase = IngestPhase.PARTIAL
        else:
            phase = IngestPhase.ADMITTED
        detail = {
            "artifact_id": artifact_id,
            "writeback_event": event.event_id,
            "writeback_status": event.status.value,
        }
        self.journal.record(item.source.source_id, phase, detail)
        if phase in {IngestPhase.ADMITTED, IngestPhase.PARTIAL}:
            self.quarantine_store.remove(item.source.source_id, artifact_id)
        return IngestReceipt(
            source_id=item.source.source_id,
            artifact_id=artifact_id,
            phase=phase,
            writeback=event,
            warnings=item.warnings + event.warnings,
        )
