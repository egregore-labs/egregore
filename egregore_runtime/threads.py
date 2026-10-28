"""Runtime-owned Thread intent, fold-in events, and projection inputs.

Threads deliberately keep two substances separate: mutable human intent is
canonical Markdown/Git state, while inferred state is a disposable projection.
Every intent mutation is accompanied by an append-only, actor-attributed event.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
import hashlib
import json
from pathlib import Path
import re
from typing import Any, Callable, Mapping, Sequence
from uuid import UUID

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalDocument,
    content_digest,
    parse_canonical_markdown,
)
from .contracts import ActorContext, ArtifactRelationship, CanonicalArtifact, Permission, WritebackEvent, WritebackStatus
from .errors import AuthorizationDenied
from .policy import scope_allows_path
from .runtime import EgregoreRuntime


THREAD_SCHEMA_VERSION = "egregore-thread/v1"
THREAD_EVENT_SCHEMA_VERSION = "egregore-thread-event/v1"
THREAD_CONFIRMATION = "CONFIRM_THREAD_FOLD"
THREAD_STATUSES = frozenset({"active", "paused", "shipped", "archived"})
THREAD_EVENT_TYPES = frozenset(
    {
        "attach",
        "detach",
        "status-change",
        "blocker-mark",
        "facet-update",
        "glossary-trim",
        "pin",
    }
)
THREAD_FIELDS = frozenset(
    {
        "target",
        "next_steps",
        "membership_seed",
        "steward",
        "stewards",
        "status",
        "composes_into",
        "domain",
        "planning_horizon",
        "next_move",
        "reviewed_at",
        "facets",
        "glossary",
    }
)


class ThreadError(ValueError):
    """A Thread operation violates its stored-intent lifecycle."""


def _slug(value: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")[:50]
    if not normalized:
        raise ThreadError("thread slug must contain a letter or number")
    return normalized


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _clean_strings(values: Sequence[str]) -> tuple[str, ...]:
    return tuple(dict.fromkeys(" ".join(value.split()) for value in values if value.strip()))


def _stable_actor_id(value: str) -> bool:
    if value.startswith(("actor_", "person:", "service:", "agent:", "legacy-actor:")):
        return True
    try:
        UUID(value)
    except (ValueError, AttributeError, TypeError):
        return False
    return True


def _as_mapping(value: Any, *, field: str) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, Mapping):
        raise ThreadError(f"{field} must be an object")
    return dict(value)


@dataclass(frozen=True, slots=True)
class ThreadSnapshot:
    slug: str
    title: str
    target: str
    status: str
    steward_id: str
    steward_ids: tuple[str, ...]
    next_steps: tuple[str, ...]
    membership_seed: Mapping[str, Any]
    composes_into: tuple[str, ...]
    domain: str | None
    planning_horizon: str | None
    next_move: str | None
    reviewed_at: str | None
    facets: Mapping[str, Any]
    glossary: Mapping[str, Any]
    document: CanonicalDocument

    @property
    def revision(self) -> str:
        return self.document.artifact.revision

    def projection_input(self) -> dict[str, Any]:
        """Return stored intent only; callers must add derived envelopes."""

        return {
            "slug": self.slug,
            "target": self.target,
            "status": self.status,
            "steward": self.steward_id,
            "stewards": list(self.steward_ids),
            "next_steps": list(self.next_steps),
            "membership_seed": dict(self.membership_seed),
            "composes_into": list(self.composes_into),
            "domain": self.domain,
            "planning_horizon": self.planning_horizon,
            "next_move": self.next_move,
            "reviewed_at": self.reviewed_at,
            "facets": dict(self.facets),
            "glossary": dict(self.glossary),
            "canonical_revision": self.revision,
        }


@dataclass(frozen=True, slots=True)
class ThreadFoldReceipt:
    thread: ThreadSnapshot
    event_id: str
    receipts: tuple[WritebackEvent, ...]


def parse_thread_markdown(markdown: str, *, slug: str, org_id: str) -> ThreadSnapshot:
    normalized_slug = _slug(slug)
    document = parse_canonical_markdown(
        markdown,
        canonical_path=f"threads/{normalized_slug}.md",
        default_org_id=org_id,
    )
    if document.artifact.artifact_type != "thread":
        raise ThreadError("canonical Thread record has the wrong artifact type")
    fields = document.legacy_fields
    declared_slug = _slug(str(fields.get("slug") or normalized_slug))
    if declared_slug != normalized_slug:
        raise ThreadError("thread slug does not match its canonical path")
    status = document.artifact.status.casefold()
    if status not in THREAD_STATUSES:
        raise ThreadError(f"invalid thread status: {status}")
    steward_id = str(fields.get("steward_id") or fields.get("steward") or "").strip()
    if not steward_id:
        raise ThreadError("thread requires a stable steward actor id")
    if not _stable_actor_id(steward_id):
        raise ThreadError(
            "legacy steward alias is not fold authority; migrate it to a stable actor id"
        )
    raw_stewards = fields.get("steward_ids") or fields.get("stewards") or [steward_id]
    if isinstance(raw_stewards, str):
        raw_stewards = [raw_stewards]
    if not isinstance(raw_stewards, Sequence):
        raise ThreadError("thread stewards must be a list of actor ids")
    steward_ids = tuple(dict.fromkeys([steward_id, *(str(item) for item in raw_stewards)]))
    if not all(_stable_actor_id(value) for value in steward_ids):
        raise ThreadError(
            "legacy steward aliases are not fold authority; migrate them to stable actor ids"
        )
    raw_steps = fields.get("next_steps") or ()
    if isinstance(raw_steps, str):
        raw_steps = [raw_steps]
    raw_composes = fields.get("composes_into") or ()
    if isinstance(raw_composes, str):
        raw_composes = [raw_composes]
    target = str(fields.get("target") or "").strip()
    if not target:
        raise ThreadError("thread target is required")
    return ThreadSnapshot(
        slug=normalized_slug,
        title=document.artifact.title,
        target=target,
        status=status,
        steward_id=steward_id,
        steward_ids=steward_ids,
        next_steps=tuple(str(item) for item in raw_steps if str(item).strip()),
        membership_seed=_as_mapping(fields.get("membership_seed"), field="membership_seed"),
        composes_into=tuple(str(item) for item in raw_composes if str(item).strip()),
        domain=str(fields["domain"]) if fields.get("domain") else None,
        planning_horizon=str(fields["planning_horizon"]) if fields.get("planning_horizon") else None,
        next_move=str(fields["next_move"]) if fields.get("next_move") else None,
        reviewed_at=str(fields["reviewed_at"]) if fields.get("reviewed_at") else None,
        facets=_as_mapping(fields.get("facets"), field="facets"),
        glossary=_as_mapping(fields.get("glossary"), field="glossary"),
        document=document,
    )


def _body(title: str, target: str, next_steps: Sequence[str]) -> str:
    steps = "\n".join(f"- {item}" for item in next_steps) or "- Define the next deliberate move"
    return f"# {title}\n\n## Target\n\n{target}\n\n## Next steps\n\n{steps}\n"


def _replace_or_append_section(body: str, heading: str, content: str) -> str:
    """Update one level-two section without discarding richer Thread prose."""

    normalized = body.rstrip() + "\n"
    pattern = re.compile(
        rf"(?ms)^## {re.escape(heading)}\s*\n.*?(?=^## |\Z)"
    )
    replacement = f"## {heading}\n\n{content.rstrip()}\n\n"
    if pattern.search(normalized):
        return pattern.sub(replacement, normalized, count=1).rstrip() + "\n"
    return normalized.rstrip() + f"\n\n{replacement}"


def _fold_body(current: ThreadSnapshot, field: str, after: Any) -> str:
    if field == "target":
        return _replace_or_append_section(current.document.body, "Target", str(after))
    if field == "next_steps":
        steps = "\n".join(f"- {item}" for item in after)
        return _replace_or_append_section(current.document.body, "Next steps", steps)
    return current.document.body


class CanonicalThreadService:
    """Own Thread authorization, intent folds, event provenance, and reads."""

    def __init__(
        self,
        runtime: EgregoreRuntime,
        memory_root: Path,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.runtime = runtime
        self.memory_root = memory_root.resolve()
        self.clock = clock or (lambda: datetime.now(UTC))

    @staticmethod
    def canonical_path(slug: str) -> str:
        return f"memory/threads/{_slug(slug)}.md"

    def _path(self, slug: str) -> Path:
        return self.memory_root / "threads" / f"{_slug(slug)}.md"

    def _authorize(self, actor: ActorContext, permission: Permission, resource: str, path: str) -> None:
        decision = self.runtime.authorize(actor, permission, (resource,))
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons) or f"thread {permission.value} denied")
        if not scope_allows_path(path, decision.scopes):
            raise AuthorizationDenied("thread path is outside the actor's authorized scope")

    def read(self, actor: ActorContext, slug: str) -> ThreadSnapshot:
        normalized = _slug(slug)
        path = self.canonical_path(normalized)
        self._authorize(actor, Permission.READ, f"thread:{normalized}", path)
        source = self._path(normalized)
        if not source.is_file():
            raise ThreadError(f"thread does not exist: {normalized}")
        return parse_thread_markdown(
            source.read_text(encoding="utf-8"), slug=normalized, org_id=actor.profile.org_id
        )

    def list(self, actor: ActorContext, *, include_archived: bool = False) -> tuple[ThreadSnapshot, ...]:
        decision = self.runtime.authorize(actor, Permission.READ, ("threads",))
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons) or "thread read denied")
        directory = self.memory_root / "threads"
        if not directory.is_dir():
            return ()
        rows = []
        for path in sorted(directory.glob("*.md")):
            if path.name.startswith("_"):
                continue
            canonical = f"memory/threads/{path.name}"
            if not scope_allows_path(canonical, decision.scopes):
                continue
            row = parse_thread_markdown(
                path.read_text(encoding="utf-8"), slug=path.stem, org_id=actor.profile.org_id
            )
            if include_archived or row.status != "archived":
                rows.append(row)
        return tuple(rows)

    def create(
        self,
        actor: ActorContext,
        *,
        title: str,
        target: str,
        slug: str | None = None,
        topics: Sequence[str] = (),
        people: Sequence[str] = (),
        next_steps: Sequence[str] = (),
        window_days: int = 45,
        review_after_days: int = 7,
        attention_ttl_days: int = 30,
        supersedes: Sequence[str] = (),
    ) -> tuple[ThreadSnapshot, WritebackEvent]:
        clean_title = " ".join(title.split()).strip()
        clean_target = " ".join(target.split()).strip()
        if not clean_title or not clean_target:
            raise ThreadError("thread title and target are required")
        if min(window_days, review_after_days, attention_ttl_days) < 1:
            raise ThreadError("thread windows must be positive days")
        normalized = _slug(slug or clean_title)
        canonical = self.canonical_path(normalized)
        self._authorize(actor, Permission.WRITE, f"thread:{normalized}", canonical)
        if self._path(normalized).exists():
            raise ThreadError(f"thread already exists: {normalized}")
        now = self.clock().astimezone(UTC)
        steps = _clean_strings(next_steps)
        body = _body(clean_title, clean_target, steps)
        digest = content_digest(body)
        artifact = CanonicalArtifact(
            schema_version=ARTIFACT_SCHEMA_VERSION,
            artifact_id=f"thread:{normalized}",
            org_id=actor.profile.org_id,
            artifact_type="thread",
            title=clean_title,
            created_at=now,
            created_by=actor.actor.actor_id,
            status="active",
            canonical_path=f"threads/{normalized}.md",
            revision=f"sha256:{digest[:16]}",
            content_hash=digest,
            supersedes=tuple(dict.fromkeys(value for value in supersedes if value)),
        )
        document = CanonicalDocument(
            artifact=artifact,
            body=body,
            policy_hints={"human_intent_only": True, "projection_state": "disposable"},
            legacy_fields={
                "thread_schema": THREAD_SCHEMA_VERSION,
                "slug": normalized,
                "target": clean_target,
                "next_steps": list(steps),
                "membership_seed": {
                    "topics": list(_clean_strings(topics)),
                    "people": list(_clean_strings(people)),
                    "window_days": window_days,
                },
                "steward_id": actor.actor.actor_id,
                "steward_ids": [actor.actor.actor_id],
                "steward_alias": actor.actor.display_name,
                "review_at": _iso(now + timedelta(days=review_after_days)),
                "attention_expires_at": _iso(now + timedelta(days=attention_ttl_days)),
                "reviewed_at": _iso(now),
            },
        )
        receipt = self.runtime.write_document(actor, document)
        return parse_thread_markdown(
            self._path(normalized).read_text(encoding="utf-8") if self._path(normalized).is_file() else "",
            slug=normalized,
            org_id=actor.profile.org_id,
        ) if receipt.status.value != "rejected" else ThreadSnapshot(
            normalized, clean_title, clean_target, "active", actor.actor.actor_id,
            (actor.actor.actor_id,), steps, document.legacy_fields["membership_seed"], (),
            None, None, None, _iso(now), {}, {}, document,
        ), receipt

    def fold(
        self,
        actor: ActorContext,
        *,
        slug: str,
        event_type: str,
        field: str,
        operation: str,
        payload: Any,
        source: str,
        expected_revision: str,
        confirmation: str,
    ) -> ThreadFoldReceipt:
        if confirmation != THREAD_CONFIRMATION:
            raise ThreadError("thread fold requires the exact steward confirmation")
        if event_type not in THREAD_EVENT_TYPES:
            raise ThreadError("unsupported thread event type")
        if field not in THREAD_FIELDS:
            raise ThreadError("unsupported stored-intent field")
        if operation not in {"replace", "append", "remove"}:
            raise ThreadError("thread fold operation must be replace, append, or remove")
        current = self.read(actor, slug)
        self._authorize(actor, Permission.WRITE, f"thread:{current.slug}", self.canonical_path(current.slug))
        if actor.actor.actor_id not in current.steward_ids:
            admin = self.runtime.authorize(actor, Permission.ADMINISTER, (f"thread:{current.slug}",))
            admin_role = bool(
                actor.membership
                and {role.casefold() for role in actor.membership.roles}
                & {"admin", "administrator", "owner", "founder"}
            )
            if not admin.allowed or not admin_role:
                raise AuthorizationDenied("only a stable steward actor id may confirm this fold")
        if current.revision != expected_revision:
            raise ThreadError("thread revision changed; re-open it before confirming the fold")
        intent = current.projection_input()
        before = intent.get(field)
        if operation == "replace":
            after = payload
        elif operation == "append":
            values = list(before or [])
            if payload not in values:
                values.append(payload)
            after = values
        else:
            values = list(before or [])
            after = [value for value in values if value != payload]
        if field == "status" and str(after) not in THREAD_STATUSES:
            raise ThreadError("invalid thread status transition")
        if field == "planning_horizon" and after not in {None, "now", "next", "later"}:
            raise ThreadError("planning horizon must be now, next, or later")
        if field in {"steward", "stewards"}:
            candidates = [str(after)] if field == "steward" else [str(item) for item in after]
            if not all(_stable_actor_id(value) for value in candidates):
                raise ThreadError("stewards must use stable actor ids, not display aliases")
        now = self.clock().astimezone(UTC)
        event_payload = {
            "thread": current.document.artifact.artifact_id,
            "thread_revision": current.revision,
            "occurred_at": _iso(now),
            "actor_id": actor.actor.actor_id,
            "actor_alias": actor.actor.display_name,
            "type": event_type,
            "field": field,
            "op": operation,
            "before": before,
            "payload": payload,
            "after": after,
            "source": source.strip(),
            "confirmed": True,
        }
        encoded = json.dumps(event_payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        event_hash = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
        event_id = f"thread-event:{current.slug}:{event_hash[:20]}"
        event_body = f"# Thread fold: {current.title}\n\n```json\n{encoded}\n```\n"
        event_document = CanonicalDocument(
            artifact=CanonicalArtifact(
                schema_version=ARTIFACT_SCHEMA_VERSION,
                artifact_id=event_id,
                org_id=actor.profile.org_id,
                artifact_type="lifecycle-event",
                title=f"thread fold: {current.title}",
                created_at=now,
                created_by=actor.actor.actor_id,
                status="accepted",
                canonical_path=f"threads/.events/{current.slug}/{event_hash[:20]}.md",
                revision=f"sha256:{content_digest(event_body)[:16]}",
                content_hash=content_digest(event_body),
                relationships=(ArtifactRelationship("transitions", current.document.artifact.artifact_id),),
            ),
            body=event_body,
            legacy_fields={
                "lifecycle_action": "thread-fold",
                "target_artifact_id": current.document.artifact.artifact_id,
                "target_path": f"memory/threads/{current.slug}.md",
                "expected_lifecycle_revision": current.revision,
                "domain_event_schema": THREAD_EVENT_SCHEMA_VERSION,
                "domain_event": event_payload,
            },
        )
        updates = dict(current.document.legacy_fields)
        key = "steward_id" if field == "steward" else "steward_ids" if field == "stewards" else field
        updates[key] = after
        updates["last_event_id"] = event_id
        updates["reviewed_at"] = _iso(now)
        body = _fold_body(current, field, after)
        digest = content_digest(body)
        thread_document = CanonicalDocument(
            artifact=replace(
                current.document.artifact,
                status=str(after) if field == "status" else current.status,
                revision=f"sha256:{digest[:16]}-{event_hash[:8]}",
                content_hash=digest,
            ),
            body=body,
            policy_hints=current.document.policy_hints,
            legacy_fields=updates,
            migrated_from=current.document.migrated_from,
            warnings=current.document.warnings,
            expected_revision=current.revision,
        )
        receipts = self.runtime.write_documents(actor, (event_document, thread_document))
        if any(row.status is WritebackStatus.REJECTED for row in receipts):
            raise ThreadError("Thread canonical persistence failed; partial writes may remain: " +
                              "; ".join(w for row in receipts for w in row.warnings))
        updated = replace(
            current,
            target=str(after) if field == "target" else current.target,
            status=str(after) if field == "status" else current.status,
            steward_id=str(after) if field == "steward" else current.steward_id,
            steward_ids=tuple(str(item) for item in after) if field == "stewards" else current.steward_ids,
            next_steps=tuple(str(item) for item in after) if field == "next_steps" else current.next_steps,
            membership_seed=_as_mapping(after, field=field) if field == "membership_seed" else current.membership_seed,
            composes_into=tuple(str(item) for item in after) if field == "composes_into" else current.composes_into,
            domain=str(after) if field == "domain" and after is not None else current.domain,
            planning_horizon=str(after) if field == "planning_horizon" and after is not None else current.planning_horizon,
            next_move=str(after) if field == "next_move" and after is not None else current.next_move,
            reviewed_at=str(updates["reviewed_at"]),
            facets=_as_mapping(after, field=field) if field == "facets" else current.facets,
            glossary=_as_mapping(after, field=field) if field == "glossary" else current.glossary,
            document=thread_document,
        )
        return ThreadFoldReceipt(updated, event_id, receipts)
