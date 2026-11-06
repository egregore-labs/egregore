#!/usr/bin/env python3
"""Run real Codex startup/card code in a disposable, offline fixture only.

Startup intentionally mutates state and sweeps aged scratch. A Git read-only
flag cannot make running it against the developer's checkout safe. External
integrations are fixture stubs; rendering, mode detection and scratch cleanup
use copied source implementations. No source identity/config contents escape.
"""
from __future__ import annotations

import argparse
from contextlib import suppress
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time


def metadata(path: Path):
    if not path.exists() and not path.is_symlink():
        return None
    own = path.lstat()
    target = path.stat() if path.exists() else None
    fields = lambda value: (value.st_dev, value.st_ino, value.st_size,
                            value.st_mtime_ns, value.st_ctime_ns, value.st_mode)
    return fields(own), fields(target) if target else None


def source_snapshot(root: Path):
    # These are metadata checks, not organizational/credential reads. Include
    # resolved Git HEAD/index hashes without printing either contents or hashes.
    snapshot = {name: metadata(root / name) for name in (
        '.egregore-state.json', '.egregore-session-id', '.egregore-boundary-consent',
        '.egregore-branch-consent', 'egregore.json', '.env', '.git')}
    git = shutil.which('git')
    env = {'PATH': os.environ.get('PATH', ''), 'HOME': str(root),
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull}
    for name in ('HEAD', 'index'):
        result = subprocess.run([git, '-C', str(root), 'rev-parse', '--git-path', name],
                                env=env, capture_output=True, text=True, check=True)
        file = Path(result.stdout.strip())
        if not file.is_absolute():
            file = root / file
        snapshot[f'git/{name}'] = hashlib.sha256(file.read_bytes()).hexdigest() if file.exists() else None
    return snapshot


def write(path: Path, body: str):
    path.write_text(body)
    path.chmod(0o700)


def fixture(root: Path, base: Path, native_names: list[str]):
    project, home, commands = base / 'project', base / 'home', base / 'commands'
    for directory in (project / 'bin/lib', project / 'tmp', home, commands, base / 'tmp'):
        directory.mkdir(parents=True, mode=0o700)
    for name in ('config', 'hash', 'time', 'metrics', 'notices', 'health-footer', 'startup-restart'):
        shutil.copy2(root / f'bin/lib/{name}.sh', project / f'bin/lib/{name}.sh')
    shutil.copy2(root / 'bin/codex-session-start.sh', project / 'bin/codex-session-start.sh')
    shutil.copy2(root / 'bin/scratch-sweep.sh', project / 'bin/scratch-sweep-real.sh')
    # Copy only code. Scratch's Runtime root resolver imports this package, but
    # no actual Runtime, connector, identity resolver or canonical memory opens.
    shutil.copytree(root / 'egregore_runtime', project / 'egregore_runtime',
                    ignore=lambda _directory, names: [name for name in names
                        if name == '__pycache__' or name.endswith(('.pyc', '.pyo'))])
    write(project / 'bin/scratch-sweep.sh', '''#!/bin/bash
trap 'printf "%s\\n" "$?" > "$STARTUP_RECEIPTS/scratch"' EXIT
bash "$(dirname "$0")/scratch-sweep-real.sh" "$@"
''')
    for name in ('session-autosave', 'connect-refresh', 'session-record'):
        write(project / f'bin/{name}.sh', f'#!/bin/bash\nprintf "0\\n" > "$STARTUP_RECEIPTS/{name}"\n')
    write(project / 'bin/node-run.sh', '#!/bin/bash\nexit 0\n')
    write(project / 'bin/lib/identity.sh', 'AUTHOR=fixture\nDISPLAY_NAME_STATE=Fixture\n')
    write(project / 'bin/lib/git-sync.sh', 'BRANCH=fixture\nREPOS_STATUS=""\n')
    write(project / 'bin/lib/context.sh', 'CTX_DIR="$(mktemp -d "$TMPDIR/context.XXXXXX")"\n')
    write(project / 'bin/lib/greeting.sh', '_print_session_records() { :; }\n_print_reflexes() { :; }\n')
    write(project / 'bin/codex-sync-skills.sh', '''#!/bin/bash
[ "$1" = "--list-native" ] || exit 1
cat "$(dirname "$0")/native-skills"
''')
    (project / 'bin/native-skills').write_text('\n'.join(native_names) + '\n')
    (project / '.egregore-state.json').write_text(json.dumps({
        'github_username': 'fixture', 'display_name': 'Fixture',
        'onboarding_complete': True, 'autosave_enabled': False}))

    # Child startup gets an exact environment and a command allowlist, never
    # inherited credentials, GIT_*/Python startup overrides, or host HOME.
    for name in ('bash', 'awk', 'cat', 'cksum', 'cut', 'date', 'dirname', 'grep',
                 'head', 'jq', 'mkdir', 'mktemp', 'rm', 'sed', 'sort', 'tail', 'tr', 'wc'):
        executable = shutil.which(name)
        if not executable:
            raise AssertionError(f'fixture dependency missing: {name}')
        (commands / name).symlink_to(executable)
    (commands / 'python3').symlink_to(os.path.realpath(os.sys.executable))
    for name in ('git', 'gh', 'curl', 'wget', 'npm', 'npx', 'qmd', 'claude', 'ssh', 'scp'):
        write(commands / name, '#!/bin/bash\nprintf "%s\\n" "$0" >> "$FORBIDDEN_CALLS"\nexit 97\n')
    env = {'PATH': str(commands), 'HOME': str(home), 'TMPDIR': str(base / 'tmp'),
           'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
           'XDG_DATA_HOME': str(home / '.local/share'), 'LC_ALL': 'C',
           'PYTHONDONTWRITEBYTECODE': '1', 'PYTHONNOUSERSITE': '1',
           'EGREGORE_NOTICE_LEDGER': 'off', 'FORBIDDEN_CALLS': str(base / 'forbidden-calls')}
    return project, env


def run_startup(project: Path, env: dict, base: Path, mode: str, argument: str):
    receipts = base / f'{mode}-{argument[2:]}'
    receipts.mkdir()
    old, fresh = project / 'tmp/old-sentinel', project / 'tmp/fresh-sentinel'
    old.write_text('sweep this fixture only\n')
    fresh.write_text('retain fresh fixture\n')
    timestamp = time.time() - 7200
    os.utime(old, (timestamp, timestamp))
    config = {'mode': mode, 'org_name': 'Startup fixture', 'github_org': 'fixture',
              'repo_name': 'egregore', 'repos': []}
    if mode == 'connected':
        # A reserved invalid hostname selects the badge; refresh is stubbed and
        # no credential is present. The fixture cannot execute a network client.
        config['api_url'] = 'https://startup-fixture.invalid'
    (project / 'egregore.json').write_text(json.dumps(config))
    process = subprocess.Popen([str(Path(env['PATH']) / 'bash'),
                                str(project / 'bin/codex-session-start.sh'), argument],
                               cwd=project, env={**env, 'STARTUP_RECEIPTS': str(receipts)},
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               start_new_session=True)
    settled = False
    try:
        stdout, stderr = process.communicate(timeout=20)
        assert process.returncode == 0, 'fixture startup failed: ' + stderr
        assert not stderr.strip(), 'fixture startup emitted unexpected diagnostics: ' + stderr
        expected = ['scratch', 'session-autosave', 'connect-refresh']
        if argument == '--card':
            expected.append('session-record')
        # Every background entry point is instrumented in the fixture. Do not
        # tear down while children are using it; a sleep cannot prove completion.
        deadline = time.monotonic() + 10
        while not all((receipts / name).is_file() for name in expected):
            if time.monotonic() >= deadline:
                raise AssertionError('fixture background startup did not settle')
            time.sleep(0.02)
        assert all((receipts / name).read_text().strip() == '0' for name in expected)
        settled = True
        assert not old.exists(), 'real startup must sweep aged fixture scratch'
        assert fresh.read_text() == 'retain fresh fixture\n'
        assert not (base / 'forbidden-calls').exists(), 'startup attempted a forbidden external integration'
        return stdout
    finally:
        # Receipts are the final filesystem operation of every background stub
        # and of the wrapper that waits for real scratch cleanup. On failure or
        # timeout, terminate the separate fixture group before removing files.
        # Do not signal an already settled/reaped group: its ID can be reused.
        if not settled:
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--native-file', type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    if args.native_file:
        names = args.native_file.read_text().splitlines()
    else:
        names = subprocess.run(['bash', str(root / 'bin/codex-sync-skills.sh'), '--list-native'],
                               capture_output=True, text=True, check=True).stdout.splitlines()
    names = [name for name in names if name]
    assert all(re.fullmatch(r'[a-z0-9][a-z0-9-]*', name) for name in names)
    snapshot = source_snapshot(root)
    (root / 'tmp').mkdir(exist_ok=True)
    # This unique file is the only source write. Never use an existing name or
    # delete another session's scratch. An accidental source startup loses it.
    descriptor, filename = tempfile.mkstemp(prefix='codex-isolation-sentinel-', dir=root / 'tmp')
    os.close(descriptor)
    sentinel = Path(filename)
    sentinel.write_text('source scratch must survive startup tests\n')
    timestamp = time.time() - 7200
    os.utime(sentinel, (timestamp, timestamp))
    try:
        with tempfile.TemporaryDirectory(prefix='codex-startup-isolation-') as directory:
            base = Path(directory)
            assert root not in base.resolve().parents, 'fixture must be outside source checkout'
            project, env = fixture(root, base, names)
            for mode in ('local', 'connected'):
                card = run_startup(project, env, base, mode, '--card')
                assert ('◇ LOCAL' if mode == 'local' else '◆ CONNECTED') in card
                assert 'What are you working on?' in card
                for hidden in ('egregore-site:', 'egregore-videos:', 'codex harness active',
                               'Codex skills:', 'More skills:', 'Trusted Codex:', 'Adapter skills:'):
                    assert hidden not in card, f'card exposed prompt-only content: {hidden}'
                prompt = run_startup(project, env, base, mode, '--prompt')
                for required in ('Trusted Codex: full shell/network access is enabled',
                                 'Codex reserves leading slash commands for built-ins',
                                 'Every Egregore workflow is a $name skill whose adapter names the canonical workflow it runs.'):
                    assert required in prompt
                assert ('Maintained native Codex skills:' in prompt) == bool(names)
                assert not re.search(r'\$([^a-zA-Z0-9_]|$)', prompt)
                assert all(f'${name}' in prompt for name in names)
                assert sentinel.read_text() == 'source scratch must survive startup tests\n'
                assert source_snapshot(root) == snapshot, 'startup changed source identity or Git metadata'
    finally:
        sentinel.unlink(missing_ok=True)
    print('codex startup isolation ok (local + connected; real fixture sweep; source state unchanged)')


if __name__ == '__main__':
    main()
