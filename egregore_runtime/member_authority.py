"""Request-local member authority above an injected trusted introspector.

This module implements parsing, identity resolution and policy intersection.
It does not issue credentials, call HTTP, read operator identity or provision
members. The host supplies an authenticated introspector; every resolution and
policy decision calls it again. Ownership, funding and actor parentage confer
no permissions here.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, fields, replace
from datetime import UTC, datetime, timedelta
import re
from typing import Any, Protocol
from uuid import UUID

from .contracts import (
    AccountIdentity,
    ActionAuthorizer,
    ActorContext,
    ActorIdentity,
    ActorKind,
    Capability,
    EgregoreProfile,
    Entitlements,
    ExecutionAuthority,
    OrgMembership,
    Permission,
    PolicyDecision,
    RetrievalRequest,
)
from .errors import AuthorizationDenied


SCHEMA = "egregore.member-authority/v1"
_PERMISSIONS = frozenset({Permission.DISCOVER, Permission.READ, Permission.WRITE})
_IDENTIFIER = re.compile(r"^[A-Za-z0-9._:-]{1,160}$")
_PATH_PART = re.compile(r"^[A-Za-z0-9_.-]+$")


class MemberAuthorityError(AuthorizationDenied):
    """A bounded refusal that contains neither payload nor transport details."""

    def __init__(self):
        super().__init__("Authenticated member authority could not be verified.")


def _require(value: bool) -> None:
    if not value:
        raise MemberAuthorityError()


def _identifier(value: Any) -> str:
    _require(isinstance(value, str) and _IDENTIFIER.fullmatch(value) is not None)
    return value


def _uuid(value: Any) -> str:
    _require(isinstance(value, str))
    try:
        parsed = UUID(value)
    except (ValueError, AttributeError):
        raise MemberAuthorityError() from None
    _require(parsed.int != 0 and str(parsed) == value)
    return value


def _text(value: Any, limit: int = 160) -> str:
    _require(isinstance(value, str) and 0 < len(value) <= limit
             and value == value.strip() and all(ord(c) >= 32 and ord(c) != 127 for c in value))
    return value


def _mapping(value: Any) -> Mapping:
    _require(isinstance(value, Mapping))
    return value


def _strings(value: Any, *, limit: int = 32) -> tuple[str, ...]:
    _require(isinstance(value, list) and len(value) <= limit)
    result = tuple(_identifier(item) for item in value)
    _require(len(set(result)) == len(result))
    return result


def _prefix(value: Any) -> str:
    _require(isinstance(value, str) and len(value) <= 1024)
    parts = value.split("/")
    _require(parts[0] == "memory" and all(
        part not in {"", ".", ".."} and _PATH_PART.fullmatch(part) for part in parts
    ))
    return value


def _prefixes(value: Any) -> tuple[str, ...]:
    _require(isinstance(value, list) and len(value) <= 64)
    result = tuple(_prefix(item) for item in value)
    _require(len(set(result)) == len(result))
    return result


def _utc(value: Any) -> datetime:
    _require(isinstance(value, datetime) and value.tzinfo is not None
             and value.utcoffset() == timedelta(0))
    return value


@dataclass(frozen=True, slots=True)
class MemberAuthorityBinding:
    member_account_id: str
    member_actor_id: str
    membership_id: str
    org_id: str
    executor_actor_id: str
    worker_id: str
    binding_id: str
    audience: str
    grant_id: str

    def __post_init__(self) -> None:
        for field in fields(self):
            value = getattr(self, field.name)
            # Connected instances may retain their immutable Local organization
            # reference (migration 046). It must still match the host-selected
            # reference exactly; the database UUID is not an interchangeable alias.
            if field.name == "org_id" and isinstance(value, str) and re.fullmatch(r"org_[0-9a-f]{32}", value):
                continue
            (_identifier if field.name in {"worker_id", "audience"} else _uuid)(value)
        _require(self.executor_actor_id != self.member_actor_id)


class MemberIntrospector(Protocol):
    def __call__(
        self, *, expected: MemberAuthorityBinding, operation: str,
    ) -> Mapping[str, Any]: ...


@dataclass(frozen=True, slots=True)
class VerifiedMemberAuthority:
    expected: MemberAuthorityBinding
    executor_kind: ActorKind
    revision: str
    expires_at: datetime
    permissions: frozenset[Permission]
    read_prefixes: tuple[str, ...]
    write_prefixes: tuple[str, ...]
    account_name: str
    member_name: str
    roles: tuple[str, ...]
    teams: tuple[str, ...]
    aliases: tuple[tuple[str, str], ...]
    org_slug: str
    org_name: str
    org_revision: str
    default_policy: str
    default_context_budget: int
    entitlement_plan: str
    entitlement_capabilities: frozenset[Capability]
    entitlement_source: str
    entitlement_revision: str

    @property
    def execution(self) -> ExecutionAuthority:
        return ExecutionAuthority(
            **{field.name: getattr(self.expected, field.name) for field in fields(self.expected)},
            executor_kind=self.executor_kind, revision=self.revision, expires_at=self.expires_at,
        )

    def actor_context(self, *, session_id: str, harness: str) -> ActorContext:
        _text(session_id, 240)
        _identifier(harness)
        binding = self.expected
        return ActorContext(
            account=AccountIdentity(binding.member_account_id, self.account_name),
            actor=ActorIdentity(
                actor_id=binding.member_actor_id, kind=ActorKind.PERSON,
                display_name=self.member_name, account_id=binding.member_account_id,
                aliases=dict(self.aliases),
            ),
            profile=EgregoreProfile(
                schema_version="egregore-profile/v1", org_id=binding.org_id,
                slug=self.org_slug, name=self.org_name, revision=self.org_revision,
                default_policy=self.default_policy,
                default_context_budget=self.default_context_budget,
            ),
            membership=OrgMembership(
                binding.membership_id, binding.org_id, binding.member_actor_id,
                roles=self.roles, teams=self.teams, status="active",
            ),
            entitlements=Entitlements(
                self.entitlement_plan, self.entitlement_capabilities,
                self.entitlement_source, self.entitlement_revision,
            ),
            session_id=session_id, harness=harness, execution=self.execution,
        )


def parse_member_authority(
    payload: Mapping[str, Any], *, expected: MemberAuthorityBinding, now: datetime,
) -> VerifiedMemberAuthority:
    """Validate a fresh authenticated response against a host-selected binding."""
    try:
        _require(isinstance(expected, MemberAuthorityBinding))
        _utc(now)
        payload = _mapping(payload)
        _require(payload.get("schema") == SCHEMA and payload.get("active") is True)
        actual = MemberAuthorityBinding(**{
            field.name: payload[field.name] for field in fields(expected)
        })
        _require(actual == expected)
        kind = ActorKind(payload["executor_kind"])
        _require(kind in {ActorKind.AGENT, ActorKind.SERVICE})
        expires = _text(payload["expires_at"], 40)
        expires_at = _utc(datetime.fromisoformat(expires.replace("Z", "+00:00")))
        _require(expires_at > now)
        operations = _strings(payload["operations"], limit=3)
        permissions = frozenset(Permission(item) for item in operations)
        _require(bool(permissions) and permissions <= _PERMISSIONS)
        reads, writes = _prefixes(payload["read_prefixes"]), _prefixes(payload["write_prefixes"])
        member, account = _mapping(payload["member"]), _mapping(payload["account"])
        aliases = _mapping(member["aliases"])
        _require(len(aliases) <= 16)
        org, entitlement = _mapping(payload["organization"]), _mapping(payload["entitlements"])
        budget = org["default_context_budget"]
        _require(type(budget) is int and 1 <= budget <= 1_000_000)
        return VerifiedMemberAuthority(
            expected=actual, executor_kind=kind, revision=_identifier(payload["revision"]),
            expires_at=expires_at, permissions=permissions,
            read_prefixes=reads, write_prefixes=writes,
            account_name=_text(account["display_name"]), member_name=_text(member["display_name"]),
            roles=_strings(member["roles"]), teams=_strings(member["teams"]),
            aliases=tuple(sorted((_identifier(key), _text(value)) for key, value in aliases.items())),
            org_slug=_identifier(org["slug"]), org_name=_text(org["name"]),
            org_revision=_text(org["revision"]), default_policy=_identifier(org["default_policy"]),
            default_context_budget=budget, entitlement_plan=_identifier(entitlement["plan"]),
            entitlement_capabilities=frozenset(Capability(item) for item in
                                              _strings(entitlement["capabilities"])),
            entitlement_source=_text(entitlement["source"]),
            entitlement_revision=_text(entitlement["revision"]),
        )
    except MemberAuthorityError:
        raise
    except Exception:
        raise MemberAuthorityError() from None


def _now() -> datetime:
    return datetime.now(UTC)


@dataclass(frozen=True, slots=True)
class AuthenticatedMemberResolver:
    expected: MemberAuthorityBinding
    introspect: MemberIntrospector
    clock: Callable[[], datetime] = _now

    def __post_init__(self) -> None:
        _require(isinstance(self.expected, MemberAuthorityBinding)
                 and callable(self.introspect) and callable(self.clock))

    def _fresh(self, operation: str) -> VerifiedMemberAuthority:
        try:
            _require(operation in {"resolve", "discover", "read", "write"})
            payload = self.introspect(expected=self.expected, operation=operation)
            # Validate time after introspection, not before a potentially slow call.
            return parse_member_authority(payload, expected=self.expected, now=self.clock())
        except MemberAuthorityError:
            raise
        except Exception:
            raise MemberAuthorityError() from None

    def resolve(self, *, session_id: str, harness: str) -> ActorContext:
        return self._fresh("resolve").actor_context(session_id=session_id, harness=harness)

    def verify(self, actor: ActorContext, operation: str) -> VerifiedMemberAuthority:
        """Verify current authority without trusting mutable presentation fields."""
        try:
            binding = self.expected
            _require(isinstance(actor, ActorContext) and actor.account is not None
                     and actor.membership is not None and isinstance(actor.execution, ExecutionAuthority))
            _require(actor.account.account_id == actor.actor.account_id == binding.member_account_id
                     and actor.actor.actor_id == actor.membership.actor_id == binding.member_actor_id
                     and actor.profile.org_id == actor.membership.org_id == binding.org_id
                     and actor.membership.membership_id == binding.membership_id
                     and actor.membership.status == "active" and actor.actor.kind == ActorKind.PERSON)
            _require(all(getattr(actor.execution, field.name) == getattr(binding, field.name)
                         for field in fields(binding)))
            verified = self._fresh(operation)
            _require(actor.execution.executor_kind == verified.executor_kind)
            return verified
        except MemberAuthorityError:
            raise
        except Exception:
            raise MemberAuthorityError() from None


def _intersect(left: Sequence[str], right: Sequence[str]) -> tuple[str, ...]:
    """Intersect segment prefixes; never expand an append grant into a write."""
    result = set()
    for first in left:
        _prefix(first)
        for second in right:
            _prefix(second)
            # Both sides are canonical memory prefixes, validated above.
            # This is lexical segment containment, not filesystem traversal;
            # keeping it here lets the hosted parser run without Local policy.
            if first == second or first.startswith(second + "/"):
                result.add(first)
            elif second.startswith(first + "/"):
                result.add(second)
    return tuple(sorted(result))


@dataclass(frozen=True, slots=True)
class MemberAuthorityPolicy:
    resolver: AuthenticatedMemberResolver
    base_policy_factory: Callable[[ActorContext], ActionAuthorizer]

    def _denied(self, permission: Permission, reason: str, base=None) -> PolicyDecision:
        if base is not None:
            return replace(base, allowed=False, reasons=(reason,), scopes=(), resource_ids=(),
                           read_prefixes=(), write_prefixes=(), append_prefixes=())
        expected = self.resolver.expected
        return PolicyDecision(False, expected.member_actor_id, expected.org_id, permission,
                              "member-authority/v1", reasons=(reason,))

    def _intersect_decision(self, base, verified, permission) -> PolicyDecision:
        expected = self.resolver.expected
        _require(isinstance(base, PolicyDecision) and base.actor_id == expected.member_actor_id
                 and base.org_id == expected.org_id and base.permission == permission)
        if not base.allowed:
            return self._denied(permission, "Local policy denied this operation.", base)
        # policy.check consumes prefix fields, not decision.permission. Return
        # only the operation the base policy actually authorized, so a read
        # decision cannot become a write or a discover-only grant expose bytes.
        reads = verified.read_prefixes if (
            permission in {Permission.DISCOVER, Permission.READ}
            and Permission.READ in verified.permissions
        ) else ()
        writes = verified.write_prefixes if (
            permission == Permission.WRITE and Permission.WRITE in verified.permissions
        ) else ()
        read = _intersect(base.read_prefixes, reads)
        write = _intersect(base.write_prefixes, writes)
        append = _intersect(base.append_prefixes, writes)
        selected = read if permission in {Permission.READ, Permission.DISCOVER} else (*write, *append)
        if not selected:
            return self._denied(permission, "The member grant and local policy have no common scope.", base)
        return replace(base, read_prefixes=read, write_prefixes=write, append_prefixes=append,
                       scopes=_intersect(base.scopes, reads if permission != Permission.WRITE else writes))

    def authorize_observe(self, actor: ActorContext, request: RetrievalRequest) -> PolicyDecision:
        try:
            verified = self.resolver.verify(actor, "read")
            if not {Permission.DISCOVER, Permission.READ} <= verified.permissions:
                return self._denied(Permission.READ, "The member grant does not permit discovery and reading.")
            expected = self.resolver.expected
            _require(request.org_id == expected.org_id and request.actor_id == expected.member_actor_id)
            current = verified.actor_context(session_id=actor.session_id, harness=actor.harness)
            base = self.base_policy_factory(current).authorize_observe(current, request)
            return self._intersect_decision(base, verified, Permission.READ)
        except Exception:
            return self._denied(Permission.READ, "Authenticated member authority is unavailable.")

    def authorize_action(
        self, actor: ActorContext, permission: Permission, resource_ids: Sequence[str] = (),
    ) -> PolicyDecision:
        try:
            _require(isinstance(permission, Permission) and permission in _PERMISSIONS)
            verified = self.resolver.verify(actor, permission.value)
            if permission not in verified.permissions or (
                permission == Permission.DISCOVER and Permission.READ not in verified.permissions
            ):
                return self._denied(permission, "The member grant does not permit this operation.")
            current = verified.actor_context(session_id=actor.session_id, harness=actor.harness)
            authorizer = self.base_policy_factory(current)
            base = authorizer.authorize_action(current, permission, resource_ids)
            if permission == Permission.DISCOVER:
                # Discovery exposes readable source metadata. Require the
                # underlying policy's read decision as well as its discover
                # decision, and retain the read decision's hold restrictions.
                readable = authorizer.authorize_action(current, Permission.READ, resource_ids)
                expected = self.resolver.expected
                _require(isinstance(base, PolicyDecision) and isinstance(readable, PolicyDecision)
                         and base.permission == Permission.DISCOVER and readable.permission == Permission.READ
                         and base.actor_id == readable.actor_id == expected.member_actor_id
                         and base.org_id == readable.org_id == expected.org_id)
                if not base.allowed or not readable.allowed:
                    return self._denied(permission, "Local policy denied discovery or reading.")
                _require(base.policy_epoch == readable.policy_epoch and base.scope == readable.scope
                         and base.memory_revision == readable.memory_revision)
                resources = base.resource_ids or readable.resource_ids
                if base.resource_ids and readable.resource_ids:
                    resources = tuple(item for item in base.resource_ids if item in readable.resource_ids)
                    if not resources:
                        return self._denied(permission, "Local discovery and reading scopes do not overlap.")
                base = replace(readable, permission=Permission.DISCOVER,
                               resource_ids=resources,
                               read_prefixes=_intersect(base.read_prefixes, readable.read_prefixes),
                               scopes=_intersect(base.scopes, readable.scopes))
            return self._intersect_decision(base, verified, permission)
        except Exception:
            return self._denied(permission, "Authenticated member authority is unavailable.")
