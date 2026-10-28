"""Runtime-neutral shell adapter for knowledge capture and private notes."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
from uuid import uuid4

from .contracts import ArtifactRelationship
from .errors import AuthorizationDenied
from .knowledge import (
    CanonicalKnowledgeService,
    KnowledgeCaptureError,
    PersonalNoteService,
)
from .runtime import local_runtime, runtime_root
from .scratch import read_and_consume


def _root() -> Path:
    return runtime_root()


def _context(*, push_remote: bool):
    root = _root()
    runtime = local_runtime(root, push_remote=push_remote)
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    knowledge = CanonicalKnowledgeService(runtime, (root / "memory").resolve())
    notes = PersonalNoteService(runtime, root / ".egregore" / "notes", knowledge)
    return actor, knowledge, notes


def _input(path: str) -> str:
    return read_and_consume(path, _root()).decode("utf-8")


def _relationships(values: list[str]) -> tuple[ArtifactRelationship, ...]:
    rows = []
    for value in values:
        relation, separator, target = value.partition(":")
        if not separator or not relation.strip() or not target.strip():
            raise KnowledgeCaptureError("relationship must use RELATION:TARGET")
        rows.append(ArtifactRelationship(relation.strip(), target.strip()))
    return tuple(rows)


def _receipt(receipt) -> dict[str, object]:
    return {
        "artifact_id": receipt.artifact.artifact_id,
        "canonical_path": f"memory/{receipt.artifact.canonical_path}",
        "artifact_type": receipt.artifact.artifact_type,
        "created_by": receipt.artifact.created_by,
        "writeback_status": receipt.status.value,
        "git_revision": receipt.git_revision,
        "index_revision": receipt.index_revision,
        "embedding_state": receipt.embedding_state,
        "warnings": list(receipt.warnings),
    }


def _create(args: argparse.Namespace) -> int:
    actor, knowledge, _ = _context(push_remote=not args.no_push)
    receipt = knowledge.create(
        actor,
        artifact_type=args.type,
        title=args.title,
        body=_input(args.input),
        topics=args.topic,
        workstream=args.workstream,
        subtype=args.subtype,
        relationships=_relationships(args.relationship),
        supersedes=args.supersedes,
    )
    print(json.dumps(_receipt(receipt), ensure_ascii=False))
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _note_create(args: argparse.Namespace) -> int:
    actor, _, notes = _context(push_remote=False)
    note = notes.create(
        actor,
        title=args.title,
        body=_input(args.input),
        note_type=args.type,
    )
    print(json.dumps(note.to_dict(), ensure_ascii=False))
    return 0


def _note_list(args: argparse.Namespace) -> int:
    actor, _, notes = _context(push_remote=False)
    rows = notes.list(actor)
    print(json.dumps({"notes": [row.to_dict() for row in rows]}, ensure_ascii=False))
    return 0


def _note_open(args: argparse.Namespace) -> int:
    actor, _, notes = _context(push_remote=False)
    note = notes.open(actor, args.path)
    print(note.body, end="")
    return 0


def _note_promote(args: argparse.Namespace) -> int:
    actor, _, notes = _context(push_remote=not args.no_push)
    receipt = notes.promote(
        actor,
        raw_path=args.path,
        artifact_type=args.type,
        title=args.title,
        topics=args.topic,
        workstream=args.workstream,
    )
    print(json.dumps(_receipt(receipt), ensure_ascii=False))
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-knowledge")
    commands = parser.add_subparsers(dest="command", required=True)

    create = commands.add_parser("create")
    create.add_argument("--type", choices=("decision", "finding", "pattern"), required=True)
    create.add_argument("--title", required=True)
    create.add_argument("--input", required=True)
    create.add_argument("--topic", action="append", default=[])
    create.add_argument("--workstream")
    create.add_argument("--subtype")
    create.add_argument("--relationship", action="append", default=[])
    create.add_argument("--supersedes", action="append", default=[])
    create.add_argument("--no-push", action="store_true")
    create.set_defaults(handler=_create)

    note_create = commands.add_parser("note-create")
    note_create.add_argument("--title", required=True)
    note_create.add_argument("--type", choices=("thought", "session", "retrospective", "journal"), default="thought")
    note_create.add_argument("--input", required=True)
    note_create.set_defaults(handler=_note_create)

    note_list = commands.add_parser("note-list")
    note_list.set_defaults(handler=_note_list)

    note_open = commands.add_parser("note-open")
    note_open.add_argument("path")
    note_open.set_defaults(handler=_note_open)

    note_promote = commands.add_parser("note-promote")
    note_promote.add_argument("--path", required=True)
    note_promote.add_argument("--type", choices=("decision", "finding", "pattern"), required=True)
    note_promote.add_argument("--title")
    note_promote.add_argument("--topic", action="append", default=[])
    note_promote.add_argument("--workstream")
    note_promote.add_argument("--no-push", action="store_true")
    note_promote.set_defaults(handler=_note_promote)
    return parser


def main() -> int:
    args = _parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuthorizationDenied, KnowledgeCaptureError, OSError, ValueError) as exc:
        print(f"knowledge: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
