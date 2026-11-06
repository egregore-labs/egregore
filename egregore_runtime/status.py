"""Bounded canonical status snapshots for activity and dashboard rituals."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
import hashlib
import importlib.util
from functools import lru_cache
import json
from pathlib import Path
import re
import sys
from typing import Any, Iterable, Mapping

from .artifacts import artifact_id_from_path, split_frontmatter
from .contracts import ActorContext, Permission, PolicyDecision
from .line_ids import unmarked
from .identity import actor_presentation_name
from .policy import check, is_admin
from .record_subject import classify_record, record_subject
from .questions import actor_aliases
from .quests import parse_quest_markdown
from .runtime import EgregoreRuntime
from .todos import CanonicalTodoService, parse_todo_markdown


STATUS_SCHEMA_VERSION = "egregore-status-snapshot/v1"
STATUS_INDEX_SPEC_VERSION = "egregore-status-canonical/v1"
MAX_SESSION_SOURCES = 200
MAX_SESSION_RESULTS = 40
MAX_QUEST_RESULTS = 20
MAX_HANDOFF_RESULTS = 30
MAX_QUESTION_RESULTS = 20


@lru_cache(maxsize=1)
def _record_controls():
    lib = Path(__file__).resolve().parents[1] / "bin/lib"
    sys.path.insert(0, str(lib))
    spec = importlib.util.spec_from_file_location("egregore_status_records", lib / "session_record.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _native_control_held(root: Path, control_id: str) -> bool:
    """Reuse public record controls without importing the private producer.

    A personal hold can precede the canonical stub after an interrupted write.
    Failure to inspect that control must not reveal the earlier full record.
    """
    try:
        module = _record_controls()
        return module.native_record_held(module.Context(root), control_id)
    except (OSError, ImportError, ValueError, KeyError, TypeError):
        return True


def _scalar(fields: Mapping[str, Any], *names: str) -> str:
    for name in names:
        value = fields.get(name)
        if value is not None and str(value).strip():
            return str(value).strip()
    return ""


def _legacy_field(markdown: str, name: str) -> str:
    match = re.search(rf"^\*\*{re.escape(name)}\*\*:\s*(.+)$", markdown, re.MULTILINE)
    return match.group(1).strip() if match else ""


def _heading(markdown: str) -> str:
    match = re.search(r"^#(?:\s+[^:]+:)?\s*(.+)$", markdown, re.MULTILINE)
    return match.group(1).strip() if match else ""


def _parse_datetime(value: str) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        try:
            parsed = datetime.fromisoformat(f"{value}T00:00:00+00:00")
        except ValueError:
            return None
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)


def _actor_aliases(actor: ActorContext) -> frozenset[str]:
    values = {actor.actor.actor_id, actor.actor.display_name}
    values.update(str(value) for value in actor.actor.aliases.values())
    if actor.account is not None:
        values.update((actor.account.account_id, actor.account.display_name))
        values.update(str(value) for value in actor.account.provider_aliases.values())
    return frozenset(value.casefold() for value in values if value.strip())


def _activity_status(record) -> str:
    obligation = record.obligation_state.value
    attention = record.attention_state.value
    if obligation == "completed":
        return "done"
    if obligation in {"claimed", "read", "review_required"}:
        return {"review_required": "review_due"}.get(obligation, obligation)
    if attention == "expired" and record.intent == "fyi":
        return "expired"
    return "pending"


def _handoff_row(actor: ActorContext, record) -> dict[str, Any]:
    recipient = record.recipients[0] if len(record.recipients) == 1 else None
    author = actor_presentation_name(
        actor,
        record.created_by,
        record.created_by_alias,
    )
    return {
        "id": record.artifact_id,
        "sessionId": record.artifact_id,
        "topic": record.title,
        "author": author,
        "from": author,
        "authorActorId": record.created_by,
        "recipient": actor_presentation_name(actor, recipient) if recipient else None,
        "to": actor_presentation_name(actor, recipient) if recipient else None,
        "date": record.created_at.date().isoformat(),
        "filePath": record.canonical_path.removeprefix("memory/"),
        "status": _activity_status(record),
        "intent": record.intent or "unclassified",
        "ageDays": record.age_days,
        "authority": record.authority_state.value,
        "attention": record.attention_state.value,
        "obligation": record.obligation_state.value,
        "lifecycleRevision": record.lifecycle_revision,
        "lifecycleReason": record.terminal_reason,
    }


def _extract_open_threads(markdown: str) -> list[str]:
    match = re.search(
        r"^## (?:Open Threads|Next Steps)\s*$\n(.*?)(?=^## |\Z)",
        markdown,
        re.MULTILINE | re.DOTALL | re.IGNORECASE,
    )
    if not match:
        return []
    rows = []
    for line in match.group(1).splitlines():
        item = re.match(r"^\s*(?:[-*]|\d+\.)\s+(?:\[[ xX]\]\s*)?(.+)$", unmarked(line))
        if item and item.group(1).strip():
            rows.append(item.group(1).strip())
    return rows[:3]


@dataclass(slots=True)
class CanonicalStatusSnapshotService:
    """Compile one authorized snapshot without projection or network authority."""

    runtime: EgregoreRuntime
    root: Path
    clock: Any = None
    memory_root: Path = field(init=False)

    def __post_init__(self) -> None:
        self.root = self.root.resolve()
        self.memory_root = (self.root / "memory").resolve()
        if self.clock is None:
            self.clock = lambda: datetime.now(UTC)

    def _decision(self, actor: ActorContext):
        decision = self.runtime.authorize(actor, Permission.READ, ("org:status",))
        if not decision.allowed:
            raise PermissionError("organizational status read denied")
        return decision

    def _admin_visible(self, decision: PolicyDecision) -> bool:
        """Egregore-surface admin protection for listings — fails closed."""

        return is_admin(decision)

    @staticmethod
    def _fields_admin(fields: Mapping[str, Any]) -> bool:
        return str(fields.get("admin", "")).strip().lower() == "true"

    def _session_rows(
        self,
        actor: ActorContext,
        *,
        decision: PolicyDecision,
        cutoff: datetime,
    ) -> tuple[list[dict[str, Any]], int]:
        candidates: list[Path] = []
        for directory in ("sessions", "wraps", "handoffs"):
            base = self.memory_root / directory
            if base.is_dir():
                candidates.extend(base.rglob("*.md"))
        candidates = [path for path in candidates if not path.name.startswith("index")]
        candidates.sort(key=lambda path: path.as_posix(), reverse=True)
        admin_visible = self._admin_visible(decision)
        rows: list[dict[str, Any]] = []
        visible_sources = 0
        for path in candidates:
            relative = path.relative_to(self.memory_root).as_posix()
            canonical = f"memory/{relative}"
            verdict = check(decision, canonical, root=self.memory_root)
            if not verdict.allowed and not verdict.reason.startswith("held:"):
                continue
            # Unreadable paths cannot consume the visible-content budget and
            # displace authorized records merely by sorting ahead of them.
            if visible_sources >= MAX_SESSION_SOURCES:
                break
            visible_sources += 1
            try:
                # Held rows may need legacy body dates; only the masked row is emitted.
                source = verdict.resolved if verdict.allowed else path.resolve()
                markdown = source.read_text(encoding="utf-8")
                fields, _ = split_frontmatter(markdown)
            except (OSError, ValueError):
                continue
            occurred = _parse_datetime(
                _scalar(fields, "date", "created_at", "created")
                or _legacy_field(markdown, "Date")
            )
            if occurred is None or occurred < cutoff:
                continue
            author = (
                _scalar(fields, "from", "author", "created_by", "started_by")
                or _legacy_field(markdown, "Author")
            )
            topic = _scalar(fields, "topic", "title") or _heading(markdown)
            branch = _scalar(fields, "branch") or _legacy_field(markdown, "Branch")
            status = _scalar(fields, "status")
            kind = relative.split("/", 1)[0]
            if not status:
                status = "wrapped" if kind == "wraps" else "handed_off" if kind == "handoffs" else "active"
            subject = classify_record(fields, markdown)
            projection = record_subject(fields, markdown) if subject != "human-session" else None
            control_held = subject != "human-session" and _native_control_held(self.root, str(fields.get("session", "")))
            if verdict.reason.startswith("held:") or (not admin_visible and self._fields_admin(fields)) or control_held or projection and projection.get("held"):
                # Tag-not-hide: existence stays visible, identity does not.
                rows.append(
                    {
                        "id": "[admin]",
                        "date": occurred.isoformat().replace("+00:00", "Z"),
                        "topic": "[admin]",
                        "branch": "",
                        "author": "[admin]",
                        "by": "[admin]",
                        "status": "[admin]",
                        "type": kind if subject == "human-session" else "held-record",
                        "filePath": "[admin]",
                        "openThreads": [],
                    }
                )
                continue
            if subject != "human-session":
                if subject == "unsupported-native":
                    rows.append({"subject_kind": subject, "date": occurred.isoformat().replace("+00:00", "Z")})
                else:
                    rows.append({**projection, "date": occurred.isoformat().replace("+00:00", "Z"),
                                 "id": projection["control_id"], "type": "spirit-record", "filePath": canonical})
                continue
            rows.append(
                {
                    "id": _scalar(fields, "id", "session_id") or path.stem,
                    "date": occurred.isoformat().replace("+00:00", "Z"),
                    "topic": topic,
                    "branch": branch,
                    "author": author,
                    "by": author,
                    "status": status,
                    "type": kind,
                    "filePath": canonical,
                    "openThreads": _extract_open_threads(markdown) if kind == "wraps" else [],
                }
            )
        rows.sort(key=lambda row: row["date"], reverse=True)
        # Only expose sources represented by authorized (possibly masked) rows.
        # The pre-authorization inventory size would disclose unreadable records.
        return rows, len(rows)

    def _quests(self, actor: ActorContext, decision: PolicyDecision) -> list[dict[str, Any]]:
        rows, quests = [], []
        for path in sorted((self.memory_root / "quests").glob("*.md")):
            if path.name in {"_template.md", "index.md"}:
                continue
            verdict = check(decision, f"memory/quests/{path.name}", root=self.memory_root)
            if not verdict.allowed and not verdict.reason.startswith("held:"):
                continue
            source = verdict.resolved if verdict.allowed else path.resolve()
            quest = parse_quest_markdown(source.read_text(encoding="utf-8"), slug=path.stem, org_id=actor.profile.org_id)
            if quest.status != "completed":
                quests.append((quest.priority, quest.started, quest if verdict.allowed else None))
        for _, _, quest in sorted(quests, key=lambda row: row[:2], reverse=True)[:MAX_QUEST_RESULTS]:
            if quest is None:
                rows.append(
                    {
                        "quest": "[admin]",
                        "slug": "[admin]",
                        "title": "[admin]",
                        "status": "[admin]",
                        "projects": [],
                        "priority": "",
                        "started": "",
                        "artifacts": 0,
                        "daysSince": 0,
                    }
                )
                continue
            rows.append(
                {
                    "quest": quest.slug,
                    "slug": quest.slug,
                    "title": quest.title,
                    "status": quest.status,
                    "projects": list(quest.projects),
                    "priority": quest.priority,
                    "started": quest.started,
                    "artifacts": len(re.findall(r"^\s*[-*]\s+\S", quest.body, re.MULTILINE)),
                    "daysSince": max(0, (self.clock().date() - (_parse_datetime(quest.started) or self.clock()).date()).days),
                }
            )
        return rows

    def _todos(
        self, actor: ActorContext, decision: PolicyDecision
    ) -> list[dict[str, Any]]:
        aliases = [actor.actor.display_name, *actor.actor.aliases.values()]
        person = next((str(value) for value in aliases if str(value).strip()), actor.actor.actor_id)
        service = CanonicalTodoService(
            memory_root=self.memory_root,
            write_document=self.runtime.write_document,
        )
        verdict = check(decision, service.canonical_path(person), root=self.memory_root)
        if not verdict.allowed or not verdict.resolved.exists():
            return []
        snapshot = parse_todo_markdown(verdict.resolved.read_text(encoding="utf-8"), person=person)
        return [dict(row) for row in snapshot.todos if row.get("status") in {"open", "blocked", "deferred"}]

    def _questions(self, actor: ActorContext, limit: int) -> list[dict[str, Any]]:
        decision = self.runtime.authorize(actor, Permission.DISCOVER, ("questions",))
        if not decision.allowed:
            return []
        aliases = actor_aliases(actor)
        directory = self.memory_root / "knowledge" / "questions"
        rows = []
        if not directory.is_dir():
            return rows
        for path in sorted(directory.glob("*.md"), reverse=True):
            relative = path.relative_to(self.memory_root).as_posix()
            canonical = f"memory/{relative}"
            verdict = check(decision, canonical, root=self.memory_root)
            if not verdict.allowed:
                continue
            try:
                fields, _ = split_frontmatter(verdict.resolved.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if str(fields.get("status") or "pending") != "pending":
                continue
            if not self._admin_visible(decision) and self._fields_admin(fields):
                continue
            recipient_actor = str(fields.get("to_actor_id") or "").strip()
            recipient_alias = str(fields.get("to") or fields.get("addressed_to") or "").strip().removeprefix("@").casefold()
            if recipient_actor:
                addressed = recipient_actor == actor.actor.actor_id
            else:
                addressed = bool(recipient_alias and recipient_alias in aliases)
            if not addressed:
                continue
            rows.append(
                {
                    "setId": str(fields.get("id") or artifact_id_from_path(relative)),
                    "artifact_id": str(fields.get("id") or artifact_id_from_path(relative)),
                    "topic": str(fields.get("topic") or fields.get("title") or path.stem),
                    "from": str(fields.get("from") or fields.get("created_by") or "unknown"),
                    "created": str(fields.get("created_at") or fields.get("created") or ""),
                    "canonical_path": canonical,
                }
            )
            if len(rows) >= limit:
                break
        return rows

    def build(self, actor: ActorContext, *, time_range: str = "P7D") -> dict[str, Any]:
        decision = self._decision(actor)
        days = {"P1D": 1, "P7D": 7, "P30D": 30, "P365D": 365}.get(time_range, 7)
        now = self.clock().astimezone(UTC)
        rows, source_count = self._session_rows(
            actor,
            decision=decision,
            cutoff=now - timedelta(days=days),
        )
        sessions = [row for row in rows if "subject_kind" not in row and row.get("type") != "held-record"][:MAX_SESSION_RESULTS]
        spirits = [row for row in rows if row.get("subject_kind") == "durable-intent"][:MAX_SESSION_RESULTS]
        held_records = [row for row in rows if row.get("type") == "held-record"][:MAX_SESSION_RESULTS]
        unsupported = sum(row.get("subject_kind") == "unsupported-native" for row in rows)
        aliases = _actor_aliases(actor)
        mine = [row for row in sessions if row["author"].casefold() in aliases]
        team = [row for row in sessions if row["author"] and row["author"].casefold() not in aliases]

        plan = self.runtime.lifecycle_plan(actor, artifact_types=("handoff",), user=actor.actor.display_name)
        handoffs = [_handoff_row(actor, row) for row in plan.records][:MAX_HANDOFF_RESULTS]
        active_handoffs = [row for row in handoffs if row["status"] in {"pending", "read", "claimed"}]
        questions = self._questions(actor, MAX_QUESTION_RESULTS)
        quests = self._quests(actor, decision)
        todos = self._todos(actor, decision)
        open_threads = [
            {"id": row["id"], "date": row["date"], "topic": row["topic"], "threads": row["openThreads"]}
            for row in mine
            if row["openThreads"]
        ][:3]
        payload = {
            "schema_version": STATUS_SCHEMA_VERSION,
            "index_spec_version": STATUS_INDEX_SPEC_VERSION,
            "source_revision": plan.source_revision,
            "org_id": actor.profile.org_id,
            "actor_id": actor.actor.actor_id,
            "generated_at": now.isoformat(),
            "bounds": {
                "session_sources": source_count,
                "session_source_limit": MAX_SESSION_SOURCES,
                "session_result_limit": MAX_SESSION_RESULTS,
                "handoff_result_limit": MAX_HANDOFF_RESULTS,
                "question_result_limit": MAX_QUESTION_RESULTS,
                "quest_result_limit": MAX_QUEST_RESULTS,
            },
            "sessions": sessions,
            "my_sessions": mine,
            "team_sessions": team,
            "spirit_records": spirits,
            "my_spirit_records": [row for row in spirits if row["record_owner_actor_id"] == actor.actor.actor_id],
            "spirit_intents": len(spirits),
            "unsupported_native_records": unsupported,
            "held_records": held_records,
            "spirit_coverage": "bounded",
            "handoffs_to_me": handoffs,
            "handoffs": active_handoffs,
            "pending_questions": questions,
            "questions": questions,
            "answered_questions": [],
            "quests": quests,
            "todos": todos,
            "open_threads": open_threads,
            "stats": {
                "totalSessions": len(mine),
                "wrappedSessions": sum(row["status"] == "wrapped" for row in mine),
                "openTodos": len(todos),
                "oldestTodoDays": max(
                    [max(0, (now.date() - (_parse_datetime(str(row.get("created") or "")) or now).date()).days) for row in todos],
                    default=0,
                ),
            },
            "lifecycle": {
                "available": True,
                "authority": "canonical_markdown",
                "graph_dependency": False,
                "index_spec_version": plan.index_spec_version,
                "source_revision": plan.source_revision,
                "snapshot_id": plan.snapshot_id,
                "review_count": sum(row["status"] == "review_due" for row in handoffs),
            },
        }
        digest_payload = {key: value for key, value in payload.items() if key != "generated_at"}
        digest = hashlib.sha256(json.dumps(digest_payload, sort_keys=True).encode()).hexdigest()
        payload["snapshot_id"] = f"status:{digest[:20]}"
        return payload
