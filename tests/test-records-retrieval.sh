#!/usr/bin/env bash
# Retrieval readings from disposable installation/worktree/organization fixtures.
# Never opens real records or episodes, reaches the network, or rewrites Git.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/tmp"
python3 - "$ROOT" <<'PY'
import contextlib
from datetime import date, datetime, timedelta, timezone
import json
import io
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

ROOT = Path(sys.argv[1])
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'bin/lib'))
import budget
import retrieval_scorecard as rs
import session_record as sr

TODAY = date(2026, 10, 16)
ZERO_RECORDS = ['- publish-artifact: 0 calls', '- notify.sh: 0 calls']
PASSED = FAILED = 0
os.environ['TZ'] = 'UTC'
time.tzset()


class Fixture:
    def __init__(self):
        self.temp = Path(tempfile.mkdtemp(prefix='retrieval-', dir=ROOT / 'tmp'))
        self.root = self.temp / 'installation'
        self.memory = self.temp / 'organization-memory'
        self.home = self.temp / 'home'
        self.worktree = self.root / '.claude/worktrees/task'
        for path in (self.root / 'bin/lib', self.root / 'bin/reflexes', self.root / 'egregore_runtime',
                     self.memory / 'sessions', self.home, self.worktree, self.root / '.git/worktrees/task'):
            path.mkdir(parents=True, exist_ok=True)
        for name in ('records.sh', 'reflexes.sh'):
            shutil.copy2(ROOT / 'bin' / name, self.root / 'bin' / name)
        for name in ('retrieval_scorecard.py', 'session_record.py', 'session_trail.py', 'reflexes.py'):
            shutil.copy2(ROOT / 'bin/lib' / name, self.root / 'bin/lib' / name)
        shutil.copy2(ROOT / 'bin/reflexes/15-retrieval.sh', self.root / 'bin/reflexes/15-retrieval.sh')
        # Only installation resolution is needed; no Runtime adapters or network.
        (self.root / 'egregore_runtime/__init__.py').write_text('')
        shutil.copy2(ROOT / 'egregore_runtime/installation.py', self.root / 'egregore_runtime/installation.py')
        (self.worktree / '.git').write_text(f'gitdir: {self.root}/.git/worktrees/task\n')
        (self.root / '.git/worktrees/task/gitdir').write_text(str(self.worktree / '.git') + '\n')
        (self.root / 'memory').symlink_to(self.memory, target_is_directory=True)
        (self.worktree / 'memory').symlink_to(self.memory, target_is_directory=True)
        self.config = {'mode': 'local', 'features': {'session_records': {'enabled': True}}}
        self.save()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('GIT_', 'EGREGORE_', 'CLAUDE_', 'CODEX_', 'PYTHONPATH'))}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.temp), TZ='UTC',
                        PYTHONDONTWRITEBYTECODE='1', EGREGORE_NO_TELEMETRY='1')

    def save(self):
        for root in (self.root, self.worktree):
            (root / 'egregore.json').write_text(json.dumps(self.config))

    def episode(self, name, as_of, calls, *, opened=None, deliveries=None, root=None, mtime=None, **extra):
        path = (root or self.root) / '.egregore/runtime/investigations' / (name + '.json')
        path.parent.mkdir(parents=True, exist_ok=True)
        data = {'as_of': as_of, 'calls': calls, 'opened': opened or {}, 'deliveries': deliveries or {}}
        data.update(extra)
        path.write_text(json.dumps(data))
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def record(self, name, day, harness='claude', calls=None):
        day = date.fromisoformat(day) if isinstance(day, str) else day
        body = '## Asked\nfixture work\n'
        if calls is not None:
            body += '\n## Memory and artifacts\n' + '\n'.join(calls) + '\n'
        body += '\n## Friction\n- tool errors: 0\n'
        data = dict(author='fixture', session=name, date=day.isoformat() + 'T12:00:00+00:00',
                    detail='outline', status='final', record_revision=1, duration='10m',
                    topic='fixture ' + name, branch='dev/fixture/retrieval', harness=harness,
                    summary='fixture session', body=body)
        path = self.memory / 'sessions' / day.strftime('%Y-%m') / f'{day:%d}-fixture-{name}.md'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(sr.record_text(data))
        return path

    def notices(self, *notices, name='20261016-120000.jsonl'):
        path = self.root / '.egregore/runtime/mind/log' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps(notice) + '\n' for notice in notices))
        return path

    def score(self, **kwargs):
        return rs.scorecard(kwargs.pop('root', self.root), today=kwargs.pop('today', TODAY), **kwargs)

    def cli(self, *args, line=False, dispatch=False, env=None):
        cmd = (['bash', str(self.root / 'bin/records.sh'), 'retrieval'] if dispatch else
               [sys.executable, str(self.root / 'bin/lib/retrieval_scorecard.py')] + (['line'] if line else []) +
               ['--root', str(self.root)])
        return subprocess.run(cmd + list(map(str, args)), env=env or self.env, cwd=self.root,
                              capture_output=True, text=True, timeout=15)

    def probe(self, harness='codex'):
        env = dict(self.env, EGREGORE_ROOT=str(self.root), EGREGORE_MEMORY=str(self.root / 'memory'),
                   EGREGORE_HARNESS=harness)
        return subprocess.run(['bash', str(self.root / 'bin/reflexes/15-retrieval.sh')],
                              env=env, cwd=self.root, capture_output=True, text=True, timeout=5)


@contextlib.contextmanager
def fixture():
    f = Fixture()
    try:
        yield f
    finally:
        shutil.rmtree(f.temp)


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


def equal(actual, expected):
    assert actual == expected, f'{actual!r} != {expected!r}'


def near(actual, expected):
    assert isinstance(actual, (float, int)) and math.isclose(actual, expected, abs_tol=1e-9), (actual, expected)


def ok(result):
    assert result.returncode == 0 and result.stderr == '', result.stdout + result.stderr
    return result.stdout


def discover(invocation, kind='hybrid', **fields):
    return dict(operation='discover', origin='find', kind=kind, invocation_id=invocation, **fields)


def simple(invocation, **fields):
    return discover(invocation, ok=True, new_sources=1, delivery='stdout', seconds=1, **fields)


def main_fixture(f, shift=timedelta(0)):
    def stamp(value):
        return (datetime.fromisoformat(value) + shift).isoformat()
    def day(value):
        return date.fromisoformat(value) + shift
    def call(inv, kind, number, **fields):
        return discover(inv, kind, seconds=number, phase_ms={'authorization': number * 10,
                        'revision_check': number * 100}, **fields)
    f.episode('a', stamp('2026-10-16T12:00:00+00:00'), [
        call('a1', 'hybrid', 1, ok=True, delivery='stdout', new_sources=2),
        call('a2', 'keyword', 3, ok=True, delivery='packet_ready', new_sources=0),
        call('a3', 'semantic', 5, ok=False, error_code='backend_error'),
        call('a4', 'filename', 7, ok=True, delivery='packet_ready', new_sources=0),
        call('a5', 'literal', 9, ok=False),
        {'operation': 'open', 'seconds': 2, 'phase_ms': {'authorization': 20, 'revision_check': 200}},
        {'operation': 'open_many', 'seconds': 4, 'phase_ms': {'authorization': 40, 'revision_check': 400}},
    ], opened={'memory/fixture/a.md': {}}, deliveries={
        'packet-a4': {'invocation_id': 'a4', 'status': 'attachment_prepared'},
        'not-a-lookup': {'invocation_id': 'unmatched', 'status': 'attachment_prepared'},
    })
    f.episode('b', stamp('2026-10-12T12:00:00+00:00'), [
        discover('b1', 'dates', ok=True, delivery='stdout_truncated', new_sources=0, seconds=11),
        discover('b2', 'hybrid', ok=True, seconds=13),
    ], root=f.worktree)
    f.episode('c', stamp('2026-10-10T12:00:00+00:00'), [
        discover('c1', 'keyword', ok=True, delivery='packet_ready', new_sources=1, seconds=15),
    ], deliveries={'wrong': {'invocation_id': 'not-c1', 'status': 'attachment_prepared'}})
    f.episode('open-only', stamp('2026-10-14T12:00:00+00:00'), [
        {'operation': 'open', 'seconds': 6}], opened={'memory/fixture/open.md': {}})
    # Starting one second before midnight: even its later calls stay in the earlier cohort.
    f.episode('boundary', stamp('2026-10-09T23:59:59+00:00'), [
        discover('p1', 'semantic', ok=True, delivery='stdout', new_sources=1, seconds=4),
        discover('p2', 'literal', ok=False, error_code='budget_exhausted', seconds=6),
        {'operation': 'open_many', 'seconds': 2}], opened={'memory/fixture/previous.md': {}})
    f.episode('previous', stamp('2026-10-03T12:00:00+00:00'), [
        discover('p3', 'hybrid', ok=True, delivery='packet_ready', new_sources=0, seconds=8),
    ], deliveries={'packet-p3': {'invocation_id': 'p3', 'status': 'attachment_prepared'}})
    f.episode('outside', stamp('2026-10-02T12:00:00+00:00'), [simple('outside')])
    f.record('c-looked', day('2026-10-16'), 'codex', ['- find/hybrid: 2 calls, 0 failed', '- open/-: 3 calls, 0 failed'])
    f.record('c-idle', day('2026-10-15'), 'codex', ZERO_RECORDS)
    f.record('a-looked', day('2026-10-12'), 'claude', ['- query/keyword: 1 calls, 1 failed'])
    f.record('a-open-only', day('2026-10-10'), 'claude', ['- open_many/-: 2 calls, 0 failed'])
    f.record('p-unmeasured', day('2026-10-11'), 'pi', None)
    f.record('earlier-looked', day('2026-10-09'), 'prime', ['- find/semantic: 2 calls, 0 failed'])
    f.record('earlier-idle', day('2026-10-03'), 'claude', ZERO_RECORDS)


def hand_counted_periods():
    with fixture() as f:
        main_fixture(f)
        result = f.score()
        equal(result['days'], 7)
        now, before = result['now'], result['before']
        equal(now['boundaries'], {'start': '2026-10-10', 'end': '2026-10-16'})
        equal(before['boundaries'], {'start': '2026-10-03', 'end': '2026-10-09'})
        for period in (now, before):
            equal(period['completeness'], 'complete')
            equal(period['skipped_episodes'], 0)
            equal(period['installation']['scope'], 'installation')
            equal(period['organization']['scope'], 'organization')
        n, p = now['installation'], before['installation']
        for key, expected in dict(lookups=8, opens=3, failed=2, delivered=3, delivered_measured=5,
                                  delivered_total=6, empty=3, empty_measured=5, empty_total=6, episodes=4,
                                  read_after_lookup=1, lookups_without_read=2).items():
            equal(n[key], expected)
        equal(n['failed_by_cause'], {'backend_error': 1, 'unknown': 1})
        near(n['delivered_share'], 3 / 5)
        near(n['empty_share'], 3 / 5)
        near(n['refinements']['median'], 1.5)
        near(n['refinements']['p90'], 4.1)
        equal(n['kinds'], {'hybrid': 2, 'keyword': 2, 'semantic': 1, 'filename': 1, 'literal': 1, 'dates': 1})
        equal(n['latency_s']['discover']['measured'], 8)
        equal(n['latency_s']['discover']['total'], 8)
        near(n['latency_s']['discover']['p50'], 8)
        near(n['latency_s']['discover']['p95'], 14.3)
        equal(n['latency_s']['open']['measured'], 3)
        equal(n['latency_s']['open']['total'], 3)
        near(n['latency_s']['open']['p50'], 4)
        near(n['latency_s']['open']['p95'], 5.8)
        equal(n['phase_ms_p50'], {'authorization': 40, 'revision_check': 400})
        equal(n['grounding'], None)
        equal(n['grounding_coverage'], 'unavailable')
        for key, expected in dict(lookups=3, opens=1, failed=1, delivered=2, delivered_measured=2,
                                  delivered_total=2, empty=1, empty_measured=2, empty_total=2, episodes=2,
                                  read_after_lookup=1, lookups_without_read=1).items():
            equal(p[key], expected)
        equal(p['failed_by_cause'], {'budget_exhausted': 1})
        equal(p['kinds'], {'semantic': 1, 'literal': 1, 'hybrid': 1})
        near(p['delivered_share'], 1)
        near(p['empty_share'], 0.5)
        near(p['refinements']['median'], 1.5)
        near(p['refinements']['p90'], 1.9)
        near(p['latency_s']['discover']['p50'], 6)
        near(p['latency_s']['discover']['p95'], 7.8)
        near(p['latency_s']['open']['p50'], 2)
        near(p['latency_s']['open']['p95'], 2)
        equal(p['phase_ms_p50'], None)
        equal(result['coverage']['episodes_read'], 7)
        equal(result['coverage']['records_read'], 7)
        equal(result['coverage']['unattributed'], 0)
        equal(result['coverage']['preselected_by_mtime'], False)
        equal(result['coverage']['cap_reached'], False)
        equal(result['coverage']['observation_cutoff'], '2026-10-16T12:00:00+00:00')
        equal(result['coverage']['oldest_as_of'], '2026-10-02T12:00:00+00:00')
        descriptions = result['field_descriptions']
        for key in ('read_after_lookup', 'lookups_without_read'):
            assert 'episode' in descriptions[key].lower() and 'opened' in descriptions[key].lower(), descriptions
        assert any(word in descriptions['read_after_lookup'].lower() for word in ('nonempty', 'non-empty')), descriptions
        assert 'empty' in descriptions['lookups_without_read'].lower(), descriptions


def organizational_reach():
    with fixture() as f:
        main_fixture(f)
        result = f.score()
        n, p = result['now']['organization'], result['before']['organization']
        equal(n['sessions'], 5)
        equal(n['sessions_by_harness'], {'codex': 2, 'claude': 2, 'pi': 1})
        equal(n['sessions_without_lookup'], 2)
        equal(n['sessions_without_lookup_by_harness'], {'codex': 1, 'claude': 1, 'pi': None})
        equal(n['sessions_lookup_measured'], 4)
        equal((n['records_zero_calls'], n['records_measured'], n['records_total']), (2, 4, 5))
        equal(p['sessions'], 2)
        equal(p['sessions_by_harness'], {'claude': 1, 'prime': 1})
        equal(p['sessions_without_lookup'], 1)
        equal(p['sessions_without_lookup_by_harness'], {'claude': 1, 'prime': 0})
        equal(p['sessions_lookup_measured'], 2)
        equal((p['records_zero_calls'], p['records_measured'], p['records_total']), (1, 2, 2))
        # Run from the linked worktree: installation episodes are pooled, organization records unchanged.
        same = f.score(root=f.worktree)
        equal(same['now']['installation'], result['now']['installation'])
        equal(same['now']['organization'], n)
        # A second linked name for a verified worktree is resolved once, not counted twice.
        (f.root / '.claude/worktrees/task-alias').symlink_to(f.worktree, target_is_directory=True)
        equal(f.score()['coverage']['episodes_read'], 7)


def grounding_union():
    with fixture() as f:
        main_fixture(f)
        f.notices(
            {'k': 'seen', 'op': 'discover', 'invocation': 'a1', 'lookup': 'hybrid', 'shown': ['memory/fixture/a.md']},
            {'k': 'seen', 'op': 'discover', 'invocation': 'a1', 'lookup': 'hybrid', 'shown': ['memory/fixture/a.md', 'memory/fixture/b.md']},
            {'k': 'seen', 'op': 'discover', 'invocation': 'a2', 'shown': []},
            {'k': 'seen', 'op': 'discover', 'invocation': 'b1', 'kind': 'dates', 'paths': ['memory/fixture/c.md']},
            {'k': 'seen', 'op': 'discover', 'invocation': 'unmatched', 'shown': ['memory/fixture/outside.md']},
            {'k': 'seen', 'op': 'discover', 'invocation': '', 'shown': ['memory/fixture/empty.md']},
            {'k': 'seen', 'op': 'discover', 'shown': ['memory/fixture/missing.md']},
            {'k': 'delivered', 'invocation': 'b2', 'shown': ['memory/fixture/not-seen.md']},
            {'k': 'seen', 'op': 'discover', 'invocation': 'p1', 'shown': ['memory/fixture/previous.md']},
        )
        result = f.score()
        n, p = result['now']['installation'], result['before']['installation']
        equal(n['grounding_coverage'], {'correlated': 3, 'total': 8})
        near(n['grounding']['lookups_with_shown_path'], 2 / 3)
        near(n['grounding']['shown_paths_per_lookup'], 1)
        equal(n['grounding']['measured'], 3)
        equal(n['grounding']['total'], 8)
        equal(p['grounding_coverage'], {'correlated': 1, 'total': 3})
        near(p['grounding']['lookups_with_shown_path'], 1)
        near(p['grounding']['shown_paths_per_lookup'], 1)
        # IDs absent on both sides do not create a correlation.
        f.episode('no-id', '2026-10-16T14:00:00+00:00', [simple(None), simple('')])
        n = f.score()['now']['installation']
        equal(n['grounding_coverage'], {'correlated': 3, 'total': 10})


def partial_telemetry():
    with fixture() as f:
        calls = [discover(f'i{i}', ok=True, **({'new_sources': 0 if i < 2 else 1} if i < 5 else {}))
                 for i in range(10)]
        f.episode('partial', '2026-10-16T12:00:00Z', calls)
        n = f.score()['now']['installation']
        equal(n['lookups'], 10)
        equal((n['empty'], n['empty_measured'], n['empty_total']), (2, 5, 10))
        near(n['empty_share'], 2 / 5)
        equal((n['delivered'], n['delivered_measured'], n['delivered_total']), (None, 0, 10))
        equal(n['delivered_share'], None)
        equal(n['latency_s']['discover'], {'p50': None, 'p95': None, 'measured': 0, 'total': 10})
        equal(n['phase_ms_p50'], None)
        # Neither an uncorrelated receipt nor a blank-ID receipt measures a call.
        f.episode('partial', '2026-10-16T12:00:00Z', calls, deliveries={
            'wrong': {'invocation_id': 'absent', 'status': 'attachment_prepared'},
            'blank': {'invocation_id': '', 'status': 'attachment_prepared'}})
        n = f.score()['now']['installation']
        equal(n['delivered_measured'], 0)
        equal(n['delivered_share'], None)
    with fixture() as f:
        path = f.episode('unknown-fields', '2026-10-16T12:00:00Z', [
            discover('one', new_sources=0, seconds=True),
            discover('two', ok=True, new_sources=True, seconds=-1),
            discover('three', kind=['malformed'], ok=True, new_sources=-1, seconds=10 ** 400),
        ])
        data = json.loads(path.read_text())
        del data['opened']
        path.write_text(json.dumps(data))
        n = f.score()['now']['installation']
        equal(n['lookups'], 3)
        equal(n['failed_measured'], 2)
        equal(n['empty_measured'], 0)
        equal(n['empty_share'], None)
        equal(n['read_after_lookup'], None)
        equal(n['lookups_without_read'], None)
        equal(n['read_measured'], 0)
        equal(n['read_total'], 1)
        equal(n['latency_s']['discover']['measured'], 0)
        equal(n['kinds'], {'hybrid': 2, 'unknown': 1})


def skipped_uncertain():
    with fixture() as f:
        f.episode('good', '2026-10-16T12:00:00Z', [simple('good')])
        folder = f.root / '.egregore/runtime/investigations'
        (folder / 'unreadable.json').write_text('{broken json')
        (folder / 'oversized.json').write_text(' ' * (2 * 1024 * 1024 + 1))
        result = f.score()
        coverage = result['coverage']
        equal(coverage['episodes_read'], 1)
        equal(coverage['episodes_skipped']['unreadable'], 1)
        equal(coverage['episodes_skipped']['oversized'], 1)
        equal(coverage['unattributed'], 2)
        equal(coverage['cap_reached'], False)
        for period in ('now', 'before'):
            equal(result[period]['completeness'], 'uncertain')
            equal(result[period]['skipped_episodes'], 2)
        equal(result['now']['installation']['lookups'], 1)
        equal(result['before']['installation']['lookups'], None)
        text = ok(f.cli('--after', '2026-10-10', '--before', '2026-10-16'))
        assert 'uncertain' in text and 'unattributed' in text, text


def symlink_boundaries():
    with fixture() as f:
        f.episode('good', '2026-10-16T12:00:00Z', [simple('good')])
        f.record('org', TODAY, 'codex', ZERO_RECORDS)
        # Configured memory and worktree roots are real roots after one resolution.
        linked_root = f.temp / 'workspace-link'
        linked_root.symlink_to(f.worktree, target_is_directory=True)
        result = f.score(root=linked_root)
        equal(result['now']['installation']['lookups'], 1)
        equal(result['now']['organization']['sessions'], 1)
        foreign = f.temp / 'do-not-read.json'
        foreign.write_text(json.dumps({'as_of': '2026-10-16T12:00:00Z', 'calls': [simple('bad')] * 100}))
        (f.root / '.egregore/runtime/investigations/linked.json').symlink_to(foreign)
        log = f.root / '.egregore/runtime/mind/log/20261016-120000.jsonl'
        log.parent.mkdir(parents=True)
        foreign_log = f.temp / 'do-not-read.jsonl'
        foreign_log.write_text(json.dumps({'k': 'seen', 'invocation': 'good', 'shown': ['memory/fixture/forbidden.md']}))
        log.symlink_to(foreign_log)
        result = f.score()
        equal(result['now']['installation']['lookups'], 1)
        equal(result['coverage']['episodes_skipped']['symlink'], 1)
        equal(result['coverage']['unattributed'], 1)
        equal(result['now']['installation']['grounding'], None)
        equal(result['now']['installation']['grounding_coverage'], 'unavailable')
        # Symlinked directories below the episode root cannot smuggle in files either.
        subdir = f.temp / 'outside-episodes'
        subdir.mkdir()
        (subdir / 'outside.json').write_text(foreign.read_text())
        (f.root / '.egregore/runtime/investigations/linked-dir').symlink_to(subdir, target_is_directory=True)
        equal(f.score()['now']['installation']['lookups'], 1)
    with fixture() as f:
        f.episode('good', '2026-10-16T12:00:00Z', [simple('good')])
        runtime = f.root / '.egregore/runtime'
        outside = f.temp / 'outside-runtime'
        runtime.rename(outside)
        runtime.symlink_to(outside, target_is_directory=True)
        data = f.score()
        equal(data['coverage']['episodes_read'], 0)
        assert data['coverage']['unattributed'] >= 1, data
        equal(data['now']['installation']['lookups'], None)
        equal(data['now']['completeness'], 'uncertain')


def record_local_date():
    with fixture() as f:
        path = f.record('utc-month-boundary', '2026-09-30', 'codex', ['- find/hybrid: 1 calls, 0 failed'])
        path.write_text(path.read_text().replace('2026-09-30T12:00:00+00:00', '2026-09-30T23:00:00+00:00'))
        try:
            os.environ['TZ'] = 'Pacific/Kiritimati'
            time.tzset()
            data = f.score(today=date(2026, 10, 1), days=1)
            equal(data['now']['organization']['sessions'], 1)
            equal(data['now']['organization']['sessions_without_lookup'], 0)
            equal(data['before']['organization']['sessions'], 0)
            equal(data['coverage']['records_read'], 1)
        finally:
            os.environ['TZ'] = 'UTC'
            time.tzset()


def cap_and_order():
    with fixture() as f:
        f.episode('older-start-newest-mtime', '2026-10-05T12:00:00Z', [simple('old')], mtime=300)
        f.episode('newer-start', '2026-10-15T12:00:00Z', [simple('new')], mtime=200)
        f.episode('newest-start-oldest-mtime', '2026-10-16T12:00:00Z', [simple('newest')], mtime=100)
        all_ = f.score(max_episodes=3)
        equal(all_['coverage']['episodes_read'], 3)
        equal(all_['coverage']['preselected_by_mtime'], False)
        equal(all_['now']['installation']['lookups'], 2)
        equal(all_['before']['installation']['lookups'], 1)
        equal(all_['before']['completeness'], 'complete')
        capped = f.score(max_episodes=2)
        equal(capped['coverage']['episodes_read'], 2)
        equal(capped['coverage']['preselected_by_mtime'], True)
        equal(capped['coverage']['cap_reached'], True)
        equal(capped['now']['installation']['lookups'], 1)
        equal(capped['before']['installation']['lookups'], 1)
        equal(capped['now']['completeness'], 'incomplete')
        equal(capped['before']['completeness'], 'incomplete')
        equal(capped['coverage']['observation_cutoff'], '2026-10-15T12:00:00+00:00')
        assert capped['coverage']['oldest_as_of'].startswith('2026-10-05'), capped
        # Equal modification times across the cutoff still produce a bounded, stable selection.
        for path in (f.root / '.egregore/runtime/investigations').glob('*.json'):
            os.utime(path, (500, 500))
        first = f.score(max_episodes=2)
        equal(first, f.score(max_episodes=2))
        equal(first['coverage']['episodes_read'], 2)
        equal(first['coverage']['preselected_by_mtime'], True)
        # Both periods begin before the sole inspected episode: earlier is unknown, never zero.
        newest = f.root / '.egregore/runtime/investigations/newest-start-oldest-mtime.json'
        os.utime(newest, (600, 600))
        capped = f.score(max_episodes=1)
        for period in ('now', 'before'):
            equal(capped[period]['completeness'], 'incomplete')
        equal(capped['before']['installation']['lookups'], None)
        text = ok(f.cli('--after', '2026-10-10', '--before', '2026-10-16', '--max-episodes', 1))
        assert 'incomplete' in text and ('n/a' in text or 'unknown' in text), text
        bad = newest.with_name('unreadable.json')
        bad.write_text('not JSON')
        os.utime(bad, (700, 700))
        capped = f.score(max_episodes=2)
        for period in ('now', 'before'):
            equal(capped[period]['completeness'], 'uncertain')
            equal(capped[period]['incomplete'], True)
            equal(capped[period]['skipped_episodes'], 1)
        text = ok(f.cli('--after', '2026-10-10', '--before', '2026-10-16', '--max-episodes', 2))
        assert text.count('[uncertain, incomplete]') == 2, text


def date_options_and_json():
    with fixture() as f:
        main_fixture(f)
        explicit = f.score(after='2026-10-10', before='2026-10-16')
        equal(explicit['now'], f.score()['now'])
        equal(f.score(after='2026-10-10')['now'], explicit['now'])
        equal(f.score(before='2026-10-16')['before'], explicit['before'])
        shorter = f.score(after='2026-10-15', before='2026-10-16')
        equal(shorter['days'], 2)
        equal(shorter['before']['boundaries'], {'start': '2026-10-13', 'end': '2026-10-14'})
        raw = ok(f.cli('--after', '2026-10-10', '--before', '2026-10-16', '--json', dispatch=True))
        data = json.loads(raw)
        equal(data['now'], explicit['now'])
        assert raw.strip().startswith('{') and raw.strip().endswith('}'), raw
        assert 'null' in raw and 'memory/fixture/' not in raw and 'invocation_id' not in raw, raw
        text = ok(f.cli('--after', '2026-10-10', '--before', '2026-10-16', dispatch=True))
        lines = text.strip().splitlines()
        equal(len(lines), 4)
        for line in lines[:2]:
            assert 'installation' in line and 'organization' in line, line
            assert 'boundaries' in line and '[complete]' in line, line
        assert 'backend_error' in lines[2] and 'unknown' in lines[2] and 'hybrid' in lines[2], lines[2]
        assert 'coverage' in lines[3].lower(), lines[3]
        assert 'observation_cutoff' in lines[3] and '2026-10-16T12:00:00+00:00' in lines[3], lines[3]
        assert 'oldest_as_of' in lines[3] and '2026-10-02T12:00:00+00:00' in lines[3], lines[3]
        assert 'memory/fixture/' not in text, text
        assert 'records reporting zero calls: 2 of 4 measured, out of 5 records' in lines[0], lines[0]
        assert 'records reporting zero calls: 1 of 2 measured, out of 2 records' in lines[1], lines[1]
        assert 'never looked' not in text and 'sessions_without_lookup' not in text, text
        invalid = f.cli('--days', 0)
        assert invalid.returncode != 0, invalid.stdout
        invalid = f.cli('--after', '2026-10-16', '--before', '2026-10-10')
        assert invalid.returncode != 0, invalid.stdout


def absent_inputs():
    with fixture() as f:
        data = f.score()
        for period in ('now', 'before'):
            n = data[period]['installation']
            equal(n['lookups'], 0)
            equal(n['opens'], 0)
            equal(n['episodes'], 0)
            equal(n['empty_share'], None)
            equal(n['delivered_share'], None)
            equal(n['ok'], 0)
            equal(n['delivered_total'], 0)
            equal(n['empty_total'], 0)
            equal(n['latency_s']['discover']['p50'], None)
            equal(n['grounding'], None)
            equal(n['grounding_coverage'], 'unavailable')
        equal(data['coverage']['episodes_read'], 0)
        equal(data['coverage']['records_read'], 0)
        equal(data['coverage']['observation_cutoff'], None)
        equal(data['coverage']['oldest_as_of'], None)
        equal(ok(f.cli(line=True)), '')


def reflex_line():
    with fixture() as f:
        shift = date.today() - TODAY
        main_fixture(f, shift)
        for harness in ('claude', 'codex', 'pi', 'prime'):
            started = time.monotonic()
            result = f.probe(harness)
            elapsed = (time.monotonic() - started) * 1000
            assert elapsed <= budget.limit(1000), budget.note(elapsed, 1000)
            line = ok(result).strip()
            equal(len(line.splitlines()), 1)
            assert len(line) <= 160, line
            assert '7d' in line and '8 here' in line, line
            assert 'delivered 60% of 5' in line, line
            assert 'org' in line and 'records reporting zero calls: 2 of 4 measured, out of 5 records' in line, line
            assert 'never looked' not in line, line
            assert '/records retrieval' in line, line
        f.config['features']['session_records']['enabled'] = False
        f.save()
        equal(ok(f.probe()), '')
        # Explicit inspection remains useful even if records are off.
        data = json.loads(ok(f.cli('--json')))
        equal(data['now']['installation']['lookups'], 8)
    with fixture() as f:
        stamp = datetime.now(timezone.utc).isoformat()
        f.episode('only-one', stamp, [simple('one')])
        equal(ok(f.probe()), '')
        f.episode('unmeasured', stamp, [discover('two', ok=True)])
        # One measured and one unknown still has a valid measured delivery share.
        line = ok(f.probe()).strip()
        assert 'delivered 100% of 1' in line, line


def reflex_partial_and_null():
    with fixture() as f:
        stamp = datetime.now(timezone.utc).isoformat()
        f.episode('unmeasured', stamp, [discover('one', ok=True), discover('two', ok=True)], mtime=600)
        f.record('org', date.today(), 'codex', ZERO_RECORDS)
        (f.root / '.egregore/runtime/investigations/bad.json').write_text('not JSON')
        line = ok(f.probe()).strip()
        assert '2 here' in line and 'delivered n/a' in line, line
        assert 'org' in line and 'records reporting zero calls: 1 of 1 measured, out of 1 records' in line, line
        assert line.endswith('· partial') and len(line) <= 160, line
        # The same indicator represents bounded, incomplete inspection.
        (f.root / '.egregore/runtime/investigations/bad.json').unlink()
        f.episode('extra', stamp, [simple('extra')], mtime=100)
        line = ok(f.cli('line', '--max-episodes', 1)).strip()
        assert line.endswith('· partial') and len(line) <= 160, line
    with fixture() as f:
        # Mtime selection may skip a newer-started episode even when the oldest
        # selected cohort precedes the current window. Both windows stay partial.
        f.episode('old-start-new-mtime', '2026-10-05T12:00:00Z', [simple('old')], mtime=300)
        f.episode('current-selected', '2026-10-15T12:00:00Z', [simple('one'), simple('two')], mtime=200)
        f.episode('current-omitted', '2026-10-16T12:00:00Z', [simple('omitted')], mtime=100)
        f.record('org', TODAY, 'codex', ZERO_RECORDS)
        line = ok(f.cli('line', '--after', '2026-10-10', '--before', '2026-10-16', '--max-episodes', 2)).strip()
        assert '2 here' in line and 'delivered 100% of 2' in line, line
        assert line.endswith('· partial') and len(line) <= 160, line


def record_races():
    for target in ('leaf', 'month'):
        with fixture() as f:
            record = f.record('allowed', TODAY, 'codex', ZERO_RECORDS)
            outside = f.temp / 'outside-records'
            outside.mkdir()
            (outside / record.name).write_text(record.read_text().replace('"codex"', '"prime"'))
            real_open = os.open
            fired = False
            def raced_open(path, flags, *args, **kwargs):
                nonlocal fired
                name = os.path.basename(os.fspath(path))
                wanted = record.name if target == 'leaf' else record.parent.name
                if not fired and name == wanted:
                    fired = True
                    if target == 'leaf':
                        record.unlink()
                        record.symlink_to(outside / record.name)
                    else:
                        record.parent.rename(record.parent.with_name('saved-month'))
                        record.parent.symlink_to(outside, target_is_directory=True)
                return real_open(path, flags, *args, **kwargs)
            out, err = io.StringIO(), io.StringIO()
            with patch.object(os, 'open', raced_open), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                data = f.score()
            assert fired, f'{target} race injection did not intercept evidence open'
            equal(data['coverage']['records_read'], 0)
            assert data['coverage']['records_skipped'] > 0, data
            equal(data['now']['organization']['coverage'], 'uncertain')
            equal(data['now']['organization']['sessions'], None)
            equal(data['now']['organization']['sessions_by_harness'], {})
            assert 'prime' not in json.dumps(data), data
            equal(out.getvalue() + err.getvalue(), '')


def retained_directory_pins():
    # Replacing an ordinary directory after enumeration must not make a later
    # open consume the replacement, even though it is not itself a symlink.
    for target in ('month', 'sessions'):
        with fixture() as f:
            record = f.record('pinned', TODAY, 'codex', ZERO_RECORDS)
            directory = record.parent if target == 'month' else record.parent.parent
            identity = (directory.stat().st_dev, directory.stat().st_ino)
            foreign = f.temp / ('foreign-' + target)
            destination = foreign if target == 'month' else foreign / record.parent.name
            destination.mkdir(parents=True)
            (destination / record.name).write_text(record.read_text().replace('"codex"', '"prime"'))
            real_listdir = os.listdir
            fired = False
            def replace_after_listing(path='.'):
                nonlocal fired
                names = real_listdir(path)
                info = os.fstat(path) if isinstance(path, int) else os.stat(path)
                if not fired and (info.st_dev, info.st_ino) == identity:
                    fired = True
                    directory.rename(f.temp / ('original-' + target))
                    foreign.rename(directory)
                return names
            out, err = io.StringIO(), io.StringIO()
            with patch.object(os, 'listdir', replace_after_listing), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                data = f.score()
            assert fired, f'{target} replacement after enumeration did not run'
            equal(data['coverage']['records_read'], 1)
            equal(data['coverage']['records_skipped'], 0)
            equal(data['now']['organization']['sessions_by_harness'], {'codex': 1})
            equal(data['now']['organization']['records_total'], 1)
            assert 'prime' not in json.dumps(data), data
            equal(out.getvalue() + err.getvalue(), '')
    for target in ('worktrees', 'worktree'):
        with fixture() as f:
            f.episode('main', '2026-10-16T12:00:00Z', [simple('main')])
            f.episode('pinned', '2026-10-16T12:00:00Z', [simple('first'), simple('second')], root=f.worktree)
            directory = f.worktree.parent if target == 'worktrees' else f.worktree
            identity = (directory.stat().st_dev, directory.stat().st_ino)
            foreign = f.temp / ('foreign-' + target)
            foreign_worktree = foreign / f.worktree.name if target == 'worktrees' else foreign
            f.episode('foreign', '2026-10-16T12:00:00Z', [simple('foreign')] * 20, root=foreign_worktree)
            real_listdir, real_open = os.listdir, os.open
            fired = False
            def swap():
                nonlocal fired
                fired = True
                directory.rename(f.temp / ('original-' + target))
                directory.symlink_to(foreign, target_is_directory=True)
            def replace_worktrees_after_listing(path='.'):
                names = real_listdir(path)
                info = os.fstat(path) if isinstance(path, int) else os.stat(path)
                if target == 'worktrees' and not fired and (info.st_dev, info.st_ino) == identity:
                    swap()
                return names
            def replace_worktree_after_open(path, flags, *args, **kwargs):
                descriptor = real_open(path, flags, *args, **kwargs)
                if target == 'worktree' and not fired:
                    info = os.fstat(descriptor)
                    if (info.st_dev, info.st_ino) == identity:
                        swap()
                return descriptor
            out, err = io.StringIO(), io.StringIO()
            with patch.object(os, 'listdir', replace_worktrees_after_listing), \
                    patch.object(os, 'open', replace_worktree_after_open), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                data = f.score()
            assert fired, f'{target} replacement after validation did not run'
            lookups = data['now']['installation']['lookups']
            assert lookups in (1, 3), data
            if lookups == 1:
                assert data['coverage']['unattributed'] > 0, data
                equal(data['now']['completeness'], 'uncertain')
            equal(out.getvalue() + err.getvalue(), '')


def unreadable_records():
    for target in ('record', 'month'):
        with fixture() as f:
            record = f.record('unreadable', TODAY, 'codex', ZERO_RECORDS)
            month_identity = (record.parent.stat().st_dev, record.parent.stat().st_ino)
            real_open, real_listdir = os.open, os.listdir
            fired = False
            def denied_open(path, flags, *args, **kwargs):
                nonlocal fired
                if target == 'record' and os.path.basename(os.fspath(path)) == record.name:
                    fired = True
                    raise PermissionError(f'fixture denied {record}')
                return real_open(path, flags, *args, **kwargs)
            def denied_listdir(path='.'):
                nonlocal fired
                info = os.fstat(path) if isinstance(path, int) else os.stat(path)
                if target == 'month' and (info.st_dev, info.st_ino) == month_identity:
                    fired = True
                    raise PermissionError(f'fixture denied {record.parent}')
                return real_listdir(path)
            out, err = io.StringIO(), io.StringIO()
            with patch.object(os, 'open', denied_open), patch.object(os, 'listdir', denied_listdir), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                data = f.score()
            assert fired, f'{target} permission injection did not run'
            equal(data['coverage']['records_read'], 0)
            assert data['coverage']['records_skipped'] > 0, data
            for period in ('now', 'before'):
                equal(data[period]['organization']['coverage'], 'uncertain')
                equal(data[period]['organization']['sessions'], None)
                equal(data[period]['organization']['sessions_without_lookup'], None)
            equal(out.getvalue() + err.getvalue(), '')


def bounded_record_reads():
    with fixture() as f:
        path = f.record('long-memory-section', TODAY, 'codex', ['- find/hybrid: 7 calls, 0 failed'])
        text = path.read_text().replace('- find/hybrid: 7 calls, 0 failed',
                                        '- memory/fixture/padding.md\n' * 20000 + '- find/hybrid: 7 calls, 0 failed')
        assert text.index('## Memory and artifacts') < 256 * 1024
        assert text.index('- find/hybrid: 7 calls') > 256 * 1024
        assert len(text.encode()) < 2 * 1024 * 1024
        path.write_text(text)
        data = f.score()
        equal(data['coverage']['records_read'], 1)
        equal(data['coverage']['records_skipped'], 0)
        equal(data['now']['organization']['sessions'], 1)
        equal(data['now']['organization']['sessions_lookup_measured'], 1)
        equal(data['now']['organization']['sessions_without_lookup'], 0)
        # A genuinely oversized record is skipped instead of counted from a prefix.
        path.write_text(text + 'x' * (2 * 1024 * 1024))
        data = f.score()
        equal(data['coverage']['records_read'], 0)
        assert data['coverage']['records_skipped'] > 0, data
        equal(data['now']['organization']['coverage'], 'uncertain')
        equal(data['now']['organization']['sessions'], None)


def canonical_record_sections():
    with fixture() as f:
        def earlier_section(path, lines):
            text = path.read_text()
            text = text.replace('## Asked\nfixture work\n',
                                '## Asked\nQuoted example follows.\n\n## Memory and artifacts\n' +
                                '\n'.join(lines) + '\n\n## Asked\nfixture work\n', 1)
            path.write_text(text)
        actual_calls = f.record('canonical-calls', TODAY, 'codex', ['- find/hybrid: 7 calls, 0 failed'])
        earlier_section(actual_calls, ['- find/hybrid: 0 calls, 0 failed'])
        equal(rs.lookup_in_record(actual_calls.read_text()), 7)
        actual_zero = f.record('canonical-zero', TODAY, 'claude', ZERO_RECORDS)
        earlier_section(actual_zero, ['- find/hybrid: 99 calls, 0 failed'])
        org = f.score()['now']['organization']
        equal((org['records_zero_calls'], org['records_measured'], org['records_total']), (1, 2, 2))
        invalid = {
            'missing': None,
            'empty': [],
            'none-recorded': ['none recorded'],
            'prose': ['- no memory used'],
            'artifacts-only': ['- memory/fixture/artifact.md'],
            'unsupported-op': ['- search/hybrid: 1 calls, 0 failed'],
            'unsupported-kind': ['- find/future: 1 calls, 0 failed'],
            'malformed-count': ['- find/hybrid: many calls, 0 failed'],
            'missing-failed': ['- find/hybrid: 3 calls'],
            'negative-count': ['- find/hybrid: -1 calls, 0 failed'],
            'too-many-failures': ['- find/hybrid: 1 calls, 2 failed'],
            'duplicate': ['- find/hybrid: 1 calls, 0 failed', '- find/hybrid: 1 calls, 0 failed'],
            'mixed': ['- find/hybrid: 1 calls, 0 failed', '- unknown/hybrid: 1 calls, 0 failed'],
            'incomplete-pair': ['- publish-artifact: 0 calls'],
            'malformed-pair': ['- publish-artifact: many calls', '- notify.sh: 0 calls'],
        }
        for number, (name, lines) in enumerate(invalid.items(), 3):
            path = f.record(name, TODAY, 'pi', lines)
            if name == 'malformed-count':
                # Earlier valid evidence cannot rescue a malformed final section.
                earlier_section(path, ['- find/hybrid: 0 calls, 0 failed'])
            org = f.score()['now']['organization']
            equal((org['records_zero_calls'], org['records_measured'], org['records_total']), (1, 2, number))
        # Compatibility aliases retain their values without adding a behavioral claim.
        equal(org['sessions_without_lookup'], org['records_zero_calls'])
        equal(org['sessions_lookup_measured'], org['records_measured'])
        equal(org['sessions'], org['records_total'])


def kind_aliases_and_episode_units():
    with fixture() as f:
        f.episode('legacy-kinds', '2026-10-16T12:00:00Z', [
            discover('k1', 'lex', ok=True), discover('k2', 'keyword', ok=True),
            discover('s1', 'vec', ok=True), discover('s2', 'semantic', ok=True),
            discover('h1', 'lex+vec', ok=True), discover('h2', 'hybrid', ok=True),
        ], opened={'memory/fixture/source.md': {}})
        f.episode('open-before-lookup', '2026-10-15T12:00:00Z', [
            {'operation': 'open'}, discover('later', 'lex', ok=True),
        ], opened={'memory/fixture/already-open.md': {}})
        f.episode('without-open', '2026-10-14T12:00:00Z', [discover('unopened', 'vec', ok=True)])
        data = f.score()
        n = data['now']['installation']
        equal(n['kinds'], {'keyword': 3, 'semantic': 3, 'hybrid': 2})
        equal(n['lookups'], 8)
        equal(n['read_after_lookup'], 2)
        equal(n['lookups_without_read'], 1)
        descriptions = data['field_descriptions']
        assert 'episode' in descriptions['read_after_lookup'].lower(), descriptions
        assert 'episode' in descriptions['lookups_without_read'].lower(), descriptions
        assert 'chronolog' in descriptions['read_after_lookup'].lower(), descriptions


def private_labels():
    with fixture() as f:
        private = '5f958854-7c51-4e27-a4eb-45c6df0487ca'
        f.episode('private-label', '2026-10-16T12:00:00Z', [
            discover('fixture-call', ok=False, error_code=private, phase_ms={private: 25, 'authorization': 5})])
        f.record('private-harness', TODAY, private, ZERO_RECORDS)
        data = f.score()
        n, org = data['now']['installation'], data['now']['organization']
        equal(n['failed_by_cause'], {'unknown': 1})
        equal(n['phase_ms_p50'], {'authorization': 5, 'unknown': 25})
        equal(n['phase_ms_measured'], {'authorization': 1, 'unknown': 1})
        equal(org['sessions_by_harness'], {'unknown': 1})
        equal(org['sessions_without_lookup_by_harness'], {'unknown': 1})
        assert private not in json.dumps(data), data
        for args in ((), ('--json',)):
            output = ok(f.cli('--after', '2026-10-10', '--before', '2026-10-16', *args))
            assert private not in output and str(f.temp) not in output, output


def worktree_symlink_loops():
    with fixture() as f:
        f.episode('good', '2026-10-16T12:00:00Z', [simple('one'), simple('two')])
        loop = f.root / '.claude/worktrees/self-loop'
        loop.symlink_to(loop.name, target_is_directory=True)
        data = f.score()
        equal(data['coverage']['episodes_read'], 1)
        assert data['coverage']['unattributed'] > 0, data
        equal(data['now']['completeness'], 'uncertain')
        equal(data['now']['installation']['lookups'], 2)
        output = ok(f.cli('--after', '2026-10-10', '--before', '2026-10-16'))
        assert str(loop) not in output and str(f.temp) not in output, output
        # Python 3.11 reports a loop as RuntimeError; newer versions use OSError.
        real_resolve = Path.resolve
        fired = False
        def loop_error(path, *args, **kwargs):
            nonlocal fired
            if path == loop:
                fired = True
                raise RuntimeError(f'Symlink loop from {loop}')
            return real_resolve(path, *args, **kwargs)
        out, err = io.StringIO(), io.StringIO()
        with patch.object(Path, 'resolve', loop_error), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            data = f.score()
        assert fired, 'RuntimeError loop injection did not run'
        equal(data['coverage']['episodes_read'], 1)
        assert data['coverage']['unattributed'] > 0, data
        equal(data['now']['completeness'], 'uncertain')
        equal(out.getvalue() + err.getvalue(), '')
    with fixture() as f:
        f.episode('good', '2026-10-16T12:00:00Z', [simple('one')])
        (f.root / '.claude/worktrees/task-alias').symlink_to(f.worktree, target_is_directory=True)
        (f.worktree / '.git').write_text('x' * (2 * 1024 * 1024 + 1))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            data = f.score()
        equal(data['coverage']['episodes_read'], 1)
        equal(data['now']['installation']['lookups'], 1)
        assert data['coverage']['unattributed'] > 0, data
        equal(data['now']['completeness'], 'uncertain')
        equal(out.getvalue() + err.getvalue(), '')
    with fixture() as f:
        f.episode('good', '2026-10-16T12:00:00Z', [simple('one')])
        outside = f.temp / 'foreign-worktree'
        f.episode('foreign', '2026-10-16T12:00:00Z', [simple('foreign')] * 20, root=outside)
        real_open = os.open
        fired = False
        def replaced_worktree(path, flags, *args, **kwargs):
            nonlocal fired
            if os.path.basename(os.fspath(path)) == f.worktree.name and not fired:
                fired = True
                f.worktree.rename(f.temp / 'original-worktree')
                f.worktree.symlink_to(outside, target_is_directory=True)
            return real_open(path, flags, *args, **kwargs)
        out, err = io.StringIO(), io.StringIO()
        with patch.object(os, 'open', replaced_worktree), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            data = f.score()
        assert fired, 'directory-to-symlink worktree race injection did not run'
        equal(data['coverage']['episodes_read'], 1)
        equal(data['now']['installation']['lookups'], 1)
        assert data['coverage']['unattributed'] > 0, data
        equal(data['now']['completeness'], 'uncertain')
        equal(out.getvalue() + err.getvalue(), '')


def snapshot(root):
    return {str(p.relative_to(root)): ('link', os.readlink(p)) if p.is_symlink() else
            ('dir',) if p.is_dir() else (p.stat().st_size, p.stat().st_mtime_ns)
            for p in root.rglob('*') if '__pycache__' not in p.parts}


def no_writes():
    with fixture() as f:
        main_fixture(f, date.today() - TODAY)
        before = snapshot(f.temp)
        ok(f.cli('--json', dispatch=True))
        ok(f.probe())
        equal(snapshot(f.temp), before)


def timing_budget():
    with fixture() as f:
        stamp = datetime.now(timezone.utc).isoformat()
        for index in range(500):
            path = f.episode(f'episode-{index:04}', stamp, [simple(f'i{index}')], fixture_padding='x' * (100 * 1024))
            assert path.stat().st_size >= 100 * 1024
        sizes = (1024, 24 * 1024, 100 * 1024, 300 * 1024)
        for index in range(120):
            calls = (ZERO_RECORDS, ['- find/hybrid: 1 calls, 0 failed'],
                     ['- open/-: 1 calls, 0 failed'], None, ['none recorded'])[index % 5]
            path = f.record(f'bench-{index:03}', date.today(), ('codex', 'claude', 'pi', 'prime')[index % 4], calls)
            path.write_text(path.read_text().replace('## Asked\nfixture work\n',
                            '## Asked\n' + 'x' * sizes[index % len(sizes)] + '\n'))
            assert sizes[index % len(sizes)] <= path.stat().st_size < 2 * 1024 * 1024
        started = time.monotonic()
        data = json.loads(ok(f.cli('--json', dispatch=True)))
        elapsed = (time.monotonic() - started) * 1000
        equal(data['coverage']['episodes_read'], 500)
        equal(data['coverage']['records_read'], 120)
        equal(data['now']['installation']['lookups'], 500)
        org = data['now']['organization']
        equal((org['records_zero_calls'], org['records_measured'], org['records_total']), (48, 72, 120))
        assert elapsed <= budget.limit(2000), budget.note(elapsed, 2000)
        return budget.note(elapsed, 2000)


test('hand count: both cohorts, every episode reading, latency and phase percentiles', hand_counted_periods)
test('organization reach by harness and installation resolution from a linked worktree', organizational_reach)
test('grounding joins nonempty invocation IDs and unions repeated notices per lookup', grounding_union)
test('partial telemetry names measured denominators and leaves absent readings null', partial_telemetry)
test('unreadable and oversized episodes remain unattributed and make both periods uncertain', skipped_uncertain)
test('configured root symlinks work; evidence-entry symlinks are never followed', symlink_boundaries)
test('record local dates retain UTC-named files across a month boundary', record_local_date)
test('cap preselects by mtime, orders cohorts by start, handles ties and never invents zero', cap_and_order)
test('date windows, JSON shape, four text lines, scopes, causes, kinds and CLI dispatch', date_options_and_json)
test('absent evidence has no fabricated measurements and the reflex stays silent', absent_inputs)
test('reflex is one scoped line on every harness and follows both silence rules', reflex_line)
test('reflex flags partial coverage and unmeasured delivery within 160 characters', reflex_partial_and_null)
test('record leaf and month swaps cannot follow a symlink during the read', record_races)
test('retained directory descriptors survive sessions, month and worktree replacements', retained_directory_pins)
test('unreadable records and month listings count coverage gaps instead of zero sessions', unreadable_records)
test('records read beyond 256 KiB through the bounded 2 MiB limit', bounded_record_reads)
test('only the final valid canonical section contributes measured record counters', canonical_record_sections)
test('legacy kinds normalize and opened-path readings count episodes without chronology', kind_aliases_and_episode_units)
test('unrecognized harness, cause and phase labels become unknown without leaking IDs', private_labels)
test('worktree symlink loops remain uncertain without aborting or exposing paths', worktree_symlink_loops)
test('scorecard and reflex write no evidence or other fixture files', no_writes)
test('500 episodes of 100 KiB plus 120 mixed-size records finish within two seconds', timing_budget)
print(f'\n{PASSED} passed, {FAILED} failed', flush=True)
sys.exit(1 if FAILED else 0)
PY
