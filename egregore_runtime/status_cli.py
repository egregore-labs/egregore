"""Runtime-neutral CLI for activity and dashboard status snapshots."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .contracts import Capability, Permission
from .runtime import local_runtime
from .status import CanonicalStatusSnapshotService


def _root() -> Path:
    return Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()


def _session_id(root: Path) -> str:
    if os.environ.get("EGREGORE_SESSION_ID"):
        return os.environ["EGREGORE_SESSION_ID"]
    try:
        return (root / ".egregore-session-id").read_text(encoding="utf-8").strip() or "status-shell"
    except OSError:
        return "status-shell"


def _connected_enrichment(root, config, runtime, actor, surface, time_range):
    """Read one optional projection without allowing it to replace canonical state."""

    if not actor.entitlements.has(Capability.CONNECTED_CONTROL_PLANE):
        return {"status": "unavailable", "reason": "capability_missing"}
    decision = runtime.authorize(actor, Permission.READ, ("projection:status",))
    if not decision.allowed:
        return {"status": "unavailable", "reason": "authorization_denied"}
    api_url = str(config.get("api_url") or "").rstrip("/")
    api_key = os.environ.get("EGREGORE_API_KEY", "")
    if not api_key:
        try:
            for line in (root / ".env").read_text(encoding="utf-8").splitlines():
                if line.startswith("EGREGORE_API_KEY="):
                    api_key = line.split("=", 1)[1]
                    break
        except OSError:
            pass
    if not api_url or not api_key:
        return {"status": "unavailable", "reason": "missing_config"}
    aliases = dict(actor.actor.aliases)
    if actor.account is not None:
        aliases.update(actor.account.provider_aliases)
    username = aliases.get("github") or aliases.get("github_username") or actor.actor.display_name
    endpoint = "/api/activity/dashboard" if surface == "activity" else "/api/personal/dashboard"
    query = {"github_username": username}
    if surface == "dashboard":
        query.update({"time_range": time_range, "session_id": actor.session_id})
    request = Request(
        f"{api_url}{endpoint}?{urlencode(query)}",
        headers={"Authorization": f"Bearer {api_key}"},
    )
    try:
        with urlopen(request, timeout=8) as response:  # noqa: S310 - configured control plane
            body = json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        reason = "auth_error" if exc.code in {401, 403} else "server_error"
        return {"status": "offline", "reason": reason}
    except (OSError, URLError, json.JSONDecodeError):
        return {"status": "offline", "reason": "unreachable"}
    return {"status": "connected", "reason": None, "payload": body}


def main() -> int:
    parser = argparse.ArgumentParser(prog="egregore-status")
    parser.add_argument("surface", choices=("activity", "dashboard"))
    parser.add_argument("--time-range", default="P7D", choices=("P1D", "P7D", "P30D", "P365D"))
    parser.add_argument("--connected-enrichment", action="store_true")
    args = parser.parse_args()
    root = _root()
    try:
        config = json.loads((root / "egregore.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        config = {}
    runtime = local_runtime(root, push_remote=False)
    actor = runtime.resolve_actor(session_id=_session_id(root), harness=os.environ.get("EGREGORE_RUNTIME", "shell"))
    payload = CanonicalStatusSnapshotService(runtime, root).build(actor, time_range=args.time_range)
    if args.surface == "dashboard":
        payload["sessions"] = payload["my_sessions"]
    branch = subprocess.run(
        ["git", "-C", str(root), "branch", "--show-current"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip() or "unknown"
    dirty = bool(
        subprocess.run(
            ["git", "-C", str(root), "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
    )
    current_session_id = _session_id(root)
    current = next(
        (row for row in payload["my_sessions"] if row["id"] == current_session_id),
        None,
    ) or {
        "id": current_session_id,
        "status": "active",
        "topic": None,
        "branch": branch,
    }
    time_labels = {
        "P1D": "today",
        "P7D": "last 7 days",
        "P30D": "last 30 days",
        "P365D": "all time",
    }
    mode = str(config.get("mode") or ("connected" if config.get("api_url") else "local"))
    payload.update(
        {
            "surface": args.surface,
            "mode": mode,
            "org": str(config.get("org_name") or actor.profile.name),
            "me": actor.actor.display_name,
            "date": datetime.now().strftime("%b %d"),
            "range_label": time_labels[args.time_range],
            "graph_status": "not_requested",
            "graph_reason": "canonical_runtime_snapshot",
            "current_session": current,
            "git": {"branch": branch, "dirty": dirty},
            "local_sessions": {
                "sessions": payload["my_sessions"],
                "session_count": len(payload["my_sessions"]),
                "my_sessions": payload["my_sessions"],
                "team_sessions": payload["team_sessions"],
            },
            "prs": [],
            "checkins": [],
            "focus_history": [],
            "todos_merged": {
                "activeTodoCount": len(payload["todos"]),
                "blockedCount": sum(row.get("status") == "blocked" for row in payload["todos"]),
                "deferredCount": sum(row.get("status") == "deferred" for row in payload["todos"]),
                "staleBlockedCount": 0,
                "lastCheckinDate": None,
            },
            "knowledge_gap": {"gapCount": 0},
            "orphans": {"orphanCount": 0},
            "trends": {
                "resolution": {"avgDays": 0, "resolved": 0},
                "throughput": {"created": 0, "completed": 0},
                "capture": {"total": 0, "captured": 0},
                "cadence": [],
            },
            "disk": {"handoffs": "", "decisions": ""},
        }
    )
    if args.connected_enrichment:
        enrichment = _connected_enrichment(
            root, config, runtime, actor, args.surface, args.time_range
        )
        payload["connected_enrichment"] = enrichment
        payload["graph_status"] = enrichment["status"]
        payload["graph_reason"] = enrichment.get("reason")
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
