"""Runtime-neutral command adapter for the resumable onboarding ritual."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
from uuid import uuid4

from .errors import AuthorizationDenied
from .onboarding import OnboardingService
from .runtime import local_runtime
from .sync import LocalGitSyncTransport


def _context():
    root = Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()
    runtime = local_runtime(root, push_remote=False)
    marker = root / ".egregore-session-id"
    session_id = os.environ.get("EGREGORE_SESSION_ID", "").strip()
    if not session_id and marker.is_file():
        session_id = marker.read_text(encoding="utf-8").splitlines()[0].strip()
    actor = runtime.resolve_actor(
        session_id=session_id or f"onboarding_{uuid4().hex}",
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    return root, actor, OnboardingService(root, runtime)


def _identity(root: Path, command: str, *arguments: str) -> bool:
    result = subprocess.run(
        ("bash", str(root / "bin" / "person.sh"), command, *arguments),
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
        timeout=45,
    )
    return result.returncode == 0


def _shell_alias(root: Path) -> str | None:
    result = subprocess.run(
        ("bash", str(root / "bin" / "ensure-shell-function.sh")),
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
        timeout=15,
    )
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip().splitlines()[-1]
    return None


def main() -> int:
    parser = argparse.ArgumentParser(prog="egregore-onboarding")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    name = commands.add_parser("set-name")
    name.add_argument("value")
    role = commands.add_parser("set-role")
    role.add_argument("value")
    invite = commands.add_parser("record-invite")
    invite.add_argument("choice", choices=("invited", "skipped"))
    commands.add_parser("complete")
    args = parser.parse_args()
    root, actor, service = _context()

    if args.command == "status":
        snapshot = service.snapshot(actor)
        result = snapshot.to_dict()
    elif args.command == "set-name":
        snapshot = service.set_name(actor, args.value)
        result = snapshot.to_dict() | {"identity_reconciled": _identity(root, "sync")}
    elif args.command == "set-role":
        snapshot = service.set_role(actor, args.value)
        result = snapshot.to_dict() | {"identity_reconciled": _identity(root, "sync")}
    elif args.command == "record-invite":
        snapshot = service.record_invite(actor, skipped=args.choice == "skipped")
        result = snapshot.to_dict()
    else:
        if not _identity(root, "onboard"):
            raise OSError("canonical person profile could not be reconciled")
        current = service.snapshot(actor)
        state = json.loads((root / ".egregore-state.json").read_text(encoding="utf-8"))
        username = str(state.get("github_username") or "").strip()
        profile = root / "memory" / "people" / f"{username}.md"
        if not current.profile_witness or not profile.is_file():
            raise ValueError("canonical person profile witness is missing")
        sync = LocalGitSyncTransport((root / "memory").resolve(), push_remote=True).push(
            message=f"docs(people): onboard {username}", paths=(str(profile),)
        )
        snapshot = service.complete(actor, profile_witness=current.profile_witness)
        result = snapshot.to_dict() | {
            "sync_warnings": list(sync.warnings),
            "launcher_alias": _shell_alias(root),
        }
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuthorizationDenied, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"onboarding: {exc}", file=os.sys.stderr)
        raise SystemExit(1) from exc
