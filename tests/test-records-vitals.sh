#!/usr/bin/env bash
# Vitals: the organization's pulse from the session records and the merge
# gate's ledger. The numbers, the line and its silence, edge dates and time
# zones, absent inputs, held and backfilled records, the line budget and the
# latency, and the probe through the reflex runner on every harness. Every
# case runs in a disposable project and memory directory; no real record or
# ledger is read and no network is reached.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/tmp"
python3 - "$ROOT" <<'PY'
from collections import Counter
import contextlib
from datetime import date, datetime, timedelta, timezone
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(sys.argv[1])
PASSED = FAILED = 0
# A record's period follows its local date. Pin the zone for in-process reads;
# every subprocess gets its zone explicitly.
os.environ['TZ'] = 'UTC'
time.tzset()
sys.path.insert(0, str(ROOT / 'bin/lib'))
import budget as timing  # bin/lib/budget.py; `budget` here names the line-length test
import session_record as sr
import session_trail as st

TODAY = date(2026, 10, 16)
ZONES = ('UTC', 'Pacific/Kiritimati', 'Pacific/Pago_Pago')
ZERO = ['- tool errors: 0', '- non-zero exits: 0', '- worktree-guard refusals: 0', '- recall failures: 0',
        '- sleep commands: 0, 0.0 minutes', '- compactions: 0']
EMPTY = {'sessions': 0, 'by_harness': {}, 'cost_usd': None, 'priced_sessions': 0,
         'friction': None, 'friction_sessions': 0, 'retried_decisions': None, 'retry_observations': 0,
         'merges': None, 'refused': None, 'flaked': None, 'receipts': None}
FIELDS = ['sessions', 'by_harness', 'cost_usd', 'priced_sessions', 'friction', 'friction_sessions',
          'retried_decisions', 'retry_observations', 'merges', 'refused', 'flaked', 'receipts']
LINE_NOW = ('7 days: 6 sessions (3 claude, 2 codex, 1 unknown) · $19 · friction 3.2 a session '
            '· observed 4 merges, 3 flaked, 2 refused, 1 receipt (partial)')
LINE_BEFORE = 'before: 3 sessions (2 claude, 1 pi) · $22 · friction 2.5 · observed 2 merges, 1 flaked, 1 receipt (partial)'

# Records every record file a process opens, through the interpreter's own audit
# events (as tests/test-records-open-items.sh does).
AUDIT = r'''import os, sys
log = os.environ.get('OPEN_AUDIT_LOG')
def hook(event, args):
    if event == 'open' and args and isinstance(args[0], (str, bytes, os.PathLike)):
        path = os.fsdecode(args[0])
        if os.sep + 'sessions' + os.sep in path and path.endswith('.md'):
            with open(log, 'a') as stream:
                stream.write(path + '\n')
if log:
    sys.addaudithook(hook)
'''


def expected(today=TODAY):
    return {'days': 7, 'today': today.isoformat(), 'gate_coverage': 'partial',
            'gate_capture_coverage': 'unknown', 'gate_counts_basis': 'observed_events',
            'now': {'sessions': 6, 'by_harness': {'claude': 3, 'codex': 2, 'unknown': 1}, 'cost_usd': 19.45, 'priced_sessions': 6,
                    'friction': 3.2, 'friction_sessions': 5,
                    'retried_decisions': 2, 'retry_observations': 2,
                    'merges': 4, 'refused': 2, 'flaked': 3, 'receipts': 1},
            'before': {'sessions': 3, 'by_harness': {'claude': 2, 'pi': 1}, 'cost_usd': 21.55, 'priced_sessions': 3,
                       'friction': 2.5, 'friction_sessions': 2,
                       'retried_decisions': None, 'retry_observations': 0,
                       'merges': 2, 'refused': 0, 'flaked': 1, 'receipts': 1}}


def body(friction, pad=0, open_lines=None):
    """A record body in the writer's section order; ``friction`` None leaves its section out."""
    sections = ['## Asked\n- fixture work', '## Decided\nnone recorded',
                '## Open\n' + ('\n'.join('- ' + line for line in open_lines) if open_lines else 'none recorded'),
                '## Risks\nnone noted', '## Commits and PRs\nnone recorded',
                '## Files\n' + '\n'.join(f'- bin/fixture_{index}.py' for index in range(40))]
    if pad:
        sections.append('## Memory and artifacts\n' + '- memory/fixture/a-padding-note.md\n' * (pad // 34))
    if friction is not None:
        sections.append('## Friction\n' + '\n'.join(friction))
    sections.append('## Cost\n- total: $1.00 (ledger)\n- model calls: 3\n- tool calls: 9')
    return '\n\n'.join(sections) + '\n'


def snapshot(top):
    """Every path under ``top`` with its size and time, leaving out the bytecode cache."""
    return {str(path.relative_to(top)): None if path.is_dir() else (path.stat().st_size, path.stat().st_mtime_ns)
            for path in top.rglob('*') if '__pycache__' not in path.parts and not path.is_symlink()}


class Fixture:
    def __init__(self):
        self.temp = Path(tempfile.mkdtemp(prefix='vitals-', dir=ROOT / 'tmp'))
        self.root = self.temp / 'project'
        self.home = self.temp / 'home'
        self.memory = self.temp / 'memory'
        for path in (self.root / 'bin/lib', self.root / 'bin/reflexes', self.home, self.memory / 'sessions',
                     self.temp / 'audit'):
            path.mkdir(parents=True)
        for name in ('records.sh', 'reflexes.sh'):
            shutil.copy2(ROOT / 'bin' / name, self.root / 'bin' / name)
        for name in ('session_record.py', 'session_trail.py', 'record_outcomes.py', 'reflexes.py'):
            shutil.copy2(ROOT / 'bin/lib' / name, self.root / 'bin/lib' / name)
        shutil.copy2(ROOT / 'bin/reflexes/05-vitals.sh', self.root / 'bin/reflexes/05-vitals.sh')
        (self.temp / 'audit/sitecustomize.py').write_text(AUDIT)
        (self.root / 'memory').symlink_to(self.memory, target_is_directory=True)
        self.config = {'mode': 'local', 'features': {'session_records': {'enabled': True}}}
        self.save()
        (self.root / '.egregore-state.json').write_text(json.dumps({'github_username': 'cem'}))
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('GIT_', 'EGREGORE_', 'CLAUDE_', 'CODEX_', 'OPEN_AUDIT'))}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.temp), TZ='UTC', EGREGORE_NO_TELEMETRY='1')
        self.env.pop('PYTHONPATH', None)

    def save(self):
        (self.root / 'egregore.json').write_text(json.dumps(self.config))

    def record(self, name, day, *, harness='claude', cost=0.0, friction=ZERO, stub=False, backfill=False,
               at='12:00:00+00:00', author='cem', pad=0, extra=None, open_lines=None):
        """One record as the writer lays it out (session_record.record_text), named by
        its date. ``at`` None writes a date-only record; ``harness`` None leaves it out."""
        day = date.fromisoformat(day) if isinstance(day, str) else day
        data = {'author': author, 'session': name, 'date': day.isoformat() + ('T' + at if at else ''),
                'detail': 'stub' if stub else 'outline', 'status': 'final', 'record_revision': 1,
                'cost_usd': cost, 'cost_source': 'list price' if harness == 'codex' else 'ledger',
                'duration': '42m', 'active': '30m', 'topic': 'fixture ' + name, 'branch': 'dev/cem/fixture',
                'harness': harness, 'backfill': backfill, 'summary': f'42m on fixture {name}',
                'body': body(friction, pad, open_lines)}
        text = sr.record_text(data)
        if extra:
            text = text.replace('kind: session-record\n', 'kind: session-record\n' + ''.join(
                f'{key}: {json.dumps(value)}\n' for key, value in extra.items()), 1)
        return self.write(f'{day:%Y-%m}/{day:%d}-{author}-{name}.md', text)

    def write(self, relative, text):
        path = self.memory / 'sessions' / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def gate(self, *events):
        lines = [event if isinstance(event, str) else json.dumps(event) for event in events]
        return self.write('gate.jsonl', ''.join(line + '\n' for line in lines))

    def cli(self, *args, env=None):
        return subprocess.run([sys.executable, str(self.root / 'bin/lib/session_record.py'), *map(str, args)],
                              env=env or self.env, capture_output=True, text=True, timeout=30)

    def vitals(self, *args, env=None, memory=None, observations_only=True):
        result = self.cli('vitals', '--root', self.root, '--memory', memory or self.memory, '--json', *args, env=env)
        assert result.returncode == 0 and result.stderr == '', result.stdout + result.stderr
        data = json.loads(result.stdout)
        return observations(data) if observations_only else data

    def scorecard(self, *args, **kwargs):
        return self.vitals(*args, observations_only=False, **kwargs)

    def line(self, *args, env=None, memory=None):
        result = self.cli('vitals-line', '--root', self.root, '--memory', memory or self.memory, *args, env=env)
        assert result.returncode == 0 and result.stderr == '', result.stdout + result.stderr
        return result.stdout

    def probe(self, memory=None, env=None):
        env = dict(env or self.env, EGREGORE_ROOT=str(self.root), EGREGORE_MEMORY=str(memory or self.memory))
        result = subprocess.run(['bash', str(self.root / 'bin/reflexes/05-vitals.sh')], env=env,
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == 0 and result.stderr == '', result.stdout + result.stderr
        return result.stdout

    def runner(self, *args):
        env = dict(self.env, EGREGORE_ROOT=str(self.root), EGREGORE_MEMORY=str(self.memory))
        return subprocess.run(['bash', str(self.root / 'bin/reflexes.sh'), *args], env=env,
                              capture_output=True, text=True, timeout=20)

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
        note = fn()
        PASSED += 1
        print('PASS: ' + name + (f' ({note})' if note else ''), flush=True)
    except Exception as exc:
        FAILED += 1
        print('FAIL: ' + name + ' — ' + repr(exc), flush=True)
        import traceback
        traceback.print_exc()


def observations(data):
    # Existing vitals contracts test the measurements independently of findings.
    return {key: value for key, value in data.items() if key not in ('findings', 'unit_economics', 'outcome_scorecard')}


def main_fixture(f, shift=timedelta(0)):
    """Six records in the seven days to 2026-10-16, three in the seven before,
    records either side and two files that are no countable record; a gate
    ledger with events in both periods and lines a reader skips."""
    def day(text):
        return date.fromisoformat(text) + shift

    def at(text):
        return (datetime.fromisoformat(text) + shift).isoformat()

    f.record('r1', day('2026-10-16'), cost=12.50, friction=[
        '- tool errors: Bash 3, Edit 1', '- non-zero exits: Bash 2', '- worktree-guard refusals: 1',
        '- recall failures: keyword/timeout 1', '- sleep commands: 4, 2.0 minutes', '- compactions: 3'])
    f.record('r2', day('2026-10-14'), harness='codex', cost=3.25, extra={'mood': 'an unknown field'})
    f.record('r3', day('2026-10-12'), harness=None, cost=2.00, stub=True)
    f.record('r4', day('2026-10-11'), cost=0.75, backfill=True, friction=[
        '- tool errors: mcp__fixture__lookup 2', '- non-zero exits: 0', '- worktree-guard refusals: 0',
        '- recall failures: keyword/episode-binding 1, semantic/error 2'])
    f.record('r5', day('2026-10-10'), harness='codex', cost=0.95, friction=['- non-zero exits: git 1, npm 1'])
    # The writer's lines come first; a later line under the same label is the model's own text.
    f.record('r6', day('2026-10-13'), friction=['- tool errors: Read 1', '- tool errors: Bash 50'])
    f.record('b1', day('2026-10-09'), cost=20.00, friction=['- tool errors: Bash 1'])
    f.record('b2', day('2026-10-03'), cost=1.10, friction=['- worktree-guard refusals: 4'])
    f.record('b3', day('2026-10-05'), harness='pi', cost=0.45, friction=None)
    f.record('o1', day('2026-10-02'), cost=100.00, friction=['- tool errors: Bash 9'])
    f.record('o2', day('2026-10-17'), cost=100.00, friction=['- tool errors: Bash 9'])
    other = day('2026-10-15')
    f.write(f'{other:%Y-%m}/{other:%d}-cem-handoff.md', '---\nkind: handoff\nfrom: "cem"\n'
            f'date: "{other.isoformat()}"\ncost_usd: 100\n---\n\n# Handoff\n')
    f.write(f'{other:%Y-%m}/{other:%d}-cem-undated.md', '---\nkind: session-record\nfrom: "cem"\ndate: "someday"\n'
            'session: "undated"\ndetail: outline\ncost_usd: 100\n---\n\n# Session: undated\n\n**Date**: someday\n')
    f.gate({'at': at('2026-10-16T12:21:27+00:00'), 'kind': 'merge', 'pr': 1981,
            'head': '49edeb5341a2c022475fc944925f4c23c67904f1', 'base': 'develop', 'repo': 'Curve-Labs/egregore',
            'checks': {'green': 21, 'neutral': 1, 'red': 0}, 'attempts': 2, 'flaked': ['Mind fast contracts'],
            'receipt': False, 'by': 'fcdagdelen', 'session': '20261016T120712-fcdagdelen-84826'},
           {'at': at('2026-10-15T08:00:00+00:00'), 'kind': 'merge', 'pr': 1982, 'flaked': [], 'receipt': True},
           {'at': at('2026-10-10T10:00:00+00:00'), 'kind': 'merge', 'pr': 1983, 'attempts': 2,
            'flaked': ['Shell contracts', 'Runtime']},
           {'at': at('2026-10-12T10:00:00+00:00'), 'kind': 'refuse', 'pr': 1984,
            'checks': {'green': 3, 'neutral': 0, 'red': 1}},
           # A refusal's flaked list is not a merge's; only merges count flakes.
           {'at': at('2026-10-13T10:00:00+00:00'), 'kind': 'refuse', 'pr': 1985, 'flaked': ['Not a merge']},
           # A merge whose flaked and receipt are not a list and true: the merge counts, they do not.
           {'at': at('2026-10-14T10:00:00+00:00'), 'kind': 'merge', 'pr': 1986, 'flaked': 'Mind fast contracts',
            'receipt': 'true', 'future': {'field': 1}},
           {'at': at('2026-10-09T10:00:00+00:00'), 'kind': 'merge', 'pr': 1970, 'flaked': ['Mind fast contracts'],
            'receipt': True},
           {'at': at('2026-10-03T10:00:00+00:00'), 'kind': 'merge', 'pr': 1960},
           '', 'not json', '[1, 2]',
           {'at': at('2026-10-14T10:00:00+00:00'), 'kind': 'hold', 'pr': 1990},
           {'kind': 'merge', 'pr': 1991},
           {'at': 'yesterday', 'kind': 'merge', 'pr': 1992},
           {'at': at('2026-10-02T10:00:00+00:00'), 'kind': 'merge', 'pr': 1950},
           {'at': at('2026-10-17T10:00:00+00:00'), 'kind': 'refuse', 'pr': 1999})


# 1 · The numbers.

def numbers():
    with fixture() as f:
        main_fixture(f)
        data = f.vitals('--today', TODAY)
        assert list(data) == ['days', 'today', 'gate_coverage', 'gate_capture_coverage', 'gate_counts_basis',
                              'now', 'before'], data
        for period in ('now', 'before'):
            assert list(data[period]) == FIELDS, data[period]
            for field, value in expected()[period].items():
                assert data[period][field] == value, (period, field, data[period][field], value)
        assert data == expected(), data
        # The function agrees with the command and takes the date or its ISO form.
        assert observations(sr.vitals(f.memory, today=TODAY)) == observations(sr.vitals(str(f.memory), today='2026-10-16')) == expected()
        # The default window is seven days; --days 7 is the same.
        assert f.vitals('--today', TODAY, '--days', '7') == data
test('numbers: sessions by harness, cost, friction and gate events per period, field by field', numbers)


# 2 · The line.

def line_shapes():
    with fixture() as f:
        main_fixture(f)
        assert f.line('--today', TODAY) == LINE_NOW + '\n' + LINE_BEFORE + '\n'
        assert all(len(line) <= sr.REFLEX_LINE for line in (LINE_NOW, LINE_BEFORE))
        # Without --json the command prints the same two lines.
        result = f.cli('vitals', '--root', f.root, '--memory', f.memory, '--today', TODAY)
        assert result.returncode == 0 and result.stdout == LINE_NOW + '\n' + LINE_BEFORE + '\n', result.stdout
        # No gate events in either period: the gate part goes from both lines.
        (f.memory / 'sessions/gate.jsonl').unlink()
        assert f.line('--today', TODAY) == ('7 days: 6 sessions (3 claude, 2 codex, 1 unknown) · $19 · friction 3.2 a session\n'
                                             'before: 3 sessions (2 claude, 1 pi) · $22 · friction 2.5\n')
        # Gate events in the days before only: the last seven days show none.
        f.gate({'at': '2026-10-08T10:00:00+00:00', 'kind': 'merge', 'flaked': ['Runtime']},
               {'at': '2026-10-07T10:00:00+00:00', 'kind': 'refuse'})
        lines = f.line('--today', TODAY).splitlines()
        assert lines[0].endswith(' · friction 3.2 a session · observed 0 merges'), lines
        assert lines[1].endswith(' · friction 2.5 · observed 1 merge, 1 flaked, 1 refused'), lines
    with fixture() as f:
        # One harness, whatever its case: no breakdown. Nothing before: the first line alone.
        f.record('a', '2026-10-16', cost=4.2, friction=['- tool errors: Bash 1'])
        f.record('b', '2026-10-15', harness='CLAUDE')
        assert f.line('--today', TODAY) == '7 days: 2 sessions · $4.20 · friction 0.5 a session\n'
        # A record in the days before brings the before line, in the singular; a cost under a cent is $0.
        f.record('c', '2026-10-08', harness='codex', cost=0.004)
        assert f.line('--today', TODAY).splitlines() == ['7 days: 2 sessions · $4.20 · friction 0.5 a session',
                                                           'before: 1 session · $0 · friction 0.0']
        f.gate({'at': '2026-10-16T09:00:00+00:00', 'kind': 'merge', 'receipt': True})
        assert f.line('--today', TODAY).splitlines() == [
            '7 days: 2 sessions · $4.20 · friction 0.5 a session · observed 1 merge, 1 receipt',
            'before: 1 session · $0 · friction 0.0 · observed 0 merges']
        # Under two sessions in the last seven days the line is silent; the command still prints both lines.
        (f.memory / 'sessions/2026-10/15-cem-b.md').unlink()
        assert f.line('--today', TODAY) == ''
        result = f.cli('vitals', '--root', f.root, '--memory', f.memory, '--today', TODAY)
        assert result.stdout.splitlines() == ['7 days: 1 session · $4.20 · friction 1.0 a session · observed 1 merge, 1 receipt',
                                              'before: 1 session · $0 · friction 0.0 · observed 0 merges'], result.stdout
        (f.memory / 'sessions/2026-10/16-cem-a.md').unlink()
        assert f.line('--today', TODAY) == ''
    # The brief's own example, straight into the formatter.
    example = {'days': 7, 'today': '2026-10-16',
               'now': {'sessions': 27, 'by_harness': {'claude': 23, 'codex': 4}, 'cost_usd': 412.31, 'friction': 2.1,
                       'merges': 9, 'refused': 1, 'flaked': 2, 'receipts': 0},
               'before': {'sessions': 19, 'by_harness': {'claude': 19}, 'cost_usd': 380.02, 'friction': 3.4,
                          'merges': 4, 'refused': 0, 'flaked': 1, 'receipts': 0}}
    assert sr.vitals_line(example) == ('7 days: 27 sessions (23 claude, 4 codex) · $412 · friction 2.1 a session '
                                       '· observed 9 merges, 2 flaked, 1 refused\n'
                                       'before: 19 sessions · $380 · friction 3.4 · observed 4 merges, 1 flaked')
    # Money: whole dollars from $10, cents below, $0 at zero; a cost rounding up to $10 is whole.
    for cost, money in ((412.31, '$412'), (10.0, '$10'), (9.996, '$10'), (9.99, '$9.99'), (4.2, '$4.20'),
                        (0.01, '$0.01'), (0.004, '$0'), (0.0, '$0'), (12345.6, '$12,346')):
        period = dict(EMPTY, sessions=2, priced_sessions=2, cost_usd=cost)
        assert f' · {money} · ' in sr.vitals_line({'days': 7, 'now': period, 'before': EMPTY}), (cost, money)
test('line: the two lines, the breakdown, the gate part and the before line appear only with something to say',
     line_shapes)


# 3 · Edge dates.

def edge_dates():
    with fixture() as f:
        # The periods cross a month: 2026-10-27..11-02 and 2026-10-20..10-26.
        for name, day in (('today', '2026-11-02'), ('today-again', '2026-11-02'), ('first-now', '2026-10-27'),
                          ('last-before', '2026-10-26'), ('first-before', '2026-10-20'), ('too-old', '2026-10-19'),
                          ('tomorrow', '2026-11-03')):
            f.record(name, day, cost=1.0)
        f.gate({'at': '2026-10-27T00:30:00+00:00', 'kind': 'merge'}, {'at': '2026-10-26T23:30:00+00:00', 'kind': 'refuse'},
               {'at': '2026-10-20T00:00:00+00:00', 'kind': 'merge'}, {'at': '2026-10-19T23:59:59+00:00', 'kind': 'merge'},
               {'at': '2026-11-03T00:00:00+00:00', 'kind': 'merge'})
        data = f.vitals('--today', '2026-11-02')
        assert (data['now']['sessions'], data['before']['sessions']) == (3, 2), data
        assert (data['now']['merges'], data['now']['refused'], data['before']['merges'], data['before']['refused']) == \
            (1, 0, 1, 1), data
        # A day earlier the boundary moves with it: the first day of before is now in the last seven days.
        data = f.vitals('--today', '2026-11-01')
        assert (data['now']['sessions'], data['before']['sessions']) == (2, 2), data
        assert (data['now']['merges'], data['now']['refused'], data['before']['merges']) == (1, 1, 2), data
        # One day beside the one before.
        assert f.line('--today', '2026-11-02', '--days', '1') == '1 day: 2 sessions · $2.00 · friction 0.0 a session\n'
        for bad in (('--days', '0'), ('--days', '367'), ('--days', 'seven'), ('--today', '2026-13-01')):
            result = f.cli('vitals', '--root', f.root, '--memory', f.memory, *bad)
            assert result.returncode == 2 and result.stdout == '' and 'usage:' in result.stderr, (bad, result)
    with fixture() as f:
        # A date-only record counts on its date in any zone. A timed record counts on its local date,
        # as in the digest, and so does a gate event.
        f.record('first-day', '2026-10-10', at=None)
        f.record('day-before', '2026-10-09', at=None)
        f.record('late', '2026-10-09', at='23:30:00+00:00')
        assert '**Date**: 2026-10-10\n' in (f.memory / 'sessions/2026-10/10-cem-first-day.md').read_text()
        f.gate({'at': '2026-10-09T23:30:00+00:00', 'kind': 'merge'})
        zones = all(Path('/usr/share/zoneinfo', zone).exists() for zone in ZONES)
        for zone in ZONES:
            data = f.vitals('--today', TODAY, env=dict(f.env, TZ=zone))
            if not zones:
                assert data['now']['sessions'] >= 1 and data['before']['sessions'] >= 1, (zone, data)
                continue
            # Kiritimati is UTC+14: 23:30 on the 9th is the 10th there.
            later = zone == 'Pacific/Kiritimati'
            assert (data['now']['sessions'], data['before']['sessions']) == (1 + later, 2 - later), (zone, data)
            assert (data['now']['merges'], data['before']['merges']) == (int(later), 1 - later), (zone, data)
        return None if zones else 'time zone data missing: the date-only checks ran alone'
test('edge dates: a period boundary, a month, one day; a date-only record keeps its date in every zone', edge_dates)


# 4 · Absence.

def absence():
    with fixture() as f:
        missing = f.temp / 'no-memory'
        assert f.line('--today', TODAY, memory=missing) == '' and f.probe(memory=missing) == ''
        data = f.vitals('--today', TODAY, memory=missing)
        assert data == {'days': 7, 'today': '2026-10-16', 'gate_coverage': 'missing',
                        'gate_capture_coverage': 'unknown', 'gate_counts_basis': 'observed_events',
                        'now': EMPTY, 'before': EMPTY}, data
        bare = f.temp / 'bare-memory'
        bare.mkdir()
        assert f.line('--today', TODAY, memory=bare) == '' and f.vitals('--today', TODAY, memory=bare)['now'] == EMPTY
        main_fixture(f)
        # A sessions folder that is a link is not followed.
        linked = f.temp / 'linked-memory'
        linked.mkdir()
        (linked / 'sessions').symlink_to(f.memory / 'sessions', target_is_directory=True)
        assert f.vitals('--today', TODAY, memory=linked)['now'] == EMPTY
        # Records off stops every vitals surface before it reads records.
        f.config['features']['session_records']['enabled'] = False
        f.save()
        assert f.line('--today', TODAY) == '' and f.scorecard('--today', TODAY) == {
            'status': 'disabled', 'reason': 'session-records-off', 'findings': []}
        assert f.cli('vitals', '--root', f.root, '--today', TODAY).stdout == 'Scorecard unavailable while session recording is off.\n'
        (f.root / 'egregore.json').unlink()
        assert f.line('--today', TODAY) == ''
        f.config['features']['session_records']['enabled'] = True
        f.save()
        # Files in the window that are no record are skipped; an unknown field changes nothing.
        f.write('2026-10/16-cem-garbage.md', 'no front matter at all\n')
        (f.memory / 'sessions/2026-10/16-cem-binary.md').write_bytes(b'\x00\xff\xfe' * 300)
        f.write('2026-10/16-cem-empty.md', '')
        assert f.vitals('--today', TODAY) == expected()
        # Blank, malformed, nested, non-object and unknown-kind gate lines are skipped; the good one counts.
        # The nested line stays within the reader's line bound, so it reaches the parser.
        f.gate('', '   ', 'not json', '{"kind": "merge"', '[1, 2]', '"merge"', '[' * 30000 + ']' * 30000,
               {'at': '2026-10-16T10:00:00+00:00', 'kind': 'hold'},
               {'at': '2026-10-16T10:00:00+00:00', 'kind': 'merge', 'unknown': [1, {'field': None}]})
        data = f.vitals('--today', TODAY)
        assert (data['now']['merges'], data['now']['refused'], data['before']['merges']) == (1, 0, 0), data
        assert f.line('--today', TODAY).splitlines()[0].endswith(' · observed 1 merge (partial)'), f.line('--today', TODAY)
        # A gate ledger that is a folder or a link is not read: numbers without the gate part.
        ledger = f.memory / 'sessions/gate.jsonl'
        ledger.unlink()
        ledger.mkdir()
        data = f.vitals('--today', TODAY)
        assert ' merge' not in f.line('--today', TODAY) and (data['gate_coverage'], data['now']['merges']) == ('unavailable', None)
        ledger.rmdir()
        target = f.temp / 'elsewhere.jsonl'
        target.write_text(json.dumps({'at': '2026-10-16T10:00:00+00:00', 'kind': 'merge'}) + '\n')
        ledger.symlink_to(target)
        data = f.vitals('--today', TODAY)
        assert (data['gate_coverage'], data['now']['merges']) == ('unavailable', None), data
        ledger.unlink()
        # A FIFO in its place is never opened, so the read cannot block, and it is not an empty ledger.
        os.mkfifo(ledger)
        data = f.vitals('--today', TODAY)
        assert (data['gate_coverage'], data['now']['merges']) == ('unavailable', None), data
        ledger.unlink()
        assert f.line('--today', TODAY) == ('7 days: 6 sessions (3 claude, 2 codex, 1 unknown) · $19 · friction 3.2 a session\n'
                                             'before: 3 sessions (2 claude, 1 pi) · $22 · friction 2.5\n')
test('absence: no memory, no sessions, records off, no gate ledger, and lines and files a reader skips', absence)


def malformed_costs():
    with fixture() as f:
        # An invalid cost is unpriced; known costs still contribute to the subtotal.
        for name, cost in (('true', True), ('nan', 'nan'), ('inf', 'inf'), ('negative', -5), ('null', None),
                           ('list', [1]), ('text', '12.5'), ('number', 0.25)):
            f.record('cost-' + name, '2026-10-16', cost=cost)
        assert 'cost_usd: true\n' in (f.memory / 'sessions/2026-10/16-cem-cost-true.md').read_text()
        data = f.vitals('--today', TODAY)
        assert (data['now']['sessions'], data['now']['cost_usd']) == (8, 12.75), data
        assert f.line('--today', TODAY) == '7 days: 8 sessions · $13 (2/8 priced) · friction 0.0 a session\n'
test('invalid cost is unpriced; known costs have an explicit denominator', malformed_costs)


# 5 · Held and backfilled records.

def held_and_backfilled():
    with fixture() as f:
        # The writer drops a held session's body, so its stub has no Friction section and no harness.
        held = f.record('held', '2026-10-15', harness='codex', cost=2.00, stub=True, friction=['- tool errors: Bash 9'])
        past = f.record('past', '2026-10-14', cost=1.25, backfill=True, friction=[
            '- tool errors: 0', '- non-zero exits: Bash 1, git 2, npm 3', '- worktree-guard refusals: 2',
            '- recall failures: keyword/timeout 1, semantic/sandbox 1, hybrid/interrupted 1',
            '- sleep commands: 12, 30.0 minutes', '- compactions: 5', '- subagent transcripts unavailable: 4'])
        text = held.read_text()
        assert 'detail: stub' in text and '## Friction' not in text and 'harness' not in text, text
        assert 'backfill: true' in past.read_text()
        data = f.vitals('--today', TODAY)
        # Both are sessions; the stub adds its cost and stays out of the friction average.
        assert data['now'] == dict(EMPTY, sessions=2, by_harness={'claude': 1, 'unknown': 1}, cost_usd=3.25,
                                         priced_sessions=2, friction=11.0, friction_sessions=1), data
        # The parser reads what the writer writes: an outline built from session facts.
        facts = {'harness': 'claude', 'first': 1760600000.0, 'last': 1760603600.0, 'calls': {}, 'tools': {
            '1': {'name': 'Bash', 'input': {'command': 'ls missing'}, 'error': True, 'nonzero_exit': True,
                  'result': 'exit 2'},
            '2': {'name': 'Edit', 'input': {'file_path': str(f.root / 'a.py')}, 'error': True, 'result': 'boom'},
            '3': {'name': 'Edit', 'input': {'file_path': str(f.root / 'b.py')}, 'error': True, 'result': 'boom'},
            '4': {'name': 'Bash', 'input': {'command': "bash bin/search.sh find 'x' --kind semantic"}, 'error': True,
                  'nonzero_exit': True, 'result': 'timed out'}}}
        outline = st.outline(facts, repo=f.root)
        friction = outline['sections']['Friction'].splitlines()
        assert friction[:4] == ['- tool errors: Edit 2', '- non-zero exits: Bash 2', '- worktree-guard refusals: 0',
                                '- recall failures: semantic/timeout 1'], friction
        assert sr.record_friction(outline['body']) == 5
        # A prompt excerpt in a full record comes before the writer's Friction section and is not read as one.
        excerpt = '## Prompts\n- 09:00 a pasted note\n## Friction\n- tool errors: Bash 900\n\n'
        assert sr.record_friction(excerpt + outline['body']) == 5
        assert sr.record_friction('## Friction\n- tool errors: Bash 3\n\n## Cost\n- tool errors: Bash 7\n') == 3
        assert sr.record_friction('## Summary\nno friction section\n') is None
        # Negative space: labels the reader must not count and counts it must not read. Only the
        # indented recall line counts, as its label and count are the writer's.
        assert sr.record_friction('## Friction\n- sleep commands: 9, 4.0 minutes\n- compactions: 9\n'
                                  '- subagent transcripts unavailable: 9\n- tool errors were 9\n- tool error: Bash 9\n'
                                  '- tool errors: Bash 1234567890\n- non-zero exits: Bash 3 times\n'
                                  '  - recall failures: keyword/error 2\n') == 2
test('held and backfilled records are sessions; a stub adds cost and no friction; Friction lines sum right',
     held_and_backfilled)

def unknown_is_not_zero():
    with fixture() as f:
        for name in ('a', 'b'):
            path = f.record(name, TODAY, harness='codex', cost=0, friction=None)
            path.write_text(path.read_text().replace('cost_source: list price', 'cost_source: unavailable'))
        period = f.vitals('--today', TODAY)['now']
        assert period['cost_usd'] is None and period['priced_sessions'] == 0, period
        assert period['friction'] is None and period['friction_sessions'] == 0, period
        assert period['merges'] is None, period
        # With no gate ledger beside the records, coverage is missing, which is not the same as unreadable.
        assert f.vitals('--today', TODAY)['gate_coverage'] == 'missing'
        assert 'cost unavailable · friction unavailable' in f.line('--today', TODAY)
        # A present, empty ledger has zero observed events, with capture coverage unknown.
        f.gate()
        data = f.vitals('--today', TODAY)
        assert data['gate_coverage'] == 'complete' and data['now']['merges'] == 0, data
        assert data['gate_capture_coverage'] == 'unknown' and data['gate_counts_basis'] == 'observed_events'
        # The whole ledger is read, past the megabyte an older reader kept: an event at its start counts.
        ledger = f.memory / 'sessions/gate.jsonl'
        first = {'at': '2026-10-16T09:00:00+00:00', 'kind': 'merge'}
        ledger.write_text(json.dumps(first) + '\n' + (' ' * 60000 + '\n') * 18)
        assert ledger.stat().st_size > 1024 * 1024
        data = f.vitals('--today', TODAY)
        assert (data['gate_coverage'], data['now']['merges']) == ('complete', 1), data
        # Blank lines leave the read complete; a line that does not parse makes it partial.
        for lines, coverage in ((('', '   '), 'complete'), (('not json',), 'partial')):
            f.gate(first, *lines)
            data = f.vitals('--today', TODAY)
            assert (data['gate_coverage'], data['now']['merges']) == (coverage, 1), (lines, data)
        # A line past the reader's bound is skipped, so the read is partial; the lines around it count.
        f.gate(first, json.dumps({'at': '2026-10-16T09:30:00+00:00', 'kind': 'merge', 'pad': 'x' * 70000}),
               {'at': '2026-10-16T10:00:00+00:00', 'kind': 'refuse'})
        data = f.vitals('--today', TODAY)
        assert (data['gate_coverage'], data['now']['merges'], data['now']['refused']) == ('partial', 1, 1), data
        # A ledger the reader cannot open is unavailable and carries no counts.
        if os.geteuid() != 0:
            ledger.chmod(0)
            try:
                data = f.vitals('--today', TODAY)
            finally:
                ledger.chmod(0o644)
            assert (data['gate_coverage'], data['now']['merges']) == ('unavailable', None), data
        # Missing harnesses are unknown, and unknown counter labels are not measured zero.
        assert sr.record_friction('## Friction\n- some future counter: 7\n') is None
        assert sr.record_friction('## Friction\n- tool errors: 0\n') == 0
test('unavailable cost, friction and gate counts remain distinct from observed zero', unknown_is_not_zero)


def personal_off_precedes_reads():
    with fixture() as f:
        main_fixture(f)
        (f.root / '.egregore-state.json').write_text(json.dumps({
            'github_username': 'cem', 'session_records_enabled': False}))
        audit = f.temp / 'opened-off.log'
        env = dict(f.env, PYTHONPATH=str(f.temp / 'audit'), OPEN_AUDIT_LOG=str(audit))
        assert f.line('--today', TODAY, env=env) == '' and f.probe(env=env) == ''
        assert not audit.exists(), 'record files were read despite personal records-off'
        # The action scorecard and explicit plain summary also stop before reads.
        assert f.scorecard('--today', TODAY, env=env) == {
            'status': 'disabled', 'reason': 'session-records-off', 'findings': []}
        result = f.cli('vitals', '--root', f.root, '--findings', env=env)
        assert result.stdout == 'Scorecard unavailable while session recording is off.\n'
        assert not audit.exists()
        assert f.cli('vitals', '--root', f.root, '--today', TODAY, env=env).stdout == 'Scorecard unavailable while session recording is off.\n'
        assert not audit.exists()
test('personal records-off silences the startup probe before any record read', personal_off_precedes_reads)

def findings_from_measurements():
    with fixture() as f:
        main_fixture(f)
        data = f.scorecard('--today', TODAY)
        findings = {item['code']: item for item in data['findings']}
        assert set(findings) == {'harness_coverage_gap', 'friction_coverage_gap', 'friction_signal',
                                 'gate_coverage_gap', 'gate_capture_coverage_gap', 'ci_retries_observed', 'gate_refusals_observed',
                                 'ci_flakes_observed', 'accepted_outcome_link_missing'}, findings
        for finding in findings.values():
            assert {'code', 'severity', 'observation', 'coverage', 'action', 'verification'} <= set(finding), finding
            assert finding['severity'] in ('warning', 'info') and all(
                finding[key] for key in ('observation', 'coverage', 'action', 'verification')), finding
        assert findings['harness_coverage_gap']['coverage']['unknown'] == {'now': 1, 'before': 0}
        assert findings['friction_signal']['coverage']['now'] == {'observed': 5, 'total': 6}
        assert 'overlap' in findings['friction_signal']['coverage']['limitation']
        assert findings['ci_retries_observed']['coverage']['observed_decisions'] == 2
        assert findings['gate_refusals_observed']['coverage']['refusals'] == 2
        assert findings['gate_coverage_gap']['coverage']['ledger'] == 'partial'
        # Explicit text uses the same proposals, stays within the terminal frame,
        # and names a concrete next action and verification for every observation.
        text = f.cli('vitals', '--root', f.root, '--today', TODAY, '--findings').stdout
        assert text.startswith('┌') and all(len(line) == 72 for line in text.splitlines()), text
        assert text.count('Verify:') == len(findings) and 'RECORDS SCORECARD' in text
        before = snapshot(f.temp)
        from unittest.mock import patch
        with patch.object(sr, 'model_call', side_effect=AssertionError('scorecard called a model')), \
             patch.object(subprocess, 'Popen', side_effect=AssertionError('scorecard spawned a process')):
            assert observations(sr.vitals(f.memory, today=TODAY)) == observations(data)
            import record_outcomes as ro
            outcome = ro.scorecard(sr, f.memory)
            assert outcome.pop('unit_economics') == data['unit_economics']
            outcome.pop('findings')
            assert outcome == data['outcome_scorecard']
        assert snapshot(f.temp) == before
test('each measured finding carries evidence, coverage, an action and verification without writes or models',
     findings_from_measurements)


def findings_missing_and_zero():
    with fixture() as f:
        empty = f.scorecard('--today', TODAY)
        assert {x['code'] for x in empty['findings']} == {
            'records_missing', 'gate_coverage_gap', 'gate_capture_coverage_gap', 'accepted_outcome_link_missing'}, empty
        for name in ('a', 'b'):
            path = f.record(name, TODAY, harness='codex', friction=None)
            path.write_text(path.read_text().replace('cost_source: list price', 'cost_source: unavailable'))
        missing = f.scorecard('--today', TODAY)
        findings = {x['code']: x for x in missing['findings']}
        assert findings['cost_coverage_gap']['coverage']['now'] == {'observed': 0, 'total': 2}, findings
        assert findings['gate_coverage_gap']['coverage']['merges'] is None
        assert 'friction_signal' not in findings and 'ci_retries_observed' not in findings
        assert 'gate_refusals_observed' not in findings and missing['now']['retried_decisions'] is None
        # Measured zero is a real observation; it does not request a retry or refusal repair.
        for name in ('a', 'b'):
            f.record(name, TODAY, harness='codex', friction=ZERO, cost=0)
        f.gate({'at': '2026-10-16T12:00:00+00:00', 'kind': 'merge', 'attempts': 1},
               {'at': '2026-10-16T12:01:00+00:00', 'kind': 'merge', 'attempts': True})
        zero = f.scorecard('--today', TODAY)
        findings = {x['code']: x for x in zero['findings']}
        assert zero['now']['retried_decisions'] == 0 and zero['now']['retry_observations'] == 1
        assert zero['now']['friction'] == 0 and zero['now']['cost_usd'] == 0
        assert set(findings) == {'friction_signal', 'gate_capture_coverage_gap', 'accepted_outcome_link_missing'}, findings
        assert findings['friction_signal']['severity'] == 'info'
test('missing coverage creates a repair proposal; measured zero never fabricates failures', findings_missing_and_zero)

def file_coverage_is_not_capture_coverage():
    with fixture() as f:
        f.record('current', TODAY)
        f.record('previous', TODAY - timedelta(days=7))
        f.gate({'at': '2026-10-16T12:00:00+00:00', 'kind': 'merge', 'attempts': 1})
        data = f.scorecard('--today', TODAY)
        assert data['gate_coverage'] == 'complete'
        assert data['gate_capture_coverage'] == 'unknown'
        assert data['gate_counts_basis'] == 'observed_events'
        assert data['now']['merges'] == 1 and data['before']['merges'] == 0
        assert data['now']['refused'] == 0 and data['before']['refused'] == 0
        findings = {item['code']: item for item in data['findings']}
        assert 'gate_coverage_gap' not in findings
        gap = findings['gate_capture_coverage_gap']
        assert gap['coverage']['ledger'] == 'complete' and gap['coverage']['temporal'] == 'unknown'
        assert 'prospective capture window' in gap['action']
        assert 'first event does not establish capture start' in gap['verification']
        assert 'zero observed events never asserts zero actual decisions' in gap['verification']
        assert 'gate_refusals_observed' not in findings and 'ci_retries_observed' not in findings
        text = f.cli('vitals', '--root', f.root, '--today', TODAY).stdout
        assert 'observed 1 merge' in text and 'observed 0 merges' in text, text
        # Even an empty, completely read file leaves historical capture unknown.
        f.gate()
        data = f.scorecard('--today', TODAY)
        assert data['gate_coverage'] == 'complete' and data['gate_capture_coverage'] == 'unknown'
        assert data['before']['merges'] == 0
        assert 'gate_capture_coverage_gap' in {item['code'] for item in data['findings']}
test('a complete ledger read never establishes historical capture or zero actual decisions',
     file_coverage_is_not_capture_coverage)


def held_findings_and_economics():
    with fixture() as f:
        f.record('held', TODAY, harness='codex', stub=True, cost=4, friction=['- tool errors: Bash 900'])
        f.record('current', TODAY, cost=1, friction=ZERO)
        f.record('previous', TODAY - timedelta(days=7), cost=100, friction=['- tool errors: Bash 8'])
        f.gate(*[{'at': '2026-10-16T12:00:00+00:00', 'kind': 'merge', 'attempts': 1, 'pr': i}
                 for i in range(10)])
        before = snapshot(f.temp)
        data = f.scorecard('--today', TODAY)
        assert data['now']['by_harness'] == {'claude': 1, 'unknown': 1}
        assert data['now']['friction_sessions'] == 1 and data['now']['friction'] == 0
        assert data['now']['cost_usd'] == 5 and data['before']['cost_usd'] == 100
        assert data['now']['merges'] == 10
        assert data['unit_economics']['status'] == 'unavailable'
        assert data['unit_economics']['cost_per_accepted_outcome_usd'] is None
        assert data['unit_economics']['accepted_outcomes'] is None
        findings = {x['code']: x for x in data['findings']}
        assert 'accepted_outcome_link_missing' in findings
        assert not {'unit_economics_improved', 'cost_reduction', 'improvement'} & findings.keys()
        assert 'held stubs remain unchanged' in findings['harness_coverage_gap']['verification']
        assert snapshot(f.temp) == before
test('held data stays withheld and lower cost with more merges never becomes improved unit economics',
     held_findings_and_economics)


# 6 · The budget.

def budget():
    with fixture() as f:
        names = [f'harness-{index}-' + 'x' * 40 for index in range(4)]
        heavy = ['- tool errors: Bash 999999999, Edit 999999999', '- recall failures: keyword/timeout 999999999']
        for index in range(8):
            f.record(f'long-{index}', TODAY - timedelta(days=index % 7), harness=names[index % 4],
                     cost=123456789.99, friction=heavy)
            f.record(f'older-{index}', TODAY - timedelta(days=7 + index % 7), harness=names[index % 4],
                     cost=98765432.10, friction=heavy)
        stamp = datetime(2026, 10, 16, 6, 0, tzinfo=timezone.utc)
        f.gate(*[{'at': (stamp - timedelta(minutes=index)).isoformat(), 'kind': 'merge', 'receipt': True,
                  'flaked': ['Mind fast contracts', 'Shell contracts', 'Runtime']} for index in range(1500)],
               *[{'at': (stamp - timedelta(days=8, minutes=index)).isoformat(), 'kind': 'refuse'} for index in range(500)])
        lines = f.line('--today', TODAY).splitlines()
        assert len(lines) == 2 and all(len(line) <= sr.REFLEX_LINE for line in lines), [len(line) for line in lines]
        # Four long names do not fit beside the rest, so the breakdown gives way.
        assert lines[0] == ('7 days: 8 sessions · $987,654,320 · friction 2999999997.0 a session '
                            '· observed 1500 merges, 4500 flaked, 1500 receipts'), lines[0]
        assert lines[1] == 'before: 8 sessions · $790,123,457 · friction 2999999997.0 · observed 0 merges, 500 refused', lines[1]
    huge = {'sessions': 10 ** 12, 'by_harness': {name: 10 ** 11 for name in ('claude', 'codex', 'pi', 'prime')},
            'cost_usd': 10.0 ** 15, 'friction': 123456789.1, 'merges': 10 ** 12, 'refused': 10 ** 12,
            'flaked': 10 ** 12, 'receipts': 10 ** 12}
    for quiet in (True, False):
        text = sr.vitals_line({'days': sr.VITALS_MAX_DAYS, 'now': huge, 'before': huge}, quiet=quiet)
        assert len(text.splitlines()) == 2 and all(len(line) <= sr.REFLEX_LINE for line in text.splitlines()), text
test('budget: every line stays within 160 characters with long harness names and large numbers', budget)


def latency():
    with fixture() as f:
        today = datetime.now(timezone.utc).date()
        for index in range(150):
            f.record(f'bulk-{index:03d}', today - timedelta(days=index % 14), harness=('claude', 'codex', 'pi')[index % 3],
                     cost=index / 10, pad=60000 if index % 15 == 0 else 3000,
                     friction=['- tool errors: Bash 2, Edit 1', '- non-zero exits: Bash 1', '- worktree-guard refusals: 0',
                               '- recall failures: keyword/timeout 1', '- sleep commands: 1, 0.5 minutes', '- compactions: 1'])
        for index in range(30):
            f.record(f'old-{index:02d}', today - timedelta(days=20 + index), cost=1.0)
        now = datetime.now(timezone.utc)
        f.gate(*[{'at': (now - timedelta(hours=index)).isoformat(), 'kind': 'refuse' if index % 4 == 0 else 'merge',
                  'flaked': ['Runtime'] if index % 7 == 0 else [], 'attempts': 1} for index in range(300)])
        line = f.probe()
        assert line.startswith('7 days: ') and line.count('\n') == 2, line
        timings = []
        for _ in range(3):
            started = time.monotonic()
            assert f.line() == line
            timings.append(time.monotonic() - started)
        elapsed = statistics.median(timings)
        # A contract on a laptop, a reading with a ceiling on a shared one-CPU runner (510–620 ms there).
        assert elapsed * 1000 < timing.limit(500), (timing.note(elapsed * 1000, 500), timings)
        # Each record of the two periods is read once; nothing older than the window's day either side is opened.
        audit = f.temp / 'opened.log'
        env = dict(f.env, PYTHONPATH=str(f.temp / 'audit'), OPEN_AUDIT_LOG=str(audit))
        assert f.line(env=env) == line
        opened = Counter(Path(path).name for path in audit.read_text().splitlines())
        assert set(opened) == {f'{(today - timedelta(days=index % 14)):%d}-cem-bulk-{index:03d}.md'
                               for index in range(150)}, sorted(opened)
        assert set(opened.values()) == {1}, opened.most_common(3)
        data = f.vitals()
        assert data['now']['sessions'] + data['before']['sessions'] == 150, data
        return f'median {timing.note(elapsed * 1000, 500)} over 3 runs on 150 records, {len(opened)} record files read once'
test('latency: vitals-line on 150 records finishes under 500 ms and reads each record once', latency)


# 7 · The probe.

def probe_through_runner():
    with fixture() as f:
        today = datetime.now(timezone.utc).date()
        main_fixture(f, shift=today - TODAY)
        card = '  ◦ ' + LINE_NOW + '\n  ◦ ' + LINE_BEFORE + '\n'
        assert f.probe() == LINE_NOW + '\n' + LINE_BEFORE + '\n'
        result = f.runner()
        assert result.returncode == 0 and result.stdout == card, result.stdout + result.stderr
        # Every startup card runs the same runner; the harness changes nothing in the line.
        for harness in ('claude', 'codex', 'pi', 'prime'):
            result = f.runner('--memory', str(f.memory), '--author', 'cem', '--harness', harness)
            assert result.stdout == card, (harness, result.stdout)
        # records.sh routes vitals to the same numbers.
        for args, output in ((('vitals',), LINE_NOW + '\n' + LINE_BEFORE + '\n'),
                             (('vitals', '--json'), json.dumps(f.scorecard()) + '\n')):
            result = subprocess.run(['bash', str(f.root / 'bin/records.sh'), *args], env=f.env, cwd=f.root,
                                    capture_output=True, text=True, timeout=30)
            assert result.returncode == 0 and result.stdout == output, (args, result.stdout + result.stderr)
        # The vitals open the probe block, before the open-items line.
        shutil.copy2(ROOT / 'bin/reflexes/10-open-items.sh', f.root / 'bin/reflexes/10-open-items.sh')
        f.record('open', today, open_lines=['Ship the fixture vitals — cem'])
        lines = f.runner().stdout.splitlines()
        assert lines[0].startswith('  ◦ 7 days: 7 sessions (4 claude, 2 codex, 1 unknown) · ') and lines[1].startswith('  ◦ before: '), lines
        assert lines[2].startswith('  ◦ 1 open item carried (oldest 0d: "Ship the fixture vitals")'), lines
        (f.root / 'bin/reflexes/10-open-items.sh').unlink()
        (f.memory / f'sessions/{today:%Y-%m}/{today:%d}-cem-open.md').unlink()
        # It writes nothing anywhere: the project, the memory and the home are as they
        # were, apart from the card the runner keeps in the instance's runtime state.
        def written():
            return {path: info for path, info in snapshot(f.temp).items()
                    if path not in ('project/.egregore', 'project/.egregore/runtime')
                    and not path.startswith('project/.egregore/runtime/reflexes')}
        before = written()
        assert f.runner().stdout == card and f.probe() == LINE_NOW + '\n' + LINE_BEFORE + '\n'
        assert written() == before
        # Without a project root the probe says nothing and succeeds.
        result = subprocess.run(['bash', str(f.root / 'bin/reflexes/05-vitals.sh')], env=f.env,
                                capture_output=True, text=True, timeout=10)
        assert (result.returncode, result.stdout, result.stderr) == (0, '', ''), result
        # Silent through the runner under two sessions: a probe that printed nothing, not one that failed.
        for path in list((f.memory / 'sessions').rglob('*.md')):
            path.unlink()
        f.record('alone', today)
        result = f.runner('--debug')
        assert result.stdout == '' and 'reflex 05-vitals.sh: silent, printed nothing' in result.stderr, result
test('the probe prints the line through the runner on every harness, after records.sh routes it, and writes nothing',
     probe_through_runner)

print(f'{PASSED} passed, {FAILED} failed')
sys.exit(1 if FAILED else 0)
PY
