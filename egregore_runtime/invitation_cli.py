"""Runtime-neutral command adapter for organization invitations."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from uuid import uuid4

from .adapters.invitation import ShellInvitationTransport
from .errors import AuthorizationDenied
from .invitations import InvitationService
from .runtime import local_runtime


def _root() -> Path:
    return Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()


def _session_id(root: Path) -> str:
    value = os.environ.get("EGREGORE_SESSION_ID", "").strip()
    marker = root / ".egregore-session-id"
    if not value and marker.is_file():
        value = marker.read_text(encoding="utf-8").splitlines()[0].strip()
    return value or f"invite_{uuid4().hex}"


def main() -> int:
    parser = argparse.ArgumentParser(prog="egregore-invite")
    parser.add_argument("username")
    args = parser.parse_args()
    root = _root()
    runtime = local_runtime(root, push_remote=True)
    actor = runtime.resolve_actor(
        session_id=_session_id(root),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    receipt = InvitationService(
        runtime, ShellInvitationTransport(root, push_remote=True)
    ).invite(actor, provider_username=args.username)
    print(json.dumps(receipt.to_dict(), ensure_ascii=False, sort_keys=True))
    return 0 if receipt.status == "accepted" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuthorizationDenied, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"invite: {exc}", file=os.sys.stderr)
        raise SystemExit(1) from exc
