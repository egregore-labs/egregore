"""Runtime-neutral CLI for canonical issues and explicit external sharing."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from uuid import uuid4

from .contracts import Permission
from .issues import CanonicalIssueService, IssueSnapshot
from .policy import scope_allows_path
from .runtime import local_runtime


SHARE_CONSENT_SECONDS = 600


def _context():
    root = Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()
    runtime = local_runtime(root, push_remote=os.environ.get("EGREGORE_NO_PUSH") != "1")
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID", f"session_{uuid4().hex}"),
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    service = CanonicalIssueService(
        memory_root=(root / "memory").resolve(),
        write_document=runtime.write_document,
    )
    return root, runtime, actor, service


def _require(runtime, actor, permission: Permission, *resources: str):
    decision = runtime.authorize(actor, permission, tuple(resources))
    if not decision.allowed:
        raise PermissionError(
            "; ".join(decision.reasons) or f"issue {permission.value} denied"
        )
    return decision


def _require_issue_path(runtime, actor, permission: Permission, issue: IssueSnapshot):
    decision = _require(
        runtime, actor, permission, issue.document.artifact.artifact_id
    )
    if not scope_allows_path(f"memory/{issue.canonical_path}", decision.scopes):
        raise PermissionError("issue path is outside the actor's authorized scope")
    return decision


def _snapshot(runtime, actor, service, permission: Permission = Permission.READ):
    _require(runtime, actor, Permission.DISCOVER, "issues")
    decision = _require(runtime, actor, permission, "issues")
    return service.snapshot(actor, authorized_scopes=decision.scopes), decision


def _resolve(runtime, actor, service, reference: str) -> IssueSnapshot:
    rows, _ = _snapshot(runtime, actor, service)
    return service.resolve(rows, reference)


def _write_result(issue: IssueSnapshot, receipt) -> int:
    print(json.dumps({"issue": issue.to_dict(), "writeback": receipt.to_dict()}, ensure_ascii=False))
    return 0 if receipt.status.value in {"accepted", "partial"} else 1


def _list(args):
    _, runtime, actor, service = _context()
    rows, _ = _snapshot(runtime, actor, service)
    selected = rows if args.status == "all" else tuple(
        row for row in rows if row.status == args.status
    )
    print(json.dumps({"issues": [row.to_dict() for row in selected]}, ensure_ascii=False))
    return 0


def _show(args):
    _, runtime, actor, service = _context()
    issue = _resolve(runtime, actor, service, args.reference)
    print(json.dumps({"issue": issue.to_dict(include_body=True)}, ensure_ascii=False))
    return 0


def _search(args):
    _, runtime, actor, service = _context()
    rows, _ = _snapshot(runtime, actor, service)
    terms = tuple(part for part in args.term.casefold().split() if part)

    def matches(row: IssueSnapshot) -> bool:
        haystack = " ".join((row.issue_id, row.title, row.body, *row.topics)).casefold()
        return all(term in haystack for term in terms)

    selected = [row.to_dict() for row in rows if matches(row)][: args.limit]
    print(json.dumps({"issues": selected}, ensure_ascii=False))
    return 0


def _create(args):
    _, runtime, actor, service = _context()
    date = datetime.now(UTC).date().isoformat()
    prospective = f"memory/knowledge/issues/{date}-{args.title}.md"
    decision = _require(runtime, actor, Permission.WRITE, "issues:new")
    if not scope_allows_path(prospective, decision.scopes):
        # Policies commonly authorize the directory rather than a pre-slugged
        # filename; test the canonical directory as the stable resource.
        if not scope_allows_path("memory/knowledge/issues/", decision.scopes):
            raise PermissionError("issue path is outside the actor's authorized scope")
    issue, receipt = service.create(
        actor,
        title=args.title,
        description=args.description,
        recipient=args.recipient,
        topics=args.topic,
        context=args.context,
        suggested_fix=args.suggested_fix,
    )
    return _write_result(issue, receipt)


def _close(args):
    _, runtime, actor, service = _context()
    issue = _resolve(runtime, actor, service, args.reference)
    _require_issue_path(runtime, actor, Permission.WRITE, issue)
    closed, receipt = service.close(actor, issue, reason=args.reason)
    return _write_result(closed, receipt)


def _share_state_path(root: Path) -> Path:
    return root / ".egregore" / "runtime" / "issues" / "share-consent.json"


def _share_payload(issue: IssueSnapshot, *, action: str, repo: str | None) -> dict[str, str]:
    if action == "create":
        if not repo or "/" not in repo:
            raise ValueError("GitHub create requires --repo owner/name")
        return {
            "action": "create",
            "destination": f"github:{repo}",
            "artifact_id": issue.document.artifact.artifact_id,
            "title": issue.title,
            "body": issue.body.rstrip(),
        }
    if not issue.github_url:
        raise ValueError("canonical issue has no linked GitHub issue")
    return {
        "action": "close",
        "destination": issue.github_url,
        "artifact_id": issue.document.artifact.artifact_id,
        "title": issue.title,
        "body": "Close the linked GitHub issue.",
    }


def _payload_hash(payload: dict[str, str]) -> str:
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _share_preview(args):
    root, runtime, actor, service = _context()
    issue = _resolve(runtime, actor, service, args.reference)
    _require_issue_path(runtime, actor, Permission.SHARE, issue)
    payload = _share_payload(issue, action=args.action, repo=args.repo)
    now = datetime.now(UTC)
    token = secrets.token_hex(24)
    state = {
        "token_hash": hashlib.sha256(token.encode("utf-8")).hexdigest(),
        "payload_hash": _payload_hash(payload),
        "expires_at": (now + timedelta(seconds=SHARE_CONSENT_SECONDS)).isoformat(),
        "payload": payload,
    }
    path = _share_state_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    path.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass
    print(json.dumps({
        "share_preview": payload,
        "confirmation_token": token,
        "expires_at": state["expires_at"],
        "notice": "No external action has occurred. Confirm this exact unchanged payload separately.",
    }, ensure_ascii=False))
    return 0


def _confirmed_payload(root: Path, token: str) -> dict[str, str]:
    path = _share_state_path(root)
    if not path.is_file():
        raise PermissionError("share preview is missing; prepare a new preview")
    state = json.loads(path.read_text(encoding="utf-8"))
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    if not secrets.compare_digest(str(state.get("token_hash") or ""), token_hash):
        raise PermissionError("share confirmation token is invalid")
    expires = datetime.fromisoformat(str(state["expires_at"]).replace("Z", "+00:00"))
    if datetime.now(UTC) > expires:
        raise PermissionError("share confirmation expired; prepare a new preview")
    payload = state.get("payload")
    if not isinstance(payload, dict) or _payload_hash(payload) != state.get("payload_hash"):
        raise PermissionError("share payload changed; prepare a new preview")
    return {str(key): str(value) for key, value in payload.items()}


def _share_confirm(args):
    root, runtime, actor, service = _context()
    payload = _confirmed_payload(root, args.confirm)
    issue = _resolve(runtime, actor, service, payload["artifact_id"])
    _require_issue_path(runtime, actor, Permission.SHARE, issue)
    if payload["action"] == "create":
        # Do not perform the external action unless its canonical provenance
        # link can also be recorded after GitHub succeeds.
        _require_issue_path(runtime, actor, Permission.WRITE, issue)
    # Rebuild from current canonical state so the consent cannot outlive a
    # changed title/body/link.
    repo = payload["destination"].removeprefix("github:") if payload["action"] == "create" else None
    current = _share_payload(issue, action=payload["action"], repo=repo)
    if _payload_hash(current) != _payload_hash(payload):
        raise PermissionError("canonical issue changed; prepare a new share preview")
    if payload["action"] == "create":
        command = [
            "gh", "issue", "create", "--repo", repo or "",
            "--title", payload["title"], "--body", payload["body"],
        ]
    else:
        command = ["gh", "issue", "close", payload["destination"]]
    result = subprocess.run(command, check=False, text=True, capture_output=True)
    if result.returncode != 0:
        raise OSError(result.stderr.strip() or "GitHub issue action failed")
    output = result.stdout.strip()
    receipt = None
    if payload["action"] == "create":
        github_url = next(
            (line.strip() for line in output.splitlines() if line.strip().startswith("https://github.com/")),
            output,
        )
        issue, receipt = service.link_github(actor, issue, github_url)
    _share_state_path(root).unlink(missing_ok=True)
    response: dict[str, object] = {
        "shared": True,
        "action": payload["action"],
        "destination": payload["destination"],
        "github_output": output,
        "issue": issue.to_dict(),
    }
    if receipt is not None:
        response["writeback"] = receipt.to_dict()
    print(json.dumps(response, ensure_ascii=False))
    return 0


def _parser():
    parser = argparse.ArgumentParser(prog="egregore-issue")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list")
    listing.add_argument("--status", choices=("open", "closed", "all"), default="open")
    listing.set_defaults(handler=_list)
    show = commands.add_parser("show")
    show.add_argument("reference")
    show.set_defaults(handler=_show)
    search = commands.add_parser("search")
    search.add_argument("term")
    search.add_argument("--limit", type=int, default=10)
    search.set_defaults(handler=_search)
    duplicates = commands.add_parser("duplicates", help="Find possible existing issues without changing them")
    duplicates.add_argument("--title", required=True)
    duplicates.add_argument("--description", required=True)
    duplicates.add_argument("--limit", type=int, default=5)
    readiness = commands.add_parser("readiness", help="Inspect local issue-pilot setup without network access")
    readiness.add_argument("--harness", choices=("claude", "codex", "pi", "prime"))
    triage = commands.add_parser("triage", help="Suggest classifications for selected report text without changing an issue")
    triage.add_argument("--title", required=True)
    triage.add_argument("--description", required=True)
    triage.add_argument("--environment")
    triage.add_argument("--evidence")
    triage.add_argument("--kind", choices=("bug", "improvement", "question"))
    triage.add_argument("--area", choices=("runtime", "onboarding", "connectors", "site", "other"))
    triage.add_argument("--severity", choices=("critical", "high", "normal"))
    triage.add_argument("--preview", action="store_true", help="Show the exact scrubbed provider input without sending it")
    create = commands.add_parser("create")
    create.add_argument("--title", required=True)
    create.add_argument("--description", required=True)
    create.add_argument("--recipient", default="just memory")
    create.add_argument("--topic", action="append", default=[])
    create.add_argument("--context")
    create.add_argument("--suggested-fix")
    create.add_argument("--kind", choices=("bug", "improvement", "question"), default="bug")
    create.add_argument("--area", choices=("runtime", "onboarding", "connectors", "site", "other"), default="other")
    create.add_argument("--severity", choices=("critical", "high", "normal"), default="normal")
    create.add_argument("--artifact")
    create.add_argument("--request-id")
    create.add_argument("--draft", action="store_true")
    create.set_defaults(handler=_create)
    close = commands.add_parser("close")
    close.add_argument("reference")
    close.add_argument("--reason")
    close.set_defaults(handler=_close)
    reopen = commands.add_parser("reopen")
    reopen.add_argument("reference")
    reopen.add_argument("--reason", required=True)
    repeat = commands.add_parser("repeat")
    repeat.add_argument("reference")
    repeat.add_argument("--description", required=True)
    repeat.add_argument("--environment")
    repeat.add_argument("--request-id")
    repeat.add_argument("--draft", action="store_true")
    for route in ("report", "upstream"):
        reporting = commands.add_parser(route)
        reporting.add_argument("--title")
        reporting.add_argument("--description")
        reporting.add_argument("--environment")
        reporting.add_argument("--evidence")
        reporting.add_argument("--kind", choices=("bug", "improvement", "question"))
        reporting.add_argument("--area", choices=("runtime", "onboarding", "connectors", "site", "other"))
        reporting.add_argument("--severity", choices=("critical", "high", "normal"))
        reporting.add_argument("--confirm")
    report_status = commands.add_parser("report-status")
    report_status.add_argument("request_id")
    preview = commands.add_parser("share-preview")
    preview.add_argument("reference")
    preview.add_argument("--action", choices=("create", "close"), default="create")
    preview.add_argument("--repo")
    preview.set_defaults(handler=_share_preview)
    confirm = commands.add_parser("share-github")
    confirm.add_argument("--confirm", required=True)
    confirm.set_defaults(handler=_share_confirm)
    return parser


def main() -> int:
    args = _parser().parse_args()
    if args.command == "readiness":
        from .issue_readiness import inspect_issue_readiness
        root = Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()
        print(json.dumps(inspect_issue_readiness(root, harness=args.harness), ensure_ascii=False))
        return 0
    from .github_issues import GitHubIssues, configured_repo
    root = Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()
    if args.command == "triage":
        from .issue_triage_service import IssueTriage
        root, runtime, actor, _ = _context()
        result = IssueTriage(root, runtime, actor).run(
            args.title, args.description, environment=args.environment, evidence=args.evidence,
            kind=args.kind, area=args.area, severity=args.severity, preview=args.preview,
        )
        print(json.dumps(result, ensure_ascii=False))
        return 0
    if args.command in {"report", "upstream", "report-status"}:
        from .issue_reporting import FrameworkReporting, report_payload
        root, runtime, actor, _ = _context()
        reporting = FrameworkReporting(root, runtime, actor)
        if args.command == "report-status":
            result = reporting.status(args.request_id)
        elif args.confirm:
            if any(getattr(args, key) is not None for key in ("title", "description", "kind", "area", "severity", "environment", "evidence")):
                raise ValueError("confirmation accepts only the saved request ID; prepare a new preview to edit")
            result = reporting.confirm(args.command, args.confirm)
        else:
            payload = report_payload(args.title, args.description, args.kind or "bug", args.area or "other", args.severity or "normal", public=args.command == "upstream", environment=args.environment, evidence=args.evidence)
            result = reporting.prepare(args.command, payload)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    repo = configured_repo(root)
    if repo:
        root, runtime, actor, _ = _context()
        service = GitHubIssues(root, runtime, actor, repo)
        if args.command == "list":
            result = service.listing(args.status)
        elif args.command == "search":
            result = service.listing("all", args.term, args.limit)
        elif args.command == "duplicates":
            result = service.duplicates(args.title, args.description, limit=args.limit)
        elif args.command == "show":
            result = service.show(args.reference)
        elif args.command == "create":
            result = service.create(args)
        elif args.command == "repeat":
            result = service.repeat(args)
        elif args.command in {"close", "reopen"}:
            result = service.change_state(args.reference, "closed" if args.command == "close" else "open", args.reason)
        else:
            raise ValueError("the configured GitHub tracker uses create/close directly; share-github is only for canonical issues")
        print(json.dumps(result, ensure_ascii=False))
        return 0
    if args.command in {"reopen", "repeat", "duplicates"} or getattr(args, "draft", False) or getattr(args, "request_id", None) or getattr(args, "artifact", None):
        raise ValueError("this operation requires a configured GitHub issue backend")
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, PermissionError, ValueError) as exc:
        print(f"issue: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
