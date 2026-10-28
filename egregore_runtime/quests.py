"""Canonical collaborative quest lifecycle shared by every harness and mode."""

from __future__ import annotations

import re
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Mapping, Sequence

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalDocument,
    content_digest,
    parse_canonical_markdown,
    split_frontmatter,
)
from .contracts import ActorContext, CanonicalArtifact, WritebackEvent
from .policy import scope_allows_path


QUEST_STATUSES = frozenset({"active", "paused", "completed"})


def _slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    if not result:
        raise ValueError("quest slug must contain a letter or number")
    return result


def _strings(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        return (value,) if value.strip() else ()
    if isinstance(value, Sequence):
        return tuple(str(item) for item in value if str(item).strip())
    raise ValueError("quest projects must be a list of names")


def _parse_document(markdown: str, *, path: str, org_id: str) -> CanonicalDocument:
    """Adopt historical quest files without inventing author attribution."""

    fields, _ = split_frontmatter(markdown)
    author_fields = ("created_by", "actor", "author", "from", "started_by")
    if not any(fields.get(field) for field in author_fields):
        # One historical Curve Labs quest predates author frontmatter. Keep the
        # absence explicit while allowing an authorized edit to migrate it.
        markdown = markdown.replace("---\n", "---\nstarted_by: unknown\n", 1)
    return parse_canonical_markdown(
        markdown,
        canonical_path=path,
        default_org_id=org_id,
    )


@dataclass(frozen=True, slots=True)
class QuestSnapshot:
    slug: str
    title: str
    status: str
    projects: tuple[str, ...]
    started: str
    started_by: str
    priority: int
    completed: str | None
    body: str
    document: CanonicalDocument


def parse_quest_markdown(
    markdown: str,
    *,
    slug: str,
    org_id: str,
) -> QuestSnapshot:
    normalized_slug = _slug(slug)
    document = _parse_document(
        markdown,
        path=f"quests/{normalized_slug}.md",
        org_id=org_id,
    )
    fields = document.legacy_fields
    declared_slug = _slug(str(fields.get("slug") or normalized_slug))
    if declared_slug != normalized_slug:
        raise ValueError("quest slug does not match its canonical path")
    status = document.artifact.status.casefold()
    if status not in QUEST_STATUSES:
        raise ValueError(f"invalid quest status: {status}")
    priority = int(fields.get("priority") or 0)
    if priority not in range(4):
        raise ValueError("quest priority must be between 0 and 3")
    started = str(fields.get("started") or document.artifact.created_at.date().isoformat())
    started_by = str(fields.get("started_by") or document.artifact.created_by)
    completed = fields.get("completed")
    return QuestSnapshot(
        slug=normalized_slug,
        title=document.artifact.title,
        status=status,
        projects=_strings(fields.get("projects")),
        started=started,
        started_by=started_by,
        priority=priority,
        completed=str(completed) if completed else None,
        body=document.body,
        document=document,
    )


def _document(
    actor: ActorContext,
    snapshot: QuestSnapshot,
    *,
    now: datetime,
    action: str,
) -> CanonicalDocument:
    digest = content_digest(snapshot.body)
    source = snapshot.document
    artifact = replace(
        source.artifact,
        schema_version=ARTIFACT_SCHEMA_VERSION,
        org_id=actor.profile.org_id,
        artifact_type="quest",
        title=snapshot.title,
        status=snapshot.status,
        canonical_path=f"quests/{snapshot.slug}.md",
        revision=f"sha256:{digest[:16]}",
        content_hash=digest,
    )
    fields = dict(source.legacy_fields)
    lifecycle_events = fields.get("lifecycle_events")
    if not isinstance(lifecycle_events, list):
        lifecycle_events = []
    lifecycle_events = [*lifecycle_events, {
        "action": action,
        "actor_id": actor.actor.actor_id,
        "actor_alias": actor.actor.display_name,
        "occurred_at": now.isoformat().replace("+00:00", "Z"),
    }]
    fields.update(
        {
            "slug": snapshot.slug,
            "projects": list(snapshot.projects),
            "started": snapshot.started,
            "started_by": snapshot.started_by,
            "priority": snapshot.priority,
            "completed": snapshot.completed,
            "lifecycle_events": lifecycle_events,
        }
    )
    return CanonicalDocument(
        artifact=artifact,
        body=snapshot.body,
        policy_hints={**source.policy_hints, "collaborative": True},
        legacy_fields=fields,
        migrated_from=source.migrated_from,
        warnings=source.warnings,
    )


def _new_document(
    actor: ActorContext,
    *,
    slug: str,
    title: str,
    question: str,
    projects: Sequence[str],
    threads: Sequence[str],
    now: datetime,
) -> QuestSnapshot:
    thread_lines = [f"- [ ] {' '.join(item.split())}" for item in threads if item.strip()]
    body_lines = [
        f"# {title}",
        "",
        "## The Question",
        "",
        question.strip(),
        "",
        "## Threads",
        "",
        *(thread_lines or ["- [ ] Define the first line of inquiry"]),
        "",
        "## Contributions",
        "",
        "## Artifacts",
        "",
        "## Entry Points",
        "",
        "## Outcome",
        "",
    ]
    body = "\n".join(body_lines)
    digest = content_digest(body)
    started = now.date().isoformat()
    artifact = CanonicalArtifact(
        schema_version=ARTIFACT_SCHEMA_VERSION,
        artifact_id=f"quest:{slug}",
        org_id=actor.profile.org_id,
        artifact_type="quest",
        title=title,
        created_at=now,
        created_by=actor.actor.actor_id,
        status="active",
        canonical_path=f"quests/{slug}.md",
        revision=f"sha256:{digest[:16]}",
        content_hash=digest,
    )
    document = CanonicalDocument(
        artifact=artifact,
        body=body,
        policy_hints={"collaborative": True},
        legacy_fields={
            "slug": slug,
            "projects": list(projects),
            "started": started,
            "started_by": actor.actor.display_name,
            "priority": 0,
            "lifecycle_events": [{
                "action": "created",
                "actor_id": actor.actor.actor_id,
                "actor_alias": actor.actor.display_name,
                "occurred_at": now.isoformat().replace("+00:00", "Z"),
            }],
        },
    )
    return QuestSnapshot(
        slug,
        title,
        "active",
        tuple(projects),
        started,
        actor.actor.display_name,
        0,
        None,
        body,
        document,
    )


def _append_contribution(body: str, *, date: str, actor: str, text: str) -> str:
    entry = f"- {date} — {actor}: {' '.join(text.split())}"
    heading = "## Contributions"
    if heading not in body:
        return body.rstrip() + f"\n\n{heading}\n\n{entry}\n"
    start = body.index(heading) + len(heading)
    next_heading = body.find("\n## ", start)
    if next_heading < 0:
        next_heading = len(body)
    section = body[start:next_heading].rstrip()
    replacement = f"\n\n{section.lstrip()}\n{entry}\n" if section.strip() else f"\n\n{entry}\n"
    return body[:start] + replacement + body[next_heading:].lstrip("\n")


def _set_outcome(body: str, outcome: str) -> str:
    heading = "## Outcome"
    replacement = f"{heading}\n\n{outcome.strip()}\n"
    if heading not in body:
        return body.rstrip() + "\n\n" + replacement
    start = body.index(heading)
    next_heading = body.find("\n## ", start + len(heading))
    if next_heading < 0:
        return body[:start].rstrip() + "\n\n" + replacement
    return body[:start].rstrip() + "\n\n" + replacement + body[next_heading:]


class CanonicalQuestService:
    """Own quest reads and explicit transitions; projections remain downstream."""

    def __init__(self, *, memory_root: Path, write_document, clock=None):
        self.memory_root = memory_root.resolve()
        self.write_document = write_document
        self.clock = clock or (lambda: datetime.now(UTC))

    def _path(self, slug: str) -> Path:
        return self.memory_root / "quests" / f"{_slug(slug)}.md"

    @staticmethod
    def canonical_path(slug: str) -> str:
        return f"memory/quests/{_slug(slug)}.md"

    def _persist(
        self,
        actor: ActorContext,
        snapshot: QuestSnapshot,
        *,
        now: datetime,
        action: str,
    ) -> tuple[QuestSnapshot, WritebackEvent]:
        document = _document(actor, snapshot, now=now, action=action)
        current = replace(snapshot, document=document)
        return current, self.write_document(actor, document)

    def read(self, actor: ActorContext, slug: str) -> QuestSnapshot:
        path = self._path(slug)
        if not path.is_file():
            raise ValueError(f"quest does not exist: {_slug(slug)}")
        return parse_quest_markdown(
            path.read_text(encoding="utf-8"),
            slug=path.stem,
            org_id=actor.profile.org_id,
        )

    def list(
        self,
        actor: ActorContext,
        *,
        include_completed: bool = False,
        authorized_scopes: tuple[str, ...] | None = None,
    ) -> tuple[QuestSnapshot, ...]:
        quest_dir = self.memory_root / "quests"
        if not quest_dir.is_dir():
            return ()
        snapshots = []
        for path in sorted(quest_dir.glob("*.md")):
            if path.name in {"_template.md", "index.md"}:
                continue
            canonical = f"memory/quests/{path.name}"
            if authorized_scopes is not None and not scope_allows_path(
                canonical, authorized_scopes
            ):
                continue
            snapshots.append(self.read(actor, path.stem))
        if not include_completed:
            snapshots = [row for row in snapshots if row.status != "completed"]
        return tuple(sorted(snapshots, key=lambda row: (row.priority, row.started), reverse=True))

    def create(
        self,
        actor: ActorContext,
        *,
        title: str,
        question: str,
        slug: str | None = None,
        projects: Sequence[str] = (),
        threads: Sequence[str] = (),
    ) -> tuple[QuestSnapshot, WritebackEvent]:
        clean_title = " ".join(title.split()).strip()
        clean_question = " ".join(question.split()).strip()
        if not clean_title or not clean_question:
            raise ValueError("quest title and question are required")
        normalized_slug = _slug(slug or clean_title)
        if self._path(normalized_slug).exists():
            raise ValueError(f"quest already exists: {normalized_slug}")
        now = self.clock().astimezone(UTC)
        snapshot = _new_document(
            actor,
            slug=normalized_slug,
            title=clean_title,
            question=clean_question,
            projects=tuple(dict.fromkeys(_slug(item) for item in projects if item.strip())),
            threads=threads,
            now=now,
        )
        receipt = self.write_document(actor, snapshot.document)
        return snapshot, receipt

    def prioritize(
        self,
        actor: ActorContext,
        *,
        slug: str,
        priority: int,
    ) -> tuple[QuestSnapshot, WritebackEvent]:
        if priority not in range(4):
            raise ValueError("quest priority must be between 0 and 3")
        snapshot = replace(self.read(actor, slug), priority=priority)
        return self._persist(
            actor, snapshot, now=self.clock().astimezone(UTC), action="prioritized"
        )

    def transition(
        self,
        actor: ActorContext,
        *,
        slug: str,
        status: str,
        outcome: str | None = None,
    ) -> tuple[QuestSnapshot, WritebackEvent]:
        if status not in {"paused", "completed"}:
            raise ValueError("quest transition must be paused or completed")
        current = self.read(actor, slug)
        if current.status != "active":
            raise ValueError("only an active quest can be paused or completed")
        if status == "completed" and not (outcome or "").strip():
            raise ValueError("completed quests require an outcome")
        now = self.clock().astimezone(UTC)
        snapshot = replace(
            current,
            status=status,
            completed=now.date().isoformat() if status == "completed" else None,
            body=_set_outcome(current.body, outcome or "") if status == "completed" else current.body,
        )
        return self._persist(actor, snapshot, now=now, action=status)

    def contribute(
        self,
        actor: ActorContext,
        *,
        slug: str,
        text: str,
    ) -> tuple[QuestSnapshot, WritebackEvent]:
        clean = " ".join(text.split()).strip()
        if not clean:
            raise ValueError("quest contribution is required")
        current = self.read(actor, slug)
        if current.status != "active":
            raise ValueError("contributions require an active quest")
        now = self.clock().astimezone(UTC)
        snapshot = replace(
            current,
            body=_append_contribution(
                current.body,
                date=now.date().isoformat(),
                actor=actor.actor.display_name,
                text=clean,
            ),
        )
        return self._persist(actor, snapshot, now=now, action="contributed")
