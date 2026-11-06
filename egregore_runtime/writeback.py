"""Canonical artifact writeback orchestration.

The orchestrator deliberately knows only domain protocols.  Git, QMD, graph,
and telemetry implementations stay behind their respective adapters.
"""

from __future__ import annotations

import contextlib
import errno
import os
import stat
import time
import uuid
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import Callable, Sequence

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    ArtifactConflictError,
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
from .policy import allows
from .held import package


_LINK_REFUSAL = "canonical file path must not pass through a symbolic link"
_NO_FOLLOW = getattr(os, "O_NOFOLLOW", 0)
_FOLDER = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | _NO_FOLLOW
_STAGING = ".staging"
_IGNORE_ALL = b"*\n"
_STALE_STAGING_SECONDS = 24 * 60 * 60
# What a link failure means when the filesystem has no hard links at all.
_NO_HARD_LINKS = frozenset({errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EXDEV, errno.ENOSYS})
# The calls creating a file makes through folder descriptors, captured at
# import so that a wrapped function is not mistaken for a missing one.
_DIR_FD_CALLS = tuple(getattr(os, name, None) for name in ("open", "mkdir", "link", "stat", "unlink"))
_LINK, _LISTDIR = getattr(os, "link", None), os.listdir


class UnsupportedPlatformError(OSError):
    """This platform cannot walk folders and link files through descriptors,
    so it cannot create a file safely. Checked before anything is written."""


class NoHardLinksError(OSError):
    """This filesystem has no hard links, so a file cannot appear complete
    without replacing another. The staged copy is removed; nothing is written."""


def require_descriptor_calls() -> None:
    """Refuse, before any write, a platform (Windows, for one) without the
    descriptor-relative calls creating a file depends on."""

    if not (
        all(call in os.supports_dir_fd for call in _DIR_FD_CALLS)
        and _LINK in os.supports_follow_symlinks
        and _LISTDIR in os.supports_fd
    ):
        raise UnsupportedPlatformError(
            "this platform cannot create files through folder descriptors; nothing was written"
        )


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


def canonical_new_file_path(memory_root: Path, raw_path: str) -> tuple[Path, str]:
    """Name a file to create inside canonical memory, reached through no link.

    Authorization names the lexical path, so the file written must be that
    path: a symbolic link anywhere below memory/ (a directory linked to
    ../private, or the file itself) would carry the write somewhere else.
    """

    memory = memory_root.resolve()
    relative = canonical_relative_path(raw_path.strip().removeprefix("memory/"))
    parts = PurePosixPath(relative).parts
    if ".git" in parts:
        raise ValueError("canonical file must be inside memory/, outside .git")
    if relative.casefold().endswith(".md"):
        raise ValueError("Markdown is written through the artifact store, which checks its envelope")
    target = memory
    for part in parts:
        target = target / part
        if target.is_symlink():
            raise ValueError(_LINK_REFUSAL)
    return target, relative


def _open_below(name: str, folder: int, flags: int, mode: int = 0o777) -> int:
    """Open ``name`` inside the open folder ``folder``, never through a link."""

    try:
        return os.open(name, flags | _NO_FOLLOW, mode, dir_fd=folder)
    except FileNotFoundError:
        raise
    except OSError:
        with contextlib.suppress(OSError):
            if stat.S_ISLNK(os.stat(name, dir_fd=folder, follow_symlinks=False).st_mode):
                raise ValueError(_LINK_REFUSAL) from None
        raise


def _open_folders(memory: Path, names: Sequence[str]) -> int:
    """The folder a new file goes in, reached from the memory root one name at
    a time through open descriptors, creating missing folders and following
    no link. No path string is resolved after this walk, so a folder swapped
    for a link while it runs cannot carry the write elsewhere."""

    folder = os.open(memory, _FOLDER)
    try:
        for name in names:
            try:
                child = _open_below(name, folder, _FOLDER)
            except FileNotFoundError:
                with contextlib.suppress(FileExistsError):
                    os.mkdir(name, 0o755, dir_fd=folder)
                child = _open_below(name, folder, _FOLDER)
            os.close(folder)
            folder = child
    except BaseException:
        os.close(folder)
        raise
    return folder


def _open_staging(memory: Path, top: Sequence[str]) -> int:
    """The folder a file is written in before it is published: ``.staging``
    in the destination's top folder (``taste/.staging/`` for an event), on
    the destination's filesystem, reached by the same descriptor walk. Its
    ``.gitignore`` holds ``*`` and is written before anything is staged, so
    Git and autosave's ``git add -A`` never see the folder or anything in
    it, the ``.gitignore`` included. Staged files a crash left there more
    than a day ago are removed."""

    staging = _open_folders(memory, (*top, _STAGING))
    try:
        if _read_below(".gitignore", staging) != _IGNORE_ALL:
            # Written in place, never emptied first: two first writers both
            # put the same bytes at the start, so a file that already
            # ignores everything keeps doing so while the other stages.
            ignore = _open_below(".gitignore", staging, os.O_WRONLY | os.O_CREAT, 0o644)
            try:
                os.pwrite(ignore, _IGNORE_ALL, 0)
                os.ftruncate(ignore, len(_IGNORE_ALL))
                os.fsync(ignore)
            finally:
                os.close(ignore)
    except BaseException:
        os.close(staging)
        raise
    cutoff = time.time() - _STALE_STAGING_SECONDS
    with contextlib.suppress(OSError):
        for name in os.listdir(staging):
            with contextlib.suppress(OSError):
                found = os.stat(name, dir_fd=staging, follow_symlinks=False)
                if name.endswith(".tmp") and stat.S_ISREG(found.st_mode) and found.st_mtime < cutoff:
                    os.unlink(name, dir_fd=staging)
    return staging


def _read_below(name: str, folder: int) -> bytes | None:
    try:
        descriptor = _open_below(name, folder, os.O_RDONLY)
    except FileNotFoundError:
        return None
    with open(descriptor, "rb") as handle:
        return handle.read()


def _publish(data: bytes, name: str, folder: int, staging: int) -> os.stat_result:
    """Write and flush ``data`` in staging, then link it into ``folder`` as
    ``name``: the file appears complete or not at all. A link never replaces
    a name, so ``FileExistsError`` means another writer published first. A
    filesystem without hard links refuses; a rename would replace a name."""

    staged = f"{uuid.uuid4().hex}.tmp"
    descriptor = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL | _NO_FOLLOW, 0o644, dir_fd=staging)
    try:
        with open(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            written = os.fstat(handle.fileno())
        try:
            os.link(staged, name, src_dir_fd=staging, dst_dir_fd=folder, follow_symlinks=False)
        except OSError as error:
            if error.errno in _NO_HARD_LINKS:
                raise NoHardLinksError(
                    "this memory folder's filesystem cannot create files safely (no hard links); "
                    "nothing was written"
                ) from error
            raise
        try:
            os.fsync(folder)  # the new name survives a power loss
        except OSError as error:
            if error.errno not in (errno.EINVAL, errno.ENOTSUP):
                raise
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(staged, dir_fd=staging)
    return written


_ECHOED = ("artifact_type", "title", "created_by", "status", "workstream", "visibility", "relationships", "supersedes",
           "provenance")


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

    def _echo(self, receipt, root: Path | None = None):
        """A receipt as its writer reads it back: the names of documents held from them leave its title and
        warnings (a sync or index message can name another file); when that fails, both are dropped."""
        root = root if root is not None else getattr(self.store, "root", None)
        if root is None:
            return receipt
        artifact = getattr(receipt, "artifact", None)  # an existing document's metadata comes from memory
        shown = {"warnings": receipt.warnings, **({name: getattr(artifact, name) for name in _ECHOED} if artifact else {})}
        kept = package(receipt.permission_decision, shown, root=Path(root))
        if kept == shown:
            return receipt
        kept = kept or {name: type(value)() for name, value in shown.items()}
        warnings = kept.pop("warnings")
        return replace(replace(receipt, artifact=replace(artifact, **kept)) if artifact else receipt, warnings=warnings)

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
            expected_sha256=(source_document.expected_sha256 if source_document else None),
        )

    def write(
        self,
        actor: ActorContext,
        artifact: CanonicalArtifact,
        content: str,
    ) -> WritebackEvent:
        return self._echo(self._write(actor, artifact, content, policy_hints={}, source_document=None))

    def write_document(
        self,
        actor: ActorContext,
        document: CanonicalDocument,
        *,
        message: str | None = None,
    ) -> WritebackEvent:
        """Richer local API that preserves advisory envelope policy hints.

        ``message`` replaces the commit's own ``docs(memory): capture <type>``
        (an edit names its file and why); without it nothing changes."""

        return self._echo(self._write(
            actor,
            document.artifact,
            document.body,
            policy_hints=dict(document.policy_hints),
            source_document=document,
            message=message,
        ))

    def commit_files(
        self,
        actor: ActorContext,
        paths: Sequence[str],
        *,
        memory_root: Path,
        message: str,
        refresh_retrieval: bool = True,
    ) -> CanonicalFilesWritebackEvent:
        """Version rendered auxiliary canonical files through the normal transport.

        YAML registries and compatibility ledgers have no artifact envelope to
        normalize or project. Their authorized Git provenance, retrieval refresh,
        and telemetry still belong to the same Runtime writeback boundary.
        ``refresh_retrieval=False`` is for files search never reads: retrieval
        indexes Markdown, so there is nothing to refresh, and its next update
        records the new revision without rescanning an unchanged corpus.
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
        if decision.allowed and any(
            not allows(decision, f"memory/{path}", "write", root=memory)
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

            if refresh_retrieval and git_revision is None:
                warnings.append("retrieval: skipped because canonical Git provenance failed")
            elif refresh_retrieval:
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

        return self._echo(CanonicalFilesWritebackEvent(
            event_id=event_id,
            canonical_path=canonical_paths[0],
            canonical_paths=canonical_paths,
            permission_decision=decision,
            status=status,
            git_revision=git_revision,
            index_revision=index_revision,
            embedding_state=embedding_state,
            warnings=tuple(warnings),
        ), memory)

    def create_file(
        self,
        actor: ActorContext,
        raw_path: str,
        content: str,
        *,
        memory_root: Path,
        message: str,
    ) -> CanonicalFilesWritebackEvent:
        """Create one immutable canonical file, then version it.

        The append-only lifecycle for records search never reads, such as one
        JSON file per event. The content is written and flushed in a staging
        folder Git ignores, on the same filesystem, then linked into place,
        so the file appears complete or not at all: an autosave, a rebase or
        a crash never sees it partly written. A platform or filesystem that
        cannot do this is refused with nothing written, never served by a
        replacing rename. A link never replaces a name, so a rebase cannot
        overwrite it and two clones never write the same path. A path already
        holding exactly this content (a retry, or a file an autosave committed
        first) is only versioned again; different content is an
        ``ArtifactConflictError``. Authorization comes before any write. No
        step below memory/ may be a symbolic link: the path is checked before
        authorization, the folders are then walked through descriptors that
        follow no link, and the path is checked again before Git receives it.
        Retrieval indexes Markdown only, so no index refresh is asked for.
        """

        if not message.strip():
            raise ValueError("canonical file creation requires a non-empty message")
        require_descriptor_calls()
        memory = memory_root.resolve()
        target, relative = canonical_new_file_path(memory, raw_path)
        event_id = self._event_id()
        decision = self.authorizer.authorize_action(actor, Permission.WRITE, (relative,))
        # Revalidate after authorization: it may have swapped a parent for a symlink.
        canonical_new_file_path(memory, relative)
        if decision.allowed and not allows(decision, f"memory/{relative}", "write", root=memory):
            decision = replace(
                decision,
                allowed=False,
                reasons=(*decision.reasons, "canonical write path is outside the actor's authorized scope"),
            )
        if not decision.allowed:
            warnings = tuple(decision.reasons)
            try:
                self._emit(
                    actor=actor, event_id=event_id, artifact_id="",
                    status=WritebackStatus.REJECTED, warning_count=len(warnings),
                )
            except Exception:
                warnings += ("telemetry: failed to record denied writeback",)
            return CanonicalFilesWritebackEvent(
                event_id=event_id,
                canonical_path=relative,
                canonical_paths=(relative,),
                permission_decision=decision,
                status=WritebackStatus.REJECTED,
                warnings=warnings,
            )

        data = content.encode("utf-8")
        *names, name = PurePosixPath(relative).parts
        folder = _open_folders(memory, names)
        written = None
        try:
            existing = _read_below(name, folder)
            if existing is None:
                staging = _open_staging(memory, names[:1])
                try:
                    written = _publish(data, name, folder, staging)
                except FileExistsError:
                    existing = _read_below(name, folder)
                finally:
                    os.close(staging)
            if existing is not None and existing != data:
                raise ArtifactConflictError(
                    f"{relative} already holds different content; an immutable file is never replaced"
                )
            try:
                # Git receives the path, so the path must still name these
                # bytes through no link; else what was just published goes.
                canonical_new_file_path(memory, relative)
                with open(os.open(target, os.O_RDONLY | _NO_FOLLOW), "rb") as handle:
                    if handle.read() != data:
                        raise ArtifactConflictError(f"{relative} changed while it was written")
            except BaseException:
                with contextlib.suppress(OSError):
                    found = os.stat(name, dir_fd=folder, follow_symlinks=False)
                    if written is not None and (found.st_dev, found.st_ino) == (written.st_dev, written.st_ino):
                        os.unlink(name, dir_fd=folder)
                raise
        finally:
            os.close(folder)
        return self.commit_files(
            actor, (str(target),), memory_root=memory, message=message, refresh_retrieval=False,
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
        outside = tuple(document.artifact.canonical_path for document in prepared
                        if not allows(decision, f"memory/{document.artifact.canonical_path}", "write", root=self.store.root))
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
        return tuple(self._echo(receipt) for receipt in receipts + rejected)

    def _write(
        self,
        actor: ActorContext,
        artifact: CanonicalArtifact,
        content: str,
        *,
        policy_hints: dict[str, object],
        source_document: CanonicalDocument | None,
        message: str | None = None,
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
        if not allows(decision, f"memory/{path}", "write", root=self.store.root):
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
                message=message or f"docs(memory): capture {artifact.artifact_type}",
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
