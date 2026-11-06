#!/usr/bin/env bash
# Exercise the retired entry points in a fixture with no real credentials or tools.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1])
BASH = shutil.which("bash")
NOTICE = b"Hosted Coder workspaces have been retired. Use Egregore from your local workspace.\n"
checks = 0


def check(condition, description):
    global checks
    if not condition:
        raise AssertionError(description)
    checks += 1


with tempfile.TemporaryDirectory(prefix="hosting-retired-") as temporary:
    fixture = Path(temporary)
    checkout = fixture / "checkout"
    tools = fixture / "tools"
    home = fixture / "home"
    elsewhere = fixture / "elsewhere"
    for directory in (checkout / "bin/lib", tools, home, elsewhere):
        directory.mkdir(parents=True)
    scripts = ("hosting-ops.sh", "provision-hosted.sh")
    for script in scripts:
        shutil.copyfile(ROOT / "bin" / script, checkout / "bin" / script)

    events = fixture / "child-calls"
    injected = fixture / "injected"
    # Only fixture tools are on PATH. Even helper scripts or sourced libraries
    # leave a receipt if reached; none can contact an API or start an SSH session.
    sentinel = '#!/bin/bash\nprintf "reached\n" >> "$RETIREMENT_EVENTS"\nexit 97\n'
    for name in (
        "bash", "sh", "env", "curl", "wget", "ssh", "scp", "sshpass", "coder",
        "docker", "git", "jq", "python", "python3", "cat", "grep", "cut", "sed",
        "awk", "dirname", "readlink", "realpath", "mkdir", "mktemp", "rm", "sleep",
        "terraform", "nc",
    ):
        path = tools / name
        path.write_text(sentinel)
        path.chmod(0o700)
    for name in ("api-call.sh", "config-get.sh", "lib/config.sh", "lib/scratch.sh"):
        path = checkout / "bin" / name
        path.write_text(sentinel)
        path.chmod(0o700)

    # A builtin read/source of config blocks too, even if it bypasses PATH.
    # No writer opens these pipes. The bounded subprocess timeout detects reads.
    for path in (checkout / ".env", checkout / "egregore.json",
                 fixture / "override.env", fixture / "override.json"):
        os.mkfifo(path)
    secrets = ["fixture-private-" + name for name in ("github", "org", "hetzner", "coder", "ssh")]
    environment = {
        "PATH": str(tools), "HOME": str(home), "LC_ALL": "C",
        "RETIREMENT_EVENTS": str(events),
        "CONFIG": str(fixture / "override.json"),
        "ENV_FILE": str(fixture / "override.env"),
        "GITHUB_TOKEN": secrets[0], "EGREGORE_API_KEY": secrets[1],
        "HETZNER_API_TOKEN": secrets[2], "CODER_SESSION_TOKEN": secrets[3],
        "SSHPASS": secrets[4],
    }
    attack = '$(printf owned > "' + str(injected) + '"); `printf owned`;\nfixture-argument-\x1b[31m'

    def run(script, args, expected=1, *, traced=False, cwd=checkout, stdin=subprocess.DEVNULL):
        label = script + " " + (args[0] if args and args[0] != attack else "untrusted arguments")
        command = [BASH] + (["-xv"] if traced else []) + [str(checkout / "bin" / script), *args]
        try:
            result = subprocess.run(command, cwd=cwd, env=environment, stdin=stdin,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
        except subprocess.TimeoutExpired:
            raise AssertionError(label + " blocked on config or stdin") from None
        check(result.returncode == expected, label + " exit status")
        check(result.stdout == b"", label + " must not emit operational output")
        check(NOTICE in result.stderr, label + " retirement explanation")
        if not traced:
            check(result.stderr == NOTICE, label + " fixed diagnostic, no reflected arguments")
        output = result.stdout + result.stderr
        check(not any(value.encode() in output for value in [*secrets, attack, str(injected)]),
              label + " must not expose credentials or arguments")
        check(not events.exists(), label + " must not invoke helpers, transport or config tools")
        check(not injected.exists(), label + " must not execute arguments")

    former_commands = (
        ["status", "fixture"], ["enable", "fixture"], ["list"],
        ["wait-ready", "fixture"], ["ssh", "fixture", "--", attack],
        ["scp", "fixture", attack, "/remote/path"],
        ["deploy-template", "fixture", "--version", attack],
        ["restart-workspace", "fixture", "workspace-id"],
        ["users", "fixture"], ["user", "fixture", "member"],
    )
    for args in former_commands:
        run("hosting-ops.sh", args)
    for script in scripts:
        run(script, [])
        run(script, ["unknown", attack])
        run(script, [attack])
        run(script, ["--help"], expected=0)
        run(script, ["-h", attack], expected=0)
        run(script, ["ssh", "fixture", "--", attack], traced=True)
        run(script, ["--help", attack], expected=0, traced=True)
        run(script, ["enable", "fixture"], cwd=elsewhere)
        # Keep the write end open: reading even one byte would wait indefinitely.
        read_fd, write_fd = os.pipe()
        try:
            run(script, ["enable", "fixture"], stdin=read_fd)
        finally:
            os.close(read_fd)
            os.close(write_fd)
        # Share the read descriptor so the parent can prove every byte remains.
        read_fd, write_fd = os.pipe()
        payload = b"fixture-private-stdin\n"
        try:
            os.write(write_fd, payload)
            os.close(write_fd)
            write_fd = None
            run(script, ["ssh", "fixture", "--", "cat"], stdin=read_fd)
            check(os.read(read_fd, len(payload) + 1) == payload, script + " must not consume stdin")
        finally:
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)

print(f"test-hosting-ops: {checks} passed, 0 failed")
PY
