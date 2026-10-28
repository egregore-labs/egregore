"""Versioned organizational profile loading for the Egregore runtime.

``egregore.json`` remains a small, committed configuration document.  Rich
organizational identity belongs in referenced Markdown documents; runtime
caches, secrets, and telemetry never belong here.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Mapping
from datetime import UTC, datetime
from uuid import uuid4

from .contracts import EgregoreProfile


CONFIG_SCHEMA = "egregore-config/v1"
PROFILE_SCHEMA = "egregore-profile/v1"
DEFAULT_CONTEXT_BUDGET = 8_000


class ProfileConfigError(ValueError):
    """Raised when committed organization identity configuration is invalid."""


def new_org_id() -> str:
    """Return an opaque organization id with no provider or transport meaning."""

    return f"org_{uuid4().hex}"


def default_profile_config(*, revision: str = "profile/v1") -> dict[str, Any]:
    """Return conservative profile defaults for a newly initialized org."""

    return {
        "schema_version": PROFILE_SCHEMA,
        "revision": revision,
        "identity_path": "memory/identity/EGREGORE.md",
        "purpose_path": "memory/identity/EGREGORE.md",
        "principles_path": "memory/identity/EGREGORE.md",
        "conventions_path": "memory/identity/EGREGORE.md",
        "declared_sections": [
            "essence",
            "values",
            "domains",
            "voice",
            "decision-grammar",
        ],
        "default_policy": "all-access-v1",
        "default_context_budget": DEFAULT_CONTEXT_BUDGET,
    }


def initialize_org_config(
    config: Mapping[str, Any],
    *,
    org_id: str | None = None,
) -> dict[str, Any]:
    """Add runtime identity fields without disturbing existing configuration."""

    result = dict(config)
    result.setdefault("schema_version", CONFIG_SCHEMA)
    result.setdefault("org_id", org_id or new_org_id())
    profile = default_profile_config()
    profile.update(dict(result.get("profile") or {}))
    result["profile"] = profile
    return result


def render_identity_document(
    name: str,
    *,
    org_type: str = "team",
    intent: str = "collaborate and accumulate organizational knowledge",
    founded: str | None = None,
) -> str:
    """Render declared organizational identity without derived graph claims."""

    founded_on = founded or datetime.now(UTC).date().isoformat()
    return "\n".join(
        [
            f"# {name}",
            "",
            "## Essence",
            "",
            f"{name} is a {org_type} using Egregore to {intent}.",
            "This declaration is versioned organizational identity; refine it through normal review.",
            "",
            "## Values",
            "",
            "- Preserve provenance and make consequential reasoning inspectable.",
            "- Leave canonical organizational state more useful than you found it.",
            "- Keep human and agent authority explicit.",
            "",
            "## Domains",
            "",
            "- Add the fields this organization works in and the boundaries it respects.",
            "",
            "## Voice",
            "",
            "Direct, specific, and honest about uncertainty.",
            "",
            "## Decision Grammar",
            "",
            "- Record decisions that affect more than one session.",
            "- Bias toward action for reversible choices.",
            "- Seek another perspective before irreversible choices.",
            "",
            "## Lineage",
            "",
            f"Declaration created: {founded_on}",
            "",
        ]
    )


def _content_revision(raw: bytes) -> str:
    return f"config-sha256:{hashlib.sha256(raw).hexdigest()}"


def _profile_revision(root: Path, raw: bytes, profile: Mapping[str, Any]) -> str:
    """Hash committed declarations so context freshness follows identity edits."""

    digest = hashlib.sha256(raw)
    for field in ("identity_path", "purpose_path", "principles_path", "conventions_path"):
        value = profile.get(field)
        if not isinstance(value, str) or not value.strip():
            continue
        relative = value.strip().replace("\\", "/")
        parts = Path(relative).parts
        if Path(relative).is_absolute() or ".." in parts:
            raise ProfileConfigError(f"profile.{field} must stay inside the Egregore")
        declaration = (root / relative).resolve()
        digest.update(field.encode())
        digest.update(relative.encode())
        try:
            digest.update(declaration.read_bytes())
        except OSError:
            digest.update(b"<missing>")
    return f"profile-sha256:{digest.hexdigest()}"


def load_profile(config_path: Path | str) -> EgregoreProfile:
    """Load new or legacy ``egregore.json`` into the stable profile contract.

    Legacy configs remain readable.  Their fallback org id is explicitly
    marked as legacy and should be replaced by ``initialize_org_config`` at
    the next controlled config write.
    """

    path = Path(config_path)
    raw = path.read_bytes()
    try:
        config = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ProfileConfigError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(config, dict):
        raise ProfileConfigError(f"{path} must contain a JSON object")

    slug = str(config.get("slug") or "").strip()
    name = str(config.get("org_name") or config.get("name") or "").strip()
    if not slug or not name:
        raise ProfileConfigError(f"{path} must define slug and org_name")

    profile = config.get("profile") or {}
    if not isinstance(profile, dict):
        raise ProfileConfigError(f"{path} profile must be an object")
    schema = str(profile.get("schema_version") or PROFILE_SCHEMA)
    if schema != PROFILE_SCHEMA:
        raise ProfileConfigError(f"unsupported profile schema: {schema}")

    configured_org_id = str(config.get("org_id") or "").strip()
    # Read compatibility only. New setup always writes an opaque org id.
    resolved_org_id = configured_org_id or f"legacy-org:{slug}"
    budget = profile.get("default_context_budget", DEFAULT_CONTEXT_BUDGET)
    if not isinstance(budget, int) or budget <= 0:
        raise ProfileConfigError("profile.default_context_budget must be positive")

    return EgregoreProfile(
        schema_version=schema,
        org_id=resolved_org_id,
        slug=slug,
        name=name,
        revision=_profile_revision(path.parent, raw, profile),
        purpose_path=profile.get("purpose_path"),
        principles_path=profile.get("principles_path"),
        conventions_path=profile.get("conventions_path"),
        default_policy=str(profile.get("default_policy") or "all-access-v1"),
        default_context_budget=budget,
    )
