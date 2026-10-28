"""Canonical artifact writeback orchestration.

The orchestrator deliberately knows only domain protocols.  Git, QMD, graph,
and telemetry implementations stay behind their respective adapters.
"""

from __future__ import annotations

import uuid
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Callable, Sequence

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalArtifactStore,
    CanonicalDocument,
    artifact_id_from_path,
    canonical_relative_path,
    content_digest,
    store_managed_reason,
    validate_artifact,
)
from .contracts import (
    ActionAuthorizer,
    ActorContext,
    CanonicalArtifact,
    CanonicalFilesWritebackEvent,
    GraphProjection,
    Permission,
    Retriever,
    SyncTransport,
    TelemetryEvent,
    TelemetrySink,
    WritebackEvent,
    WritebackStatus,
)
from .telemetry import TELEMETRY_SCHEMA_VERSION
from .policy import scope_allows_path


def canonical_file_path(memory_root: Path, raw_path: str) -> Path:
    """Resolve an existing file inside canonical memory, never a directory/pathspec."""

    memory = memory_root.resolve()
    source = Path(raw_path)
    if not source.is_absolute():
        if not raw_path or ".." in source.parts:
            raise ValueError("canonical file must be a non-empty path inside memory/")
        if source.parts and source.parts[0] == "memory":
            source = Path(*source.parts[1:])
        source = memory / source
    source = source.resolve()
    try:
        relative = source.relative_to(memory)
    except ValueError as exc:
        raise ValueError("canonical file must be inside memory/") from exc
    if ".git" in relative.parts or not source.is_file():
        raise ValueError("canonical path must name an existing file inside memory/")
    return source


class CanonicalArtifactWriteback:
    """Authorize and persist canonical state, then update disposable projections."""

    def __init__(
        self,
        *,
        authorizer: ActionAuthorizer,
        store: CanonicalArtifactStore,
        sync_transport: SyncTransport,
        retriever: Retriever,
        telemetry: TelemetrySink,
        graph: GraphProjection | None = None,
        clock: Callable[[], datetime] | None = None,
        id_factory: Callable[[], str] | None = None,
    ) -> None:
        self.authorizer = authorizer
        self.store = store
        self.sync_transport = sync_transport
        self.retriever = retriever
        self.telemetry = telemetry
        self.graph = graph
        self.clock = clock or (lambda: datetime.now(UTC))
        self.id_factory = id_factory or (lambda: f"writeback-{uuid.uuid4().hex}")

    def _event_id(self) -> str:
        return self.id_factory()

    def _emit(
        self,
        *,
        actor: ActorContext,
        event_id: str,
        artifact_id: str,
        status: WritebackStatus,
        warning_count: int,
    ) -> None:
        self.telemetry.emit(
            TelemetryEvent(
                schema_version=TELEMETRY_SCHEMA_VERSION,
                event_id=f"telemetry-{event_id}",
                event_type=f"writeback.{status.value}",
                occurred_at=self.clock(),
                org_id=actor.profile.org_id,
                actor_id=actor.actor.actor_id,
                session_id=actor.session_id,
                org_revision=actor.profile.revision,
                metrics={
                    "count": warning_count,
                    "writeback_result": status.value,
                    "success": status is WritebackStatus.ACCEPTED,
                },
                artifact_ids=(artifact_id,) if artifact_id else (),
            )
        )

    def _prepare(
        self,
        actor: ActorContext,
        artifact: CanonicalArtifact,
        content: str,
        *,
        policy_hints: dict[str, object] | None = None,
        source_document: CanonicalDocument | None = None,
    ) -> CanonicalDocument:
        if artifact.org_id != actor.profile.org_id:
            raise ValueError("artifact organization does not match the active actor context")
        path = canonical_relative_path(artifact.canonical_path)
        digest = content_digest(content)
        prepared = replace(
            artifact,
            schema_version=ARTIFACT_SCHEMA_VERSION,
            artifact_id=artifact.artifact_id or artifact_id_from_path(path),
            canonical_path=path,
            created_by=(
                actor.actor.actor_id
                if source_document is not None and source_document.migrated_from is not None
                else artifact.created_by or actor.actor.actor_id
            ),
            revision=artifact.revision or f"sha256:{digest[:16]}",
            content_hash=digest,
        )
        return CanonicalDocument(
            artifact=validate_artifact(prepared, content),
            body=content,
            policy_hints=policy_hints or {},
            legacy_fields=(source_document.legacy_fields if source_document else {}),
            migrated_from=(source_document.migrated_from if source_document else None),
            warnings=(source_document.warnings if source_document else ()),
            replaces_existing=(source_document.replaces_existing if source_document else False),
            expected_revision=(source_document.expected_revision if source_document else None),
        )

    def write(
        self,
        actor: ActorContext,
        artifact: CanonicalArtifact,
        content: str,
    ) -> WritebackEvent:
        return self._write(actor, artifact, content, policy_hints={}, source_document=None)

    def write_document(
        self,
        actor: ActorContext,
        document: CanonicalDocument,
    ) -> WritebackEvent:
        """Richer local API that preserves advisory envelope policy hints."""

        return self._write(
            actor,
            document.artifact,
            document.body,
            policy_hints=dict(document.policy_hints),
            source_document=document,
        )

    def commit_files(
        self,
        actor: ActorContext,
        paths: Sequence[str],
        *,
        memory_root: Path,
        message: str,
    ) -> CanonicalFilesWritebackEvent:
        """Version rendered auxiliary canonical files through the normal transport.

        YAML registries and compatibility ledgers have no artifact envelope to
        normalize or project. Their authorized Git provenance, retrieval refresh,
        and telemetry still belong to the same Runtime writeback boundary.
        """

        if not paths or not message.strip():
            raise ValueError("canonical commit requires paths and a non-empty message")
        memory = memory_root.resolve()
        sources = tuple(dict.fromkeys(canonical_file_path(memory, path) for path in paths))
        canonical_paths = tuple(source.relative_to(memory).as_posix() for source in sources)
        for source, relative in zip(sources, canonical_paths):
            if source.suffix.lower() != ".md":
                continue
            reason = store_managed_reason(source.read_text(encoding="utf-8"))
            if reason is not None:
                raise ValueError(
                    f"{relative} is a store-managed canonical artifact ({reason}); "
                    "write it with adopt, which validates its envelope and lifecycle"
                )
        event_id = self._event_id()
        decision = self.authorizer.authorize_action(actor, Permission.WRITE, canonical_paths)
        if decision.allowed and decision.scopes and any(
            not scope_allows_path(f"memory/{path}", decision.scopes)
            for path in canonical_paths
        ):
            decision = replace(
                decision,
                allowed=False,
                reasons=(*decision.reasons, "canonical write path is outside the actor's authorized scope"),
            )

        warnings = list(decision.reasons) if not decision.allowed else []
        git_revision: str | None = None
        index_revision: str | None = None
        embedding_state: str | None = None
        if decision.allowed:
            try:
                sync = self.sync_transport.push(
                    message=message,
                    paths=tuple(str(source) for source in sources),
                )
                git_revision = sync.local_revision
                warnings.extend(f"sync: {warning}" for warning in sync.warnings)
            except Exception as exc:
                warnings.append(f"sync: {exc}")

            if git_revision is None:
                warnings.append("retrieval: skipped because canonical Git provenance failed")
            else:
                try:
                    health = self.retriever.update(tuple(str(source) for source in sources))
                    index_revision = health.index_revision
                    if not health.available:
                        warnings.append("retrieval: index unavailable after canonical write")
                    warnings.extend(f"retrieval: {warning}" for warning in health.warnings)
                except Exception as exc:
                    warnings.append(f"retrieval update: {exc}")
                try:
                    health = self.retriever.embed_background()
                    embedding_state = health.embedding_state
                    warnings.extend(f"embedding: {warning}" for warning in health.warnings)
                except Exception as exc:
                    warnings.append(f"embedding: {exc}")

        # Canonical Git provenance is the write. Without a local revision there
        # is nothing to report as a partial success, so the caller is told the
        # write was refused rather than left to inspect a null revision.
        status = (
            WritebackStatus.REJECTED if not decision.allowed or git_revision is None
            else WritebackStatus.PARTIAL if warnings else WritebackStatus.ACCEPTED
        )
        try:
            self._emit(
                actor=actor,
                event_id=event_id,
                artifact_id="",
                status=status,
                warning_count=len(warnings),
            )
        except Exception as exc:
            warnings.append(f"telemetry: {exc}")
            if status is WritebackStatus.ACCEPTED:
                status = WritebackStatus.PARTIAL

        return CanonicalFilesWritebackEvent(
            event_id=event_id,
            canonical_path=canonical_paths[0],
            canonical_paths=canonical_paths,
            permission_decision=decision,
            status=status,
            git_revision=git_revision,
            index_revision=index_revision,
            embedding_state=embedding_state,
            warnings=tuple(warnings),
        )

    def write_documents(
        self,
        actor: ActorContext,
        documents: Sequence[CanonicalDocument],
    ) -> tuple[WritebackEvent, ...]:
        """Persist a validated artifact set with one provenance/projection cycle."""

        if not documents:
            return ()
        event_id = self._event_id()
        resources = tuple(
            document.artifact.artifact_id or document.artifact.canonical_path
            for document in documents
        )
        decision = self.authorizer.authorize_action(actor, Permission.WRITE, resources)
        if not decision.allowed:
            warnings = tuple(decision.reasons)
            return tuple(
                WritebackEvent(
                    event_id=f"{event_id}-{index}",
                    artifact=document.artifact,
                    permission_decision=decision,
                    status=WritebackStatus.REJECTED,
                    warnings=warnings,
                )
                for index, document in enumerate(documents, start=1)
            )

        prepared = tuple(
            self._prepare(
                actor,
                document.artifact,
                document.body,
                policy_hints=dict(document.policy_hints),
                source_document=document,
            )
            for document in documents
        )
        if decision.scopes:
            outside = tuple(
                document.artifact.canonical_path
                for document in prepared
                if not scope_allows_path(
                    f"memory/{document.artifact.canonical_path}", decision.scopes
                )
            )
            if outside:
                raise PermissionError("canonical write path is outside the actor's authorized scope")

        # Catch deterministic conflicts before any item changes. persist() checks
        # again so concurrent changes cannot bypass the store's normal rules.
        targets = [self.store.check_write(document) for document in prepared]
        if len(set(targets)) != len(targets):
            raise ValueError("a batch cannot write the same canonical path twice")
        persisted_paths = []
        failure: str | None = None
        for document in prepared:
            try:
                persisted_paths.append(self.store.persist(document))
            except Exception as exc:
                failure = f"persistence failed for {document.artifact.canonical_path}: {type(exc).__name__}: {exc}"
                break
        artifacts = tuple(document.artifact for document in prepared[:len(persisted_paths)])
        warnings: list[str] = [failure] if failure else []
        rejected = tuple(
            WritebackEvent(
                event_id=f"{event_id}-{index}",
                artifact=document.artifact,
                permission_decision=decision,
                status=WritebackStatus.REJECTED,
                warnings=(failure or "not persisted", "not persisted; retry after resolving the batch failure"),
            )
            for index, document in enumerate(prepared[len(persisted_paths):], start=len(persisted_paths) + 1)
        )
        if not persisted_paths:
            return rejected
        git_revision: str | None = None
        index_revision: str | None = None
        embedding_state: str | None = None

        try:
            sync = self.sync_transport.push(
                message=f"docs(memory): capture {len(artifacts)} artifacts",
                paths=tuple(str(path) for path in persisted_paths),
            )
            git_revision = sync.local_revision
            warnings.extend(f"sync: {warning}" for warning in sync.warnings)
        except Exception as exc:
            warnings.append(f"sync: {exc}")

        if git_revision is None:
            warnings.append("retrieval: skipped because canonical Git provenance failed")
        else:
            try:
                health = self.retriever.update(tuple(str(path) for path in persisted_paths))
                index_revision = health.index_revision
                if not health.available:
                    warnings.append("retrieval: index unavailable after canonical write")
                warnings.extend(f"retrieval: {warning}" for warning in health.warnings)
            except Exception as exc:
                warnings.append(f"retrieval update: {exc}")
            try:
                health = self.retriever.embed_background()
                embedding_state = health.embedding_state
                warnings.extend(f"embedding: {warning}" for warning in health.warnings)
            except Exception as exc:
                warnings.append(f"embedding: {exc}")

        if self.graph is not None and git_revision is not None:
            try:
                health = self.graph.project(artifacts)
                if health.enabled:
                    warnings.extend(f"optional hosted index: {warning}" for warning in health.warnings)
                    if health.consistent is False:
                        warnings.append("optional hosted index: inconsistent with canonical state")
            except Exception as exc:
                warnings.append(f"optional hosted index: {exc}")

        status = WritebackStatus.PARTIAL if warnings else WritebackStatus.ACCEPTED
        receipts = tuple(
            WritebackEvent(
                event_id=f"{event_id}-{index}",
                artifact=artifact,
                permission_decision=decision,
                status=status,
                git_revision=git_revision,
                index_revision=index_revision,
                embedding_state=embedding_state,
                warnings=tuple(warnings),
            )
            for index, artifact in enumerate(artifacts, start=1)
        )
        for receipt in receipts:
            try:
                self._emit(
                    actor=actor,
                    event_id=receipt.event_id,
                    artifact_id=receipt.artifact.artifact_id,
                    status=status,
                    warning_count=len(warnings),
                )
            except Exception as exc:
                warnings.append(f"telemetry: {exc}")
                status = WritebackStatus.PARTIAL
        if status is WritebackStatus.PARTIAL and any(
            receipt.status is WritebackStatus.ACCEPTED for receipt in receipts
        ):
            receipts = tuple(replace(receipt, status=status, warnings=tuple(warnings)) for receipt in receipts)
        return receipts + rejected

    def _write(
        self,
        actor: ActorContext,
        artifact: CanonicalArtifact,
        content: str,
        *,
        policy_hints: dict[str, object],
        source_document: CanonicalDocument | None,
    ) -> WritebackEvent:
        event_id = self._event_id()
        resource = artifact.artifact_id or artifact.canonical_path
        decision = self.authorizer.authorize_action(actor, Permission.WRITE, (resource,))
        if not decision.allowed:
            warnings = tuple(decision.reasons)
            try:
                self._emit(
                    actor=actor,
                    event_id=event_id,
                    artifact_id=artifact.artifact_id,
                    status=WritebackStatus.REJECTED,
                    warning_count=len(warnings),
                )
            except Exception:
                warnings += ("telemetry: failed to record denied writeback",)
            return WritebackEvent(
                event_id=event_id,
                artifact=artifact,
                permission_decision=decision,
                status=WritebackStatus.REJECTED,
                warnings=warnings,
            )

        path = canonical_relative_path(artifact.canonical_path)
        if decision.scopes and not scope_allows_path(f"memory/{path}", decision.scopes):
            raise PermissionError("canonical write path is outside the actor's authorized scope")

        document = self._prepare(
            actor,
            artifact,
            content,
            policy_hints=policy_hints,
            source_document=source_document,
        )
        persisted_path = self.store.persist(document)
        artifact = document.artifact

        warnings: list[str] = []
        git_revision: str | None = None
        index_revision: str | None = None
        embedding_state: str | None = None

        try:
            sync = self.sync_transport.push(
                message=f"docs(memory): capture {artifact.artifact_type}",
                paths=(str(persisted_path),),
            )
            git_revision = sync.local_revision
            warnings.extend(f"sync: {warning}" for warning in sync.warnings)
        except Exception as exc:
            warnings.append(f"sync: {exc}")

        if git_revision is None:
            warnings.append("retrieval: skipped because canonical Git provenance failed")
        else:
            try:
                health = self.retriever.update((str(persisted_path),))
                index_revision = health.index_revision
                if not health.available:
                    warnings.append("retrieval: index unavailable after canonical write")
                warnings.extend(f"retrieval: {warning}" for warning in health.warnings)
            except Exception as exc:
                warnings.append(f"retrieval update: {exc}")

            try:
                health = self.retriever.embed_background()
                embedding_state = health.embedding_state
                warnings.extend(f"embedding: {warning}" for warning in health.warnings)
            except Exception as exc:
                warnings.append(f"embedding: {exc}")

        if self.graph is not None and git_revision is not None:
            try:
                health = self.graph.project((artifact,))
                if health.enabled:
                    warnings.extend(f"optional hosted index: {warning}" for warning in health.warnings)
                    if health.consistent is False:
                        warnings.append("optional hosted index: inconsistent with canonical state")
            except Exception as exc:
                warnings.append(f"optional hosted index: {exc}")

        # A write without canonical Git provenance is not a partial success:
        # nothing is versioned, so the receipt reports a refusal.
        status = (
            WritebackStatus.REJECTED if git_revision is None
            else WritebackStatus.PARTIAL if warnings else WritebackStatus.ACCEPTED
        )
        try:
            self._emit(
                actor=actor,
                event_id=event_id,
                artifact_id=artifact.artifact_id,
                status=status,
                warning_count=len(warnings),
            )
        except Exception as exc:
            warnings.append(f"telemetry: {exc}")
            if status is WritebackStatus.ACCEPTED:
                status = WritebackStatus.PARTIAL

        return WritebackEvent(
            event_id=event_id,
            artifact=artifact,
            permission_decision=decision,
            status=status,
            git_revision=git_revision,
            index_revision=index_revision,
            embedding_state=embedding_state,
            warnings=tuple(warnings),
        )
