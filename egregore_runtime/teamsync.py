"""Team-memory synchronization truth for user-facing surfaces.

Maps the canonical memory repository's Git state to the six plain states
Settings shows. Git synchronization and semantic readiness are deliberately
independent: this module never consults retrieval state, and "up to date
with the team" is claimed only when a fetch actually succeeded and local
history is neither ahead of nor behind its upstream, with nothing
unpublished. Meaning-search freshness is reported elsewhere.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

STATE_UP_TO_DATE = "up-to-date"
STATE_UPDATES_AVAILABLE = "updates-available"
STATE_UNSHARED_WORK = "unshared-work"
STATE_DIVERGED = "diverged"
STATE_ATTENTION = "attention"
STATE_OFFLINE = "offline"

LABELS = {
    STATE_UP_TO_DATE: "Up to date with the team",
    STATE_UPDATES_AVAILABLE: "Team updates available",
    STATE_UNSHARED_WORK: "Your latest work has not been shared",
    STATE_DIVERGED: "Sync needs attention",
    STATE_ATTENTION: "Sync needs attention",
    STATE_OFFLINE: "Offline; showing last synchronized state",
}


@dataclass(frozen=True, slots=True)
class TeamSync:
    state: str
    label: str
    ahead: int
    behind: int
    dirty: bool
    fetched: bool
    local_revision: str
    remote_revision: str

    def to_dict(self) -> dict[str, object]:
        return {
            "state": self.state,
            "label": self.label,
            "ahead": self.ahead,
            "behind": self.behind,
            "dirty": self.dirty,
            "fetched": self.fetched,
            "local_revision": self.local_revision,
            "remote_revision": self.remote_revision,
        }


def _git(root: Path, *args: str, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ("git", "-C", str(root), *args),
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def team_sync(memory_root: Path, *, fetch: bool = True) -> TeamSync:
    """Compute the honest sync state for the canonical memory repository.

    ``fetch=True`` attempts a real fetch first; a failed fetch yields the
    offline state (last synchronized information, clearly labeled) rather
    than a phantom "up to date". ``fetch=False`` reads local refs only and
    never claims up-to-date — surfaces that skip the network must present
    cached knowledge as cached.
    """
    branch = _git(memory_root, "branch", "--show-current").stdout.strip()
    local = _git(memory_root, "rev-parse", "HEAD").stdout.strip()
    dirty = bool(_git(memory_root, "status", "--porcelain").stdout.strip())
    has_origin = _git(memory_root, "remote", "get-url", "origin").returncode == 0

    fetched = False
    if fetch and branch and has_origin:
        fetched = _git(memory_root, "fetch", "origin", branch, timeout=60).returncode == 0

    upstream = f"origin/{branch}" if branch else ""
    remote = _git(memory_root, "rev-parse", upstream).stdout.strip() if upstream else ""

    ahead = behind = 0
    if remote:
        counts = _git(memory_root, "rev-list", "--left-right", "--count", f"HEAD...{upstream}")
        if counts.returncode == 0 and counts.stdout.strip():
            left, _, right = counts.stdout.strip().partition("\t")
            ahead = int(left or 0)
            behind = int(right or 0)

    if not branch or not local or not has_origin:
        # No branch, no history, or nothing to synchronize with — this needs
        # a person, not a retry.
        state = STATE_ATTENTION
    elif fetch and not fetched:
        state = STATE_OFFLINE
    elif not remote:
        state = STATE_ATTENTION
    elif ahead and behind:
        state = STATE_DIVERGED
    elif dirty or ahead:
        state = STATE_UNSHARED_WORK
    elif behind:
        state = STATE_UPDATES_AVAILABLE
    elif not fetch:
        # Local refs alone cannot prove currency with the team.
        state = STATE_OFFLINE
    else:
        state = STATE_UP_TO_DATE

    return TeamSync(
        state=state,
        label=LABELS[state],
        ahead=ahead,
        behind=behind,
        dirty=dirty,
        fetched=fetched,
        local_revision=local[:12],
        remote_revision=remote[:12],
    )


__all__ = [
    "LABELS",
    "STATE_ATTENTION",
    "STATE_DIVERGED",
    "STATE_OFFLINE",
    "STATE_UNSHARED_WORK",
    "STATE_UPDATES_AVAILABLE",
    "STATE_UP_TO_DATE",
    "TeamSync",
    "team_sync",
]
