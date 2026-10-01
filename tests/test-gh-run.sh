#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

# Copy only the helper and its dependency; never inspect the checkout's .env.
mkdir -p "$TEST_TMP/fixture root/bin/lib"
cp "$TEST_ROOT/bin/gh-run.sh" "$TEST_TMP/fixture root/bin/gh-run.sh"
cp "$TEST_ROOT/bin/lib/config.sh" "$TEST_TMP/fixture root/bin/lib/config.sh"

python3 - "$TEST_TMP/fixture root" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

fixture = Path(sys.argv[1])
stub_dir = fixture / "stub bin"
stub_dir.mkdir()
stub = stub_dir / "gh"
stub.write_text("""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

Path(os.environ["GH_RUN_RECORD"]).write_text(json.dumps({
    "argv": sys.argv[1:],
    "token": os.environ.get("GITHUB_TOKEN"),
    "gh_token": os.environ.get("GH_TOKEN"),
    "git": {key: value for key, value in os.environ.items() if key.startswith("GIT_")},
}))
sys.stdout.buffer.write(sys.stdin.buffer.read())
sys.stderr.buffer.write(b"stub gh stderr\\n")
raise SystemExit(int(os.environ.get("GH_RUN_STATUS", "0")))
""")
stub.chmod(0o755)
bash = shutil.which("bash")
assert bash, "bash is required"
record = fixture / "record.json"
env_file = fixture / ".env"
passed = 0


def check(condition, description):
    global passed
    assert condition, description
    passed += 1
    print(f"PASS: {description}")


def run(contents, *, inherited=None, args=(), trace=False, status=0):
    if contents is None:
        env_file.unlink(missing_ok=True)
    else:
        env_file.write_text(contents)
    # Start without real credentials or environment-file overrides.
    child_env = {
        "PATH": str(stub_dir) + os.pathsep + os.environ["PATH"],
        "GH_RUN_RECORD": str(record),
        "GH_RUN_STATUS": str(status),
    }
    child_env.update(inherited or {})
    record.unlink(missing_ok=True)
    result = subprocess.run(
        [bash, *(["-x"] if trace else []), str(fixture / "bin/gh-run.sh"), *args],
        cwd=stub_dir,
        env=child_env,
        input=b"stdin passed through\nincluding a NUL: \x00\n",
        capture_output=True,
    )
    assert result.returncode == status, f"unexpected child status: {result.returncode}"
    assert record.is_file(), "stub gh did not record this invocation"
    return result, json.loads(record.read_text())


token = "fixture-only-token=with=equals"
arguments = ["pr", "view", "37", "--repo", "example/project", "two words", "", "literal '$value' ; *"]
result, seen = run(f"GITHUB_TOKEN={token}\n", args=arguments)
check(seen["token"] == token and all(token not in value for value in seen["argv"]),
      "fixture token reaches child environment only, never the argument vector")
check(seen["argv"] == arguments, "arguments pass through verbatim, including spaces and empty values")
check(result.stdout == b"stdin passed through\nincluding a NUL: \x00\n" and result.stderr == b"stub gh stderr\n",
      "stdin, stdout, and stderr pass through unchanged")
check(result.returncode == 0, "successful child status passes through")

result, seen = run(f"GITHUB_TOKEN= \t{token} \t\r\n")
check(seen["token"] == token, "surrounding whitespace and CRLF are trimmed without changing equals signs")

for description, contents in [("missing .env", None), ("missing token key", "OTHER_KEY=fixture\n"),
                              ("empty token", "GITHUB_TOKEN=\n"), ("whitespace-only token", "GITHUB_TOKEN= \t\r\n")]:
    result, seen = run(contents, inherited={"GH_TOKEN": "inherited-gh-login"})
    check(seen["token"] is None and seen["gh_token"] == "inherited-gh-login",
          f"{description} leaves inherited gh login and unset GITHUB_TOKEN untouched")
    result, seen = run(contents, inherited={"GITHUB_TOKEN": "inherited-github-token"})
    check(seen["token"] == "inherited-github-token", f"{description} preserves an inherited GITHUB_TOKEN")

result, seen = run(f"GITHUB_TOKEN={token}\n", inherited={"GITHUB_TOKEN": "inherited-github-token"})
check(seen["token"] == token, "nonempty fixture token overrides an inherited GITHUB_TOKEN")

result, seen = run(f"GITHUB_TOKEN={token}\n", inherited={"GH_TOKEN": "inherited-gh-token"})
check(seen["token"] == token and seen["gh_token"] == "inherited-gh-token",
      "configured GITHUB_TOKEN preserves inherited GH_TOKEN and gh's existing precedence")

result, seen = run(None, inherited={
    "GIT_DIR": "other-repository",
    "GIT_WORK_TREE": "other-worktree",
    "GIT_INDEX_FILE": "other-index",
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_KEY_0": "core.sshCommand",
    "GIT_CONFIG_VALUE_0": "fixture-command",
    "GIT_SSH_COMMAND": "fixture-ssh-command",
    "GIT_CUSTOM_OVERRIDE": "fixture-custom-override",
})
check(seen["git"] == {}, "all inherited GIT_* overrides are removed")

result, seen = run(f"GITHUB_TOKEN={token}\n", status=37)
check(result.returncode == 37, "failing child exit status passes through unchanged")

result, seen = run(f"GITHUB_TOKEN={token}\n", trace=True)
check(result.returncode == 0 and seen["token"] == token and token.encode() not in result.stdout + result.stderr,
      "bash -x never prints the fixture token")

decoy = fixture / "decoy.env"
decoy.write_text("GITHUB_TOKEN=wrong-fixture-token\n")
result, seen = run(f"GITHUB_TOKEN={token}\n", inherited={"ENV_FILE": str(decoy)})
check(seen["token"] == token, "credential lookup stays at the helper's fixture root")

print(f"{passed} passed, 0 failed")
PY
