"""Configured GitHub issue authority with durable, fail-closed submission receipts."""
from __future__ import annotations

from datetime import UTC, datetime, timedelta
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import urlencode
from uuid import uuid4

from .contracts import Permission
from .policy import allows, action_for
from .issue_markers import artifact_url, issue_request_id, observation_id, request_id

REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/(?!(?:\.|\.\.)$)[A-Za-z0-9_.-]{1,100}")


class GitHubError(OSError):
    def __init__(self, *, rejected=False):
        self.rejected = rejected
        super().__init__("GitHub rejected the request" if rejected else "GitHub response unavailable; reconciliation required")


def gh_api(endpoint, method="GET", payload=None):
    command = ["gh", "api", "--hostname", "github.com", endpoint, "--method", method]
    if payload is not None:
        command += ["--input", "-"]
    try:
        result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                                text=True, capture_output=True, timeout=30, check=False)
    except FileNotFoundError:
        raise GitHubError(rejected=True) from None
    except (OSError, subprocess.TimeoutExpired):
        raise GitHubError() from None
    if result.returncode:
        # gh prints HTTP status without requiring us to expose credential-bearing stderr.
        rejected = result.returncode == 4 or bool(re.search(r"\(HTTP (400|401|403|404|405|410|422|429)\)", result.stderr))
        raise GitHubError(rejected=rejected)
    try:
        return json.loads(result.stdout) if result.stdout.strip() else {}
    except ValueError:
        raise GitHubError() from None


def configured_repo(root):
    cfg = json.loads((root / "egregore.json").read_text()).get("issues", {})
    backend = cfg.get("backend", "canonical")
    if backend == "canonical":
        return None
    if backend != "github" or not REPO.fullmatch(str(cfg.get("repo", ""))):
        raise ValueError("invalid issues backend or repository configuration")
    return cfg["repo"]


def _reject_markers(*values):
    """User text never carries a reserved marker; reconciliation trusts only markers we wrote."""
    for value in values:
        if isinstance(value, str) and "<!-- egregore-" in value:
            raise ValueError("issue text cannot contain reserved Egregore request markers")


class GitHubIssues:
    def __init__(self, root, runtime, actor, repo, api=gh_api):
        if not REPO.fullmatch(repo):
            raise ValueError("invalid GitHub issue repository")
        self.root, self.runtime, self.actor, self.repo, self.api = Path(root), runtime, actor, repo, api
        self.base = f"repos/{repo}/issues"

    def authorize(self, write=False):
        permissions = [Permission.DISCOVER, Permission.READ]
        if write:
            permissions += [Permission.WRITE, Permission.SHARE]
        for permission in permissions:
            decision = self.runtime.authorize(self.actor, permission, (f"github:{self.repo}:issues",))
            if not decision.allowed or not allows(decision, "memory/knowledge/issues/", action_for(decision.permission), root=self.runtime.canonical_root):
                raise PermissionError(f"GitHub issues {permission.value} denied or whole issue namespace not authorized")

    def number(self, reference):
        value = str(reference)
        match = re.fullmatch(rf"https://github\.com/{re.escape(self.repo)}/issues/([1-9][0-9]*)", value, re.I | re.ASCII)
        if match:
            return int(match[1])
        if re.fullmatch(r"#?[1-9][0-9]*", value):
            return int(value.lstrip("#"))
        raise ValueError("issue reference must be a number or URL in the configured repository")

    def pages(self, endpoint):
        page = 1
        while True:
            rows = self.api(f"{endpoint}{'&' if '?' in endpoint else '?'}per_page=100&page={page}")
            if not isinstance(rows, list):
                raise GitHubError()
            yield from rows
            if len(rows) < 100:
                break
            page += 1

    def listing(self, status="open", term=None, limit=10):
        self.authorize()
        rows = [row for row in self.pages(f"{self.base}?state={status}") if "pull_request" not in row]
        if term is not None:
            terms = term.casefold().split()
            rows = [r for r in rows if all(t in (str(r.get("title", "")) + " " + str(r.get("body", ""))).casefold() for t in terms)][:limit]
        return {"issues": rows}

    def duplicates(self, title, description, *, limit=5):
        """Read possible matches from one authorized tracker; never mutate it.

        Fetch a bounded recent issue inventory, then rank locally. Report text
        is not placed in GitHub search queries or sent to an inference provider.
        A limited/indexed search cannot establish that a report is unique.
        """
        self.authorize()
        from .issue_reporting import report_payload
        from .issue_duplicates import rank_candidates

        if type(limit) is not int or not 1 <= limit <= 10:
            raise ValueError("duplicate candidate limit must be between 1 and 10")
        report = report_payload(title, description, public=True)
        rows, seen, totals = [], set(), []
        reasons = set()
        fetched = 0
        for page in range(1, 4):
            # Only fixed qualifiers and the validated configured repository
            # cross the network. PRs do not consume the issue inventory limit.
            query = urlencode({"q": f"repo:{self.repo} is:issue", "sort": "updated",
                               "order": "desc", "per_page": 100, "page": page})
            try:
                response = self.api("search/issues?" + query)
                if (not isinstance(response, dict)
                    or type(response.get("total_count")) is not int
                    or response["total_count"] < 0
                    or type(response.get("incomplete_results")) is not bool
                    or not isinstance(response.get("items"), list)
                    or len(response["items"]) > 100):
                    raise GitHubError()
            except OSError:
                reasons.add("lookup_unavailable")
                break
            totals.append(response["total_count"])
            if response["incomplete_results"]:
                reasons.add("github_incomplete_results")
            items = response["items"]
            fetched += len(items)
            for row in items:
                try:
                    if (not isinstance(row, dict) or "pull_request" in row
                        or type(row.get("number")) is not int
                        or not isinstance(row.get("html_url"), str)
                        or not re.fullmatch(rf"https://github\.com/{re.escape(self.repo)}/issues/[1-9][0-9]*", row["html_url"], re.I | re.ASCII)
                        or self.number(row.get("html_url", "")) != row["number"]
                        or row.get("state") not in {"open", "closed"}
                        or not isinstance(row.get("title"), str)
                        or not row["title"].strip()
                        or (row.get("body") is not None and not isinstance(row["body"], str))
                        or str(row.get("repository_url", f"https://api.github.com/repos/{self.repo}")).lower()
                           != f"https://api.github.com/repos/{self.repo}".lower()):
                        raise ValueError()
                except (ValueError, TypeError):
                    reasons.add("invalid_result_omitted")
                    continue
                if row["number"] in seen:
                    reasons.add("inventory_changed_during_read")
                    continue
                seen.add(row["number"])
                rows.append({**row, "html_url": f"https://github.com/{self.repo}/issues/{row['number']}"})
            if fetched >= response["total_count"] or len(items) < 100:
                break
        if totals:
            if len(set(totals)) > 1:
                reasons.add("inventory_changed_during_read")
            if fetched < max(totals):
                reasons.add("inventory_truncated")
            if fetched > min(totals):
                reasons.add("inventory_changed_during_read")
        status = "partial" if reasons and rows else "unavailable" if reasons else "ok"
        return {
            "schema_version": "egregore-issue-candidates/v1",
            "status": status,
            "repository": self.repo,
            "candidates": rank_candidates(report["title"], report["description"], rows, limit=limit),
            "coverage": {"source": "github_search", "states": ["open", "closed"],
                         "order": "updated_desc", "max_issues": 300,
                         "scanned_issues": len(rows), "reported_total": max(totals) if totals else None,
                         "collection_complete": bool(totals) and not reasons,
                         "index_may_lag": True, "limitations": sorted(reasons)},
            "review_required": True,
            "issue_changed": False,
            "notice": "Possible matches only. Review the issue before choosing a recurrence or a new report. "
                      "No matches does not establish uniqueness; the index may lag and wording may differ.",
        }

    def _issue(self, number):
        row = self.api(f"{self.base}/{number}")
        if not isinstance(row, dict) or "pull_request" in row:
            raise ValueError("reference is not an issue")
        return row

    def show(self, reference):
        self.authorize()
        number = self.number(reference)
        issue = self._issue(number)
        now = datetime.now(UTC)
        seen = set()
        dates = []
        initial = issue_request_id(issue.get("body"))
        if initial:
            seen.add(initial)
        dates.append(datetime.fromisoformat(issue["created_at"].replace("Z", "+00:00")))
        for comment in self.pages(f"{self.base}/{number}/comments"):
            marker = observation_id(comment.get("body"))
            if marker and marker not in seen:
                seen.add(marker)
                dates.append(datetime.fromisoformat(comment["created_at"].replace("Z", "+00:00")))
        issue["observations_7d"] = sum(now - timedelta(days=7) <= date <= now for date in dates)
        issue["last_observed_at"] = max(dates).isoformat()
        return {"issue": issue}

    def change_state(self, reference, state, reason):
        self.authorize(write=True)
        number = self.number(reference)
        self._issue(number)
        if not reason or not reason.strip():
            raise ValueError("record the check, result and build/environment in --reason")
        _reject_markers(reason)
        # Evidence is posted through the same durable contract, before state mutation.
        self.submit("evidence", {"number": number, "body": f"{state.title()} check: {reason.strip()}"})
        issue = self.api(f"{self.base}/{number}", "PATCH", {"state": state})
        return {"issue": issue}

    def create(self, args):
        self.authorize(write=True)
        if not args.title.strip() or not args.description.strip():
            raise ValueError("title and description are required")
        _reject_markers(args.title, args.description, args.context, args.suggested_fix)
        body = args.description.strip()
        for label, value in [("Context", args.context), ("Suggested fix", args.suggested_fix)]:
            if value:
                body += f"\n\n## {label}\n{value.strip()}"
        if args.artifact:
            body += f"\n\nEgregore artifact: {artifact_url(args.artifact)}"
        payload = {"title": args.title.strip(), "body": body,
                   "labels": [f"kind:{args.kind}", f"area:{args.area}", f"severity:{args.severity}"]}
        return self.submit("create", payload, args.request_id, args.draft)

    def repeat(self, args):
        self.authorize(write=True)
        number = self.number(args.reference)
        if not args.description.strip():
            raise ValueError("observation description is required")
        _reject_markers(args.description, args.environment)
        payload = {"number": number, "description": args.description.strip(), "environment": args.environment or ""}
        return self.submit("repeat", payload, args.request_id, args.draft)

    @staticmethod
    def _save(path, state):
        temporary = path.with_suffix(".tmp")
        with open(temporary, "w", encoding="utf-8", opener=lambda p, f: os.open(p, f, 0o600)) as stream:
            json.dump(state, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

    def submit(self, operation, payload, identifier=None, draft=False):
        self.authorize(write=True)
        if operation not in {"create", "repeat", "evidence"}:
            raise ValueError("unsupported GitHub issue submission operation")
        if operation != "create":
            self.number(payload["number"])
        identifier = request_id(identifier or str(uuid4()))
        binding = {"actor": self.actor.actor.actor_id, "repo": self.repo.lower(), "operation": operation, "payload": payload}
        digest = hashlib.sha256(json.dumps(binding, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        directory = self.root / ".egregore/runtime/issues/requests"
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = directory / f"{identifier}.json"
        with open(directory / f"{identifier}.lock", "a", opener=lambda p, f: os.open(p, f, 0o600)) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if path.exists():
                state = json.loads(path.read_text())
                if state["digest"] != digest:
                    raise ValueError("request ID is bound to a different actor, repository or payload")
            else:
                state = {**binding, "digest": digest, "request_id": identifier, "status": "draft", "created_at": datetime.now(UTC).isoformat()}
                self._save(path, state)
            if state["status"] == "submitted" or draft:
                return state
            if state["status"] in {"submitting", "uncertain"}:
                endpoint = f"{self.base}?state=all" if operation == "create" else f"{self.base}/{payload['number']}/comments"
                recognizer = observation_id if operation == "repeat" else issue_request_id
                for row in self.pages(endpoint):
                    if "pull_request" not in row and recognizer(row.get("body")) == identifier:
                        self._complete(path, state, row)
                        return state
                raise ValueError(f"request {identifier} needs reconciliation; no repeat POST is safe (draft: {path})")
            if operation == "repeat" and self._issue(payload["number"]).get("state") != "open":
                raise ValueError("issue is closed; explicitly reopen it before recording another observation")
            body = payload.get("body", "")
            if operation == "repeat":
                body = f"Observed again · {state['created_at']}\nActor: {binding['actor']}\nEnvironment: {payload['environment']}\n\n{payload['description']}"
            marker_kind = "observation" if operation == "repeat" else "issue"
            body += f"\n\n<!-- egregore-{marker_kind}:v1 request={identifier} -->"
            endpoint = self.base if operation == "create" else f"{self.base}/{payload['number']}/comments"
            outbound = {**payload, "body": body} if operation == "create" else {"body": body}
            state["status"] = "submitting"
            self._save(path, state)
            try:
                result = self.api(endpoint, "POST", outbound)
                self._complete(path, state, result)
            except (OSError, ValueError, TypeError, KeyError) as exc:
                state["status"] = "rejected" if isinstance(exc, GitHubError) and exc.rejected else "uncertain"
                self._save(path, state)
                raise ValueError(f"request {identifier}: {state['status']}; retry with the same --request-id (draft: {path})") from None
            return state

    def _complete(self, path, state, result):
        if not isinstance(result, dict):
            raise ValueError("GitHub did not return an issue object")
        url = result.get("html_url", "")
        pattern = rf"https://github\.com/{re.escape(self.repo)}/issues/[1-9][0-9]*(?:#issuecomment-[0-9]+)?"
        if not re.fullmatch(pattern, url, re.I):
            raise ValueError("GitHub did not return a valid issue URL")
        state.update(status="submitted", github_url=url)
        self._save(path, state)
