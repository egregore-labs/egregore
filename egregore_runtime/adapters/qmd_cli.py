"""Internal compatibility bridge from ``bin/search.sh`` to the QMD adapter.

This is intentionally not the public Egregore Runtime CLI.  Harness-facing
commands should use the integrated runtime boundary; this module only keeps the
existing shell search UX working while QMD details stay inside its adapter.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from pathlib import Path

from egregore_runtime.adapters.qmd import QmdAdapterError, QmdLocalRetriever
from egregore_runtime.contracts import EvidenceItem, RetrievalMode, RetrievalRequest
from egregore_runtime.errors import AuthorizationDenied
from egregore_runtime.runtime import local_runtime


def _root() -> Path:
    configured = os.environ.get("EGREGORE_ROOT")
    return Path(configured).resolve() if configured else Path.cwd().resolve()


def _config(root: Path) -> dict[str, object]:
    try:
        return json.loads((root / "egregore.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _retriever(root: Path) -> QmdLocalRetriever:
    return QmdLocalRetriever(
        repository_root=root,
        memory_root=root / "memory",
        collection=os.environ.get("EGREGORE_QMD_COLLECTION") or None,
    )


def _request(args: argparse.Namespace, *, org_id: str, actor_id: str) -> RetrievalRequest:
    lex = tuple(args.lex)
    vec = tuple(args.vec)
    if args.mode is RetrievalMode.LEX and not lex:
        lex = vec
    if args.mode is RetrievalMode.VEC and not vec:
        vec = lex
    return RetrievalRequest(
        request_id=f"search-{uuid.uuid4()}",
        org_id=org_id,
        actor_id=actor_id,
        task=args.task,
        lex=lex,
        vec=vec,
        top_k=args.limit,
        mode=args.mode,
        open_sources=False,
    )


def _render_evidence(evidence: EvidenceItem) -> str:
    parts = [
        "---",
        f"**file:** `{evidence.canonical_path}`",
        f"**artifact:** `{evidence.artifact_id}`",
        f"**reason:** {evidence.reason}",
    ]
    if evidence.content:
        parts.extend(("", evidence.content))
    return "\n".join(parts)


def _actor(runtime):
    return runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid.uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )


def _query(args: argparse.Namespace) -> int:
    root = _root()
    runtime = local_runtime(root, push_remote=False)
    actor = _actor(runtime)
    context = runtime.observe(
        actor,
        _request(args, org_id=actor.profile.org_id, actor_id=actor.actor.actor_id),
        token_budget=actor.profile.default_context_budget,
    )
    if args.json:
        print(json.dumps(context.to_dict(), indent=2))
    elif context.evidence:
        print("\n\n".join(_render_evidence(item) for item in context.evidence))
    else:
        print("No results found.")
    return 0


def _status(args: argparse.Namespace) -> int:
    health = local_runtime(_root(), push_remote=False).retrieval_health()
    if args.json:
        print(json.dumps(health.to_dict(), indent=2))
    else:
        print(f"adapter: {health.adapter} {health.adapter_version}")
        print(f"index spec: {health.index_spec_version}")
        print(f"index revision: {health.index_revision}")
        print(f"source revision: {health.source_revision}")
        print(f"embedding: {health.embedding_state}")
        print(f"readiness: {health.runtime_state}")
        print(f"bm25 ready: {'yes' if health.bm25_ready else 'no'}")
        print(f"semantic ready: {'yes' if health.semantic_ready else 'no'}")
        print(f"semantic build: {health.semantic_source_revision or 'none'}")
        print(f"worker pid: {health.runtime_pid or 'none'}")
        print(f"endpoint: {health.runtime_endpoint or 'none'}")
        print(f"index: {health.index_path or 'unknown'}")
        print(f"collection: {health.collection or 'unknown'}")
        print(f"available: {'yes' if health.available else 'no'}")
        for warning in health.warnings:
            print(f"warning: {warning}")
    return 0 if health.available else 1


def _start(args: argparse.Namespace) -> int:
    health = local_runtime(_root(), push_remote=False).start_retrieval()
    print(json.dumps(health.to_dict(), indent=2) if args.json else health.runtime_state)
    return 0 if health.available and health.bm25_ready else 1


def _stop(args: argparse.Namespace) -> int:
    health = local_runtime(_root(), push_remote=False).shutdown_retrieval()
    print(json.dumps(health.to_dict(), indent=2) if args.json else "stopped")
    return 0


def _update(args: argparse.Namespace) -> int:
    retriever = _retriever(_root())
    # Explicit reindex also repairs missing entries behind a current receipt.
    health = retriever.update(force=True)
    if health.available and args.embed:
        health = retriever.embed_foreground()
    print(json.dumps(health.to_dict(), indent=2) if args.json else health.index_revision)
    if not health.available:
        print("; ".join(health.warnings) or "Local retrieval is unavailable.", file=sys.stderr)
    return 0 if health.available else 1


def _install(args: argparse.Namespace) -> int:
    del args
    print(_retriever(_root()).install_managed())
    return 0


def _open(args: argparse.Namespace) -> int:
    root = _root()
    runtime = local_runtime(root, push_remote=False)
    actor = _actor(runtime)
    sys.stdout.write(runtime.open_source(actor, args.path))
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-runtime-qmd")
    commands = parser.add_subparsers(dest="command", required=True)

    query = commands.add_parser("query")
    query.add_argument("--task", required=True)
    query.add_argument("--lex", action="append", default=[])
    query.add_argument("--vec", action="append", default=[])
    query.add_argument("--mode", type=RetrievalMode, default=RetrievalMode.HYBRID)
    query.add_argument("--limit", type=int, default=6)
    query.add_argument("--json", action="store_true")
    query.set_defaults(handler=_query)

    status = commands.add_parser("status")
    status.add_argument("--json", action="store_true")
    status.set_defaults(handler=_status)

    start = commands.add_parser("start")
    start.add_argument("--json", action="store_true")
    start.set_defaults(handler=_start)

    stop = commands.add_parser("stop")
    stop.add_argument("--json", action="store_true")
    stop.set_defaults(handler=_stop)

    update = commands.add_parser("update")
    update.add_argument("--embed", action="store_true")
    update.add_argument("--json", action="store_true")
    update.set_defaults(handler=_update)

    install = commands.add_parser("install")
    install.set_defaults(handler=_install)

    source = commands.add_parser("open")
    source.add_argument("path")
    source.set_defaults(handler=_open)
    return parser


def main() -> int:
    args = _parser().parse_args()
    if getattr(args, "limit", 1) < 1:
        raise QmdAdapterError("retrieval limit must be positive")
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuthorizationDenied, QmdAdapterError, ValueError) as exc:
        print(f"search: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
