"""Detached embedding worker for an instance-owned QMD Local runtime."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from .qmd import QmdLocalRetriever


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-qmd-embed-worker")
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--memory-root", type=Path, required=True)
    parser.add_argument("--collection", required=True)
    parser.add_argument("--collection-purpose", required=True)
    parser.add_argument("--source-revision", required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    retriever = QmdLocalRetriever(
        repository_root=args.repository_root,
        memory_root=args.memory_root,
        collection=args.collection,
        collection_purpose=args.collection_purpose,
    )
    lock = retriever._embed_lock_path()
    try:
        # args.source_revision documents the scheduling trigger (visible in
        # ps output); each cycle embeds whatever update just indexed and
        # records the covered revision, so convergence needs no target.
        for _ in range(3):
            retriever.update()
            retriever.embed_foreground()
            if retriever._semantic_state_current():
                return 0
            retriever._source_revision_cache = None
        raise RuntimeError("canonical state changed repeatedly during background embedding")
    except Exception as exc:  # detached process records a local diagnostic receipt
        retriever._atomic_json(
            retriever._runtime_root() / "embedding-error.json",
            {"pid": os.getpid(), "error_type": type(exc).__name__, "message": str(exc)[:400]},
        )
        return 1
    finally:
        try:
            state = json.loads(lock.read_text(encoding="utf-8"))
            if int(state.get("pid", -1)) == os.getpid():
                lock.unlink(missing_ok=True)
        except (OSError, ValueError, TypeError):
            pass


if __name__ == "__main__":
    raise SystemExit(main())
