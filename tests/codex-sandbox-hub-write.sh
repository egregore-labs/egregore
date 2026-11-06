#!/usr/bin/env bash
# DRIVER-ONLY live measurement; do not add this to a test gate. This attempts a
# real HOME write through codex exec's workspace-write sandbox and decides no
# policy. A missing CLI, unavailable model, or absent tool evidence is unmeasured.
# The runner uses exclusive creation and a random ownership token. After Codex
# returns, the wrapper removes only its token-matched probe and directories
# that were absent before this run and remain empty. Pre-existing files stay.
set -u

if ! command -v codex >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' unmeasured
  exit 0
fi

probe_workspace=$(mktemp -d "${TMPDIR:-/tmp}/egregore-codex-hub-probe.XXXXXX" 2>/dev/null) || {
  printf '%s\n' unmeasured
  exit 0
}
trap 'rm -rf "$probe_workspace"' EXIT

# Record ownership before the sandbox runs. The token is written into the
# target file, so a surviving unrelated/pre-existing probe can never be removed.
if ! probe_state=$(python3 - <<'PY'
import json
import os
from pathlib import Path
import secrets

home = Path.home()
directories = [home / '.egregore', home / '.egregore' / 'mind']
target = directories[-1] / 'probe'
state = {
    'token': secrets.token_hex(32),
    'target': str(target),
    'probe_existed': os.path.lexists(target),
    'directories': [[str(directory), os.path.lexists(directory)]
                    for directory in directories],
}
print(json.dumps(state))
PY
)
then
  printf '%s\n' unmeasured
  exit 0
fi
# This copy is available to the sandbox; the wrapper keeps the authoritative
# snapshot in memory, so an edited copy cannot redirect cleanup or claim an
# existing file/directory was created by this run.
printf '%s\n' "$probe_state" > "$probe_workspace/probe-state.json"

cat > "$probe_workspace/probe.py" <<'PY'
import errno
import json
from pathlib import Path

state = json.loads(Path(__file__).with_name('probe-state.json').read_text())
target = Path(state['target'])
result = 'unmeasured'
try:
    if not state['probe_existed']:
        for directory, _ in state['directories']:
            Path(directory).mkdir(mode=0o700, exist_ok=True)
        with target.open('x') as probe:
            probe.write(state['token'] + '\n')
        result = 'writable'
except OSError as error:
    if error.errno in (errno.EACCES, errno.EPERM, errno.EROFS):
        result = 'blocked'
# Cleanup belongs to the wrapper: it still runs when this command is killed
# after creation or when cleanup would be denied inside the sandbox.
print('EGREGORE_HUB_SANDBOX_PROBE:' + result)
PY

probe_source_digest=$(python3 - "$probe_workspace/probe.py" <<'PY'
import hashlib
from pathlib import Path
import sys
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
) || {
  printf '%s\n' unmeasured
  exit 0
}

# Classify the executed command's output, never the model's final assertion.
codex exec --sandbox workspace-write --json --skip-git-repo-check \
  -c 'approval_policy="never"' --cd "$probe_workspace" \
  'Run exactly python3 probe.py once with your shell tool in the current workspace. Do not inspect or edit it. It safely attempts exclusive creation of ~/.egregore/mind/probe and reports the result. Do not retry or request broader permissions. Then stop.' \
  > "$probe_workspace/events.jsonl" 2> "$probe_workspace/stderr.log" || true

probe_result=$(python3 - "$probe_workspace/events.jsonl" "$probe_state" "$probe_source_digest" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys


def ran_probe(command):
    """Accept the requested command, optionally in Codex's shell wrapper."""
    if not isinstance(command, str):
        return False
    command = command.strip()
    if '\n' in command or '\r' in command:
        return False
    try:
        words = shlex.split(command)
    except ValueError:
        return False
    if words == ['python3', 'probe.py']:
        return True
    if (len(words) == 3 and Path(words[0]).name in ('bash', 'zsh', 'sh', 'dash', 'ksh')
            and words[1] in ('-c', '-lc')):
        # One shell wrapper only; no compound commands or nested shells.
        script = words[2].strip()
        if '\n' in script or '\r' in script:
            return False
        try:
            return shlex.split(script) == ['python3', 'probe.py']
        except ValueError:
            return False
    return False


result = 'unmeasured'
completed = []
started = []
try:
    workspace = Path(sys.argv[1]).parent
    unchanged = (hashlib.sha256((workspace / 'probe.py').read_bytes()).hexdigest() == sys.argv[3]
        and json.loads((workspace / 'probe-state.json').read_text()) == json.loads(sys.argv[2]))
    with open(sys.argv[1]) as events:
        for line in events:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            item = event.get('item', {})
            if not isinstance(item, dict) or item.get('type') != 'command_execution':
                continue
            if event.get('type') == 'item.started':
                started.append(item)
            elif event.get('type') == 'item.completed':
                completed.append(item)
    if unchanged and len(completed) == 1:
        item = completed[0]
        # A second started command may have run without a completion event.
        # Reject that ambiguity as well as duplicate completed executions.
        same_start = not started or (len(started) == 1
            and isinstance(item.get('id'), str)
            and started[0].get('id') == item['id']
            and ran_probe(started[0].get('command')))
        output = item.get('aggregated_output', '')
        if (same_start and ran_probe(item.get('command'))
                and item.get('exit_code') == 0 and isinstance(output, str)):
            results = re.findall(r'^EGREGORE_HUB_SANDBOX_PROBE:(writable|blocked|unmeasured)$',
                                 output, re.MULTILINE)
            if len(results) == 1:
                result = results[0]
except (OSError, ValueError):
    pass

# This runs after Codex regardless of its exit status. Do not delete an
# unmatched file, a symlink, or any directory that existed before this run.
residue = False
try:
    state = json.loads(sys.argv[2])
    target = Path(state['target'])
    if not state['probe_existed'] and os.path.lexists(target):
        expected = (state['token'] + '\n').encode()
        try:
            before = target.lstat()
            if not stat.S_ISREG(before.st_mode) or before.st_size != len(expected):
                residue = True
            else:
                descriptor = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(descriptor, 'rb') as probe:
                    opened = os.fstat(probe.fileno())
                    contents = probe.read(len(expected) + 1)
                after = target.lstat()
                if (contents == expected
                        and (before.st_dev, before.st_ino) == (opened.st_dev, opened.st_ino)
                        == (after.st_dev, after.st_ino)):
                    target.unlink()
                else:
                    residue = True
        except OSError:
            residue = True
    for directory, existed_before in reversed(state['directories']):
        if not existed_before and os.path.lexists(directory):
            try:
                Path(directory).rmdir()  # succeeds only for an empty directory
            except OSError:
                residue = True
except (OSError, ValueError, KeyError, TypeError):
    residue = True
if residue:
    result = 'unmeasured'
    print('warning: sandbox probe residue remains; no unmatched files were removed.', file=sys.stderr)
print(result)
PY
) || probe_result=unmeasured

# Keep the public surface one word even if an unavailable/broken parser fails.
case "$probe_result" in
  writable|blocked|unmeasured) printf '%s\n' "$probe_result" ;;
  *) printf '%s\n' unmeasured ;;
esac
