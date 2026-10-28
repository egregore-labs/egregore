"""Canonical issue lifecycle shared by every harness and deployment mode.

Issue Markdown is authoritative. Graph projection, GitHub publication, and
notifications consume canonical receipts and never participate in issue state
resolution.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
import re
from typing import Any, Callable, Iterable, Sequence

from .artifacts import (
    ARTIFACT_SCHEMA_VERSION,
    CanonicalDocument,
    content_digest,
    parse_canonical_markdown,
    split_frontmatter,
)
from .contracts import ActorContext, CanonicalArtifact, SourceProvenance, WritebackEvent
from .policy import scope_allows_path


ISSUE_SCHEMA_VERSION = "egregore-issue/v1"
ISSUE_STATUSES = frozenset({"open", "closed"})


def _slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")[:72]
    if not result:
        raise ValueError("issue title must contain a letter or number")
    return result


def _strings(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        return tuple(part.strip() for part in value.split(",") if part.strip())
    if isinstance(value, Sequence):
        return tuple(str(item).strip() for item in value if str(item).strip())
    raise ValueError("issue topics must be a string or list")


@dataclass(frozen=True, slots=True)
class IssueSnapshot:
    issue_id: str
    title: str
    status: str
    recipient: str
    topics: tuple[str, ...]
    reported_by: str
    reported_by_actor_id: str | None
    created_at: str
    closed_at: str | None
    github_url: str | None
    canonical_path: str
    body: str
    document: CanonicalDocument

    def to_dict(self, *, include_body: bool = False) -> dict[str, object]:
        row: dict[str, object] = {
            "id": self.issue_id,
            "artifact_id": self.document.artifact.artifact_id,
            "title": self.title,
            "status": self.status,
            "recipient": self.recipient,
            "topics": list(self.topics),
            "reported_by": self.reported_by,
            "reported_by_actor_id": self.reported_by_actor_id,
            "created_at": self.created_at,
            "closed_at": self.closed_at,
            "github_url": self.github_url,
            "canonical_path": f"memory/{self.canonical_path}",
        }
        if include_body:
            row["body"] = self.body
        return row


def parse_issue_markdown(
    markdown: str,
    *,
    canonical_path: str,
    org_id: str,
) -> IssueSnapshot:
    fields, _ = split_frontmatter(markdown)
    document = parse_canonical_markdown(
        markdown,
        canonical_path=canonical_path,
        default_org_id=org_id,
    )
    status = str(fields.get("status") or document.artifact.status or "open").casefold()
    if status not in ISSUE_STATUSES:
        raise ValueError(f"unsupported issue status: {status}")
    path_id = Path(canonical_path).stem
    issue_id = str(fields.get("issue_id") or path_id)
    return IssueSnapshot(
        issue_id=issue_id,
        title=document.artifact.title,
        status=status,
        recipient=str(fields.get("recipient") or "just memory"),
        topics=_strings(fields.get("topics")),
        reported_by=str(fields.get("author") or fields.get("reported_by") or document.artifact.created_by),
        reported_by_actor_id=(
            str(fields["reported_by_actor_id"])
            if fields.get("reported_by_actor_id")
            else None
        ),
        created_at=document.artifact.created_at.isoformat(),
        closed_at=str(fields["closed_at"]) if fields.get("closed_at") else (
            str(fields["closed"]) if fields.get("closed") else None
        ),
        github_url=str(fields["github_url"]) if fields.get("github_url") else None,
        canonical_path=canonical_path,
        body=document.body,
        document=document,
    )


class CanonicalIssueService:
    """Resolve and mutate issue state from one authorized canonical snapshot."""

    def __init__(
        self,
        *,
        memory_root: Path,
        write_document,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.memory_root = memory_root.resolve()
        self.write_document = write_document
        self.clock = clock or (lambda: datetime.now(UTC))

    def _paths(self) -> Iterable[Path]:
        directory = self.memory_root / "knowledge" / "issues"
        if not directory.is_dir():
            return ()
        return tuple(sorted(directory.glob("*.md"), reverse=True))

    def snapshot(
        self,
        actor: ActorContext,
        *,
        authorized_scopes: tuple[str, ...],
    ) -> tuple[IssueSnapshot, ...]:
        """Read each authorized canonical source at most once for this operation."""

        rows: list[IssueSnapshot] = []
        for path in self._paths():
            relative = path.relative_to(self.memory_root).as_posix()
            canonical = f"memory/{relative}"
            if not scope_allows_path(canonical, authorized_scopes):
                continue
            rows.append(
                parse_issue_markdown(
                    path.read_text(encoding="utf-8"),
                    canonical_path=relative,
                    org_id=actor.profile.org_id,
                )
            )
        return tuple(rows)

    @staticmethod
    def resolve(rows: Sequence[IssueSnapshot], reference: str) -> IssueSnapshot:
        term = reference.strip().casefold()
        if not term:
            raise ValueError("issue reference is required")
        exact = [
            row for row in rows
            if term in {
                row.issue_id.casefold(),
                row.document.artifact.artifact_id.casefold(),
                row.canonical_path.casefold(),
                f"memory/{row.canonical_path}".casefold(),
            }
        ]
        if len(exact) == 1:
            return exact[0]
        matches = [
            row for row in rows
            if term in row.issue_id.casefold() or term in row.title.casefold()
        ]
        if len(matches) != 1:
            qualifier = "missing" if not matches else "ambiguous"
            raise ValueError(f"issue reference is {qualifier}: {reference}")
        return matches[0]

    def create(
        self,
        actor: ActorContext,
        *,
        title: str,
        description: str,
        recipient: str = "just memory",
        topics: Sequence[str] = (),
        context: str | None = None,
        suggested_fix: str | None = None,
    ) -> tuple[IssueSnapshot, WritebackEvent]:
        if not title.strip() or not description.strip():
            raise ValueError("issue title and description are required")
        now = self.clock().astimezone(UTC)
        issue_id = f"{now.date().isoformat()}-{_slug(title)}"
        relative = f"knowledge/issues/{issue_id}.md"
        if (self.memory_root / relative).exists():
            raise ValueError(f"issue already exists: {issue_id}")
        sections = [f"# {title.strip()}", "", "## Description", "", description.strip()]
        if context and context.strip():
            sections.extend(("", "## Context", "", context.strip()))
        if suggested_fix and suggested_fix.strip():
            sections.extend(("", "## Suggested Fix", "", suggested_fix.strip()))
        body = "\n".join(sections) + "\n"
        digest = content_digest(body)
        artifact = CanonicalArtifact(
            schema_version=ARTIFACT_SCHEMA_VERSION,
            artifact_id=f"issue:{issue_id}",
            org_id=actor.profile.org_id,
            artifact_type="issue",
            title=title.strip(),
            created_at=now,
            created_by=actor.actor.actor_id,
            status="open",
            canonical_path=relative,
            revision=f"sha256:{digest[:16]}",
            content_hash=digest,
            workstream="issue-tracking",
            provenance=(
                SourceProvenance(
                    source_type="session",
                    source_id=actor.session_id,
                    revision=actor.profile.revision,
                    content_hash=digest,
                    observed_at=now,
                    imported_by=actor.actor.actor_id,
                ),
            ),
        )
        legacy = {
            "issue_schema": ISSUE_SCHEMA_VERSION,
            "issue_id": issue_id,
            "date": now.date().isoformat(),
            "author": actor.actor.display_name,
            "reported_by_actor_id": actor.actor.actor_id,
            "category": "issue",
            "recipient": recipient.strip() or "just memory",
            "topics": list(dict.fromkeys(topic.strip() for topic in topics if topic.strip())),
            "lifecycle_events": [{
                "action": "created",
                "actor_id": actor.actor.actor_id,
                "occurred_at": now.isoformat().replace("+00:00", "Z"),
            }],
        }
        document = CanonicalDocument(
            artifact=artifact,
            body=body,
            policy_hints={"internal": True},
            legacy_fields=legacy,
        )
        receipt = self.write_document(actor, document)
        return parse_issue_markdown(
            self._rendered_markdown(document),
            canonical_path=relative,
            org_id=actor.profile.org_id,
        ), receipt

    @staticmethod
    def _rendered_markdown(document: CanonicalDocument) -> str:
        # Parsing a newly prepared document only needs its body/envelope fields;
        # use the shared serializer to avoid a second filesystem read.
        from .artifacts import render_canonical_markdown

        return render_canonical_markdown(document)

    def close(
        self,
        actor: ActorContext,
        issue: IssueSnapshot,
        *,
        reason: str | None = None,
    ) -> tuple[IssueSnapshot, WritebackEvent]:
        if issue.status != "open":
            raise ValueError("only open issues can be closed")
        now = self.clock().astimezone(UTC)
        source = issue.document
        fields = dict(source.legacy_fields)
        events = list(fields.get("lifecycle_events") or [])
        events.append({
            "action": "closed",
            "actor_id": actor.actor.actor_id,
            "occurred_at": now.isoformat().replace("+00:00", "Z"),
            **({"reason": reason.strip()} if reason and reason.strip() else {}),
        })
        fields.update({
            "issue_schema": ISSUE_SCHEMA_VERSION,
            "issue_id": issue.issue_id,
            "reported_by_actor_id": issue.reported_by_actor_id or source.artifact.created_by,
            "closed_at": now.isoformat().replace("+00:00", "Z"),
            "lifecycle_events": events,
        })
        digest = content_digest(source.body)
        artifact = replace(
            source.artifact,
            artifact_type="issue",
            status="closed",
            revision=f"sha256:{digest[:16]}:closed",
            content_hash=digest,
        )
        document = CanonicalDocument(
            artifact=artifact,
            body=source.body,
            policy_hints=source.policy_hints,
            legacy_fields=fields,
            migrated_from=source.migrated_from,
            warnings=source.warnings,
        )
        receipt = self.write_document(actor, document)
        return parse_issue_markdown(
            self._rendered_markdown(document),
            canonical_path=issue.canonical_path,
            org_id=actor.profile.org_id,
        ), receipt

    def link_github(
        self,
        actor: ActorContext,
        issue: IssueSnapshot,
        github_url: str,
    ) -> tuple[IssueSnapshot, WritebackEvent]:
        """Record a separately authorized publication as canonical provenance."""

        if not github_url.strip().startswith("https://github.com/"):
            raise ValueError("GitHub issue URL is invalid")
        source = issue.document
        fields = dict(source.legacy_fields)
        fields["github_url"] = github_url.strip()
        events = list(fields.get("lifecycle_events") or [])
        events.append({
            "action": "github_linked",
            "actor_id": actor.actor.actor_id,
            "occurred_at": self.clock().astimezone(UTC).isoformat().replace("+00:00", "Z"),
        })
        fields["lifecycle_events"] = events
        document = CanonicalDocument(
            artifact=source.artifact,
            body=source.body,
            policy_hints=source.policy_hints,
            legacy_fields=fields,
            migrated_from=source.migrated_from,
            warnings=source.warnings,
        )
        receipt = self.write_document(actor, document)
        return parse_issue_markdown(
            self._rendered_markdown(document),
            canonical_path=issue.canonical_path,
            org_id=actor.profile.org_id,
        ), receipt
