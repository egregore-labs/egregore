"""Stable domain contracts for the Egregore organizational runtime.

The module intentionally uses only Python's standard library.  It is a domain
boundary, not an infrastructure SDK.  Concrete adapters may use Pydantic,
QMD, Supabase, Neo4j, Git, or a local daemon behind these protocols.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime
from enum import StrEnum
from pathlib import Path
from typing import TYPE_CHECKING, Any, Mapping, Protocol, Sequence, runtime_checkable

if TYPE_CHECKING:
    from .artifacts import CanonicalDocument


JsonObject = Mapping[str, Any]


class ActorKind(StrEnum):
    PERSON = "person"
    AGENT = "agent"
    SERVICE = "service"


class Permission(StrEnum):
    DISCOVER = "discover"
    READ = "read"
    WRITE = "write"
    EXECUTE = "execute"
    SHARE = "share"
    PROMOTE = "promote"
    ADMINISTER = "administer"


class Capability(StrEnum):
    CANONICAL_MEMORY_LOCAL = "canonical-memory.local"
    RETRIEVAL_LOCAL = "retrieval.local"
    EMBEDDINGS_LOCAL = "embeddings.local"
    TELEMETRY_LOCAL = "telemetry.local"
    IDENTITY_BASIC = "identity.basic"
    POLICY_BASIC = "policy.basic"
    INGEST_MANUAL = "ingest.manual"
    SYNC_GIT = "sync.git"
    GRAPH_PROJECTION = "projection.graph"
    CONNECTED_CONTROL_PLANE = "control-plane.connected"
    CONNECTED_MANAGED_INDEX = "retrieval.managed"
    CONNECTED_CONTINUOUS_INGEST = "ingest.continuous"
    CONNECTED_POLICY_ADMIN = "policy.admin"
    CONNECTED_AUDIT_RETENTION = "telemetry.retained"


class RetrievalMode(StrEnum):
    LEX = "lex"
    VEC = "vec"
    HYBRID = "lex+vec"


class TemporalScope(StrEnum):
    CURRENT = "current"
    CURRENT_AND_HISTORICAL = "current+historical"
    HISTORICAL = "historical"


class WritebackStatus(StrEnum):
    ACCEPTED = "accepted"
    REJECTED = "rejected"
    PARTIAL = "partial"


@dataclass(frozen=True, slots=True)
class Serializable:
    """Small common JSON-shape helper for contract fixtures and adapters."""

    def to_dict(self) -> dict[str, Any]:
        def convert(value: Any) -> Any:
            if isinstance(value, StrEnum):
                return value.value
            if isinstance(value, datetime):
                return value.isoformat()
            if isinstance(value, Path):
                return str(value)
            if isinstance(value, tuple):
                return [convert(item) for item in value]
            if isinstance(value, frozenset):
                return sorted(convert(item) for item in value)
            if isinstance(value, dict):
                return {key: convert(item) for key, item in value.items()}
            if hasattr(value, "to_dict"):
                return value.to_dict()
            return value

        return {key: convert(value) for key, value in asdict(self).items()}


@dataclass(frozen=True, slots=True)
class EgregoreProfile(Serializable):
    schema_version: str
    org_id: str
    slug: str
    name: str
    revision: str
    purpose_path: str | None = None
    principles_path: str | None = None
    conventions_path: str | None = None
    default_policy: str = "all-access-v1"
    default_context_budget: int = 8_000


@dataclass(frozen=True, slots=True)
class AccountIdentity(Serializable):
    account_id: str
    display_name: str
    primary_email: str | None = None
    provider_aliases: Mapping[str, str] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class ActorIdentity(Serializable):
    actor_id: str
    kind: ActorKind
    display_name: str
    account_id: str | None = None
    parent_actor_id: str | None = None
    aliases: Mapping[str, str] = field(default_factory=dict)
    # Historical identity references for attribution/search only. Never use
    # these as membership, recipient, policy, or write authority.
    attribution_ids: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class OrgMembership(Serializable):
    membership_id: str
    org_id: str
    actor_id: str
    roles: tuple[str, ...] = ()
    teams: tuple[str, ...] = ()
    status: str = "active"


@dataclass(frozen=True, slots=True)
class Entitlements(Serializable):
    plan: str
    capabilities: frozenset[Capability]
    source: str
    revision: str

    def has(self, capability: Capability) -> bool:
        return capability in self.capabilities


@dataclass(frozen=True, slots=True)
class ActorContext(Serializable):
    account: AccountIdentity | None
    actor: ActorIdentity
    profile: EgregoreProfile
    membership: OrgMembership | None
    entitlements: Entitlements
    session_id: str
    harness: str


@dataclass(frozen=True, slots=True)
class PolicyDecision(Serializable):
    allowed: bool
    actor_id: str
    org_id: str
    permission: Permission
    policy_epoch: str
    resource_ids: tuple[str, ...] = ()
    scopes: tuple[str, ...] = ()
    reasons: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class SourceProvenance(Serializable):
    source_type: str
    source_id: str
    revision: str
    content_hash: str
    observed_at: datetime
    source_uri: str | None = None
    imported_by: str | None = None


@dataclass(frozen=True, slots=True)
class ArtifactRelationship(Serializable):
    relation: str
    target_id: str


@dataclass(frozen=True, slots=True)
class CanonicalArtifact(Serializable):
    schema_version: str
    artifact_id: str
    org_id: str
    artifact_type: str
    title: str
    created_at: datetime
    created_by: str
    status: str
    canonical_path: str
    revision: str
    content_hash: str
    workstream: str | None = None
    visibility: tuple[str, ...] = ()
    relationships: tuple[ArtifactRelationship, ...] = ()
    supersedes: tuple[str, ...] = ()
    provenance: tuple[SourceProvenance, ...] = ()


@dataclass(frozen=True, slots=True)
class IngestSource(Serializable):
    source_type: str
    source_id: str
    revision: str
    content_hash: str
    observed_at: datetime
    title: str | None = None
    source_uri: str | None = None
    visibility: tuple[str, ...] = ()
    metadata: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class RetrievalRequest(Serializable):
    request_id: str
    org_id: str
    actor_id: str
    task: str
    lex: tuple[str, ...]
    vec: tuple[str, ...]
    top_k: int = 6
    mode: RetrievalMode = RetrievalMode.HYBRID
    authorized_scopes: tuple[str, ...] = ()
    allowed_artifact_ids: tuple[str, ...] = ()
    artifact_types: tuple[str, ...] = ()
    workstream: str | None = None
    source_revision: str | None = None
    open_sources: bool = True
    temporal_scope: TemporalScope = TemporalScope.CURRENT
    not_before: datetime | None = None


@dataclass(frozen=True, slots=True)
class RetrievalHit(Serializable):
    artifact_id: str
    canonical_path: str
    rank: int
    score: float
    retrieval_types: tuple[RetrievalMode, ...]
    passage: str | None = None
    passage_id: str | None = None
    revision: str | None = None
    content_hash: str | None = None
    observed_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class RetrievalResult(Serializable):
    request_id: str
    # The mode actually executed; requested_mode preserves the caller's intent.
    mode: RetrievalMode
    hits: tuple[RetrievalHit, ...]
    index_spec_version: str
    index_revision: str
    source_revision: str
    latency_ms: int
    degraded: bool = False
    warnings: tuple[str, ...] = ()
    # Canonical revision the served vector build represents; None when the
    # executed retrieval used no vectors. Trails source_revision while a
    # newer embedding builds — hybrid stays available throughout.
    semantic_source_revision: str | None = None
    requested_mode: RetrievalMode | None = None
    coverage: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class EvidenceItem(Serializable):
    artifact_id: str
    canonical_path: str
    revision: str
    reason: str
    content: str
    token_count: int
    provenance: tuple[SourceProvenance, ...] = ()


@dataclass(frozen=True, slots=True)
class OrgContext(Serializable):
    schema_version: str
    context_id: str
    org_id: str
    actor_id: str
    task: str
    profile_revision: str
    source_revision: str
    policy_epoch: str
    evidence: tuple[EvidenceItem, ...]
    action_permissions: frozenset[Permission]
    token_budget: int
    tokens_used: int
    omissions: tuple[str, ...] = ()
    freshness: Mapping[str, str] = field(default_factory=dict)
    retrieval_mode: str = "unknown"
    degraded: bool = False
    warnings: tuple[str, ...] = ()
    requested_retrieval_mode: str = "unknown"


@dataclass(frozen=True, slots=True)
class TelemetryEvent(Serializable):
    schema_version: str
    event_id: str
    event_type: str
    occurred_at: datetime
    org_id: str
    actor_id: str
    session_id: str
    task_id: str | None = None
    org_revision: str | None = None
    index_spec_version: str | None = None
    metrics: Mapping[str, int | float | bool | str | None] = field(default_factory=dict)
    artifact_ids: tuple[str, ...] = ()
    shared: bool = False


@dataclass(frozen=True, slots=True)
class WritebackEvent(Serializable):
    event_id: str
    artifact: CanonicalArtifact
    permission_decision: PolicyDecision
    status: WritebackStatus
    git_revision: str | None = None
    index_revision: str | None = None
    embedding_state: str | None = None
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class CanonicalFilesWritebackEvent(Serializable):
    """Provenance receipt for existing canonical files without a document envelope."""

    event_id: str
    canonical_path: str
    canonical_paths: tuple[str, ...]
    permission_decision: PolicyDecision
    status: WritebackStatus
    git_revision: str | None = None
    index_revision: str | None = None
    embedding_state: str | None = None
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class RetrieverHealth(Serializable):
    available: bool
    adapter: str
    adapter_version: str
    index_spec_version: str
    index_revision: str
    source_revision: str
    embedding_state: str
    warnings: tuple[str, ...] = ()
    canonical_state_ready: bool = False
    bm25_ready: bool = False
    semantic_ready: bool = False
    runtime_state: str = "runtime_unavailable"
    runtime_pid: int | None = None
    runtime_endpoint: str | None = None
    index_path: str | None = None
    collection: str | None = None
    index_source_revision: str | None = None
    # Canonical revision of the last complete vector build (the revision
    # hybrid retrieval serves while semantic_ready is still false).
    semantic_source_revision: str | None = None


@dataclass(frozen=True, slots=True)
class GraphProjectionHealth(Serializable):
    enabled: bool
    adapter: str
    projection_revision: str | None
    canonical_revision: str
    coverage: float | None = None
    consistent: bool | None = None
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class SyncStatus(Serializable):
    transport: str
    local_revision: str
    remote_revision: str | None
    clean: bool
    warnings: tuple[str, ...] = ()
    current: bool = True
    changed: bool = False
    dirty_count: int = 0


# Retrieval readiness graded for a reader, not a boolean. `stale` means the
# lexical index answers from a snapshot slightly behind the canonical tree;
# `unavailable` means it cannot answer at all.
RETRIEVAL_GRADES = ("ready", "stale", "unavailable")


@dataclass(frozen=True, slots=True)
class SynchronizationReceipt(Serializable):
    """Canonical sync and disposable retrieval readiness as one result.

    `failure_kind` and `remedy` carry the canonical-sync failure as something
    a greeting can act on: the kind is one of the transport's typed kinds (or
    `runtime` for a non-Git exception), the remedy is the one line a person
    should read. `failures` keeps the prose for logs.
    """

    schema_version: str
    status: str
    canonical_sync: SyncStatus | None
    retrieval: RetrieverHealth | None
    canonical_current: bool
    index_source_aligned: bool
    semantic_building: bool
    failures: tuple[str, ...] = ()
    failure_kind: str | None = None
    remedy: str | None = None
    retrieval_grade: str = "unavailable"
    retrieval_detail: str | None = None


@runtime_checkable
class IdentityResolver(Protocol):
    def resolve(self, *, session_id: str, harness: str) -> ActorContext: ...


@runtime_checkable
class ActionAuthorizer(Protocol):
    def authorize_observe(
        self, actor: ActorContext, request: RetrievalRequest
    ) -> PolicyDecision: ...

    def authorize_action(
        self,
        actor: ActorContext,
        permission: Permission,
        resource_ids: Sequence[str] = (),
    ) -> PolicyDecision: ...


@runtime_checkable
class Retriever(Protocol):
    def health(self) -> RetrieverHealth: ...

    def retrieve(self, request: RetrievalRequest) -> RetrievalResult: ...

    def open_source(self, hit: RetrievalHit) -> str: ...

    def update(self, paths: Sequence[str] = ()) -> RetrieverHealth: ...

    def embed_background(self) -> RetrieverHealth: ...


@runtime_checkable
class RetrievalRuntimeControl(Protocol):
    """Optional lifecycle surface for persistent retrieval implementations."""

    def start(self) -> RetrieverHealth: ...

    def shutdown(self) -> RetrieverHealth: ...


@runtime_checkable
class GraphProjection(Protocol):
    def health(self) -> GraphProjectionHealth: ...

    def project(self, artifacts: Sequence[CanonicalArtifact]) -> GraphProjectionHealth: ...

    def rebuild(self) -> GraphProjectionHealth: ...

    def verify(self) -> GraphProjectionHealth: ...


@runtime_checkable
class TelemetrySink(Protocol):
    def emit(self, event: TelemetryEvent) -> None: ...

    def inspect(self, *, limit: int = 100) -> Sequence[TelemetryEvent]: ...

    def export(self, destination: Path) -> Path: ...


@runtime_checkable
class Ingestor(Protocol):
    def normalize(self, source: IngestSource, payload: bytes) -> CanonicalArtifact: ...


@runtime_checkable
class ArtifactWriteback(Protocol):
    def write(
        self,
        actor: ActorContext,
        artifact: CanonicalArtifact,
        content: str,
    ) -> WritebackEvent: ...

    def write_document(
        self,
        actor: ActorContext,
        document: "CanonicalDocument",
    ) -> WritebackEvent: ...

    def write_documents(
        self,
        actor: ActorContext,
        documents: Sequence["CanonicalDocument"],
    ) -> Sequence[WritebackEvent]: ...


@runtime_checkable
class SyncTransport(Protocol):
    def status(self) -> SyncStatus: ...

    def pull(self) -> SyncStatus: ...

    def push(self, *, message: str, paths: Sequence[str] = ()) -> SyncStatus: ...


@runtime_checkable
class OrgContextCompiler(Protocol):
    def observe(
        self,
        actor: ActorContext,
        request: RetrievalRequest,
        *,
        token_budget: int,
    ) -> OrgContext: ...
