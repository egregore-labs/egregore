"""Internal shell bridge to the canonical artifact/writeback service."""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

from .artifacts import parse_canonical_markdown, split_frontmatter
from .contracts import Permission
from .runtime import local_runtime, runtime_root
from .scratch import read_and_consume
from .writeback import canonical_file_path


class WritebackUsageError(ValueError):
    """The requested canonical file or command arguments are invalid."""


def _nonempty_message(value: str) -> str:
    if not value.strip():
        raise argparse.ArgumentTypeError("commit requires a non-empty message")
    return value


def _canonical_source(root: Path, path: str) -> Path:
    try:
        return canonical_file_path(root / "memory", path)
    except ValueError as exc:
        raise WritebackUsageError(str(exc)) from exc


def _canonical_argument(value: str) -> str:
    try:
        _canonical_source(_root(), value)
    except WritebackUsageError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    return value


def _markdown_argument(value: str) -> str:
    _canonical_argument(value)
    if Path(value).suffix.lower() != ".md":
        raise argparse.ArgumentTypeError("adopt requires a canonical Markdown file")
    return value


def _root() -> Path:
    return Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()


def _adopt(args: argparse.Namespace) -> int:
    root = _root()
    memory = (root / "memory").resolve()
    # Capture workers report the checkout-facing memory symlink. Resolve both
    # sides before enforcing containment so a legitimate instance-owned
    # canonical write is not mistaken for an external path.
    source = _canonical_source(root, args.path)
    relative = source.relative_to(memory).as_posix()
    if source.suffix.lower() != ".md":
        raise WritebackUsageError("adopt requires a canonical Markdown file")

    runtime = local_runtime(root, push_remote=not args.no_push)
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid.uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    markdown = source.read_text(encoding="utf-8")
    # Only a rendering with no frontmatter at all may borrow the session's
    # identity and clock. A partially populated legacy artifact still fails:
    # inventing its missing authorship would forge organizational provenance.
    fields, _ = split_frontmatter(markdown)
    document = parse_canonical_markdown(
        markdown,
        canonical_path=relative,
        default_org_id=actor.profile.org_id,
        default_created_at=None if fields else datetime.now(UTC),
        default_created_by=None if fields else actor.actor.actor_id,
        # The source may be a file a previous adopt rewrote and the ritual then
        # re-rendered, so its declared digest is not evidence of its body.
        recompute_digest=True,
    )
    if args.replace:
        document = replace(document, replaces_existing=True)
    receipt = runtime.write_document(actor, document)
    payload = receipt.to_dict()
    # Both verbs report the canonical path the same way; adopt keeps the full
    # artifact envelope alongside it.
    payload["canonical_path"] = receipt.artifact.canonical_path
    print(json.dumps(payload, ensure_ascii=False))
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _commit(args: argparse.Namespace) -> int:
    root = _root()
    sources = tuple(str(_canonical_source(root, path)) for path in args.path)
    if not args.message.strip():
        raise WritebackUsageError("commit requires a non-empty message")
    runtime = local_runtime(root, push_remote=not args.no_push)
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid.uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    receipt = runtime.commit_canonical_files(actor, sources, message=args.message)
    print(json.dumps(receipt.to_dict(), ensure_ascii=False))
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _create(args: argparse.Namespace) -> int:
    root = runtime_root()
    runtime = local_runtime(root, push_remote=not args.no_push)
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid.uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    document = parse_canonical_markdown(
        read_and_consume(args.input, root).decode("utf-8"),
        canonical_path=args.path.removeprefix("memory/"),
        default_org_id=actor.profile.org_id,
    )
    receipt = runtime.write_document(actor, document)
    print(json.dumps(receipt.to_dict(), ensure_ascii=False))
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _authorize(args: argparse.Namespace) -> int:
    root = _root()
    runtime = local_runtime(root, push_remote=False)
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid.uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    decision = runtime.authorize(
        actor,
        Permission(args.permission),
        (args.resource,) if args.resource else (),
    )
    print(json.dumps(decision.to_dict(), ensure_ascii=False))
    return 0 if decision.allowed else 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-artifact-writeback")
    commands = parser.add_subparsers(dest="command", required=True)
    adopt = commands.add_parser("adopt")
    adopt.add_argument("path", type=_markdown_argument)
    adopt.add_argument("--no-push", action="store_true")
    adopt.add_argument("--replace", action="store_true")
    adopt.set_defaults(handler=_adopt)
    commit = commands.add_parser("commit")
    commit.add_argument("--path", type=_canonical_argument, action="append", required=True)
    commit.add_argument("--message", type=_nonempty_message, required=True)
    commit.add_argument("--no-push", action="store_true")
    commit.set_defaults(handler=_commit)
    create = commands.add_parser("create")
    create.add_argument("--path", required=True)
    create.add_argument("--input", required=True)
    create.add_argument("--no-push", action="store_true")
    create.set_defaults(handler=_create)
    authorize = commands.add_parser("authorize")
    authorize.add_argument("permission", choices=[item.value for item in Permission])
    authorize.add_argument("--resource")
    authorize.set_defaults(handler=_authorize)
    return parser


def main() -> int:
    parser = _parser()
    args = parser.parse_args()
    try:
        return args.handler(args)
    except WritebackUsageError as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(f"writeback: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
