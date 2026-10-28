"""Provider-independent organization invitation domain service.

An invitation is an authorization to create a future membership.  It is not
an AccountIdentity, ActorIdentity, or OrgMembership, and linked-provider
handles remain transport aliases until the invitee authenticates.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import re
from typing import Mapping, Protocol

from .contracts import ActorContext, Permission, Serializable
from .errors import AuthorizationDenied


_PROVIDER_USERNAME = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")


@dataclass(frozen=True, slots=True)
class InvitationTransportResult(Serializable):
    status: str
    provider_status: str
    memory_status: str
    managed_access: tuple[Mapping[str, str], ...] = ()
    invite_url: str | None = None
    join_command: str | None = None
    group_link: str | None = None
    manual_access_url: str | None = None
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class InvitationReceipt(Serializable):
    status: str
    org_id: str
    org_name: str
    invited_by_actor_id: str
    provider: str
    provider_username: str
    provider_status: str
    memory_status: str
    managed_access: tuple[Mapping[str, str], ...] = ()
    invite_url: str | None = None
    join_command: str | None = None
    group_link: str | None = None
    manual_access_url: str | None = None
    warnings: tuple[str, ...] = ()


class InvitationTransport(Protocol):
    """Current provider/control-plane transport behind the Runtime seam."""

    def invite(
        self,
        actor: ActorContext,
        *,
        provider: str,
        provider_username: str,
    ) -> InvitationTransportResult: ...


class InvitationService:
    """Authorize one future membership before invoking any external effect."""

    def __init__(self, runtime, transport: InvitationTransport) -> None:
        self.runtime = runtime
        self.transport = transport

    @staticmethod
    def normalize_provider_username(value: str) -> str:
        username = value.strip()
        if not _PROVIDER_USERNAME.fullmatch(username) or "--" in username:
            raise ValueError("a valid GitHub username is required")
        return username

    def invite(
        self,
        actor: ActorContext,
        *,
        provider_username: str,
        provider: str = "github",
    ) -> InvitationReceipt:
        username = self.normalize_provider_username(provider_username)
        if provider != "github":
            raise ValueError("the installed invitation transport supports GitHub aliases only")

        resource = f"org:{actor.profile.org_id}:membership-invite"
        decision = self.runtime.authorize(actor, Permission.ADMINISTER, (resource,))
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons))
        if actor.membership is None or actor.membership.status != "active":
            raise AuthorizationDenied("an active organization membership is required")

        result = self.transport.invite(
            actor,
            provider=provider,
            provider_username=username,
        )
        return InvitationReceipt(
            status=result.status,
            org_id=actor.profile.org_id,
            org_name=actor.profile.name,
            invited_by_actor_id=actor.actor.actor_id,
            provider=provider,
            provider_username=username,
            provider_status=result.provider_status,
            memory_status=result.memory_status,
            managed_access=result.managed_access,
            invite_url=result.invite_url,
            join_command=result.join_command,
            group_link=result.group_link,
            manual_access_url=result.manual_access_url,
            warnings=result.warnings,
        )
