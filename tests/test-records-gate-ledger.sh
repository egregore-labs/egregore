#!/usr/bin/env bash
# The gate ledger written through the records module (session_record.py
# gate-event, called by bin/merge-gate.sh): a valid event is appended, printed
# and committed; invalid input is refused with nothing written; the aggregate
# CI job is never a flake; the session is the flag, else the harness's own id,
# never the checkout's session file, and with neither the line carries none.
# Every case runs in a disposable project and memory repository, with no real
# harness session in its environment.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/tmp"
python3 - "$ROOT" <<'PY'
import contextlib
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1])
PASSED = FAILED = 0
sys.path.insert(0, str(ROOT / 'bin/lib'))
import session_record as sr

HEAD = '49edeb5341a2c022475fc944925f4c23c67904f1'
SESSION_VARS = ('EGREGORE_NATIVE_SESSION_ID', 'CLAUDE_CODE_SESSION_ID', 'CODEX_THREAD_ID')
FILE_SESSION = '20261016T120712-cem-84826'
FIELDS = ['at', 'kind', 'pr', 'head', 'base', 'repo', 'checks', 'attempts', 'flaked', 'recovered', 'receipt', 'by',
          'session']


class Fixture:
    def __init__(self):
        self.temp = Path(tempfile.mkdtemp(prefix='gate-ledger-', dir=ROOT / 'tmp'))
        self.root = self.temp / 'project'
        self.home = self.temp / 'home'
        self.memory = self.temp / 'memory'
        for path in (self.root / 'bin/lib', self.home, self.memory / 'sessions'):
            path.mkdir(parents=True)
        for name in ('session_record.py', 'session_trail.py'):
            shutil.copy2(ROOT / 'bin/lib' / name, self.root / 'bin/lib' / name)
        (self.root / 'memory').symlink_to(self.memory, target_is_directory=True)
        self.state = {'github_username': 'cem', 'display_name': 'Cem', 'actor_id': 'fixture-actor'}
        self.save()
        (self.root / 'egregore.json').write_text(json.dumps({'features': {'session_records': {'enabled': True}}}))
        (self.root / '.egregore-session-id').write_text(FILE_SESSION + '\n')
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('GIT_', 'EGREGORE_', 'CLAUDE_', 'CODEX_'))}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.temp), CODEX_THREAD_ID="fixture-thread")
        self.env.pop('PYTHONPATH', None)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.memory / 'seed').write_text('fixture\n')
        self.git('add', 'seed')
        self.git('commit', '-qm', 'fixture seed')
        self.ledger = self.memory / 'sessions/gate.jsonl'

    def save(self):
        (self.root / '.egregore-state.json').write_text(json.dumps(self.state))

    def git(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        env['HOME'] = str(self.home)
        result = subprocess.run(['git', '-C', str(self.memory), *args], env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()

    def command(self, *extra, memory=None, **flags):
        """gate-event as the gate calls it; a flag set to None is left out."""
        values = dict(kind='merge', pr='1981', head=HEAD, base='develop', repo='Curve-Labs/egregore',
                      green='21', neutral='1', red='0')
        values.update(flags)
        args = [sys.executable, str(self.root / 'bin/lib/session_record.py'), 'gate-event', '--root', str(self.root)]
        if memory is not None:
            args += ['--memory', str(memory)]
        for key, value in values.items():
            if value is not None:
                args += ['--' + key, str(value)]
        return args + list(extra)

    def event(self, *extra, env=None, **flags):
        return subprocess.run(self.command(*extra, **flags), env=dict(self.env, **(env or {})), cwd=self.root,
                              capture_output=True, text=True, timeout=60)

    def lines(self):
        return self.ledger.read_text().splitlines() if self.ledger.exists() else []

    def newest(self):
        return json.loads(self.lines()[-1])

    def cleanup(self):
        shutil.rmtree(self.temp)


@contextlib.contextmanager
def fixture():
    f = Fixture()
    try:
        yield f
    finally:
        f.cleanup()


def test(name, fn):
    global PASSED, FAILED
    try:
        fn()
        PASSED += 1
        print('PASS: ' + name, flush=True)
    except Exception as exc:
        FAILED += 1
        print('FAIL: ' + name + ' — ' + repr(exc), flush=True)
        import traceback
        traceback.print_exc()


def appended_and_committed():
    with fixture() as f:
        result = f.event('--attempts', '2', '--flaked', 'Mind fast contracts', memory=f.memory)
        assert result.returncode == 0, result.stderr
        lines = f.lines()
        assert len(lines) == 1, lines
        event = json.loads(lines[0])
        assert list(event) == FIELDS, list(event)
        assert {key: value for key, value in event.items() if key != 'at'} == {
            'kind': 'merge', 'pr': 1981, 'head': HEAD, 'base': 'develop', 'repo': 'Curve-Labs/egregore',
            'checks': {'green': 21, 'neutral': 1, 'red': 0}, 'attempts': 2, 'flaked': ['Mind fast contracts'],
            'recovered': [], 'receipt': False, 'by': 'fixture-actor', 'session':'fixture-thread'}, event
        at = datetime.fromisoformat(event['at'])
        assert event['at'].endswith('+00:00') and at.microsecond == 0, event['at']
        assert abs(at - datetime.now(timezone.utc)) < timedelta(minutes=5)
        # It prints the line it appended, and nothing else.
        assert result.stdout == lines[0] + '\n' and result.stderr == '', (result.stdout, result.stderr)
        assert f.git('log', '-1', '--format=%s') == 'chore(sessions): record gate verdict for #1981'
        assert set(f.git('show', '--name-only', '--format=', 'HEAD').split()) == \
            {'sessions/gate.jsonl', 'sessions/.gitattributes'}
        assert 'gate.jsonl merge=union' in (f.memory / 'sessions/.gitattributes').read_text().splitlines()
        assert f.git('status', '--porcelain') == ''
        # Without --memory the checkout's memory link is the ledger's home. A
        # second event is a second line, the first stays as written, and the
        # merge rule is not repeated.
        first = f.ledger.read_bytes()
        result = f.event('--receipt', kind='refuse', green='19', red='2')
        assert result.returncode == 0, result.stderr
        assert f.ledger.read_bytes().startswith(first) and len(f.lines()) == 2
        second = f.newest()
        assert (second['kind'], second['receipt'], second['checks'], second['flaked'], second['recovered']) == \
            ('refuse', True, {'green': 19, 'neutral': 1, 'red': 2}, [], []), second
        assert 'attempts' not in second
        assert (f.memory / 'sessions/.gitattributes').read_text().splitlines().count('gate.jsonl merge=union') == 1
        assert f.git('rev-list', '--count', 'HEAD') == '3' and f.git('status', '--porcelain') == ''
test('a valid event is appended, printed and committed with its union rule; a second is a second line',
     appended_and_committed)


def existing_lines_kept():
    with fixture() as f:
        # An empty ledger takes the line as its first; no blank line precedes it.
        f.ledger.write_text('')
        assert f.event().returncode == 0
        assert f.ledger.read_text() == f.lines()[0] + '\n'
        # A malformed line, a line of an unknown kind and a missing final newline
        # stay as written; the new line starts on a line of its own.
        old = f.lines()[0] + '\nnot json\n{"kind": "rollback", "pr": 7, "extra": true}'
        f.ledger.write_text(old)
        assert f.event(pr='1982').returncode == 0
        text = f.ledger.read_text()
        assert text.startswith(old + '\n') and text.endswith('\n'), text
        assert f.newest()['pr'] == 1982 and len(f.lines()) == 4
test('an empty ledger, a malformed line, an unknown kind and a missing final newline are kept as written',
     existing_lines_kept)


def invalid_refused():
    with fixture() as f:
        refusals = [
            dict(head='49edeb53'), dict(head=HEAD.upper()), dict(head=HEAD + '0'), dict(head='g' * 40),
            dict(kind='hold'), dict(kind='MERGE'), dict(kind=''),
            dict(pr='0'), dict(pr='-3'), dict(pr='01981'), dict(pr='19.81'), dict(pr='abc'), dict(pr='#1981'),
            dict(green='-1'), dict(neutral='1.5'), dict(red='x'), dict(red='007'), dict(green=''),
            dict(repo='Curve-Labs'), dict(repo='a/b/c'), dict(repo='../etc'), dict(repo='owner/..'),
            dict(repo='owner/.'), dict(repo='/abs/path'), dict(repo='owner/name with space'),
            dict(base=''), dict(base='two words'),
            dict(head=None), dict(kind=None), dict(repo=None), dict(red=None),
        ]
        extras = [('--attempts', '0'), ('--attempts', '-1'), ('--attempts', 'two'), ('--flaked', ''),
                  ('--flaked', '   '), ('--flaked', 'x' * 121), ('--recovered', ''), ('--recovered', 'x' * 121),
                  ('--session', '../etc/passwd'), ('--session', 'two words'), ('--session', ''), ('--unknown', '1')]
        for extra, flags in [((), flags) for flags in refusals] + [(extra, {}) for extra in extras]:
            result = f.event(*extra, **flags)
            assert result.returncode == 1, (extra, flags, result.stdout, result.stderr)
            # One line on stderr, the reason the gate prints; never a usage text.
            assert result.stderr.count('\n') == 1 and result.stderr.endswith('; nothing was written\n'), \
                (extra, flags, result.stderr)
            assert result.stdout == '', (extra, flags, result.stdout)
        assert not f.ledger.exists() and not (f.memory / 'sessions/.gitattributes').exists()
        assert f.git('rev-list', '--count', 'HEAD') == '1'
        # The bounds themselves are accepted.
        result = f.event('--flaked', 'x' * 120, '--recovered', 'y' * 120, '--attempts', '1', pr='999999999',
                         green='0', neutral='0', red='0', repo='octo_cat-1/repo.name_2-x')
        assert result.returncode == 0, result.stderr
        assert (f.newest()['flaked'], f.newest()['recovered'], f.newest()['pr'], f.newest()['repo']) == \
            (['x' * 120], ['y' * 120], 999999999, 'octo_cat-1/repo.name_2-x')
test('an invalid head, kind, number, count, repository, branch, job or session is refused with nothing written',
     invalid_refused)


def aggregate_dropped():
    with fixture() as f:
        long_aggregate = 'Full CI result — ' + 'y' * 130
        result = f.event('--attempts', '2', '--flaked', 'Full CI result — ' + HEAD, '--flaked', 'Full CI result',
                         '--flaked', long_aggregate, '--flaked', 'Mind fast contracts', '--flaked', 'Mind fast contracts',
                         '--flaked', 'Full CI results — nightly', '--flaked', 'Not the Full CI result — x',
                         '--flaked', 'Suite baseline — shard 2', '--recovered', 'Full CI result — ' + HEAD,
                         '--recovered', 'Not the Full CI result — y', '--recovered', 'Not the Full CI result — y')
        assert result.returncode == 0, result.stderr
        # The aggregate is dropped before any check, whatever its length; a name
        # that only contains or resembles it is a job of its own; repeats are one.
        assert f.newest()['flaked'] == ['Mind fast contracts', 'Full CI results — nightly',
                                        'Not the Full CI result — x', 'Suite baseline — shard 2'], f.newest()
        assert f.newest()['recovered'] == ['Not the Full CI result — y'], f.newest()
        assert 'Full CI result —' not in f.ledger.read_text().replace('Not the Full CI result —', '')
        assert f.event('--attempts', '2', '--flaked', 'Full CI result — ' + HEAD, '--recovered', 'Full CI result',
                       pr='1982').returncode == 0
        assert (f.newest()['attempts'], f.newest()['flaked'], f.newest()['recovered']) == (2, [], [])
test('the aggregate job is dropped from --flaked and --recovered silently; names that only resemble it are kept',
     aggregate_dropped)


def recovered_roundtrip():
    with fixture() as f:
        # A job the gate names flaked and recovered at once flaked: the failure
        # is proof, the cancel is not. Read back, no reader turns a recovered
        # job into a flake: the record's reader names the proven job alone and
        # vitals count it alone.
        result = f.event('--attempts', '3', '--recovered', 'Mind fast contracts', '--recovered', 'Suite baseline — shard 1',
                         '--flaked', 'Suite baseline — shard 1', memory=f.memory)
        assert result.returncode == 0, result.stderr
        event = f.newest()
        assert list(event) == FIELDS, list(event)
        assert (event['attempts'], event['flaked'], event['recovered']) == \
            (3, ['Suite baseline — shard 1'], ['Mind fast contracts']), event
        result = f.event('--attempts', '2', '--recovered', 'test', pr='1982', memory=f.memory)
        assert result.returncode == 0, result.stderr
        assert (f.newest()['flaked'], f.newest()['recovered']) == ([], ['test']), f.newest()
        assert sr.gate_flakes(f.memory, 'fixture-thread') == ['Suite baseline — shard 1']
        now = sr.vitals(f.memory)['now']
        assert (now['merges'], now['flaked'], now['retried_decisions']) == (2, 1, 2), now
test('a recovered job is written beside flaked, never as one, and no reader counts it as a flake', recovered_roundtrip)


def session_sources():
    with fixture() as f:
        f.env.pop("CODEX_THREAD_ID", None)
        def session(*extra, env=None):
            before = len(f.lines())
            result = f.event(*extra, env=env)
            assert result.returncode == 0, result.stderr
            assert len(f.lines()) == before + 1
            return f.newest().get('session')
        every = {'EGREGORE_NATIVE_SESSION_ID': 'native-id', 'CLAUDE_CODE_SESSION_ID': 'claude-uuid',
                 'CODEX_THREAD_ID': 'codex-thread'}
        assert session('--session', 'flag-id', env=every) == 'flag-id'
        assert session(env=every) == 'native-id'
        assert session(env={'CLAUDE_CODE_SESSION_ID': 'claude-uuid', 'CODEX_THREAD_ID': 'codex-thread'}) == 'claude-uuid'
        assert session(env={'CODEX_THREAD_ID': 'codex-thread'}) == 'codex-thread'
        assert session(env={'EGREGORE_NATIVE_SESSION_ID': '', 'CODEX_THREAD_ID': 'codex-thread'}) == 'codex-thread'
        # No harness id: the line is still written, with no session.
        assert session() is None
        # A harness id that is not a safe id names no session, and not the file's either.
        assert session(env={'CLAUDE_CODE_SESSION_ID': '../../etc/passwd'}) is None
        sid = f.root / '.egregore-session-id'
        for text, expected in (('first-line\nsecond-line\n', None), ('', None), ('\n', None),
                               ('no-newline-id', None), ('x' * 129 + '\n', None)):
            sid.write_text(text)
            assert session() == expected, (text, expected)
        # Not even when the file links to the main checkout's, as in a worktree.
        main = f.temp / 'main-session-id'
        main.write_text('linked-session\n')
        sid.unlink()
        sid.symlink_to(main)
        assert session() is None
        sid.unlink()
        assert session() is None
        assert list(f.newest()) == [field for field in FIELDS if field not in ('attempts', 'session')], f.newest()
test('session is the flag, else the harness id in order, never the shared session file, else left out',
     session_sources)


def harness_chain_shared():
    saved = {name: os.environ.pop(name, None) for name in SESSION_VARS}
    try:
        assert sr.harness_session_id() is None
        os.environ['CODEX_THREAD_ID'] = 'codex-thread'
        assert sr.harness_session_id() == 'codex-thread'
        os.environ['CLAUDE_CODE_SESSION_ID'] = 'claude-uuid'
        assert sr.harness_session_id() == 'claude-uuid'
        os.environ['EGREGORE_NATIVE_SESSION_ID'] = 'native-id'
        assert sr.harness_session_id() == 'native-id'
    finally:
        for name, value in saved.items():
            os.environ.pop(name, None)
            if value is not None:
                os.environ[name] = value
    with fixture() as f:
        f.env.pop("CODEX_THREAD_ID", None)
        hold = [sys.executable, str(f.root / 'bin/lib/session_record.py'), 'records', '--root', str(f.root), 'hold']
        result = subprocess.run(hold, env=f.env, cwd=f.root, capture_output=True, text=True, timeout=60)
        assert (result.returncode, result.stdout) == (1, 'Session could not be identified; no hold was written.\n'), \
            (result.stdout, result.stderr)
        # records.sh hold reads the same chain: the third variable reaches its id check.
        result = subprocess.run(hold, env=dict(f.env, CODEX_THREAD_ID='not a session id'), cwd=f.root,
                                capture_output=True, text=True, timeout=60)
        assert (result.returncode, result.stdout) == (1, 'invalid session id\n'), (result.stdout, result.stderr)
test('records.sh hold and the gate ledger read the harness id through one helper, in one order',
     harness_chain_shared)


def nothing_written_when_absent():
    with fixture() as f:
        f.state.pop('actor_id')
        f.save()
        result = f.event()
        assert (result.returncode, result.stderr) == \
            (1, 'Runtime actor identity is unavailable; nothing was written\n'), result.stderr
        f.state['actor_id'] = 'fixture-actor'
        f.save()
        for memory in (f.temp / 'absent', f.temp):
            result = f.event(memory=memory)
            assert (result.returncode, result.stderr) == \
                (1, 'this egregore has no session records; nothing was written\n'), (memory, result.stderr)
        assert not f.ledger.exists()
        # A linked ledger or a directory in its place is never written through.
        target = f.temp / 'elsewhere.jsonl'
        target.write_text('')
        f.ledger.symlink_to(target)
        result = f.event()
        assert (result.returncode, result.stderr) == (1, 'the gate ledger cannot be opened; nothing was written\n')
        assert target.read_text() == ''
        f.ledger.unlink()
        f.ledger.mkdir()
        result = f.event()
        assert (result.returncode, result.stderr) == (1, 'the gate ledger cannot be opened; nothing was written\n')
        f.ledger.rmdir()
        assert f.git('rev-list', '--count', 'HEAD') == '1'
        # Other merge rules are kept, a missing final newline added, and the rule given its own line.
        attributes = f.memory / 'sessions/.gitattributes'
        attributes.write_text('open-items.jsonl merge=union')
        assert f.event().returncode == 0
        assert attributes.read_text() == 'open-items.jsonl merge=union\ngate.jsonl merge=union\n'
test('no username, no memory, no session records, a linked or directory ledger: refused, nothing written',
     nothing_written_when_absent)


def record_controls():
    with fixture() as f:
        f.state['session_records_enabled'] = False
        f.save()
        result=f.event()
        assert result.returncode == 3 and 'withhold' in result.stderr, result.stderr
        assert not f.ledger.exists()
        f.state['session_records_enabled'] = True
        f.save()
        hold=f.home / '.egregore/trails' / sr.st.instance_prefix(f.root) / 'holds' / 'native-held'
        hold.parent.mkdir(parents=True)
        hold.write_text('held')
        result=f.event(env={'EGREGORE_NATIVE_SESSION_ID':'native-held'})
        assert result.returncode == 3 and not f.ledger.exists(), result.stderr
        assert f.git('rev-list','--count','HEAD') == '1'
        assert f.event(env={'EGREGORE_NATIVE_SESSION_ID':'native-other'}).returncode == 0
        assert f.newest()['session'] == 'native-other'
test('personal off and a native session hold suppress gate writes before publication', record_controls)


def no_native_session():
    with fixture() as f:
        for name in SESSION_VARS:
            f.env.pop(name, None)
        # A dry run previews the line and writes nothing.
        result = f.event('--dry-run')
        assert result.returncode == 0 and 'session' not in json.loads(result.stdout), (result.stdout, result.stderr)
        assert not f.ledger.exists()
        # The decision is recorded whole, with no session, so it joins no record.
        result = f.event('--receipt', kind='refuse', green='19', red='2')
        assert result.returncode == 0, result.stderr
        event = f.newest()
        assert list(event) == [field for field in FIELDS if field not in ('attempts', 'session')], event
        assert (event['kind'], event['by'], event['receipt'], event['checks']['red']) == \
            ('refuse', 'fixture-actor', True, 2), event
        assert result.stdout == f.lines()[-1] + '\n' and result.stderr == '', (result.stdout, result.stderr)
        assert f.git('log', '-1', '--format=%s') == 'chore(sessions): record gate verdict for #1981'
        # Records off still withhold a decision that has no session.
        f.state['session_records_enabled'] = False
        f.save()
        result = f.event(pr='1982')
        assert result.returncode == 3 and 'withhold' in result.stderr, result.stderr
        assert len(f.lines()) == 1 and f.git('rev-list', '--count', 'HEAD') == '2'
test('a decision outside a harness session is recorded without a session; records off still withhold it',
     no_native_session)


def time_is_utc():
    with fixture() as f:
        for zone in ('Asia/Tokyo', 'America/Los_Angeles', 'UTC'):
            assert f.event(env={'TZ': zone}).returncode == 0
            stamp = f.newest()['at']
            assert stamp.endswith('+00:00'), (zone, stamp)
            assert abs(datetime.fromisoformat(stamp) - datetime.now(timezone.utc)) < timedelta(minutes=5), (zone, stamp)
test('at is the UTC time to the second under any TZ', time_is_utc)


def concurrent_writers():
    with fixture() as f:
        writers = [subprocess.Popen(f.command(pr=str(100 + index)), env=f.env, cwd=f.root,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                   for index in range(4)]
        outputs = [writer.communicate(timeout=120) for writer in writers]
        assert all(writer.returncode == 0 for writer in writers), outputs
        assert sorted(json.loads(line)['pr'] for line in f.lines()) == [100, 101, 102, 103], f.lines()
        assert f.git('rev-list', '--count', 'HEAD') == '5' and f.git('status', '--porcelain') == ''
test('four writers at once: four whole lines and four commits, under the memory lock', concurrent_writers)

print(f'{PASSED} passed, {FAILED} failed')
sys.exit(1 if FAILED else 0)
PY
