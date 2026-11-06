"""Local, non-mutating prerequisites for the Curve Labs source-checkout pilot.

This is inventory, not authorization or an end-to-end health check. It never
initializes Runtime, launches a harness, or contacts GitHub or the advisor.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from .issue_triage import DEFAULT_MODEL
from .issue_triage_service import triage_credential
from .profile import PROFILE_SCHEMA


SCHEMA_VERSION = "egregore-issue-readiness/v1"
TRACKER = "Curve-Labs/egregore"
SHARED_PATHS = (
    ".claude/skills/issue/SKILL.md",
    "bin/issue.sh", "egregore_runtime/issue_cli.py",
    "egregore_runtime/github_issues.py", "egregore_runtime/issue_reporting.py",
    "egregore_runtime/issue_triage.py", "egregore_runtime/issue_triage_service.py",
)
HARNESS_PATHS = {
    "claude-code": (".claude/settings.json", ".claude/skills/issue/SKILL.md", "bin/session-start.sh"),
    "codex": ("AGENTS.md", ".codex/config.toml", ".codex/hooks.json", ".codex/skills/issue/SKILL.md", "bin/codex-session-start.sh", "bin/codex-install-skills.sh"),
    "pi": (".pi/APPEND_SYSTEM.md", ".pi/settings.json", ".pi/extensions/egregore.ts", ".codex/skills/issue/SKILL.md", "bin/pi-session-start.sh", "bin/codex-session-start.sh"),
    "prime": (".prime/agent/APPEND_SYSTEM.md", ".prime/agent/settings.json", ".prime/agent/extensions/egregore.ts", ".codex/skills/issue/SKILL.md", "bin/prime-session-start.sh", "bin/codex-session-start.sh"),
}
HARNESS_DIRS = {"codex": (".codex/hooks",)}
HARNESS_BINARIES = {"claude-code": "claude", "codex": "codex", "pi": "pi", "prime": "prime-agent"}


def _object(path):
    try:
        if not path.is_file():
            return None
        with path.open(encoding="utf-8") as stream:
            # Refuse unexpectedly large state/config files without echoing data.
            raw = stream.read(256 * 1024 + 1)
        value = json.loads(raw) if len(raw) <= 256 * 1024 else None
        return value if isinstance(value, dict) else None
    except (OSError, ValueError, UnicodeError):
        return None


def _git(root, *arguments):
    # Ignore inherited Git directory/config overrides. No fetch, hooks, optional
    # index locks or user-config aliases participate in these literal reads.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0", GIT_ALLOW_PROTOCOL="")
    try:
        result = subprocess.run(
            # Empty GIT_ALLOW_PROTOCOL denies every transport, including on
            # older Git versions that do not recognize GIT_NO_LAZY_FETCH.
            ["git", "--no-optional-locks", "-c", "protocol.allow=never", "-C", str(root), *arguments],
            capture_output=True, text=True, timeout=2, env=env, check=False,
        )
        return result.returncode, result.stdout.strip()
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return None, ""


def _checkout(root):
    result = {"revision": None, "source_checkout": False, "contains_local_develop": False,
              "remote_freshness": "unverified", "worktree": (root / ".git").is_file()}
    if not (root / ".git").exists():
        return result
    code, top = _git(root, "rev-parse", "--show-toplevel")
    if code != 0 or top != str(root):
        return result
    code, revision = _git(root, "rev-parse", "--verify", "HEAD")
    if code != 0 or not re.fullmatch(r"[0-9a-f]{40}", revision):
        return result
    result.update(revision=revision, source_checkout=True)
    code, _ = _git(root, "merge-base", "--is-ancestor", "origin/develop", "HEAD")
    result["contains_local_develop"] = code == 0
    return result


def _identity(config, state):
    if state is None:
        return "missing_or_unreadable"
    org = config.get("org_id")
    if not isinstance(org, str) or not org.strip() or org.startswith("legacy-"):
        return "needs_identity_setup"
    nested = state.get("identity", {})
    if not isinstance(nested, dict):
        return "invalid"
    for field in ("account_id", "actor_id", "membership_id", "org_id"):
        top = config.get(field) if field == "org_id" else state.get(field)
        inner = nested.get(field)
        if top and inner and top != inner:
            return "conflicting"
        if field == "org_id" and state.get(field) and state[field] != top:
            return "conflicting"
        value = top or inner
        if not isinstance(value, str) or not value.strip() or value.startswith("legacy-"):
            return "needs_identity_setup"
    if state.get("membership_status", "active") != "active":
        return "inactive"
    return "present"


def _profile_shape(config):
    """Check load_profile prerequisites without reading its declarations."""
    name = config.get("org_name") or config.get("name")
    if not isinstance(name, str) or not name.strip():
        return False
    profile = config.get("profile") or {}
    if not isinstance(profile, dict) or profile.get("schema_version", PROFILE_SCHEMA) != PROFILE_SCHEMA:
        return False
    budget = profile.get("default_context_budget", 1)
    if type(budget) is not int or budget <= 0:
        return False
    for field in ("identity_path", "purpose_path", "principles_path", "conventions_path"):
        value = profile.get(field)
        if value is None:
            continue
        if not isinstance(value, str):
            return False
        path = Path(value.strip().replace("\\", "/"))
        if path.is_absolute() or ".." in path.parts:
            return False
    return True


def inspect_issue_readiness(root: Path | str, *, harness: str | None = None) -> dict:
    """Return only safe local facts; never return config, identity or key values.

    ``ready_for_local_pilot`` means local prerequisites are present. It does not
    establish current membership, provider validity or private-tracker access.
    """
    try:
        root = Path(root).resolve()
        same_root = Path(__file__).resolve().parent.parent == root
    except (OSError, RuntimeError, ValueError):
        same_root = False
    if not same_root:
        # Reject before reading a target's config, identity, Git or credentials.
        return {"schema_version": SCHEMA_VERSION, "status": "unsupported",
                "scope": "curve_labs_source_checkout", "reason": "different_or_unavailable_source_root",
                "next_steps": ["Run readiness from the client checkout whose issue command you are using."],
                "limitations": ["No target files, identity, credentials or remote access were inspected."]}
    config = _object(root / "egregore.json") or {}
    issues = config.get("issues")
    issues = issues if isinstance(issues, dict) else {}
    triage = issues.get("triage")
    triage = triage if isinstance(triage, dict) else {}
    checkout = _checkout(root)
    hosted = any(os.environ.get(key) for key in ("CODER_AGENT_TOKEN", "CODER_WORKSPACE_ID", "CODER_USERNAME"))
    hosted = hosted or os.environ.get("EGREGORE_HOSTED", "").lower() in {"1", "true"}
    eligible = (
        not hosted and checkout["source_checkout"]
        and config.get("upstream_url") == "none"
        and config.get("github_org") == "Curve-Labs"
        and config.get("slug") == "curvelabs"
        and config.get("base_branch", "develop") == "develop"
    )
    selected = harness if harness is not None else os.environ.get("EGREGORE_RUNTIME", "shell")
    selected = {"claude": "claude-code", "prime-agent": "prime"}.get(selected, selected)
    selected_known = selected in HARNESS_PATHS
    adapters = {
        name: {"files_present": all((root / path).is_file() for path in paths)
               and all((root / path).is_dir() for path in HARNESS_DIRS.get(name, ())),
               "binary_present": shutil.which(HARNESS_BINARIES[name]) is not None}
        for name, paths in HARNESS_PATHS.items()
    }
    missing = [path for path in SHARED_PATHS if not (root / path).is_file()]
    tracker = issues.get("backend") == "github" and issues.get("repo") == TRACKER
    identity = _identity(config, _object(root / ".egregore-state.json")) if eligible else "not_checked"
    profile_valid = _profile_shape(config)
    enabled = triage.get("enabled") is True
    pinned = triage.get("provider", "typesafe") == "typesafe" and triage.get("model", DEFAULT_MODEL) == DEFAULT_MODEL
    credential = "not_checked"
    if eligible and tracker and not missing and enabled and pinned:
        try:
            credential = "present" if triage_credential(root) else "missing"
        except (OSError, UnicodeError, ValueError):
            credential = "unreadable"
    harness_ready = selected_known and all(adapters[selected].values())
    tools = {name: shutil.which(name) is not None for name in ("git", "gh", "bash")}
    tools["python_compatible"] = sys.version_info >= (3, 11)
    manual = eligible and profile_valid and tracker and not missing and identity == "present" and all(tools.values()) and harness_ready and checkout["contains_local_develop"]
    advisor = manual and enabled and pinned and credential == "present"
    steps = []
    if not eligible:
        steps.append("Use an existing Curve Labs source checkout on its own host; hosted and packaged/stable clients need a separate verified rollout.")
    elif not checkout["contains_local_develop"] or missing:
        steps.append("Sync this checkout through the existing pull workflow, then restart the harness; do not reinstall or rejoin to update it.")
    if eligible and not tracker:
        steps.append("Restore the reviewed Curve Labs internal tracker configuration; do not switch to a public reporting route.")
    if eligible and identity != "present":
        steps.append("Complete or repair this client's existing Runtime identity through the normal setup flow.")
    if eligible and not profile_valid:
        steps.append("Repair the local organization profile configuration through the normal setup flow.")
    if eligible and not harness_ready:
        steps.append("Select an installed Claude Code, Codex, Pi or Prime harness and verify its project adapter is present.")
    if eligible and not all(tools.values()):
        steps.append("Install the missing local prerequisites before testing issue commands.")
    if eligible and (not enabled or not pinned):
        steps.append("Review the TypeSafe disclosure and the pilot's enabled, pinned triage configuration.")
    if credential in {"missing", "unreadable"}:
        steps.append("Use the private env entry flow to install this host's authorized TYPESAFE_API_KEY; manual filing does not require it.")
    steps.append("Verify GitHub permissions and provider access separately with the participating member; this report has made no remote request.")
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "unsupported" if not eligible else "ready_for_local_pilot" if advisor else "needs_setup",
        "scope": "curve_labs_source_checkout", "checkout": checkout,
        "code": {"shared_files_present": not missing, "missing_files": missing},
        "configuration": {"profile_shape_valid": profile_valid, "internal_tracker_configured": tracker, "triage_enabled": enabled, "pilot_model_configured": pinned},
        "identity": {"status": identity, "authorization": "unverified"},
        "credential": {"key": "TYPESAFE_API_KEY", "status": credential, "validity": "unverified"},
        "harness": {"selected": selected if selected_known else None, "adapters": adapters},
        "tools": tools,
        "private_entry": {"helper_present": (root / "bin/secret-entry.py").is_file() and (root / "bin/lib/secret_entry.py").is_file(), "input_method": "unverified"},
        "manual_filing": {"local_prerequisites": "present" if manual else "needs_setup", "github_access": "unverified"},
        "triage": {"local_prerequisites": "present" if advisor else "needs_setup", "provider_access": "unverified"},
        "limitations": ["File presence does not prove adapter execution or byte integrity.",
                        "Local Git refs may be stale; no fetch was performed.",
                        "No remote membership, permissions, provider validity, quota, issue submission or Telegram delivery was verified.",
                        "No secret-entry dialog or harness was launched; no files were changed.",
                        "This report describes only this checkout and process, not another member or host."],
        "next_steps": steps,
    }
