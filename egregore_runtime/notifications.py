"""Actor-bound notification planning and exact-consent dispatch."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import json
import os
from pathlib import Path
from typing import Callable, Mapping, Protocol
from uuid import uuid4

from .contracts import ActorContext, Permission, TelemetryEvent
from .errors import AuthorizationDenied
from .runtime import EgregoreRuntime
from .telemetry import TELEMETRY_SCHEMA_VERSION


EXACT_NOTIFICATION_CONFIRMATION = "APPROVE_EXACT_NOTIFICATION"
NOTIFICATION_BINDING_SCHEMA = "egregore-notification-binding/v1"


class NotificationError(RuntimeError):
    """A notification plan or dispatch failed closed."""


class NotificationTransport(Protocol):
    def status(self) -> Mapping[str, object]: ...

    def plan(self, *, kind: str, recipient: str | None, message: str) -> Mapping[str, object]: ...

    def approve(self, *, plan_id: str, digest: str, confirmation: str) -> Mapping[str, object]: ...

    def dispatch(self, *, plan_id: str, approval_token: str) -> Mapping[str, object]: ...

    def cancel(self, *, plan_id: str) -> Mapping[str, object]: ...


@dataclass(frozen=True, slots=True)
class NotificationBinding:
    plan_id: str
    digest: str
    org_id: str
    actor_id: str
    session_id: str
    kind: str
    recipient: str | None


class NotificationService:
    """Authorize and bind one immutable notification plan to one actor session."""

    def __init__(
        self,
        runtime: EgregoreRuntime,
        transport: NotificationTransport,
        state_root: Path,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.runtime = runtime
        self.transport = transport
        self.state_root = state_root.resolve()
        self.clock = clock or (lambda: datetime.now(UTC))

    def _authorize(
        self,
        actor: ActorContext,
        permission: Permission,
        resource: str,
    ) -> None:
        decision = self.runtime.authorize(actor, permission, (resource,))
        if not decision.allowed:
            raise AuthorizationDenied(
                "; ".join(decision.reasons) or f"notification {permission.value} denied"
            )

    def status(self, actor: ActorContext) -> Mapping[str, object]:
        """Return sanitized transport readiness through the Runtime boundary."""

        self._authorize(actor, Permission.READ, "notification:configuration")
        receipt = self.transport.status()
        return {
            "status": str(receipt.get("status") or "unknown"),
            "configured": bool(receipt.get("configured", False)),
            "channels": tuple(str(value) for value in receipt.get("channels", ()) if value),
        }

    def _binding_path(self, plan_id: str) -> Path:
        if not plan_id or any(character not in "0123456789abcdef" for character in plan_id):
            raise NotificationError("notification plan id is invalid")
        return self.state_root / f"{plan_id}.json"

    def _write_binding(self, actor: ActorContext, plan: Mapping[str, object], *, kind: str, recipient: str | None) -> None:
        plan_id = str(plan.get("plan_id") or "")
        digest = str(plan.get("digest") or "")
        if plan.get("status") != "approval_required" or not plan_id or not digest:
            raise NotificationError("notification transport returned an invalid plan")
        self.state_root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state_root, 0o700)
        target = self._binding_path(plan_id)
        temporary = target.with_name(f".{target.name}.tmp")
        payload = {
            "schema_version": NOTIFICATION_BINDING_SCHEMA,
            "plan_id": plan_id,
            "digest": digest,
            "org_id": actor.profile.org_id,
            "actor_id": actor.actor.actor_id,
            "session_id": actor.session_id,
            "kind": kind,
            "recipient": recipient,
            "created_at": self.clock().astimezone(UTC).isoformat(),
        }
        temporary.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(target)

    def _binding(self, actor: ActorContext, *, plan_id: str, digest: str | None = None) -> NotificationBinding:
        path = self._binding_path(plan_id)
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise NotificationError("notification plan binding is unavailable") from exc
        if payload.get("schema_version") != NOTIFICATION_BINDING_SCHEMA:
            raise NotificationError("notification plan binding is invalid")
        if (
            payload.get("org_id") != actor.profile.org_id
            or payload.get("actor_id") != actor.actor.actor_id
            or payload.get("session_id") != actor.session_id
        ):
            raise AuthorizationDenied("notification plan belongs to another actor session")
        if digest is not None and payload.get("digest") != digest:
            raise NotificationError("notification plan digest changed; prepare it again")
        return NotificationBinding(
            plan_id=plan_id,
            digest=str(payload["digest"]),
            org_id=str(payload["org_id"]),
            actor_id=str(payload["actor_id"]),
            session_id=str(payload["session_id"]),
            kind=str(payload["kind"]),
            recipient=str(payload["recipient"]) if payload.get("recipient") else None,
        )

    def plan(
        self,
        actor: ActorContext,
        *,
        kind: str,
        message: str,
        recipient: str | None = None,
    ) -> Mapping[str, object]:
        clean_kind = kind.strip().casefold()
        if clean_kind not in {"group", "send"}:
            raise NotificationError("notification kind must be group or send")
        clean_message = message.strip()
        if not clean_message:
            raise NotificationError("notification message is required")
        clean_recipient = recipient.strip() if recipient and recipient.strip() else None
        if clean_kind == "send" and clean_recipient is None:
            raise NotificationError("direct notification recipient is required")
        resource = f"notification:{clean_kind}:{clean_recipient or 'organization'}"
        self._authorize(actor, Permission.SHARE, resource)
        plan = self.transport.plan(
            kind=clean_kind,
            recipient=clean_recipient,
            message=clean_message,
        )
        self._write_binding(actor, plan, kind=clean_kind, recipient=clean_recipient)
        return plan

    def approve(
        self,
        actor: ActorContext,
        *,
        plan_id: str,
        digest: str,
        confirmation: str,
    ) -> Mapping[str, object]:
        if confirmation != EXACT_NOTIFICATION_CONFIRMATION:
            raise NotificationError("exact notification confirmation is required")
        binding = self._binding(actor, plan_id=plan_id, digest=digest)
        resource = f"notification:{binding.kind}:{binding.recipient or 'organization'}"
        self._authorize(actor, Permission.SHARE, resource)
        approval = self.transport.approve(
            plan_id=plan_id,
            digest=digest,
            confirmation=confirmation,
        )
        if approval.get("status") != "approved" or not approval.get("approval_token"):
            raise NotificationError("notification transport did not approve the exact plan")
        return approval

    def dispatch(
        self,
        actor: ActorContext,
        *,
        plan_id: str,
        approval_token: str,
    ) -> Mapping[str, object]:
        binding = self._binding(actor, plan_id=plan_id)
        resource = f"notification:{binding.kind}:{binding.recipient or 'organization'}"
        self._authorize(actor, Permission.SHARE, resource)
        self._authorize(actor, Permission.EXECUTE, resource)
        receipt = self.transport.dispatch(plan_id=plan_id, approval_token=approval_token)
        if receipt.get("status") not in {"sent", "delivered", "partial"}:
            raise NotificationError("notification dispatch did not return a delivery receipt")
        self._binding_path(plan_id).unlink(missing_ok=True)
        try:
            self.runtime.telemetry.emit(
                TelemetryEvent(
                    schema_version=TELEMETRY_SCHEMA_VERSION,
                    event_id=f"evt_{uuid4().hex}",
                    event_type="notification.dispatched",
                    occurred_at=self.clock().astimezone(UTC),
                    org_id=actor.profile.org_id,
                    actor_id=actor.actor.actor_id,
                    session_id=actor.session_id,
                    org_revision=actor.profile.revision,
                    metrics={"success": True, "action": binding.kind},
                )
            )
        except Exception:
            pass
        return receipt

    def cancel(self, actor: ActorContext, *, plan_id: str) -> Mapping[str, object]:
        self._binding(actor, plan_id=plan_id)
        receipt = self.transport.cancel(plan_id=plan_id)
        self._binding_path(plan_id).unlink(missing_ok=True)
        return receipt
