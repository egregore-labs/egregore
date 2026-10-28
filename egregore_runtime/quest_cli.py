"""Runtime-neutral CLI for canonical collaborative quests."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from uuid import uuid4

from .contracts import Permission
from .policy import scope_allows_path
from .quests import CanonicalQuestService
from .runtime import local_runtime


PRIORITIES = {"none": 0, "low": 1, "medium": 2, "high": 3}


def _context():
    root = Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()
    runtime = local_runtime(root, push_remote=os.environ.get("EGREGORE_NO_PUSH") != "1")
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    service = CanonicalQuestService(
        memory_root=(root / "memory").resolve(),
        write_document=runtime.write_document,
    )
    return runtime, actor, service


def _require(
    runtime,
    actor,
    permission: Permission,
    resource: str,
    *,
    canonical_path: str | None = None,
):
    decision = runtime.authorize(actor, permission, (resource,))
    if not decision.allowed:
        raise PermissionError("; ".join(decision.reasons) or f"quest {permission.value} denied")
    if canonical_path and not scope_allows_path(canonical_path, decision.scopes):
        raise PermissionError("quest path is outside the actor's authorized scope")
    return decision


def _row(snapshot, *, detail: bool = False):
    row = {
        "id": snapshot.document.artifact.artifact_id,
        "slug": snapshot.slug,
        "title": snapshot.title,
        "status": snapshot.status,
        "projects": list(snapshot.projects),
        "started": snapshot.started,
        "started_by": snapshot.started_by,
        "priority": snapshot.priority,
        "completed": snapshot.completed,
        "canonical_path": f"memory/quests/{snapshot.slug}.md",
    }
    if detail:
        row["body"] = snapshot.body
    return row


def _list(args):
    runtime, actor, service = _context()
    decision = _require(runtime, actor, Permission.READ, "quests")
    rows = [
        _row(snapshot)
        for snapshot in service.list(
            actor,
            include_completed=args.all,
            authorized_scopes=decision.scopes,
        )
    ]
    print(json.dumps({"quests": rows}, ensure_ascii=False))
    return 0


def _show(args):
    runtime, actor, service = _context()
    _require(
        runtime,
        actor,
        Permission.READ,
        f"quest:{args.slug}",
        canonical_path=service.canonical_path(args.slug),
    )
    print(json.dumps({"quest": _row(service.read(actor, args.slug), detail=True)}, ensure_ascii=False))
    return 0


def _write_result(snapshot, receipt):
    print(
        json.dumps(
            {"quest": _row(snapshot), "writeback": receipt.to_dict()},
            ensure_ascii=False,
        )
    )
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _create(args):
    runtime, actor, service = _context()
    resource = f"quest:{args.slug or args.title}"
    _require(
        runtime,
        actor,
        Permission.WRITE,
        resource,
        canonical_path=service.canonical_path(args.slug or args.title),
    )
    snapshot, receipt = service.create(
        actor,
        title=args.title,
        question=args.question,
        slug=args.slug,
        projects=args.project,
        threads=args.thread,
    )
    return _write_result(snapshot, receipt)


def _prioritize(args):
    runtime, actor, service = _context()
    _require(
        runtime,
        actor,
        Permission.WRITE,
        f"quest:{args.slug}",
        canonical_path=service.canonical_path(args.slug),
    )
    value = PRIORITIES.get(args.priority, int(args.priority) if args.priority.isdigit() else -1)
    snapshot, receipt = service.prioritize(actor, slug=args.slug, priority=value)
    return _write_result(snapshot, receipt)


def _transition(args):
    runtime, actor, service = _context()
    _require(
        runtime,
        actor,
        Permission.WRITE,
        f"quest:{args.slug}",
        canonical_path=service.canonical_path(args.slug),
    )
    snapshot, receipt = service.transition(
        actor,
        slug=args.slug,
        status=args.command,
        outcome=getattr(args, "outcome", None),
    )
    return _write_result(snapshot, receipt)


def _contribute(args):
    runtime, actor, service = _context()
    _require(
        runtime,
        actor,
        Permission.WRITE,
        f"quest:{args.slug}",
        canonical_path=service.canonical_path(args.slug),
    )
    snapshot, receipt = service.contribute(actor, slug=args.slug, text=args.text)
    return _write_result(snapshot, receipt)


def _parser():
    parser = argparse.ArgumentParser(prog="egregore-quest")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list")
    listing.add_argument("--all", action="store_true")
    listing.set_defaults(handler=_list)
    show = commands.add_parser("show")
    show.add_argument("slug")
    show.set_defaults(handler=_show)
    create = commands.add_parser("new")
    create.add_argument("--title", required=True)
    create.add_argument("--question", required=True)
    create.add_argument("--slug")
    create.add_argument("--project", action="append", default=[])
    create.add_argument("--thread", action="append", default=[])
    create.set_defaults(handler=_create)
    prioritize = commands.add_parser("prioritize")
    prioritize.add_argument("slug")
    prioritize.add_argument("priority")
    prioritize.set_defaults(handler=_prioritize)
    contribute = commands.add_parser("contribute")
    contribute.add_argument("slug")
    contribute.add_argument("text")
    contribute.set_defaults(handler=_contribute)
    pause = commands.add_parser("pause")
    pause.add_argument("slug")
    pause.set_defaults(handler=_transition)
    complete = commands.add_parser("complete")
    complete.add_argument("slug")
    complete.add_argument("--outcome", required=True)
    complete.set_defaults(handler=_transition)
    return parser


def main():
    args = _parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, PermissionError, ValueError) as exc:
        print(f"quest: {exc}", file=os.sys.stderr)
        raise SystemExit(1) from exc
