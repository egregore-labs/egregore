"""Internal bridge for adopting verified control-plane identity responses."""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

from .contracts import Permission
from .identity import (
    control_plane_identity_from_records,
    initialize_local_instance_identity,
    reconcile_control_plane_identity,
)


def _session_id(root: Path) -> str:
    explicit = os.environ.get("EGREGORE_SESSION_ID", "").strip()
    if explicit:
        return explicit
    marker = root / ".egregore-session-id"
    if marker.exists():
        value = marker.read_text(encoding="utf-8").strip()
        if value:
            return value
    return "identity-shell"


def _authorize_self(root: Path, permission: Permission, resource: str) -> int:
    # Import lazily so initialization/reconciliation stays independent from
    # infrastructure composition and can bootstrap a legacy Local instance.
    from .runtime import local_runtime

    runtime = local_runtime(root, push_remote=False)
    actor = runtime.resolve_actor(
        session_id=_session_id(root),
        harness=os.environ.get("EGREGORE_RUNTIME", "identity-shell"),
    )
    decision = runtime.authorize(actor, permission, (resource,))
    print(json.dumps(decision.to_dict(), sort_keys=True))
    if not decision.allowed:
        raise PermissionError("; ".join(decision.reasons) or "identity action denied")
    return 0


def _install_connected_key(root: Path, payload: dict) -> dict[str, str]:
    """Install a membership-verified key without exposing it in output."""

    config = json.loads((root / "egregore.json").read_text(encoding="utf-8"))
    expected_slug = str(config.get("slug") or "").strip()
    returned_slug = str(payload.get("org_slug") or "").strip()
    api_key = str(payload.get("api_key") or "").strip()
    if not expected_slug or returned_slug != expected_slug:
        raise ValueError("recovered credential does not match the configured organization")
    if not api_key or "\n" in api_key or "\r" in api_key:
        raise ValueError("recovered credential is missing or malformed")

    env_path = root / ".env"
    existing = env_path.read_text(encoding="utf-8") if env_path.exists() else ""
    output: list[str] = []
    replaced = False
    for line in existing.splitlines():
        if line.startswith("EGREGORE_API_KEY="):
            if not replaced:
                output.append(f"EGREGORE_API_KEY={api_key}")
                replaced = True
            continue
        output.append(line)
    if not replaced:
        output.append(f"EGREGORE_API_KEY={api_key}")

    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=root,
            prefix=".env.egregore-key.",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            os.chmod(temporary, 0o600)
            handle.write("\n".join(output) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, env_path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)

    return {"org_slug": expected_slug}


def main() -> int:
    root = Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()
    if len(sys.argv) > 1 and sys.argv[1] == "initialize-local":
        result = initialize_local_instance_identity(root)
        print(json.dumps({"status": "initialized", **result}, sort_keys=True))
        return 0
    if len(sys.argv) > 1 and sys.argv[1] == "authorize-self":
        if len(sys.argv) != 4:
            raise ValueError(
                "usage: identity_cli authorize-self {read|administer} RESOURCE"
            )
        permission = Permission(sys.argv[2])
        if permission not in {Permission.READ, Permission.ADMINISTER}:
            raise ValueError("identity self-service permits read or administer only")
        resource = sys.argv[3].strip()
        if not resource.startswith("identity:"):
            raise ValueError("identity resource must use the identity: namespace")
        return _authorize_self(root, permission, resource)
    if len(sys.argv) > 1 and sys.argv[1] == "reconcile-records":
        payload = json.load(sys.stdin)
        config = json.loads((root / "egregore.json").read_text(encoding="utf-8"))
        state = json.loads(
            (root / ".egregore-state.json").read_text(encoding="utf-8")
        )
        response = control_plane_identity_from_records(
            state,
            payload.get("organization") or {},
            payload.get("roster") or {},
            expected_slug=str(config.get("slug") or ""),
        )
        result = reconcile_control_plane_identity(root, response)
        print(json.dumps({"status": "reconciled", **result}, sort_keys=True))
        return 0
    if len(sys.argv) > 1 and sys.argv[1] == "install-connected-key":
        payload = json.load(sys.stdin)
        result = _install_connected_key(root, payload)
        print(json.dumps({"status": "installed", **result}, sort_keys=True))
        return 0
    payload = json.load(sys.stdin)
    result = reconcile_control_plane_identity(root, payload)
    print(json.dumps({"status": "reconciled", **result}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, PermissionError, ValueError, json.JSONDecodeError) as exc:
        print(f"identity reconciliation: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
