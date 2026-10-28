"""Handle-anchored scratch input consumption and session cleanup.

GUARANTEE: no deletion ever follows a symlink out of `root/tmp`, and no
pathname is trusted between a check and a delete. NOT GUARANTEED: a
concurrent process that renames a directory out of `root/tmp`, or
replaces a scratch file, during the operation; `tmp/` is the session's
own gitignored scratch and is not a security boundary against a hostile
local process.

Inside-scratch consumers refuse symlinks; the sweep unlinks symlink entries,
never targets. Outside inputs retain ordinary path-reader semantics and are
never consumed. Relative paths are interpreted from the caller's cwd.
read_and_consume binds deletion to the descriptor read via device/inode.
The shell consume path is pathname-bound after the read: it cannot bind an
earlier shell read to an inode. All scratch entry operations use verified directory
handles, never a checked pathname. Consumers allow at most three intermediate
directories below `root/tmp`; the sweep is handle-anchored at every level and
unbounded in depth. Sweep directories use only symlink-safe rmtree.
Deletion errors are diagnostic only; read errors still reach the caller.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import errno
import os
from pathlib import Path
import shutil
import stat
import sys
import time

from .runtime import runtime_root


_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
_FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
_MAX_INTERMEDIATE_LEVELS = 3


class _OutsideScratch(ValueError):
    pass


def _diagnostic(path: str | Path, reason: str = "") -> None:
    # One diagnostic line even for an unusual filename.
    display = str(path).replace("\n", "\\n").replace("\r", "\\r")
    print(f"scratch: could not remove {display}{f' ({reason})' if reason else ''}", file=sys.stderr)


def _relative_parts(path: str | Path, root: Path) -> tuple[str, ...]:
    if not str(path):
        raise ValueError("scratch path must not be empty")
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    has_parent_component = ".." in candidate.parts
    try:
        candidate = candidate.relative_to(root)
    except ValueError as exc:
        # Resolve only the checkout prefix, never tmp or any candidate
        # component below it. macOS commonly spells the same checkout
        # /var/... and /private/var/... in shell and Python respectively.
        for index, part in enumerate(candidate.parts):
            if part == "tmp" and Path(*candidate.parts[:index]).resolve() == root:
                candidate = Path(*candidate.parts[index:])
                break
        else:
            raise _OutsideScratch("outside checkout/tmp") from exc
    if not candidate.parts or candidate.parts[0] != "tmp":
        raise _OutsideScratch("outside checkout/tmp")
    if has_parent_component:
        raise ValueError("parent components are not scratch paths")
    # Path() drops a trailing slash, which would otherwise turn a failed file
    # read into permission to consume a different spelling of that path.
    if str(path).endswith("/"):
        raise ValueError("scratch file path must not end with a slash")
    parts = candidate.parts[1:]
    if not parts or len(parts) - 1 > _MAX_INTERMEDIATE_LEVELS:
        raise ValueError("scratch candidate must be a file within three directory levels")
    return parts


@contextmanager
def _tmp_handle(root: Path):
    # Do not resolve tmp: resolving it would erase the symlink refusal.
    try:
        descriptor = os.open(root / "tmp", _DIRECTORY_FLAGS)
    except OSError as exc:
        raise OSError("tmp is missing, a symlink, or not an accessible real directory") from exc
    try:
        yield descriptor
    finally:
        os.close(descriptor)


@contextmanager
def _parent_handle(root: Path, parts: tuple[str, ...]):
    with _tmp_handle(root) as tmp_fd:
        parent_fd = tmp_fd
        opened = []
        try:
            for part in parts[:-1]:
                parent_fd = os.open(part, _DIRECTORY_FLAGS, dir_fd=parent_fd)
                opened.append(parent_fd)
            yield parent_fd, parts[-1]
        finally:
            for descriptor in reversed(opened):
                os.close(descriptor)


def _unlink_regular(parent_fd: int, name: str, path: str | Path,
                    expected: os.stat_result | None = None) -> bool:
    """Separate final step so descriptor/entry replacement is testable."""
    try:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(current.st_mode):
            _diagnostic(path)
            return False
        if expected is not None and (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
            _diagnostic(path)
            return False
        os.unlink(name, dir_fd=parent_fd)
        return True
    except (OSError, ValueError, NotImplementedError):
        _diagnostic(path)
        return False


def consume(path: str | Path, root: str | Path) -> None:
    """Best-effort pathname-bound deletion; outside inputs are silent no-ops."""
    try:
        resolved_root = runtime_root(root)
        parts = _relative_parts(path, resolved_root)
        with _parent_handle(resolved_root, parts) as (parent_fd, name):
            _unlink_regular(parent_fd, name, path)
    except _OutsideScratch:
        return
    except (OSError, ValueError, NotImplementedError) as exc:
        _diagnostic(path, str(exc) if "tmp is missing" in str(exc) else "")


def _read_descriptor(descriptor: int) -> tuple[bytes, os.stat_result]:
    # fdopen owns the descriptor even if fstat/read fails.
    with os.fdopen(descriptor, "rb") as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError("scratch input must be a regular file")
        return source.read(), metadata


def read_and_consume(path: str | Path, root: str | Path) -> bytes:
    """Read an input; consume only regular, non-symlink checkout/tmp inputs.

    Relative paths are relative to cwd. Outside scratch, retain the original
    path-reader semantics and never delete. Scratch candidates containing a
    parent component are refused without reading or deleting.
    """
    resolved_root = runtime_root(root)
    try:
        parts = _relative_parts(path, resolved_root)
    except _OutsideScratch:
        return Path(path).read_bytes()
    except ValueError as exc:
        raise OSError(errno.EINVAL, f"scratch policy: {exc}", str(path)) from exc
    try:
        with _parent_handle(resolved_root, parts) as (parent_fd, name):
            try:
                descriptor = os.open(name, _FILE_FLAGS, dir_fd=parent_fd)
            except OSError as exc:
                if exc.errno == errno.ELOOP:
                    raise OSError(f"scratch input must not be a symlink: {path}") from exc
                raise
            data, metadata = _read_descriptor(descriptor)
            _unlink_regular(parent_fd, name, path, metadata)
            return data
    except OSError as exc:
        if "tmp is missing" in str(exc):
            _diagnostic(path, str(exc))
        raise


def _remove_directory(parent_fd: int, name: str, display: Path, dry_run: bool) -> int:
    if not shutil.rmtree.avoids_symlink_attacks:
        _diagnostic(display, "symlink-safe directory removal is unavailable")
        return 0
    if dry_run:
        print(display)
        return 1
    try:
        shutil.rmtree(name, dir_fd=parent_fd)
        return 1
    except (OSError, ValueError, NotImplementedError):
        _diagnostic(display)
        return 0


def _sweep_entries(parent_fd: int, display: Path, cutoff: float | None,
                   dry_run: bool, *, top: bool = False) -> tuple[int, bool]:
    removed = 0
    remaining = False
    for name in os.listdir(parent_fd):
        if top and name == ".gitkeep":
            remaining = True
            continue
        entry = display / name
        try:
            metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if stat.S_ISDIR(metadata.st_mode):
                if cutoff is None:
                    count = _remove_directory(parent_fd, name, entry, dry_run)
                else:
                    child_fd = os.open(name, _DIRECTORY_FLAGS, dir_fd=parent_fd)
                    try:
                        child_count, child_remaining = _sweep_entries(child_fd, entry, cutoff, dry_run)
                        removed += child_count
                    finally:
                        os.close(child_fd)
                    # Do not remove a directory with any fresh/failed entry.
                    # Recheck emptiness through a handle at removal time, too.
                    count = 0
                    if not child_remaining:
                        verify_fd = os.open(name, _DIRECTORY_FLAGS, dir_fd=parent_fd)
                        try:
                            if dry_run or not os.listdir(verify_fd):
                                count = _remove_directory(parent_fd, name, entry, dry_run)
                        finally:
                            os.close(verify_fd)
                removed += count
                remaining |= not bool(count)
            elif cutoff is not None and metadata.st_mtime >= cutoff:
                remaining = True
            else:
                if dry_run:
                    print(entry)
                else:
                    os.unlink(name, dir_fd=parent_fd)
                removed += 1
        except (OSError, ValueError, NotImplementedError):
            _diagnostic(entry)
            remaining = True
    return removed, remaining


def sweep(root: str | Path, *, older_than: float | None = None, dry_run: bool = False) -> int:
    """Remove scratch entries; return the number removed (or planned).

    An unfiltered directory subtree counts as one selected entry. An age
    filtered sweep counts each selected leaf and newly empty directory.
    """
    removed = 0
    try:
        resolved_root = runtime_root(root)
        cutoff = None if older_than is None else time.time() - older_than * 60
        with _tmp_handle(resolved_root) as tmp_fd:
            removed, _ = _sweep_entries(tmp_fd, resolved_root / "tmp", cutoff, dry_run, top=True)
    except (OSError, ValueError, NotImplementedError, RecursionError) as exc:
        _diagnostic(Path(root) / "tmp", str(exc) if "tmp is missing" in str(exc) else "")
    print(f"scratch-sweep: removed {removed} entries", file=sys.stderr)
    return removed


def _minutes(value: str) -> float:
    import math
    try:
        number = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("minutes must be a nonnegative number") from exc
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("minutes must be a nonnegative number")
    return number


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    consumer = commands.add_parser("consume")
    consumer.add_argument("path")
    consumer.add_argument("--root", type=Path)
    sweeper = commands.add_parser("sweep")
    sweeper.add_argument("--root", type=Path)
    sweeper.add_argument("--older-than", type=_minutes)
    sweeper.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "consume":
        consume(args.path, runtime_root(args.root))
    else:
        sweep(runtime_root(args.root), older_than=args.older_than, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
