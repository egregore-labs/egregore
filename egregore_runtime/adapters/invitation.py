"""GitHub and Connected invitation transports for Egregore Runtime."""

from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
from typing import Any, Mapping
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import uuid4

from ..contracts import ActorContext
from ..invitations import InvitationTransportResult
from ..sync import LocalGitSyncTransport


def _json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain an object")
    return value


def _secret(root: Path, name: str) -> str:
    environment = os.environ.get(name, "").strip()
    if environment:
        return environment
    env_path = root / ".env"
    if not env_path.is_file():
        return ""
    prefix = f"{name}="
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith(prefix):
            return line[len(prefix) :].strip()
    return ""


def _request_json(
    url: str,
    *,
    method: str,
    headers: Mapping[str, str],
    payload: Mapping[str, Any] | None = None,
    timeout: float = 15,
) -> tuple[int, dict[str, Any]]:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = Request(url, method=method, headers=dict(headers), data=body)
    try:
        with urlopen(request, timeout=timeout) as response:  # noqa: S310 - fixed/configured APIs
            raw = response.read().decode("utf-8")
            return response.status, json.loads(raw) if raw else {}
    except HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            detail = json.loads(raw)
        except json.JSONDecodeError:
            detail = {"detail": f"HTTP {exc.code}"}
        return exc.code, detail
    except URLError as exc:
        raise OSError(f"invitation transport unavailable: {exc.reason}") from exc


class ShellInvitationTransport:
    """Select Local GitHub or Connected control-plane transport by config."""

    def __init__(self, root: Path | str, *, push_remote: bool = True) -> None:
        self.root = Path(root).resolve()
        self.config = _json(self.root / "egregore.json")
        self.push_remote = push_remote

    def invite(
        self,
        actor: ActorContext,
        *,
        provider: str,
        provider_username: str,
    ) -> InvitationTransportResult:
        if provider != "github":
            raise ValueError("unsupported invitation provider")
        connected = bool(self.config.get("api_url")) or self.config.get("mode") == "connected"
        if connected:
            return self._connected(actor, provider_username)
        return self._local(actor, provider_username)

    def _repos(self) -> tuple[str, ...]:
        memory = str(self.config.get("memory_repo") or "").rstrip("/")
        memory_name = memory.rsplit("/", 1)[-1].removesuffix(".git")
        values: list[str] = [str(self.config.get("repo_name") or ""), memory_name]
        for row in self.config.get("repos") or ():
            values.append(str(row.get("name") if isinstance(row, Mapping) else row))
        return tuple(dict.fromkeys(value for value in values if value))

    def _github_add(self, org: str, repo: str, username: str, token: str) -> int:
        status, _ = _request_json(
            f"https://api.github.com/repos/{org}/{repo}/collaborators/{username}",
            method="PUT",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            payload={"permission": "push"},
        )
        return status

    def _write_stub(
        self, actor: ActorContext, username: str
    ) -> tuple[str, tuple[str, ...]]:
        people = (self.root / "memory" / "people").resolve()
        people.mkdir(parents=True, exist_ok=True)
        target = people / f"{username}.md"
        if target.exists() and "Onboarded:" in target.read_text(encoding="utf-8"):
            return "existing-member", ()
        if not target.exists():
            invite_id = f"invite_{uuid4().hex}"
            text = "\n".join(
                [
                    "---",
                    "schema: egregore-membership-invite/v1",
                    f"invite_id: {invite_id}",
                    f"org_id: {actor.profile.org_id}",
                    "identity_status: invited",
                    "provider: github",
                    f"provider_username: {username}",
                    f"github: {username}",  # compatibility alias for person.sh
                    f"invited_by_actor: {actor.actor.actor_id}",
                    "---",
                    "",
                ]
            )
            descriptor, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=people)
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                    handle.write(text)
                os.replace(temporary, target)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        try:
            sync = LocalGitSyncTransport(
                (self.root / "memory").resolve(), push_remote=self.push_remote
            ).push(message=f"chore(people): invite {username}", paths=(str(target),))
        except Exception as exc:
            return "recorded-unsynced", (f"canonical Git sync: {exc}",)
        return (
            "recorded" if not sync.warnings else "recorded-local",
            tuple(f"canonical Git sync: {warning}" for warning in sync.warnings),
        )

    def _local(self, actor: ActorContext, username: str) -> InvitationTransportResult:
        token = _secret(self.root, "GITHUB_TOKEN")
        if not token:
            raise ValueError("GitHub authentication is required; run bash bin/github-auth.sh")
        org = str(self.config.get("github_org") or "").strip()
        repos = self._repos()
        if not org or not repos:
            raise ValueError("egregore.json must define github_org and repo_name")
        rows: list[Mapping[str, str]] = []
        for repo in repos:
            status = self._github_add(org, repo, username, token)
            rows.append(
                {
                    "repo": repo,
                    "status": "added" if status in {201, 204} else (
                        "already-added" if status == 422 else f"failed-http-{status}"
                    ),
                }
            )
        core = rows[0]["status"]
        successful = core in {"added", "already-added"}
        profile, sync_warnings = (
            self._write_stub(actor, username)
            if successful
            else ("not-recorded", ())
        )
        warnings = tuple(
            f"{row['repo']}: {row['status']}" for row in rows if row["status"].startswith("failed")
        ) + sync_warnings
        repo = str(self.config.get("repo_name"))
        return InvitationTransportResult(
            status="accepted" if successful else "rejected",
            provider_status=core,
            memory_status=profile,
            managed_access=tuple(rows[1:]),
            join_command=f"npx -y create-egregore@latest join {org}/{repo}",
            group_link=str(self.config.get("telegram_group_link") or "") or None,
            manual_access_url=f"https://github.com/{org}/{repo}/settings/access",
            warnings=warnings,
        )

    def _connected(self, actor: ActorContext, username: str) -> InvitationTransportResult:
        api_url = str(self.config.get("api_url") or "").rstrip("/")
        api_key = _secret(self.root, "EGREGORE_API_KEY")
        github_token = _secret(self.root, "GITHUB_TOKEN")
        if not api_url or not api_key or not github_token:
            raise ValueError("Connected invitation requires Egregore and GitHub authentication")
        org = str(self.config.get("github_org") or "")
        repo = str(self.config.get("repo_name") or "")
        status, payload = _request_json(
            f"{api_url}/api/org/invite",
            method="POST",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            payload={
                "github_org": org,
                "github_username": username,
                "repo_name": repo,
                "slug": self.config.get("slug"),
                "github_token": github_token,
            },
        )
        if status >= 400:
            detail = str(payload.get("detail") or f"HTTP {status}")
            return InvitationTransportResult(
                status="rejected",
                provider_status=f"failed-http-{status}",
                memory_status="not-recorded",
                manual_access_url=f"https://github.com/{org}/{repo}/settings/access",
                warnings=(detail,),
            )
        github = payload.get("github_invite") or {}
        memory = payload.get("memory_access") or {}
        return InvitationTransportResult(
            status="accepted",
            provider_status=str(github.get("status") or "unknown"),
            memory_status=str(memory.get("status") or "unknown"),
            managed_access=tuple(payload.get("managed_access") or ()),
            invite_url=str(payload.get("invite_url") or "") or None,
            join_command=str(payload.get("fallback_command") or "") or None,
            group_link=str(payload.get("telegram_group_link") or "") or None,
            manual_access_url=f"https://github.com/{org}/{repo}/settings/access",
        )
