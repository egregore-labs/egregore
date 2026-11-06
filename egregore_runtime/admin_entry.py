"""Admin-only entries refuse a non-admin grant before they read anything.

Corpus and data-room builders and hosted-index maintenance read or hand over
memory wholesale, outside the per-path predicate, so they are admin-only
channels: the entry asks the one policy whether this session's read grant is
an admin's and stops otherwise. There is no operator-only class; running in
your own checkout is not a grant. Shell and Node entries run the
``egregore_runtime.admin_entry`` module with the surface name (exit 5 on refusal).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

REFUSED = 5


def refusal(surface: str) -> str:
    return (f"{surface} is for organization admins, and this session's grant is not an admin's; "
            "nothing was read. Admins are the GitHub handles listed under `admins` in egregore.json.")


def admin_session(root: Path | str | None = None, harness: str | None = None) -> bool:
    """True only when the policy names this session's actor an admin; fails closed."""
    from .contracts import Permission
    from .policy import is_admin
    from .runtime import local_runtime, runtime_root

    try:
        runtime = local_runtime(runtime_root(root), push_remote=False)
        actor = runtime.resolve_actor(session_id=os.environ.get("EGREGORE_SESSION_ID") or "admin-entry",
                                      harness=harness or os.environ.get("EGREGORE_RUNTIME") or "shell")
        return is_admin(runtime.authorize(actor, Permission.READ))
    except Exception:
        return False


def require_admin(surface: str, root: Path | str | None = None) -> None:
    if not admin_session(root):
        print(refusal(surface), file=sys.stderr)
        raise SystemExit(REFUSED)


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    surface = args[0] if args else "This command"
    if admin_session():
        return 0
    print(refusal(surface), file=sys.stderr)
    return REFUSED


if __name__ == "__main__":
    raise SystemExit(main())
