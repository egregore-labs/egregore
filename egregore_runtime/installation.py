"""Which Egregore installation a checkout belongs to.

Standard library only, no package imports: the upgrade engine, the map
hand-over and the memory map notice writer import it, and the map's server
(serve.py) loads this file by path from a checkout that may run another Runtime
version.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
from pathlib import Path

_SMALL = 4096  # a .git file or a git dir's back-link is one short path
_UNSET = object()


def _read_small(path: str) -> str:
    """A short regular file's text; a link, folder, pipe or device raises OSError."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise OSError(f"not a regular file: {path}")
        return os.read(descriptor, _SMALL).decode("utf-8")
    finally:
        os.close(descriptor)


def installation_root(repository_root) -> Path:
    """The main installation directory a checkout belongs to.

    A linked git worktree (``.git`` is a file) belongs to its main checkout;
    upgrade state is per installation, so every worktree of one install
    shares it. A standalone clone is its own installation.

    The ``.git`` file sits in the checkout and anyone working there can rewrite
    it, so its claim counts only when the git dir links back to this checkout,
    as git's own ``<gitdir>/gitdir`` file does for a real linked worktree (the
    check bin/boundary-guard.cjs makes). A forged or broken ``.git`` file, a git
    dir outside ``<main>/.git/worktrees/<name>``, or any read error makes the
    checkout its own installation.

    So does a worktree moved with plain ``mv``: its back-link still names the
    old place until ``git worktree repair`` is run in it. The shell copies of
    this climb (bin/search.sh, bin/settings.sh, bin/graph.sh, bin/lib/greeting.sh,
    bin/lib/runtime-owned.sh) skip the back-link and key such a checkout by its
    main checkout. Every genuine layout gets the same answer from both.
    """
    root = Path(repository_root).resolve()
    marker = root / ".git"
    try:
        if not stat.S_ISREG(os.lstat(marker).st_mode):
            return root
        for line in _read_small(str(marker)).splitlines():
            if line.startswith("gitdir:"):
                git_dir = Path(line.split(":", 1)[1].strip())
                break
        else:
            return root
        if not git_dir.is_absolute():
            git_dir = (root / git_dir).resolve()
        # <main>/.git/worktrees/<name> → <main>
        if git_dir.parent.name != "worktrees" or git_dir.parent.parent.name != ".git":
            return root
        back = _read_small(str(git_dir / "gitdir")).strip()
        # ``root`` is resolved and ``.git`` was read as a regular file, so ``marker`` is already its
        # real path; resolving it again would follow a ``.git`` swapped for a link after the read.
        if not back or os.path.realpath(os.path.join(git_dir, back)) != str(marker):
            return root
        main = git_dir.parent.parent.parent
        return main.resolve() if main.is_dir() else root
    except (OSError, ValueError):
        return root


class InstallationIdentityError(ValueError):
    """The checkout has no stable organization identity, so per-installation state fails closed."""


def installation_key(repository_root, *, existing_org_id=_UNSET) -> str:
    """Durable per-installation key: stable org identity × installation identity.

    It keys upgrade state and the map hand-over slot. Identity is never inferred
    from a path alone: the stable organization ID from egregore.json is required
    and leads the key, so two organizations that share, symlink, or otherwise
    resolve to the same memory repository never share state. The installation
    path is composed in so two installs of one organization stay independent,
    while worktrees of one install share it. A checkout without a stable org_id
    fails closed.

    ``existing_org_id`` is an optional host-owned value already read and
    validated by a caller. It avoids a second config read; it does not change
    installation_root's existing path/backlink semantics or authenticate an org.
    """
    root = Path(repository_root).resolve()
    if existing_org_id is _UNSET:
        try:
            org_id = str(json.loads((root / "egregore.json").read_text(encoding="utf-8")).get("org_id") or "").strip()
        except (OSError, ValueError, AttributeError) as exc:
            raise InstallationIdentityError(f"cannot read egregore.json for instance identity: {exc}") from exc
    else:
        org_id = existing_org_id
        try:
            valid = (isinstance(org_id, str) and bool(org_id) and org_id == org_id.strip()
                     and len(org_id.encode("utf-8")) <= 2000
                     and not any(ord(character) < 33 or ord(character) == 127 for character in org_id))
        except UnicodeError:
            valid = False
        if not valid:
            raise InstallationIdentityError("a canonical existing organization identity is required")
    if not org_id:
        raise InstallationIdentityError(
            "this instance has no stable org_id; per-installation state fails closed "
            "without a stable organization identity"
        )
    return hashlib.sha256(f"{org_id}|{installation_root(root)}".encode("utf-8")).hexdigest()[:16]
