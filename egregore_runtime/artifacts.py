"""Canonical Markdown artifact envelope, compatibility reader, and local store.

Markdown remains the canonical organizational state.  This module standardizes
only the small machine-readable envelope around that Markdown; type-specific
payloads and lifecycles remain owned by their rituals (for example, Scrolls
remain mutable living documents while handoffs are append-only captures).
"""

from __future__ import annotations

import hashlib
import fcntl
from contextlib import contextmanager
import json
import os
import re
import unicodedata
from dataclasses import dataclass, field, replace
from datetime import UTC, date, datetime
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Protocol, runtime_checkable

from .contracts import ArtifactRelationship, CanonicalArtifact, SourceProvenance


ARTIFACT_SCHEMA_VERSION = "egregore-artifact/v1"
_FRONTMATTER_KEY = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):(?:[ \t]*(.*))?$")
# Existing hosted artifact ids are URL-safe opaque tokens and may begin with
# ``-`` or ``_``.  Keep those stable during explicit v1 migration.
_OPAQUE_ID = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._:/-]{2,255}$")


class ArtifactSchemaError(ValueError):
    """A canonical artifact envelope is invalid or cannot be migrated safely."""


class ArtifactConflictError(FileExistsError):
    """An append-only artifact path already contains a different artifact."""


@dataclass(frozen=True, slots=True)
class CanonicalDocument:
    """A canonical artifact plus its Markdown body and advisory policy hints."""

    artifact: CanonicalArtifact
    body: str
    policy_hints: Mapping[str, Any] = field(default_factory=dict)
    legacy_fields: Mapping[str, Any] = field(default_factory=dict)
    migrated_from: str | None = None
    warnings: tuple[str, ...] = ()
    # An authorized re-render of a path the ritual owns (a diagnostic for a
    # date, a republished emissary pointer). Append-only lifecycles stay the
    # default; only a caller that states this intent may replace a stored body.
    replaces_existing: bool = False
    # Optimistic concurrency for a mutable lifecycle update; never serialized.
    expected_revision: str | None = None


@runtime_checkable
class CanonicalArtifactStore(Protocol):
    """Persistence seam for canonical Markdown, independent of Git transport."""

    def check_write(self, document: CanonicalDocument) -> Path: ...

    def persist(self, document: CanonicalDocument) -> Path: ...

    def read(self, canonical_path: str) -> CanonicalDocument: ...


def normalize_markdown_body(content: str) -> str:
    """Return a deterministic UTF-8 Markdown body with LF endings and one EOF LF."""

    normalized = unicodedata.normalize("NFC", content.replace("\r\n", "\n").replace("\r", "\n"))
    return normalized.rstrip("\n") + "\n"


def content_digest(content: str) -> str:
    return hashlib.sha256(normalize_markdown_body(content).encode("utf-8")).hexdigest()


def canonical_relative_path(raw_path: str) -> str:
    """Normalize a repo-relative path and reject traversal/absolute targets."""

    value = raw_path.strip().replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    value = re.sub(r"/{2,}", "/", value)
    candidate = PurePosixPath(value)
    if not value or candidate.is_absolute() or ".." in candidate.parts:
        raise ArtifactSchemaError("canonical_path must be a non-empty relative path")
    return candidate.as_posix()


def artifact_id_from_path(raw_path: str) -> str:
    """Match ``bin/lib/artifact-id.sh`` and the JavaScript artifact package."""

    canonical = canonical_relative_path(raw_path)
    extension = PurePosixPath(canonical).suffix.lower()
    prefix = {".md": "m", ".html": "h"}.get(extension)
    if prefix is None:
        raise ArtifactSchemaError(f"unsupported canonical artifact extension: {extension or '(none)'}")
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:12]
    return f"{prefix}-{digest}"


def canonical_artifact_id(markdown: str, canonical_path: str) -> str:
    """Resolve one stable artifact id for retrieval and direct source opens.

    Typed/hosted artifacts keep their declared opaque id. Historical Markdown
    without one uses the established deterministic path id. Keeping this in the
    domain layer prevents retrieval adapters and harness opens from inventing
    different identities for the same canonical document.
    """

    try:
        fields, _ = split_frontmatter(markdown)
    except ArtifactSchemaError:
        fields = {}
    for key in ("artifact_id", "id", "session_id", "slug"):
        value = fields.get(key)
        if value is None:
            continue
        candidate = str(value).strip()
        if _OPAQUE_ID.fullmatch(candidate):
            return candidate
    relative = canonical_relative_path(canonical_path).removeprefix("memory/")
    return artifact_id_from_path(relative)


def _json_value(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _parse_scalar(raw: str) -> Any:
    value = raw.strip()
    if not value:
        return None
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        pass
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [part.strip().strip("\"'") for part in inner.split(",")]
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1].replace("''", "'")
    lowered = value.lower()
    if lowered in {"true", "false"}:
        return lowered == "true"
    if lowered in {"null", "~"}:
        return None
    # Deliberately retain plain values verbatim.  In particular, a title such
    # as ``Launch: architecture`` is one scalar, not malformed YAML.
    return value


def split_frontmatter(markdown: str) -> tuple[dict[str, Any], str]:
    """Parse the deterministic JSON-in-YAML subset used by v1 and legacy scalars.

    JSON values are valid YAML and let the runtime round-trip nested provenance
    without a YAML dependency.  Unknown indented legacy fields are ignored and
    preserved in the original file until an explicit migration/write occurs.
    """

    normalized = markdown.replace("\r\n", "\n").replace("\r", "\n")
    if not normalized.startswith("---\n"):
        return {}, normalized
    closing = normalized.find("\n---\n", 4)
    if closing < 0:
        raise ArtifactSchemaError("incomplete frontmatter block")
    raw_header = normalized[4:closing]
    result: dict[str, Any] = {}
    for line_number, line in enumerate(raw_header.splitlines(), 2):
        if not line.strip() or line.lstrip().startswith("#") or line[:1].isspace():
            continue
        match = _FRONTMATTER_KEY.match(line)
        if match is None:
            raise ArtifactSchemaError(f"invalid frontmatter line {line_number}")
        key, raw = match.groups()
        if key in result:
            raise ArtifactSchemaError(f"duplicate frontmatter key: {key}")
        result[key] = _parse_scalar(raw or "")
    return result, normalized[closing + 5 :]


def _as_strings(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        return (value,) if value.strip() else ()
    if isinstance(value, (list, tuple, set)):
        return tuple(str(item) for item in value if str(item).strip())
    raise ArtifactSchemaError("expected a string or list of strings")


def _datetime(value: Any, *, field_name: str) -> datetime:
    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, date):
        parsed = datetime(value.year, value.month, value.day, tzinfo=UTC)
    elif isinstance(value, str) and value.strip():
        raw = value.strip()
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw):
            parsed = datetime.fromisoformat(raw).replace(tzinfo=UTC)
        else:
            try:
                parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
            except ValueError as exc:
                raise ArtifactSchemaError(f"{field_name} must be ISO-8601") from exc
    else:
        raise ArtifactSchemaError(f"{field_name} is required")
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def _title(fields: Mapping[str, Any], body: str, canonical_path: str) -> str:
    explicit = fields.get("title") or fields.get("topic") or fields.get("name")
    if explicit:
        return str(explicit).strip()
    heading = re.search(r"^#\s+(.+?)\s*$", body, re.MULTILINE)
    if heading:
        return heading.group(1).strip()
    return PurePosixPath(canonical_path).stem.replace("-", " ").strip()


_TYPE_BY_DIRECTORY = (
    ("handoffs", "handoff"),
    ("decisions", "decision"),
    ("reflections", "reflection"),
    ("wraps", "reflection"),
    ("sessions", "session"),
    ("threads", "thread"),
    ("scrolls", "scroll"),
    ("quests", "quest"),
    ("questions", "question"),
    ("issues", "issue"),
    ("todos", "todo"),
    ("ingest", "ingest-document"),
)

# Types whose lifecycle the artifact store owns: their envelope, identity,
# append-only or living rules, and provenance header are assigned on write.
# A raw file commit must never version one of these behind the store's back.
STORE_MANAGED_ARTIFACT_TYPES = frozenset(
    artifact_type for _, artifact_type in _TYPE_BY_DIRECTORY
) | frozenset({"finding", "pattern"})


def _infer_type(fields: Mapping[str, Any], canonical_path: str) -> str:
    explicit = fields.get("type") or fields.get("artifact_type")
    if explicit:
        return str(explicit)
    kind = fields.get("kind") or fields.get("capture_mode")
    if kind == "addressed":
        return "handoff"
    parts = set(PurePosixPath(canonical_path).parts)
    for directory, artifact_type in _TYPE_BY_DIRECTORY:
        if directory in parts:
            return artifact_type
    return "artifact"


def store_managed_reason(markdown: str) -> str | None:
    """Say why raw Markdown belongs to the artifact store, or None if it does not.

    Only what the file itself declares counts. Directory inference would claim
    compatibility ledgers such as ``handoffs/index.md``, which carry no
    envelope and are versioned as plain canonical files.
    """

    try:
        fields, _ = split_frontmatter(markdown)
    except ArtifactSchemaError:
        return None
    if (fields.get("schema_version") or fields.get("schema")) == ARTIFACT_SCHEMA_VERSION:
        return f"declares {ARTIFACT_SCHEMA_VERSION}"
    declared = fields.get("type") or fields.get("artifact_type")
    if declared and str(declared).strip() in STORE_MANAGED_ARTIFACT_TYPES:
        return f"declares the store-managed type {str(declared).strip()}"
    return None


def _relationships(value: Any) -> tuple[ArtifactRelationship, ...]:
    if value is None:
        return ()
    if not isinstance(value, (list, tuple)):
        raise ArtifactSchemaError("relationships must be a list")
    rows: list[ArtifactRelationship] = []
    for item in value:
        if isinstance(item, str):
            rows.append(ArtifactRelationship("related-to", item))
        elif isinstance(item, Mapping):
            relation = item.get("relation") or item.get("type")
            target = item.get("target_id") or item.get("target") or item.get("id")
            if not relation or not target:
                raise ArtifactSchemaError("each relationship needs relation and target_id")
            rows.append(ArtifactRelationship(str(relation), str(target)))
        else:
            raise ArtifactSchemaError("invalid relationship")
    return tuple(rows)


def _provenance(value: Any) -> tuple[SourceProvenance, ...]:
    if value is None:
        return ()
    candidates = value if isinstance(value, (list, tuple)) else [value]
    rows: list[SourceProvenance] = []
    for item in candidates:
        if not isinstance(item, Mapping):
            continue
        required = ("source_type", "source_id", "revision", "content_hash", "observed_at")
        if not all(item.get(key) is not None for key in required):
            # Historical ingest provenance was an open evidence object.  It is
            # preserved as a legacy field, but cannot masquerade as typed v1
            # provenance without its source identity and revision.
            continue
        rows.append(
            SourceProvenance(
                source_type=str(item["source_type"]),
                source_id=str(item["source_id"]),
                revision=str(item["revision"]),
                content_hash=str(item["content_hash"]),
                observed_at=_datetime(item["observed_at"], field_name="provenance.observed_at"),
                source_uri=str(item["source_uri"]) if item.get("source_uri") else None,
                imported_by=str(item["imported_by"]) if item.get("imported_by") else None,
            )
        )
    return tuple(rows)


def validate_artifact(artifact: CanonicalArtifact, body: str) -> CanonicalArtifact:
    """Validate the common v1 envelope and return its normalized form."""

    if artifact.schema_version != ARTIFACT_SCHEMA_VERSION:
        raise ArtifactSchemaError(f"unsupported artifact schema: {artifact.schema_version}")
    canonical_path = canonical_relative_path(artifact.canonical_path)
    if not _OPAQUE_ID.fullmatch(artifact.artifact_id):
        raise ArtifactSchemaError("artifact_id must be an opaque non-empty identifier")
    for name, value in (
        ("org_id", artifact.org_id),
        ("artifact_type", artifact.artifact_type),
        ("title", artifact.title),
        ("created_by", artifact.created_by),
        ("status", artifact.status),
        ("revision", artifact.revision),
    ):
        if not value or not str(value).strip():
            raise ArtifactSchemaError(f"{name} is required")
    if artifact.created_at.tzinfo is None:
        raise ArtifactSchemaError("created_at must include a timezone")
    actual_hash = content_digest(body)
    if artifact.content_hash not in {actual_hash, f"sha256:{actual_hash}"}:
        raise ArtifactSchemaError("content_hash does not match the normalized Markdown body")
    if any(not row.relation or not row.target_id for row in artifact.relationships):
        raise ArtifactSchemaError("relationships require relation and target_id")
    return replace(
        artifact,
        canonical_path=canonical_path,
        created_at=artifact.created_at.astimezone(UTC),
        content_hash=actual_hash,
    )


def parse_canonical_markdown(
    markdown: str,
    *,
    canonical_path: str,
    default_org_id: str | None = None,
    default_created_at: datetime | None = None,
    default_created_by: str | None = None,
    recompute_digest: bool = False,
) -> CanonicalDocument:
    """Read v1 Markdown or migrate a legacy artifact into the common envelope.

    ``recompute_digest`` derives ``revision`` and ``content_hash`` from the body
    that was just read instead of trusting the declared envelope. A caller that
    re-reads a file it may itself have rewritten uses it; ordinary reads stay
    strict so a stale digest is still reported as a schema error.
    """

    path = canonical_relative_path(canonical_path)
    fields, raw_body = split_frontmatter(markdown)
    body = normalize_markdown_body(raw_body)
    schema = fields.get("schema_version") or fields.get("schema")
    is_v1 = schema == ARTIFACT_SCHEMA_VERSION
    if is_v1:
        required = (
            "id", "org", "type", "title", "created_at", "created_by", "status",
            "canonical_path", "revision", "content_hash",
        )
        missing = [key for key in required if fields.get(key) in (None, "")]
        if missing:
            raise ArtifactSchemaError(f"v1 frontmatter is missing: {', '.join(missing)}")
        declared_path = canonical_relative_path(str(fields["canonical_path"]))
        if declared_path != path:
            raise ArtifactSchemaError("canonical_path does not match the opened source path")
    org_id = fields.get("org") or fields.get("org_id") or default_org_id
    if not org_id:
        raise ArtifactSchemaError("org is required (or supply default_org_id for legacy artifacts)")
    artifact_id = fields.get("id") or fields.get("artifact_id") or artifact_id_from_path(path)
    created_raw = (
        fields.get("created_at")
        or fields.get("date")
        or fields.get("ingested_at")
        or fields.get("started")
        or (default_created_at if not is_v1 else None)
    )
    if created_raw is None:
        raise ArtifactSchemaError("created_at is required and could not be migrated")
    created_by = (
        fields.get("created_by")
        or fields.get("actor")
        or fields.get("author")
        or fields.get("from")
        or fields.get("started_by")
        or (default_created_by if not is_v1 else None)
    )
    if not created_by:
        raise ArtifactSchemaError("created_by is required and could not be migrated")

    relationships_value = fields.get("relationships")
    if relationships_value is None:
        legacy_related = fields.get("related") or fields.get("references")
        relationships_value = _as_strings(legacy_related) if legacy_related else ()
    provenance = _provenance(fields.get("source_provenance") or fields.get("provenance"))
    if not provenance and fields.get("source_id") and fields.get("content_hash"):
        provenance = (
            SourceProvenance(
                source_type=str(fields.get("source_type") or "ingest"),
                source_id=str(fields["source_id"]),
                revision=str(fields.get("source_revision") or fields.get("revision") or fields["content_hash"]),
                content_hash=str(fields["content_hash"]),
                observed_at=_datetime(created_raw, field_name="created_at"),
                source_uri=str(fields["source_path"]) if fields.get("source_path") else None,
                imported_by=str(created_by),
            ),
        )

    actual_hash = content_digest(body)
    artifact = CanonicalArtifact(
        schema_version=ARTIFACT_SCHEMA_VERSION,
        artifact_id=str(artifact_id),
        org_id=str(org_id),
        artifact_type=_infer_type(fields, path),
        title=_title(fields, body, path),
        created_at=_datetime(created_raw, field_name="created_at"),
        created_by=str(created_by),
        status=str(fields.get("status") or ("unverified" if _infer_type(fields, path) == "ingest-document" else "active")),
        canonical_path=path,
        revision=(
            f"sha256:{actual_hash[:16]}"
            if recompute_digest
            else str(fields.get("revision") or f"sha256:{actual_hash[:16]}")
        ),
        content_hash=(
            actual_hash
            if recompute_digest or not is_v1
            else str(fields["content_hash"])
        ),
        workstream=str(fields.get("workstream") or fields.get("topic") or fields.get("project"))
        if fields.get("workstream") or fields.get("topic") or fields.get("project")
        else None,
        visibility=_as_strings(fields.get("visibility")),
        relationships=_relationships(relationships_value),
        supersedes=_as_strings(fields.get("supersedes")),
        provenance=provenance,
    )
    artifact = validate_artifact(artifact, body)

    common_keys = {
        "schema_version", "schema", "id", "artifact_id", "org", "org_id", "type",
        "artifact_type", "title", "created_at", "created_by", "status", "revision",
        "content_hash", "workstream", "visibility", "relationships", "supersedes",
        "source_provenance", "policy_hints", "canonical_path",
    }
    policy_hints = fields.get("policy_hints") if isinstance(fields.get("policy_hints"), Mapping) else {}
    policy_hints = dict(policy_hints)
    for key in ("admin", "boundaries"):
        if key in fields:
            policy_hints[key] = fields[key]
    warnings = () if is_v1 else ("legacy frontmatter migrated in memory; source file was not rewritten",)
    return CanonicalDocument(
        artifact=artifact,
        body=body,
        policy_hints=policy_hints,
        legacy_fields={key: value for key, value in fields.items() if key not in common_keys},
        migrated_from=None if is_v1 else str(schema or "unversioned"),
        warnings=warnings,
    )


def render_canonical_markdown(document: CanonicalDocument) -> str:
    """Serialize a canonical document as deterministic, parseable Markdown."""

    artifact = validate_artifact(document.artifact, document.body)
    fields: list[tuple[str, Any]] = [
        ("schema_version", artifact.schema_version),
        ("id", artifact.artifact_id),
        ("org", artifact.org_id),
        ("type", artifact.artifact_type),
        ("title", artifact.title),
        ("created_at", artifact.created_at.isoformat().replace("+00:00", "Z")),
        ("created_by", artifact.created_by),
        ("workstream", artifact.workstream),
        ("status", artifact.status),
        ("relationships", [row.to_dict() for row in artifact.relationships]),
        ("supersedes", list(artifact.supersedes)),
        ("source_provenance", [row.to_dict() for row in artifact.provenance]),
        ("visibility", list(artifact.visibility)),
        ("policy_hints", dict(document.policy_hints)),
        ("canonical_path", artifact.canonical_path),
        ("revision", artifact.revision),
        ("content_hash", artifact.content_hash),
    ]
    common_names = {key for key, _ in fields}
    fields.extend(
        (key, value)
        for key, value in document.legacy_fields.items()
        if key not in common_names and value is not None
    )
    header = ["---", *(f"{key}: {_json_value(value)}" for key, value in fields if value not in (None, (), [], {})), "---"]
    return "\n".join(header) + "\n" + normalize_markdown_body(document.body)


class LocalMarkdownArtifactStore:
    """Atomic filesystem store with explicit append-only vs living lifecycles."""

    def __init__(
        self,
        root: Path,
        *,
        mutable_types: frozenset[str] = frozenset(
            {"scroll", "thread", "question", "quest", "todo", "issue"}
        ),
    ):
        self.root = root.resolve()
        self.mutable_types = mutable_types

    def _target(self, canonical_path: str) -> Path:
        relative = canonical_relative_path(canonical_path)
        target = (self.root / relative).resolve()
        if target != self.root and self.root not in target.parents:
            raise ArtifactSchemaError("canonical path escapes the artifact store")
        return target

    def check_write(self, document: CanonicalDocument) -> Path:
        """Validate identity and conflicts without changing the filesystem."""
        artifact = validate_artifact(document.artifact, document.body)
        target = self._target(artifact.canonical_path)
        if document.expected_revision is not None and not target.exists():
            raise ArtifactConflictError("canonical source disappeared; reopen before retrying")
        if target.exists():
            # Legacy sources may not yet declare organization identity. The
            # authorized incoming document supplies the active organization
            # for this one-time typed migration; ordinary reads remain strict.
            existing = parse_canonical_markdown(
                target.read_text(encoding="utf-8"),
                canonical_path=artifact.canonical_path,
                default_org_id=artifact.org_id,
                default_created_at=artifact.created_at if document.migrated_from is not None else None,
                default_created_by=artifact.created_by if document.migrated_from is not None else None,
                # A replacing write re-renders a path whose stored envelope may
                # already disagree with its edited body. Stable identity, not a
                # stale digest, decides whether that replacement is legitimate.
                recompute_digest=document.replaces_existing,
            )
            if document.expected_revision is not None and existing.artifact.revision != document.expected_revision:
                raise ArtifactConflictError("canonical source revision changed; reopen before retrying")
            if existing.artifact.artifact_id != artifact.artifact_id:
                raise ArtifactConflictError("artifact path belongs to a different stable id")
            if artifact.artifact_type not in self.mutable_types and not document.replaces_existing:
                if existing.artifact.content_hash == artifact.content_hash:
                    # An explicit writeback of a legacy document is its safe,
                    # typed migration point. Preserve ritual-specific fields.
                    if document.migrated_from is None:
                        return target
                else:
                    raise ArtifactConflictError(f"{artifact.artifact_type} artifacts are append-only")
        return target

    @contextmanager
    def _write_lock(self, canonical_path: str):
        # One lock per resolved canonical file, shared by normal writes and
        # identity-transfer compare-and-swap. Derived locks never enter Git.
        target = self._target(canonical_path)
        key = hashlib.sha256(str(target).encode("utf-8")).hexdigest()
        directory = Path.home() / ".egregore" / "runtime" / "artifact-locks"
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / f"{key}.lock").open("a+") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def persist(self, document: CanonicalDocument) -> Path:
        with self._write_lock(document.artifact.canonical_path):
            return self._persist(document)

    def persist_if_unchanged(self, document: CanonicalDocument, expected_sha256: str) -> Path:
        """Replace an existing document only while its full bytes still match.

        Normal Runtime writers participate in this lock. Direct filesystem
        editors do not; this is not a filesystem-wide transactional guarantee.
        """
        with self._write_lock(document.artifact.canonical_path):
            target = self._target(document.artifact.canonical_path)
            if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != expected_sha256:
                raise ArtifactConflictError("canonical source changed during identity transfer")
            return self._persist(document)

    def _persist(self, document: CanonicalDocument) -> Path:
        target = self.check_write(document)
        artifact = validate_artifact(document.artifact, document.body)
        if (
            target.exists()
            and artifact.artifact_type not in self.mutable_types
            and document.migrated_from is None
            and not document.replaces_existing
        ):
            return target  # check_write proved this append-only write is identical
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
        temporary.write_text(render_canonical_markdown(replace(document, artifact=artifact)), encoding="utf-8")
        temporary.replace(target)
        return target

    def read(self, canonical_path: str) -> CanonicalDocument:
        target = self._target(canonical_path)
        return parse_canonical_markdown(
            target.read_text(encoding="utf-8"),
            canonical_path=canonical_relative_path(canonical_path),
        )
