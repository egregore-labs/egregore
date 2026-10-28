"""Optional graph projection adapter for the Egregore Runtime.

The graph is a disposable projection of canonical Markdown.  This module never
reads graph values back into canonical artifacts and never enables the graph by
configuration discovery: callers must explicitly request the legacy adapter.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Callable, Sequence

from .contracts import CanonicalArtifact, GraphProjectionHealth


@dataclass(frozen=True, slots=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


CommandRunner = Callable[[Sequence[str], Path, int], CommandResult]


def _run(command: Sequence[str], cwd: Path, timeout: int) -> CommandResult:
    completed = subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
        # This runner belongs only to the explicitly constructed adapter.
        # Carry that opt-in across the shell boundary without changing the
        # parent process or the instance's persistent configuration.
        env={**os.environ, "EGREGORE_GRAPH_PROJECTION": "1"},
    )
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


def _canonical_inventory(memory_root: Path) -> dict[str, str]:
    if not memory_root.is_dir():
        return {}
    return {
        f"memory/{path.relative_to(memory_root).as_posix()}": sha256(
            path.read_bytes()
        ).hexdigest()
        for path in sorted(memory_root.rglob("*.md"))
        if path.is_file()
    }


def _projection_inventory(memory_root: Path) -> dict[str, str]:
    """Inventory only canonical families covered by the legacy projector."""

    inventory = _canonical_inventory(memory_root)
    projected_prefixes = (
        "memory/handoffs/",
        "memory/wraps/",
        "memory/knowledge/decisions/",
        "memory/knowledge/findings/",
        "memory/knowledge/patterns/",
        "memory/knowledge/research/",
        "memory/artifacts/",
        "memory/quests/",
    )
    return {
        path: digest
        for path, digest in inventory.items()
        if path.startswith(projected_prefixes)
        and Path(path).name not in {"index.md", "index.md.bak"}
    }


def _snapshot_revision(inventory: dict[str, str]) -> str:
    payload = json.dumps(inventory, sort_keys=True, separators=(",", ":"))
    return f"snapshot:{sha256(payload.encode()).hexdigest()}"


def _canonical_revision(root: Path, memory_root: Path) -> str:
    completed = subprocess.run(
        ["git", "-C", str(memory_root), "rev-parse", "HEAD"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    revision = completed.stdout.strip()
    if completed.returncode == 0 and revision:
        status = subprocess.run(
            ["git", "-C", str(memory_root), "status", "--porcelain"],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
        if status.returncode == 0 and status.stdout.strip():
            snapshot = _snapshot_revision(_canonical_inventory(memory_root))
            return f"{revision}+dirty:{snapshot.removeprefix('snapshot:')[:12]}"
        return revision
    return _snapshot_revision(_canonical_inventory(memory_root))


def _declared_content_hash(path: Path) -> str | None:
    """Read a canonical v1 hash without treating arbitrary body text as schema."""

    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    if not text.startswith("---\n"):
        return None
    frontmatter = text[4:].split("\n---", 1)[0]
    match = re.search(
        r"(?m)^(?:content_hash|contentHash):\s*['\"]?([a-fA-F0-9]{32,128})['\"]?\s*$",
        frontmatter,
    )
    return match.group(1).lower() if match else None


def _canonical_path(raw_path: str, memory_root: Path) -> str | None:
    """Normalize graph file pointers without allowing paths outside memory/."""

    value = raw_path.strip().replace("\\", "/")
    if not value:
        return None
    resolved_prefix = memory_root.resolve().as_posix().rstrip("/") + "/"
    if value.startswith(resolved_prefix):
        value = "memory/" + value[len(resolved_prefix) :]
    elif Path(value).is_absolute():
        return None
    elif value.startswith("qmd://"):
        parts = value.split("/", 3)
        value = "memory/" + parts[3] if len(parts) == 4 else ""
    elif not value.startswith("memory/"):
        value = "memory/" + value.lstrip("/")
    relative = value.removeprefix("memory/")
    if not relative or ".." in Path(relative).parts:
        return None
    return "memory/" + Path(relative).as_posix()


class DisabledGraphProjection:
    """Safe default: a complete no-op with explicit health reporting."""

    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.memory_root = (self.root / "memory").resolve()

    def health(self) -> GraphProjectionHealth:
        return GraphProjectionHealth(
            enabled=False,
            adapter="disabled",
            projection_revision=None,
            canonical_revision=_canonical_revision(self.root, self.memory_root),
            coverage=None,
            consistent=None,
            warnings=(
                "optional hosted indexing is disabled; canonical Markdown is authoritative",
            ),
        )

    def project(
        self, artifacts: Sequence[CanonicalArtifact]
    ) -> GraphProjectionHealth:
        del artifacts
        return self.health()

    def rebuild(self) -> GraphProjectionHealth:
        return self.health()

    def verify(self) -> GraphProjectionHealth:
        return self.health()


class LegacyGraphProjection:
    """Explicit compatibility adapter over the preserved graph shell tools.

    `project` currently delegates to the repository-wide idempotent projector
    because the legacy implementation does not expose an artifact-scoped
    operation.  Inputs are nevertheless checked against canonical memory first.
    """

    _INVENTORY_QUERY = """MATCH (n)
WHERE n.filePath IS NOT NULL
RETURN n.filePath AS path,
       coalesce(n.contentHash, '') AS contentHash,
       coalesce(n.canonicalRevision, n.gitRevision, n.commit, '') AS canonicalRevision
ORDER BY path"""

    def __init__(
        self,
        root: Path,
        *,
        runner: CommandRunner | None = None,
        timeout: int = 120,
    ) -> None:
        self.root = root.resolve()
        self.memory_root = (self.root / "memory").resolve()
        self.runner = runner or _run
        self.timeout = timeout

    def _base_health(self, *warnings: str) -> GraphProjectionHealth:
        return GraphProjectionHealth(
            enabled=True,
            adapter="legacy-shell-v1",
            projection_revision=None,
            canonical_revision=_canonical_revision(self.root, self.memory_root),
            coverage=None,
            consistent=None,
            warnings=tuple(warnings),
        )

    def _inventory(self) -> tuple[dict[str, tuple[str, str]], tuple[str, ...]]:
        result = self.runner(
            ["bash", "bin/graph.sh", "query", self._INVENTORY_QUERY],
            self.root,
            self.timeout,
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip()
            return {}, (f"optional hosted index unavailable: {detail or 'query failed'}",)
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError:
            return {}, ("optional hosted index returned an invalid health response",)
        if "values" not in payload:
            reason = str(payload.get("reason") or "no projection inventory envelope")
            reason = {
                "graph_projection_disabled": "optional hosted indexing is disabled",
                "runtime_qmd_active": "local Runtime/QMD retrieval is active",
            }.get(reason, reason)
            return {}, (f"optional hosted index unavailable: {reason}",)

        entries: dict[str, tuple[str, str]] = {}
        for row in payload.get("values", []):
            if not isinstance(row, list) or not row:
                continue
            path = _canonical_path(str(row[0] or ""), self.memory_root)
            if path is None:
                continue
            content_hash = str(row[1] or "") if len(row) > 1 else ""
            revision = str(row[2] or "") if len(row) > 2 else ""
            entries[path] = (content_hash, revision)
        return entries, ()

    def health(self) -> GraphProjectionHealth:
        return self.verify()

    def verify(self) -> GraphProjectionHealth:
        canonical = _projection_inventory(self.memory_root)
        canonical_revision = _canonical_revision(self.root, self.memory_root)
        projected, warnings = self._inventory()
        if warnings:
            return self._base_health(*warnings)

        canonical_paths = set(canonical)
        projected_paths = set(projected)
        present = canonical_paths & projected_paths
        coverage = len(present) / len(canonical_paths) if canonical_paths else 1.0
        missing = canonical_paths - projected_paths
        extra = projected_paths - canonical_paths
        declared_hashes = {
            path: _declared_content_hash(self.root / path)
            for path in present
        }
        comparable = {
            path
            for path in present
            if projected[path][0] and declared_hashes[path]
        }
        mismatched = {
            path
            for path in comparable
            if projected[path][0].lower() != declared_hashes[path]
        }
        consistent = None if not comparable else not mismatched

        graph_shape = {
            path: {"content_hash": values[0], "canonical_revision": values[1]}
            for path, values in sorted(projected.items())
        }
        graph_payload = json.dumps(graph_shape, sort_keys=True, separators=(",", ":"))
        projection_revision = f"graph:{sha256(graph_payload.encode()).hexdigest()}"

        notices = list(warnings)
        if missing:
            notices.append(f"projection missing {len(missing)} canonical artifact(s)")
        if extra:
            notices.append(
                f"projection has {len(extra)} path(s) without canonical artifacts; ignored"
            )
        if mismatched:
            notices.append(
                f"projection disagrees with {len(mismatched)} canonical artifact(s); canonical wins"
            )
        projected_revisions = {
            revision for _, revision in projected.values() if revision
        }
        if projected_revisions and canonical_revision not in projected_revisions:
            notices.append("projection source revision differs from canonical revision")

        return GraphProjectionHealth(
            enabled=True,
            adapter="legacy-shell-v1",
            projection_revision=projection_revision,
            canonical_revision=canonical_revision,
            coverage=coverage,
            consistent=consistent,
            warnings=tuple(notices),
        )

    def _validate_artifacts(self, artifacts: Sequence[CanonicalArtifact]) -> None:
        for artifact in artifacts:
            relative = artifact.canonical_path.removeprefix("memory/")
            candidate = (self.memory_root / relative).resolve()
            if self.memory_root not in candidate.parents:
                raise ValueError(
                    f"artifact {artifact.artifact_id!r} is outside canonical memory"
                )
            if not candidate.is_file():
                raise ValueError(
                    f"artifact {artifact.artifact_id!r} has no canonical file"
                )

    def project(
        self, artifacts: Sequence[CanonicalArtifact]
    ) -> GraphProjectionHealth:
        self._validate_artifacts(artifacts)
        return self._sync("project")

    def rebuild(self) -> GraphProjectionHealth:
        return self._sync("rebuild")

    def _sync(self, operation: str) -> GraphProjectionHealth:
        result = self.runner(
            ["bash", "bin/sync-graph.sh"], self.root, self.timeout
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip()
            return self._base_health(
                f"optional hosted index {operation} failed: {detail or 'index sync exited nonzero'}",
                "canonical Markdown was preserved and remains authoritative",
            )
        return self.verify()


def graph_projection(
    root: Path,
    *,
    enabled: bool = False,
    runner: CommandRunner | None = None,
) -> DisabledGraphProjection | LegacyGraphProjection:
    """Build the projection adapter; callers must opt in on every construction."""

    if not enabled:
        return DisabledGraphProjection(root)
    return LegacyGraphProjection(root, runner=runner)
