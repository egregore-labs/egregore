"""Cohesive harness-facing Egregore Runtime.

Harness adapters use this facade for identity, authorization, Observe,
canonical writeback, and telemetry. Infrastructure-specific classes are
composed here and are not part of the harness contract.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import hashlib
import os
from pathlib import Path
from typing import Callable, Sequence
from uuid import uuid4

from .adapters.qmd import QmdLocalRetriever
from .admin_gate import AdminGate, document_is_admin
from .artifacts import (
    CanonicalArtifactStore,
    CanonicalDocument,
    LocalMarkdownArtifactStore,
    artifact_id_from_path,
    canonical_artifact_id,
)
from .contracts import (
    ActionAuthorizer,
    ActorContext,
    CanonicalArtifact,
    CanonicalFilesWritebackEvent,
    GraphProjection,
    IdentityResolver,
    OrgContext,
    Permission,
    PolicyDecision,
    RetrievalHit,
    RetrievalMode,
    RetrievalRequest,
    RetrievalRuntimeControl,
    Retriever,
    RetrieverHealth,
    SyncTransport,
    SynchronizationReceipt,
    TelemetryEvent,
    TelemetrySink,
    WritebackEvent,
    WritebackStatus,
)
from .errors import AuthorizationDenied
from .graph import DisabledGraphProjection
from .identity import LocalIdentityResolver
from .ingest import CanonicalIngestRegistry, IngestRegistrationReceipt
from .lifecycle import (
    CanonicalLifecycleService,
    LifecycleAction,
    LifecycleError,
    LifecyclePlan,
    LifecycleRecord,
)
from .observe import DefaultOrgContextCompiler
from .sync_health import grade_retrieval, sync_remedy
from .policy import all_access_dogfood_policy, scope_allows_path
from .sync import LocalGitSyncTransport
from .telemetry import LocalTelemetrySink, TELEMETRY_SCHEMA_VERSION
from .writeback import CanonicalArtifactWriteback


PolicyFactory = Callable[[ActorContext], ActionAuthorizer]


@dataclass(slots=True)
class EgregoreRuntime:
    """Stable organizational boundary exposed to harness adapters."""

    identity: IdentityResolver
    retriever: Retriever
    telemetry: TelemetrySink
    store: CanonicalArtifactStore
    sync_transport: SyncTransport
    graph: GraphProjection | None
    policy_factory: PolicyFactory
    lifecycle: CanonicalLifecycleService | None = None
    canonical_root: Path | None = None
    admin_gate: AdminGate | None = None
    instance_root: Path | None = None

    def resolve_actor(self, *, session_id: str, harness: str) -> ActorContext:
        return self.identity.resolve(session_id=session_id, harness=harness)

    def authorize(
        self,
        actor: ActorContext,
        permission: Permission,
        resource_ids: tuple[str, ...] = (),
    ) -> PolicyDecision:
        return self.policy_factory(actor).authorize_action(actor, permission, resource_ids)

    def observe(
        self,
        actor: ActorContext,
        request: RetrievalRequest,
        *,
        token_budget: int | None = None,
    ) -> OrgContext:
        compiler = DefaultOrgContextCompiler(
            authorizer=self.policy_factory(actor),
            retriever=self.retriever,
            telemetry=self.telemetry,
            lifecycle=self.lifecycle,
            admin_gate=self.admin_gate,
        )
        return compiler.observe(
            actor,
            request,
            token_budget=token_budget or actor.profile.default_context_budget,
        )

    def retrieval_health(self) -> RetrieverHealth:
        return self.retriever.health()

    def investigate(self, actor: ActorContext, request, *, episode_id: str,
                    seeds=(), initial_searches: int = 0, initial_bounds=None,
                    request_id=None, binding=None, origin='direct') -> dict:
        """Execute one bounded discovery/read step in the current user prompt."""
        from .investigation import execute
        if self.instance_root is None:
            raise ValueError('Runtime investigation requires instance-local state storage')
        return execute(self, actor, request, root=self.instance_root,
                       episode_id=episode_id, seeds=seeds,
                       initial_searches=initial_searches, initial_bounds=initial_bounds,
                       request_id=request_id,binding=binding,origin=origin)

    def synchronize(self) -> SynchronizationReceipt:
        """Synchronize canonical state, make lexical recall current, and warm vectors.

        Canonical synchronization is the gate: a failed pull never produces a
        receipt that calls either canonical state or a pre-existing index
        current.  Once it succeeds, the retriever refresh is synchronous so
        lexical search is usable; semantic construction is only scheduled.
        """

        try:
            canonical = self.sync_transport.pull()
        except Exception as exc:
            kind = getattr(exc, "kind", None) or "runtime"
            return SynchronizationReceipt(
                schema_version="egregore-runtime-sync/v1",
                status="failed",
                canonical_sync=None,
                retrieval=None,
                canonical_current=False,
                index_source_aligned=False,
                semantic_building=False,
                failures=(f"canonical sync failed: {exc}",),
                failure_kind=kind,
                remedy=sync_remedy(kind, exc),
            )

        failures: list[str] = []
        failure_kind: str | None = None
        remedy: str | None = None
        if not canonical.current:
            failures.append("canonical sync completed without reaching the remote revision")
            failure_kind = "behind"
            remedy = sync_remedy("behind", None)
        try:
            # The launcher calls synchronization outside the model sandbox.
            # Bring the owned query worker up here so native sandboxes can
            # use local embeddings without opening a GPU context themselves.
            health = (self.retriever.start() if isinstance(self.retriever, RetrievalRuntimeControl)
                      else self.retriever.update())
        except Exception as exc:
            return SynchronizationReceipt(
                schema_version="egregore-runtime-sync/v1",
                status="degraded",
                canonical_sync=canonical,
                retrieval=None,
                canonical_current=canonical.current,
                index_source_aligned=False,
                semantic_building=False,
                failures=tuple((*failures, f"retrieval refresh failed: {exc}")),
                failure_kind=failure_kind,
                remedy=remedy,
                retrieval_grade="unavailable",
                retrieval_detail=f"retrieval refresh failed: {exc}",
            )

        index_aligned = bool(
            health.index_source_revision
            and health.index_source_revision == health.source_revision
        )
        if not health.bm25_ready:
            failures.append("lexical retrieval is not ready")
        if not index_aligned:
            failures.append("retrieval index source revision differs from canonical source")
        retrieval_grade, retrieval_detail = grade_retrieval(
            health, index_aligned=index_aligned, dirty_count=canonical.dirty_count
        )

        try:
            health = self.retriever.embed_background()
        except Exception as exc:
            failures.append(f"semantic warm-up could not be scheduled: {exc}")

        semantic_building = bool(
            not health.semantic_ready
            and health.runtime_state == "semantic_index_building"
        )
        ready = canonical.current and health.bm25_ready and index_aligned
        return SynchronizationReceipt(
            schema_version="egregore-runtime-sync/v1",
            status="ready" if ready and not failures else "degraded",
            canonical_sync=canonical,
            retrieval=health,
            canonical_current=canonical.current,
            index_source_aligned=index_aligned,
            semantic_building=semantic_building,
            failures=tuple(failures),
            failure_kind=failure_kind,
            remedy=remedy,
            retrieval_grade=retrieval_grade,
            retrieval_detail=retrieval_detail,
        )

    def start_retrieval(self) -> RetrieverHealth:
        if isinstance(self.retriever, RetrievalRuntimeControl):
            return self.retriever.start()
        return self.retriever.health()

    def shutdown_retrieval(self) -> RetrieverHealth:
        if isinstance(self.retriever, RetrievalRuntimeControl):
            return self.retriever.shutdown()
        return self.retriever.health()

    def open_source(self, actor: ActorContext, canonical_path: str) -> str:
        """Authorize, open, and record one canonical source through Runtime."""

        path = canonical_path.strip().replace("\\", "/")
        relative = path.removeprefix("memory/")
        artifact_id = artifact_id_from_path(relative)
        # Authorize the canonical path before reading even its frontmatter. The
        # stable declared id is resolved from the authorized source and then
        # checked separately before content is returned to the harness.
        decision = self.authorize(actor, Permission.READ)
        if not decision.allowed or not scope_allows_path(path, decision.scopes):
            raise AuthorizationDenied("canonical source is outside the actor read scope")

        content = self.retriever.open_source(
            RetrievalHit(
                artifact_id=artifact_id,
                canonical_path=path,
                rank=1,
                score=1,
                retrieval_types=(RetrievalMode.LEX,),
            )
        )
        # Egregore-surface admin protection: admin-marked content is served
        # only to organization admins. Repository members can still read the
        # raw Git file — this guards the product surface, not the filesystem.
        if (
            self.admin_gate is not None
            and document_is_admin(content)
            and not self.admin_gate.actor_is_admin(actor)
        ):
            raise AuthorizationDenied(
                "this document is admin-marked; Egregore serves it to organization admins only"
            )
        stable_artifact_id = canonical_artifact_id(content, path)
        stable_decision = self.authorize(actor, Permission.READ, (stable_artifact_id,))
        if not stable_decision.allowed:
            raise AuthorizationDenied(
                "canonical artifact identity is outside the actor read scope"
            )
        artifact_id = stable_artifact_id
        try:
            self.telemetry.emit(
                TelemetryEvent(
                    schema_version=TELEMETRY_SCHEMA_VERSION,
                    event_id=f"evt_{uuid4().hex}",
                    event_type="source.opened",
                    occurred_at=datetime.now(UTC),
                    org_id=actor.profile.org_id,
                    actor_id=actor.actor.actor_id,
                    session_id=actor.session_id,
                    org_revision=actor.profile.revision,
                    index_spec_version=self.retriever.health().index_spec_version,
                    metrics={
                        "opened_count": 1,
                        "result": "authorized",
                        "success": True,
                    },
                    artifact_ids=(artifact_id,),
                )
            )
        except Exception:
            # Source access is canonical behavior; telemetry is disposable.
            pass
        return content

    def write_artifact(
        self,
        actor: ActorContext,
        artifact: CanonicalArtifact,
        content: str,
    ) -> WritebackEvent:
        return self._writeback(actor).write(actor, artifact, content)

    def write_document(
        self,
        actor: ActorContext,
        document: CanonicalDocument,
    ) -> WritebackEvent:
        return self._writeback(actor).write_document(actor, document)

    def write_documents(
        self,
        actor: ActorContext,
        documents: tuple[CanonicalDocument, ...],
    ) -> tuple[WritebackEvent, ...]:
        return self._writeback(actor).write_documents(actor, documents)

    def commit_canonical_files(
        self,
        actor: ActorContext,
        paths: Sequence[str],
        *,
        message: str,
    ) -> CanonicalFilesWritebackEvent:
        """Commit exact existing canonical files, including registries and ledgers."""

        if self.canonical_root is None:
            raise RuntimeError("canonical file writeback is unavailable")
        return self._writeback(actor).commit_files(
            actor, paths, memory_root=self.canonical_root, message=message,
        )

    def register_ingest_manifest(
        self,
        actor: ActorContext,
        *,
        source_id: str,
        manifest_path: Path,
        source_path: Path,
    ) -> IngestRegistrationReceipt:
        """Commit canonical intake provenance before refreshing its index."""

        if self.canonical_root is None:
            raise RuntimeError("canonical ingest registry is unavailable")
        registry = CanonicalIngestRegistry(
            memory_root=self.canonical_root,
            authorizer=self.policy_factory(actor),
            sync_transport=self.sync_transport,
            telemetry=self.telemetry,
        )
        return registry.register(
            actor,
            source_id=source_id,
            manifest_path=manifest_path,
            source_path=source_path,
        )

    def lifecycle_plan(
        self,
        actor: ActorContext,
        *,
        artifact_types: tuple[str, ...] = (),
        user: str | None = None,
    ) -> LifecyclePlan:
        decision = self.authorize(actor, Permission.READ)
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons))
        if self.lifecycle is None:
            raise LifecycleError("canonical lifecycle service is unavailable")
        recipient_aliases: tuple[str, ...] | None = None
        if user:
            aliases = {
                user,
                actor.actor.actor_id,
                actor.actor.display_name,
                *(str(value) for value in actor.actor.aliases.values()),
            }
            if actor.account is not None:
                aliases.add(actor.account.display_name)
                aliases.update(str(value) for value in actor.account.provider_aliases.values())
            recipient_aliases = tuple(sorted(value for value in aliases if value.strip()))
        return self.lifecycle.scan(
            authorized_scopes=decision.scopes,
            artifact_types=artifact_types,
            user=recipient_aliases,
        )

    def transition_lifecycle(
        self,
        actor: ActorContext,
        *,
        target_artifact_id: str,
        action: LifecycleAction,
        reason: str,
        evidence_ids: tuple[str, ...] = (),
        automatic: bool = False,
        expected_lifecycle_revision: str | None = None,
        user: str | None = None,
    ) -> WritebackEvent:
        decision = self.authorize(actor, Permission.WRITE, (target_artifact_id,))
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons))
        if automatic:
            execute = self.authorize(actor, Permission.EXECUTE, (target_artifact_id,))
            if not execute.allowed:
                raise AuthorizationDenied("; ".join(execute.reasons))
        plan = self.lifecycle_plan(actor, user=user)
        matches = [record for record in plan.records if record.artifact_id == target_artifact_id]
        if len(matches) != 1:
            raise LifecycleError("lifecycle target is missing or ambiguous")
        administer = bool(
            actor.membership
            and {role.casefold() for role in actor.membership.roles}
            & {"admin", "administrator", "owner", "founder"}
            and self.authorize(actor, Permission.ADMINISTER, (target_artifact_id,)).allowed
        )
        if self.lifecycle is None:
            raise LifecycleError("canonical lifecycle service is unavailable")
        transition = self.lifecycle.prepare_transition(
            actor,
            matches[0],
            action,
            reason=reason,
            evidence_ids=evidence_ids,
            automatic=automatic,
            allow_admin=administer,
            expected_lifecycle_revision=expected_lifecycle_revision,
        )
        receipt = self.write_document(actor, transition.document)
        if receipt.status is not WritebackStatus.REJECTED:
            try:
                self.telemetry.emit(
                    TelemetryEvent(
                        schema_version=TELEMETRY_SCHEMA_VERSION,
                        event_id=f"evt_{uuid4().hex}",
                        event_type="lifecycle.transitioned",
                        occurred_at=datetime.now(UTC),
                        org_id=actor.profile.org_id,
                        actor_id=actor.actor.actor_id,
                        session_id=actor.session_id,
                        org_revision=actor.profile.revision,
                        metrics={
                            "action": action.value,
                            "result": receipt.status.value,
                            "success": receipt.status is WritebackStatus.ACCEPTED,
                        },
                        artifact_ids=(target_artifact_id, receipt.artifact.artifact_id),
                    )
                )
            except Exception:
                pass
        return receipt

    def _writeback(self, actor: ActorContext) -> CanonicalArtifactWriteback:
        return CanonicalArtifactWriteback(
            authorizer=self.policy_factory(actor),
            store=self.store,
            sync_transport=self.sync_transport,
            retriever=self.retriever,
            telemetry=self.telemetry,
            graph=self.graph,
        )


def runtime_root(root: Path | str | None = None) -> Path:
    """Resolve the checkout using the harness CLIs' shared root convention."""
    return Path(root if root is not None else os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()


def local_runtime(
    root: Path,
    *,
    push_remote: bool = True,
    policy_factory: PolicyFactory | None = None,
) -> EgregoreRuntime:
    """Compose the Local architecture; all projections remain disposable."""

    repository_root = runtime_root(root)
    memory_root = (repository_root / "memory").resolve()
    instance_id = hashlib.sha256(str(memory_root).encode("utf-8")).hexdigest()[:16]
    lifecycle = CanonicalLifecycleService(
        memory_root,
        state_dir=Path.home() / ".egregore" / "runtime" / "lifecycle" / instance_id,
    )

    def dogfood(actor: ActorContext) -> ActionAuthorizer:
        return all_access_dogfood_policy(
            org_id=actor.profile.org_id,
            actor_id=actor.actor.actor_id,
        )

    return EgregoreRuntime(
        identity=LocalIdentityResolver(repository_root),
        retriever=QmdLocalRetriever(
            repository_root=repository_root,
            memory_root=memory_root,
            collection=os.environ.get("EGREGORE_QMD_COLLECTION") or None,
        ),
        telemetry=LocalTelemetrySink(
            state_file=repository_root / ".egregore-state.json",
            instance_root=memory_root,
        ),
        store=LocalMarkdownArtifactStore(memory_root),
        sync_transport=LocalGitSyncTransport(memory_root, push_remote=push_remote),
        graph=DisabledGraphProjection(repository_root),
        lifecycle=lifecycle,
        canonical_root=memory_root,
        instance_root=repository_root,
        policy_factory=policy_factory or dogfood,
        admin_gate=AdminGate(
            config_path=repository_root / "egregore.json",
            memory_root=memory_root,
        ),
    )
