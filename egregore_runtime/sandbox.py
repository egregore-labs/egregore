"""Sandbox markers, and where per-user state goes when it refuses writes.

A session started outside the ``egregore`` launcher can run inside Codex's
sandbox or a macOS app sandbox, where the per-user state under ``~/.egregore``
refuses writes. A sandbox is named only from positive markers, the predicate
``bin/lib/secret_entry.py`` and ``bin/reflexes/20-sandbox.sh`` also use; a
failing write alone never names one.
"""

from __future__ import annotations

from contextlib import suppress
import errno
import os
from pathlib import Path
import stat
import tempfile
from typing import Mapping

# The errors that mean a location refuses writes. Anything else (a file where
# a directory belongs, a full disk) keeps its own failure: a fallback must not
# hide an unrelated fault.
REFUSED = frozenset({errno.EACCES, errno.EPERM, errno.EROFS})
REMEDY = "start through `egregore` to lift it"
# The workspace copy ignores itself, so it never reaches a commit in a
# checkout whose .gitignore predates it.
IGNORE_EVERYTHING = "# Egregore state for a sandboxed session\n*\n"


class FallbackRefused(Exception):
    """The workspace copy cannot be used; the message says why."""


def sandboxed(environment: Mapping[str, str] | None = None) -> bool:
    """True when CODEX_SANDBOX or APP_SANDBOX_CONTAINER_ID says so."""
    env = os.environ if environment is None else environment
    return (str(env.get("CODEX_SANDBOX") or "").lower() not in {"", "none", "false", "0"}
            or bool(env.get("APP_SANDBOX_CONTAINER_ID")))


def reason(error: OSError) -> str:
    return (error.strerror or type(error).__name__).lower()


def write_probe(directory: Path) -> OSError | None:
    """Create and remove one file where ``directory`` is, or would be created.

    The file goes in the nearest existing ancestor, so the probe creates no
    directory. A file that cannot be removed fails the probe as surely as one
    that cannot be created. Returns the error, or None when both succeeded.
    """
    anchor = Path(directory)
    while not os.path.exists(anchor) and anchor.parent != anchor:
        anchor = anchor.parent
    try:
        descriptor, probe = tempfile.mkstemp(prefix=".egregore-write-probe-", dir=anchor)
    except OSError as error:
        return error
    removal: OSError | None = None
    try:
        os.close(descriptor)
    except OSError:
        pass
    finally:
        try:
            os.unlink(probe)
        except OSError as error:
            removal = error
    return removal


def display(path: Path, home: Path | None = None) -> str:
    """``path`` with the home directory written as ``~``.

    Both the home as given and its resolved form count, so a resolved path
    under a linked home does not show the physical directory.
    """
    try:
        base = Path(home) if home is not None else Path.home()
    except (KeyError, OSError, RuntimeError):
        return str(path)
    bases = [base]
    with suppress(OSError, RuntimeError):
        if base.resolve() != base:
            bases.append(base.resolve())
    for candidate in bases:
        if candidate == candidate.parent:
            continue
        try:
            relative = Path(path).relative_to(candidate)
        except ValueError:
            continue
        return "~" if relative == Path(".") else f"~/{relative.as_posix()}"
    return str(path)


def _ignore_everything(directory: Path, home: Path | None) -> None:
    """Make ``directory/.gitignore`` a regular file that ignores everything.

    A file that already says so is kept. Anything else (missing, empty,
    edited, a link, not a file) is replaced through a temporary file and a
    rename, which replaces a link itself and never writes through it.
    """
    ignore = directory / ".gitignore"
    current = None
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    with suppress(OSError):
        descriptor = os.open(ignore, flags)
        with os.fdopen(descriptor, "rb") as handle:
            if stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                current = handle.read(len(IGNORE_EVERYTHING) + 1)
    if current == IGNORE_EVERYTHING.encode():
        return
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=".gitignore.", dir=directory)
    except OSError as error:
        raise FallbackRefused(f"{display(ignore, home)} cannot be written ({reason(error)})") from error
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(IGNORE_EVERYTHING)
        os.replace(temporary, ignore)
    except OSError as error:
        with suppress(OSError):
            os.unlink(temporary)
        raise FallbackRefused(f"{display(ignore, home)} cannot be written ({reason(error)})") from error


def _prepare(fallback: Path, workspace: Path, home: Path | None) -> None:
    """Create ``fallback`` inside ``workspace`` and make it ignore itself.

    Raises FallbackRefused, naming why, when the copy would leave the
    workspace (through a link under it or outright), or when it cannot be
    created, marked ignored, or written.
    """
    root = Path(workspace)
    try:
        relative = Path(fallback).relative_to(root)
    except ValueError:
        relative = None
    if relative is None or not relative.parts:
        # Never the workspace root itself: its .gitignore would hide the checkout.
        raise FallbackRefused(f"{display(fallback, home)} is not inside the workspace")
    current = root
    for part in relative.parts:
        current = current / part
        if os.path.islink(current):
            raise FallbackRefused(f"{display(current, home)} is a link")
        try:
            os.mkdir(current, 0o700)
        except FileExistsError:
            if os.path.islink(current) or not os.path.isdir(current):
                raise FallbackRefused(f"{display(current, home)} is not a directory") from None
        except OSError as error:
            raise FallbackRefused(f"{display(current, home)} cannot be created ({reason(error)})") from error
    try:
        inside = Path(os.path.realpath(fallback)).is_relative_to(os.path.realpath(root))
    except (OSError, ValueError):
        inside = False
    if not inside:
        raise FallbackRefused(f"{display(fallback, home)} resolves outside the workspace")
    _ignore_everything(Path(fallback), home)
    # An ignore file that already matched proves nothing about new files: a
    # folder may take subfolders yet refuse files (a macOS deny add_file ACL).
    error = write_probe(Path(fallback))
    if error is not None:
        raise FallbackRefused(f"{display(fallback, home)} is not writable ({reason(error)})")


def state_directory(
    preferred: Path,
    fallback: Path,
    *,
    workspace: Path,
    environment: Mapping[str, str] | None = None,
    home: Path | None = None,
) -> tuple[Path, str | None]:
    """``preferred``, or ``fallback`` when the first refuses writes; and a warning.

    The fallback is taken only when ``preferred`` refuses writes and the
    workspace copy can be created inside ``workspace`` and marked ignored.
    The warning names the cause, the sandbox when a marker is set and the
    operating system's reason otherwise. When the copy is refused too, the
    preferred directory stays, and the warning names both failures.
    """
    error = write_probe(preferred)
    if error is None or error.errno not in REFUSED:
        return preferred, None
    cause = "sandbox" if sandboxed(environment) else reason(error)
    refused = f"per-user state at {display(preferred, home)} is not writable ({cause})"
    try:
        _prepare(fallback, workspace, home)
    except FallbackRefused as why:
        return preferred, f"{refused}; no workspace copy either: {why}"
    return fallback, f"{refused}; using {display(fallback, home)}"
