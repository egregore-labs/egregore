"""Central plan/status to runtime-capability translation.

Capability decisions are intentionally separate from authorization.  Local
safety, identity, policy, and canonical memory do not disappear when a paid
entitlement is absent or inactive.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from typing import Any

from .contracts import Capability, Entitlements


CAPABILITY_REVISION = "egregore-capabilities/v1"
ACTIVE_ENTITLEMENT_STATUSES = frozenset({"active", "trialing"})

LOCAL_CAPABILITIES = frozenset(
    {
        Capability.CANONICAL_MEMORY_LOCAL,
        Capability.RETRIEVAL_LOCAL,
        Capability.EMBEDDINGS_LOCAL,
        Capability.TELEMETRY_LOCAL,
        Capability.IDENTITY_BASIC,
        Capability.POLICY_BASIC,
        Capability.INGEST_MANUAL,
        Capability.SYNC_GIT,
    }
)

# Only capabilities backed by current shared infrastructure are implicit.
# Future managed retrieval/ingest/policy products require an explicit
# capability grant from the control plane instead of inheriting from a price.
PLAN_CAPABILITIES: Mapping[str, frozenset[Capability]] = {
    "local": frozenset(),
    "free": frozenset(),
    "connect": frozenset({Capability.CONNECTED_CONTROL_PLANE}),
    "connected": frozenset({Capability.CONNECTED_CONTROL_PLANE}),
}


def _parse_capabilities(values: Iterable[str | Capability]) -> frozenset[Capability]:
    result: set[Capability] = set()
    for value in values:
        try:
            result.add(value if isinstance(value, Capability) else Capability(value))
        except ValueError:
            # Forward-compatible control-plane rows may contain capabilities
            # this older Local runtime does not know yet.
            continue
    return frozenset(result)


def resolve_entitlements(
    *,
    mode: str = "local",
    row: Mapping[str, Any] | None = None,
) -> Entitlements:
    """Resolve capabilities from Local defaults plus an optional shared row."""

    entitlement = dict(row or {})
    plan = str(entitlement.get("plan") or ("connect" if mode == "connected" else "local")).lower()
    status = str(entitlement.get("status") or ("active" if mode == "local" else "inactive")).lower()
    capabilities = set(LOCAL_CAPABILITIES)

    if status in ACTIVE_ENTITLEMENT_STATUSES:
        capabilities.update(PLAN_CAPABILITIES.get(plan, ()))
        metadata = entitlement.get("metadata") or {}
        if isinstance(metadata, Mapping):
            explicit = metadata.get("capabilities") or ()
            if isinstance(explicit, (list, tuple, set, frozenset)):
                capabilities.update(_parse_capabilities(explicit))

    revision = str(
        entitlement.get("updated_at")
        or entitlement.get("id")
        or CAPABILITY_REVISION
    )
    return Entitlements(
        plan=plan,
        capabilities=frozenset(capabilities),
        source="supabase" if row is not None else "local-defaults",
        revision=revision,
    )
