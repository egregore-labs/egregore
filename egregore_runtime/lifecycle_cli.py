"""Thin shell compatibility adapter for canonical Runtime lifecycle operations."""

from __future__ import annotations

import argparse
from dataclasses import replace
import json
import os
from pathlib import Path
import sys

from .lifecycle import (
    AttentionState,
    LifecycleAction,
    LifecycleError,
    LifecyclePlan,
    LifecyclePolicy,
    LifecycleRecord,
    ObligationState,
)
from .identity import actor_presentation_name
from .runtime import local_runtime


def _root() -> Path:
    return Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()


def _session_id(root: Path) -> str:
    configured = os.environ.get("EGREGORE_SESSION_ID", "").strip()
    if configured:
        return configured
    try:
        return (root / ".egregore-session-id").read_text(encoding="utf-8").strip() or "lifecycle-shell"
    except OSError:
        return "lifecycle-shell"


def _runtime(args: argparse.Namespace):
    root = _root()
    runtime = local_runtime(
        root,
        push_remote=os.environ.get("EGREGORE_LIFECYCLE_PUSH", "1") != "0",
    )
    if args.days is not None and runtime.lifecycle is not None:
        runtime.lifecycle.policy = replace(
            runtime.lifecycle.policy,
            handoff_ttl_days=args.days,
            fyi_expiry_days=args.days,
        )
    actor = runtime.resolve_actor(session_id=_session_id(root), harness="lifecycle-shell")
    return runtime, actor


def _activity_status(record: LifecycleRecord) -> str:
    if record.obligation_state is ObligationState.COMPLETED:
        return "done"
    if record.obligation_state is ObligationState.CLAIMED:
        return "claimed"
    if record.obligation_state is ObligationState.READ:
        return "read"
    if record.obligation_state is ObligationState.REVIEW_REQUIRED:
        return "review_due"
    if record.attention_state is AttentionState.EXPIRED and record.intent == "fyi":
        return "expired"
    return "pending"


def _item(actor, record: LifecycleRecord) -> dict[str, object]:
    recipient = record.recipients[0] if len(record.recipients) == 1 else None
    author = actor_presentation_name(actor, record.created_by, record.created_by_alias)
    return {
        "id": record.artifact_id,
        "sessionId": record.artifact_id,
        "topic": record.title,
        "author": author,
        "from": author,
        "authorActorId": record.created_by,
        "recipient": actor_presentation_name(actor, recipient) if recipient else None,
        "to": actor_presentation_name(actor, recipient) if recipient else None,
        "date": record.created_at.date().isoformat(),
        "filePath": record.canonical_path.removeprefix("memory/"),
        "status": _activity_status(record),
        "intent": record.intent or "unclassified",
        "ageDays": record.age_days,
        "authority": record.authority_state.value,
        "attention": record.attention_state.value,
        "obligation": record.obligation_state.value,
        "lifecycleRevision": record.lifecycle_revision,
        "lifecycleReason": record.terminal_reason,
        "recommendation": record.recommendation,
        "automaticTransitionSafe": record.automatic_transition_safe,
        "supersededBy": list(record.superseded_by),
    }


def _plan_json(actor, plan: LifecyclePlan, *, managed_only: bool = False) -> dict[str, object]:
    records = [record for record in plan.records if record.artifact_type == "handoff"]
    if managed_only:
        records = [record for record in records if record.intent in {"action", "feedback", "fyi"}]
    items = [_item(actor, record) for record in records]
    safe = [item for item in items if item["automaticTransitionSafe"]]
    review = [item for item in items if item["recommendation"] == "review"]
    return {
        "schema": plan.schema_version,
        "index_spec_version": plan.index_spec_version,
        "snapshot_id": plan.snapshot_id,
        "source_revision": plan.source_revision,
        "generated_at": plan.generated_at.isoformat(),
        "authority": "canonical_markdown",
        "graph_dependency": False,
        "managed_only": managed_only,
        "counts": {
            "handoffs": len(items),
            "safe_candidates": len(safe),
            "review_candidates": len(review),
        },
        "safe_candidates": safe,
        "review_candidates": review,
        "handoffs_to_me": items,
        "items": items,
        "warnings": list(plan.warnings),
        "apply_contract": {
            "requires_snapshot": True,
            "confirmation": "APPLY_SAFE_HANDOFF_LIFECYCLE",
            "age_alone_never_marks_done": True,
            "attention_expiry_never_completes_obligation": True,
        },
    }


def _scan(args: argparse.Namespace) -> int:
    runtime, actor = _runtime(args)
    plan = runtime.lifecycle_plan(actor, artifact_types=("handoff",), user=args.user)
    print(json.dumps(_plan_json(actor, plan, managed_only=args.managed_only), separators=(",", ":")))
    return 0


def _action(args: argparse.Namespace) -> int:
    runtime, actor = _runtime(args)
    action = {
        "read": LifecycleAction.ACKNOWLEDGE,
        "acknowledge": LifecycleAction.ACKNOWLEDGE,
        "claim": LifecycleAction.CLAIM,
        "done": LifecycleAction.COMPLETE,
        "complete": LifecycleAction.COMPLETE,
        "expire": LifecycleAction.EXPIRE_ATTENTION,
        "expire_attention": LifecycleAction.EXPIRE_ATTENTION,
        "reopen": LifecycleAction.REOPEN,
        "review": LifecycleAction.REQUEST_REVIEW,
        "request_review": LifecycleAction.REQUEST_REVIEW,
    }[args.action]
    receipt = runtime.transition_lifecycle(
        actor,
        target_artifact_id=args.target,
        action=action,
        reason=args.reason,
        evidence_ids=tuple(args.evidence),
        automatic=args.automatic,
        expected_lifecycle_revision=args.expected_revision,
        user=args.user,
    )
    resulting_status = {
        LifecycleAction.ACKNOWLEDGE: "read",
        LifecycleAction.CLAIM: "claimed",
        LifecycleAction.COMPLETE: "done",
        LifecycleAction.EXPIRE_ATTENTION: "expired",
        LifecycleAction.REOPEN: "pending",
        LifecycleAction.REQUEST_REVIEW: "review_due",
    }[action]
    print(
        json.dumps(
            {
                "applied": receipt.status.value != "rejected",
                "action": action.value,
                "id": args.target,
                "event_id": receipt.artifact.artifact_id,
                "status": resulting_status,
                "writeback_status": receipt.status.value,
                "git_revision": receipt.git_revision,
                "warnings": list(receipt.warnings),
            },
            separators=(",", ":"),
        )
    )
    return 0 if receipt.status.value != "rejected" else 3


def _apply(args: argparse.Namespace) -> int:
    runtime, actor = _runtime(args)
    plan = runtime.lifecycle_plan(actor, artifact_types=("handoff",), user=args.user)
    if args.snapshot != plan.snapshot_id:
        raise LifecycleError("snapshot changed; scan again before applying")
    if args.confirm != "APPLY_SAFE_HANDOFF_LIFECYCLE":
        raise LifecycleError("explicit lifecycle confirmation is required")
    receipts = []
    for record in plan.records:
        if not record.automatic_transition_safe:
            continue
        receipt = runtime.transition_lifecycle(
            actor,
            target_artifact_id=record.artifact_id,
            action=LifecycleAction.EXPIRE_ATTENTION,
            reason="typed_attention_ttl_elapsed",
            automatic=True,
            expected_lifecycle_revision=record.lifecycle_revision,
            user=args.user,
        )
        receipts.append(receipt)
    print(
        json.dumps(
            {
                **_plan_json(actor, plan, managed_only=args.managed_only),
                "applied": True,
                "transitions": {
                    "attention_expired": len(receipts),
                    "completed": 0,
                },
            },
            separators=(",", ":"),
        )
    )
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-lifecycle")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("scan", "apply"):
        command = commands.add_parser(name)
        command.add_argument("--days", type=int)
        command.add_argument("--user")
        command.add_argument("--managed-only", action="store_true")
        if name == "apply":
            command.add_argument("--snapshot", required=True)
            command.add_argument("--confirm", required=True)
        command.set_defaults(handler=_scan if name == "scan" else _apply)
    action = commands.add_parser("action")
    action.add_argument(
        "action",
        choices=(
            "read", "acknowledge", "claim", "done", "complete", "expire",
            "expire_attention", "reopen", "review", "request_review",
        ),
    )
    action.add_argument("target")
    action.add_argument("--reason", default="explicit_user_action")
    action.add_argument("--evidence", action="append", default=[])
    action.add_argument("--automatic", action="store_true")
    action.add_argument("--expected-revision")
    action.add_argument("--user")
    action.add_argument("--days", type=int)
    action.set_defaults(handler=_action)
    return parser


def main() -> int:
    args = _parser().parse_args()
    if args.days is not None and not 1 <= args.days <= 365:
        raise LifecycleError("days must be between 1 and 365")
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (LifecycleError, RuntimeError, ValueError) as exc:
        print(f"egregore lifecycle: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
