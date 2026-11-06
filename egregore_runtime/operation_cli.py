"""Content-free, fail-open shell bridge for the search/save operation pilot."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

from .operation_observations import OPERATIONS, OperationObserver
from .telemetry import LocalTelemetrySink


def _json(path: Path) -> dict:
    if not path.exists():
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    return value if isinstance(value, dict) else {}


def observer_for_root(root: Path) -> OperationObserver | None:
    root = root.resolve()
    state_path = root / ".egregore-state.json"
    state = _json(state_path)
    config = _json(root / "egregore.json")
    memory = root / "memory"
    instance = memory.resolve() if memory.exists() else root
    sink = LocalTelemetrySink(state_file=state_path, instance_root=instance)
    if sink._disabled_reason() is not None:
        return None
    session = os.environ.get("EGREGORE_SESSION_ID")
    if not session and (root / ".egregore-session-id").exists():
        session = (root / ".egregore-session-id").read_text(encoding="utf-8").strip()
    return OperationObserver(
        sink, instance_id=hashlib.sha256(str(instance).encode()).hexdigest()[:20],
        org_id=os.environ.get("EGREGORE_ORG_ID") or config.get("org_id") or "unknown",
        actor_id=os.environ.get("EGREGORE_ACTOR_ID") or state.get("actor_id") or "unknown",
        session_id=session or "unknown",
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("start", "finish", "coverage"))
    parser.add_argument("--root", type=Path, default=Path(os.environ.get("EGREGORE_ROOT", ".")))
    parser.add_argument("--operation", choices=sorted(OPERATIONS))
    parser.add_argument("--invocation-id")
    parser.add_argument("--exit-status", type=int)
    parser.add_argument("--outcome", choices=("success", "error", "cancelled"))
    args = parser.parse_args()
    try:
        observer = observer_for_root(args.root)
        if observer is None:
            return 0
        if args.command == "start":
            invocation_id = observer.begin(args.operation, args.invocation_id or os.environ.get("EGREGORE_OPERATION_ID"))
            if invocation_id:
                print(invocation_id)
        elif args.command == "finish":
            outcome = args.outcome
            if outcome is None and args.exit_status is not None:
                outcome = "success" if args.exit_status == 0 else "error"
            observer.finish(args.operation, args.invocation_id or "", outcome=outcome,
                            exit_status=args.exit_status)
        else:
            print(json.dumps(observer.coverage(), sort_keys=True))
    except Exception:
        # Broken/corrupt/locked telemetry storage must not become a workflow
        # failure or print a content-bearing exception into command output.
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
