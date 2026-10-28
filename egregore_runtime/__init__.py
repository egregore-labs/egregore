"""Public Egregore Runtime v1 contracts.

Infrastructure adapters live outside this package.  Harnesses and rituals
should depend on these domain types and protocols rather than QMD, Neo4j,
Supabase, or Git implementation details.
"""

from .contracts import (
    AccountIdentity,
    ActionAuthorizer,
    ActorContext,
    ActorIdentity,
    ActorKind,
    ArtifactRelationship,
    ArtifactWriteback,
    CanonicalArtifact,
    Capability,
    Entitlements,
    EgregoreProfile,
    EvidenceItem,
    GraphProjection,
    GraphProjectionHealth,
    IdentityResolver,
    IngestSource,
    Ingestor,
    OrgContext,
    OrgContextCompiler,
    OrgMembership,
    Permission,
    PolicyDecision,
    RetrievalHit,
    RetrievalMode,
    RetrievalRequest,
    RetrievalResult,
    Retriever,
    RetrieverHealth,
    RetrievalRuntimeControl,
    SourceProvenance,
    SyncStatus,
    SyncTransport,
    SynchronizationReceipt,
    TelemetryEvent,
    TelemetrySink,
    TemporalScope,
    WritebackEvent,
    WritebackStatus,
)
from .errors import AuthorizationDenied, ContextBudgetError, EgregoreRuntimeError
from .observe import DefaultOrgContextCompiler
from .policy import ActorGrant, StaticPolicy, all_access_dogfood_policy, scope_allows_path
from .telemetry import (
    ALLOWED_METRIC_KEYS,
    TELEMETRY_SCHEMA_VERSION,
    HttpSharedTelemetrySink,
    LocalTelemetrySink,
    SharedTelemetrySink,
    TelemetryPrivacyError,
    TelemetryShareError,
    TelemetrySharePlan,
    TelemetryShareReceipt,
    TelemetryStatus,
    event_from_mapping,
    make_event,
    validate_event,
)
from .notifications import (
    EXACT_NOTIFICATION_CONFIRMATION,
    NOTIFICATION_BINDING_SCHEMA,
    NotificationBinding,
    NotificationError,
    NotificationService,
    NotificationTransport,
)
from .entitlements import (
    ACTIVE_ENTITLEMENT_STATUSES,
    CAPABILITY_REVISION,
    LOCAL_CAPABILITIES,
    PLAN_CAPABILITIES,
    resolve_entitlements,
)
from .identity import (
    IDENTITY_SCHEMA,
    LocalIdentityResolver,
    OrganizationMemberPresentation,
    actor_identity,
    actor_presentation_name,
    control_plane_identity_from_records,
    initialize_local_instance_identity,
    migrate_local_identity_state,
    new_identity_id,
    organization_member_presentations,
    reconcile_control_plane_identity,
)
from .onboarding import (
    ONBOARDING_SCHEMA,
    OnboardingPlan,
    OnboardingService,
    OnboardingSnapshot,
    OnboardingStep,
    onboarding_plan,
)
from .invitations import (
    InvitationReceipt,
    InvitationService,
    InvitationTransport,
    InvitationTransportResult,
)
from .profile import (
    CONFIG_SCHEMA,
    DEFAULT_CONTEXT_BUDGET,
    PROFILE_SCHEMA,
    ProfileConfigError,
    default_profile_config,
    initialize_org_config,
    load_profile,
    new_org_id,
    render_identity_document,
)
from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    ArtifactConflictError,
    ArtifactSchemaError,
    canonical_artifact_id,
    CanonicalArtifactStore,
    CanonicalDocument,
    LocalMarkdownArtifactStore,
    parse_canonical_markdown,
    render_canonical_markdown,
)
from .graph import DisabledGraphProjection, LegacyGraphProjection, graph_projection
from .ingest import (
    CanonicalIngestRegistry,
    CanonicalIngestWorkflow,
    IngestPhase,
    IngestRegistrationReceipt,
    IngestReceipt,
    IngestReview,
    IngestWorkflow,
    LocalIngestJournal,
    LocalQuarantine,
    NormalizedIngest,
)
from .runtime import EgregoreRuntime, local_runtime
from .questions import (
    QUESTION_SCHEMA_VERSION,
    CanonicalQuestionService,
    PendingQuestion,
    QuestionLifecycleError,
)
from .issues import (
    ISSUE_SCHEMA_VERSION,
    ISSUE_STATUSES,
    CanonicalIssueService,
    IssueSnapshot,
    parse_issue_markdown,
)
from .knowledge import (
    KNOWLEDGE_SCHEMA_VERSION,
    PRIVATE_NOTE_SCHEMA_VERSION,
    CanonicalKnowledgeService,
    KnowledgeCaptureError,
    PersonalNote,
    PersonalNoteService,
)
from .research_ingest import (
    RESEARCH_INGEST_SCHEMA_VERSION,
    CanonicalResearchIngestService,
    ResearchIngestError,
    ResearchIngestReceipt,
)
from .quests import (
    QUEST_STATUSES,
    CanonicalQuestService,
    QuestSnapshot,
    parse_quest_markdown,
)
from .todos import (
    TODO_STATUSES,
    CanonicalTodoService,
    TodoSnapshot,
    parse_todo_markdown,
)
from .status import (
    STATUS_INDEX_SPEC_VERSION,
    STATUS_SCHEMA_VERSION,
    CanonicalStatusSnapshotService,
)
from .sync import GitSyncError, LocalGitSyncTransport
from .writeback import CanonicalArtifactWriteback
from .lifecycle import (
    AttentionState,
    AuthorityState,
    CanonicalLifecycleService,
    LIFECYCLE_INDEX_SPEC,
    LifecycleAction,
    LifecycleError,
    LifecyclePlan,
    LifecyclePolicy,
    LifecycleRecord,
    LifecycleTransition,
    ObligationState,
)
from .threads import (
    THREAD_CONFIRMATION,
    THREAD_EVENT_SCHEMA_VERSION,
    THREAD_SCHEMA_VERSION,
    CanonicalThreadService,
    ThreadError,
    ThreadFoldReceipt,
    ThreadSnapshot,
    parse_thread_markdown,
)
from .scrolls import (
    EXACT_SHARE_CONFIRMATION,
    SCROLL_EVENT_SCHEMA_VERSION,
    SCROLL_SCHEMA_VERSION,
    SCROLL_SHARE_SCHEMA_VERSION,
    CanonicalScrollService,
    ScrollError,
    ScrollEventReceipt,
    ScrollSharePlan,
    ScrollShareReceipt,
    ScrollSnapshot,
    parse_scroll_markdown,
    scroll_turn_id,
)

__all__ = [name for name in globals() if not name.startswith("_")]
