"""Runtime-owned knowledge capture and private-note promotion.

Reflect and archive produce immutable canonical knowledge. Personal notes stay
outside organizational Git until the actor explicitly promotes one; promotion
then enters the same canonical writeback transaction as every other accepted
knowledge artifact.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import re
from typing import Callable, Iterable

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalDocument,
    artifact_id_from_path,
    content_digest,
    normalize_markdown_body,
    split_frontmatter,
)
from .contracts import (
    ActorContext,
    ArtifactRelationship,
    CanonicalArtifact,
    Permission,
    SourceProvenance,
    WritebackEvent,
)
from .errors import AuthorizationDenied
from .policy import scope_allows_path
from .runtime import EgregoreRuntime


KNOWLEDGE_SCHEMA_VERSION = "egregore-knowledge/v1"
PRIVATE_NOTE_SCHEMA_VERSION = "egregore-private-note/v1"
KNOWLEDGE_TYPES = frozenset({"decision", "finding", "pattern"})
NOTE_TYPES = frozenset({"thought", "session", "retrospective", "journal"})


class KnowledgeCaptureError(ValueError):
    """A knowledge capture or private-note operation is invalid."""


def _slug(value: str, *, limit: int = 50) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")[:limit]
    return result or "untitled"


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _authorized(runtime: EgregoreRuntime, actor: ActorContext, permission: Permission, resource: str) -> None:
    decision = runtime.authorize(actor, permission, (resource,))
    if not decision.allowed:
        raise AuthorizationDenied("; ".join(decision.reasons) or f"{permission.value} denied")


class CanonicalKnowledgeService:
    """Create accepted decision, finding, and prompting-pattern artifacts."""

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

    def _path(self, artifact_type: str, title: str) -> str:
        directory = {
            "decision": "decisions",
            "finding": "findings",
            "pattern": "patterns",
        }[artifact_type]
        date = self.clock().astimezone(UTC).date().isoformat()
        stem = f"{date}-{_slug(title)}"
        candidate = self.memory_root / "knowledge" / directory / f"{stem}.md"
        sequence = 2
        while candidate.exists():
            candidate = candidate.with_name(f"{stem}-{sequence}.md")
            sequence += 1
        return candidate.relative_to(self.memory_root).as_posix()

    def create(
        self,
        actor: ActorContext,
        *,
        artifact_type: str,
        title: str,
        body: str,
        topics: Iterable[str] = (),
        workstream: str | None = None,
        subtype: str | None = None,
        relationships: Iterable[ArtifactRelationship] = (),
        supersedes: Iterable[str] = (),
        source_provenance: Iterable[SourceProvenance] = (),
        policy_hints: dict[str, object] | None = None,
    ) -> WritebackEvent:
        kind = artifact_type.strip().casefold()
        if kind not in KNOWLEDGE_TYPES:
            raise KnowledgeCaptureError("knowledge type must be decision, finding, or pattern")
        clean_title = " ".join(title.split()).strip()
        if not clean_title:
            raise KnowledgeCaptureError("knowledge title is required")
        content = normalize_markdown_body(body)
        if not content.strip():
            raise KnowledgeCaptureError("knowledge body is required")

        now = self.clock().astimezone(UTC)
        relative = self._path(kind, clean_title)
        digest = content_digest(content)
        decision = self.runtime.authorize(
            actor, Permission.WRITE, (f"knowledge:{kind}",)
        )
        if not decision.allowed:
            raise AuthorizationDenied(
                "; ".join(decision.reasons) or "knowledge write denied"
            )
        if not scope_allows_path(f"memory/{relative}", decision.scopes):
            raise AuthorizationDenied(
                "knowledge path is outside the actor's authorized scope"
            )
        provenance = tuple(source_provenance) or (
            SourceProvenance(
                source_type="session",
                source_id=actor.session_id,
                revision=f"session:{actor.session_id}",
                content_hash=digest,
                observed_at=now,
                imported_by=actor.actor.actor_id,
            ),
        )
        artifact = CanonicalArtifact(
            schema_version=ARTIFACT_SCHEMA_VERSION,
            artifact_id=artifact_id_from_path(relative),
            org_id=actor.profile.org_id,
            artifact_type=kind,
            title=clean_title,
            created_at=now,
            created_by=actor.actor.actor_id,
            status="accepted",
            canonical_path=relative,
            revision=f"sha256:{digest[:16]}",
            content_hash=digest,
            workstream=workstream.strip() if workstream and workstream.strip() else None,
            visibility=("org",),
            relationships=tuple(relationships),
            supersedes=tuple(value for value in supersedes if value),
            provenance=provenance,
        )
        hints = {"knowledge_posture": "share-ready"}
        hints.update(policy_hints or {})
        legacy = {
            "knowledge_schema": KNOWLEDGE_SCHEMA_VERSION,
            "topics": tuple(dict.fromkeys(value.strip() for value in topics if value.strip())),
        }
        if subtype:
            legacy["subtype"] = subtype.strip()
        return self.runtime.write_document(
            actor,
            CanonicalDocument(
                artifact=artifact,
                body=content,
                policy_hints=hints,
                legacy_fields=legacy,
            ),
        )


@dataclass(frozen=True, slots=True)
class PersonalNote:
    note_id: str
    title: str
    note_type: str
    created_at: datetime
    created_by: str
    body: str
    path: Path
    revision: str
    promoted_to: str | None = None

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.note_id,
            "title": self.title,
            "note_type": self.note_type,
            "created_at": _iso(self.created_at),
            "created_by": self.created_by,
            "path": str(self.path),
            "revision": self.revision,
            "promoted_to": self.promoted_to,
        }


class PersonalNoteService:
    """Actor-authorized local notes with an explicit canonical promotion seam."""

    def __init__(
        self,
        runtime: EgregoreRuntime,
        notes_root: Path,
        knowledge: CanonicalKnowledgeService,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.runtime = runtime
        self.notes_root = notes_root.resolve()
        self.knowledge = knowledge
        self.clock = clock or (lambda: datetime.now(UTC))

    def _contained(self, raw_path: str | Path) -> Path:
        candidate = Path(raw_path)
        if not candidate.is_absolute():
            candidate = self.notes_root / candidate
        resolved = candidate.resolve()
        if resolved != self.notes_root and self.notes_root not in resolved.parents:
            raise KnowledgeCaptureError("private note path escapes the active instance")
        return resolved

    def _parse(self, actor: ActorContext, path: Path, text: str) -> PersonalNote:
        fields, body = split_frontmatter(text)
        schema = str(fields.get("schema_version") or "")
        if schema and schema != PRIVATE_NOTE_SCHEMA_VERSION:
            raise KnowledgeCaptureError("unsupported private note schema")
        owner = str(fields.get("created_by") or actor.actor.actor_id)
        if owner != actor.actor.actor_id:
            raise AuthorizationDenied("private note belongs to a different actor")
        created_raw = str(fields.get("created_at") or fields.get("date") or "")
        created = self.clock().astimezone(UTC)
        if created_raw:
            created = datetime.fromisoformat(created_raw.replace("Z", "+00:00"))
            if created.tzinfo is None:
                created = created.replace(tzinfo=UTC)
        normalized = normalize_markdown_body(body)
        digest = content_digest(normalized)
        note_id = str(fields.get("id") or f"note:{actor.actor.actor_id}:{digest[:16]}")
        title = str(fields.get("title") or path.stem.replace("-", " ")).strip()
        note_type = str(fields.get("note_type") or fields.get("type") or "thought")
        return PersonalNote(
            note_id=note_id,
            title=title,
            note_type=note_type,
            created_at=created.astimezone(UTC),
            created_by=owner,
            body=normalized,
            path=path,
            revision=str(fields.get("revision") or f"sha256:{digest[:16]}"),
            promoted_to=str(fields["promoted_to"]) if fields.get("promoted_to") else None,
        )

    def create(
        self,
        actor: ActorContext,
        *,
        title: str,
        body: str,
        note_type: str = "thought",
    ) -> PersonalNote:
        kind = note_type.strip().casefold()
        if kind not in NOTE_TYPES:
            raise KnowledgeCaptureError("private note type is invalid")
        clean_title = " ".join(title.split()).strip()
        content = normalize_markdown_body(body)
        if not clean_title or not content.strip():
            raise KnowledgeCaptureError("private note title and body are required")
        _authorized(self.runtime, actor, Permission.WRITE, "private-note:self")
        now = self.clock().astimezone(UTC)
        digest = content_digest(content)
        stem = f"{now.date().isoformat()}-{_slug(clean_title, limit=40)}"
        owner_root = self.notes_root / actor.actor.actor_id
        target = owner_root / f"{stem}.md"
        sequence = 2
        while target.exists():
            target = owner_root / f"{stem}-{sequence}.md"
            sequence += 1
        note_id = f"note:{actor.actor.actor_id}:{digest[:16]}"
        fields = {
            "schema_version": PRIVATE_NOTE_SCHEMA_VERSION,
            "id": note_id,
            "type": "note",
            "note_type": kind,
            "title": clean_title,
            "created_at": _iso(now),
            "created_by": actor.actor.actor_id,
            "status": "draft",
            "visibility": [f"actor:{actor.actor.actor_id}"],
            "policy_hints": {"posture": "private", "owner": actor.actor.actor_id},
            "revision": f"sha256:{digest[:16]}",
            "content_hash": digest,
        }
        header = ["---", *(f"{key}: {json.dumps(value, ensure_ascii=False)}" for key, value in fields.items()), "---"]
        target.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(target.parent, 0o700)
        temporary = target.with_name(f".{target.name}.tmp")
        temporary.write_text("\n".join(header) + "\n" + content, encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(target)
        return self._parse(actor, target, target.read_text(encoding="utf-8"))

    def open(self, actor: ActorContext, raw_path: str | Path) -> PersonalNote:
        target = self._contained(raw_path)
        relative = target.relative_to(self.notes_root)
        if len(relative.parts) < 2 or relative.parts[0] != actor.actor.actor_id:
            raise AuthorizationDenied("private note belongs to a different actor")
        _authorized(self.runtime, actor, Permission.READ, f"private-note:{target.name}")
        return self._parse(actor, target, target.read_text(encoding="utf-8"))

    def list(self, actor: ActorContext) -> tuple[PersonalNote, ...]:
        _authorized(self.runtime, actor, Permission.DISCOVER, "private-note:self")
        owner_root = self.notes_root / actor.actor.actor_id
        if not owner_root.is_dir():
            return ()
        rows: list[PersonalNote] = []
        for path in sorted(owner_root.glob("*.md"), reverse=True):
            try:
                rows.append(self._parse(actor, path, path.read_text(encoding="utf-8")))
            except AuthorizationDenied:
                continue
        return tuple(rows)

    def promote(
        self,
        actor: ActorContext,
        *,
        raw_path: str | Path,
        artifact_type: str,
        title: str | None = None,
        topics: Iterable[str] = (),
        workstream: str | None = None,
    ) -> WritebackEvent:
        note = self.open(actor, raw_path)
        _authorized(self.runtime, actor, Permission.SHARE, note.note_id)
        digest = content_digest(note.body)
        receipt = self.knowledge.create(
            actor,
            artifact_type=artifact_type,
            title=title or note.title,
            body=note.body,
            topics=topics,
            workstream=workstream,
            source_provenance=(
                SourceProvenance(
                    source_type="private-note",
                    source_id=note.note_id,
                    revision=note.revision,
                    content_hash=digest,
                    observed_at=self.clock().astimezone(UTC),
                    source_uri=note.path.name,
                    imported_by=actor.actor.actor_id,
                ),
            ),
            policy_hints={"promoted_from_private_note": note.note_id},
        )
        if receipt.status.value == "rejected":
            raise AuthorizationDenied("canonical promotion writeback was denied")
        target = f"memory/{receipt.artifact.canonical_path}"
        text = note.path.read_text(encoding="utf-8")
        fields, body = split_frontmatter(text)
        fields["promoted_to"] = target
        fields["promoted_at"] = _iso(self.clock().astimezone(UTC))
        header = ["---", *(f"{key}: {json.dumps(value, ensure_ascii=False)}" for key, value in fields.items()), "---"]
        temporary = note.path.with_name(f".{note.path.name}.tmp")
        temporary.write_text("\n".join(header) + "\n" + normalize_markdown_body(body), encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(note.path)
        return receipt
