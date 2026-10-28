"""On-demand canonical eligibility. No new index or cached authorization.

Only Runtime-authorized callers construct these snapshots. The backend receives
canonical paths and content hashes, never authority supplied by a model.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import UTC
import hashlib
import json
import time
from typing import Any, Callable

from .contracts import TemporalScope
from .errors import AuthorizationDenied, EgregoreRuntimeError
from .lifecycle import AuthorityState
from .policy import scope_allows_path

ELIGIBILITY_VERSION = 'egregore-eligibility/v1'
MAX_DOCUMENTS = 50_000


def is_internal_event(canonical_path, artifact_type=None):
    return artifact_type in ('lifecycle-event', 'thread-output-event') or canonical_path.startswith(
        ('memory/lifecycle/events/', 'memory/scrolls/.events/', 'memory/threads/.events/'))


@dataclass(frozen=True)
class EligibleDocument:
    canonical_path: str
    metadata: Any

    def to_wire(self):
        return {'path': self.canonical_path.removeprefix('memory/'),
                'hash': self.metadata.content_hash}


@dataclass(frozen=True)
class EligibilitySnapshot:
    source_revision: str
    revision: str
    documents: tuple[EligibleDocument, ...]
    unknown_dates: int
    warnings: tuple[str, ...]
    latency_ms: int

    def to_wire(self):
        return {'version': ELIGIBILITY_VERSION, 'revision': self.revision,
                'source_revision': self.source_revision,
                'documents': [document.to_wire() for document in self.documents]}


def build_eligibility(retriever, request, *, actor, admin_gate=None, lifecycle=None,
                      path_filter: Callable[[str], bool] | None = None,
                      metadata_filter: Callable[[str, Any], bool] | None = None):
    """Read current scoped files once and fence the resulting view by revision.

    Preserve the existing filesystem enumeration (including ignored Markdown);
    Git supplies revision identity rather than silently redefining membership.
    """
    if not request.authorized_scopes:
        raise AuthorizationDenied('eligibility requires an authorized scope')
    started = time.monotonic()
    revision = retriever.source_revision()
    root = retriever.memory_root.resolve()
    rows = []
    warnings = []
    is_admin = admin_gate is None or admin_gate.actor_is_admin(actor)
    for path in sorted(root.rglob('*.md')):
        canonical = 'memory/' + path.relative_to(root).as_posix()
        if not scope_allows_path(canonical, request.authorized_scopes):
            continue
        resolved = path.resolve()
        if not path.is_file() or not resolved.is_relative_to(root):
            continue
        if not scope_allows_path('memory/' + resolved.relative_to(root).as_posix(), request.authorized_scopes):
            continue
        if path_filter and not path_filter(canonical):
            continue
        if not is_admin and admin_gate.path_is_admin(canonical):
            continue
        metadata = retriever.describe_source(canonical)
        if request.allowed_artifact_ids and metadata.artifact_id not in request.allowed_artifact_ids:
            continue
        if request.artifact_types and metadata.artifact_type not in request.artifact_types:
            continue
        if request.workstream and metadata.workstream != request.workstream:
            continue
        if is_internal_event(canonical, metadata.artifact_type) and not request.artifact_types:
            continue
        rows.append(EligibleDocument(canonical, metadata))
        if len(rows) > MAX_DOCUMENTS:
            raise EgregoreRuntimeError('eligible inventory exceeds 50000 documents; narrow the authorized scope or filters')

    lifecycle_by_path = {}
    if lifecycle is not None:
        try:
            lifecycle_by_path, _ = lifecycle.resolve_paths(
                [row.canonical_path for row in rows], source_revision=revision,
                authorized_scopes=request.authorized_scopes,
                allowed_artifact_ids=request.allowed_artifact_ids)
        except Exception as error:
            # Preserve Observe's advisory lifecycle fallback, but do not claim
            # complete temporal-authority filtering when it was unavailable.
            warnings.append(f'lifecycle-unavailable:{type(error).__name__}')
    eligible = []
    unknown_dates = 0
    for row in rows:
        metadata = row.metadata
        record = lifecycle_by_path.get(row.canonical_path)
        if record is not None:
            if record.artifact_type == 'lifecycle-event' and 'lifecycle-event' not in request.artifact_types:
                continue
            historical = record.authority_state in {AuthorityState.SUPERSEDED, AuthorityState.HISTORICAL}
            if request.temporal_scope is TemporalScope.CURRENT and historical:
                continue
            if request.temporal_scope is TemporalScope.HISTORICAL and not historical:
                continue
            if metadata.observed_at is None:
                metadata = replace(metadata, observed_at=record.created_at,
                                   date_provenance='lifecycle.created_at')
        if metadata.observed_at is None:
            unknown_dates += 1
        if request.not_before is not None:
            if metadata.observed_at is None or metadata.observed_at.astimezone(UTC) < request.not_before.astimezone(UTC):
                continue
        if metadata_filter and not metadata_filter(row.canonical_path, metadata):
            continue
        eligible.append(EligibleDocument(row.canonical_path, metadata))
    if retriever.source_revision() != revision:
        raise EgregoreRuntimeError('sources changed while constructing eligibility; retry the operation')
    material = [ELIGIBILITY_VERSION, revision, request.org_id, request.actor_id,
                [(row.canonical_path, row.metadata.content_hash) for row in eligible]]
    digest = hashlib.sha256(json.dumps(material, separators=(',', ':')).encode()).hexdigest()
    return EligibilitySnapshot(revision, digest, tuple(eligible), unknown_dates,
                               tuple(warnings), round((time.monotonic()-started)*1000))
