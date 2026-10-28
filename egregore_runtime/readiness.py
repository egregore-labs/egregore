"""Runtime MVP readiness surface.

One staged, truthful view of what the local Runtime can do right now:
trust boundary, authorization policy, pinned QMD, reranking posture, BM25,
embeddings, the semantic build revision versus the canonical source
revision, and whether search stays usable while vectors rebuild.

Truth sources are Runtime state — ``RetrieverHealth``, a ``PolicyDecision``
from the actor's authorizer, and the session boundary state computed at
session start. Nothing is inferred from filenames, process names, or
hardcoded organizations, no percentage progress is invented (QMD does not
provide one), and building this report performs no network call.
"""

from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .contracts import Permission, PolicyDecision, RetrieverHealth
from .adapters.qmd import RERANKING_ENABLED

STAGE_READY = "ready"
STAGE_BUILDING = "building"
STAGE_UNAVAILABLE = "unavailable"
STAGE_DISABLED = "disabled"

_GLYPHS = {
    STAGE_READY: "●",
    STAGE_BUILDING: "◐",
    STAGE_UNAVAILABLE: "○",
    STAGE_DISABLED: "–",
}


@dataclass(frozen=True, slots=True)
class ReadinessItem:
    key: str
    label: str
    stage: str
    detail: str

    def to_dict(self) -> dict[str, str]:
        return {
            "key": self.key,
            "label": self.label,
            "stage": self.stage,
            "detail": self.detail,
        }


@dataclass(frozen=True, slots=True)
class ReadinessReport:
    items: tuple[ReadinessItem, ...]
    generated_in_ms: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": "egregore-readiness/v1",
            "items": [item.to_dict() for item in self.items],
            "generated_in_ms": self.generated_in_ms,
        }


def _short_revision(revision: str | None) -> str:
    """Compress a canonical revision to an honest, comparable short form."""
    if not revision:
        return "none"
    dirty = "+dirty" if "+dirty" in revision else ""
    head = revision.split("+", 1)[0]
    if ":" in head:
        scheme, value = head.split(":", 1)
        return f"{scheme}:{value[:12]}{dirty}"
    return f"{head[:12]}{dirty}"


def session_boundary_state(root: Path) -> Mapping[str, Any] | None:
    """The session boundary computed at session start, if any.

    The cache key mirrors the shell tooling: the hex MD5 of the project
    path. Reading state written by the boundary machinery is the runtime
    truth for isolation readiness; absence means no session start has
    computed a boundary here yet.
    """
    digest = hashlib.md5(str(root).encode("utf-8")).hexdigest()
    cache = Path("/tmp") / f"egregore-boundary-{digest}.json"
    try:
        value = json.loads(cache.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _boundary_item(root: Path, boundary: Mapping[str, Any] | None) -> ReadinessItem:
    label = "Trust boundary"
    if boundary is None:
        return ReadinessItem(
            key="boundary",
            label=label,
            stage=STAGE_UNAVAILABLE,
            detail="session boundary not computed yet — run a session start",
        )
    project_dir = str(boundary.get("project_dir") or "")
    if Path(project_dir) != root:
        return ReadinessItem(
            key="boundary",
            label=label,
            stage=STAGE_UNAVAILABLE,
            detail="boundary belongs to another checkout — run a session start here",
        )
    denied = boundary.get("denied_paths")
    if not isinstance(denied, list):
        return ReadinessItem(
            key="boundary",
            label=label,
            stage=STAGE_UNAVAILABLE,
            detail="boundary state is unreadable — run a session start",
        )
    posture = str(boundary.get("posture") or "standard")
    return ReadinessItem(
        key="boundary",
        label=label,
        stage=STAGE_READY,
        detail=(
            f"posture {posture} · {len(denied)} foreign instance"
            f"{'s' if len(denied) != 1 else ''} isolated"
        ),
    )


def _authorization_item(probe: PolicyDecision | Exception | None) -> ReadinessItem:
    label = "Authorization"
    if probe is None:
        return ReadinessItem(
            key="authorization",
            label=label,
            stage=STAGE_UNAVAILABLE,
            detail="no policy answered the authorization probe",
        )
    if isinstance(probe, Exception):
        return ReadinessItem(
            key="authorization",
            label=label,
            stage=STAGE_UNAVAILABLE,
            detail=f"policy probe failed: {str(probe)[:120]}",
        )
    if not probe.allowed:
        reasons = "; ".join(probe.reasons) or "no reason given"
        return ReadinessItem(
            key="authorization",
            label=label,
            stage=STAGE_UNAVAILABLE,
            detail=f"read denied by policy {probe.policy_epoch}: {reasons[:120]}",
        )
    return ReadinessItem(
        key="authorization",
        label=label,
        stage=STAGE_READY,
        detail=f"actor authorized · policy {probe.policy_epoch}",
    )


def _qmd_item(health: RetrieverHealth) -> ReadinessItem:
    label = "QMD"
    if health.available:
        return ReadinessItem(
            key="qmd",
            label=label,
            stage=STAGE_READY,
            detail=f"{health.adapter} {health.adapter_version} pinned",
        )
    reason = health.warnings[0] if health.warnings else "retrieval adapter unavailable"
    return ReadinessItem(
        key="qmd", label=label, stage=STAGE_UNAVAILABLE, detail=str(reason)[:140]
    )


def _reranker_item() -> ReadinessItem:
    if RERANKING_ENABLED:
        return ReadinessItem(
            key="reranker",
            label="Reranker",
            stage=STAGE_READY,
            detail="model reranking enabled",
        )
    return ReadinessItem(
        key="reranker",
        label="Reranker",
        stage=STAGE_DISABLED,
        detail="disabled for the MVP — typed rank fusion only",
    )


def _bm25_item(health: RetrieverHealth) -> ReadinessItem:
    label = "BM25"
    if health.bm25_ready:
        return ReadinessItem(
            key="bm25",
            label=label,
            stage=STAGE_READY,
            detail=f"lexical index usable · {_short_revision(health.index_source_revision)}",
        )
    if health.available and health.canonical_state_ready:
        return ReadinessItem(
            key="bm25",
            label=label,
            stage=STAGE_BUILDING,
            detail="lexical index registering — first update pending",
        )
    return ReadinessItem(
        key="bm25",
        label=label,
        stage=STAGE_UNAVAILABLE,
        detail="no lexical index — retrieval adapter is not available",
    )


def _embeddings_item(health: RetrieverHealth) -> ReadinessItem:
    label = "Embeddings"
    state = health.embedding_state
    if state == "ready":
        return ReadinessItem(
            key="embeddings", label=label, stage=STAGE_READY, detail="vector build complete"
        )
    if state in ("running", "pending"):
        detail = (
            "background embed running — search does not wait for it"
            if state == "running"
            else "documents pending embedding — background embed scheduled"
        )
        return ReadinessItem(
            key="embeddings", label=label, stage=STAGE_BUILDING, detail=detail
        )
    if state == "missing_model":
        if health.semantic_source_revision:
            return ReadinessItem(
                key="embeddings",
                label=label,
                stage=STAGE_UNAVAILABLE,
                detail=(
                    "embedding model missing — stored vectors intact · "
                    "repair: bin/search.sh reindex --embed"
                ),
            )
        return ReadinessItem(
            key="embeddings",
            label=label,
            stage=STAGE_UNAVAILABLE,
            detail="embedding model not installed — lexical retrieval only",
        )
    return ReadinessItem(
        key="embeddings",
        label=label,
        stage=STAGE_UNAVAILABLE,
        detail="no vector build yet",
    )


def _semantic_item(health: RetrieverHealth) -> ReadinessItem:
    label = "Semantic build"
    source = _short_revision(health.source_revision)
    build = _short_revision(health.semantic_source_revision)
    if health.embedding_state == "missing_model":
        return ReadinessItem(
            key="semantic",
            label=label,
            stage=STAGE_UNAVAILABLE,
            detail=(
                "embedding model missing — semantic queries unavailable · "
                "repair: bin/search.sh reindex --embed"
            ),
        )
    if health.semantic_ready:
        return ReadinessItem(
            key="semantic",
            label=label,
            stage=STAGE_READY,
            detail=f"vectors current at {build}",
        )
    if health.semantic_source_revision:
        return ReadinessItem(
            key="semantic",
            label=label,
            stage=STAGE_BUILDING,
            detail=f"serving {build} while {source} builds",
        )
    return ReadinessItem(
        key="semantic",
        label=label,
        stage=STAGE_UNAVAILABLE,
        detail=f"no complete vector build yet · source {source}",
    )


def _search_item(health: RetrieverHealth) -> ReadinessItem:
    label = "Search"
    if health.bm25_ready and health.semantic_ready:
        return ReadinessItem(
            key="search", label=label, stage=STAGE_READY, detail="hybrid current"
        )
    if health.bm25_ready and health.embedding_state == "missing_model":
        return ReadinessItem(
            key="search",
            label=label,
            stage=STAGE_READY,
            detail=(
                "lexical only — embedding model missing · "
                "repair: bin/search.sh reindex --embed"
            ),
        )
    if health.bm25_ready and health.semantic_source_revision:
        return ReadinessItem(
            key="search",
            label=label,
            stage=STAGE_READY,
            detail="hybrid stays available while embeddings rebuild",
        )
    if health.bm25_ready:
        return ReadinessItem(
            key="search",
            label=label,
            stage=STAGE_READY,
            detail="lexical available until the first vector build completes",
        )
    reason = health.warnings[0] if health.warnings else "retrieval is not available"
    return ReadinessItem(
        key="search", label=label, stage=STAGE_UNAVAILABLE, detail=str(reason)[:140]
    )


def build_report(
    *,
    root: Path,
    health: RetrieverHealth,
    boundary: Mapping[str, Any] | None,
    authorization: PolicyDecision | Exception | None,
    started_monotonic: float | None = None,
) -> ReadinessReport:
    """Assemble the staged report from injected Runtime state (deterministic)."""
    started = started_monotonic if started_monotonic is not None else time.monotonic()
    items = (
        _boundary_item(root, boundary),
        _authorization_item(authorization),
        _qmd_item(health),
        _reranker_item(),
        _bm25_item(health),
        _embeddings_item(health),
        _semantic_item(health),
        _search_item(health),
    )
    elapsed_ms = max(0, round((time.monotonic() - started) * 1000))
    return ReadinessReport(items=items, generated_in_ms=elapsed_ms)


def collect_report(root: Path, runtime, *, harness: str, session_id: str) -> ReadinessReport:
    """Gather live Runtime state and assemble the report. Local I/O only."""
    started = time.monotonic()
    health = runtime.retrieval_health()
    boundary = session_boundary_state(root)
    authorization: PolicyDecision | Exception | None
    try:
        actor = runtime.resolve_actor(session_id=session_id, harness=harness)
        authorization = runtime.authorize(actor, Permission.READ)
    except Exception as exc:  # readiness must report failures, not raise them
        authorization = exc
    return build_report(
        root=root,
        health=health,
        boundary=boundary,
        authorization=authorization,
        started_monotonic=started,
    )


def render(report: ReadinessReport, *, tty: bool) -> str:
    """Render the staged report for humans. No raw JSON, no command traces."""
    lines: list[str] = []
    if tty:
        lines.append("Egregore Runtime readiness")
        lines.append("┄" * 40)
    else:
        lines.append("egregore runtime readiness")
    width = max(len(item.label) for item in report.items)
    for item in report.items:
        if tty:
            glyph = _GLYPHS.get(item.stage, "○")
            lines.append(f"  {glyph} {item.label:<{width}}  {item.stage:<11} {item.detail}")
        else:
            lines.append(f"{item.key}: {item.stage} — {item.detail}")
    lines.append(f"rendered in {report.generated_in_ms} ms · local state only, no network")
    return "\n".join(lines)


__all__ = [
    "STAGE_BUILDING",
    "STAGE_DISABLED",
    "STAGE_READY",
    "STAGE_UNAVAILABLE",
    "ReadinessItem",
    "ReadinessReport",
    "build_report",
    "collect_report",
    "render",
    "session_boundary_state",
]
