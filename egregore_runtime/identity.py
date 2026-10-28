"""Provider-independent Local identity resolution.

GitHub fields remain compatibility aliases used by today's Git transport. They
are never used as the domain account or actor identifier.
"""

from __future__ import annotations

import json
import os
import tempfile
import fcntl
import hashlib
import re
from contextlib import contextmanager
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import uuid4

from .contracts import (
    AccountIdentity,
    ActorContext,
    ActorIdentity,
    ActorKind,
    OrgMembership,
)
from .entitlements import resolve_entitlements
from .profile import initialize_org_config, load_profile, render_identity_document


IDENTITY_SCHEMA = "egregore-identity/v2"


@dataclass(frozen=True, slots=True)
class OrganizationMemberPresentation:
    """Presentation-only view of one canonical organization identity.

    Authorization continues to use ActorContext and opaque actor/membership
    identifiers. This local directory exists only so harnesses can present a
    teammate's chosen name when evidence contains a provider handle or legacy
    alias.
    """

    person_id: str
    display_name: str
    aliases: tuple[str, ...]


def _profile_identity(path: Path) -> dict[str, Any]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")[:4_000]
    except OSError:
        return {}
    title = re.search(r"(?m)^#\s+(.+?)\s*$", text)
    fields = {
        match.group(1).casefold(): match.group(2).strip()
        for match in re.finditer(
            r"(?m)^([A-Za-z][A-Za-z-]*)[ \t]*:[ \t]*(.*)$",
            text,
        )
    }
    return {
        "path": path,
        "title": title.group(1).strip() if title else "",
        "person_id": fields.get("person-id", ""),
        "github": fields.get("github", ""),
        "github_aliases": tuple(
            item.strip()
            for item in fields.get("github-aliases", "").split(",")
            if item.strip()
        ),
        "previous_names": tuple(
            item.strip()
            for item in fields.get("previous-names", "").split(",")
            if item.strip()
        ),
        "alias_of": fields.get("alias-of", ""),
    }


def organization_member_presentations(
    root: Path,
    actor: ActorContext | None = None,
) -> tuple[OrganizationMemberPresentation, ...]:
    """Load stable member names without treating aliases as extra people.

    ``memory/people`` is the canonical local witness produced by identity
    reconciliation. Profiles with the same Person-ID collapse into one member;
    an explicit Alias-Of title is the preferred presentation witness for
    legacy canonical profiles whose title is still a provider handle.
    """

    people = root / "memory" / "people"
    if not people.is_dir():
        return ()
    # Durable removals: the committed ledger in egregore.json outranks file
    # presence — a person file resurrected by a session write or sync never
    # resurfaces a removed member in the roster.
    removed: set[str] = set()
    try:
        config = json.loads((root / "egregore.json").read_text(encoding="utf-8"))
        removed = {
            str(handle).strip().casefold()
            for handle in (config.get("people_removed") or [])
            if str(handle).strip()
        }
    except (OSError, ValueError):
        removed = set()
    grouped: dict[str, list[dict[str, Any]]] = {}
    for path in sorted(people.glob("*.md")):
        if path.name == "index.md":
            continue
        if path.stem.casefold() in removed:
            continue
        profile = _profile_identity(path)
        if not profile:
            continue
        if str(profile.get("github") or "").strip().casefold() in removed:
            continue
        identity = str(profile["person_id"] or profile["github"]).strip()
        if not identity:
            continue
        grouped.setdefault(identity.casefold(), []).append(profile)

    current_references: set[str] = set()
    if actor is not None:
        current_references = {
            actor.actor.display_name.casefold(),
            *(str(value).casefold() for value in actor.actor.aliases.values()),
        }
        account = getattr(actor, "account", None)
        if account is not None:
            current_references.add(account.display_name.casefold())
            current_references.update(
                str(value).casefold()
                for value in getattr(account, "provider_aliases", {}).values()
            )

    members: list[OrganizationMemberPresentation] = []
    for profiles in grouped.values():
        aliases: dict[str, str] = {}
        explicit_titles: list[str] = []
        canonical_titles: list[str] = []
        previous_names: list[str] = []
        for profile in profiles:
            values = (
                profile["path"].stem,
                profile["github"],
                *profile["github_aliases"],
                profile["title"],
                *profile["previous_names"],
            )
            for value in values:
                clean = str(value).strip()
                if clean:
                    aliases.setdefault(clean.casefold(), clean)
            title = str(profile["title"]).strip()
            if title:
                if profile["alias_of"]:
                    explicit_titles.append(title)
                else:
                    canonical_titles.append(title)
            previous_names.extend(profile["previous_names"])

        display_name = ""
        if actor is not None and current_references.intersection(aliases):
            display_name = actor.actor.display_name
        elif explicit_titles:
            display_name = explicit_titles[0]
        else:
            machine_names = {
                str(profile["path"].stem).casefold() for profile in profiles
            } | {
                str(profile["github"]).casefold()
                for profile in profiles
                if profile["github"]
            }
            display_name = next(
                (
                    title
                    for title in canonical_titles
                    if title.casefold() not in machine_names
                ),
                "",
            )
            if not display_name:
                display_name = next(iter(previous_names), "")
            if not display_name:
                display_name = next(iter(canonical_titles), "Egregore member")

        compact_aliases = tuple(
            value
            for key, value in sorted(aliases.items())
            if key != display_name.casefold()
            and (
                key in {str(profile["path"].stem).casefold() for profile in profiles}
                or key
                in {
                    str(profile["github"]).casefold()
                    for profile in profiles
                    if profile["github"]
                }
            )
        )
        members.append(
            OrganizationMemberPresentation(
                person_id=str(profiles[0]["person_id"] or profiles[0]["github"]),
                display_name=display_name,
                aliases=compact_aliases,
            )
        )
    return tuple(sorted(members, key=lambda item: item.display_name.casefold()))


def resolve_actor_query(actor: ActorContext, query: str) -> str:
    """Bind first-person references in ranked queries to the resolved actor.

    No identity is inferred from query text or machine state. Exact filename
    and literal lookups do not use this helper. This changes the search subject,
    never the actor's authorization or the chosen retrieval mode.
    """
    identity = actor.actor
    name = identity.display_name
    username = str(identity.aliases.get("github.username") or "").strip()
    subject = f"{name} ({username})" if username and username.casefold() != name.casefold() else name

    def replacement(match: re.Match[str]) -> str:
        token = " ".join(match.group().casefold().split())
        if token == "am i":
            return f"is {subject}"
        if token in {"i am", "i'm", "i’m"}:
            return f"{subject} is"
        if token in {"my", "mine"}:
            return f"{subject}'s"
        return subject

    return re.sub(
        r"(?<!\w)(?:I['’]m|am\s+I|I\s+am|I|me|myself|my|mine)(?!\w)",
        replacement, query, flags=re.I,
    )


def actor_lexical_formulations(
    actor: ActorContext, task: str, formulations: tuple[str, ...]
) -> tuple[str, ...]:
    """Expand an explicit or first-person actor reference using verified identity."""
    identity = actor.actor
    references = tuple(dict.fromkeys(
        value.strip() for value in (
            identity.actor_id, identity.display_name,
            *(str(value) for value in identity.aliases.values()),
            *getattr(identity, "attribution_ids", ()),
        ) if value and value.strip()
    ))
    bound_task = resolve_actor_query(actor, task)
    expanded = [resolve_actor_query(actor, value) for value in formulations]
    if not any(re.search(r"(?<!\w)" + re.escape(value) + r"(?!\w)", bound_task, re.I)
               for value in references):
        return tuple(expanded)
    seen = {value.strip().casefold() for value in expanded}
    for reference in references:
        if reference.casefold() not in seen:
            expanded.append(reference)
            seen.add(reference.casefold())
    return tuple(expanded)


def new_identity_id(prefix: str) -> str:
    return f"{prefix}_{uuid4().hex}"


def actor_identity(
    *,
    kind: ActorKind,
    display_name: str,
    actor_id: str | None = None,
    account_id: str | None = None,
    parent_actor_id: str | None = None,
    aliases: Mapping[str, str] | None = None,
    attribution_ids: tuple[str, ...] = (),
) -> ActorIdentity:
    """Construct a person, agent, or service actor without provider coupling."""

    if kind is ActorKind.PERSON and not account_id:
        raise ValueError("person actors require an account_id")
    return ActorIdentity(
        actor_id=actor_id or new_identity_id("actor"),
        kind=kind,
        display_name=display_name,
        account_id=account_id,
        parent_actor_id=parent_actor_id,
        aliases=dict(aliases or {}),
        attribution_ids=attribution_ids,
    )


def actor_presentation_name(
    actor: ActorContext,
    actor_id: str | None,
    declared_alias: str | None = None,
) -> str:
    """Render an identity reference without weakening stable-ID authority.

    Canonical artifacts use stable actor IDs for ownership and may carry a
    display-only alias captured at write time. The active ActorContext is the
    authority for the current actor's presentation; otherwise the declared
    alias is preferred. Stable references remain structured identity fields
    and are never used as presentation labels.
    """

    stable_reference = str(actor_id or "").strip()
    alias = str(declared_alias or "").strip()
    current_references = {
        actor.actor.actor_id.casefold(),
        actor.actor.display_name.casefold(),
        *(value.casefold() for value in getattr(actor.actor, "attribution_ids", ())),
        *(
            str(value).casefold()
            for value in actor.actor.aliases.values()
            if str(value).strip()
        ),
    }
    if actor.account is not None:
        current_references.add(actor.account.account_id.casefold())
        current_references.add(actor.account.display_name.casefold())
        current_references.update(
            str(value).casefold()
            for value in actor.account.provider_aliases.values()
            if str(value).strip()
        )
    if (
        stable_reference.casefold() in current_references
        or alias.casefold() in current_references
    ):
        return actor.actor.display_name
    return alias or "Egregore member"


def migrate_local_identity_state(
    state: Mapping[str, Any],
    *,
    org_id: str,
    id_factory: Callable[[str], str] = new_identity_id,
) -> tuple[dict[str, Any], bool]:
    """Upgrade legacy GitHub-shaped state while preserving its old readers."""

    result = dict(state)
    changed = False

    identity = dict(result.get("identity") or {})
    account_id = str(result.get("account_id") or identity.get("account_id") or "").strip()
    actor_id = str(result.get("actor_id") or identity.get("actor_id") or "").strip()
    membership_id = str(
        result.get("membership_id") or identity.get("membership_id") or ""
    ).strip()
    if not account_id:
        account_id = id_factory("acct")
    if result.get("account_id") != account_id:
        result["account_id"] = account_id
        changed = True
    if not actor_id:
        actor_id = id_factory("actor")
    if result.get("actor_id") != actor_id:
        result["actor_id"] = actor_id
        changed = True
    if not membership_id:
        membership_id = id_factory("membership")
    if result.get("membership_id") != membership_id:
        result["membership_id"] = membership_id
        changed = True

    providers = dict(
        result.get("provider_identities")
        or identity.get("provider_identities")
        or {}
    )
    github: dict[str, str] = dict(providers.get("github") or {})
    if result.get("github_id") is not None:
        github["subject"] = str(result["github_id"])
    if result.get("github_username"):
        github["username"] = str(result["github_username"])
    if github:
        providers["github"] = github
    if result.get("email"):
        providers.setdefault("email", {"subject": str(result["email"]).lower()})

    next_identity = {
        **identity,
        "schema_version": IDENTITY_SCHEMA,
        "account_id": account_id,
        "actor_id": actor_id,
        "actor_kind": "person",
        "membership_id": membership_id,
        "org_id": org_id,
        "provider_identities": providers,
    }
    if next_identity != identity:
        result["identity"] = next_identity
        result["provider_identities"] = providers
        result["identity_version"] = 2
        changed = True
    return result, changed


def _atomic_json(path: Path, payload: Mapping[str, Any]) -> None:
    if path.is_symlink():
        path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f"{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _atomic_committed_json(path: Path, payload: Mapping[str, Any]) -> None:
    """Atomically update non-secret committed config while retaining its mode."""

    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    descriptor, temporary = tempfile.mkstemp(prefix=f"{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def control_plane_identity_from_records(
    state: Mapping[str, Any],
    organization: Mapping[str, Any],
    roster: Mapping[str, Any],
    *,
    expected_slug: str,
) -> dict[str, str]:
    """Select one existing membership for safe, read-only reconciliation.

    Numeric provider subjects are preferred and never downgraded to mutable
    usernames. The caller may persist the returned IDs only after both records
    came from the authenticated control plane for the configured organization.
    This function never creates an organization, account, actor, or membership.
    """

    org_id = str(organization.get("org_id") or "").strip()
    org_slug = str(organization.get("slug") or "").strip()
    roster_slug = str(roster.get("org_slug") or "").strip()
    roster_org_id = str(roster.get("org_id") or "").strip()
    if not org_id or org_id.startswith("legacy-org:"):
        raise ValueError("control-plane organization identity is unavailable")
    if not expected_slug or org_slug != expected_slug or roster_slug != expected_slug:
        raise ValueError("control-plane identity records belong to another organization")
    if roster_org_id and roster_org_id != org_id:
        raise ValueError("control-plane organization records disagree")

    nested_identity = state.get("identity") or {}
    providers = state.get("provider_identities") or (
        nested_identity.get("provider_identities")
        if isinstance(nested_identity, Mapping)
        else {}
    ) or {}
    github = providers.get("github") if isinstance(providers, Mapping) else None
    provider_subject = ""
    provider_username = ""
    if isinstance(github, Mapping):
        provider_subject = str(github.get("subject") or "").strip()
        provider_username = str(github.get("username") or "").strip().casefold()
    provider_subject = provider_subject or str(state.get("github_id") or "").strip()
    provider_username = provider_username or str(
        state.get("github_username") or ""
    ).strip().casefold()
    if not provider_subject and not provider_username:
        raise ValueError("local identity has no verified provider reference")

    members = roster.get("members")
    if not isinstance(members, list):
        raise ValueError("control-plane membership roster is unavailable")
    matches: list[Mapping[str, Any]] = []
    for member in members:
        if not isinstance(member, Mapping) or member.get("status") != "active":
            continue
        if provider_subject:
            if str(member.get("github_id") or "").strip() == provider_subject:
                matches.append(member)
            continue
        aliases = {
            str(member.get("github_username") or "").strip().casefold(),
            *(
                str(alias).strip().casefold()
                for alias in (member.get("github_aliases") or [])
            ),
        }
        if provider_username in aliases:
            matches.append(member)
    if len(matches) != 1:
        raise ValueError("control-plane membership identity is missing or ambiguous")

    member = matches[0]
    required = {
        "org_id": org_id,
        "account_id": member.get("account_id"),
        "actor_id": member.get("actor_id"),
        "runtime_membership_id": member.get("runtime_membership_id"),
    }
    missing = [key for key, value in required.items() if not str(value or "").strip()]
    if missing:
        raise ValueError(
            "control-plane identity migration is incomplete: " + ", ".join(missing)
        )
    return {
        "status": "ok",
        "membership_status": "active",
        **{key: str(value).strip() for key, value in required.items()},
        **({"verified_github_id": str(member["verified_github_id"])}
           if member.get("verified_github_id") is not None else {}),
    }


def _local_github_subject(state: Mapping[str, Any]) -> str:
    identity = state.get("identity") or {}
    providers = state.get("provider_identities") or identity.get("provider_identities") or {}
    github = providers.get("github") if isinstance(providers, Mapping) else None
    subjects = {
        str(value).strip() for value in (
            state.get("github_id"),
            github.get("subject") if isinstance(github, Mapping) else None,
        ) if value is not None and str(value).strip()
    }
    if len(subjects) != 1:
        return ""
    subject = subjects.pop()
    return subject if re.fullmatch(r"[0-9]+", subject) else ""


def _attribution_ids(state: Mapping[str, Any], org_id: str) -> tuple[str, ...]:
    """Follow same-provider reconciliation history for display/search only."""
    identity = state.get("identity") or {}
    history = identity.get("reconciliation_history") or []
    subject = _local_github_subject(state)
    if not subject or not isinstance(history, list):
        return ()
    reachable = {(str(state["account_id"]), str(state["actor_id"]))}
    references: set[str] = set()
    # Each edge can extend the reachable set once, including repeated connects.
    for _ in range(len(history)):
        before = len(reachable)
        for entry in history:
            if not isinstance(entry, Mapping) or entry.get("verified_github_id") != subject:
                continue
            previous, current = entry.get("previous"), entry.get("current")
            if not isinstance(previous, Mapping) or not isinstance(current, Mapping):
                continue
            if previous.get("org_id") != org_id or current.get("org_id") != org_id:
                continue
            target = (current.get("account_id"), current.get("actor_id"))
            source = (previous.get("account_id"), previous.get("actor_id"))
            if not all(isinstance(value, str) and value for value in (*target, *source)):
                continue
            if target in reachable:
                reachable.add(source)
                references.update(source)
        if len(reachable) == before:
            break
    references.difference_update((str(state["account_id"]), str(state["actor_id"])))
    return tuple(sorted(references))


def reconcile_control_plane_identity(
    root: Path,
    response: Mapping[str, Any],
) -> dict[str, str]:
    """Adopt authoritative Connected IDs without inventing or relinking them.

    The response must come from the authenticated Egregore control plane. Its
    optional verified_github_id must be provider-backed, never a client echo.
    Prior IDs are retained; only a same-org, matching verified provider subject
    connects them for presentation/search. They never become authority aliases.
    Pending question recipients and current thread stewards transfer explicitly
    before the identity swap, only with a matching provider and active membership.
    A legacy or absent local organization id may advance to its returned opaque
    id; a different established opaque id is never silently replaced.
    """

    required = {
        "org_id": response.get("org_id"),
        "account_id": response.get("account_id"),
        "actor_id": response.get("actor_id"),
        "membership_id": response.get("runtime_membership_id")
        or response.get("membership_id"),
    }
    missing = [key for key, value in required.items() if not str(value or "").strip()]
    if response.get("status") != "ok" or missing:
        raise ValueError(
            "control-plane identity response is incomplete: " + ", ".join(missing)
        )
    if response.get("membership_status") not in (None, "active"):
        raise ValueError("control-plane membership is not active; identity was not changed")
    resolved = {key: str(value).strip() for key, value in required.items()}
    root = root.resolve()
    config_path = root / "egregore.json"
    state_path = root / ".egregore-state.json"

    with _identity_lock(state_path):
        config = json.loads(config_path.read_text(encoding="utf-8"))
        current_org = str(config.get("org_id") or "")
        if current_org and not current_org.startswith("legacy-org:") and current_org != resolved["org_id"]:
            raise ValueError("control-plane org_id conflicts with committed organization identity")
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            state = {}
        if not isinstance(state, dict):
            raise ValueError("local identity state must be an object")
        identity = dict(state.get("identity") or {})
        previous = {
            key: str(state.get(key) or identity.get(key) or "").strip()
            for key in ("account_id", "actor_id", "membership_id")
        }
        previous["org_id"] = str(identity.get("org_id") or current_org)
        history = identity.get("reconciliation_history", [])
        if not isinstance(history, list):
            raise ValueError("identity reconciliation history must be a list")
        if any(previous[key] and previous[key] != resolved[key] for key in previous):
            entry: dict[str, Any] = {"previous": previous, "current": dict(resolved)}
            subject = _local_github_subject(state)
            verified = str(response.get("verified_github_id") or "").strip()
            if subject and verified == subject and previous["org_id"] == resolved["org_id"]:
                entry["verified_github_id"] = subject
            # Unproven transitions remain historical records, never aliases.
            identity["reconciliation_history"] = [*history, entry]
        if previous["actor_id"] and previous["actor_id"] != resolved["actor_id"]:
            from .identity_transfer import transfer_local_ownership

            # This runs under the identity lock. Do not let the resolver
            # reacquire it to persist a migration. Only live source identity
            # and this fresh authenticated response may authorize a transfer.
            source = LocalIdentityResolver(root, persist_migrations=False).resolve(
                session_id="identity-transfer", harness="runtime"
            )
            subject = _local_github_subject(state)
            verified = str(response.get("verified_github_id") or "").strip()
            transfer_local_ownership(
                root, source=source, destination=resolved,
                verified_subject=(subject if subject and subject == verified
                                  and previous["org_id"] == resolved["org_id"] else ""),
                destination_active=response.get("membership_status") == "active",
            )
        state.update(resolved)
        if response.get("membership_status") == "active":
            state["membership_status"] = "active"
        providers = dict(
            state.get("provider_identities")
            or identity.get("provider_identities")
            or {}
        )
        state["provider_identities"] = providers
        identity.update(
            {
                "schema_version": IDENTITY_SCHEMA,
                **resolved,
                "actor_kind": identity.get("actor_kind") or "person",
                "provider_identities": providers,
            }
        )
        state["identity"] = identity
        state["identity_version"] = 2
        config = initialize_org_config(config, org_id=resolved["org_id"])
        config["org_id"] = resolved["org_id"]
        _atomic_committed_json(config_path, config)
        _atomic_json(state_path, state)

    _ensure_identity_declaration(root, config)
    return resolved


def initialize_local_instance_identity(root: Path) -> dict[str, str]:
    """Create opaque Local identities once, under the same instance lock.

    Connected instances must reconcile authoritative control-plane ids instead.
    This path exists for legacy Local installs that predate the identity model.
    """

    root = root.resolve()
    config_path = root / "egregore.json"
    state_path = root / ".egregore-state.json"
    with _identity_lock(state_path):
        config = json.loads(config_path.read_text(encoding="utf-8"))
        if str(config.get("mode") or "local") == "connected" or config.get("api_url"):
            raise ValueError(
                "connected identity must be reconciled from the control plane"
            )
        current_org = str(config.get("org_id") or "").strip()
        org_id = (
            current_org
            if current_org and not current_org.startswith("legacy-org:")
            else new_identity_id("org")
        )
        config = initialize_org_config(config, org_id=org_id)
        config["org_id"] = org_id
        _atomic_committed_json(config_path, config)
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            state = {}
        migrated, _ = migrate_local_identity_state(state, org_id=org_id)
        _atomic_json(state_path, migrated)

    _ensure_identity_declaration(root, config)
    return {
        "org_id": org_id,
        "account_id": str(migrated["account_id"]),
        "actor_id": str(migrated["actor_id"]),
        "membership_id": str(migrated["membership_id"]),
    }


def _ensure_identity_declaration(root: Path, config: Mapping[str, Any]) -> None:
    declaration = root / str(config["profile"]["identity_path"])
    if declaration.exists():
        return
    declaration.parent.mkdir(parents=True, exist_ok=True)
    declaration.write_text(
        render_identity_document(
            str(config.get("org_name") or config.get("name") or config.get("slug"))
        ),
        encoding="utf-8",
    )


@contextmanager
def _identity_lock(state_path: Path):
    if state_path.is_symlink():
        state_path = state_path.resolve()
    lock_path = state_path.with_name(f"{state_path.name}.identity.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as handle:
        os.chmod(lock_path, 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


class LocalIdentityResolver:
    """Resolve actor context from committed org config and local user state."""

    def __init__(
        self,
        root: Path | str,
        *,
        persist_migrations: bool = True,
        entitlement_row: Mapping[str, Any] | None = None,
    ) -> None:
        self.root = Path(root)
        self.persist_migrations = persist_migrations
        self.entitlement_row = entitlement_row

    def resolve(self, *, session_id: str, harness: str) -> ActorContext:
        profile = load_profile(self.root / "egregore.json")
        state_path = self.root / ".egregore-state.json"
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except FileNotFoundError as exc:
            raise ValueError(f"local identity state is missing: {state_path}") from exc
        if not isinstance(state, dict):
            raise ValueError(f"local identity state must be an object: {state_path}")

        config = json.loads((self.root / "egregore.json").read_text(encoding="utf-8"))
        id_factory = new_identity_id
        if (
            profile.org_id.startswith("legacy-org:")
            and (str(config.get("mode") or "local") == "connected" or config.get("api_url"))
        ):
            # A pre-migration Connected install must remain usable offline, but
            # it must not mint a new random actor in each detached checkout.
            # These explicitly legacy ids are deterministic compatibility
            # placeholders and are replaced only by control-plane IDs.
            legacy_seed = json.dumps(
                {
                    "org": profile.org_id,
                    "person_id": state.get("person_id"),
                    "github_id": state.get("github_id"),
                    "github_username": state.get("github_username"),
                    "email": state.get("email"),
                },
                sort_keys=True,
                separators=(",", ":"),
            )

            def id_factory(prefix: str) -> str:
                digest = hashlib.sha256(f"{prefix}:{legacy_seed}".encode()).hexdigest()[:24]
                return f"legacy-{prefix}:{digest}"

        migrated, changed = migrate_local_identity_state(
            state, org_id=profile.org_id, id_factory=id_factory
        )
        if changed and self.persist_migrations:
            # First-session races must not mint competing account/actor ids.
            # Re-read after taking the instance lock, then persist once.
            with _identity_lock(state_path):
                current = json.loads(state_path.read_text(encoding="utf-8"))
                if not isinstance(current, dict):
                    raise ValueError(f"local identity state must be an object: {state_path}")
                migrated, changed = migrate_local_identity_state(
                    current, org_id=profile.org_id, id_factory=id_factory
                )
                if changed:
                    _atomic_json(state_path, migrated)

        provider_aliases: dict[str, str] = {}
        for provider, record in (migrated.get("provider_identities") or {}).items():
            if isinstance(record, Mapping) and record.get("subject"):
                provider_aliases[str(provider)] = str(record["subject"])

        display_name = str(
            migrated.get("display_name")
            or migrated.get("github_name")
            or migrated.get("name")
            or "Egregore member"
        )
        account = AccountIdentity(
            account_id=str(migrated["account_id"]),
            display_name=display_name,
            primary_email=migrated.get("email"),
            provider_aliases=provider_aliases,
        )
        aliases = {}
        if migrated.get("person_id"):
            aliases["legacy.person"] = str(migrated["person_id"])
        if migrated.get("github_username"):
            aliases["github.username"] = str(migrated["github_username"])
        actor = actor_identity(
            kind=ActorKind.PERSON,
            actor_id=str(migrated["actor_id"]),
            display_name=display_name,
            account_id=account.account_id,
            aliases=aliases,
            attribution_ids=_attribution_ids(migrated, profile.org_id),
        )

        roles = tuple(
            dict.fromkeys(
                str(value).lower()
                for value in (
                    migrated.get("role") or "member",
                    migrated.get("onboarding", {}).get("role")
                    if isinstance(migrated.get("onboarding"), Mapping)
                    else None,
                )
                if value
            )
        )
        teams_value = migrated.get("teams") or ()
        teams = tuple(str(item) for item in teams_value) if isinstance(teams_value, list) else ()
        membership = OrgMembership(
            membership_id=str(migrated["membership_id"]),
            org_id=profile.org_id,
            actor_id=actor.actor_id,
            roles=roles,
            teams=teams,
            status=str(migrated.get("membership_status") or "active"),
        )
        entitlements = resolve_entitlements(
            mode=str(config.get("mode") or "local"),
            row=self.entitlement_row,
        )
        return ActorContext(
            account=account,
            actor=actor,
            profile=profile,
            membership=membership,
            entitlements=entitlements,
            session_id=session_id,
            harness=harness,
        )
