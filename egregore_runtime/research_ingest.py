"""Typed canonical write boundary for meetings and user interviews."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence

from .artifacts import ARTIFACT_SCHEMA_VERSION, CanonicalDocument, artifact_id_from_path, content_digest
from .contracts import (
    ActorContext,
    ArtifactRelationship,
    CanonicalArtifact,
    Permission,
    SourceProvenance,
    WritebackStatus,
)
from .runtime import EgregoreRuntime
from .policy import scope_allows_path


RESEARCH_INGEST_SCHEMA_VERSION = "egregore-research-ingest/v1"
KINDS = frozenset({"meeting", "interview"})
ARTIFACT_TYPES = frozenset(
    {"meeting", "interview", "participant", "decision", "finding", "pattern"}
)
MAX_DOCUMENTS = 40
MAX_BODY_BYTES = 250_000


class ResearchIngestError(ValueError):
    """An analysis package violates the canonical research contract."""


@dataclass(frozen=True, slots=True)
class ResearchIngestReceipt:
    kind: str
    source_id: str
    status: str
    artifacts: tuple[dict[str, Any], ...]
    warnings: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": RESEARCH_INGEST_SCHEMA_VERSION,
            "kind": self.kind,
            "source_id": self.source_id,
            "status": self.status,
            "artifacts": list(self.artifacts),
            "warnings": list(self.warnings),
        }


def _required(mapping: Mapping[str, Any], key: str) -> str:
    value = str(mapping.get(key) or "").strip()
    if not value:
        raise ResearchIngestError(f"{key} is required")
    return value


def _canonical_path(kind: str, value: str, artifact_type: str) -> str:
    raw = value.strip().replace("\\", "/").removeprefix("memory/")
    path = PurePosixPath(raw)
    if path.is_absolute() or ".." in path.parts or path.suffix != ".md":
        raise ResearchIngestError("canonical_path must be a relative Markdown path")
    allowed = (
        ("meetings/", "knowledge/decisions/", "knowledge/findings/", "knowledge/patterns/")
        if kind == "meeting"
        else (
            "research/interviews/",
            "research/participants/",
            "knowledge/findings/",
            "knowledge/patterns/",
            "knowledge/decisions/",
        )
    )
    if not raw.startswith(allowed):
        raise ResearchIngestError(f"canonical_path is outside the {kind} research boundary")
    if artifact_type == "meeting" and not raw.startswith("meetings/"):
        raise ResearchIngestError("meeting briefing must be stored under meetings/")
    if artifact_type == "interview" and not raw.startswith("research/interviews/"):
        raise ResearchIngestError("interview briefing must be stored under research/interviews/")
    if artifact_type == "participant" and not raw.startswith("research/participants/"):
        raise ResearchIngestError("participant record must be stored under research/participants/")
    return raw


def _relationships(values: Any) -> tuple[ArtifactRelationship, ...]:
    if values is None:
        return ()
    if not isinstance(values, Sequence) or isinstance(values, (str, bytes)):
        raise ResearchIngestError("relationships must be a list")
    rows = []
    for item in values:
        if not isinstance(item, Mapping):
            raise ResearchIngestError("relationship entries must be objects")
        rows.append(
            ArtifactRelationship(
                relation=_required(item, "relation"),
                target_id=_required(item, "target_id"),
            )
        )
    return tuple(rows)


class CanonicalResearchIngestService:
    """Validate metadata, authorize, then inspect and persist analysis content."""

    def __init__(self, runtime: EgregoreRuntime, *, clock=None, content_loader=None) -> None:
        self.runtime = runtime
        self.clock = clock or (lambda: datetime.now(UTC))
        self.content_loader = content_loader or (
            lambda body_path: Path(body_path).read_text(encoding="utf-8")
        )

    def ingest(
        self,
        actor: ActorContext,
        package: Mapping[str, Any],
        *,
        expected_kind: str | None = None,
    ) -> ResearchIngestReceipt:
        schema = _required(package, "schema_version")
        if schema != RESEARCH_INGEST_SCHEMA_VERSION:
            raise ResearchIngestError(f"unsupported schema_version: {schema}")
        kind = _required(package, "kind").casefold()
        if kind not in KINDS or (expected_kind and kind != expected_kind):
            raise ResearchIngestError("research package kind does not match the requested adapter")
        source = package.get("source")
        if not isinstance(source, Mapping):
            raise ResearchIngestError("source must be an object")
        source_type = _required(source, "type")
        source_id = _required(source, "id")
        source_revision = _required(source, "revision")
        source_content_hash = _required(source, "content_hash")
        documents = package.get("documents")
        if not isinstance(documents, Sequence) or isinstance(documents, (str, bytes)):
            raise ResearchIngestError("documents must be a list")
        if not documents or len(documents) > MAX_DOCUMENTS:
            raise ResearchIngestError(f"documents must contain 1-{MAX_DOCUMENTS} entries")

        # Metadata is intentionally validated before any body is accessed.
        metadata: list[tuple[Mapping[str, Any], str, str, str, str, str]] = []
        resources = []
        for raw in documents:
            if not isinstance(raw, Mapping):
                raise ResearchIngestError("document entries must be objects")
            artifact_type = _required(raw, "artifact_type").casefold()
            if artifact_type not in ARTIFACT_TYPES:
                raise ResearchIngestError(f"unsupported research artifact_type: {artifact_type}")
            title = _required(raw, "title")
            status = str(raw.get("status") or "active").strip()
            body_path = _required(raw, "body_path")
            canonical_path = _canonical_path(
                kind, _required(raw, "canonical_path"), artifact_type
            )
            artifact_id = str(raw.get("id") or artifact_id_from_path(canonical_path)).strip()
            metadata.append((raw, artifact_type, title, status, canonical_path, body_path))
            resources.append(artifact_id)

        decision = self.runtime.authorize(actor, Permission.WRITE, tuple(resources))
        if not decision.allowed:
            raise PermissionError("; ".join(decision.reasons) or "research ingest denied")

        for _, _, _, _, canonical_path, _ in metadata:
            if decision.scopes and not scope_allows_path(
                f"memory/{canonical_path}", decision.scopes
            ):
                raise PermissionError(
                    "research artifact path is outside the actor's authorized scope"
                )

        now = self.clock().astimezone(UTC)
        provenance = SourceProvenance(
            source_type=source_type,
            source_id=source_id,
            revision=source_revision,
            content_hash=source_content_hash,
            observed_at=now,
            source_uri=str(source.get("uri")) if source.get("uri") else None,
            imported_by=actor.actor.actor_id,
        )
        prepared_documents: list[CanonicalDocument] = []
        for raw, artifact_type, title, status, canonical_path, body_path in metadata:
            body = self.content_loader(body_path)
            if not isinstance(body, str) or not body.strip():
                raise ResearchIngestError("document body is required")
            if len(body.encode("utf-8")) > MAX_BODY_BYTES:
                raise ResearchIngestError("document body exceeds the research ingest limit")
            digest = content_digest(body)
            artifact_id = str(raw.get("id") or artifact_id_from_path(canonical_path)).strip()
            artifact = CanonicalArtifact(
                schema_version=ARTIFACT_SCHEMA_VERSION,
                artifact_id=artifact_id,
                org_id=actor.profile.org_id,
                artifact_type=artifact_type,
                title=title,
                created_at=now,
                created_by=actor.actor.actor_id,
                status=status,
                canonical_path=canonical_path,
                revision=f"sha256:{digest[:16]}",
                content_hash=digest,
                workstream=str(raw.get("workstream")) if raw.get("workstream") else None,
                visibility=tuple(str(item) for item in (raw.get("visibility") or ())),
                relationships=_relationships(raw.get("relationships")),
                supersedes=tuple(str(item) for item in (raw.get("supersedes") or ())),
                provenance=(provenance,),
            )
            legacy_fields = dict(raw.get("metadata") or {})
            legacy_fields.update(
                {
                    "research_ingest_schema": RESEARCH_INGEST_SCHEMA_VERSION,
                    "research_kind": kind,
                    "source_type": source_type,
                    "source_id": source_id,
                    "source_revision": source_revision,
                }
            )
            prepared_documents.append(
                CanonicalDocument(
                    artifact=artifact,
                    body=body,
                    policy_hints=dict(raw.get("policy_hints") or {}),
                    legacy_fields=legacy_fields,
                )
            )

        receipts = self.runtime.write_documents(actor, tuple(prepared_documents))
        rows = []
        warnings: list[str] = []
        for receipt in receipts:
            rows.append(
                {
                    "artifact_id": receipt.artifact.artifact_id,
                    "canonical_path": f"memory/{receipt.artifact.canonical_path}",
                    "status": receipt.status.value,
                    "git_revision": receipt.git_revision,
                    "index_revision": receipt.index_revision,
                    "embedding_state": receipt.embedding_state,
                }
            )
            warnings.extend(
                warning for warning in receipt.warnings if warning not in warnings
            )

        statuses = {row["status"] for row in rows}
        overall = (
            WritebackStatus.REJECTED.value
            if statuses == {WritebackStatus.REJECTED.value}
            else WritebackStatus.PARTIAL.value
            if warnings or WritebackStatus.REJECTED.value in statuses or WritebackStatus.PARTIAL.value in statuses
            else WritebackStatus.ACCEPTED.value
        )
        return ResearchIngestReceipt(kind, source_id, overall, tuple(rows), tuple(warnings))
