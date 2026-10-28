"""Runtime-neutral command adapter for notification consent and delivery."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from uuid import uuid4

from .adapters.notification import ShellNotificationTransport
from .errors import AuthorizationDenied
from .notifications import NotificationError, NotificationService
from .runtime import local_runtime, runtime_root
from .scratch import read_and_consume


def _root() -> Path:
    return runtime_root()


def _context():
    root = _root()
    runtime = local_runtime(root, push_remote=False)
    session_path = root / ".egregore-session-id"
    session_id = os.environ.get("EGREGORE_SESSION_ID")
    if not session_id and session_path.is_file():
        session_id = session_path.read_text(encoding="utf-8").splitlines()[0].strip()
    actor = runtime.resolve_actor(
        session_id=session_id or f"session_{uuid4().hex}",
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    service = NotificationService(
        runtime,
        ShellNotificationTransport(root),
        root / ".egregore" / "runtime" / "notifications",
    )
    return actor, service


def _plan(args: argparse.Namespace) -> int:
    actor, service = _context()
    message = read_and_consume(args.message_file, _root()).decode("utf-8")
    result = service.plan(
        actor,
        kind=args.kind,
        recipient=args.recipient,
        message=message,
    )
    print(json.dumps(result, ensure_ascii=False))
    return 0


def _status(args: argparse.Namespace) -> int:
    del args
    actor, service = _context()
    print(json.dumps(service.status(actor), ensure_ascii=False))
    return 0


def _approve(args: argparse.Namespace) -> int:
    if args.out is None:
        result = _approval_receipt(args)
        print(json.dumps(result, ensure_ascii=False))
        return 0

    target = Path(args.out)
    temporary: Path | None = None
    try:
        if (
            not args.out
            or target.is_dir()
            or args.out.endswith(os.sep)
            or not target.parent.is_dir()
            or not os.access(target.parent, os.W_OK | os.X_OK)
        ):
            raise ValueError("approval output must be a file in an existing directory")
        # mkstemp requires an existing parent and creates the file privately.
        descriptor, name = tempfile.mkstemp(prefix=".notification-approval.", dir=target.parent)
        temporary = Path(name)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o600)
            result = _approval_receipt(args)
            json.dump(result, output, ensure_ascii=False)
            output.write("\n")
        os.replace(temporary, target)
        print(json.dumps({"status": result["status"], "plan_id": args.plan_id}, ensure_ascii=False))
        return 0
    except BaseException:
        # A failed attempt must not leave an old receipt available for dispatch.
        try:
            target.unlink(missing_ok=True)
        except OSError:
            pass
        raise
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _approval_receipt(args: argparse.Namespace):
    actor, service = _context()
    return service.approve(
        actor,
        plan_id=args.plan_id,
        digest=args.digest,
        confirmation=args.confirmation,
    )


def _dispatch(args: argparse.Namespace) -> int:
    token = args.approval_token
    if args.approval_file is not None:
        try:
            path = Path(args.approval_file)
            mode = path.stat().st_mode
            if not stat.S_ISREG(mode) or not mode & 0o444:
                raise ValueError("unreadable approval file")
            receipt = json.loads(read_and_consume(path, _root()).decode("utf-8"))
            token = receipt.get("approval_token") if isinstance(receipt, dict) else None
            if not isinstance(token, str) or not token:
                raise ValueError("missing approval token")
        except (OSError, ValueError):
            print("notify: approval file unreadable or has no approval_token", file=sys.stderr)
            return 1
    actor, service = _context()
    result = service.dispatch(
        actor,
        plan_id=args.plan_id,
        approval_token=token,
    )
    print(json.dumps(result, ensure_ascii=False))
    return 0


def _cancel(args: argparse.Namespace) -> int:
    actor, service = _context()
    print(json.dumps(service.cancel(actor, plan_id=args.plan_id), ensure_ascii=False))
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-notification")
    commands = parser.add_subparsers(dest="command", required=True)
    status = commands.add_parser("status")
    status.set_defaults(handler=_status)
    plan = commands.add_parser("plan")
    plan.add_argument("--kind", choices=("group", "send"), required=True)
    plan.add_argument("--recipient")
    plan.add_argument("--message-file", required=True)
    plan.set_defaults(handler=_plan)
    approve = commands.add_parser("approve")
    approve.add_argument("plan_id")
    approve.add_argument("digest")
    approve.add_argument("confirmation")
    approve.add_argument("--out")
    approve.set_defaults(handler=_approve)
    dispatch = commands.add_parser("dispatch")
    dispatch.add_argument("plan_id")
    approval = dispatch.add_mutually_exclusive_group(required=True)
    approval.add_argument("approval_token", nargs="?")
    approval.add_argument("--approval-file")
    dispatch.set_defaults(handler=_dispatch)
    cancel = commands.add_parser("cancel")
    cancel.add_argument("plan_id")
    cancel.set_defaults(handler=_cancel)
    return parser


def main() -> int:
    args = _parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuthorizationDenied, NotificationError, OSError, ValueError) as exc:
        print(f"notification: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
