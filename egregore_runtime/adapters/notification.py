"""Compatibility transport adapter for the existing notification shell."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
from typing import Mapping, Sequence

from ..notifications import NotificationError


class ShellNotificationTransport:
    def __init__(self, root: Path, *, environment: Mapping[str, str] | None = None) -> None:
        self.root = root.resolve()
        self.environment = dict(environment or os.environ)

    def _run(self, arguments: Sequence[str]) -> Mapping[str, object]:
        command = ["bash", str(self.root / "bin" / "notify.sh"), *arguments]
        environment = dict(self.environment)
        environment["EGREGORE_NOTIFY_PROJECT_DIR"] = str(self.root)
        completed = subprocess.run(
            command,
            cwd=self.root,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        if completed.returncode != 0:
            reason = completed.stderr.strip() or completed.stdout.strip() or "notification transport failed"
            raise NotificationError(reason)
        try:
            payload = json.loads(completed.stdout)
        except ValueError as exc:
            raise NotificationError("notification transport returned invalid JSON") from exc
        if not isinstance(payload, dict):
            raise NotificationError("notification transport returned an invalid receipt")
        return payload

    def status(self) -> Mapping[str, object]:
        return self._run(("test",))

    def plan(self, *, kind: str, recipient: str | None, message: str) -> Mapping[str, object]:
        arguments = ["plan", kind]
        if kind == "send":
            arguments.append(recipient or "")
        arguments.append(message)
        return self._run(arguments)

    def approve(self, *, plan_id: str, digest: str, confirmation: str) -> Mapping[str, object]:
        return self._run(("approve", plan_id, digest, confirmation))

    def dispatch(self, *, plan_id: str, approval_token: str) -> Mapping[str, object]:
        return self._run(("dispatch", plan_id, approval_token))

    def cancel(self, *, plan_id: str) -> Mapping[str, object]:
        return self._run(("cancel", plan_id))
