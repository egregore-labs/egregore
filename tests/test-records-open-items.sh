#!/usr/bin/env bash
# Open items carried in the session records: ids, the append-only ledger, the
# carry and its cutover, the open/close/file commands and the reflex line.
# Every case runs in a disposable project and memory repository; the issue
# flow is a local double, so nothing is filed and no network is reached.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/tmp"
python3 - "$ROOT" <<'PY'
import contextlib
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(sys.argv[1])
PASSED = FAILED = 0
sys.path.insert(0, str(ROOT / 'bin/lib'))
import budget
import session_record as sr

# The issue flow's contract, locally: --draft saves a durable draft and prints
# it; --request-id submits only the unchanged payload of that draft.
FAKE_ISSUE = r'''import json, os, sys, uuid
from pathlib import Path
args = sys.argv[1:]
root = Path(os.environ['EGREGORE_ROOT'])
with open(root.parent / 'issue-calls.jsonl', 'a') as log:
    log.write(json.dumps(args) + '\n')
if os.environ.get('FAKE_ISSUE_FAIL'):
    print('issue: GitHub response unavailable; reconciliation required', file=sys.stderr)
    sys.exit(1)
def value(flag):
    return args[args.index(flag) + 1] if flag in args else None
payload = {'title': value('--title').strip(), 'body': value('--description').strip(),
           'labels': ['kind:' + value('--kind'), 'area:' + value('--area'), 'severity:' + value('--severity')]}
requests = root / '.egregore/runtime/issues/requests'
requests.mkdir(parents=True, exist_ok=True)
if '--draft' in args:
    identifier = str(uuid.uuid4())
    state = {'repo': 'fixture/egregore', 'operation': 'create', 'payload': payload,
             'request_id': identifier, 'status': 'draft'}
    (requests / (identifier + '.json')).write_text(json.dumps(state))
    print(json.dumps(state))
    sys.exit(0)
path = requests / (value('--request-id') + '.json')
state = json.loads(path.read_text())
if state['payload'] != payload:
    print('issue: request ID is bound to a different actor, repository or payload', file=sys.stderr)
    sys.exit(1)
state.update(status='submitted', github_url='https://github.com/fixture/egregore/issues/7')
path.write_text(json.dumps(state))
print(json.dumps(state))
'''

# Records every record file a probe opens, through the interpreter's own audit
# events rather than a wrapper around one particular open function.
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


def ident(text):
    return hashlib.sha256(sr.digest_key(text).encode()).hexdigest()[:6]


class Fixture:
    def __init__(self):
        self.temp = Path(tempfile.mkdtemp(prefix='open-items-', dir=ROOT / 'tmp'))
        self.root = self.temp / 'project'
        self.home = self.temp / 'home'
        self.memory = self.temp / 'memory'
        for path in (self.root / 'bin/lib', self.root / 'bin/reflexes', self.home, self.memory / 'sessions',
                     self.temp / 'audit'):
            path.mkdir(parents=True)
        for name in ('records.sh', 'reflexes.sh'):
            shutil.copy2(ROOT / 'bin' / name, self.root / 'bin' / name)
        for name in ('session_record.py', 'session_trail.py', 'reflexes.py'):
            shutil.copy2(ROOT / 'bin/lib' / name, self.root / 'bin/lib' / name)
        shutil.copy2(ROOT / 'bin/reflexes/10-open-items.sh', self.root / 'bin/reflexes/10-open-items.sh')
        (self.root / 'bin/issue.sh').write_text('#!/usr/bin/env bash\nexec python3 "$(dirname "$0")/fake_issue.py" "$@"\n')
        (self.root / 'bin/fake_issue.py').write_text(FAKE_ISSUE)
        (self.temp / 'audit/sitecustomize.py').write_text(AUDIT)
        (self.root / 'memory').symlink_to(self.memory, target_is_directory=True)
        self.config = {'mode': 'local', 'features': {'session_records': {'enabled': True}}}
        self.state = {'github_username': 'cem', 'display_name': 'Cem', 'actor_id': 'fixture-actor'}
        self.save()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('GIT_', 'EGREGORE_', 'CLAUDE_', 'CODEX_', 'FAKE_', 'OPEN_AUDIT'))}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.temp), EGREGORE_NO_TELEMETRY='1')
        self.env.pop('PYTHONPATH', None)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.memory / 'seed').write_text('fixture\n')
        self.git('add', 'seed')
        self.git('commit', '-qm', 'fixture seed')
        self.today = datetime.now().date()

    def save(self):
        (self.root / 'egregore.json').write_text(json.dumps(self.config))
        (self.root / '.egregore-state.json').write_text(json.dumps(self.state))

    def git(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        result = subprocess.run(['git', '-C', str(self.memory), *args], env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()

    def record(self, name, days_ago, open_lines, author='cem', topic='fixture work'):
        day = self.today - timedelta(days=days_ago)
        started = datetime(day.year, day.month, day.day, 12, 0).astimezone()
        path = self.memory / 'sessions' / day.strftime('%Y-%m') / f'{day:%d}-{author}-{name}.md'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('---\nkind: session-record\n' + f'from: "{author}"\ndate: "{day.isoformat()}"\n'
                        f'topic: "{topic}"\nsession: "{name}"\n---\n\n# Session: {topic}\n\n'
                        f'**Date**: {started.isoformat()}\n**Author**: {author}\n\n## Summary\n\nfixture\n\n'
                        '## Open\n' + ''.join(f'- {line}\n' for line in open_lines) + '\n## Risks\nnone noted\n')
        return path

    def run(self, *args, env=None):
        return subprocess.run(['bash', str(self.root / 'bin/records.sh'), *map(str, args)], env=env or self.env,
                              cwd=self.root, capture_output=True, text=True, timeout=60)

    def probe(self, audit=None):
        env = dict(self.env, EGREGORE_ROOT=str(self.root), EGREGORE_MEMORY=str(self.root / 'memory'))
        if audit:
            env.update(PYTHONPATH=str(self.temp / 'audit'), OPEN_AUDIT_LOG=str(audit))
        result = subprocess.run(['bash', str(self.root / 'bin/reflexes/10-open-items.sh')], env=env,
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()

    def ledger(self):
        path = self.memory / 'sessions/open-items.jsonl'
        return path.read_text().splitlines() if path.exists() else []

    def carried(self, **kwargs):
        return sr.collect_digest(self.memory, days=0, **kwargs)['carried']

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


def shared_identity():
    with fixture() as f:
        f.record('first', 1, ['Rotate the fixture keys — cem'])
        f.record('second', 0, ['rotate the fixture keys!', 'Write the release notes'])
        keys = hashlib.sha256(b'rotate the fixture keys').hexdigest()[:6]
        assert sr.item_id(sr.digest_key('Rotate the fixture keys')) == keys == ident('rotate the fixture keys!')
        result = f.run('digest')
        assert result.returncode == 0, result.stdout + result.stderr
        lines = result.stdout.splitlines()
        assert sum(keys in line for line in lines) == 1, result.stdout
        assert any(line.startswith(f'  - {keys} Rotate the fixture keys — cem · fixture work · sessions/')
                   for line in lines), result.stdout
        assert any(line.startswith(f'  - {ident("Write the release notes")} Write the release notes — cem by default ·')
                   for line in lines), result.stdout
        listed = f.run('open').stdout
        rows = [line for line in listed.splitlines() if line.startswith(keys)]
        # One row: the newest wording, the newest named owner, the age of the first record.
        assert len(rows) == 1 and rows[0].startswith(f'{keys}   1d  {"cem".ljust(13)}  rotate the fixture keys! · sessions/'), listed
test('two records raising the same item share one id, printed beside each open item', shared_identity)


def carried_across_days():
    with fixture() as f:
        f.record('two-days', 2, ['Check the fixture backups — unstated owner'])
        backups = ident('Check the fixture backups')
        assert [(row['id'], row['age'], row['ownerless'], row['owner']) for row in f.carried()] == \
            [(backups, 2, True, 'cem')]
        tomorrow = f.carried(today=f.today + timedelta(days=1))
        assert [(row['id'], row['age']) for row in tomorrow] == [(backups, 3)], tomorrow
        result = f.run('digest')
        assert result.stdout.startswith(f'Nothing recorded since {f.today - timedelta(days=1)}.\nCarried\n'), result.stdout
        assert f'  - {backups} 2d Check the fixture backups — cem by default · fixture work · sessions/' in result.stdout
        assert f'{backups}   2d  cem (default)  Check the fixture backups · sessions/' in f.run('open').stdout
        # A window that already shows the item does not repeat it as carried.
        wide = f.run('digest', '--days', '3').stdout
        assert '\nCarried\n' not in wide and wide.count(backups) == 1, wide
test('an item is carried across two days with its age and owner', carried_across_days)


def closed_by_event():
    with fixture() as f:
        f.record('stale', 5, ['Retire the fixture bucket — unstated owner'])
        f.record('fresh', 0, ['Draft the fixture summary — cem'])
        bucket = ident('Retire the fixture bucket')
        assert bucket in f.run('open').stdout and 'Retire the fixture bucket' in f.probe()
        result = f.run('close', bucket)
        assert result.returncode == 0, result.stdout + result.stderr
        assert result.stdout.startswith(f'Closed {bucket} · Retire the fixture bucket · sessions/'), result.stdout
        lines = f.ledger()
        event = json.loads(lines[0])
        assert len(lines) == 1 and set(event) == {'id', 'state', 'by', 'at'}, lines
        assert (event['id'], event['state'], event['by']) == (bucket, 'closed', 'fixture-actor')
        assert abs(datetime.fromisoformat(event['at']) - datetime.now(timezone.utc)) < timedelta(minutes=5)
        assert 'Retire' not in (f.memory / 'sessions/open-items.jsonl').read_text()
        assert f.git('log', '-1', '--format=%s') == f'chore(sessions): close open item {bucket}'
        assert set(f.git('show', '--name-only', '--format=', 'HEAD').split()) == \
            {'sessions/open-items.jsonl', 'sessions/.gitattributes'}
        assert 'open-items.jsonl merge=union' in (f.memory / 'sessions/.gitattributes').read_text().splitlines()
        assert f.git('status', '--porcelain', '--', 'sessions/open-items.jsonl', 'sessions/.gitattributes') == ''
        assert bucket not in f.run('open').stdout
        line = f.probe()
        assert 'Retire the fixture bucket' not in line and line.startswith('1 open item carried (oldest 0d: '), line
        assert bucket not in f.run('digest', '--days', '7').stdout
        # Append-only: a second close is a second line, and the first stays as written.
        first = (f.memory / 'sessions/open-items.jsonl').read_bytes()
        result = f.run('close', bucket)
        assert result.returncode == 0 and '(already closed)' in result.stdout, result.stdout
        after = (f.memory / 'sessions/open-items.jsonl').read_bytes()
        assert after.startswith(first) and len(after.splitlines()) == 2
        assert f.git('rev-list', '--count', 'HEAD') == '3'
        for bad in ('abcdef', 'XYZ123', '12345', ''):
            result = f.run('close', bad)
            assert result.returncode != 0, (bad, result.stdout)
        assert (f.memory / 'sessions/open-items.jsonl').read_bytes() == after
        f.state.pop('actor_id')
        f.save()
        result = f.run('close', ident('Draft the fixture summary'))
        assert result.returncode == 1 and 'nothing was written' in result.stdout, result.stdout
        assert (f.memory / 'sessions/open-items.jsonl').read_bytes() == after
test('closed by event: gone from open, the digest and the probe; a second close is a second line', closed_by_event)


def last_event_wins():
    with fixture() as f:
        f.record('events', 2, ['Event one', 'Event two', 'Event three', 'Event four'])
        one, two, three, four = (ident('Event ' + word) for word in ('one', 'two', 'three', 'four'))
        stamp = lambda minutes: (datetime.now(timezone.utc) - timedelta(minutes=minutes)).isoformat()
        rows = [{'id': two, 'state': 'filed', 'by': 'oz', 'at': stamp(1), 'issue': 'https://github.com/fixture/egregore/issues/9'},
                {'id': two, 'state': 'closed', 'by': 'cem', 'at': stamp(30)},
                {'id': three, 'state': 'expired', 'by': 'cem', 'at': stamp(5)},
                {'id': four, 'state': 'reopened', 'by': 'cem', 'at': stamp(2)}]
        (f.memory / 'sessions/open-items.jsonl').write_text(
            '\n'.join(json.dumps(row) for row in rows) + '\nnot json\n{"id": "zz", "state": "closed"}\n')
        events = sr.ledger_events(f.memory)
        # Lines merged from two histories may be out of order; the event time decides.
        assert events[two]['state'] == 'filed' and events[three]['state'] == 'expired', events
        assert four not in events and set(events) == {two, three}
        assert [row['id'] for row in f.carried()] == [four, one], f.carried()
        target = f.temp / 'elsewhere.jsonl'
        target.write_text(json.dumps({'id': one, 'state': 'closed', 'by': 'oz', 'at': stamp(1)}) + '\n')
        (f.memory / 'sessions/open-items.jsonl').unlink()
        (f.memory / 'sessions/open-items.jsonl').symlink_to(target)
        assert sr.ledger_events(f.memory) == {}
        result = f.run('close', one)
        assert result.returncode == 1 and 'nothing was written' in result.stdout, result.stdout
        assert target.read_text().count('\n') == 1
test('the last event for an id wins by time; malformed lines and a linked ledger are ignored', last_event_wins)


def old_closure_is_durable():
    with fixture() as f:
        f.record('long-ago', 40, ['Closed fixture remains closed'])
        item=ident('Closed fixture remains closed')
        assert f.run('close', item).returncode == 0
        with (f.memory/'sessions/open-items.jsonl').open('ab') as stream:
            stream.write(b'x'*(17*1024*1024)+b'\n')
        data=sr.collect_digest(f.memory,days=0)
        assert item not in {row['id'] for row in data['carried']+data['stale']}
        assert sr.ledger_events(f.memory)[item]['state']=='closed'
test('historical closures survive large ledgers and oversized malformed lines',old_closure_is_durable)


def closed_then_raised_again():
    with fixture() as f:
        f.record('before', 3, ['Restart the fixture worker'])
        worker = ident('Restart the fixture worker')
        assert f.run('close', worker).returncode == 0
        prior = (f.memory / 'sessions/open-items.jsonl').read_bytes()
        f.record('mention', 0, ['Restart the fixture worker'])
        assert not f.carried() and worker not in f.run('digest').stdout
        rejected = f.run('stale', worker)
        assert rejected.returncode == 1 and 'only explicit reactivation' in rejected.stdout
        assert (f.memory / 'sessions/open-items.jsonl').read_bytes() == prior
        assert f.run('reactivate', worker).returncode == 0
        assert (f.memory / 'sessions/open-items.jsonl').read_bytes().startswith(prior)
        row = f.carried()[0]
        assert (row['id'], row['age'], row['relevance_age']) == (worker, 3, 0), row
        assert json.loads(f.ledger()[-1])['state'] == 'active'
test('a later mention cannot reopen closed work; explicit reactivation preserves history and original age',
     closed_then_raised_again)


def closed_after_the_newest_raise():
    with fixture() as f:
        f.record('first', 3, ['Rotate the fixture certificate — unstated'])
        f.record('newest', 1, ['Rotate the fixture certificate'])
        certificate = ident('Rotate the fixture certificate')
        assert certificate in f.run('open').stdout
        assert f.run('close', certificate).returncode == 0
        for view in (f.run('open').stdout, f.run('digest', '--days', '7').stdout, f.probe()):
            assert certificate not in view and 'Rotate the fixture certificate' not in view, view
        # A close stamped at the very time of the newest raise is not older than it: still closed.
        same = f.record('same-moment', 2, ['Renew the fixture lease'])
        lease = ident('Renew the fixture lease')
        started = sr.metadata(same.read_text())['started_at']
        with (f.memory / 'sessions/open-items.jsonl').open('a') as stream:
            stream.write(json.dumps({'id': lease, 'state': 'closed', 'by': 'cem',
                                     'at': datetime.fromisoformat(started).astimezone(timezone.utc).isoformat()}) + '\n')
        assert lease not in {row['id'] for row in f.carried()}
test('closed after the newest raise stays closed, in open, the digest and the probe', closed_after_the_newest_raise)


def ownerless_four_days():
    with fixture() as f:
        f.record('four', 4, ['Choose the fixture retention — owner unstated', 'Pick the fixture name — cem'])
        f.record('owned', 1, ['Write the fixture guide — cem'])
        retention = ident('Choose the fixture retention')
        lines = f.probe().splitlines()
        assert lines[0] == '3 open items carried (oldest 4d: "Choose the fixture retention") · 3 yours · /records open --mine', lines
        assert lines[1] == (f'yours, oldest: {retention} 4d "Choose the fixture retention" · {ident("Pick the fixture name")} 4d '
                            f'"Pick the fixture name" · {ident("Write the fixture guide")} 1d "Write the fixture guide"'), lines
        listed = f.run('open').stdout.splitlines()
        assert listed[0] == '3 active open items, oldest first', listed
        # Oldest first; within an age, the ownerless item first, held by its author by default.
        assert listed[1].startswith(f'{retention}   4d  cem (default)  Choose the fixture retention · sessions/'), listed
        assert listed[2].startswith(ident('Pick the fixture name') + f'   4d  {"cem".ljust(13)}  Pick the fixture name'), listed
        assert listed[3].startswith(ident('Write the fixture guide') + '   1d  cem'), listed
        f.record('three', 3, ['Only three days old — unstated'])
        assert '2 ownerless' not in f.probe()
test('an ownerless item at four days is shown with its age, and nothing is proposed', ownerless_four_days)


def owner_defaults_to_author():
    with fixture() as f:
        # A thread nobody named belongs to the author of the session that left
        # it; a named owner stands; a record without an author leaves it
        # unowned. The card counts yours and names your oldest three, and
        # open --mine lists them.
        f.record('mine-old', 6, ['Settle the fixture charter — unstated'])
        f.record('theirs', 5, ['Review the fixture charter'], author='oz')
        f.record('named', 4, ['Approve the fixture charter — oz'])
        nobody = f.record('nobody', 3, ['Archive the fixture charter'])
        nobody.write_text(re.sub(r'^(from|\*\*Author\*\*): .*\n', '', nobody.read_text(), flags=re.M))
        f.record('mine-new', 2, ['Publish the fixture charter'])
        rows = {row['line']: (row['owner'], row['ownerless']) for row in f.carried()}
        assert rows == {'Settle the fixture charter': ('cem', True), 'Review the fixture charter': ('oz', True),
                        'Approve the fixture charter': ('oz', False), 'Archive the fixture charter': ('unowned', True),
                        'Publish the fixture charter': ('cem', True)}, rows
        settle, publish = ident('Settle the fixture charter'), ident('Publish the fixture charter')
        lines = f.probe().splitlines()
        assert lines[0] == '5 open items carried (oldest 6d: "Settle the fixture charter") · 2 yours · /records open --mine', lines
        assert lines[1] == f'yours, oldest: {settle} 6d "Settle the fixture charter" · {publish} 2d "Publish the fixture charter"', lines
        listed = f.run('open', '--mine').stdout.splitlines()
        assert listed[0] == '2 active open items of yours, oldest first', listed
        assert [line.split()[0] for line in listed[1:3]] == [settle, publish], listed
        digest = f.run('digest', '--days', '7').stdout
        for expected in ('Review the fixture charter — oz by default ·', 'Approve the fixture charter — oz ·',
                         'Archive the fixture charter — unowned ·', 'Settle the fixture charter — cem by default ·'):
            assert expected in digest, (expected, digest)
        data = json.loads(f.run('open', '--mine', '--json').stdout)
        assert data['active_count'] == 5 and [row['owner'] for row in data['items']] == ['cem', 'cem'], data
        # Another person sees their own: oz holds one by default and one by name.
        f.state['github_username'] = 'oz'; f.state['display_name'] = 'Oz'; f.save()
        assert f.probe().splitlines()[0].endswith('· 2 yours · /records open --mine'), f.probe()
        assert [line.split()[0] for line in f.run('open', '--mine').stdout.splitlines()[1:3]] == \
            [ident('Review the fixture charter'), ident('Approve the fixture charter')]
test('a thread nobody named belongs to the author who left it, counts as yours on the card and lists under open --mine',
     owner_defaults_to_author)


def eight_days_proposes():
    with fixture() as f:
        # Raised once, by one record eight days ago: nobody re-raised it.
        f.record('raised-once', 8, ['Decide the fixture archive policy — unstated'])
        archive = ident('Decide the fixture archive policy')
        lines = f.probe().splitlines()
        assert lines[0] == '1 open item carried (oldest 8d: "Decide the fixture archive policy") · 1 yours · /records open --mine', lines
        assert lines[1] == f'yours, oldest: {archive} 8d "Decide the fixture archive policy"', lines
        result = subprocess.run([sys.executable, str(f.root / 'bin/lib/reflexes.py'), '--root', str(f.root)],
                                env=f.env, capture_output=True, text=True, timeout=10)
        assert result.stdout == '  ◦ ' + lines[0] + '\n  ◦ ' + lines[1] + '\n', result.stdout + result.stderr
        long = 'Settle' + ' the long fixture question' * 8
        f.record('long-first', 9, [long + ' — unowned'])
        f.record('long-again', 2, [long])
        f.record('fillers', 5, [f'Filler {index} — unstated' for index in range(120)])
        lines = f.probe().splitlines()
        assert len(lines) == 2 and all(len(line) <= 160 for line in lines) and '/records file' not in lines[0], lines
        assert lines[0].startswith('122 open items carried (oldest 9d: "Settle the long fixture question'), lines
        assert lines[0].endswith('· 122 yours · /records open --mine') and 'ownerless' not in lines[0], lines
        assert lines[1].startswith('yours, oldest: ') and lines[1].count(' · ') == 2, lines
test('age alone does not propose filing or require a human owner', eight_days_proposes)


def cutover():
    with fixture() as f:
        f.record('old', 40, ['Old conceptual shell'])
        f.record('mention', 1, ['Old conceptual shell'])
        f.record('edge', 14, ['Fresh edge'])
        old, edge = ident('Old conceptual shell'), ident('Fresh edge')
        data = sr.collect_digest(f.memory, days=0)
        assert [row['id'] for row in data['carried']] == [edge]
        assert [(row['id'], row['age'], row['relevance']) for row in data['stale']] == [(old,40,'stale')]
        assert 'Old conceptual shell' not in f.run('open').stdout
        assert old in f.run('open','--stale').stdout
        assert f.run('open','--json').returncode == 0
        assert len(json.loads(f.run('open','--all','--json').stdout)['items']) == 2
        assert not f.ledger(), 'reading relevance must not write history'
        later = sr.collect_digest(f.memory,days=0,today=f.today+timedelta(days=1))
        assert not later['carried'] and len(later['stale']) == 2
        assert f.run('reactivate',old).returncode == 0
        renewed = next(row for row in f.carried() if row['id']==old)
        assert renewed['age']==40 and renewed['relevance_age']==0
        assert f.run('stale',old).returncode == 0
        assert old not in {row['id'] for row in f.carried()}
        f.record('another-mention',0,['Old conceptual shell'])
        assert old not in {row['id'] for row in f.carried()}
        assert [json.loads(line)['state'] for line in f.ledger()]==['active','stale']
test('stale work stays open and findable without automatic reactivation or age reset',cutover)


def file_needs_confirm():
    with fixture() as f:
        f.record('issue', 9, ['Document the fixture rollback — unstated owner'])
        f.record('issue-again', 3, ['Document the fixture rollback'])
        f.record('other', 1, ['Name the fixture owner'])
        rollback, other = ident('Document the fixture rollback'), ident('Name the fixture owner')
        result = f.run('file', rollback)
        assert result.returncode == 0, result.stdout + result.stderr
        request = re.search(r'^  request: (\S+)$', result.stdout, re.M)[1]
        assert result.stdout.startswith(f'Issue draft for open item {rollback} · nothing is filed yet\n'), result.stdout
        assert f'bash bin/records.sh file {rollback} --confirm {request}' in result.stdout
        description = '\n'.join(['Document the fixture rollback', '', f'Open item {rollback} from the session records.',
                                 'Record: memory/' + str(next((f.memory / 'sessions').glob('*/*-cem-issue-again.md'))
                                                         .relative_to(f.memory)),
                                 'Owner: cem (by default)', f'Open for 9 days, since {f.today - timedelta(days=9)}.'])
        calls = [json.loads(line) for line in (f.temp / 'issue-calls.jsonl').read_text().splitlines()]
        assert calls == [['create', '--title', 'Document the fixture rollback', '--description', description,
                          '--kind', 'improvement', '--area', 'other', '--severity', 'normal', '--draft']], calls
        assert f.ledger() == [] and f.git('rev-list', '--count', 'HEAD') == '1'
        assert rollback in f.run('open').stdout
        other_request = re.search(r'^  request: (\S+)$', f.run('file', other).stdout, re.M)[1]
        for bad in (str(uuid.uuid4()), 'not-a-request', '../../../etc/passwd', other_request):
            result = f.run('file', rollback, '--confirm', bad)
            assert result.returncode == 1 and 'nothing' in result.stdout, (bad, result.stdout)
        failing = dict(f.env, FAKE_ISSUE_FAIL='1')
        result = f.run('file', rollback, '--confirm', request, env=failing)
        assert result.returncode == 1 and 'GitHub response unavailable' in result.stdout, result.stdout
        assert f.ledger() == [] and f.git('rev-list', '--count', 'HEAD') == '1'
        result = f.run('file', rollback, '--confirm', request)
        assert result.returncode == 0, result.stdout + result.stderr
        assert result.stdout == f'Filed {rollback} as https://github.com/fixture/egregore/issues/7\n', result.stdout
        event = json.loads(f.ledger()[-1])
        assert event == {'id': rollback, 'state': 'filed', 'by': 'fixture-actor', 'at': event['at'],
                         'issue': 'https://github.com/fixture/egregore/issues/7'}, event
        assert len(f.ledger()) == 1 and rollback not in f.run('open').stdout
        assert f.git('log', '-1', '--format=%s') == f'chore(sessions): file open item {rollback} as an issue'
        result = f.run('file', rollback)
        assert result.stdout == f'{rollback} is already filed: https://github.com/fixture/egregore/issues/7\n'
        assert len(f.ledger()) == 1
test('file prepares a draft and appends nothing until --confirm names its request and the filing succeeds',
     file_needs_confirm)


def filed_then_recorded():
    with fixture() as f:
        f.record('reconcile', 2, ['Reconcile the fixture filing — unstated'])
        item = ident('Reconcile the fixture filing')
        request = re.search(r'^  request: (\S+)$', f.run('file', item).stdout, re.M)[1]
        ledger = f.memory / 'sessions/open-items.jsonl'
        ledger.mkdir()
        result = f.run('file', item, '--confirm', request)
        assert result.returncode == 1 and result.stdout.startswith(
            f'Filed {item} as https://github.com/fixture/egregore/issues/7, but its ledger event was not recorded'), result.stdout
        ledger.rmdir()
        # The same request reconciles to the one issue, then records the event.
        result = f.run('file', item, '--confirm', request)
        assert result.stdout == f'Filed {item} as https://github.com/fixture/egregore/issues/7\n', result.stdout
        assert [json.loads(line)['state'] for line in f.ledger()] == ['filed']
test('a filing whose event could not be written is recorded by running the same confirm again', filed_then_recorded)


def digest_carried_cap():
    with fixture() as f:
        f.record('many', 3, [f'Carried item {index:02d} — unstated' for index in range(11)])
        result = f.run('digest')
        lines = result.stdout.splitlines()
        carried = [line for line in lines if line.startswith('  - ')]
        assert lines[:2] == [f'Nothing recorded since {f.today - timedelta(days=1)}.', 'Carried'], lines
        assert len(carried) == 8 and lines[-1] == '  … 3 more · /records open', lines
        assert all(re.match(r'  - [0-9a-f]{6} 3d Carried item \d\d — cem by default · fixture work · sessions/', line)
                   for line in carried), carried
        future = (f.today + timedelta(days=2)).isoformat()
        assert f.run('digest', '--since', future).stdout == f'Nothing recorded since {future}.\n'
test('the digest lists carried items with id and age, capped with a pointer to open', digest_carried_cap)


def probe_bounds():
    with fixture() as f:
        assert f.probe() == '' and f.run('open').stdout == 'No active open items.\n'
        for index in range(150):
            f.record(f'bulk-{index:03d}', index * 60 // 150,
                     [f'Bulk item {index} — unstated owner', f'Owned bulk item {index} — cem'])
        f.config['features']['session_records']['enabled'] = False
        f.save()
        assert f.probe() == ''
        f.config['features']['session_records']['enabled'] = True
        f.save()
        audit = f.temp / 'opened.log'
        started = time.monotonic()
        line = f.probe(audit=audit)
        elapsed = time.monotonic() - started
        assert ' open items carried (oldest ' in line, line
        assert elapsed < budget.limit(1.0), budget.note(elapsed, 1.0, 's')
        opened = audit.read_text().splitlines()
        days = sorted({(f.today - datetime.strptime(Path(path).parent.name + '-' + Path(path).name[:2], '%Y-%m-%d').date()).days
                       for path in opened})
        assert opened and days[0] >= -1 and days[-1] > sr.STALE_DAYS, days
        assert len(opened) == len(set(opened)) == 150, len(opened)
        print(f'  probe on 150 records: {elapsed * 1000:.0f} ms, {len(opened)} record files read', flush=True)
test('the probe is silent with nothing carried or records off, and projects full history once within a second without reviving stale items',
     probe_bounds)

print(f'{PASSED} passed, {FAILED} failed')
sys.exit(1 if FAILED else 0)
PY
