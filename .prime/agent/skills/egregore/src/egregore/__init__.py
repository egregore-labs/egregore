"""Egregore mechanics as kernel functions.

Thin wrappers over the runtime-neutral ``bin/`` scripts of the enclosing
Egregore checkout. No logic lives here: every function resolves the instance
root from the current working directory, shells out to the same script the
other harnesses use, and returns its text output.

Consent boundary: :func:`notify_plan` only creates a proposal. Approving and
dispatching a notification require an explicit human Send / Edit / Cancel
checkpoint in the conversation — this module deliberately provides no
``notify_approve``/``notify_dispatch`` so that step stays visible.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

__all__ = [
    "activity",
    "branch",
    "handoff",
    "instance_root",
    "notify_plan",
    "run",
    "save",
    "search",
]

_DEFAULT_TIMEOUT = 120


def instance_root(start: str | os.PathLike | None = None) -> Path:
    """Walk up from ``start`` (default: cwd) to the directory holding egregore.json."""
    cursor = Path(start or os.getcwd()).resolve()
    for candidate in (cursor, *cursor.parents):
        if (candidate / "egregore.json").is_file():
            return candidate
    raise RuntimeError(
        "not inside an Egregore instance (no egregore.json above %s)" % cursor
    )


def _run_script(args: list[str], timeout: int = _DEFAULT_TIMEOUT) -> str:
    root = instance_root()
    script = root / args[0]
    if not script.is_file():
        raise RuntimeError(f"missing script: {script}")
    try:
        result = subprocess.run(
            ["bash", *args],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=timeout,
            start_new_session=True,
        )
    except subprocess.TimeoutExpired as exc:
        # Own process group (start_new_session) so the timeout kills the real
        # workers, not just the bash wrapper; surface it as the documented
        # RuntimeError instead of an uncaught traceback in the kernel.
        raise RuntimeError(f"{args[0]} timed out after {timeout}s") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip().splitlines()
        raise RuntimeError(
            f"{args[0]} failed (exit {result.returncode}): {detail[-1] if detail else 'no output'}"
        )
    return result.stdout.strip()


def search(query: str, limit: int = 6) -> str:
    """Ranked shared-memory recall (decisions, handoffs, knowledge, meetings)."""
    return _run_script(["bin/search.sh", "query", query, "-n", str(limit)])


def activity(for_user: str | None = None) -> str:
    """Team activity: handoffs, questions, and recent work.

    Returns the runtime-neutral ``bin/agent.sh activity`` text view; pass
    ``for_user`` to scope to a handle.
    """
    args = ["bin/agent.sh", "activity"]
    if for_user:
        args += ["--for", for_user]
    return _run_script(args)


def branch(topic: str) -> str:
    """Create a task branch + worktree for ``topic``; returns branch and path."""
    return _run_script(["bin/agent.sh", "branch", "--topic", topic])


def save(message: str, topic: str, pr_body: str | None = None) -> str:
    """Commit, push, and open/update the PR for the current working branch."""
    args = ["bin/agent.sh", "save", "--message", message, "--topic", topic]
    if pr_body:
        args += ["--pr-body", pr_body]
    return _run_script(args, timeout=300)


def handoff(
    to: str | None,
    topic: str,
    body: str,
    sender: str | None = None,
    notify: bool = False,
) -> str:
    """Create an internal handoff document addressed to ``to``.

    ``notify=False`` (default) skips the notification leg entirely; enabling it
    still routes through the plan/approve/dispatch consent protocol.
    """
    root = instance_root()
    if sender is None:
        try:
            state = json.loads((root / ".egregore-state.json").read_text())
            sender = state.get("github_username") or "unknown"
        except (OSError, ValueError):
            sender = "unknown"
    args = [
        "bin/agent.sh", "handoff",
        "--from", sender,
        "--topic", topic,
        "--body", body,
    ]
    if to:
        args += ["--to", to]
    if not notify:
        args += ["--no-notify"]
    return _run_script(args, timeout=300)


def notify_plan(recipient: str | None, message: str) -> str:
    """Create a notification PLAN (proposal only — nothing is sent).

    ``recipient`` is a person's handle for a DM, or ``None`` for the group
    channel. Show the returned plan (recipient, channel, exact message, plan
    id and one-use approval token) to the user in a Send / Edit / Cancel
    checkpoint. Only after an explicit yes run ``bin/notify.sh approve`` and
    ``dispatch`` yourself — this module intentionally stops at the plan.
    """
    if recipient:
        return _run_script(["bin/notify.sh", "plan", "send", recipient, message])
    return _run_script(["bin/notify.sh", "plan", "group", message])


def run() -> str:
    """Discovery entry point: list the bridge functions and the consent rule."""
    return (
        "egregore kernel bridge — search(query), activity(for_user=None), "
        "branch(topic), save(message, topic), handoff(to, topic, body), "
        "notify_plan(recipient, message). notify_plan is proposal-only: "
        "approval and dispatch require an explicit human checkpoint."
    )
