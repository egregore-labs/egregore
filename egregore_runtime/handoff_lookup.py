"""Deterministic lifecycle lookup for exact handoff questions.

QMD answers fuzzy topical recall; this service answers exact
organizational-state questions — "latest handoff addressed to me", "oldest
unresolved handoff", "what did I last hand off to X" — as a typed operation
over canonical artifact metadata. No QMD, no graph, no ranking: iterate the
canonical handoff repository, filter by stable identity, order by canonical
creation time with a deterministic tie-breaker.

Identity: "me" is the resolved ActorContext. The stable actor id matches
``created_by``/``to_actor_id`` directly; addressing fields written as
handles (``to: oz``) resolve through the actor's own alias set or, for a
named member, through the organization member presentations — addressing
resolution, never authorization. Authorization stays with the Runtime READ
decision, and admin-marked handoffs are withheld from non-admins exactly as
on every other surface.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from .artifacts import split_frontmatter
from .contracts import ActorContext, Permission
from .errors import AuthorizationDenied
from .identity import organization_member_presentations
from .policy import scope_allows_path
from .questions import actor_aliases

_CLOSED_STATUSES = frozenset(
    {"done", "completed", "closed", "resolved", "superseded", "cancelled", "archived"}
)


@dataclass(frozen=True, slots=True)
class HandoffRecord:
    canonical_path: str
    topic: str
    sender: str
    recipient: str
    status: str
    occurred_at: str
    claim: str
    ask: str


def _scalar(fields: Any, *names: str) -> str:
    for name in names:
        value = fields.get(name)
        if value is None:
            continue
        if isinstance(value, list):
            value = ", ".join(str(item) for item in value)
        text = str(value).strip()
        if text:
            return text
    return ""


def _occurred_at(fields: Any, path_stem: str) -> str:
    created = _scalar(fields, "created_at")
    if created:
        return created
    date = _scalar(fields, "date")
    if date:
        # A date-only stamp sorts before any same-day ISO timestamp; suffix
        # with the day's start so date-only records order stably among
        # themselves and the path tie-breaker decides within one day.
        return f"{date}T00:00:00Z"
    return f"0000-00-00T00:00:00Z:{path_stem}"


def _member_terms(root: Path, actor: ActorContext, name: str) -> frozenset[str]:
    """Stable-identity terms for a NAMED member (addressing resolution)."""

    needle = name.strip().removeprefix("@").casefold()
    if not needle:
        return frozenset()
    for member in organization_member_presentations(root, actor):
        values = {
            str(member.display_name).casefold(),
            *(str(alias).casefold() for alias in member.aliases),
        }
        if needle in values:
            return frozenset(values)
    return frozenset({needle})


def _self_terms(actor: ActorContext) -> frozenset[str]:
    return frozenset({actor.actor.actor_id.casefold(), *actor_aliases(actor)})


class HandoffLookupService:
    """Typed lifecycle lookup over the canonical handoff repository."""

    def __init__(self, runtime: Any, root: Path):
        self.runtime = runtime
        self.root = Path(root)
        self.memory_root = (self.root / "memory").resolve()

    def query(
        self,
        actor: ActorContext,
        *,
        addressed_to: str | None = None,
        sent_by: str | None = None,
        status_filter: str = "any",
        order: str = "newest",
        limit: int = 1,
    ) -> list[HandoffRecord]:
        decision = self.runtime.authorize(actor, Permission.READ)
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons))
        scopes = tuple(decision.scopes)

        gate = getattr(self.runtime, "admin_gate", None)
        admin_visible = True
        if gate is not None:
            try:
                admin_visible = bool(gate.actor_is_admin(actor))
            except Exception:
                admin_visible = False

        recipient_terms = self._terms(actor, addressed_to)
        sender_terms = self._terms(actor, sent_by)

        records: list[tuple[str, str, HandoffRecord]] = []
        base = self.memory_root / "handoffs"
        if not base.is_dir():
            return []
        for path in base.rglob("*.md"):
            if path.name.startswith("index"):
                continue
            relative = path.relative_to(self.memory_root).as_posix()
            canonical = f"memory/{relative}"
            if not scope_allows_path(canonical, scopes):
                continue
            if not admin_visible and gate is not None and gate.path_is_admin(canonical):
                continue
            try:
                fields, _ = split_frontmatter(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            status = (_scalar(fields, "status") or "active").casefold()
            if status_filter in ("open", "unresolved") and status in _CLOSED_STATUSES:
                continue
            if recipient_terms is not None:
                recipient_actor = _scalar(fields, "to_actor_id").casefold()
                recipient_text = _scalar(fields, "addressed_to", "to").casefold()
                if recipient_actor:
                    if recipient_actor not in recipient_terms:
                        continue
                elif not self._addressed_match(recipient_text, recipient_terms):
                    continue
            if sender_terms is not None:
                sender_actor = _scalar(fields, "created_by").casefold()
                sender_text = _scalar(fields, "from", "author").casefold()
                if sender_actor and sender_actor in sender_terms:
                    pass
                elif not self._addressed_match(sender_text, sender_terms):
                    continue
            record = HandoffRecord(
                canonical_path=canonical,
                topic=_scalar(fields, "topic", "title") or path.stem,
                sender=_scalar(fields, "from", "author", "created_by") or "unknown",
                recipient=_scalar(fields, "addressed_to", "to") or "unaddressed",
                status=status,
                occurred_at=_occurred_at(fields, path.stem),
                claim=_scalar(fields, "claim"),
                ask=_scalar(fields, "ask"),
            )
            records.append((record.occurred_at, canonical, record))

        records.sort(key=lambda item: (item[0], item[1]), reverse=(order == "newest"))
        return [record for _, _, record in records[: max(1, limit)]]

    def _terms(self, actor: ActorContext, who: str | None) -> frozenset[str] | None:
        if who is None:
            return None
        if who.strip().casefold() in ("me", "self", actor.actor.actor_id.casefold()):
            return _self_terms(actor)
        return _member_terms(self.root, actor, who)

    @staticmethod
    def _addressed_match(text: str, terms: frozenset[str]) -> bool:
        if not text:
            return False
        parts = {
            piece.strip().removeprefix("@").casefold()
            for chunk in text.split(",")
            for piece in chunk.split()
        }
        parts.add(text.strip().casefold())
        return bool(parts & terms)
