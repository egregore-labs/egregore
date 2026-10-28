"""Shell adapter for the canonical asynchronous-question lifecycle."""

from __future__ import annotations

import argparse
from dataclasses import replace
import json
import os
from pathlib import Path
import sys
from uuid import uuid4

from .contracts import RetrievalHit, RetrieverHealth
from .errors import AuthorizationDenied
from .questions import CanonicalQuestionService, QuestionLifecycleError
from .runtime import EgregoreRuntime, local_runtime


def _root() -> Path:
    return Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()


class _CanonicalOnlyRetriever:
    """Test/portable-fixture adapter where derived retrieval is unavailable."""

    def __init__(self, memory_root: Path) -> None:
        self.memory_root = memory_root.resolve()

    def health(self) -> RetrieverHealth:
        return RetrieverHealth(
            available=False,
            adapter="canonical-only",
            adapter_version="1",
            index_spec_version="none",
            index_revision="none",
            source_revision="canonical",
            embedding_state="unavailable",
            warnings=("derived retrieval disabled for isolated canonical fixture",),
            canonical_state_ready=True,
            runtime_state="runtime_unavailable",
        )

    def retrieve(self, request):  # pragma: no cover - questions never retrieve
        raise RuntimeError("derived retrieval is unavailable")

    def open_source(self, hit: RetrievalHit) -> str:
        relative = hit.canonical_path.removeprefix("memory/")
        target = (self.memory_root / relative).resolve()
        if self.memory_root not in target.parents:
            raise ValueError("canonical source escapes memory root")
        return target.read_text(encoding="utf-8")

    def update(self, paths=()) -> RetrieverHealth:
        return self.health()

    def embed_background(self) -> RetrieverHealth:
        return self.health()


def _runtime(*, push_remote: bool) -> tuple[EgregoreRuntime, Path]:
    root = _root()
    memory_root = (root / "memory").resolve()
    override = os.environ.get("EGREGORE_MEMORY_DIR")
    if override and Path(override).resolve() != memory_root:
        raise ValueError("question memory root must belong to the active Egregore instance")
    canonical_only = os.environ.get("EGREGORE_CANONICAL_ONLY") == "1"
    runtime = local_runtime(root, push_remote=push_remote)
    if canonical_only:
        # Portable fixtures may disable the derived index, but they retain the
        # active instance's identity, policy, store, sync, and lifecycle.
        runtime = replace(runtime, retriever=_CanonicalOnlyRetriever(memory_root))
    return runtime, memory_root


def _actor(runtime: EgregoreRuntime):
    return runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )


def _receipt(receipt, canonical_path: str) -> dict[str, object]:
    return {
        "artifact_id": receipt.artifact.artifact_id,
        "canonical_path": f"memory/{canonical_path.removeprefix('memory/')}",
        "writeback_status": receipt.status.value,
        "warnings": list(receipt.warnings),
    }


def _create(args: argparse.Namespace) -> int:
    runtime, memory = _runtime(push_remote=not args.no_push)
    receipt = CanonicalQuestionService(runtime, memory).create(
        _actor(runtime),
        sender_alias=args.sender,
        recipient_alias=args.recipient,
        recipient_actor_id=args.recipient_actor_id,
        topic=args.topic,
        question=args.question,
        harvest_id=args.harvest_id,
        harvest_session_id=args.harvest_session_id,
        turn=args.turn,
        question_intent=args.question_intent,
        context_mode=args.context_mode,
    )
    print(json.dumps(_receipt(receipt, receipt.artifact.canonical_path), ensure_ascii=False))
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _pending(args: argparse.Namespace) -> int:
    runtime, memory = _runtime(push_remote=False)
    rows = CanonicalQuestionService(runtime, memory).pending(_actor(runtime), limit=args.limit)
    print(json.dumps({"questions": [row.to_dict() for row in rows]}, ensure_ascii=False))
    return 0


def _open(args: argparse.Namespace) -> int:
    runtime, memory = _runtime(push_remote=False)
    print(CanonicalQuestionService(runtime, memory).open(_actor(runtime), args.path), end="")
    return 0


def _answer(args: argparse.Namespace) -> int:
    runtime, memory = _runtime(push_remote=not args.no_push)
    receipt = CanonicalQuestionService(runtime, memory).answer(
        _actor(runtime),
        canonical_path=args.path,
        answer=args.body,
        responder_alias=args.responder,
    )
    print(json.dumps(_receipt(receipt, receipt.artifact.canonical_path), ensure_ascii=False))
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-question")
    commands = parser.add_subparsers(dest="command", required=True)

    create = commands.add_parser("create")
    create.add_argument("--from", dest="sender", required=True)
    create.add_argument("--to", dest="recipient", required=True)
    create.add_argument("--to-actor-id", dest="recipient_actor_id")
    create.add_argument("--topic", required=True)
    create.add_argument("--question", required=True)
    create.add_argument("--harvest-id")
    create.add_argument("--harvest-session-id")
    create.add_argument("--turn", type=int)
    create.add_argument("--question-intent")
    create.add_argument("--context-mode", choices=("blind", "disclosed", "comparative"))
    create.add_argument("--no-push", action="store_true")
    create.set_defaults(handler=_create)

    pending = commands.add_parser("pending")
    pending.add_argument("--limit", type=int, default=20)
    pending.set_defaults(handler=_pending)

    opened = commands.add_parser("open")
    opened.add_argument("path")
    opened.set_defaults(handler=_open)

    answer = commands.add_parser("answer")
    answer.add_argument("--from", dest="responder", required=True)
    answer.add_argument("--question", dest="path", required=True)
    answer.add_argument("--body", required=True)
    answer.add_argument("--no-push", action="store_true")
    answer.set_defaults(handler=_answer)
    return parser


def main() -> int:
    args = _parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuthorizationDenied, OSError, QuestionLifecycleError, ValueError) as exc:
        print(f"question: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
