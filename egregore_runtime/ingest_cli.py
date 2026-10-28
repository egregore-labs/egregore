"""Shell bridge for canonical ingest registration.

Extraction remains connector-specific. This adapter owns the organizational
boundary between normalized intake and disposable retrieval indexing.
"""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import hashlib
import json
import os
from pathlib import Path
import re
from uuid import uuid4

from .contracts import IngestSource, Permission
from .ingest import (
    CanonicalIngestWorkflow,
    IngestReview,
    LocalIngestJournal,
    LocalQuarantine,
)
from .policy import scope_allows_path
from .runtime import local_runtime, runtime_root
from .scratch import read_and_consume


def _root() -> Path:
    return runtime_root()


def _slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    if not result:
        raise ValueError("source id must contain a letter or number")
    return result


def _context(*, push_remote: bool = True):
    root = _root()
    runtime = local_runtime(root, push_remote=push_remote)
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    state_root = Path(
        os.environ.get("EGREGORE_INGEST_WORKFLOW_DIR")
        or root / ".egregore" / "ingest-runtime"
    ).resolve()
    workflow = CanonicalIngestWorkflow(
        org_id=actor.profile.org_id,
        writeback=runtime,
        journal=LocalIngestJournal(state_root),
        quarantine_store=LocalQuarantine(state_root / "quarantine"),
        default_actor_id=actor.actor.actor_id,
    )
    return root, runtime, actor, workflow


def _canonical_directory(source_id: str) -> str:
    return f"memory/ingest/sources/{_slug(source_id)}/documents"


def _require(runtime, actor, permission: Permission, source_id: str):
    resource = f"ingest-source:{_slug(source_id)}"
    decision = runtime.authorize(actor, permission, (resource,))
    if not decision.allowed:
        raise PermissionError(
            "; ".join(decision.reasons) or f"ingest {permission.value} denied"
        )
    if not scope_allows_path(_canonical_directory(source_id), decision.scopes):
        raise PermissionError("ingest path is outside the actor's authorized scope")
    return decision


def _boundaries(values: list[str]) -> dict[str, str]:
    rows: dict[str, str] = {}
    for value in values:
        key, separator, item = value.partition("=")
        if not separator or not key.strip() or not item.strip():
            raise ValueError("boundaries must use key=value")
        rows[key.strip()] = item.strip()
    return rows


def _source(args, actor, payload: bytes) -> IngestSource:
    digest = hashlib.sha256(payload).hexdigest()
    observed = (
        datetime.fromisoformat(args.observed_at.replace("Z", "+00:00"))
        if args.observed_at
        else datetime.now(UTC)
    )
    if observed.tzinfo is None:
        observed = observed.replace(tzinfo=UTC)
    return IngestSource(
        source_type=args.source_type,
        source_id=args.source,
        revision=args.revision or f"sha256:{digest}",
        content_hash=digest,
        observed_at=observed.astimezone(UTC),
        title=args.title,
        source_uri=args.source_uri,
        visibility=tuple(args.visibility),
        metadata={
            "source_path": args.source_path or args.source_uri or args.source,
            "boundaries": _boundaries(args.boundary),
            "imported_by": actor.actor.actor_id,
            **({"workstream": args.workstream} if args.workstream else {}),
        },
    )


def _input_bytes(path: str) -> bytes:
    return read_and_consume(Path(path).expanduser(), _root())


def _receipt(value) -> dict[str, object]:
    row: dict[str, object] = {
        "source": value.source_id,
        "artifact_id": value.artifact_id,
        "phase": value.phase.value,
        "quarantine_path": value.quarantine_path,
        "warnings": list(value.warnings),
    }
    if value.writeback is not None:
        row["writeback"] = value.writeback.to_dict()
        row["canonical_path"] = f"memory/{value.writeback.artifact.canonical_path}"
    return row


def _stage(args: argparse.Namespace) -> int:
    _, runtime, actor, workflow = _context(push_remote=False)
    _require(runtime, actor, Permission.WRITE, args.source)
    payload = _input_bytes(args.input)
    item = workflow.normalize_item(_source(args, actor, payload), payload)
    receipt = workflow.quarantine(item)
    print(json.dumps(_receipt(receipt), ensure_ascii=False))
    return 0


def _review(args: argparse.Namespace) -> int:
    _, runtime, actor, workflow = _context(push_remote=not args.no_push)
    _require(runtime, actor, Permission.READ, args.source)
    _require(runtime, actor, Permission.PROMOTE, args.source)
    item = workflow.load_quarantined(source_id=args.source, artifact_id=args.artifact)
    receipt = workflow.admit(
        actor,
        item,
        IngestReview(args.approve, actor.actor.actor_id, datetime.now(UTC), args.notes),
    )
    print(json.dumps(_receipt(receipt), ensure_ascii=False))
    return 0 if receipt.phase.value in {"admitted", "partial", "rejected"} else 1


def _add(args: argparse.Namespace) -> int:
    _, runtime, actor, workflow = _context(push_remote=not args.no_push)
    # Admission is explicit in this command. Resolve both permissions before
    # opening external bytes so a denied source never enters local staging.
    _require(runtime, actor, Permission.WRITE, args.source)
    _require(runtime, actor, Permission.PROMOTE, args.source)
    payload = _input_bytes(args.input)
    item = workflow.normalize_item(_source(args, actor, payload), payload)
    workflow.quarantine(item)
    receipt = workflow.admit(
        actor,
        item,
        IngestReview(True, actor.actor.actor_id, datetime.now(UTC), args.notes),
    )
    print(json.dumps(_receipt(receipt), ensure_ascii=False))
    return 0 if receipt.phase.value in {"admitted", "partial"} else 1


def _register(args: argparse.Namespace) -> int:
    _, runtime, actor, _ = _context(push_remote=not args.no_push)
    receipt = runtime.register_ingest_manifest(
        actor,
        source_id=args.source,
        manifest_path=Path(args.manifest),
        source_path=Path(args.source_record),
    )
    print(
        json.dumps(
            {
                "status": "registered",
                "source": receipt.source_id,
                "documents": receipt.document_count,
                "manifest_revision": receipt.manifest_revision,
                "git_revision": receipt.sync.local_revision,
                "warnings": list(receipt.sync.warnings),
            },
            ensure_ascii=False,
        )
    )
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-runtime-ingest")
    commands = parser.add_subparsers(dest="command", required=True)
    register = commands.add_parser("register")
    register.add_argument("--source", required=True)
    register.add_argument("--manifest", required=True)
    register.add_argument("--source-record", required=True)
    register.add_argument("--no-push", action="store_true")
    register.set_defaults(handler=_register)

    def add_source_arguments(command):
        command.add_argument("--input", required=True)
        command.add_argument("--source", required=True)
        command.add_argument("--source-type", required=True)
        command.add_argument("--title", required=True)
        command.add_argument("--revision")
        command.add_argument("--observed-at")
        command.add_argument("--source-uri")
        command.add_argument("--source-path")
        command.add_argument("--visibility", action="append", default=[])
        command.add_argument("--boundary", action="append", default=[])
        command.add_argument("--workstream")

    stage = commands.add_parser("stage")
    add_source_arguments(stage)
    stage.set_defaults(handler=_stage)
    review = commands.add_parser("review")
    review.add_argument("--source", required=True)
    review.add_argument("--artifact", required=True)
    outcome = review.add_mutually_exclusive_group(required=True)
    outcome.add_argument("--approve", action="store_true")
    outcome.add_argument("--reject", dest="approve", action="store_false")
    review.add_argument("--notes")
    review.add_argument("--no-push", action="store_true")
    review.set_defaults(handler=_review)
    add = commands.add_parser("add")
    add_source_arguments(add)
    add.add_argument("--notes")
    add.add_argument("--no-push", action="store_true")
    add.set_defaults(handler=_add)
    return parser


def main() -> int:
    args = _parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, PermissionError, ValueError) as exc:
        print(f"ingest: {exc}", file=os.sys.stderr)
        raise SystemExit(1) from exc
