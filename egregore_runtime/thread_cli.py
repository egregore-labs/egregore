"""Runtime-neutral CLI for canonical Thread intent and fold-ins."""

from __future__ import annotations

import argparse
import json
import os
from uuid import uuid4

from .runtime import local_runtime, runtime_root
from .scratch import read_and_consume
from .threads import CanonicalThreadService, THREAD_CONFIRMATION, ThreadError


def _context():
    root = runtime_root()
    runtime = local_runtime(root, push_remote=os.environ.get("EGREGORE_NO_PUSH") != "1")
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    return runtime, actor, CanonicalThreadService(runtime, (root / "memory").resolve())


def _row(snapshot, *, detail=False):
    row = snapshot.projection_input()
    row.update(
        {
            "id": snapshot.document.artifact.artifact_id,
            "title": snapshot.title,
            "canonical_path": f"memory/threads/{snapshot.slug}.md",
        }
    )
    if detail:
        row["body"] = snapshot.document.body
    return row


def _writeback(receipts):
    return [receipt.to_dict() for receipt in receipts]


def _new(args):
    _, actor, service = _context()
    snapshot, receipt = service.create(
        actor,
        title=args.title,
        target=args.target,
        slug=args.slug,
        topics=args.topic,
        people=args.person,
        next_steps=args.next_step,
        window_days=args.window_days,
        review_after_days=args.review_after_days,
        attention_ttl_days=args.ttl_days,
        supersedes=args.supersedes,
    )
    print(json.dumps({"thread": _row(snapshot), "writeback": receipt.to_dict()}, ensure_ascii=False))
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _show(args):
    _, actor, service = _context()
    print(json.dumps({"thread": _row(service.read(actor, args.slug), detail=True)}, ensure_ascii=False))
    return 0


def _list(args):
    _, actor, service = _context()
    rows = service.list(actor, include_archived=args.all)
    print(json.dumps({"threads": [_row(row) for row in rows]}, ensure_ascii=False))
    return 0


def _fold(args):
    _, actor, service = _context()
    event = json.loads(read_and_consume(args.event_json, runtime_root()).decode("utf-8"))
    receipt = service.fold(
        actor,
        slug=args.slug,
        event_type=str(event["type"]),
        field=str(event["field"]),
        operation=str(event["op"]),
        payload=event.get("payload"),
        source=str(event.get("source") or f"session:{actor.session_id}"),
        expected_revision=args.expected_revision,
        confirmation=args.confirm,
    )
    print(
        json.dumps(
            {
                "thread": _row(receipt.thread),
                "event_id": receipt.event_id,
                "writeback": _writeback(receipt.receipts),
            },
            ensure_ascii=False,
        )
    )
    return 0 if all(row.status.value in {"accepted", "partial"} for row in receipt.receipts) else 1


def _projection_input(args):
    runtime, actor, service = _context()
    rows = service.list(actor) if args.slug is None else (service.read(actor, args.slug),)
    plan = runtime.lifecycle_plan(actor, artifact_types=("thread",))
    lifecycle = plan.by_id
    print(
        json.dumps(
            {
                "schema_version": "egregore-thread-projection-input/v1",
                "source_revision": actor.profile.revision,
                "lifecycle_revision": plan.snapshot_id,
                "threads": [
                    {
                        "intent": row.projection_input(),
                        "lifecycle": lifecycle.get(row.document.artifact.artifact_id).to_dict()
                        if lifecycle.get(row.document.artifact.artifact_id)
                        else None,
                    }
                    for row in rows
                ],
                "projection_rule": "derived fields require as_of, confidence, and nonempty why",
            },
            ensure_ascii=False,
        )
    )
    return 0


def _parser():
    parser = argparse.ArgumentParser(prog="egregore-thread")
    commands = parser.add_subparsers(dest="command", required=True)
    new = commands.add_parser("new")
    new.add_argument("--title", required=True)
    new.add_argument("--target", required=True)
    new.add_argument("--slug")
    new.add_argument("--topic", action="append", default=[])
    new.add_argument("--person", action="append", default=[])
    new.add_argument("--next-step", action="append", default=[])
    new.add_argument("--window-days", type=int, default=45)
    new.add_argument("--review-after-days", type=int, default=7)
    new.add_argument("--ttl-days", type=int, default=30)
    new.add_argument("--supersedes", action="append", default=[])
    new.set_defaults(handler=_new)
    show = commands.add_parser("show")
    show.add_argument("slug")
    show.set_defaults(handler=_show)
    listing = commands.add_parser("list")
    listing.add_argument("--all", action="store_true")
    listing.set_defaults(handler=_list)
    fold = commands.add_parser("fold")
    fold.add_argument("slug")
    fold.add_argument("--event-json", required=True)
    fold.add_argument("--expected-revision", required=True)
    fold.add_argument("--confirm", choices=(THREAD_CONFIRMATION,), required=True)
    fold.set_defaults(handler=_fold)
    projection = commands.add_parser("projection-input")
    projection.add_argument("slug", nargs="?")
    projection.set_defaults(handler=_projection_input)
    return parser


def main():
    args = _parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, PermissionError, ThreadError, ValueError, json.JSONDecodeError) as exc:
        print(f"thread: {exc}", file=os.sys.stderr)
        raise SystemExit(1) from exc
