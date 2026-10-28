"""Organizational context compilation independent of harness/infrastructure."""

from __future__ import annotations

import time
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from uuid import uuid4

from .contracts import (
    ActionAuthorizer,
    ActorContext,
    EvidenceItem,
    OrgContext,
    OrgContextCompiler,
    Permission,
    RetrievalHit,
    RetrievalRequest,
    Retriever,
    TelemetryEvent,
    TelemetrySink,
    TemporalScope,
)
from .admin_gate import AdminGate
from .errors import AuthorizationDenied, ContextBudgetError
from .lifecycle import AuthorityState, CanonicalLifecycleService, LifecycleRecord
from .policy import scope_allows_path


def _token_count(content: str) -> int:
    # Deterministic, dependency-free planning estimate. Harness adapters may
    # supply a tokenizer later without weakening the authorization boundary.
    return max(1, (len(content) + 3) // 4)


def _truncate_to_budget(content: str, budget: int) -> str:
    return content[: max(0, budget * 4)]


@dataclass(slots=True)
class DefaultOrgContextCompiler(OrgContextCompiler):
    authorizer: ActionAuthorizer
    retriever: Retriever
    telemetry: TelemetrySink
    lifecycle: CanonicalLifecycleService | None = None
    admin_gate: AdminGate | None = None

    def observe(
        self,
        actor: ActorContext,
        request: RetrievalRequest,
        *,
        token_budget: int,
    ) -> OrgContext:
        if token_budget <= 0:
            raise ContextBudgetError("token budget must be positive")

        started = time.monotonic()
        decision = self.authorizer.authorize_observe(actor, request)
        if not decision.allowed:
            self._emit(
                actor,
                request,
                "observe.denied",
                metrics={"success": False, "failure_code": "authorization_denied"},
            )
            raise AuthorizationDenied("; ".join(decision.reasons))

        scopes = tuple(
            scope
            for scope in (request.authorized_scopes or decision.scopes)
            if not decision.scopes or scope_allows_path(scope, decision.scopes)
        )
        if not scopes:
            raise AuthorizationDenied("policy produced no authorized retrieval scope")

        allowed_ids = request.allowed_artifact_ids
        if decision.resource_ids:
            allowed_ids = tuple(
                artifact_id
                for artifact_id in (allowed_ids or decision.resource_ids)
                if artifact_id in decision.resource_ids
            )
            if not allowed_ids:
                raise AuthorizationDenied("policy produced no authorized artifact set")

        authorized_request = replace(
            request,
            authorized_scopes=scopes,
            allowed_artifact_ids=allowed_ids,
        )
        scoped_retrieve = getattr(self.retriever, "retrieve_authorized", None)
        result = (
            scoped_retrieve(authorized_request, actor=actor,
                            admin_gate=self.admin_gate, lifecycle=self.lifecycle)
            if callable(scoped_retrieve)
            else self.retriever.retrieve(authorized_request)
        )

        # Defense in depth: an adapter returning an out-of-scope candidate
        # cannot place it in model context.
        authorized_hits = tuple(
            hit
            for hit in result.hits
            if scope_allows_path(hit.canonical_path, scopes)
            and (not allowed_ids or hit.artifact_id in allowed_ids)
        )

        # Egregore-surface admin protection: QMD may match an admin-marked
        # document internally, but for a non-admin actor it must contribute
        # nothing to evidence — no title, path, snippet, count detail, or
        # model context. Only an opaque withheld tally survives.
        withheld_admin = 0
        if self.admin_gate is not None and not self.admin_gate.actor_is_admin(actor):
            visible_hits = []
            for hit in authorized_hits:
                if self.admin_gate.path_is_admin(hit.canonical_path):
                    withheld_admin += 1
                else:
                    visible_hits.append(hit)
            authorized_hits = tuple(visible_hits)

        lifecycle_by_path: dict[str, LifecycleRecord] = {}
        lifecycle_revision = "unavailable"
        lifecycle_warning: str | None = None
        if self.lifecycle is not None:
            try:
                resolved, lifecycle_revision = self.lifecycle.resolve_paths(
                    tuple(hit.canonical_path for hit in authorized_hits),
                    source_revision=result.source_revision,
                    authorized_scopes=scopes,
                    allowed_artifact_ids=allowed_ids,
                )
                lifecycle_by_path = dict(resolved)
            except Exception as exc:
                lifecycle_warning = f"lifecycle-unavailable:{type(exc).__name__}"

        # Lifecycle events are organizational receipts, not normal answer
        # evidence. Current authority is selected only after authorization and
        # before any source is opened.
        selected_hits: list[RetrievalHit] = []
        observed_by_path: dict[str, datetime] = {}
        for hit in authorized_hits:
            record = lifecycle_by_path.get(hit.canonical_path)
            if record is not None and record.artifact_type == "lifecycle-event":
                if "lifecycle-event" not in request.artifact_types:
                    continue
            if record is not None:
                historical = record.authority_state in {
                    AuthorityState.SUPERSEDED,
                    AuthorityState.HISTORICAL,
                }
                if request.temporal_scope is TemporalScope.CURRENT and historical:
                    continue
                if request.temporal_scope is TemporalScope.HISTORICAL and not historical:
                    continue
            observed_at = hit.observed_at or (record.created_at if record is not None else None)
            if request.not_before is not None:
                if observed_at is None:
                    continue
                if observed_at.tzinfo is None:
                    observed_at = observed_at.replace(tzinfo=UTC)
                if observed_at.astimezone(UTC) < request.not_before.astimezone(UTC):
                    continue
            if observed_at is not None:
                normalized = (observed_at.replace(tzinfo=UTC) if observed_at.tzinfo is None else observed_at).astimezone(UTC)
                observed_by_path[hit.canonical_path] = min(
                    normalized, observed_by_path.get(hit.canonical_path, normalized)
                )
            selected_hits.append(hit)

        selected_hits.sort(
            key=lambda hit: (
                1
                if lifecycle_by_path.get(hit.canonical_path)
                and lifecycle_by_path[hit.canonical_path].authority_state
                is AuthorityState.AMBIGUOUS
                else 2
                if lifecycle_by_path.get(hit.canonical_path)
                and lifecycle_by_path[hit.canonical_path].authority_state
                in {AuthorityState.SUPERSEDED, AuthorityState.HISTORICAL}
                else 0,
                hit.rank,
            )
        )

        evidence, opened_ids, omissions, tokens_used = self._package(
            tuple(selected_hits),
            request,
            token_budget,
            lifecycle_by_path,
        )
        # A rolling-window receipt is reusable only until its oldest delivered
        # source expires. Omitted/withheld hits must not affect this boundary.
        evidence_dates = [observed_by_path.get(item.canonical_path) for item in evidence]
        oldest_evidence = (
            min(evidence_dates).isoformat()
            if evidence_dates and all(value is not None for value in evidence_dates)
            else None
        )
        if lifecycle_warning:
            omissions = (*omissions, lifecycle_warning)
        if withheld_admin:
            # Tag-not-hide: existence is visible, identity is not. No id,
            # title, or path of the withheld documents may appear here.
            omissions = (*omissions, f"[admin] {withheld_admin} admin-marked item(s) withheld")
        permissions = frozenset(
            permission
            for permission in Permission
            if self.authorizer.authorize_action(actor, permission).allowed
        )
        context = OrgContext(
            schema_version="egregore-context/v1",
            context_id=f"ctx_{uuid4().hex}",
            org_id=actor.profile.org_id,
            actor_id=actor.actor.actor_id,
            task=request.task,
            profile_revision=actor.profile.revision,
            source_revision=result.source_revision,
            policy_epoch=decision.policy_epoch,
            evidence=evidence,
            action_permissions=permissions,
            token_budget=token_budget,
            tokens_used=tokens_used,
            omissions=omissions,
            retrieval_mode=result.mode.value,
            requested_retrieval_mode=(getattr(result, "requested_mode", None) or request.mode).value,
            degraded=result.degraded,
            warnings=result.warnings,
            freshness={
                "source_revision": result.source_revision,
                "index_revision": result.index_revision,
                "index_spec_version": result.index_spec_version,
                "lifecycle_revision": lifecycle_revision,
                "temporal_scope": request.temporal_scope.value,
                "temporal_authority": "canonical-markdown",
                **({"retrieval_coverage": result.coverage} if getattr(result, "coverage", None) else {}),
                **({"oldest_evidence_observed_at": oldest_evidence} if oldest_evidence else {}),
            },
        )
        elapsed_ms = int((time.monotonic() - started) * 1000)
        self._emit(
            actor,
            request,
            "observe.completed",
            # Artifact ids retain retrieval order, so array position is the
            # privacy-safe rank without creating a content-bearing map.
            artifact_ids=tuple(hit.artifact_id for hit in selected_hits),
            metrics={
                "duration_ms": elapsed_ms,
                "latency_ms": result.latency_ms,
                "count": len(selected_hits),
                "opened_count": len(opened_ids),
                "result": "context_produced",
                "token_count": tokens_used,
                "retrieval_type": result.mode.value,
                "success": True,
            },
            index_spec_version=result.index_spec_version,
        )
        if opened_ids:
            self._emit(
                actor,
                request,
                "source.opened",
                artifact_ids=opened_ids,
                metrics={"opened_count": len(opened_ids)},
                index_spec_version=result.index_spec_version,
            )
        return context

    def _package(
        self,
        hits: tuple[RetrievalHit, ...],
        request: RetrievalRequest,
        token_budget: int,
        lifecycle_by_path: dict[str, LifecycleRecord] | None = None,
    ) -> tuple[tuple[EvidenceItem, ...], tuple[str, ...], tuple[str, ...], int]:
        evidence: list[EvidenceItem] = []
        opened_ids: list[str] = []
        omissions: list[str] = []
        remaining = token_budget

        for position, hit in enumerate(hits):
            if remaining <= 0:
                omissions.append(f"budget:{hit.canonical_path}")
                continue
            if request.open_sources:
                content = self.retriever.open_source(hit)
                opened_ids.append(hit.artifact_id)
                # Preserve matches from the canonical source, not just its preamble.
                passage = " ".join((hit.passage or "").split())
                canonical = " ".join(content.split())
                if passage and passage in canonical and passage != canonical:
                    content = passage
                    omissions.append(f"excerpt:{hit.canonical_path}")
                elif passage and passage not in canonical:
                    omissions.append(f"stale-passage:{hit.canonical_path}")
            else:
                content = hit.passage or ""
            if not content:
                omissions.append(f"empty:{hit.artifact_id}")
                continue

            count = _token_count(content)
            share = max(1, remaining // (len(hits) - position))
            if count > share:
                content = _truncate_to_budget(content, share)
                count = _token_count(content)
                omissions.append(f"truncated:{hit.canonical_path}")
            evidence.append(
                EvidenceItem(
                    artifact_id=hit.artifact_id,
                    canonical_path=hit.canonical_path,
                    revision=hit.revision or "unknown",
                    reason=self._evidence_reason(
                        hit,
                        (lifecycle_by_path or {}).get(hit.canonical_path),
                    ),
                    content=content,
                    token_count=count,
                )
            )
            remaining -= count

        return (
            tuple(evidence),
            tuple(opened_ids),
            tuple(omissions),
            token_budget - remaining,
        )

    @staticmethod
    def _evidence_reason(hit: RetrievalHit, lifecycle: LifecycleRecord | None) -> str:
        observed_at = hit.observed_at or (lifecycle.created_at if lifecycle is not None else None)
        observed = (
            f"; observed={observed_at.date().isoformat()}" if observed_at is not None else ""
        )
        if lifecycle is None:
            return f"retrieval rank {hit.rank}; temporal authority unknown{observed}"
        return (
            f"retrieval rank {hit.rank}; authority={lifecycle.authority_state.value}; "
            f"attention={lifecycle.attention_state.value}; "
            f"obligation={lifecycle.obligation_state.value}{observed}"
        )

    def _emit(
        self,
        actor: ActorContext,
        request: RetrievalRequest,
        event_type: str,
        *,
        artifact_ids: tuple[str, ...] = (),
        metrics: dict[str, int | float | bool | str | None] | None = None,
        index_spec_version: str | None = None,
    ) -> None:
        try:
            self.telemetry.emit(
                TelemetryEvent(
                    schema_version="egregore.telemetry/v1",
                    event_id=f"evt_{uuid4().hex}",
                    event_type=event_type,
                    occurred_at=datetime.now(UTC),
                    org_id=actor.profile.org_id,
                    actor_id=actor.actor.actor_id,
                    session_id=actor.session_id,
                    task_id=request.request_id,
                    org_revision=actor.profile.revision,
                    index_spec_version=index_spec_version,
                    metrics=metrics or {},
                    artifact_ids=artifact_ids,
                )
            )
        except Exception:
            # Telemetry is an observability projection. It cannot make a valid
            # authorization/context result fail.
            return
