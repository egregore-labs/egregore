"""Runtime-neutral CLI for Scroll events, deterministic folds, and SHARE."""

from __future__ import annotations

import argparse
import json
import os
from uuid import uuid4

from .runtime import local_runtime, runtime_root
from .scratch import read_and_consume
from .scrolls import CanonicalScrollService, EXACT_SHARE_CONFIRMATION, ScrollError


def _context():
    root = runtime_root()
    runtime = local_runtime(root, push_remote=os.environ.get("EGREGORE_NO_PUSH") != "1")
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    return actor, CanonicalScrollService(runtime, root)


def _row(snapshot):
    return {
        "id": snapshot.document.artifact.artifact_id,
        "slug": snapshot.slug,
        "title": snapshot.title,
        "creator_id": snapshot.creator_id,
        "trusted_actor_ids": list(snapshot.trusted_actor_ids),
        "respondents": list(snapshot.respondents),
        "version": snapshot.version,
        "storage_key": snapshot.storage_key,
        "source_html": snapshot.source_html,
        "published_url": snapshot.published_url,
        "revision": snapshot.revision,
        "canonical_path": f"memory/scrolls/{snapshot.slug}.md",
    }


def _receipts(rows):
    return [row.to_dict() for row in rows]


def _show(args):
    actor, service = _context()
    print(json.dumps({"scroll": _row(service.read(actor, args.slug))}, ensure_ascii=False))
    return 0


def _create(args):
    actor, service = _context()
    snapshot, receipts = service.create(
        actor,
        title=args.title,
        face_markdown=read_and_consume(args.face, runtime_root()).decode("utf-8"),
        source_html=args.html,
        version_event=json.loads(read_and_consume(args.event_json, runtime_root()).decode("utf-8")),
        slug=args.slug,
        storage_key=args.storage_key,
        respondents=args.respondent,
        trusted_actor_ids=args.trusted_actor_id,
        review_after_days=args.review_after_days,
        attention_ttl_days=args.ttl_days,
        supersedes=args.supersedes,
    )
    print(json.dumps({"scroll": _row(snapshot), "writeback": _receipts(receipts)}, ensure_ascii=False))
    return 0 if all(row.status.value in {"accepted", "partial"} for row in receipts) else 1


def _event(args):
    actor, service = _context()
    receipt = service.append_event(
        actor,
        slug=args.slug,
        event=json.loads(read_and_consume(args.event_json, runtime_root()).decode("utf-8")),
        expected_revision=args.expected_revision,
        face_markdown=read_and_consume(args.face, runtime_root()).decode("utf-8") if args.face else None,
        source_html=args.html,
    )
    print(
        json.dumps(
            {
                "scroll": _row(receipt.scroll),
                "event_id": receipt.event_id,
                "disposition": receipt.disposition,
                "writeback": _receipts(receipt.receipts),
            },
            ensure_ascii=False,
        )
    )
    return 0 if all(row.status.value in {"accepted", "partial"} for row in receipt.receipts) else 1


def _ledger(args):
    actor, service = _context()
    print(json.dumps(service.project_ledger(actor, args.slug), ensure_ascii=False))
    return 0


def _plan_share(args):
    actor, service = _context()
    plan = service.plan_share(
        actor, slug=args.slug, html_path=args.html, description=args.description
    )
    print(json.dumps(plan.to_dict(), ensure_ascii=False))
    return 0


def _share(args):
    actor, service = _context()
    receipt = service.dispatch_share(
        actor,
        plan_id=args.plan_id,
        digest=args.digest,
        confirmation=args.confirm,
    )
    print(
        json.dumps(
            {
                "plan_id": receipt.plan_id,
                "slug": receipt.slug,
                "url": receipt.url,
                "writeback": _receipts(receipt.writeback),
            },
            ensure_ascii=False,
        )
    )
    return 0 if all(row.status.value in {"accepted", "partial"} for row in receipt.writeback) else 1


def _parser():
    parser = argparse.ArgumentParser(prog="egregore-scroll")
    commands = parser.add_subparsers(dest="command", required=True)
    show = commands.add_parser("show")
    show.add_argument("slug")
    show.set_defaults(handler=_show)
    create = commands.add_parser("create")
    create.add_argument("--title", required=True)
    create.add_argument("--slug")
    create.add_argument("--face", required=True)
    create.add_argument("--html", required=True)
    create.add_argument("--event-json", required=True)
    create.add_argument("--storage-key", required=True)
    create.add_argument("--respondent", action="append", default=[])
    create.add_argument("--trusted-actor-id", action="append", default=[])
    create.add_argument("--review-after-days", type=int, default=7)
    create.add_argument("--ttl-days", type=int, default=30)
    create.add_argument("--supersedes", action="append", default=[])
    create.set_defaults(handler=_create)
    event = commands.add_parser("event")
    event.add_argument("slug")
    event.add_argument("--event-json", required=True)
    event.add_argument("--expected-revision", required=True)
    event.add_argument("--face")
    event.add_argument("--html")
    event.set_defaults(handler=_event)
    ledger = commands.add_parser("ledger")
    ledger.add_argument("slug")
    ledger.set_defaults(handler=_ledger)
    plan = commands.add_parser("plan-share")
    plan.add_argument("slug")
    plan.add_argument("--html")
    plan.add_argument("--description", default="")
    plan.set_defaults(handler=_plan_share)
    share = commands.add_parser("share")
    share.add_argument("--plan-id", required=True)
    share.add_argument("--digest", required=True)
    share.add_argument("--confirm", choices=(EXACT_SHARE_CONFIRMATION,), required=True)
    share.set_defaults(handler=_share)
    return parser


def main():
    args = _parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, PermissionError, ScrollError, ValueError, json.JSONDecodeError) as exc:
        print(f"scroll: {exc}", file=os.sys.stderr)
        raise SystemExit(1) from exc
