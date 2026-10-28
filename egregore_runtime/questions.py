"""Canonical asynchronous-question lifecycle.

Questions are mutable canonical Markdown artifacts.  This service owns their
creation, discovery, authorized opening, and terminal answer transition; graph
records and notification delivery are optional consumers of the resulting
canonical state.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
import re
from typing import Callable, Iterable

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalDocument,
    artifact_id_from_path,
    content_digest,
    parse_canonical_markdown,
    split_frontmatter,
)
from .contracts import ActorContext, CanonicalArtifact, Permission, WritebackEvent, WritebackStatus
from .errors import AuthorizationDenied
from .policy import scope_allows_path
from .runtime import EgregoreRuntime


QUESTION_SCHEMA_VERSION = "egregore-question/v1"


class QuestionLifecycleError(ValueError):
    """A question lifecycle request is invalid or no longer current."""


@dataclass(frozen=True, slots=True)
class PendingQuestion:
    artifact_id: str
    canonical_path: str
    sender: str
    recipient: str
    topic: str
    created_at: str

    def to_dict(self) -> dict[str, str]:
        return {
            "artifact_id": self.artifact_id,
            "canonical_path": self.canonical_path,
            "sender": self.sender,
            "recipient": self.recipient,
            "topic": self.topic,
            "created_at": self.created_at,
        }


def _normalized_alias(value: str) -> str:
    return value.strip().removeprefix("@").casefold()


def actor_aliases(actor: ActorContext) -> frozenset[str]:
    """Return stable identity plus declared compatibility aliases."""

    values: set[str] = {actor.actor.actor_id, actor.actor.display_name}
    values.update(str(value) for value in actor.actor.aliases.values())
    if actor.account is not None:
        values.update((actor.account.account_id, actor.account.display_name))
        values.update(str(value) for value in actor.account.provider_aliases.values())
        if actor.account.primary_email:
            values.add(actor.account.primary_email)
    return frozenset(_normalized_alias(value) for value in values if value.strip())


def _slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")[:60]
    return result or "question"


class CanonicalQuestionService:
    """Question domain layer over the harness-facing Runtime facade."""

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

    def _question_path(self, *, sender: str, recipient: str, topic: str) -> str:
        date = self.clock().astimezone(UTC).date().isoformat()
        stem = f"{date}-{_slug(sender)}-to-{_slug(recipient)}-{_slug(topic)}"
        directory = self.memory_root / "knowledge" / "questions"
        candidate = directory / f"{stem}.md"
        sequence = 2
        while candidate.exists():
            candidate = directory / f"{stem}-{sequence}.md"
            sequence += 1
        return candidate.relative_to(self.memory_root).as_posix()

    def _relative_path(self, canonical_path: str) -> str:
        candidate = Path(canonical_path)
        if candidate.is_absolute():
            resolved = candidate.resolve()
        else:
            relative = canonical_path.removeprefix("memory/")
            resolved = (self.memory_root / relative).resolve()
        try:
            return resolved.relative_to(self.memory_root).as_posix()
        except ValueError as exc:
            raise QuestionLifecycleError(
                "question path escapes canonical memory"
            ) from exc

    def create(
        self,
        actor: ActorContext,
        *,
        sender_alias: str,
        recipient_alias: str,
        recipient_actor_id: str | None = None,
        topic: str,
        question: str,
        harvest_id: str | None = None,
        harvest_session_id: str | None = None,
        turn: int | None = None,
        question_intent: str | None = None,
        context_mode: str | None = None,
    ) -> WritebackEvent:
        if not recipient_alias.strip() or not topic.strip() or not question.strip():
            raise QuestionLifecycleError("recipient, topic, and question are required")
        if context_mode not in (None, "blind", "disclosed", "comparative"):
            raise QuestionLifecycleError("invalid question context mode")
        if turn is not None and turn < 0:
            raise QuestionLifecycleError("turn must be a non-negative integer")

        now = self.clock().astimezone(UTC)
        sender = sender_alias.strip() or actor.actor.display_name
        recipient = recipient_alias.strip().removeprefix("@")
        relative = self._question_path(sender=sender, recipient=recipient, topic=topic)
        body = f"# Question: {topic.strip()}\n\n## Question\n\n{question.strip()}\n"
        digest = content_digest(body)
        artifact = CanonicalArtifact(
            schema_version=ARTIFACT_SCHEMA_VERSION,
            artifact_id=artifact_id_from_path(relative),
            org_id=actor.profile.org_id,
            artifact_type="question",
            title=topic.strip(),
            created_at=now,
            created_by=actor.actor.actor_id,
            status="pending",
            canonical_path=relative,
            revision=f"sha256:{digest[:16]}",
            content_hash=digest,
            workstream=topic.strip(),
        )
        legacy = {
            "question_schema": QUESTION_SCHEMA_VERSION,
            "from": sender,
            "from_actor_id": actor.actor.actor_id,
            "to": recipient,
            "topic": topic.strip(),
            "created": now.isoformat().replace("+00:00", "Z"),
        }
        if recipient_actor_id and recipient_actor_id.strip():
            legacy["to_actor_id"] = recipient_actor_id.strip()
        optional = {
            "harvest_id": harvest_id,
            "harvest_session_id": harvest_session_id,
            "turn": turn,
            "question_intent": question_intent,
            "context_mode": context_mode,
        }
        legacy.update({key: value for key, value in optional.items() if value is not None})
        return self.runtime.write_document(
            actor,
            CanonicalDocument(artifact=artifact, body=body, legacy_fields=legacy),
        )

    def _authorized_question_paths(self, actor: ActorContext) -> Iterable[Path]:
        decision = self.runtime.authorize(actor, Permission.DISCOVER)
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons))
        directory = self.memory_root / "knowledge" / "questions"
        if not directory.is_dir():
            return ()
        rows: list[Path] = []
        for path in sorted(directory.glob("*.md"), reverse=True):
            canonical = f"memory/{path.relative_to(self.memory_root).as_posix()}"
            if scope_allows_path(canonical, decision.scopes):
                rows.append(path)
        return tuple(rows)

    @staticmethod
    def _addressed_to_actor(fields: dict[str, object], actor: ActorContext) -> bool:
        stable_recipient = str(fields.get("to_actor_id") or "").strip()
        if stable_recipient:
            return stable_recipient == actor.actor.actor_id
        recipient = _normalized_alias(str(fields.get("to") or fields.get("addressed_to") or ""))
        return bool(recipient and recipient in actor_aliases(actor))

    def pending(self, actor: ActorContext, *, limit: int = 20) -> tuple[PendingQuestion, ...]:
        rows: list[PendingQuestion] = []
        for path in self._authorized_question_paths(actor):
            text = path.read_text(encoding="utf-8")
            fields, _ = split_frontmatter(text)
            if str(fields.get("status") or "pending") != "pending":
                continue
            if not self._addressed_to_actor(fields, actor):
                continue
            relative = path.relative_to(self.memory_root).as_posix()
            document = parse_canonical_markdown(
                text,
                canonical_path=relative,
                default_org_id=actor.profile.org_id,
            )
            rows.append(
                PendingQuestion(
                    artifact_id=document.artifact.artifact_id,
                    canonical_path=f"memory/{relative}",
                    sender=str(fields.get("from") or document.artifact.created_by),
                    recipient=str(fields.get("to") or actor.actor.display_name),
                    topic=str(fields.get("topic") or document.artifact.title),
                    created_at=document.artifact.created_at.isoformat(),
                )
            )
            if len(rows) >= limit:
                break
        return tuple(rows)

    def open(self, actor: ActorContext, canonical_path: str) -> str:
        relative = self._relative_path(canonical_path)
        decision = self.runtime.authorize(actor, Permission.READ)
        if not decision.allowed or not scope_allows_path(
            f"memory/{relative}", decision.scopes
        ):
            raise AuthorizationDenied("question is outside the actor read scope")
        source = (self.memory_root / relative).resolve()
        fields, _ = split_frontmatter(source.read_text(encoding="utf-8"))
        if not self._addressed_to_actor(fields, actor):
            raise AuthorizationDenied("question is not addressed to the active actor")

        content = self.runtime.open_source(actor, f"memory/{relative}")
        document = parse_canonical_markdown(
            content,
            canonical_path=relative,
            default_org_id=actor.profile.org_id,
        )
        if document.artifact.artifact_type != "question":
            raise QuestionLifecycleError("selected source is not a question")
        return content

    def answer(
        self,
        actor: ActorContext,
        *,
        canonical_path: str,
        answer: str,
        responder_alias: str,
    ) -> WritebackEvent:
        if not answer.strip():
            raise QuestionLifecycleError("answer body is required")
        content = self.open(actor, canonical_path)
        relative = self._relative_path(canonical_path)
        document = parse_canonical_markdown(
            content,
            canonical_path=relative,
            default_org_id=actor.profile.org_id,
        )
        if document.artifact.status != "pending":
            raise QuestionLifecycleError("question is no longer pending")

        now = self.clock().astimezone(UTC)
        body = document.body.rstrip() + (
            f"\n\n## Answer\n\n**From**: {responder_alias.strip() or actor.actor.display_name}\n"
            f"**At**: {now.isoformat().replace('+00:00', 'Z')}\n\n{answer.strip()}\n"
        )
        legacy = dict(document.legacy_fields)
        legacy.update(
            {
                "answered_by": actor.actor.actor_id,
                "answered_by_alias": responder_alias.strip() or actor.actor.display_name,
                "answered_at": now.isoformat().replace("+00:00", "Z"),
            }
        )
        updated = CanonicalDocument(
            artifact=replace(
                document.artifact,
                status="answered",
                revision="",
                content_hash="",
            ),
            body=body,
            policy_hints=document.policy_hints,
            legacy_fields=legacy,
            expected_revision=document.artifact.revision,
        )
        receipt = self.runtime.write_document(actor, updated)
        if receipt.status is WritebackStatus.REJECTED:
            raise AuthorizationDenied("question answer writeback was denied")
        return receipt
