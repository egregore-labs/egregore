"""Git-backed provenance transport for canonical organizational state."""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path
from typing import Sequence

from .contracts import SyncStatus

# Failure kinds a caller can act on without parsing prose. `lock`, `timeout`
# and `conflict` each have a distinct remedy; `unknown` keeps the raw detail.
SYNC_FAILURE_KINDS = ("lock", "timeout", "conflict", "detached", "auth", "network", "unknown")

# A git lock older than this with no live git process on the repository is
# garbage left by a killed process. Every transport call finishes in far less
# (the longest timeout below is 180s); the margin absorbs a slow network fetch.
STALE_LOCK_SECONDS = 600

# Signals in git's own stderr that the failure is a lock, not the operation.
_LOCK_SIGNATURES = ("cannot autostash", ".lock': file exists", "index.lock", "unable to create")


class GitSyncError(RuntimeError):
    """The configured canonical Git repository could not be synchronized."""

    def __init__(self, message: str, *, kind: str = "unknown") -> None:
        super().__init__(message)
        self.kind = kind if kind in SYNC_FAILURE_KINDS else "unknown"


def _classify_git_failure(detail: str) -> str:
    lowered = detail.lower()
    if any(signature in lowered for signature in _LOCK_SIGNATURES):
        return "lock"
    if "could not read username" in lowered or "authentication failed" in lowered or "permission denied" in lowered:
        return "auth"
    if "could not resolve host" in lowered or "connection" in lowered or "network" in lowered:
        return "network"
    if "conflict" in lowered:
        return "conflict"
    return "unknown"


class LocalGitSyncTransport:
    """Commit exact canonical paths and optionally use today's Git transport.

    Path-aware commits prevent a ritual from absorbing unrelated user edits.
    GitHub is only the current remote transport; the domain contract exposes
    no GitHub identity or API detail and can be replaced independently later.

    The transport owns the two failure classes that used to strand canonical
    memory for days: a git process killed mid-write leaves an `index.lock`
    that blocks every later write, and a background push rejected by a moved
    remote leaves local history ahead with nobody retrying. Locks are reaped
    before each operation and after any timeout the transport itself caused;
    locally-ahead history is reconciled on the next pull.
    """

    def __init__(self, repository: Path, *, push_remote: bool = True) -> None:
        self.repository = repository.resolve()
        self.push_remote = push_remote
        self.async_remote_push = os.environ.get("EGREGORE_ASYNC_REMOTE_PUSH") == "1"
        self._lock_warnings: list[str] = []

    # --- process execution --------------------------------------------------

    def _run(
        self,
        *arguments: str,
        timeout: int = 60,
        literal_pathspecs: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        """Run git with a graceful timeout.

        `subprocess.run(timeout=...)` kills the child with SIGKILL, which git
        cannot intercept, so its lock files survive and poison every later
        write. Here a timeout sends SIGTERM first (git's lockfile handler
        removes its locks on that signal), escalates to SIGKILL only if git
        ignores it, and then reaps any lock the killed process left behind.
        """
        environment = dict(os.environ)
        environment.setdefault("GIT_TERMINAL_PROMPT", "0")
        if literal_pathspecs:
            # Only the invocations that carry caller-named files opt in: those
            # name exact canonical paths, and Git must not expand a filename
            # containing wildcard characters into additional canonical writes.
            environment["GIT_LITERAL_PATHSPECS"] = "1"
        started_at = time.time()
        process = subprocess.Popen(
            ("git", "-C", str(self.repository), *arguments),
            text=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            self._reap_locks_created_since(started_at, reason=f"git {arguments[0]} timed out")
            raise GitSyncError(
                f"git {' '.join(arguments)} timed out after {timeout}s", kind="timeout"
            )
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)

    def _required(
        self,
        *arguments: str,
        timeout: int = 60,
        literal_pathspecs: bool = False,
    ) -> str:
        completed = self._run(*arguments, timeout=timeout, literal_pathspecs=literal_pathspecs)
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout).strip()
            message = detail or f"git {' '.join(arguments)} failed"
            raise GitSyncError(message, kind=_classify_git_failure(message))
        return completed.stdout.strip()

    # --- lock recovery -------------------------------------------------------

    def _git_dir(self) -> Path | None:
        """Resolve the git directory without running git.

        Lock recovery runs while git may be hung or just killed, so it cannot
        depend on a git subprocess. A plain checkout keeps `.git/` as a
        directory; a linked worktree keeps a `.git` file naming its gitdir.
        """
        dot_git = self.repository / ".git"
        if dot_git.is_dir():
            return dot_git
        if dot_git.is_file():
            try:
                first = dot_git.read_text().splitlines()[0]
            except (OSError, IndexError):
                return None
            if first.startswith("gitdir:"):
                target = Path(first[len("gitdir:"):].strip())
                if not target.is_absolute():
                    target = (self.repository / target).resolve()
                return target if target.is_dir() else None
        return None

    def _lock_files(self) -> list[Path]:
        git_dir = self._git_dir()
        if git_dir is None or not git_dir.is_dir():
            return []
        locks = [path for path in git_dir.glob("*.lock") if path.is_file()]
        refs = git_dir / "refs"
        if refs.is_dir():
            locks.extend(path for path in refs.rglob("*.lock") if path.is_file())
        return locks

    def _git_process_holds_repository(self) -> bool:
        """True when a live git process names this repository on its command line.

        The transport always runs `git -C <repository>`, so its own children
        are visible here. Shell writers that `cd` into the repository are not,
        which is why the age threshold, not this check, is the primary guard.
        """
        try:
            listing = subprocess.run(
                ("ps", "-axo", "command="),
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            ).stdout
        except (OSError, subprocess.TimeoutExpired):
            return True  # cannot tell; be conservative
        needle = str(self.repository).rstrip("/")
        for line in listing.splitlines():
            tokens = line.strip().split()
            if not tokens or tokens[0].rsplit("/", 1)[-1] != "git":
                continue
            if any(token.strip("'\"").rstrip("/") == needle for token in tokens[1:]):
                return True
        return False

    def _reap_stale_locks(self) -> list[str]:
        """Remove lock files no live process can own and report each removal."""
        now = time.time()
        stale: list[tuple[Path, float]] = []
        for lock in self._lock_files():
            try:
                age = now - lock.stat().st_mtime
            except FileNotFoundError:
                continue
            if age >= STALE_LOCK_SECONDS:
                stale.append((lock, age))
        if not stale:
            return []
        if self._git_process_holds_repository():
            return [
                "stale git lock files present but a git process still holds the "
                "repository; left in place"
            ]
        return [self._remove_lock(lock, reason=f"orphaned for {_describe_age(age)}") for lock, age in stale]

    def _reap_locks_created_since(self, started_at: float, *, reason: str) -> None:
        for lock in self._lock_files():
            try:
                if lock.stat().st_mtime >= started_at - 1:
                    self._lock_warnings.append(self._remove_lock(lock, reason=reason))
            except FileNotFoundError:
                continue

    def _remove_lock(self, lock: Path, *, reason: str) -> str:
        git_dir = self._git_dir()
        label = lock.relative_to(git_dir).as_posix() if git_dir else lock.name
        try:
            lock.unlink()
        except FileNotFoundError:
            pass
        return f"removed stale git lock {label} ({reason})"

    def _take_lock_warnings(self) -> list[str]:
        warnings = list(self._lock_warnings)
        self._lock_warnings.clear()
        return warnings

    def _revision(self) -> str:
        return self._required("rev-parse", "HEAD")

    def _remote_revision(self) -> str | None:
        branch = self._required("branch", "--show-current")
        if not branch:
            return None
        completed = self._run("rev-parse", f"origin/{branch}")
        return completed.stdout.strip() if completed.returncode == 0 else None

    def _push_remote_background(self) -> str | None:
        environment = dict(os.environ)
        environment["GIT_TERMINAL_PROMPT"] = "0"
        try:
            subprocess.Popen(
                (
                    "git",
                    "-c",
                    "http.lowSpeedLimit=1",
                    "-c",
                    "http.lowSpeedTime=15",
                    "-C",
                    str(self.repository),
                    "push",
                    "origin",
                    "HEAD",
                ),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=environment,
                start_new_session=True,
            )
        except OSError as exc:
            return f"remote push could not be queued: {exc}"
        return None

    def _status(
        self,
        warnings: Sequence[str] = (),
        *,
        changed: bool = False,
    ) -> SyncStatus:
        porcelain = self._required("status", "--porcelain")
        dirty_count = len([line for line in porcelain.splitlines() if line.strip()])
        remote_revision = self._remote_revision()
        current = True
        if remote_revision is not None:
            current = self._run(
                "merge-base", "--is-ancestor", remote_revision, "HEAD"
            ).returncode == 0
        return SyncStatus(
            transport="git",
            local_revision=f"git:{self._revision()}",
            remote_revision=f"git:{remote_revision}" if remote_revision else None,
            clean=dirty_count == 0,
            warnings=tuple(warnings),
            current=current,
            changed=changed,
            dirty_count=dirty_count,
        )

    def _relative_paths(self, paths: Sequence[str]) -> tuple[str, ...]:
        relative: list[str] = []
        for raw in paths:
            candidate = Path(raw)
            if not candidate.is_absolute():
                candidate = self.repository / candidate
            resolved = candidate.resolve()
            try:
                item = resolved.relative_to(self.repository).as_posix()
            except ValueError as exc:
                raise GitSyncError(f"sync path is outside canonical repository: {raw}") from exc
            if item and item not in relative:
                relative.append(item)
        return tuple(relative)

    @staticmethod
    def _provenance_trailers() -> tuple[str, ...]:
        session_id = os.environ.get("EGREGORE_SESSION_ID", "unknown")
        runtime = os.environ.get("EGREGORE_RUNTIME", "shell").strip().lower()
        coauthors = {
            "codex": "OpenAI Codex <noreply@openai.com>",
            "claude": "Claude Code <noreply@anthropic.com>",
            "claude-code": "Claude Code <noreply@anthropic.com>",
            "pi": "Pi Egregore Runtime <noreply@egregore.xyz>",
            "prime": "Prime Agent <noreply@egregore.xyz>",
        }
        trailers = [
            f"Egregore-Session: {session_id}",
            f"Egregore-Harness: {runtime}",
        ]
        if coauthor := coauthors.get(runtime):
            trailers.append(f"Co-Authored-By: {coauthor}")
        return tuple(trailers)

    def status(self) -> SyncStatus:
        return self._status()

    def pull(self) -> SyncStatus:
        warnings: list[str] = self._reap_stale_locks()
        before = self._revision()
        if self._run("remote", "get-url", "origin").returncode != 0:
            return self._status(
                (*warnings, "no origin remote configured; canonical history is local")
            )
        branch = self._required("branch", "--show-current")
        if not branch:
            raise GitSyncError("canonical Git repository is on a detached HEAD", kind="detached")
        # EGREGORE_SYNC_FETCH_FRESH=1 means the caller proved a successful
        # fetch of this repository moments ago (the attendant's warm marker is
        # stamped only after its fetches succeed). Reuse that remote-tracking
        # ref instead of paying a second network round; if the ref is absent
        # the claim is void and the fetch happens anyway. Integration below is
        # unchanged — currency is still judged against the remote revision.
        fetch_is_fresh = (
            os.environ.get("EGREGORE_SYNC_FETCH_FRESH") == "1"
            and self._remote_revision() is not None
        )
        if not fetch_is_fresh:
            self._required("fetch", "origin", branch, timeout=180)
        remote_revision = self._remote_revision()
        if remote_revision is None:
            raise GitSyncError(f"origin/{branch} is unavailable after fetch", kind="network")

        # A dirty canonical checkout is safe when it is already current or
        # locally ahead: no working-tree mutation is needed. Only ask Git to
        # integrate when the fetched remote is not already contained in HEAD.
        remote_is_ancestor = self._run(
            "merge-base", "--is-ancestor", remote_revision, "HEAD"
        ).returncode == 0
        if not remote_is_ancestor:
            warnings.extend(self._integrate_remote(remote_revision))

        # Reconcile locally-ahead history. Writeback pushes run detached and a
        # rejection (the remote moved first) used to leave commits stranded
        # until someone noticed; the pull is the periodic rendezvous with the
        # remote, so it is the right place to finish that delivery.
        if self.push_remote and self._local_is_ahead():
            warnings.extend(self._push_with_retry())
        warnings.extend(self._take_lock_warnings())
        return self._status(tuple(warnings), changed=self._revision() != before)

    def _local_is_ahead(self) -> bool:
        remote_revision = self._remote_revision()
        if remote_revision is None:
            return False
        if remote_revision == self._revision():
            return False
        return self._run("merge-base", "--is-ancestor", remote_revision, "HEAD").returncode == 0

    def _integrate_remote(self, remote_revision: str) -> list[str]:
        """Integrate fetched history into a possibly-dirty canonical checkout.

        Canonical memory has many concurrent writers (sessions, background
        capture, hosted agents) appending distinct files — incoming history
        plus local edits is almost never a content conflict, so it must
        self-heal instead of failing closed. The rebase autostashes local
        edits and re-applies them; edits git cannot re-apply are parked in
        the stash (content preserved, surfaced as a warning). Only a rebase
        that itself conflicts — a genuine same-line collision with local
        commits — fails closed.
        """
        warnings: list[str] = []
        dirty = bool(self._required("status", "--porcelain"))
        stashes_before = self._run("stash", "list").stdout.count("\n")
        arguments = ["rebase"]
        if dirty:
            arguments.append("--autostash")
        result = self._run(*arguments, remote_revision, timeout=180)
        if result.returncode != 0:
            self._run("rebase", "--abort")
            detail = (result.stderr or result.stdout).strip()
            last_line = detail.splitlines()[-1] if detail else ""
            kind = _classify_git_failure(detail)
            if kind == "lock":
                raise GitSyncError(
                    "canonical sync could not integrate incoming changes because a "
                    "git lock file blocks the memory repository"
                    + (f" ({last_line})" if last_line else ""),
                    kind="lock",
                )
            if kind in ("auth", "network"):
                raise GitSyncError(
                    f"canonical sync could not reach the remote ({last_line})", kind=kind
                )
            raise GitSyncError(
                "canonical sync hit a real content conflict while integrating "
                "incoming changes; resolve it in the memory repository"
                + (f" ({last_line})" if last_line else ""),
                kind="conflict",
            )
        if dirty and self._run("stash", "list").stdout.count("\n") > stashes_before:
            # Git kept the whole autostash entry AND left a conflicted
            # application in the tree. Every local edit is safe inside the
            # kept stash, so the tree resets to the clean rebased HEAD —
            # parked edits, never conflict markers in canonical files.
            self._run("reset", "--hard", "HEAD")
            warnings.append(
                "local memory edits could not be re-applied over incoming "
                "changes and were parked in git stash — recover with "
                "`git stash pop` in the memory repository"
            )
        return warnings

    def _push_with_retry(self, attempts: int = 3) -> list[str]:
        """Push canonical history, absorbing the many-writer race.

        The memory remote moves constantly (teammates' sessions, background
        capture, hosted agents). A rejected push is re-integrated with an
        autostashed rebase and retried — the exact manual recovery this
        failure class always needed — before anything is reported as failed.
        """
        detail = ""
        for attempt in range(attempts):
            pushed = self._run("push", "origin", "HEAD", timeout=180)
            if pushed.returncode == 0:
                return []
            detail = (pushed.stderr or pushed.stdout).strip()
            if attempt == attempts - 1:
                break
            branch = self._required("branch", "--show-current")
            if not branch:
                break
            if self._run("fetch", "origin", branch, timeout=180).returncode != 0:
                break
            remote_revision = self._remote_revision()
            if remote_revision is None:
                break
            try:
                self._integrate_remote(remote_revision)
            except GitSyncError as exc:
                return [f"remote push failed: {exc}"]
        return [f"remote push failed: {detail or 'git push failed'}"]

    def push(self, *, message: str, paths: Sequence[str] = ()) -> SyncStatus:
        selected = self._relative_paths(paths)
        if not selected:
            raise GitSyncError("path-aware canonical sync requires at least one artifact path")

        warnings: list[str] = self._reap_stale_locks()
        self._required("add", "--", *selected, literal_pathspecs=True)
        staged = self._run("diff", "--cached", "--quiet", "--", *selected, literal_pathspecs=True)
        if staged.returncode not in (0, 1):
            raise GitSyncError((staged.stderr or staged.stdout).strip() or "git diff failed")
        if staged.returncode == 1:
            arguments = [
                "commit",
                "--only",
                "-m",
                message,
                "-m",
                "Record the authorized canonical artifact and its provenance.",
            ]
            for trailer in self._provenance_trailers():
                arguments.extend(("-m", trailer))
            arguments.extend(("--", *selected))
            self._required(*arguments, literal_pathspecs=True)

        if self.push_remote:
            if self._run("remote", "get-url", "origin").returncode == 0:
                if self.async_remote_push:
                    if warning := self._push_remote_background():
                        warnings.append(warning)
                else:
                    warnings.extend(self._push_with_retry())
            else:
                warnings.append("no origin remote configured; canonical history is local")
        warnings.extend(self._take_lock_warnings())
        return self._status(warnings)


def _describe_age(seconds: float) -> str:
    if seconds < 3600:
        return f"{int(seconds // 60)}m"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h"
    return f"{int(seconds // 86400)}d"
