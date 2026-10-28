"""Deterministic v1 policy and action-permission implementations."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping, Sequence

from .contracts import (
    ActionAuthorizer,
    ActorContext,
    Permission,
    PolicyDecision,
    RetrievalRequest,
)


def _canonical_parts(path: str) -> tuple[str, ...] | None:
    normalized = path.replace("\\", "/").strip().strip("/")
    parts = tuple(normalized.split("/")) if normalized else ()
    if not parts or any(part in {"", ".", ".."} for part in parts):
        return None
    return parts


def scope_allows_path(path: str, scopes: Sequence[str]) -> bool:
    """Return whether a normalized canonical path is inside an ACL scope."""

    canonical = _canonical_parts(path)
    if canonical is None:
        return False
    for raw_scope in scopes:
        scope = _canonical_parts(raw_scope)
        if scope is not None and canonical[: len(scope)] == scope:
            return True
    return False


@dataclass(frozen=True, slots=True)
class ActorGrant:
    permissions: frozenset[Permission]
    scopes: tuple[str, ...] = ()
    resource_ids: tuple[str, ...] = ()


@dataclass(slots=True)
class StaticPolicy(ActionAuthorizer):
    """Fail-closed policy driven by explicit actor grants.

    This is deliberately small. It proves that dogfood uses a real policy
    boundary while leaving room for a future ACL-backed policy adapter.
    """

    org_id: str
    policy_epoch: str
    grants: Mapping[str, ActorGrant] = field(default_factory=dict)

    def _base_reasons(self, actor: ActorContext) -> list[str]:
        reasons: list[str] = []
        if actor.profile.org_id != self.org_id:
            reasons.append("actor profile belongs to a different organization")
        if actor.membership is None:
            reasons.append("actor has no organization membership")
        elif actor.membership.org_id != self.org_id:
            reasons.append("membership belongs to a different organization")
        elif actor.membership.actor_id != actor.actor.actor_id:
            reasons.append("membership belongs to a different actor")
        elif actor.membership.status != "active":
            reasons.append("membership is not active")
        if (
            actor.actor.account_id is not None
            and (actor.account is None or actor.account.account_id != actor.actor.account_id)
        ):
            reasons.append("actor account does not match the resolved account")
        return reasons

    def authorize_observe(
        self, actor: ActorContext, request: RetrievalRequest
    ) -> PolicyDecision:
        reasons = self._base_reasons(actor)
        if request.org_id != self.org_id:
            reasons.append("retrieval request belongs to a different organization")
        if request.actor_id != actor.actor.actor_id:
            reasons.append("retrieval request actor does not match the active actor")
        grant = self.grants.get(actor.actor.actor_id)
        if grant is None:
            reasons.append("actor has no policy grant")
        elif not {Permission.DISCOVER, Permission.READ}.issubset(grant.permissions):
            reasons.append("actor lacks discover/read permission")

        return PolicyDecision(
            allowed=not reasons,
            actor_id=actor.actor.actor_id,
            org_id=self.org_id,
            permission=Permission.READ,
            policy_epoch=self.policy_epoch,
            resource_ids=grant.resource_ids if grant else (),
            scopes=grant.scopes if grant else (),
            reasons=tuple(reasons) if reasons else ("explicit actor grant",),
        )

    def authorize_action(
        self,
        actor: ActorContext,
        permission: Permission,
        resource_ids: Sequence[str] = (),
    ) -> PolicyDecision:
        reasons = self._base_reasons(actor)
        grant = self.grants.get(actor.actor.actor_id)
        if grant is None:
            reasons.append("actor has no policy grant")
        elif permission not in grant.permissions:
            reasons.append(f"actor lacks {permission.value} permission")
        elif grant.resource_ids and any(
            resource_id not in grant.resource_ids for resource_id in resource_ids
        ):
            reasons.append("requested resource is outside the actor grant")

        return PolicyDecision(
            allowed=not reasons,
            actor_id=actor.actor.actor_id,
            org_id=self.org_id,
            permission=permission,
            policy_epoch=self.policy_epoch,
            resource_ids=tuple(resource_ids),
            scopes=grant.scopes if grant else (),
            reasons=tuple(reasons) if reasons else ("explicit actor grant",),
        )


def all_access_dogfood_policy(
    *, org_id: str, actor_id: str, policy_epoch: str = "all-access-v1"
) -> StaticPolicy:
    """Return the explicit dogfood policy; never bypass the policy interface."""

    return StaticPolicy(
        org_id=org_id,
        policy_epoch=policy_epoch,
        grants={
            actor_id: ActorGrant(
                permissions=frozenset(Permission),
                scopes=("memory",),
            )
        },
    )
