"""Detached preparation worker for the transactional Runtime upgrade.

Runs the staged engine for one instance with stdio fully detached, so the
launching surface (Settings, CLI) returns immediately and reconnects later
through the durable state file. Progress survives the terminal session; an
interrupted run resumes completed stages instead of restarting them.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-runtime-upgrade-worker")
    parser.add_argument("--repository-root", type=Path, required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    root = args.repository_root.resolve()

    from .adapters.qmd import QmdLocalRetriever
    from .runtime import local_runtime
    from .upgrade import UpgradeEngine, UpgradeStore, upgrade_root

    store = UpgradeStore(root=upgrade_root(root))
    engine = UpgradeEngine(
        repository_root=root,
        store=store,
        runtime=local_runtime(root, push_remote=False),
        retriever=QmdLocalRetriever(repository_root=root),
    )
    try:
        state = engine.prepare()
    except Exception as exc:  # a detached process records, never raises
        current = store.load()
        if current is not None:
            current["status"] = "failed"
            current["failure"] = {
                "stage": "worker",
                "message": f"{type(exc).__name__}: {exc}"[:300],
            }
            store.write(current)
        return 1
    return 0 if state.get("status") in ("ready-to-activate", "active") else 1


if __name__ == "__main__":
    raise SystemExit(main())
