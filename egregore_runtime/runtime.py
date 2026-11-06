"""Cohesive harness-facing Egregore Runtime.

Harness adapters use this facade for identity, authorization, Observe,
canonical writeback, and telemetry. Infrastructure-specific classes are
composed here and are not part of the harness contract.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
import hashlib
import json
import os
from pathlib import Path
from typing import TYPE_CHECKING, Callable, Sequence
from uuid import uuid4

from .adapters.qmd import QmdLocalRetriever
from .held import document_is_admin, redact
from .access import authorization_inputs
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
from .observers import MAX_EVENT_PATHS, Observer, RuntimeEvent
from .sync_health import grade_retrieval, sync_remedy
from .policy import check, is_admin, policy_for
from .projection import observer as projection_observer
from .optional_modules import optional_module

_record = optional_module(".record")
record_observer = _record.observer if _record is not None else None
from .sync import LocalGitSyncTransport
from .telemetry import LocalTelemetrySink, TELEMETRY_SCHEMA_VERSION
from .writeback import CanonicalArtifactWriteback

if TYPE_CHECKING:
    from .member_authority import AuthenticatedMemberResolver


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
    instance_root: Path | None = None
    observers: list[Observer] = field(default_factory=list)

    def _notify(self, kind, actor, paths):
        paths = tuple(dict.fromkeys(path for path in paths if path))[:MAX_EVENT_PATHS]
        if not paths:
            return
        event = RuntimeEvent(kind, actor.actor.actor_id, actor.session_id, actor.harness, paths,
                             execution=actor.execution)
        for observer in self.observers:
            try:
                observer(event)
            except Exception:
                pass

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
            memory_root=self.canonical_root,
        )
        context = compiler.observe(
            actor,
            request,
            token_budget=token_budget or actor.profile.default_context_budget,
        )
        self._notify("observed", actor, (item.canonical_path for item in context.evidence))
        return context

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

        content, artifact_id, canonical = self._served(actor, canonical_path)
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
                    index_spec_version=self._index_spec_version(),
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
        self._notify("opened", actor, (canonical,))
        return content

    def serve_source(self, actor: ActorContext, canonical_path: str) -> str:
        """One canonical source as ``open_source`` serves it (authorized, the admin guard, redacted), without
        recording it as opened: for a listing that reads many files to show a few (``shown`` records those)."""

        return self._served(actor, canonical_path)[0]

    def shown(self, actor: ActorContext, canonical_paths: Sequence[str]) -> None:
        """Record that a listing showed the actor what these canonical sources hold, as an observe does."""

        self._notify("observed", actor, canonical_paths)

    def _index_spec_version(self) -> str:
        """The retriever's index spec: its own constant when it states one, since its health check can be a
        subprocess (QMD's runs ``qmd status``) that every source open would pay for."""

        known = getattr(self.retriever, "index_spec_version", None)
        return known if isinstance(known, str) and known else self.retriever.health().index_spec_version

    def _served(self, actor: ActorContext, canonical_path: str) -> tuple[str, str, str]:
        """(content, stable artifact id, canonical path) of one authorized, redacted canonical source."""

        path = canonical_path.strip().replace("\\", "/")
        relative = path.removeprefix("memory/")
        artifact_id = artifact_id_from_path(relative)
        # Authorize the canonical path before reading even its frontmatter. The
        # stable declared id is resolved from the authorized source and then
        # checked separately before content is returned to the harness.
        decision = self.authorize(actor, Permission.READ)
        verdict = check(decision, path, "read", root=self.canonical_root)
        if not verdict.allowed:
            raise AuthorizationDenied("canonical source is outside the actor read scope")

        content = self.retriever.open_source(
            RetrievalHit(
                artifact_id=artifact_id,
                canonical_path=verdict.canonical,
                rank=1,
                score=1,
                retrieval_types=(RetrievalMode.LEX,),
            )
        )
        # Egregore-surface admin protection: admin-marked content is served
        # only to organization admins. Repository members can still read the
        # raw Git file — this guards the product surface, not the filesystem.
        if (
            not is_admin(decision) and document_is_admin(content)
        ):
            raise AuthorizationDenied(
                "this document is admin-marked; Egregore serves it to organization admins only"
            )
        stable_artifact_id = canonical_artifact_id(content, path)
        stable_decision = self.authorize(actor, Permission.READ, (stable_artifact_id,))
        if not stable_decision.allowed or (
            stable_decision.resource_ids and stable_artifact_id not in stable_decision.resource_ids
        ):
            raise AuthorizationDenied(
                "canonical artifact identity is outside the actor read scope"
            )
        if not check(stable_decision, path, "read", root=self.canonical_root).allowed:
            raise AuthorizationDenied(
                "canonical source is outside the current actor read scope"
            )
        if not is_admin(stable_decision) and document_is_admin(content):
            raise AuthorizationDenied(
                "this document is admin-marked; Egregore serves it to organization admins only"
            )
        artifact_id = stable_artifact_id
        # The one packaging: names of the documents held from this reader leave the text.
        content = redact(stable_decision, content, root=self.canonical_root)
        return content, artifact_id, verdict.canonical

    def write_artifact(
        self,
        actor: ActorContext,
        artifact: CanonicalArtifact,
        content: str,
    ) -> WritebackEvent:
        receipt = self._writeback(actor).write(actor, artifact, content)
        if receipt.status in (WritebackStatus.ACCEPTED, WritebackStatus.PARTIAL):
            self._notify("wrote", actor, ("memory/" + receipt.artifact.canonical_path,))
        return receipt

    def write_document(
        self,
        actor: ActorContext,
        document: CanonicalDocument,
        *,
        message: str | None = None,
    ) -> WritebackEvent:
        """``message``: the commit's own message (a document edit's file, why and trailers); every other
        write keeps the writeback's."""
        receipt = self._writeback(actor).write_document(actor, document, **({"message": message} if message else {}))
        if receipt.status in (WritebackStatus.ACCEPTED, WritebackStatus.PARTIAL):
            self._notify("wrote", actor, ("memory/" + receipt.artifact.canonical_path,))
        return receipt

    def write_documents(
        self,
        actor: ActorContext,
        documents: tuple[CanonicalDocument, ...],
    ) -> tuple[WritebackEvent, ...]:
        receipts = self._writeback(actor).write_documents(actor, documents)
        self._notify("wrote", actor, (
            "memory/" + receipt.artifact.canonical_path for receipt in receipts
            if receipt.status in (WritebackStatus.ACCEPTED, WritebackStatus.PARTIAL)
        ))
        return receipts

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
        receipt = self._writeback(actor).commit_files(
            actor, paths, memory_root=self.canonical_root, message=message,
        )
        if receipt.status in (WritebackStatus.ACCEPTED, WritebackStatus.PARTIAL):
            self._notify("wrote", actor, ("memory/" + path for path in receipt.canonical_paths))
        return receipt

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
            decision=decision,
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
        admin = self.authorize(actor, Permission.ADMINISTER, (target_artifact_id,))
        administer = is_admin(admin)
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
    identity: IdentityResolver | None = None,
    observers: Sequence[Observer] | None = None,
) -> EgregoreRuntime:
    """Compose the Local architecture; all projections remain disposable."""

    repository_root = runtime_root(root)
    memory_root = (repository_root / "memory").resolve()
    instance_id = hashlib.sha256(str(memory_root).encode("utf-8")).hexdigest()[:16]
    lifecycle = CanonicalLifecycleService(
        memory_root,
        state_dir=Path.home() / ".egregore" / "runtime" / "lifecycle" / instance_id,
    )

    active_observers = list(observers) if observers is not None else [
        *([record_observer(repository_root)] if record_observer is not None else []),
        projection_observer(repository_root),
    ]
    return EgregoreRuntime(
        identity=identity if identity is not None else LocalIdentityResolver(repository_root),
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
        observers=active_observers,
        policy_factory=policy_factory or (lambda actor: policy_for(authorization_inputs(repository_root))),
    )


def authenticated_member_runtime(
    root: Path,
    *,
    identity: AuthenticatedMemberResolver,
    push_remote: bool = True,
    policy_factory: PolicyFactory | None = None,
    observers: Sequence[Observer] = (),
) -> EgregoreRuntime:
    """Compose current member authority over Local policy, without Local login.

    The trusted host supplies an authenticated resolver. Missing/unavailable
    verification never falls back to the machine owner's identity. This factory
    does not issue grants, connect transports, or grant paid capabilities.
    """
    from .member_authority import AuthenticatedMemberResolver, MemberAuthorityPolicy

    if not isinstance(identity, AuthenticatedMemberResolver):
        raise ValueError("authenticated member identity is required")
    repository_root = runtime_root(root)
    # Verify the configured workspace independently of the server response.
    # Merely presenting a valid grant for another organization cannot select it.
    try:
        config = json.loads((repository_root / "egregore.json").read_text())
        if config.get("org_id") != identity.expected.org_id:
            raise ValueError("different organization")
    except (OSError, ValueError, AttributeError):
        raise ValueError("member authority does not match this workspace") from None
    base = policy_factory or (lambda actor: policy_for(authorization_inputs(repository_root)))
    return local_runtime(
        repository_root, push_remote=push_remote, identity=identity,
        policy_factory=lambda actor: MemberAuthorityPolicy(identity, base),
        # Legacy projection refresh resolves Local identity during composition.
        # Hosts opt into observers only after adapting their authority boundary.
        observers=observers,
    )
