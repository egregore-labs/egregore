"""Runtime-neutral CLI for canonical personal todos."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from uuid import uuid4

from .contracts import Permission
from .policy import scope_allows_path
from .runtime import local_runtime
from .todos import CanonicalTodoService


def _context():
    root = Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()
    runtime = local_runtime(root, push_remote=os.environ.get("EGREGORE_NO_PUSH") != "1")
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    person = actor.actor.display_name.casefold().replace(" ", "-")
    service = CanonicalTodoService(
        memory_root=(root / "memory").resolve(),
        write_document=runtime.write_document,
    )
    return runtime, actor, service, person


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
        raise PermissionError("; ".join(decision.reasons) or f"todo {permission.value} denied")
    if canonical_path and not scope_allows_path(canonical_path, decision.scopes):
        raise PermissionError("todo path is outside the actor's authorized scope")
    return decision


def _list(args):
    runtime, actor, service, default_person = _context()
    person = args.person or default_person
    _require(
        runtime,
        actor,
        Permission.READ,
        f"todos:{person}",
        canonical_path=service.canonical_path(person),
    )
    snapshot = service.read(person)
    rows = list(snapshot.todos)
    if not args.all:
        rows = [row for row in rows if row.get("status") in {"open", "blocked", "deferred"}]
    rows.sort(
        key=lambda row: (int(row.get("priority") or 0), str(row.get("created") or "")),
        reverse=True,
    )
    print(json.dumps({"person": snapshot.person, "todos": rows}, ensure_ascii=False))
    return 0


def _add(args):
    runtime, actor, service, default_person = _context()
    person = args.person or default_person
    _require(
        runtime,
        actor,
        Permission.WRITE,
        f"todos:{person}",
        canonical_path=service.canonical_path(person),
    )
    row, receipt = service.add(
        actor,
        person=person,
        text=args.text,
        priority=args.priority,
        quest=args.quest,
    )
    print(json.dumps({"todo": row, "writeback": receipt.to_dict()}, ensure_ascii=False))
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _transition(args):
    runtime, actor, service, default_person = _context()
    person = args.person or default_person
    _require(
        runtime,
        actor,
        Permission.WRITE,
        f"todos:{person}",
        canonical_path=service.canonical_path(person),
    )
    row, receipt = service.transition(
        actor,
        person=person,
        todo_id=args.id,
        status=args.command,
    )
    print(json.dumps({"todo": row, "writeback": receipt.to_dict()}, ensure_ascii=False))
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _parser():
    parser = argparse.ArgumentParser(prog="egregore-todo")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list")
    listing.add_argument("--person")
    listing.add_argument("--all", action="store_true")
    listing.set_defaults(handler=_list)
    add = commands.add_parser("add")
    add.add_argument("text")
    add.add_argument("--person")
    add.add_argument("--priority", type=int, default=0)
    add.add_argument("--quest")
    add.set_defaults(handler=_add)
    for command in ("done", "cancelled"):
        transition = commands.add_parser(command)
        transition.add_argument("--id", required=True)
        transition.add_argument("--person")
        transition.set_defaults(handler=_transition)
    return parser


def main():
    args = _parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, PermissionError, ValueError) as exc:
        print(f"todo: {exc}", file=os.sys.stderr)
        raise SystemExit(1) from exc
