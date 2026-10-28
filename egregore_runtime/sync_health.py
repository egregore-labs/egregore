"""Human-actionable readings of canonical sync and retrieval state.

The session greeting used to compress every synchronization failure to
"git ✗ — run /checkup", and any index that was not byte-identical with the
tree to "retrieval ✗". Both readings were true and neither was useful. This
module turns the typed transport failure into the one line a person should
read, and grades retrieval as ready, stale, or unavailable.
"""

from __future__ import annotations

from .contracts import RetrieverHealth

# One remedy per failure kind. Each is the action, not the diagnosis: the
# greeting prints it after the dimension name, so it must stand alone.
_REMEDIES: dict[str, str] = {
    "lock": "a git process holds the memory repository; retry in a minute",
    "conflict": "resolve the conflict in the memory repository, then rerun sync",
    "auth": "GitHub credentials are missing or expired; run /env",
    "network": "offline; memory stays local until the next sync",
    "timeout": "git timed out; check the network and rerun sync",
    "detached": "memory repository is on a detached HEAD; check out its main branch",
    "behind": "incoming memory changes could not be integrated; rerun sync",
}


def sync_remedy(kind: str, exc: BaseException | None) -> str:
    """The one line a person should read for a canonical-sync failure."""
    if kind in _REMEDIES:
        return _REMEDIES[kind]
    detail = str(exc).strip() if exc is not None else ""
    if detail:
        return f"runtime error: {detail[:120]}; run /checkup"
    return "memory sync failed for an unknown reason; run /checkup"


def grade_retrieval(
    health: RetrieverHealth | None,
    *,
    index_aligned: bool,
    dirty_count: int = 0,
) -> tuple[str, str | None]:
    """Grade lexical retrieval for a reader.

    ready       — the index answers from the exact canonical snapshot.
    stale       — the index answers, from a snapshot behind the tree; the
                  detail says by how much so the reader can judge.
    unavailable — the index cannot answer; the detail says why.
    Semantic warm-up never lowers the grade: lexical recall is what a session
    needs first, and vectors build in the background by design.
    """
    if health is None or not health.available:
        return "unavailable", "retrieval runtime is not available"
    if not health.canonical_state_ready:
        return "unavailable", "canonical memory state is not ready"
    if not health.bm25_ready:
        return "unavailable", "lexical index is not built yet"
    if index_aligned:
        return "ready", None
    if dirty_count > 0:
        noun = "file" if dirty_count == 1 else "files"
        return "stale", f"{dirty_count} uncommitted memory {noun} not yet indexed"
    return "stale", "index is behind the canonical tree; it refreshes on the next sync"
