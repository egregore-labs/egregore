#!/usr/bin/env python3
"""Egregore Workspace Init — writes config files from API.

Called by Coder startup_script. Single API call, writes all config.
Git cloning is handled separately by Coder's git-clone module.

Required env vars (injected by Coder template):
  ORG_SLUG, API_URL, EGREGORE_API_KEY, CODER_USERNAME

Writes:
  ~/egregore/egregore.json   — org config
  ~/egregore/.env            — secrets (GITHUB_TOKEN, EGREGORE_API_KEY, ANTHROPIC_API_KEY)
  ~/egregore/.egregore-state.json — user identity + state
"""

import json
import os
import subprocess
import sys
import urllib.request
import urllib.error

HOME = os.environ.get("HOME", "/home/egregore")
EGREGORE_DIR = os.path.join(HOME, "egregore")


def log(msg):
    print(f"[workspace-init] {msg}", flush=True)


def hosted_api_url(value):
    """The address to call: the shell resolver beside this script maps the
    retired October 2026 origin to the hosted API and refuses an address that
    is not plain. Empty, so nothing is sent, when it refuses or cannot run."""
    config_sh = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "config.sh")
    try:
        done = subprocess.run(
            ["bash", "-c", 'source "$1" && _hosted_api_url "$2"', "hosted-api-url", config_sh, value or ""],
            capture_output=True, text=True, timeout=10, check=True,
        )
    except subprocess.CalledProcessError as exc:
        if exc.stderr and exc.stderr.strip():
            log(exc.stderr.strip())
        return ""
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout.strip()


def fetch_config():
    """Fetch workspace config from the Egregore API."""
    api_url = hosted_api_url(os.environ.get("API_URL", ""))
    api_key = os.environ.get("EGREGORE_API_KEY", "")
    slug = os.environ.get("ORG_SLUG", "")
    username = os.environ.get("CODER_USERNAME", "")

    if not all([api_url, api_key, slug, username]):
        missing = [k for k, v in {"API_URL": api_url, "EGREGORE_API_KEY": api_key,
                                   "ORG_SLUG": slug, "CODER_USERNAME": username}.items() if not v]
        log(f"Missing env vars: {', '.join(missing)}")
        return None

    url = f"{api_url}/api/hosting/workspace-config/{slug}?username={username}"
    github_token = os.environ.get("GITHUB_TOKEN", "").strip()

    def get(with_token):
        req = urllib.request.Request(url)
        # urllib copies only req.headers to a redirect: the key and token are
        # unredirected headers, so neither follows one to another host.
        req.add_unredirected_header("Authorization", f"Bearer {api_key}")
        if with_token:
            # The person's own GitHub token is what lets the API include
            # their stored Anthropic key; the org key alone never does.
            req.add_unredirected_header("X-GitHub-Token", github_token)
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())

    try:
        try:
            return get(bool(github_token))
        except urllib.error.HTTPError as e:
            if not github_token or e.code not in (401, 403):
                raise
            # GITHUB_TOKEN is not this person's own (e.g. an org-level token):
            # take the config without the stored key rather than fail start.
            log(f"Stored Anthropic key not available ({e.code}); continuing without it")
            return get(False)
    except urllib.error.HTTPError as e:
        log(f"API error: {e.code} {e.reason}")
        return None
    except Exception as e:
        # Type only: the message of a rejected header carries the token.
        log(f"Failed to fetch config: {type(e).__name__}")
        return None


def write_json(path, data):
    """Write a JSON file."""
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    log(f"Wrote {os.path.basename(path)}")


def write_env(path, env_vars):
    """Write a .env file from a dict. Preserves GITHUB_TOKEN and EGREGORE_API_KEY from container env."""
    lines = []

    # These come from the container env (set by Terraform template)
    lines.append(f"GITHUB_TOKEN={os.environ.get('GITHUB_TOKEN', '')}")
    lines.append(f"EGREGORE_API_KEY={os.environ.get('EGREGORE_API_KEY', '')}")

    # These come from the API (user-specific)
    for key, val in env_vars.items():
        if key not in ("GITHUB_TOKEN", "EGREGORE_API_KEY"):
            lines.append(f"{key}={val}")

    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(path, 0o600)
    log("Wrote .env")


def write_state(path, state):
    """Write .egregore-state.json only if it doesn't exist (preserve user changes)."""
    if os.path.exists(path):
        log("State file exists, preserving")
        return
    write_json(path, state)


def setup_memory_symlink():
    """Create memory symlink if the memory repo was cloned by Coder's git-clone module."""
    memory_dir = os.path.join(HOME, "memory")
    link_path = os.path.join(EGREGORE_DIR, "memory")

    if os.path.isdir(memory_dir) and not os.path.exists(link_path):
        os.symlink(memory_dir, link_path)
        log("Linked memory/ symlink")
    elif not os.path.isdir(memory_dir):
        log("Memory repo not cloned yet (will be linked on next restart)")


def main():
    log("Starting workspace init...")

    # Ensure egregore dir exists (git-clone module may create it, but just in case)
    os.makedirs(EGREGORE_DIR, exist_ok=True)

    # Fetch all config from API
    config = fetch_config()
    if not config:
        log("Could not fetch config — writing fallback from env vars")
        # Write minimal config from container env vars so the workspace isn't completely broken
        fallback_json = {
            "org_name": os.environ.get("ORG_NAME", ""),
            "github_org": os.environ.get("GITHUB_ORG", ""),
            "memory_repo": os.environ.get("MEMORY_URL", ""),
            "api_url": hosted_api_url(os.environ.get("API_URL", "")),
            "slug": os.environ.get("ORG_SLUG", ""),
            "repos": [],
        }
        write_json(os.path.join(EGREGORE_DIR, "egregore.json"), fallback_json)
        write_env(os.path.join(EGREGORE_DIR, ".env"), {
            "ANTHROPIC_API_KEY": os.environ.get("ANTHROPIC_API_KEY", ""),
        })
        username = os.environ.get("CODER_USERNAME", "")
        if username:
            write_state(os.path.join(EGREGORE_DIR, ".egregore-state.json"), {
                "org_setup": True,
                "github_username": username,
                "onboarding_complete": False,
                "workspace_ready": True,
            })
        setup_memory_symlink()
        log("Fallback init complete (some features may not work)")
        return

    # Write all config files
    write_json(os.path.join(EGREGORE_DIR, "egregore.json"), config["egregore_json"])
    write_env(os.path.join(EGREGORE_DIR, ".env"), config.get("env_vars", {}))
    write_state(os.path.join(EGREGORE_DIR, ".egregore-state.json"), config.get("state", {}))
    setup_memory_symlink()

    org_name = config["egregore_json"].get("org_name", "")
    slug = config["egregore_json"].get("slug", "")
    log(f"Ready: {org_name} ({slug})")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"Init failed: {e}")
        sys.exit(0)  # Don't block workspace startup on init failure
