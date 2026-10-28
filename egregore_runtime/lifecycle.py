"""Canonical temporal-authority and artifact-lifecycle projection.

Markdown and Git remain durable truth. Lifecycle state is derived from artifact
frontmatter plus append-only lifecycle-event artifacts; this module never
rewrites or deletes the artifact whose state it projects.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from enum import StrEnum
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Any, Callable, Iterable, Mapping, Sequence
from uuid import uuid4

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalDocument,
    canonical_artifact_id,
    content_digest,
    split_frontmatter,
)
from .contracts import (
    ActorContext,
    ArtifactRelationship,
    CanonicalArtifact,
    Serializable,
)
from .policy import scope_allows_path


LIFECYCLE_PLAN_SCHEMA = "egregore-lifecycle-plan/v1"
LIFECYCLE_EVENT_SCHEMA = "egregore-lifecycle-event/v1"
LIFECYCLE_INDEX_SPEC = "egregore-lifecycle-projection/v1"


class AuthorityState(StrEnum):
    CURRENT = "current"
    SUPERSEDED = "superseded"
    HISTORICAL = "historical"
    AMBIGUOUS = "ambiguous"


class AttentionState(StrEnum):
    ACTIVE = "active"
    REVIEW_DUE = "review_due"
    EXPIRED = "expired"


class ObligationState(StrEnum):
    NONE = "none"
    PENDING = "pending"
    READ = "read"
    CLAIMED = "claimed"
    COMPLETED = "completed"
    REVIEW_REQUIRED = "review_required"


class LifecycleAction(StrEnum):
    ACKNOWLEDGE = "acknowledge"
    CLAIM = "claim"
    COMPLETE = "complete"
    EXPIRE_ATTENTION = "expire_attention"
    REOPEN = "reopen"
    REQUEST_REVIEW = "request_review"


class LifecycleError(ValueError):
    """A requested lifecycle transition is invalid or lacks evidence."""


@dataclass(frozen=True, slots=True)
class LifecyclePolicy(Serializable):
    schema_version: str = "egregore-lifecycle-policy/v1"
    review_after_days: int = 7
    handoff_ttl_days: int = 14
    fyi_expiry_days: int = 14
    retention_days: int | None = None


@dataclass(frozen=True, slots=True)
class LifecycleRecord(Serializable):
    artifact_id: str
    canonical_path: str
    artifact_type: str
    title: str
    created_at: datetime
    created_by: str
    declared_status: str
    authority_state: AuthorityState
    attention_state: AttentionState
    obligation_state: ObligationState
    current_authority: bool
    lifecycle_revision: str
    age_days: int
    created_by_alias: str | None = None
    intent: str | None = None
    recipients: tuple[str, ...] = ()
    superseded_by: tuple[str, ...] = ()
    review_at: datetime | None = None
    attention_expires_at: datetime | None = None
    retention_until: datetime | None = None
    terminal_reason: str | None = None
    recommendation: str = "keep"
    automatic_transition_safe: bool = False
    evidence_ids: tuple[str, ...] = ()
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class LifecyclePlan(Serializable):
    schema_version: str
    index_spec_version: str
    snapshot_id: str
    generated_at: datetime
    source_revision: str
    records: tuple[LifecycleRecord, ...]
    warnings: tuple[str, ...] = ()

    @property
    def by_id(self) -> dict[str, LifecycleRecord]:
        return {record.artifact_id: record for record in self.records}


@dataclass(frozen=True, slots=True)
class LifecycleTransition(Serializable):
    action: LifecycleAction
    target_artifact_id: str
    target_path: str
    previous_obligation: ObligationState
    new_obligation: ObligationState
    previous_attention: AttentionState
    new_attention: AttentionState
    expected_lifecycle_revision: str
    reason: str
    evidence_ids: tuple[str, ...]
    automatic: bool
    document: CanonicalDocument


@dataclass(frozen=True, slots=True)
class _Snapshot:
    artifact_id: str
    canonical_path: str
    artifact_type: str
    title: str
    created_at: datetime
    created_by: str
    created_by_alias: str | None
    status: str
    intent: str | None
    recipients: tuple[str, ...]
    supersedes: tuple[str, ...]
    review_at: datetime | None
    attention_expires_at: datetime | None
    retention_until: datetime | None
    terminal_reason: str | None
    lifecycle_action: str | None = None
    target_artifact_id: str | None = None
    target_path: str | None = None
    transition_state: str | None = None
    transition_attention: str | None = None
    transition_recipient: str | None = None
    expected_lifecycle_revision: str | None = None
    transition_reason: str | None = None
    transition_evidence: tuple[str, ...] = ()
    transition_automatic: bool = False
    digest: str = ""


def _strings(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        stripped = value.strip()
        if not stripped:
            return ()
        if "," in stripped:
            return tuple(part.strip() for part in stripped.split(",") if part.strip())
        return (stripped,)
    if isinstance(value, Mapping):
        return tuple(str(item) for item in value.values() if str(item).strip())
    if isinstance(value, Iterable):
        return tuple(str(item) for item in value if str(item).strip())
    return (str(value),)


def _datetime(value: Any) -> datetime | None:
    if isinstance(value, datetime):
        parsed = value
    elif not isinstance(value, str) or not value.strip():
        return None
    else:
        raw = value.strip()
        try:
            parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def _field_datetime(fields: Mapping[str, Any], *names: str) -> datetime | None:
    for name in names:
        parsed = _datetime(fields.get(name))
        if parsed is not None:
            return parsed
    return None


def _artifact_type(fields: Mapping[str, Any], path: str) -> str:
    explicit = fields.get("type") or fields.get("artifact_type")
    if explicit:
        return str(explicit)
    parts = set(Path(path).parts)
    if "handoffs" in parts:
        return "handoff"
    if "decisions" in parts:
        return "decision"
    if "threads" in parts:
        return "thread"
    if "scrolls" in parts:
        return "scroll"
    return "artifact"


def _title(fields: Mapping[str, Any], path: str) -> str:
    return str(
        fields.get("title")
        or fields.get("topic")
        or fields.get("name")
        or Path(path).stem.replace("-", " ")
    ).strip()


def _created_at(fields: Mapping[str, Any], path: Path) -> datetime:
    parsed = _field_datetime(
        fields, "created_at", "created", "date", "started", "ingested_at"
    )
    if parsed is not None:
        return parsed
    path_date = re.search(r"(?:^|/)(\d{4})-(\d{2})/(\d{2})-", path.as_posix())
    if path_date:
        candidate = _datetime("-".join(path_date.groups()))
        if candidate is not None:
            return candidate
    for part in reversed(path.parts):
        match = re.match(r"(\d{4}-\d{2}-\d{2})", part)
        if match:
            candidate = _datetime(match.group(1))
            if candidate is not None:
                return candidate
    raise LifecycleError("canonical artifact has no deterministic creation date")


def _normal_status(value: Any) -> str:
    normalized = str(value or "active").strip().lower().replace("-", "_")
    aliases = {"completed": "done", "closed": "done", "unread": "pending"}
    return aliases.get(normalized, normalized)


def _obligation(value: str, artifact_type: str) -> ObligationState:
    if artifact_type != "handoff":
        return ObligationState.NONE
    normalized = _normal_status(value)
    return {
        "pending": ObligationState.PENDING,
        "read": ObligationState.READ,
        "claimed": ObligationState.CLAIMED,
        "done": ObligationState.COMPLETED,
        "review_required": ObligationState.REVIEW_REQUIRED,
    }.get(normalized, ObligationState.PENDING)


def _transition_states(
    record: LifecycleRecord, action: LifecycleAction
) -> tuple[ObligationState, AttentionState]:
    if action is LifecycleAction.ACKNOWLEDGE:
        return ObligationState.READ, AttentionState.ACTIVE
    if action is LifecycleAction.CLAIM:
        return ObligationState.CLAIMED, AttentionState.ACTIVE
    if action is LifecycleAction.COMPLETE:
        return ObligationState.COMPLETED, AttentionState.ACTIVE
    if action is LifecycleAction.EXPIRE_ATTENTION:
        return record.obligation_state, AttentionState.EXPIRED
    if action is LifecycleAction.REOPEN:
        return ObligationState.PENDING, AttentionState.ACTIVE
    return ObligationState.REVIEW_REQUIRED, AttentionState.REVIEW_DUE


class CanonicalLifecycleService:
    """Build a disposable lifecycle projection from authorized canonical files."""

    def __init__(
        self,
        memory_root: Path,
        *,
        policy: LifecyclePolicy | None = None,
        clock: Callable[[], datetime] | None = None,
        state_dir: Path | None = None,
        default_org_id: str = "local",
    ) -> None:
        self.memory_root = memory_root.resolve()
        self.policy = policy or LifecyclePolicy()
        self.clock = clock or (lambda: datetime.now(UTC))
        self.state_dir = state_dir.resolve() if state_dir else None
        self.default_org_id = default_org_id

    def scan(
        self,
        *,
        source_revision: str | None = None,
        authorized_scopes: Sequence[str] = ("memory",),
        allowed_artifact_ids: Sequence[str] = (),
        artifact_types: Sequence[str] = (),
        user: str | Sequence[str] | None = None,
    ) -> LifecyclePlan:
        now = self.clock().astimezone(UTC)
        canonical_revision = source_revision or self._canonical_revision()
        snapshots, warnings = self._snapshots(canonical_revision)
        allowed = frozenset(allowed_artifact_ids)
        kinds = frozenset(artifact_types)
        visible_primary = [
            row
            for row in snapshots
            if row.artifact_type != "lifecycle-event"
            and scope_allows_path(row.canonical_path, authorized_scopes)
            and (
                not allowed
                or row.artifact_id in allowed
            )
        ]
        visible_ids = {row.artifact_id for row in visible_primary}
        # Derived lifecycle events inherit the target artifact's scope. Their
        # storage namespace must not require a broader read grant.
        visible_events = [
            row
            for row in snapshots
            if row.artifact_type == "lifecycle-event"
            and row.target_artifact_id in visible_ids
        ]
        visible = [*visible_primary, *visible_events]
        superseders: dict[str, list[str]] = {}
        tentative_supersession_targets: set[str] = set()
        events: dict[str, list[_Snapshot]] = {}
        for row in visible:
            for target in row.supersedes:
                if target in visible_ids:
                    if row.status in {"draft", "proposed", "review"}:
                        tentative_supersession_targets.add(target)
                    else:
                        superseders.setdefault(target, []).append(row.artifact_id)
            if row.artifact_type == "lifecycle-event" and row.target_artifact_id:
                if row.target_artifact_id in visible_ids:
                    events.setdefault(row.target_artifact_id, []).append(row)

        # Supersession outside the authorized result set must not leak a path
        # or id, but it also must not let Observe falsely assert that the old
        # artifact is current. Mark that target ambiguous without naming the
        # hidden successor.
        visible_paths = {row.canonical_path for row in visible}
        hidden_supersession_targets = {
            target
            for row in snapshots
            if row.canonical_path not in visible_paths
            for target in row.supersedes
            if target in visible_ids
        }
        cycle_ids = self._supersession_cycles(visible)

        requested_users = (user,) if isinstance(user, str) else tuple(user or ())
        user_keys = {str(item).casefold().strip() for item in requested_users if str(item).strip()}
        records: list[LifecycleRecord] = []
        for row in visible:
            if row.artifact_type == "lifecycle-event":
                continue
            if kinds and row.artifact_type not in kinds:
                continue
            if user_keys and row.artifact_type == "handoff" and not any(
                recipient.casefold() in user_keys for recipient in row.recipients
            ):
                continue
            matching_events = events.get(row.artifact_id, ())
            if user_keys:
                matching_events = tuple(
                    event
                    for event in matching_events
                    if not event.transition_recipient
                    or event.transition_recipient.casefold() in user_keys
                )
            latest = max(matching_events, key=lambda item: (item.created_at, item.artifact_id), default=None)
            conflicting_events = any(
                len(
                    {
                        (event.transition_state, event.transition_attention)
                        for event in matching_events
                        if event.expected_lifecycle_revision == expected
                    }
                )
                > 1
                for expected in {
                    event.expected_lifecycle_revision
                    for event in matching_events
                    if event.expected_lifecycle_revision
                }
            )
            successors = tuple(sorted(superseders.get(row.artifact_id, ())))
            ambiguous = (
                row.artifact_id in hidden_supersession_targets
                or row.artifact_id in tentative_supersession_targets
                or row.artifact_id in cycle_ids
                or len(successors) > 1
                or any(target not in visible_ids for target in row.supersedes)
                or conflicting_events
            )
            records.append(self._record(row, latest, successors, ambiguous, now))

        records.sort(key=lambda item: (item.created_at, item.artifact_id), reverse=True)
        snapshot_payload = "\n".join(
            f"{row.artifact_id}|{row.digest}" for row in sorted(visible, key=lambda item: item.artifact_id)
        )
        snapshot_id = hashlib.sha256(snapshot_payload.encode("utf-8")).hexdigest()
        return LifecyclePlan(
            schema_version=LIFECYCLE_PLAN_SCHEMA,
            index_spec_version=LIFECYCLE_INDEX_SPEC,
            snapshot_id=snapshot_id,
            generated_at=now,
            source_revision=canonical_revision,
            records=tuple(records),
            warnings=warnings,
        )

    def resolve_paths(
        self,
        paths: Sequence[str],
        *,
        source_revision: str | None,
        authorized_scopes: Sequence[str],
        allowed_artifact_ids: Sequence[str] = (),
    ) -> tuple[Mapping[str, LifecycleRecord], str]:
        requested = {path.replace("\\", "/").strip().lstrip("./") for path in paths}
        plan = self.scan(
            source_revision=source_revision,
            authorized_scopes=authorized_scopes,
            allowed_artifact_ids=allowed_artifact_ids,
        )
        return (
            {record.canonical_path: record for record in plan.records if record.canonical_path in requested},
            plan.snapshot_id,
        )

    def prepare_transition(
        self,
        actor: ActorContext,
        record: LifecycleRecord,
        action: LifecycleAction,
        *,
        reason: str,
        evidence_ids: Sequence[str] = (),
        automatic: bool = False,
        allow_admin: bool = False,
        expected_lifecycle_revision: str | None = None,
    ) -> LifecycleTransition:
        if (
            expected_lifecycle_revision is not None
            and expected_lifecycle_revision != record.lifecycle_revision
        ):
            raise LifecycleError("lifecycle revision changed; rebuild the plan before applying")
        aliases = {
            actor.actor.actor_id.casefold(),
            actor.actor.display_name.casefold(),
            *(str(value).casefold() for value in actor.actor.aliases.values()),
        }
        if actor.account is not None:
            aliases.add(actor.account.display_name.casefold())
            aliases.update(str(value).casefold() for value in actor.account.provider_aliases.values())
        if record.artifact_type == "handoff" and record.recipients and not allow_admin:
            if aliases.isdisjoint(recipient.casefold() for recipient in record.recipients):
                raise LifecycleError("handoff transition actor is not an addressed recipient")
        if automatic and action is LifecycleAction.COMPLETE:
            # V1 can record explicit completion evidence, but cannot yet prove
            # that an arbitrary id is a recipient-authored terminal IMPLEMENTS
            # artifact. Fail closed until canonical verification exists.
            raise LifecycleError(
                "automatic completion requires verified canonical implementation evidence"
            )
        if automatic and action is LifecycleAction.EXPIRE_ATTENTION and not record.automatic_transition_safe:
            raise LifecycleError("automatic expiry is not safe for this lifecycle state")
        if action is LifecycleAction.REOPEN and (
            record.obligation_state is not ObligationState.COMPLETED
            and record.attention_state not in {AttentionState.EXPIRED, AttentionState.REVIEW_DUE}
        ):
            raise LifecycleError("only terminal or review-due work can be reopened")
        if action is LifecycleAction.COMPLETE and record.authority_state in {
            AuthorityState.SUPERSEDED,
            AuthorityState.HISTORICAL,
            AuthorityState.AMBIGUOUS,
        }:
            raise LifecycleError("non-current artifacts cannot be completed")
        if automatic and record.intent not in {"action", "feedback", "fyi"}:
            raise LifecycleError("legacy or unclassified artifacts cannot transition unattended")

        occurred_at = self.clock().astimezone(UTC)
        new_obligation, new_attention = _transition_states(record, action)
        event_id = f"lifecycle-{uuid4().hex}"
        canonical_path = f"lifecycle/events/{occurred_at:%Y-%m}/{occurred_at:%d}-{event_id}.md"
        evidence = tuple(dict.fromkeys(str(item) for item in evidence_ids if str(item).strip()))
        body = (
            f"# Lifecycle event: {action.value} {record.title}\n\n"
            f"Target: `{record.artifact_id}`\n\n"
            f"Reason: {reason.strip()}\n"
        )
        artifact = CanonicalArtifact(
            schema_version=ARTIFACT_SCHEMA_VERSION,
            artifact_id=event_id,
            org_id=actor.profile.org_id,
            artifact_type="lifecycle-event",
            title=f"{action.value}: {record.title}",
            created_at=occurred_at,
            created_by=actor.actor.actor_id,
            status="accepted",
            canonical_path=canonical_path,
            revision="",
            content_hash=content_digest(body),
            relationships=(
                ArtifactRelationship("transitions", record.artifact_id),
                *(ArtifactRelationship("evidence", item) for item in evidence),
            ),
        )
        document = CanonicalDocument(
            artifact=artifact,
            body=body,
            legacy_fields={
                "lifecycle_schema": LIFECYCLE_EVENT_SCHEMA,
                "lifecycle_action": action.value,
                "target_artifact_id": record.artifact_id,
                "target_path": record.canonical_path,
                "actor_alias": actor.actor.display_name,
                "recipient": next(
                    (
                        recipient
                        for recipient in record.recipients
                        if recipient.casefold() in aliases
                    ),
                    None,
                ),
                "previous_obligation": record.obligation_state.value,
                "new_state": new_obligation.value,
                "previous_attention": record.attention_state.value,
                "new_attention": new_attention.value,
                "expected_lifecycle_revision": record.lifecycle_revision,
                "reason": reason.strip(),
                "evidence_ids": list(evidence),
                "automatic": automatic,
                "occurred_at": occurred_at.isoformat().replace("+00:00", "Z"),
            },
        )
        return LifecycleTransition(
            action=action,
            target_artifact_id=record.artifact_id,
            target_path=record.canonical_path,
            previous_obligation=record.obligation_state,
            new_obligation=new_obligation,
            previous_attention=record.attention_state,
            new_attention=new_attention,
            expected_lifecycle_revision=record.lifecycle_revision,
            reason=reason.strip(),
            evidence_ids=evidence,
            automatic=automatic,
            document=document,
        )

    def _record(
        self,
        row: _Snapshot,
        latest: _Snapshot | None,
        superseded_by: tuple[str, ...],
        ambiguous: bool,
        now: datetime,
    ) -> LifecycleRecord:
        status = latest.transition_state if latest and latest.transition_state else row.status
        obligation = _obligation(status, row.artifact_type)
        attention = (
            AttentionState(latest.transition_attention)
            if latest
            and latest.transition_attention
            in {state.value for state in AttentionState}
            else AttentionState.ACTIVE
        )
        authority = AuthorityState.CURRENT
        reason = latest.transition_reason if latest else row.terminal_reason
        evidence = latest.transition_evidence if latest else ()
        review_at = row.review_at
        expires_at = row.attention_expires_at
        if row.artifact_type == "handoff" and expires_at is None:
            days = self.policy.fyi_expiry_days if row.intent == "fyi" else self.policy.handoff_ttl_days
            expires_at = row.created_at + timedelta(days=days)
        retention_until = row.retention_until
        if retention_until is None and self.policy.retention_days is not None:
            retention_until = row.created_at + timedelta(days=self.policy.retention_days)
        age_days = max(0, (now.date() - row.created_at.date()).days)
        recommendation = "keep"
        automatic_safe = False

        if ambiguous:
            authority = AuthorityState.AMBIGUOUS
            recommendation = "review"
        elif superseded_by:
            authority = AuthorityState.SUPERSEDED
            recommendation = "keep_historical"
        elif row.status in {"archived", "historical"}:
            authority = AuthorityState.HISTORICAL
            recommendation = "keep_historical"
        elif obligation is ObligationState.COMPLETED:
            recommendation = "keep_historical"
        elif attention is AttentionState.EXPIRED:
            recommendation = "review_or_reopen"
        elif review_at is not None and review_at <= now:
            attention = AttentionState.REVIEW_DUE
            if obligation not in {ObligationState.NONE, ObligationState.COMPLETED}:
                obligation = ObligationState.REVIEW_REQUIRED
            recommendation = "review"
        elif expires_at is not None and expires_at <= now:
            if row.artifact_type == "handoff" and row.intent == "fyi":
                attention = AttentionState.EXPIRED
                recommendation = "expire_attention"
                automatic_safe = True
            elif row.artifact_type == "handoff" and row.intent in {"action", "feedback"}:
                attention = AttentionState.EXPIRED
                recommendation = "expire_attention"
                automatic_safe = obligation is ObligationState.PENDING
            else:
                attention = AttentionState.REVIEW_DUE
                if obligation not in {ObligationState.NONE, ObligationState.COMPLETED}:
                    obligation = ObligationState.REVIEW_REQUIRED
                recommendation = "review"
        elif row.artifact_type == "handoff" and age_days >= self.policy.review_after_days:
            attention = AttentionState.REVIEW_DUE
            if obligation not in {ObligationState.NONE, ObligationState.COMPLETED}:
                obligation = ObligationState.REVIEW_REQUIRED
            recommendation = "review"

        lifecycle_revision = hashlib.sha256(
            "|".join(
                (
                    row.digest,
                    latest.digest if latest else "",
                    authority.value,
                    attention.value,
                    obligation.value,
                )
            ).encode("utf-8")
        ).hexdigest()
        return LifecycleRecord(
            artifact_id=row.artifact_id,
            canonical_path=row.canonical_path,
            artifact_type=row.artifact_type,
            title=row.title,
            created_at=row.created_at,
            created_by=row.created_by,
            declared_status=row.status,
            authority_state=authority,
            attention_state=attention,
            obligation_state=obligation,
            current_authority=authority is AuthorityState.CURRENT,
            lifecycle_revision=f"sha256:{lifecycle_revision}",
            age_days=age_days,
            created_by_alias=row.created_by_alias,
            intent=row.intent,
            recipients=row.recipients,
            superseded_by=superseded_by,
            review_at=review_at,
            attention_expires_at=expires_at,
            retention_until=retention_until,
            terminal_reason=reason,
            recommendation=recommendation,
            automatic_transition_safe=automatic_safe,
            evidence_ids=evidence,
        )

    @staticmethod
    def _supersession_cycles(rows: Sequence[_Snapshot]) -> frozenset[str]:
        edges = {row.artifact_id: set(row.supersedes) for row in rows if row.supersedes}
        cycles: set[str] = set()

        def visit(origin: str, current: str, trail: tuple[str, ...]) -> None:
            if current in trail:
                start = trail.index(current)
                cycles.update(trail[start:])
                return
            for target in edges.get(current, ()):
                visit(origin, target, (*trail, current))

        for artifact_id in edges:
            visit(artifact_id, artifact_id, ())
        return frozenset(cycles)

    def _snapshots(self, source_revision: str | None) -> tuple[tuple[_Snapshot, ...], tuple[str, ...]]:
        cached = self._read_cache(source_revision) if source_revision else None
        if cached is not None:
            return cached, ()
        rows: list[_Snapshot] = []
        warnings: list[str] = []
        if not self.memory_root.is_dir():
            return (), ("canonical memory root is unavailable",)
        for path in sorted(self.memory_root.rglob("*.md")):
            if ".git" in path.parts or path.name == "index.md":
                continue
            relative = path.relative_to(self.memory_root).as_posix()
            canonical_path = f"memory/{relative}"
            try:
                markdown = path.read_text(encoding="utf-8")
                fields, _ = split_frontmatter(markdown)
                created = _created_at(fields, path)
            except (OSError, ValueError) as exc:
                warnings.append(f"skipped:{canonical_path}:{type(exc).__name__}")
                continue
            artifact_id = canonical_artifact_id(markdown, canonical_path)
            artifact_type = _artifact_type(fields, relative)
            recipients = _strings(
                fields.get("addressed_to")
                or fields.get("addressed_to_user")
                or fields.get("to")
                or fields.get("recipient")
            )
            supersedes = _strings(fields.get("supersedes"))
            rows.append(
                _Snapshot(
                    artifact_id=artifact_id,
                    canonical_path=canonical_path,
                    artifact_type=artifact_type,
                    title=_title(fields, relative),
                    created_at=created,
                    created_by=str(fields.get("created_by") or fields.get("author") or fields.get("from") or "unknown"),
                    created_by_alias=(
                        str(
                            fields.get("creator_alias")
                            or fields.get("actor_alias")
                            or fields.get("from")
                            or fields.get("author")
                            or ""
                        ).strip()
                        or None
                    ),
                    status=_normal_status(
                        fields.get("status")
                        or fields.get("handoff_status")
                        or ("pending" if artifact_type == "handoff" else "active")
                    ),
                    intent=str(fields.get("intent")).lower() if fields.get("intent") else None,
                    recipients=recipients,
                    supersedes=supersedes,
                    review_at=_field_datetime(fields, "review_at", "review_on", "review_date"),
                    attention_expires_at=_field_datetime(fields, "attention_expires_at", "expires_at"),
                    retention_until=_field_datetime(fields, "retention_until"),
                    terminal_reason=str(fields.get("terminal_reason") or fields.get("lifecycle_reason"))
                    if fields.get("terminal_reason") or fields.get("lifecycle_reason")
                    else None,
                    lifecycle_action=str(fields.get("lifecycle_action")) if fields.get("lifecycle_action") else None,
                    target_artifact_id=str(fields.get("target_artifact_id")) if fields.get("target_artifact_id") else None,
                    target_path=str(fields.get("target_path")) if fields.get("target_path") else None,
                    transition_state=str(fields.get("new_state")) if fields.get("new_state") else None,
                    transition_attention=str(fields.get("new_attention")) if fields.get("new_attention") else None,
                    transition_recipient=str(fields.get("recipient")) if fields.get("recipient") else None,
                    expected_lifecycle_revision=str(fields.get("expected_lifecycle_revision"))
                    if fields.get("expected_lifecycle_revision")
                    else None,
                    transition_reason=str(fields.get("reason")) if fields.get("reason") else None,
                    transition_evidence=_strings(fields.get("evidence_ids")),
                    transition_automatic=bool(fields.get("automatic", False)),
                    digest=hashlib.sha256(markdown.encode("utf-8")).hexdigest(),
                )
            )
        result = tuple(rows)
        if source_revision:
            self._write_cache(source_revision, result)
        return result, tuple(warnings[:20])

    def _cache_path(self) -> Path | None:
        return self.state_dir / "projection.json" if self.state_dir else None

    def _canonical_revision(self) -> str:
        try:
            head = subprocess.run(
                ("git", "-C", str(self.memory_root), "rev-parse", "HEAD"),
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            status = subprocess.run(
                (
                    "git", "-C", str(self.memory_root), "status",
                    "--porcelain=v1", "--untracked-files=all",
                ),
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            if head.returncode == 0 and head.stdout.strip() and status.returncode == 0:
                revision = f"git:{head.stdout.strip()}"
                if not status.stdout.strip():
                    return revision
                return f"{revision}+dirty:{self._markdown_manifest_hash()}"
        except (OSError, subprocess.SubprocessError):
            pass
        return f"filesystem:{self._markdown_manifest_hash()}"

    def _markdown_manifest_hash(self) -> str:
        digest = hashlib.sha256()
        for source in sorted(self.memory_root.rglob("*.md")):
            if not source.is_file():
                continue
            digest.update(source.relative_to(self.memory_root).as_posix().encode("utf-8"))
            digest.update(b"\0")
            try:
                digest.update(source.read_bytes())
            except OSError:
                digest.update(b"<unreadable>")
            digest.update(b"\0")
        return digest.hexdigest()[:20]

    def _read_cache(self, source_revision: str) -> tuple[_Snapshot, ...] | None:
        path = self._cache_path()
        if path is None or not path.is_file():
            return None
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            if (
                payload.get("schema") != LIFECYCLE_PLAN_SCHEMA
                or payload.get("index_spec") != LIFECYCLE_INDEX_SPEC
                or payload.get("source_revision") != source_revision
            ):
                return None
            return tuple(
                _Snapshot(
                    **{
                        **item,
                        "created_at": _datetime(item["created_at"]),
                        "review_at": _datetime(item.get("review_at")),
                        "attention_expires_at": _datetime(item.get("attention_expires_at")),
                        "retention_until": _datetime(item.get("retention_until")),
                        "recipients": tuple(item.get("recipients", ())),
                        "supersedes": tuple(item.get("supersedes", ())),
                        "transition_evidence": tuple(item.get("transition_evidence", ())),
                    }
                )
                for item in payload.get("snapshots", ())
            )
        except (OSError, TypeError, ValueError, json.JSONDecodeError):
            return None

    def _write_cache(self, source_revision: str, snapshots: Sequence[_Snapshot]) -> None:
        path = self._cache_path()
        if path is None:
            return
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path.parent, 0o700)
        payload = {
            "schema": LIFECYCLE_PLAN_SCHEMA,
            "index_spec": LIFECYCLE_INDEX_SPEC,
            "source_revision": source_revision,
            "snapshots": [
                {
                    key: (
                        value.isoformat()
                        if isinstance(value, datetime)
                        else list(value)
                        if isinstance(value, tuple)
                        else value
                    )
                    for key, value in asdict(row).items()
                }
                for row in snapshots
            ],
        }
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        temporary.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")), encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(path)
