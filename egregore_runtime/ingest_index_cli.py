"""Compatibility bridge from ``bin/ingest.sh`` to the Local Retriever.

All QMD-specific behavior remains in ``adapters.qmd``.  This module only
selects the ingest corpus/collection and translates domain results into the
legacy JSON shape consumed by the ingest boundary filter.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from pathlib import Path, PurePosixPath

from egregore_runtime.adapters.qmd import QmdAdapterError, QmdLocalRetriever
from egregore_runtime.contracts import RetrievalMode, RetrievalRequest
from egregore_runtime.identity import LocalIdentityResolver
from egregore_runtime.observe import DefaultOrgContextCompiler
from egregore_runtime.policy import all_access_dogfood_policy
from egregore_runtime.telemetry import LocalTelemetrySink


def _root() -> Path:
    configured = os.environ.get("EGREGORE_ROOT")
    return Path(configured).resolve() if configured else Path.cwd().resolve()


def _config(root: Path) -> dict[str, object]:
    try:
        return json.loads((root / "egregore.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _ingest_root(root: Path) -> Path:
    configured = os.environ.get("EGREGORE_INGEST_ROOT")
    return Path(configured).resolve() if configured else (root / ".egregore" / "ingest").resolve()


def _retriever(root: Path) -> QmdLocalRetriever:
    return QmdLocalRetriever(
        repository_root=root,
        memory_root=_ingest_root(root),
        collection_purpose="ingest",
    )


def _update(args: argparse.Namespace) -> int:
    retriever = _retriever(_root())
    health = retriever.update()
    if health.available and args.background_embed:
        health = retriever.embed_background()
    print(json.dumps(health.to_dict(), ensure_ascii=False))
    if not health.available:
        print("; ".join(health.warnings) or "Local retrieval is unavailable.", file=sys.stderr)
    return 0 if health.available else 1


def _query(args: argparse.Namespace) -> int:
    root = _root()
    retriever = _retriever(root)
    actor = LocalIdentityResolver(root).resolve(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid.uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    request = RetrievalRequest(
        request_id=f"ingest-search-{uuid.uuid4()}",
        org_id=actor.profile.org_id,
        actor_id=actor.actor.actor_id,
        task=args.query,
        lex=(args.query,),
        vec=(args.query,),
        top_k=args.limit,
        mode=RetrievalMode.HYBRID,
        open_sources=False,
    )
    policy = all_access_dogfood_policy(
        org_id=actor.profile.org_id,
        actor_id=actor.actor.actor_id,
    )
    compiler = DefaultOrgContextCompiler(
        authorizer=policy,
        retriever=retriever,
        telemetry=LocalTelemetrySink(
            state_file=root / ".egregore-state.json",
            instance_root=(root / "memory").resolve(),
        ),
    )
    context = compiler.observe(
        actor,
        request,
        token_budget=actor.profile.default_context_budget,
    )
    collection = retriever.collection
    rows = []
    for evidence in context.evidence:
        relative = evidence.canonical_path.removeprefix("memory/")
        rows.append(
            {
                "file": f"qmd://{collection}/{relative}",
                "title": PurePosixPath(relative).stem,
                "snippet": evidence.content,
                "score": 0.0,
                "artifact_id": evidence.artifact_id,
                "rank": len(rows) + 1,
                "retrieval_types": [RetrievalMode.HYBRID.value],
                "index_spec_version": context.freshness["index_spec_version"],
            }
        )
    print(json.dumps(rows, ensure_ascii=False))
    return 0


def _status(_: argparse.Namespace) -> int:
    health = _retriever(_root()).health()
    print(json.dumps(health.to_dict(), ensure_ascii=False))
    return 0 if health.available else 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-runtime-ingest-index")
    commands = parser.add_subparsers(dest="command", required=True)
    update = commands.add_parser("update")
    update.add_argument("--background-embed", action="store_true")
    update.set_defaults(handler=_update)
    query = commands.add_parser("query")
    query.add_argument("--query", required=True)
    query.add_argument("--limit", type=int, default=200)
    query.set_defaults(handler=_query)
    status = commands.add_parser("status")
    status.set_defaults(handler=_status)
    return parser


def main() -> int:
    args = _parser().parse_args()
    if getattr(args, "limit", 1) < 1:
        raise QmdAdapterError("retrieval limit must be positive")
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except QmdAdapterError as exc:
        print(f"ingest index: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
