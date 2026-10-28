"""Shell adapter for canonical meeting and interview writeback."""

from __future__ import annotations

import argparse
import json
import os
import sys

from .research_ingest import CanonicalResearchIngestService, ResearchIngestError
from .runtime import local_runtime, runtime_root
from .scratch import read_and_consume


def main() -> int:
    parser = argparse.ArgumentParser(prog="egregore-research-ingest")
    parser.add_argument("kind", choices=("meeting", "interview"))
    parser.add_argument("--input", required=True, help="analysis package JSON")
    parser.add_argument("--no-push", action="store_true")
    args = parser.parse_args()
    root = runtime_root()
    runtime = local_runtime(root, push_remote=not args.no_push)
    session_path = root / ".egregore-session-id"
    session_id = os.environ.get("EGREGORE_SESSION_ID")
    if not session_id and session_path.is_file():
        session_id = session_path.read_text(encoding="utf-8").splitlines()[0].strip()
    actor = runtime.resolve_actor(
        session_id=session_id or "research-ingest-shell",
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    package = json.loads(read_and_consume(args.input, root).decode("utf-8"))
    receipt = CanonicalResearchIngestService(runtime).ingest(
        actor, package, expected_kind=args.kind
    )
    print(json.dumps(receipt.to_dict(), ensure_ascii=False, separators=(",", ":")))
    return 0 if receipt.status in {"accepted", "partial"} and all(
        row["status"] != "rejected" for row in receipt.artifacts
    ) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (json.JSONDecodeError, OSError, PermissionError, ResearchIngestError) as exc:
        print(f"research-ingest: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
