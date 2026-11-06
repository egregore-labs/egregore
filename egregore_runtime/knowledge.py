"""Runtime-owned knowledge capture and private-note promotion.

Reflect and archive produce immutable canonical knowledge. Personal notes stay
outside organizational Git until the actor explicitly promotes one; promotion
then enters the same canonical writeback transaction as every other accepted
knowledge artifact.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import re
from typing import Any, Callable, Iterable, Iterator, Mapping

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalDocument,
    artifact_id_from_path,
    canonical_artifact_id,
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
from . import held
from .errors import AuthorizationDenied
from .policy import allows, check, action_for
from .runtime import EgregoreRuntime


KNOWLEDGE_SCHEMA_VERSION = "egregore-knowledge/v1"
PRIVATE_NOTE_SCHEMA_VERSION = "egregore-private-note/v1"
KNOWLEDGE_TYPES = frozenset({"decision", "finding", "pattern"})
NOTE_TYPES = frozenset({"thought", "session", "retrospective", "journal"})
# Knowledge has two linked layers: a pattern states a general motif, and an
# evidence record (a finding with subtype ``evidence``) keeps the specific,
# dated, sourced case and points at its pattern with ``instance-of``.
RELATIONSHIP_VOCABULARY = ("instance-of", "responds-to", "applies", "supersedes", "relates-to")
SITUATION_KEYS = ("domains", "paths", "activities")


class KnowledgeCaptureError(ValueError):
    """A knowledge capture or private-note operation is invalid."""


def _slug(value: str, *, limit: int = 50) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")[:limit]
    return result or "untitled"


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def relationship_warnings(relationships: Iterable[ArtifactRelationship]) -> tuple[str, ...]:
    """Unknown relations are kept as written and reported, never rejected."""

    known = ", ".join(RELATIONSHIP_VOCABULARY)
    return tuple(
        f"relationship '{row.relation}' is not in the vocabulary ({known}); kept as written"
        for row in relationships
        if row.relation.strip().casefold() not in RELATIONSHIP_VOCABULARY
    )


def normalize_situations(value: Mapping[str, Iterable[str]] | None) -> dict[str, list[str]]:
    """Return ``{domains, paths, activities}`` or ``{}`` when nothing is given."""

    if not value:
        return {}
    unknown = sorted(set(value) - set(SITUATION_KEYS))
    if unknown:
        raise KnowledgeCaptureError(f"unknown situation keys: {', '.join(unknown)}")
    result = {
        key: list(dict.fromkeys(" ".join(str(item).split()) for item in value.get(key, ()) if str(item).strip()))
        for key in SITUATION_KEYS
    }
    for glob in result["paths"]:
        if glob.startswith("/") or ".." in glob.split("/"):
            raise KnowledgeCaptureError("situation paths are repository-relative globs")
    return result if any(result.values()) else {}


def _relations(fields: Mapping[str, Any]) -> Iterator[tuple[str, str]]:
    value = fields.get("relationships")
    for item in value if isinstance(value, list) else ():
        if isinstance(item, Mapping):
            relation = str(item.get("relation") or item.get("type") or "")
            target = str(item.get("target_id") or item.get("target") or item.get("id") or "")
            if relation and target:
                yield relation.strip().casefold(), target.strip()


def _relative(value: str) -> str:
    return value.strip().replace("\\", "/").removeprefix("memory/")


# Situated patterns: a deterministic match of a pattern's situations against
# the paths someone is changing and the words they use. No model calls.
SITUATED_HINT_PREFIX = "Patterns that may apply: "
_STOPWORDS = frozenset(
    "about after again also and any are been before being but can could did does doing for from had has have"
    " how into its just more most not off once only other our out over own same should some such than that the"
    " their them then there these they this those through too under until very was were what when where which"
    " while who why will with would you your".split()
)


def _stem(token: str) -> str:
    if token.endswith("sses"):
        return token[:-2]
    if len(token) > 5 and token.endswith("ing"):
        return token[:-3]
    if len(token) > 3 and token.endswith("s") and not token.endswith("ss"):
        return token[:-1]
    return token


def situation_tokens(text: str) -> frozenset[str]:
    """Casefolded word stems of three or more letters, without stopwords."""

    words = re.findall(r"[^\W_]+", str(text).casefold(), re.UNICODE)
    return frozenset(_stem(word) for word in words if len(word) >= 3 and word not in _STOPWORDS)


def situation_glob_matches(glob: str, path: str) -> bool:
    """Repository-relative glob: ``**`` crosses directories, ``*`` and ``?`` do not.

    Only ``*``, ``**`` and ``?`` are wildcards; ``[`` is a literal character.
    A glob without wildcards names a file or a directory prefix.
    """

    glob = glob.strip().strip("`").removeprefix("./")
    path = path.strip().replace("\\", "/").removeprefix("./")
    if not glob or not path:
        return False
    if not any(char in glob for char in "*?"):
        prefix = glob.rstrip("/")
        return path == prefix or path.startswith(prefix + "/")
    parts, index = [], 0
    while index < len(glob):
        if glob.startswith("**/", index):
            parts.append("(?:.*/)?")
            index += 3
        elif glob.startswith("**", index):
            parts.append(".*")
            index += 2
        else:
            char = glob[index]
            parts.append("[^/]*" if char == "*" else "[^/]" if char == "?" else re.escape(char))
            index += 1
    return re.fullmatch("".join(parts), path) is not None


def _section(body: str, heading: str) -> str:
    """Text under the first ``## <heading>…`` up to the next level-2 heading."""

    match = re.search(rf"^##\s+{re.escape(heading)}[^\n]*\n(.*?)(?=^##\s|\Z)", body, re.I | re.M | re.S)
    return match.group(1).strip() if match else ""


def motif_sentence(body: str, limit: int = 240) -> str:
    """The first sentence of the Motif section, or of the first paragraph."""

    text = _section(body, "Motif")
    if not text:
        paragraphs = [part for part in re.split(r"\n\s*\n", body) if part.strip() and not part.lstrip().startswith("#")]
        text = paragraphs[0] if paragraphs else ""
    text = " ".join(text.replace("*", "").split())
    sentence = re.split(r"(?<=[.!?])\s+", text, maxsplit=1)[0]
    return sentence if len(sentence) <= limit else sentence[: limit - 1].rstrip() + "…"


def _body_situations(body: str) -> dict[str, list[str]]:
    """Read the template's ``Situations (for discovery)`` section for patterns
    written before situations were structured frontmatter."""

    lines: list[str] = []
    for line in _section(body, "Situations").splitlines():
        if re.match(r"^\s*[-*]\s", line) or not lines:
            lines.append(line)
        else:
            lines[-1] += " " + line.strip()
    result: dict[str, list[str]] = {}
    for line in lines:
        match = re.match(r"^\s*[-*]\s*(domains|paths|activities)\s*:\s*(.+)$", line, re.I)
        if not match:
            continue
        key, value = match.group(1).casefold(), match.group(2)
        items = re.findall(r"`([^`]+)`", value) if key == "paths" else re.split(r"[;,]", value)
        result[key] = [item.strip() for item in items if item.strip() and not item.strip().startswith("-")]
    return result


def _instances_any(fields: Mapping[str, Any], keys: set[str]) -> bool:
    return any(
        relation == "instance-of" and (target in keys or _relative(target) in keys)
        for relation, target in _relations(fields)
    )


def situated_hint_line(title: str, canonical_path: str, limit: int = 200) -> str:
    """One offer line within ``limit`` characters, or "" when the path alone is too long."""

    room = limit - len(SITUATED_HINT_PREFIX) - len(canonical_path) - 3
    title = " ".join(str(title).split())
    if room < 8:
        return ""
    if len(title) > room:
        title = title[: room - 1].rstrip() + "…"
    return f"{SITUATED_HINT_PREFIX}{title} ({canonical_path})"


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
        situations: Mapping[str, Iterable[str]] | None = None,
    ) -> WritebackEvent:
        kind = artifact_type.strip().casefold()
        if kind not in KNOWLEDGE_TYPES:
            raise KnowledgeCaptureError("knowledge type must be decision, finding, or pattern")
        situated = normalize_situations(situations)
        if situated and kind != "pattern":
            raise KnowledgeCaptureError("situations describe patterns only; use --type pattern")
        if subtype and subtype.strip().casefold() == "evidence" and kind != "finding":
            raise KnowledgeCaptureError("evidence records are findings; use --type finding --subtype evidence")
        relationships = tuple(relationships)
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
        if not allows(decision, f"memory/{relative}", action_for(decision.permission), root=self.runtime.canonical_root):
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
        if situated:
            legacy["situations"] = situated
        warnings = relationship_warnings(relationships) + self._instance_warnings(actor, relationships)
        receipt = self.runtime.write_document(
            actor,
            CanonicalDocument(
                artifact=artifact,
                body=content,
                policy_hints=hints,
                legacy_fields=legacy,
            ),
        )
        return replace(receipt, warnings=tuple(receipt.warnings) + warnings) if warnings else receipt

    def _readable(self, actor: ActorContext, under: str = "") -> Iterator[tuple[str, dict[str, Any], str]]:
        """Yield ``(memory/path, frontmatter, body)`` for knowledge the actor may read."""

        decision = self.runtime.authorize(actor, Permission.READ)
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons) or "knowledge read denied")
        base = self.memory_root / "knowledge" / under if under else self.memory_root / "knowledge"
        for path in sorted(base.rglob("*.md")) if base.is_dir() else ():
            relative = path.relative_to(self.memory_root).as_posix()
            canonical = f"memory/{relative}"
            verdict = check(decision, canonical, "read", root=self.memory_root)
            if not verdict.allowed:
                continue
            if not path.is_file():
                continue
            try:
                text = verdict.resolved.read_text(encoding="utf-8")
                fields, body = split_frontmatter(text)
                artifact_id = canonical_artifact_id(text, canonical)
            except (OSError, ValueError):
                continue
            # A grant limited to named artifacts reads only those artifacts.
            if not self.runtime.authorize(actor, Permission.READ, (artifact_id,)).allowed:
                continue
            if fields:
                fields["id"] = artifact_id
                if not fields.get("type") and relative.startswith("knowledge/patterns/"):
                    fields["type"] = "pattern"  # legacy patterns predate the typed envelope
                yield canonical, fields, body

    @staticmethod
    def _patterns(rows: Iterable[tuple[str, dict[str, Any], str]]) -> dict[str, tuple[str, dict[str, Any]]]:
        """Map each pattern's stable id and relative path to its record."""

        index: dict[str, tuple[str, dict[str, Any]]] = {}
        for canonical, fields, _ in rows:
            if str(fields.get("type") or "").casefold() == "pattern":
                index[str(fields["id"])] = index[_relative(canonical)] = (canonical, fields)
        return index

    def _instance_warnings(
        self, actor: ActorContext, relationships: Iterable[ArtifactRelationship]
    ) -> tuple[str, ...]:
        targets = [row.target_id for row in relationships if row.relation.strip().casefold() == "instance-of"]
        if not targets:
            return ()
        try:
            known = self._patterns(self._readable(actor))
        except AuthorizationDenied:
            return ()
        return tuple(
            f"instance-of target '{target}' is not a readable pattern; check the pattern id"
            for target in targets
            if target not in known and _relative(target) not in known
        )

    def instances(self, actor: ActorContext, pattern: str) -> dict[str, object]:
        """Reverse lookup: records whose ``instance-of`` points at ``pattern``.

        A typed scan of canonical frontmatter under the actor's read scope; no
        ranking, no graph. ``pattern`` is a stable id or a canonical path.
        """

        rows = list(self._readable(actor))
        patterns = self._patterns(rows)
        found = patterns.get(pattern.strip()) or patterns.get(_relative(pattern))
        if found is None:
            raise KnowledgeCaptureError(f"no readable pattern matches {pattern.strip()}")
        canonical, fields = found
        keys = {str(fields["id"]), _relative(canonical)}

        def summary(path: str, values: Mapping[str, Any]) -> dict[str, object]:
            return {
                "id": str(values["id"]),
                "title": str(values.get("title") or Path(path).stem),
                "type": str(values.get("type") or ""),
                "subtype": str(values.get("subtype") or "") or None,
                "canonical_path": path,
                "created_at": str(values.get("created_at") or values.get("date") or ""),
            }

        matches = [
            summary(path, values)
            for path, values, _ in rows
            if _instances_any(values, keys)
        ]
        matches.sort(key=lambda row: (str(row["created_at"]), str(row["canonical_path"])), reverse=True)
        return {"pattern": summary(canonical, fields), "count": len(matches), "instances": matches}

    def situated(
        self,
        actor: ActorContext,
        *,
        paths: Iterable[str] = (),
        text: str = "",
        limit: int = 3,
        count_instances: bool = True,
    ) -> dict[str, object]:
        """Patterns whose situations are live for these paths and this text.

        Path globs match the given repository paths (3 points per glob);
        domains, activities and topics match by shared word stems (1 point
        per stem). A pattern needs a path match, or two shared stems from at
        least two of its phrases where one phrase matches strongly (all of its
        stems, or at least two). One compound topic alone never fires, and
        common verbs scattered across phrases ("add", "design") do not either.
        Ties order by title, then path. Deterministic; no model calls.
        """

        changed = list(dict.fromkeys(str(path).strip() for path in paths if str(path).strip()))
        words = situation_tokens(text)
        hits: list[dict[str, Any]] = []
        for canonical, fields, body in self._readable(actor, "patterns"):
            if str(fields.get("type") or "").casefold() != "pattern":
                continue
            given = fields.get("situations")
            situations = given if isinstance(given, Mapping) and given else _body_situations(body)

            def listed(key: str, source: Mapping[str, Any] = situations) -> list[str]:
                value = source.get(key)
                return [str(item) for item in value] if isinstance(value, list) else []

            globs = sorted({glob for glob in listed("paths") for path in changed if situation_glob_matches(glob, path)})
            stems = [situation_tokens(phrase) for phrase in
                     (*listed("domains"), *listed("activities"), *listed("topics", fields))]
            phrases = [phrase & words for phrase in stems]
            shared = sorted(set().union(*phrases))
            strong = any(len(hit) >= 2 or (hit and hit == full) for hit, full in zip(phrases, stems))
            if not globs and (not strong or len(shared) < 2 or sum(1 for phrase in phrases if phrase) < 2):
                continue
            hits.append({
                "id": str(fields["id"]),
                "title": str(fields.get("title") or Path(canonical).stem),
                "canonical_path": canonical,
                "motif": motif_sentence(body),
                "score": 3 * len(globs) + len(shared),
                "matched": {"paths": globs, "words": shared},
            })
        hits.sort(key=lambda hit: (-hit["score"], hit["title"].casefold(), hit["canonical_path"]))
        # Packaged here, so the prompt hook's offer line and the CLI hand out the same redacted hits.
        selected = held.kept(self.runtime.authorize(actor, Permission.READ), hits[: max(0, limit)],
                             root=self.memory_root, path="canonical_path")
        if count_instances and selected:
            rows = list(self._readable(actor))
            for hit in selected:
                keys = {hit["id"], _relative(hit["canonical_path"])}
                hit["instances"] = sum(1 for _, values, _ in rows if _instances_any(values, keys))
        return {"count": len(selected), "total": len(hits), "patterns": selected}


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
