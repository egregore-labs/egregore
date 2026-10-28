"""Small resumable onboarding model and authorized state service."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any, Mapping

from .contracts import ActorContext, Permission, Serializable
from .errors import AuthorizationDenied


ONBOARDING_SCHEMA = "egregore-onboarding/v1"


@dataclass(frozen=True, slots=True)
class OnboardingStep:
    step_id: str
    required_fields: tuple[str, ...]
    next_step: str | None = None
    branches: Mapping[str, str] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class OnboardingPlan:
    schema_version: str
    intent: str
    org_type: str
    start_step: str
    steps: tuple[OnboardingStep, ...]

    def step(self, step_id: str) -> OnboardingStep:
        for item in self.steps:
            if item.step_id == step_id:
                return item
        raise KeyError(step_id)

    def advance(self, step_id: str, *, choice: str | None = None) -> str | None:
        current = self.step(step_id)
        if choice is not None and choice in current.branches:
            return current.branches[choice]
        return current.next_step


def onboarding_plan(*, intent: str = "collaborate", org_type: str = "team") -> OnboardingPlan:
    """Return today's short flow represented as an evolvable decision tree."""

    normalized_intent = intent.strip().lower() or "collaborate"
    normalized_type = org_type.strip().lower() or "team"
    return OnboardingPlan(
        schema_version=ONBOARDING_SCHEMA,
        intent=normalized_intent,
        org_type=normalized_type,
        start_step="identity",
        steps=(
            OnboardingStep("identity", ("display_name",), next_step="organization"),
            OnboardingStep(
                "organization",
                ("org_name", "org_type", "intent"),
                next_step="role",
            ),
            OnboardingStep("role", ("member_role",), next_step="workspace"),
            OnboardingStep(
                "workspace",
                ("runtime",),
                branches={"founder": "invite", "joiner": "complete"},
                next_step="complete",
            ),
            OnboardingStep("invite", (), next_step="complete"),
            OnboardingStep("complete", (), next_step=None),
        ),
    )


@dataclass(frozen=True, slots=True)
class OnboardingSnapshot(Serializable):
    schema_version: str
    phase: str
    complete: bool
    mode: str
    usage_type: str
    display_name: str | None
    member_role: str | None
    profile_fields_collected: tuple[str, ...]
    invite_skipped: bool | None
    installer_captured: bool
    invite_handled_by: str | None
    profile_witness: bool
    ready: bool
    blockers: tuple[str, ...]


class OnboardingService:
    """Own resumable onboarding state behind ActorContext authorization."""

    LEGACY_PHASES = frozenset(
        {"welcome", "harvest_identity", "harvest_connection", "consent", "first_todo"}
    )

    def __init__(self, root: Path | str, runtime) -> None:
        self.root = Path(root).resolve()
        self.runtime = runtime
        self.state_path = self.root / ".egregore-state.json"

    def _authorize(self, actor: ActorContext, permission: Permission) -> None:
        resource = f"identity:onboarding:{actor.actor.actor_id}"
        decision = self.runtime.authorize(actor, permission, (resource,))
        if not decision.allowed:
            raise AuthorizationDenied("; ".join(decision.reasons))

    def _load(self) -> dict[str, Any]:
        try:
            value = json.loads(self.state_path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            value = {}
        if not isinstance(value, dict):
            raise ValueError("onboarding state must contain an object")
        return value

    def _write(self, state: Mapping[str, Any]) -> None:
        target = self.state_path.resolve() if self.state_path.is_symlink() else self.state_path
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=f"{target.name}.", dir=target.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(dict(state), handle, ensure_ascii=False, indent=2)
                handle.write("\n")
            os.chmod(temporary, 0o600)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    @staticmethod
    def _fields(state: Mapping[str, Any]) -> list[str]:
        values = state.get("profile_fields_collected") or []
        return [str(value) for value in values if str(value)] if isinstance(values, list) else []

    def _has_secret(self, name: str) -> bool:
        if os.environ.get(name, "").strip():
            return True
        env_path = self.root / ".env"
        if not env_path.is_file():
            return False
        prefix = f"{name}="
        return any(
            line.startswith(prefix) and bool(line[len(prefix) :].strip())
            for line in env_path.read_text(encoding="utf-8").splitlines()
        )

    def _migrate(self, state: dict[str, Any]) -> tuple[dict[str, Any], bool]:
        onboarding = dict(state.get("onboarding") or {})
        phase = str(onboarding.get("phase") or "verify")
        changed = False
        if phase in self.LEGACY_PHASES:
            onboarding["phase"] = "invite" if state.get("display_name") else "orient"
            fields = self._fields(state)
            if state.get("display_name") and "name" not in fields:
                fields.append("name")
            state["profile_fields_collected"] = fields
            changed = True
        if onboarding.get("schema_version") != ONBOARDING_SCHEMA:
            onboarding["schema_version"] = ONBOARDING_SCHEMA
            changed = True
        state["onboarding"] = onboarding
        return state, changed

    def snapshot(self, actor: ActorContext) -> OnboardingSnapshot:
        self._authorize(actor, Permission.READ)
        # Reads may normalize legacy phases in the returned view, but only an
        # ADMINISTER-authorized mutation is allowed to persist that migration.
        state, _ = self._migrate(self._load())
        config = json.loads((self.root / "egregore.json").read_text(encoding="utf-8"))
        onboarding = dict(state.get("onboarding") or {})
        username = str(state.get("github_username") or "")
        profile = self.root / "memory" / "people" / f"{username}.md"
        profile_lines = (
            profile.read_text(encoding="utf-8").splitlines() if profile.is_file() else []
        )
        witness = bool(profile_lines) and (
            profile_lines[0].startswith("# ")
            or any(line.startswith("Onboarded:") for line in profile_lines)
        )
        connected = bool(config.get("api_url")) or config.get("mode") == "connected"
        blockers: list[str] = []
        if not (self.root / "memory").exists():
            blockers.append("shared memory is unavailable; run the normal Egregore sync")
        if not self._has_secret("GITHUB_TOKEN"):
            blockers.append("GitHub authentication is missing; run bash bin/github-auth.sh")
        if connected and not self._has_secret("EGREGORE_API_KEY"):
            blockers.append("Connected authentication is missing")
        return OnboardingSnapshot(
            schema_version=ONBOARDING_SCHEMA,
            phase=str(onboarding.get("phase") or "verify"),
            complete=bool(state.get("onboarding_complete")),
            mode=(
                "connected"
                if connected
                else "local"
            ),
            usage_type=str(state.get("usage_type") or "joiner_group"),
            display_name=str(state.get("display_name")) if state.get("display_name") else None,
            member_role=str(state.get("member_role")) if state.get("member_role") else None,
            profile_fields_collected=tuple(self._fields(state)),
            invite_skipped=(
                bool(onboarding["invite_skipped"])
                if "invite_skipped" in onboarding else None
            ),
            installer_captured=bool(onboarding.get("installer_captured")),
            invite_handled_by=(
                str(onboarding["invite_handled_by"])
                if onboarding.get("invite_handled_by") else None
            ),
            profile_witness=witness,
            ready=not blockers,
            blockers=tuple(blockers),
        )

    def set_name(self, actor: ActorContext, display_name: str) -> OnboardingSnapshot:
        self._authorize(actor, Permission.ADMINISTER)
        name = display_name.strip()
        if not 1 <= len(name) <= 30 or not re.fullmatch(r"[\w -]+", name, re.UNICODE):
            raise ValueError("display name must be 1-30 letters, numbers, spaces, or hyphens")
        state, _ = self._migrate(self._load())
        onboarding = dict(state.get("onboarding") or {})
        onboarding.update(
            {
                "phase": "invite",
                "started_at": onboarding.get("started_at")
                or datetime.now(UTC).isoformat().replace("+00:00", "Z"),
            }
        )
        fields = self._fields(state)
        if "name" not in fields:
            fields.append("name")
        state.update(
            {
                "display_name": name,
                "name": re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", name.lower())).strip("-"),
                "profile_fields_collected": fields,
                "onboarding": onboarding,
            }
        )
        self._write(state)
        return self.snapshot(actor)

    def set_role(self, actor: ActorContext, role: str) -> OnboardingSnapshot:
        self._authorize(actor, Permission.ADMINISTER)
        value = role.strip()
        if not 1 <= len(value) <= 80:
            raise ValueError("member role must be 1-80 characters")
        state, _ = self._migrate(self._load())
        fields = self._fields(state)
        if "role" not in fields:
            fields.append("role")
        state["member_role"] = value
        state["profile_fields_collected"] = fields
        self._write(state)
        return self.snapshot(actor)

    def record_invite(self, actor: ActorContext, *, skipped: bool) -> OnboardingSnapshot:
        self._authorize(actor, Permission.ADMINISTER)
        state, _ = self._migrate(self._load())
        onboarding = dict(state.get("onboarding") or {})
        onboarding.update({"phase": "invite", "invite_skipped": skipped})
        state["onboarding"] = onboarding
        self._write(state)
        return self.snapshot(actor)

    def complete(self, actor: ActorContext, *, profile_witness: bool) -> OnboardingSnapshot:
        self._authorize(actor, Permission.ADMINISTER)
        if not profile_witness:
            raise ValueError("canonical person profile witness is missing")
        state, _ = self._migrate(self._load())
        onboarding = dict(state.get("onboarding") or {})
        onboarding.update(
            {
                "phase": "complete",
                "completed_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
            }
        )
        state["onboarding"] = onboarding
        state["onboarding_complete"] = True
        self._write(state)
        return self.snapshot(actor)
