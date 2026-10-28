"""Canonical personal todo lifecycle shared by every harness and mode."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Mapping

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalDocument,
    artifact_id_from_path,
    content_digest,
    split_frontmatter,
)
from .contracts import ActorContext, CanonicalArtifact, WritebackEvent


TODO_STATUSES = frozenset({"open", "blocked", "deferred", "done", "cancelled"})
TODO_FIELDS = (
    "id",
    "text",
    "status",
    "priority",
    "created",
    "completed",
    "quest",
    "source",
    "topics",
    "blockedBy",
    "deferredUntil",
    "lastNote",
    "lastTransition",
    "lastTransitionDate",
    "lastCheckIn",
    "evolvedTo",
)


@dataclass(frozen=True, slots=True)
class TodoSnapshot:
    person: str
    admin: bool
    todos: tuple[Mapping[str, Any], ...]


def _slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    if not result:
        raise ValueError("todo person must contain a letter or number")
    return result


def _scalar(raw: str) -> Any:
    value = raw.strip()
    if value in {"", "null", "~"}:
        return None
    if value.casefold() in {"true", "false"}:
        return value.casefold() == "true"
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            return [part.strip().strip("'\"") for part in inner.split(",") if part.strip()]
        return value.strip("'\"")


def parse_todo_markdown(markdown: str, *, person: str) -> TodoSnapshot:
    """Read the historical indented YAML shape and the deterministic v1 shape."""

    fields, _ = split_frontmatter(markdown)
    if isinstance(fields.get("todos"), list):
        rows = tuple(dict(row) for row in fields["todos"] if isinstance(row, Mapping))
        return TodoSnapshot(_slug(person), bool(fields.get("admin", False)), rows)

    normalized = markdown.replace("\r\n", "\n").replace("\r", "\n")
    if not normalized.startswith("---\n"):
        raise ValueError("todo file is missing frontmatter")
    closing = normalized.find("\n---\n", 4)
    if closing < 0:
        raise ValueError("todo file has incomplete frontmatter")
    header = normalized[4:closing].splitlines()
    admin = False
    todos: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    in_todos = False
    for line in header:
        if line.startswith("admin:"):
            admin = bool(_scalar(line.split(":", 1)[1]))
            continue
        if line == "todos:":
            in_todos = True
            continue
        if not in_todos:
            continue
        item = re.match(r"^  - ([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", line)
        field = re.match(r"^    ([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", line)
        if item:
            current = {item.group(1): _scalar(item.group(2))}
            todos.append(current)
        elif field and current is not None:
            current[field.group(1)] = _scalar(field.group(2))
    for row in todos:
        if not row.get("id") or not row.get("text"):
            raise ValueError("todo entry requires id and text")
        if row.get("status", "open") not in TODO_STATUSES:
            raise ValueError("todo entry has an invalid status")
    return TodoSnapshot(_slug(person), admin, tuple(todos))


def _document(actor: ActorContext, snapshot: TodoSnapshot, now: datetime) -> CanonicalDocument:
    path = f"todos/{snapshot.person}.md"
    body = f"# Todos for {snapshot.person}\n"
    created_values = [str(row.get("created")) for row in snapshot.todos if row.get("created")]
    created_at = now
    if created_values:
        try:
            created_at = datetime.fromisoformat(min(created_values).replace("Z", "+00:00"))
        except ValueError:
            pass
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=UTC)
    digest = content_digest(body)
    artifact = CanonicalArtifact(
        schema_version=ARTIFACT_SCHEMA_VERSION,
        artifact_id=artifact_id_from_path(path),
        org_id=actor.profile.org_id,
        artifact_type="todo",
        title=f"Todos for {snapshot.person}",
        created_at=created_at.astimezone(UTC),
        created_by=actor.actor.actor_id,
        status="active",
        canonical_path=path,
        revision=f"sha256:{digest[:16]}",
        content_hash=digest,
    )
    return CanonicalDocument(
        artifact=artifact,
        body=body,
        policy_hints={"owner": snapshot.person},
        legacy_fields={"admin": snapshot.admin, "todos": list(snapshot.todos)},
    )


class CanonicalTodoService:
    def __init__(self, *, memory_root: Path, write_document, clock=None):
        self.memory_root = memory_root.resolve()
        self.write_document = write_document
        self.clock = clock or (lambda: datetime.now(UTC))

    def _path(self, person: str) -> Path:
        return self.memory_root / "todos" / f"{_slug(person)}.md"

    @staticmethod
    def canonical_path(person: str) -> str:
        return f"memory/todos/{_slug(person)}.md"

    def read(self, person: str) -> TodoSnapshot:
        path = self._path(person)
        if not path.exists():
            return TodoSnapshot(_slug(person), False, ())
        return parse_todo_markdown(path.read_text(encoding="utf-8"), person=person)

    def add(
        self,
        actor: ActorContext,
        *,
        person: str,
        text: str,
        priority: int = 0,
        quest: str | None = None,
        source: str = "manual",
    ) -> tuple[Mapping[str, Any], WritebackEvent]:
        clean = " ".join(text.split()).strip()
        if not clean:
            raise ValueError("todo text is required")
        if len(clean) > 200:
            raise ValueError("todo text must be 200 characters or fewer")
        if priority not in range(4):
            raise ValueError("todo priority must be between 0 and 3")
        snapshot = self.read(person)
        if any(row.get("text", "").casefold() == clean.casefold() and row.get("status") == "open" for row in snapshot.todos):
            raise ValueError("an identical open todo already exists")
        now = self.clock().astimezone(UTC)
        prefix = f"{now.date().isoformat()}-{snapshot.person}-"
        sequence = 1 + max(
            (
                int(str(row["id"])[-3:])
                for row in snapshot.todos
                if str(row.get("id", "")).startswith(prefix)
                and str(row["id"])[-3:].isdigit()
            ),
            default=0,
        )
        row: dict[str, Any] = {
            "id": f"{prefix}{sequence:03d}",
            "text": clean,
            "status": "open",
            "priority": priority,
            "created": now.isoformat().replace("+00:00", "Z"),
            "completed": None,
            "quest": quest,
            "source": source,
            "topics": [],
            "blockedBy": None,
            "deferredUntil": None,
            "lastNote": None,
            "lastTransition": None,
            "lastTransitionDate": None,
            "lastCheckIn": None,
            "evolvedTo": None,
        }
        updated = replace(snapshot, todos=(*snapshot.todos, row))
        return row, self.write_document(actor, _document(actor, updated, now))

    def transition(
        self,
        actor: ActorContext,
        *,
        person: str,
        todo_id: str,
        status: str,
    ) -> tuple[Mapping[str, Any], WritebackEvent]:
        if status not in {"done", "cancelled"}:
            raise ValueError("todo transition must be done or cancelled")
        snapshot = self.read(person)
        now = self.clock().astimezone(UTC)
        rows = [dict(row) for row in snapshot.todos]
        matches = [row for row in rows if row.get("id") == todo_id]
        if len(matches) != 1:
            raise ValueError("todo id is missing or ambiguous")
        target = matches[0]
        if target.get("status") != "open":
            raise ValueError("only open todos can be completed or cancelled")
        target["status"] = status
        target["completed"] = now.isoformat().replace("+00:00", "Z")
        target["lastTransition"] = status
        target["lastTransitionDate"] = target["completed"]
        updated = replace(snapshot, todos=tuple(rows))
        return target, self.write_document(actor, _document(actor, updated, now))
