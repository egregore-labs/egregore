"""Conservative reuse of a recent, independently successful PR test run.

No saved result is sufficient by itself. GitHub must attest to the source run,
its repository, source head tree and ancestry, current attempt and successful
jobs. A completion receipt must come from the job that actually ran the tests.
An unavailable or ambiguous proof returns None, so the caller runs its tests.

The injectable API has two methods: json(relative_endpoint) returns decoded
GitHub JSON; artifact_bytes(relative_endpoint, *, max_bytes) returns ZIP bytes.
Only repository-relative REST endpoints constructed here are passed to it.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import io
import json
import os
import re
import selectors
import subprocess
import time
from typing import Any
from urllib.parse import quote
import zipfile


WORKFLOWS = {
    ".github/workflows/tests.yml": "tests",
    ".github/workflows/suite-baseline.yml": "baseline",
    ".github/workflows/runtime-parity.yml": "runtime",
    ".github/workflows/test-api.yml": "api",
    ".github/workflows/shellcheck.yml": "shellcheck",
}
MAX_ARTIFACT_BYTES = 64 * 1024
MAX_CANDIDATES = 20
MAX_JOBS = 400
MAX_LOOKUP_SECONDS = 45
_SHA = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
_REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")


class InvalidProof(ValueError):
    """An existing result is not adequate evidence for skipping tests."""


def _require(value: Any) -> None:
    if not value:
        raise InvalidProof("incomplete CI proof")


def _integer(value: Any) -> bool:
    return type(value) is int and value > 0


def _sha(value: Any) -> bool:
    return isinstance(value, str) and _SHA.fullmatch(value) is not None


def _timestamp(value: Any) -> datetime:
    _require(isinstance(value, str))
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    _require(parsed.tzinfo is not None)
    return parsed.astimezone(timezone.utc)


def _names(value: Any) -> set[str]:
    _require(isinstance(value, list) and 0 < len(value) <= MAX_JOBS)
    _require(all(isinstance(item, str) and 0 < len(item) <= 256 for item in value))
    _require(len(set(value)) == len(value))
    return set(value)


def _object_pairs(pairs: list[tuple[str, Any]]) -> dict:
    result = {}
    for key, value in pairs:
        _require(key not in result)
        result[key] = value
    return result


def _decode(data: bytes) -> Any:
    return json.loads(data.decode("utf-8"), object_pairs_hook=_object_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(InvalidProof()))


def _same_json(left: Any, right: Any) -> bool:
    # JSON distinguishes true from 1; Python's ordinary equality does not.
    return json.dumps(left, sort_keys=True, allow_nan=False) == json.dumps(
        right, sort_keys=True, allow_nan=False)


class GitHubAPI:
    """Small bounded gh adapter; credentials stay in gh's existing environment."""

    def __init__(self) -> None:
        self.deadline = time.monotonic() + MAX_LOOKUP_SECONDS

    def _read(self, endpoint: str, limit: int) -> bytes:
        _require(endpoint.startswith("repos/") and "://" not in endpoint)
        _require(time.monotonic() < self.deadline)
        command = ["gh", "api", "--hostname", "github.com", "--method", "GET",
                   "-H", "Accept: application/vnd.github+json", endpoint]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        chunks = bytearray()
        deadline = min(self.deadline, time.monotonic() + 25)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise InvalidProof("GitHub lookup timed out")
                    chunk = os.read(process.stdout.fileno(), min(8192, limit + 1 - len(chunks)))
                    if not chunk:
                        break
                    chunks.extend(chunk)
                    _require(len(chunks) <= limit)
            _require(process.wait(timeout=max(0.01, deadline - time.monotonic())) == 0)
            return bytes(chunks)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()

    def json(self, endpoint: str) -> Any:
        return _decode(self._read(endpoint, 2 * 1024 * 1024))

    def artifact_bytes(self, endpoint: str, *, max_bytes: int) -> bytes:
        return self._read(endpoint, max_bytes)


def _run_identity(run: dict, repo: str, workflow_path: str, now: datetime,
                  max_age_hours: float) -> tuple[int, int, int, dict]:
    _require(isinstance(run, dict))
    _require(_integer(run.get("id")) and _integer(run.get("run_attempt")))
    _require(run.get("event") == "pull_request" and run.get("status") == "completed")
    _require(run.get("conclusion") == "success")
    path = run.get("path")
    _require(isinstance(path, str) and path.split("@", 1)[0] == workflow_path)
    _require(_sha(run.get("head_sha")) and isinstance(run.get("head_branch"), str)
             and run["head_branch"])
    repository, head_repository = run.get("repository", {}), run.get("head_repository", {})
    _require(repository.get("full_name", "").lower() == repo.lower())
    _require(head_repository.get("full_name", "").lower() == repo.lower())
    repo_id = repository.get("id")
    _require(_integer(repo_id) and head_repository.get("id") == repo_id)
    pulls = run.get("pull_requests")
    _require(isinstance(pulls, list) and len(pulls) == 1 and isinstance(pulls[0], dict))
    pull = pulls[0]
    _require(_integer(pull.get("number")))
    for side in ("base", "head"):
        _require(_sha(pull.get(side, {}).get("sha")))
        _require(pull.get(side, {}).get("repo", {}).get("id") == repo_id)
    _require(pull["head"]["sha"] == run["head_sha"])
    _require(pull["head"].get("ref") == run["head_branch"])
    started, updated = _timestamp(run.get("run_started_at")), _timestamp(run.get("updated_at"))
    _require(now - timedelta(hours=max_age_hours) <= started <= updated <= now)
    return run["id"], run["run_attempt"], repo_id, pull


def _read_plan(api: Any, prefix: str, run: dict, repo_id: int, artifact_name: str) -> dict:
    response = api.json(f"{prefix}/actions/runs/{run['id']}/artifacts?per_page=100")
    _require(isinstance(response, dict) and isinstance(response.get("artifacts"), list))
    artifacts = response["artifacts"]
    _require(type(response.get("total_count")) is int and response["total_count"] == len(artifacts))
    _require(len(artifacts) <= 100)
    matches = [item for item in artifacts if isinstance(item, dict) and item.get("name") == artifact_name]
    _require(len(matches) == 1)
    artifact = matches[0]
    _require(_integer(artifact.get("id")) and artifact.get("expired") is False)
    _require(_integer(artifact.get("size_in_bytes")) and artifact["size_in_bytes"] <= MAX_ARTIFACT_BYTES)
    source = artifact.get("workflow_run", {})
    _require(source.get("id") == run["id"] and source.get("head_sha") == run["head_sha"])
    _require(source.get("repository_id") == repo_id and source.get("head_repository_id") == repo_id)
    _require(_timestamp(run["run_started_at"]) <= _timestamp(artifact.get("created_at"))
             <= _timestamp(run["updated_at"]))
    data = api.artifact_bytes(f"{prefix}/actions/artifacts/{artifact['id']}/zip",
                              max_bytes=MAX_ARTIFACT_BYTES)
    _require(isinstance(data, bytes) and len(data) <= MAX_ARTIFACT_BYTES)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        _require(1 <= len(entries) <= 64)
        _require(sum(entry.file_size for entry in entries) <= MAX_ARTIFACT_BYTES)
        _require(all(entry.file_size >= 0 and not entry.flag_bits & 1 for entry in entries))
        # The uploader sends one file. No path normalization, extraction, extras,
        # symlinks or duplicate names are needed or accepted for a proof.
        _require(len(entries) == 1 and entries[0].filename == "plan.json")
        _require(not entries[0].is_dir())
        mode = entries[0].external_attr >> 16
        _require((mode & 0o170000) in (0, 0o100000))
        with archive.open(entries[0]) as stream:
            content = stream.read(MAX_ARTIFACT_BYTES + 1)
        _require(len(content) <= MAX_ARTIFACT_BYTES)
        plan = _decode(content)
    _require(isinstance(plan, dict))
    return plan


def _source_tree(api: Any, prefix: str, run: dict, pull: dict, tree: str) -> None:
    # An artifact is not authoritative about the checkout it tested. In
    # particular, an arbitrary commit can have genuine parents and a fabricated
    # tree. Bind the source workflow and its scripts to GitHub's run.head_sha,
    # then prove the PR base is already an ancestor. The synthetic merge of an
    # up-to-date branch therefore has that same head tree, without relying on
    # the artifact's claimed checkout commit. Behind/diverged branches rerun.
    head, base = run["head_sha"], pull["base"]["sha"]
    commit = api.json(f"{prefix}/git/commits/{head}")
    _require(isinstance(commit, dict) and commit.get("sha") == head)
    _require(commit.get("tree", {}).get("sha") == tree)
    comparison = api.json(f"{prefix}/compare/{base}...{head}")
    _require(isinstance(comparison, dict) and comparison.get("status") in ("ahead", "identical"))
    _require(comparison.get("base_commit", {}).get("sha") == base)
    _require(comparison.get("merge_base_commit", {}).get("sha") == base)


def _jobs_pass(api: Any, prefix: str, run_id: int, attempt: int, required: set[str]) -> None:
    jobs = []
    total = None
    for page in range(1, MAX_JOBS // 100 + 1):
        response = api.json(f"{prefix}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")
        _require(isinstance(response, dict) and isinstance(response.get("jobs"), list))
        count = response.get("total_count")
        _require(type(count) is int and 0 < count <= MAX_JOBS)
        _require(total is None or total == count)
        total = count
        batch = response["jobs"]
        _require(0 < len(batch) <= 100)
        jobs.extend(batch)
        _require(len(jobs) <= total)
        if len(jobs) == total:
            break
    _require(len(jobs) == total)
    for name in required:
        matches = [job for job in jobs if isinstance(job, dict) and job.get("name") == name]
        _require(len(matches) == 1)
        job = matches[0]
        _require(job.get("run_id") == run_id and job.get("run_attempt") == attempt)
        _require(job.get("status") == "completed" and job.get("conclusion") == "success")
        _require(job.get("completed_at") is not None)


def find_verified_run(*, repo: str, workflow_path: str, tree: str, fingerprint: str,
                      groups: list[str], environment: dict, required_jobs: list[str],
                      now: datetime | None = None, api: Any = None,
                      max_age_hours: float = 6, artifact_name: str | None = None) -> dict | None:
    """Return a verified source receipt, or None so the caller executes tests.

    The caller computes the full checkout tree, policy/workflow fingerprint,
    exact toolchain/image environment and required job names. It must only call
    this for workflows whose inputs are completely represented by that proof.
    Only current-repository PRs already containing their base and with the same
    GitHub-attested head tree can supply evidence. Reused/push/dispatch/fork
    runs and planning-only artifacts cannot. No API response or artifact URL is
    ever followed here.
    """
    try:
        _require(isinstance(repo, str) and _REPO.fullmatch(repo))
        _require(workflow_path in WORKFLOWS and _sha(tree))
        _require(isinstance(fingerprint, str) and 0 < len(fingerprint) <= 256)
        _require(isinstance(environment, dict) and bool(environment))
        _require(type(max_age_hours) in (int, float) and 0 < max_age_hours <= 6)
        wanted_groups, wanted_jobs = _names(groups), _names(required_jobs)
        # Completion receipts belong to one actual owner job. The caller asks
        # separately for each eligible group, never for an aggregate plan.
        _require(len(wanted_groups) == len(wanted_jobs) == 1)
        current_time = now or datetime.now(timezone.utc)
        _require(current_time.tzinfo is not None)
        current_time = current_time.astimezone(timezone.utc)
        artifact_name = artifact_name or "ci-result-" + WORKFLOWS[workflow_path]
        _require(isinstance(artifact_name, str) and re.fullmatch(r"ci-result-[a-z0-9-]+", artifact_name))
        gateway = api if api is not None else GitHubAPI()
        prefix = f"repos/{repo}"
        workflow = quote(workflow_path.rsplit("/", 1)[-1], safe="")
        response = gateway.json(f"{prefix}/actions/workflows/{workflow}/runs?event=pull_request&status=success&per_page={MAX_CANDIDATES}")
        _require(isinstance(response, dict) and isinstance(response.get("workflow_runs"), list))
        for candidate in response["workflow_runs"][:MAX_CANDIDATES]:
            try:
                _require(isinstance(candidate, dict) and _integer(candidate.get("id")))
                # GitHub includes the immutable head tree in the list response.
                # Reject obvious misses without doing dozens of per-run API
                # requests. This is only a prefilter: a potential hit still
                # needs every authoritative source and completion check below.
                _require(candidate.get("head_commit", {}).get("tree_id") == tree)
                started = _timestamp(candidate.get("run_started_at"))
                updated = _timestamp(candidate.get("updated_at"))
                _require(current_time - timedelta(hours=max_age_hours)
                         <= started <= updated <= current_time)
                run = gateway.json(f"{prefix}/actions/runs/{candidate['id']}")
                run_id, attempt, repo_id, pull = _run_identity(
                    run, repo, workflow_path, current_time, max_age_hours)
                _require(run_id == candidate["id"])
                _source_tree(gateway, prefix, run, pull, tree)
                plan = _read_plan(gateway, prefix, run, repo_id, artifact_name)
                _require(type(plan.get("version")) is int and plan["version"] == 1)
                _require(plan.get("workflow_path") == workflow_path and plan.get("tree") == tree)
                _require(plan.get("fingerprint") == fingerprint and _same_json(plan.get("environment"), environment))
                _require(_same_json(plan.get("start_environment"), environment))
                _require(plan.get("execute") is True)
                _require(plan.get("completion") is True)
                _require(type(plan.get("run_id")) is int and plan["run_id"] == run_id)
                _require(type(plan.get("run_attempt")) is int and plan["run_attempt"] == attempt)
                _require(wanted_groups == _names(plan.get("groups")))
                source_jobs = _names(plan.get("required_jobs"))
                _require(wanted_jobs == source_jobs)
                _require(plan.get("owner_job") == next(iter(source_jobs)))
                _require(plan.get("pr_head_sha") == pull["head"]["sha"])
                _require(plan.get("pr_base_sha") == pull["base"]["sha"])
                checkout = plan.get("checkout_sha")
                _require(_sha(checkout))
                commit = gateway.json(f"{prefix}/git/commits/{checkout}")
                _require(isinstance(commit, dict) and commit.get("sha") == checkout)
                _require(commit.get("tree", {}).get("sha") == tree)
                if checkout != pull["head"]["sha"]:
                    parents = commit.get("parents")
                    _require(isinstance(parents, list) and len(parents) == 2)
                    _require(all(isinstance(parent, dict) for parent in parents))
                    _require({parent.get("sha") for parent in parents} == {
                        pull["base"]["sha"], pull["head"]["sha"]})
                _jobs_pass(gateway, prefix, run_id, attempt, source_jobs)
                # An attempt may be re-run while its proof is being fetched.
                # Read the source again after validation before granting reuse.
                latest = gateway.json(f"{prefix}/actions/runs/{run_id}")
                _require(_run_identity(latest, repo, workflow_path, current_time, max_age_hours)
                         == (run_id, attempt, repo_id, pull))
                _require(latest.get("head_sha") == run.get("head_sha"))
                return {"run_id": run_id,
                        "url": f"https://github.com/{repo}/actions/runs/{run_id}/attempts/{attempt}",
                        "reason": "Same tree, CI policy, environment and successful PR test jobs."}
            except (InvalidProof, ValueError, TypeError, KeyError, AttributeError,
                    zipfile.BadZipFile, RuntimeError):
                continue
    except Exception:
        # Reuse is an optimization, never a prerequisite or a successful check.
        # Do not include provider responses (which may contain secrets) in logs.
        return None
    return None
