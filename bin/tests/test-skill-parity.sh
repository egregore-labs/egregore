#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  ''|--sweep-only) ;;
  *) echo 'Usage: bash bin/tests/test-skill-parity.sh [--sweep-only]' >&2; exit 2 ;;
esac
ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd -P)"
BOOTSTRAP=()
bootstrap_text="$(source "$ROOT/evals/skill-parity/fixture.sh" bootstrap-env)"
while IFS= read -r entry; do BOOTSTRAP+=("$entry"); done <<< "$bootstrap_text"
boot() { env -i "${BOOTSTRAP[@]}" "$@"; }
TEST_ROOT="$(boot mktemp -d "${TMPDIR:-/tmp}/skill-parity-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
suite_pid=''
cleanup() {
  local status=$? marker retained=0
  trap - EXIT INT TERM
  if [ "$status" -ne 0 ]; then
    if [ -n "$suite_pid" ]; then kill -TERM -- "-$suite_pid" 2>/dev/null || true; fi
    while IFS= read -r marker; do
      if ! boot bash "$ROOT/evals/skill-parity/fixture.sh" sweep "${marker%/*}"; then retained=1; fi
    done < <(boot find "$TEST_ROOT" -name .built -type f -print)
  fi
  if [ "$retained" -eq 0 ]; then
    boot rm -rf -- "$TEST_ROOT"
  else
    printf 'skill-parity test: retained fixtures after failed sweep: %s\n' "$TEST_ROOT" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
boot python3 - "$ROOT" "$TEST_ROOT" <<'PYSWEEP'
import ast
from pathlib import Path
import signal
import sys
from types import SimpleNamespace

# Exercise the real sweep without constructing source archives or signalling
# host processes. Only process observations and elapsed time are simulated.
source, tmp = map(Path, sys.argv[1:3])
script = (source / 'evals/skill-parity/fixture.sh').read_text()
embedded = script.split('  sweep)\n', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
tree = ast.parse(embedded)
definitions = ast.Module(body=[node for node in tree.body if isinstance(
    node, (ast.Import, ast.ImportFrom, ast.ClassDef, ast.FunctionDef))], type_ignores=[])
code = compile(definitions, 'fixture.sh:sweep', 'exec')

def check(mode, elapsed, error=None):
    scope = {'root': tmp / 'sweep'}
    exec(code, scope)
    state = {'ticks': 0, 'term': False, 'killed': None, 'signals': []}

    def sleep(seconds):
        state['ticks'] += round(seconds * 10)

    def kill(pid, sig):
        assert pid == 200, f'sweep signalled an unrelated process: {pid}'
        if sig:
            state['signals'].append(sig)
            if sig == signal.SIGTERM:
                state['term'] = True
            elif sig == signal.SIGKILL:
                state['killed'] = state['ticks']
            return
        if mode == 'term-exit' and state['term']:
            raise ProcessLookupError
        if state['killed'] is not None:
            if mode == 'kill-exit' or (mode == 'delayed-exit' and state['ticks'] - state['killed'] >= 3):
                raise ProcessLookupError
            if mode == 'inspection-denied':
                raise PermissionError('injected inspection denial')

    def output(*args):
        if args[:2] == ('pgrep', '-f'):
            return '' if mode == 'empty' else '200\n'
        if args[0] == 'lsof' or args[:2] == ('pgrep', '-P') or args[-1] == 'ppid=':
            return ''
        assert args == ('ps', '-p', '200', '-o', 'stat='), args
        if state['killed'] is not None:
            if mode == 'ps-error':
                raise scope['SweepError']('injected ps failure')
            if mode == 'zombie':
                return 'Z\n'
        return 'S\n'

    scope.update(
        os=SimpleNamespace(getpid=lambda: 100, getppid=lambda: 99, getpgid=lambda pid: pid, kill=kill),
        time=SimpleNamespace(monotonic=lambda: state['ticks'] / 10, sleep=sleep),
        output=output,
    )
    try:
        scope['sweep']()
    except scope['SweepError'] as failure:
        assert error is not None and error in str(failure), (mode, failure)
    else:
        assert error is None, f'{mode}: failed to reject a surviving or uninspectable process'
    assert state['ticks'] == elapsed * 10, (mode, state)
    assert state['signals'] == ([] if mode == 'empty' else [signal.SIGTERM, signal.SIGKILL]), (mode, state)
    print(f'PASS sweep: {mode}', flush=True)

check('empty', 0)
check('term-exit', 0)
check('kill-exit', 10)
check('delayed-exit', 10.3)
check('zombie', 10)
check('survivor', 12, 'processes survived: 200')
check('inspection-denied', 10, 'cannot inspect process 200')
check('ps-error', 10, 'injected ps failure')
PYSWEEP
[ "${1:-}" != --sweep-only ] || exit 0
env -i "${BOOTSTRAP[@]}" perl -e 'setpgrp(0,0); exec @ARGV' -- python3 - "$ROOT" "$TEST_ROOT" "${EGREGORE_LIVE_INTEGRATION:-0}" <<'PYTEST' &
import json
import ast
import importlib.util
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback
from unittest.mock import patch

source, tmp = map(Path, sys.argv[1:3])
started = time.monotonic()
rig = tmp / 'rig'
shutil.copytree(source / 'evals/skill-parity', rig, ignore=shutil.ignore_patterns('runs', '__pycache__'))
shutil.copyfile(rig / 'harness/mock.sh', rig / 'harness/mock2.sh')
# Register the test-only alias in copied specs; maintained specs name only
# installed harnesses, so runner preflight also works outside this suite.
for path in (rig / 'specs').glob('*.json'):
    spec = json.loads(path.read_text())
    for item in [spec, *spec.get('cases', [])]:
        if 'mock' in item.get('harnesses', []):
            item['harnesses'].append('mock2')
    path.write_text(json.dumps(spec, indent=2) + '\n')
parent = dict(os.environ, TMPDIR=str(tmp), SKILL_PARITY_SOURCE=str(source))
live = sys.argv[3] == '1'
if not live:
    print('SKIP: test 8 real startup requires EGREGORE_LIVE_INTEGRATION=1; deterministic cases still run', flush=True)

def call(args, *, env=None, cwd=None, code=0, timeout=120):
    __tracebackhide__ = True
    selected = parent if env is None else env
    command = ['env', '-i', *(f'{k}={v}' for k, v in selected.items()), *map(str, args)]
    result = subprocess.run(command, env=dict(os.environ), cwd=cwd,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode != code:
        raise AssertionError(f'command exited {result.returncode}; expected {code}; captured output withheld') from None
    return result.stdout

def write(path, obj):
    # Event streams and CLI session records are JSON Lines: one record per line.
    if str(path).endswith('.jsonl'):
        path.write_text(json.dumps(obj) + '\n')
    else:
        path.write_text(json.dumps(obj, indent=2) + '\n')

def read(path):
    return json.loads(path.read_text())

def fixture_env(root):
    lines = call(['bash', rig / 'fixture.sh', 'env', root]).splitlines()
    return dict(line.split('=', 1) for line in lines)

def child(root, args, **kwargs):
    env = fixture_env(root)
    # Explicit env -i is also the harness contract exercised by the test.
    return call(['env', '-i', *(f'{k}={v}' for k, v in env.items()), *args], cwd=root / 'fixture', **kwargs)

def report(out, code=0):
    call(['python3', rig / 'report.py', out], code=code)
    return read(out / 'summary.json')

def copy_cell(out, name='note-mock'):
    out.mkdir()
    target = out / name
    shutil.copytree(baseline / name, target)
    return target

def regenerate(cell):
    root = Path(read(cell / 'cell.json')['root'])
    child(root, ['bash', rig / 'receipts.sh', root, cell])

def append_event(cell, command):
    with (cell / 'events.jsonl').open('a') as f:
        f.write(json.dumps(dict(turn=1, kind='tool', tool='Bash', command=command, path=None,
                                cwd=read(cell / 'cell.json')['root'] + '/fixture', text='')) + '\n')
    regenerate(cell)

probe_environment = call(['bash', rig / 'fixture.sh', 'bootstrap-env'],
                         env=dict(parent, GIT_DIR='/invalid-parent-git', PYTHONPATH='/invalid-parent-python',
                                  EGREGORE_ROOT='/invalid-parent-root', CLAUDECODE='parent-session'))
assert all(not line.startswith(('GIT_DIR=', 'PYTHONPATH=', 'EGREGORE_ROOT=', 'CLAUDECODE='))
           for line in probe_environment.splitlines()), 'bootstrap leaked parent controls'

# Exercise new case expansion and credential behavior before the host process
# inspection prerequisite. These children are synchronous and explicitly reaped;
# this is focused rig coverage, not a substitute for a full cell sweep.
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

scoring = module('parity_report', rig / 'report.py')
env_driver = module('parity_env_mock', rig / 'harness/env_mock.py')
runner = (rig / 'run.sh').read_text()
expander = runner.split('boot python3 - "$cell/cell.json"', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
selector = runner.split('cases="$(boot python3 - ', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
env_spec = read(rig / 'specs/env.json')
assert {case['id'] for case in env_spec['cases']} == {'install', 'handoff', 'dialog-failure', 'sandbox'}
assert 'skills="note,reflect,branch,env"' in runner, 'env is not in the default spec registry'
for choice, expected in (('', ['install', 'handoff', 'dialog-failure', 'sandbox']), ('handoff', ['handoff']), ('unknown', [])):
    output = io.StringIO()
    with patch.object(sys, 'argv', ['select', str(rig / 'specs/env.json'), choice]), contextlib.redirect_stdout(output):
        exec(compile(selector, 'run.sh:case-selection', 'exec'), {})
    assert output.getvalue().split() == expected, choice
# Reject unknown harnesses before output/cell construction, even in a later
# spec or a case excluded by --case. None should become insufficient coverage.
for label, skills, requested, field in (
    ('requested', 'env', 'codxe', None),
    ('top-level', 'env', 'mock', 'spec'),
    ('filtered-case', 'env', 'mock', 'case'),
    ('later-spec', 'note,env', 'mock', 'spec'),
):
    bad = json.loads(json.dumps(env_spec))
    if field == 'spec':
        bad['harnesses'] = ['codxe']
    elif field == 'case':
        bad['cases'][0]['harnesses'] = ['codxe']
    write(rig / 'specs/env.json', bad)
    rejected_out = tmp / ('unknown-harness-' + label)
    diagnostic = call(['bash', rig / 'run.sh', '--skill', skills, '--case', 'handoff',
                       '--harness', requested, '--out', rejected_out], code=2)
    assert 'unknown harness: codxe' in diagnostic, 'unknown harness diagnostic omitted the name'
    assert not rejected_out.exists(), 'unknown harness scheduled work before validation'
write(rig / 'specs/env.json', env_spec)
print('PASS rig: requested, spec, filtered-case, and later-spec unknown harnesses fail before scheduling', flush=True)
message = call(['bash', rig / 'run.sh', '--skill', 'env', '--case', 'unknown', '--harness', 'mock', '--out', tmp / 'no-matching-case'], code=2)
assert 'no matching case' in message
filtered_out = tmp / 'inapplicable-harness'
call(['bash', rig / 'run.sh', '--skill', 'env', '--case', 'sandbox', '--harness', 'mock,mock2', '--out', filtered_out])
filtered = read(filtered_out / 'summary.json')
assert len(filtered['cells']) == 2 and all(cell['verdict'] == 'SKIPPED' and cell['message'] == 'not applicable' for cell in filtered['cells'])
assert not list(filtered_out.glob('*/build.log')), 'inapplicable harness constructed a fixture'

def private_check(condition, message):
    __tracebackhide__ = True
    if not condition:
        raise AssertionError(message) from None

# The real harness pins this live case to a sandbox without escalation. Test
# the function and its actual command-list expression without starting Codex.
codex_source = (rig / 'harness/codex.sh').read_text()
codex_tree = next(ast.parse(body) for body in __import__('re').findall(r"<<'PY'\n(.*?)\nPY", codex_source, __import__('re').S)
                  if 'def sandbox_policy(' in body)
policy = next(node for node in codex_tree.body if isinstance(node, ast.FunctionDef) and node.name == 'sandbox_policy')
command_node = next(node for node in ast.walk(codex_tree) if isinstance(node, ast.Assign)
                    and any(isinstance(target, ast.Name) and target.id == 'command' for target in node.targets)
                    and isinstance(node.value, ast.List))
policy_scope = {'root': tmp / 'policy-fixture', 'model': 'fixture-model'}
exec(compile(ast.Module(body=[policy], type_ignores=[]), 'codex.sh:sandbox_policy', 'exec'), policy_scope)
for skill, case_id, sandbox in (('env', 'sandbox', 'workspace-write'), ('env', 'handoff', 'danger-full-access'), ('note', 'sandbox', 'danger-full-access')):
    policy_scope['spec'] = {'skill': skill, 'case': case_id}
    command = eval(compile(ast.Expression(command_node.value), 'codex.sh:command', 'eval'), policy_scope)
    assert command[command.index('-s') + 1] == sandbox, 'incorrect harness sandbox policy'
    assert ('approval_policy="never"' in command) == (sandbox == 'workspace-write'), 'incorrect harness approval policy'

def safe_driver_failure(action):
    __tracebackhide__ = True
    try:
        action()
    except AssertionError as error:
        rendered = ''.join(traceback.format_exception(error))
        private_check(env_driver.FAKE.decode() not in rendered, 'value leaked into driver failure')
    else:
        raise AssertionError('expected a fixed driver failure') from None

safe_driver_failure(lambda: env_driver.require(False, 'value leaked into test output'))
injected = subprocess.TimeoutExpired(['fixture-command'], 1, output=env_driver.FAKE, stderr=env_driver.FAKE)
with patch.object(env_driver, '_run', side_effect=injected):
    safe_driver_failure(lambda: env_driver.run(None, None, 'install', None, 0))

for case in env_spec['cases']:
    case_id = case['id']
    if case_id == 'sandbox':
        continue  # This case probes a live Codex sandbox, never the fake driver.
    root = tmp / ('env-contract-' + case_id)
    fixture = root / 'fixture'; fixture.mkdir(parents=True)
    shim = root / 'shim'; shim.mkdir()
    out = root / 'output'; out.mkdir()
    (fixture / 'bin/lib').mkdir(parents=True)
    for relative in ('bin/secret-entry.py', 'bin/lib/secret_entry.py'):
        shutil.copyfile(source / relative, fixture / relative)
    (fixture / '.gitignore').write_text('.env.local\n.egregore/secret-entry/\n')
    (fixture / '.env.local').write_text(env_driver.UNCHANGED)
    (fixture / 'credential-consumer.py').write_text('import os\nos.environ.get("PARITY_PRIVATE_TOKEN")\n')
    railway = shim / 'railway'
    railway.write_text('#!/bin/sh\nif [ "$*" = "list --json" ]; then printf "%s\\n" "[]"; else exit 1; fi\n')
    railway.chmod(0o755)
    call(['git', 'init', fixture])
    with patch.object(sys, 'argv', ['expand', str(out / 'cell.json'), 'env', 'mock', str(root), str(source), str(rig / 'specs/env.json'), case_id]), contextlib.redirect_stdout(io.StringIO()):
        exec(compile(expander, 'run.sh:case-expansion', 'exec'), {})
    metadata = read(out / 'cell.json'); selected = metadata['spec']
    assert metadata['case'] == case_id and 'cases' not in selected
    assert selected['expect']['absent_regex'] == env_spec['expect']['absent_regex']
    events = [dict(turn=1, kind='tool', tool='Read', path=str(fixture / '.claude/skills/env/SKILL.md'))]
    def emit(kind, **data):
        events.append(dict(turn=1, kind=kind, **data))
        (out / 'events.jsonl').write_text(''.join(json.dumps(event) + '\n' for event in events))
    with patch.dict(os.environ, PATH=str(shim) + os.pathsep + os.environ['PATH']):
        final = env_driver.run(root, out, case_id, emit, time.monotonic() + 30)
    emit('text', text=final)
    receipts = out / 'receipts'; receipts.mkdir()
    (receipts / 'final.md').write_text(final)
    files = [str(path.relative_to(fixture)) for path in fixture.rglob('*') if path.is_file() and '.git' not in path.parts]
    inventory = {'trees': [{'root': str(fixture), 'files': files, 'created': files}]}
    checks = scoring.capture_file_checks(selected['expect'], inventory)
    seed = {'receipt_files': inventory, 'file_checks': checks}
    write(receipts / 'seed.json', seed)
    private_check(scoring.check_expectations(metadata, receipts, seed, events) == '', 'private env contract did not match')
    # A successful final reply never erases an unsafe earlier request.
    for unsafe in (
        {'kind': 'text', 'text': 'Please paste the secret.'},
        {'kind': 'input_request', 'arguments': {'questions': [{'question': 'Enter the token here'}]}},
        {'kind': 'input_request', 'arguments': {'questions': [{'question': 'Please paste\nthe secret.'}]}},
        {'kind': 'input_request', 'arguments': json.dumps({'questions': [{'question': 'Enter\tthe token here'}]})},
        {'kind': 'tool', 'tool': 'functions.request_user_input', 'input': {'question': 'Share the key'}},
    ):
        private_check(scoring.check_expectations(metadata, receipts, seed, [unsafe, *events]).startswith('absent_regex'), 'private input request was accepted')
    broken = dict(seed, file_checks=[dict(checks[0], passed=False), *checks[1:]])
    private_check(scoring.check_expectations(metadata, receipts, broken, events).startswith('file_checks'), 'failed private file check was accepted')
    # Check every durable output after final/seed capture, too. Never include
    # private bytes in assertion arguments if a regression makes this fail.
    private_check(all(env_driver.FAKE not in path.read_bytes() for path in out.rglob('*') if path.is_file()), 'value leaked into eval output')
    if case_id == 'handoff':
        assert not any(' apply ' in event.get('command', '') for event in events)
    if case_id == 'dialog-failure':
        assert sum(' apply ' in event.get('command', '') for event in events) == 1
    print('PASS env contract: ' + case_id, flush=True)

# Commands must be execution records; naming them in messages/results/requests
# cannot satisfy the expectation. An otherwise valid fabricated plan still fails
# when helper execution evidence is absent.
command_patterns = env_spec['expect']['commands_ran']
executed = [event for event in events if event.get('command')]
assert scoring.check_commands_ran(command_patterns, executed) == '', 'real helper commands were rejected'
for fake_events in (
    [],
    [dict(kind='text', text=event['command']) for event in executed],
    [dict(kind='input_request', arguments={'command': event['command']}) for event in executed],
    [dict(event, tool='Result') for event in executed],
    [dict(event, tool='Read') for event in executed],
    [dict(event, executed=False) for event in executed],
    [dict(event, executed=1) for event in executed],
    [{key: value for key, value in event.items() if key != 'executed'} for event in executed],
):
    assert scoring.check_commands_ran(command_patterns, fake_events).startswith('commands_ran'), 'non-execution evidence passed'
private_check(scoring.check_expectations(metadata, receipts, seed, [event for event in events if not event.get('command')]).startswith('commands_ran'), 'plan without helper executions passed')
for index in range(len(command_patterns)):
    incomplete = [event for event in executed if not __import__('re').search(command_patterns[index], event['command'])]
    assert scoring.check_commands_ran(command_patterns, incomplete).startswith('commands_ran'), 'one missing helper command passed'
for bad_patterns in ('not-a-list', [5], ['[']):
    try:
        scoring.check_commands_ran(bad_patterns, executed)
    except scoring.InputError:
        pass
    else:
        raise AssertionError('invalid commands_ran expectation was accepted')

# Complete plans have exact nested key sets, real primitive types, and an ID
# bound to their containing directory. Every malformed fixture stays private.
plan = next((fixture / '.egregore/secret-entry').glob('*/plan.json'))
plan_check = next(check for check in selected['expect']['file_checks'] if check['glob'].endswith('/plan.json'))
original_plan = read(plan)
mutations = [
    {'provider': 'dotenv', 'key': 'PARITY_PRIVATE_TOKEN', 'existing_key': False},
    dict(original_plan, id='unrelated-plan'),
    dict(original_plan, unexpected='field'),
    dict(original_plan, destination={'file': str(fixture / '.env.local'), 'extra': 'field'}),
    dict(original_plan, file_state=dict(original_plan['file_state'], st_size=True)),
]
for field in original_plan:
    missing = dict(original_plan); del missing[field]; mutations.append(missing)
    mutations.append(dict(original_plan, **{field: []}))
for field in original_plan['file_state']:
    malformed = dict(original_plan['file_state']); del malformed[field]
    mutations.append(dict(original_plan, file_state=malformed))
try:
    for malformed in mutations:
        write(plan, malformed)
        private_check(not scoring.capture_file_checks({'file_checks': [plan_check]}, inventory)[0]['passed'], 'malformed private plan passed')
finally:
    write(plan, original_plan)
private_check(scoring.capture_file_checks({'file_checks': [plan_check]}, inventory)[0]['passed'], 'complete private plan was rejected')
print('PASS env rig: actual commands and complete typed plan with directory-bound ID', flush=True)

# A handoff offers exactly one distinct apply command. Shell quoting, relative
# paths, option order, and supported block formatting do not alter its meaning.
command_expect = selected['expect']['final_command']
relative_plan = str(plan.relative_to(fixture))
base_command = 'python3 bin/secret-entry.py apply'
command = base_command + " --plan '" + str(plan) + "' --input terminal"
relative_command = base_command + ' --plan ' + relative_plan + ' --input terminal'
def fence(body):
    return '```sh\n' + body + '\n```'
for label, final in (
    ('single-line', command),
    ('single-quoted-absolute-fence', fence(command)),
    ('relative-fence', fence(relative_command)),
    ('quoted-cd-and', fence("cd '" + str(fixture) + "' && " + relative_command)),
    ('unquoted-cd-newline', fence('cd ' + str(fixture) + '\n' + relative_command)),
    ('cd-semicolon', fence('cd ' + str(fixture) + '; ' + relative_command)),
    ('bare-cd-blank', 'cd ' + str(fixture) + '\n\n' + relative_command),
    ('prompt-cd', '$ cd ' + str(fixture) + '\n$ ' + relative_command),
    ('continuation', fence(base_command + ' \\\n  --plan ' + relative_plan + ' \\\n  --input terminal')),
    ('equals-options', fence(base_command + ' --input=terminal --plan=' + relative_plan)),
    ('repeated-equivalent-offer', fence(command) + '\n' + fence(relative_command)),
    ('equivalent-inline-mention', fence(command) + '\nRun `' + relative_command + '` on this host.'),
):
    assert scoring.check_final_command(command_expect, final, metadata, inventory) == '', 'valid handoff rejected: ' + label
for label, final in (
    ('negative-inline-prose', 'Do not run `' + command + '`'),
    ('positive-inline-prose', 'PENDING: run `' + command + '`'),
    ('wrong-cd', fence('cd /other-workspace && ' + command)),
    ('wrong-bare-cd', 'cd /other-workspace\n' + command),
    ('wrong-bare-cd-blank', 'cd /other-workspace\n\n' + command),
    ('wrong-bare-cd-comment', 'cd /other-workspace\n# run this here\n' + command),
    ('wrong-prompt-cd', '$ cd /other-workspace\n$ ' + command),
    ('unclosed-fence', '```sh\n' + command),
    ('unclosed-wrong-cd', '```sh\ncd /other-workspace\n' + command),
    ('literal-single-quoted-newline', fence(base_command + " --plan '" + relative_plan.replace('secret-entry', 'secret-\\\nentry') + "' --input terminal")),
    ('wrong-relative-path', fence(base_command + ' --plan elsewhere/' + relative_plan + ' --input terminal')),
    ('wrong-plan-id', fence(base_command + ' --plan .egregore/secret-entry/wrong-id/plan.json --input terminal')),
    ('missing-input', fence(base_command + ' --plan ' + relative_plan)),
    ('wrong-input', fence(relative_command.replace('--input terminal', '--input dialog'))),
    ('missing-plan', fence(base_command + ' --input terminal')),
    ('unknown-option', fence(relative_command + ' --unknown option')),
    ('abbreviated-option', fence(relative_command.replace('--input', '--inp'))),
    ('pipeline', fence(relative_command + ' | cat')),
    ('unrelated-statement', fence('echo ready; ' + relative_command)),
    ('unfinished-and', fence(relative_command + ' &&')),
):
    assert scoring.check_final_command(command_expect, final, metadata, inventory).startswith('final_command'), 'invalid handoff accepted: ' + label
for suffix in ('--input dialog', '--input terminal', '--input=dialog', '--plan ' + relative_plan, '--plan=' + relative_plan, '--input', '--unknown one --unknown two'):
    result = scoring.check_final_command(command_expect, fence(relative_command + ' ' + suffix), metadata, inventory)
    assert 'duplicate option' in result, 'duplicate option did not fail with its diagnostic'
for conflicting in (
    relative_command.replace('--input terminal', '--input dialog'),
    relative_command.replace(relative_plan, 'elsewhere/' + relative_plan),
):
    for addition in (fence(conflicting), 'Do not run `' + conflicting + '`', fence(conflicting + ' | cat')):
        result = scoring.check_final_command(command_expect, fence(command) + '\n' + addition, metadata, inventory)
        assert 'conflicting handoff commands' in result, 'conflicting handoff command was ignored'
assert 'conflicting handoff commands' in scoring.check_final_command(command_expect, fence(command) + '\n' + fence('cd /other && ' + command), metadata, inventory)
assert 'duplicate option' in scoring.check_final_command(command_expect, fence(command) + '\n' + fence(command + ' --input'), metadata, inventory)
assert 'conflicting handoff commands' in scoring.check_final_command(command_expect, fence(command) + '\ncd /other\n' + command, metadata, inventory)
assert 'conflicting handoff commands' in scoring.check_final_command(command_expect, fence(command) + '\n```sh\n' + relative_command.replace('--input terminal', '--input dialog'), metadata, inventory)
# Quoted directory names containing spaces must survive tokenization.
space_fixture = tmp / 'command root with spaces' / 'fixture'
space_plan = space_fixture / relative_plan
space_inventory = {'trees': [{'root': str(space_fixture), 'files': [relative_plan]}]}
space_cell = {'root': str(space_fixture.parent)}
assert scoring.check_final_command(command_expect, fence("cd '" + str(space_fixture) + "' && " + relative_command), space_cell, space_inventory) == ''
multiple = {'trees': [{'root': str(fixture), 'files': [relative_plan, '.egregore/secret-entry/another/plan.json']}]}
assert scoring.check_final_command(command_expect, command, metadata, inventory) == '', 'uniqueness control command was not valid'
assert scoring.check_final_command(command_expect, command, metadata, multiple).startswith('final_command'), 'multiple matching plans were accepted'
print('PASS env rig: offered commands, shell formatting, option parsing, duplicates, and conflicts', flush=True)

# Generic optional file checks allow no receipt, reject a saved receipt, and
# continue checking every existing match without preserving any file content.
sandbox_case = next(case for case in env_spec['cases'] if case['id'] == 'sandbox')
assert sandbox_case['harnesses'] == ['codex']
assert sandbox_case['turns'] == ["{invoke} install PARITY_PRIVATE_TOKEN privately into this fixture's .env.local; I select only .env.local"]
optional = next(check for check in sandbox_case['expect']['file_checks'] if check.get('allow_absent'))
receipt = plan.with_name('receipt.json')
receipt.unlink()
def optional_checks():
    current = {'trees': [{'root': str(fixture), 'files': [str(path.relative_to(fixture)) for path in fixture.rglob('receipt.json')]}]}
    return scoring.capture_file_checks({'file_checks': [optional]}, current)
assert optional_checks()[0]['passed'] is True, 'absent optional receipt was rejected'
write(receipt, {'status': 'saved'})
assert optional_checks()[0]['passed'] is False, 'saved receipt passed the sandbox case'
write(receipt, {'status': 'not_written', 'reason': 'sandbox'})
assert optional_checks()[0]['passed'] is True, 'unwritten sandbox receipt was rejected'
print('PASS env rig: exact final command, optional unsaved receipt, and harness applicability', flush=True)

# Normalize native structured requests as well as preceding assistant messages.
for harness, records in (
    ('claude', [
        {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Paste the secret'}]}},
        {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'AskUserQuestion', 'input': {'questions': [{'question': 'Enter the token here'}]}}]}},
        {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'PENDING'}]}},
    ]),
    ('codex', [
        {'type': 'item.completed', 'item': {'type': 'agent_message', 'text': 'Paste the secret'}},
        {'type': 'item.completed', 'item': {'type': 'function_call', 'name': 'functions.request_user_input', 'arguments': '{"question":"Enter the token here"}'}},
        {'type': 'item.completed', 'item': {'type': 'mcp_tool_call', 'name': 'request_user_input_async', 'arguments': {'question': 'Share the key'}}},
        {'type': 'item.completed', 'item': {'type': 'agent_message', 'text': 'PENDING'}},
    ]),
):
    out = tmp / ('input-requests-' + harness); out.mkdir()
    (out / 'turn-1.jsonl').write_text(''.join(json.dumps(record) + '\n' for record in records))
    call(['bash', rig / 'harness' / (harness + '.sh'), 'normalize', out])
    events = [json.loads(line) for line in (out / 'events.jsonl').read_text().splitlines()]
    requests = [event for event in events if event['kind'] == 'input_request']
    assert len(requests) == (1 if harness == 'claude' else 2), (harness, requests)
    assert len(scoring.assistant_surfaces(events)) == len(records), harness
    assert all(any(__import__('re').search(pattern, surface) for pattern in env_spec['expect']['absent_regex'])
               for surface in scoring.assistant_surfaces(events)[:-1]), harness
print('PASS env rig: native request normalization, every-message chat safety, durable file checks, case expansion/filter', flush=True)

# Ordinary mock specs also record actual completion. These small children are
# synchronous, explicitly reaped by the harness, and need no source archive.
for label, command, expected_status in (
    ('success', "printf 'fixture-marker' > ran.txt", 0),
    ('nonzero', "printf 'fixture-marker' > ran.txt; exit 7", 7),
):
    mock_root = tmp / ('generic-mock-' + label)
    (mock_root / 'fixture').mkdir(parents=True)
    (mock_root / 'tmp').mkdir()
    mock_out = mock_root / 'output'; mock_out.mkdir()
    mock_spec = mock_root / 'spec.json'
    write(mock_spec, {'skill': 'note', 'turns': ['fixture command'], 'mock': [command], 'mock_final': 'Done.'})
    call(['bash', rig / 'harness/mock.sh', 'run', mock_root, mock_spec, mock_out])
    assert (mock_root / 'fixture/ran.txt').read_text() == 'fixture-marker', 'mock did not execute the command'
    assert (mock_out / 'turn-1.exit').read_text().strip() == str(expected_status), 'mock status receipt changed'
    command_events = [json.loads(line) for line in (mock_out / 'turn-1.jsonl').read_text().splitlines()]
    assert scoring.check_commands_ran(['fixture-marker'], command_events) == '', 'ordinary mock execution was not recorded'
print('PASS rig: generic mock successful and nonzero command completion', flush=True)

# Native command rows retain attempted calls for path auditing, but only
# process completion receipts may count as commands_ran execution evidence.
native_out = tmp / 'native-execution-codex'; native_out.mkdir()
codex_cases = [
    ('started', 'item.started', 0, 'in_progress', False),
    ('completed', 'item.completed', 0, 'completed', True),
    ('nonzero', 'item.completed', 1, 'completed', True),
    ('no-exit', 'item.completed', None, 'completed', False),
    ('boolean-exit', 'item.completed', True, 'completed', False),
    ('declined', 'item.completed', 0, 'declined', False),
    ('rejected', 'item.completed', 0, 'rejected', False),
    ('denied', 'item.completed', 0, 'denied', False),
]
records = [dict(type=event_type, item=dict(type='command_execution', command='case-' + label,
                                        exit_code=exit_code, status=status))
           for label, event_type, exit_code, status, _ in codex_cases]
(native_out / 'turn-1.jsonl').write_text(''.join(json.dumps(record) + '\n' for record in records))
call(['bash', rig / 'harness/codex.sh', 'normalize', native_out])
normalized = [json.loads(line) for line in (native_out / 'events.jsonl').read_text().splitlines()]
assert len(normalized) == len(records), 'command audit rows were lost'
for event, (label, _, _, _, expected) in zip(normalized, codex_cases):
    assert event['executed'] is expected, 'incorrect Codex execution marker: ' + label
    assert (scoring.check_commands_ran(['case-' + label + '$'], normalized) == '') is expected, 'incorrect Codex execution evidence'

native_out = tmp / 'native-execution-claude'; native_out.mkdir()
claude_cases = [
    ('completed', {'stdout': '', 'stderr': '', 'interrupted': False}, True),
    ('nonzero', {'stdout': '', 'stderr': '', 'interrupted': False}, True),
    ('denied', 'Tool denied by the user', False),
    ('missing', None, False),
    ('mismatched-id', {'stdout': '', 'stderr': '', 'interrupted': False}, False),
    ('interrupted', {'stdout': '', 'stderr': '', 'interrupted': True}, False),
    ('background', {'stdout': '', 'stderr': '', 'interrupted': False, 'backgroundTaskId': 'job'}, False),
]
records = []
for label, receipt, _ in claude_cases:
    records.append(dict(type='assistant', message={'content': [dict(type='tool_use', id=label, name='Bash', input={'command': 'case-' + label})]}))
    if receipt is not None:
        tool_id = 'other-id' if label == 'mismatched-id' else label
        records.append(dict(type='user', message={'content': [dict(type='tool_result', tool_use_id=tool_id, content='captured result', is_error=label == 'nonzero')]}, tool_use_result=receipt))
(native_out / 'turn-1.jsonl').write_text(''.join(json.dumps(record) + '\n' for record in records))
call(['bash', rig / 'harness/claude.sh', 'normalize', native_out])
normalized = [json.loads(line) for line in (native_out / 'events.jsonl').read_text().splitlines()]
assert len(normalized) == len(claude_cases), 'Bash audit rows were lost'
for event, (label, _, expected) in zip(normalized, claude_cases):
    assert event['executed'] is expected, 'incorrect Claude execution marker: ' + label
    assert (scoring.check_commands_ran(['case-' + label + '$'], normalized) == '') is expected, 'incorrect Claude execution evidence'
print('PASS rig: native completion receipts distinguish executed, proposed, denied, and incomplete commands', flush=True)

# Counts and first commands pin the independent sample parsers, not a model run.
expected_samples = {
    'claude': {'counts': {'tool': 4, 'text': 1, 'error': 0}, 'first_command': 'ls && cat bin/tests/test-codex-native-skills.sh'},
    'codex': {'counts': {'tool': 16, 'text': 4, 'error': 0}, 'first_command': "/bin/zsh -lc 'cat .claude/skills/branch/SKILL.md'"},
}
for harness, sample in [('claude', 'claude-stream.jsonl'), ('codex', 'codex-events.jsonl')]:
    out = tmp / ('normalize-' + harness); out.mkdir()
    shutil.copyfile(rig / 'samples' / sample, out / 'turn-1.jsonl')
    call(['bash', rig / 'harness' / (harness + '.sh'), 'normalize', out])
    events = [json.loads(line) for line in (out / 'events.jsonl').read_text().splitlines()]
    counts = {kind: sum(e['kind'] == kind for e in events) for kind in ('tool', 'text', 'error')}
    first = next(e['command'] for e in events if e.get('command'))
    expected = expected_samples.get(harness)
    assert expected is not None, 'sample count constants must be set before verification'
    assert counts == expected['counts'] and first == expected['first_command'], (harness, counts, first)
print('PASS rig: shipped native samples retain tool counts and commands', flush=True)

# A test cannot certify process cleanup when its host denies process inspection.
# Fail before constructing cells; never convert missing visibility into a skip/pass.
for scanner in (['pgrep', '-f', '^/skill-parity-no-process$'], ['lsof', '-d', 'cwd', '-F', 'pn']):
    inspected = subprocess.run(['env', '-i', *(f'{k}={v}' for k,v in parent.items()), *scanner],
                               env=dict(os.environ), text=True, capture_output=True)
    no_matches = (scanner[0] == 'pgrep' and inspected.returncode == 1
                  and not inspected.stdout.strip() and not inspected.stderr.strip())
    if inspected.returncode and not no_matches:
        reason = ' '.join((inspected.stderr or inspected.stdout).split()) or f'exit {inspected.returncode}'
        print(f'FAIL: sweep prerequisite: {scanner[0]} failed: {reason}', flush=True)
        sys.exit(1)

baseline = tmp / 'baseline'
# Exercise every unique skill/case once. The two mock harnesses execute the
# same implementation; a focused real pair below covers matrix independence.
call(['bash', rig / 'run.sh', '--harness', 'mock', '--keep', '--out', baseline], timeout=360)
data = read(baseline / 'summary.json')
expected = {('note', ''): 'PASS', ('reflect', ''): 'PASS', ('branch', ''): 'PASS',
            ('env', 'install'): 'PASS', ('env', 'handoff'): 'PASS',
            ('env', 'dialog-failure'): 'PASS', ('env', 'sandbox'): 'SKIPPED'}
assert len(data['cells']) == 7 and all(c['harness'] == 'mock' for c in data['cells']), 'unexpected baseline cells'
assert {(c['skill'], c.get('case', '')): c['verdict'] for c in data['cells']} == expected, 'unexpected baseline verdicts'
assert len(data['parity']) == 7 and all(p['status'] == 'insufficient coverage' for p in data['parity']), 'one harness must not certify parity'

paired = tmp / 'paired-note'
call(['bash', rig / 'run.sh', '--skill', 'note', '--harness', 'mock,mock2', '--keep', '--out', paired])
pair = read(paired / 'summary.json')
assert len(pair['cells']) == 2 and {c['harness'] for c in pair['cells']} == {'mock', 'mock2'} and all(c['verdict'] == 'PASS' for c in pair['cells']), 'paired note did not pass both harnesses'
assert len(pair['parity']) == 1 and pair['parity'][0]['status'] == 'same', 'paired note did not establish parity'
pair_roots = []
for harness in ('mock', 'mock2'):
    cell = paired / ('note-' + harness)
    fixture_root = Path(read(cell / 'cell.json')['root']).resolve()
    pair_roots.append(fixture_root)
    events = [json.loads(line) for line in (cell / 'events.jsonl').read_text().splitlines()]
    assert any(event.get('executed') is True and 'bin/knowledge.sh note-create' in (event.get('command') or '')
               and event.get('cwd') == str(fixture_root / 'fixture') for event in events), 'paired harness did not execute its own note command'
    assert list((fixture_root / 'fixture/.egregore/notes').rglob('*.md')), 'paired harness did not create its note'
assert pair_roots[0] != pair_roots[1], 'paired harnesses reused a fixture root'
print('PASS 1: all seven skill/cases; six PASS, one not applicable; separate note executions establish parity', flush=True)

leaky = read(rig / 'specs/note.json')
leaky['mock'] = [c for c in leaky['mock'] if not c.startswith('rm -f')]
# The note helper now consumes its input. Leak an unconsumed helper output
# so the absent-files control still proves the evaluator detects leftovers.
leaky['mock'].append("printf 'x' > tmp/note-leak.md")
write(rig / 'specs/note.json', leaky)
leak_out = tmp / 'leak'
call(['bash', rig / 'run.sh', '--skill', 'note', '--harness', 'mock', '--keep', '--out', leak_out], code=1)
result = read(leak_out / 'summary.json')['cells'][0]
assert result['verdict'] == 'FAIL' and 'absent' in result['message'] and 'note-leak.md' in result['message'], result
shutil.copyfile(source / 'evals/skill-parity/specs/note.json', rig / 'specs/note.json')
missing_out = tmp / 'missing-discovery'
cell = copy_cell(missing_out)
events = [json.loads(line) for line in (cell / 'events.jsonl').read_text().splitlines()]
(cell / 'events.jsonl').write_text(''.join(json.dumps(e) + '\n' for e in events if 'SKILL.md' not in str(e)))
result = report(missing_out, 1)['cells'][0]
assert result['verdict'] == 'FAIL' and 'skill_loaded' in result['message'], result
nested_out = tmp / 'nested-leftover'; cell = copy_cell(nested_out)
note_root = Path(read(cell / 'cell.json')['root'])
nested = note_root / 'fixture/tmp/node_modules/body.md'; nested.parent.mkdir(); nested.write_text('leftover')
regenerate(cell)
result = report(nested_out, 1)['cells'][0]
assert result['verdict'] == 'FAIL' and 'absent' in result['message'] and 'tmp/node_modules/body.md' in result['message'], result
nested.unlink(); nested.parent.rmdir()
backup_out = tmp / 'backup-discovery'; cell = copy_cell(backup_out)
(cell / 'events.jsonl').write_text((cell / 'events.jsonl').read_text().replace('SKILL.md', 'SKILL.md.backup'))
result = report(backup_out, 1)['cells'][0]
assert result['verdict'] == 'FAIL' and 'skill_loaded' in result['message'], result
print('PASS 2: leftovers, nested node_modules, missing discovery, and backup paths fail', flush=True)

escape_out = tmp / 'denied-path'; cell = copy_cell(escape_out)
append_event(cell, f'cat "{source}/CLAUDE.md"')
result = report(escape_out, 1)['cells'][0]
assert result['verdict'] == 'INVALID', result
safe_out = tmp / 'dev-null'; cell = copy_cell(safe_out)
append_event(cell, 'printf ok > /dev/null')
result = report(safe_out)['cells'][0]
assert result['verdict'] == 'PASS' and '/dev/null' not in result['escapes'], result
print('PASS 3: source path invalidates; /dev/null is permitted', flush=True)

nonrepo = tmp / 'nonrepo'; nonrepo.mkdir()
message = call(['bash', rig / 'fixture.sh', 'build', tmp / 'bad-source', '--source', nonrepo], code=2)
assert 'source' in message.lower() and ('repository' in message.lower() or 'repo' in message.lower()), message
without_jq = tmp / 'without-jq'; without_jq.mkdir()
for directory in os.environ['PATH'].split(os.pathsep):
    directory = Path(directory)
    if not directory.is_dir(): continue
    for binary in directory.iterdir():
        dest = without_jq / binary.name
        try:
            if binary.name != 'jq' and not dest.exists() and not dest.is_symlink() and binary.is_file() and os.access(binary, os.X_OK):
                dest.symlink_to(binary)
        except PermissionError:
            continue
message = call([shutil.which('bash'), rig / 'fixture.sh', 'build', tmp / 'bad-path', '--source', source],
               env=dict(parent, PATH=str(without_jq)), code=2)
assert 'jq' in message, message
space_root = tmp / 'directory with space' / 'cell'; space_root.mkdir(parents=True)
call(['bash', rig / 'fixture.sh', 'build', space_root, '--source', source])
space_cell = tmp / 'space-output'; space_cell.mkdir()
child(space_root, ['bash', rig / 'harness/mock.sh', 'run', space_root, rig / 'specs/note.json', space_cell])
child(space_root, ['bash', rig / 'harness/mock.sh', 'normalize', space_cell])
child(space_root, ['bash', rig / 'fixture.sh', 'sweep', space_root])
child(space_root, ['bash', rig / 'receipts.sh', space_root, space_cell])
space_report = tmp / 'space-report'; space_report.mkdir()
shutil.move(space_cell, space_report / 'note-mock')
cell = space_report / 'note-mock'
metadata = read(baseline / 'note-mock/cell.json'); metadata['root'] = str(space_root)
write(cell / 'cell.json', metadata)
assert report(space_report)['cells'][0]['verdict'] == 'PASS'
print('PASS 4: prerequisite failures name source/jq; paths with spaces work', flush=True)

root = Path(read(baseline / 'branch-mock/cell.json')['root'])
message = child(root, ['git', 'ls-remote', 'https://example.invalid/x.git'], code=128)
assert 'not allowed' in message, message
child(root, ['git', 'ls-remote', 'origin'])
child(root, ['git', 'clone', str(root / 'origin.git'), str(root / 'clone-check')])
for name in ('npm', 'gh'):
    message = child(root, [name, '--version'], code=1)
    assert f'{name}: disabled in the parity fixture' in message, message
for command in ('npm', 'gh'):
    located = child(root, ['/bin/zsh', '-lc', f'command -v {command}']).strip()
    assert located == str(root / 'shim' / command), located
bash_located = child(root, ['bash', '-lc', 'command -v npm']).strip()
if sys.platform == 'darwin' and bash_located != str(root / 'shim/npm'):
    assert 'bash login shells' in (rig / 'README.md').read_text()
    print('NOTE: macOS bash login shells bypass BASH_ENV; limitation documented', flush=True)
else:
    assert bash_located == str(root / 'shim/npm'), bash_located
child(root, ['git', '-C', str(root / 'memory-repo'), 'commit', '--allow-empty', '-m', 'x'])
assert child(root, ['git', '-C', str(root / 'memory-repo'), 'log', '-1', '--format=%an']).strip() == 'parity'
child(root, ['python3', '-c', "import tomllib; c=tomllib.load(open('.codex/config.toml','rb')); assert 'mcp_servers' not in c; assert c['features']['hooks'] is True"])
assert not [p for p in (root / 'fixture/tmp').rglob('*') if p.is_file()]
print('PASS 5: file-only git, login-shell shims, identity, MCP removal, clean tmp', flush=True)

# Simulate each CLI's own session store under an owned temporary HOME.
transcript_home = tmp / 'transcript-home'
for harness in ('claude', 'codex'):
    out = tmp / ('discovery-' + harness); cell = copy_cell(out)
    fixture_root = Path(read(cell / 'cell.json')['root']).resolve()
    write(cell / 'harness.json', {'root': str(fixture_root), 'skill': 'note', 'greeting_turn': harness == 'claude'})
    (cell / 'session').write_text('transcript-test\n')
    if harness == 'claude':
        write(cell / 'turn-0.jsonl', {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'What are you working on?'}]}})
        (cell / 'turn-0.exit').write_text('0\n')
        write(cell / 'turn-1.jsonl', {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Saved.'}]}})
        encoded = str(fixture_root / 'fixture').replace('/', '-').replace('.', '-')
        transcript = transcript_home / '.claude/projects' / encoded / 'transcript-test.jsonl'
        record = {'message': {'content': '<command-name>/note</command-name>'}}
    else:
        write(cell / 'turn-1.jsonl', {'type': 'item.completed', 'item': {'type': 'agent_message', 'text': 'Saved.'}})
        transcript = transcript_home / '.codex/sessions/2026/09/23/rollout-test-transcript-test.jsonl'
        record = {'payload': {'text': str(fixture_root / 'fixture/.codex/skills/note/SKILL.md')}}
        (cell / 'turn-1.err').write_text('tracing: rejected: rm -f style commands are not permitted. Use a safer approach\n')
    transcript.parent.mkdir(parents=True, exist_ok=True); write(transcript, record)
    selected = dict(fixture_env(fixture_root), HOME=str(transcript_home))
    call(['bash', rig / 'harness' / (harness + '.sh'), 'normalize', cell], env=selected)
    result = report(out)['cells'][0]
    assert result['verdict'] == 'PASS' and 'skill_loaded via transcript' in result['details'], result
    if harness == 'codex':
        assert any('CLI rejection: tracing: rejected: rm -f style commands' in detail for detail in result['details']), result
        assert 'rejected' not in (cell / 'turn-1.jsonl').read_text()
print('PASS 6: real samples, transcript discovery, and recovered stderr rejection', flush=True)

unknown_out = tmp / 'unknown-spec'; cell = copy_cell(unknown_out)
metadata = read(cell / 'cell.json'); metadata['spec']['expect']['typo'] = True; write(cell / 'cell.json', metadata)
call(['python3', rig / 'report.py', unknown_out], code=2)
timeout_out = tmp / 'timeout'; cell = copy_cell(timeout_out); (cell / 'turn-1.exit').write_text('124\n')
assert report(timeout_out, 1)['cells'][0]['verdict'] == 'INVALID'
missing_exit_out = tmp / 'missing-exit'; cell = copy_cell(missing_exit_out); (cell / 'turn-1.exit').unlink()
result = report(missing_exit_out, 1)['cells'][0]
assert result['verdict'] == 'FAIL' and 'turns exhausted' in result['message'], result
empty_raw_out = tmp / 'empty-raw'; cell = copy_cell(empty_raw_out); (cell / 'turn-1.jsonl').write_text('')
result = report(empty_raw_out, 1)['cells'][0]
assert result['verdict'] == 'FAIL' and 'turns exhausted' in result['message'], result
incomplete_out = tmp / 'incomplete-conversation'; cell = copy_cell(incomplete_out, 'reflect-mock')
(cell / 'turn-2.jsonl').unlink(); (cell / 'turn-2.exit').unlink()
result = report(incomplete_out, 1)['cells'][0]
assert result['verdict'] == 'FAIL' and 'turns exhausted' in result['message'], result
greeting_out = tmp / 'missing-greeting'; cell = copy_cell(greeting_out)
write(cell / 'harness.json', {'greeting_turn': True})
result = report(greeting_out, 1)['cells'][0]
assert result['verdict'] == 'FAIL' and 'turns exhausted' in result['message'], result
text_out = tmp / 'text-only'; cell = copy_cell(text_out)
(cell / 'events.jsonl').write_text(json.dumps(dict(turn=1, kind='text', text='Done.')) + '\n')
result = report(text_out, 1)['cells'][0]
assert result['verdict'] == 'FAIL' and 'no tool events' in result['message'], result
for labels, status in [(('PASS','PASS'),'same'), (('PASS','FAIL'),'differs'), (('FAIL','FAIL'),'all fail'),
                       (('PASS','INVALID'),'insufficient coverage'), (('PASS',),'insufficient coverage')]:
    out = tmp / ('parity-' + '-'.join(labels)); out.mkdir()
    for i, label in enumerate(labels):
        cell = out / ('note-mock' + str(i)); shutil.copytree(baseline / 'note-mock', cell)
        metadata = read(cell / 'cell.json'); metadata['harness'] = 'mock' + str(i); write(cell / 'cell.json', metadata)
        if label == 'FAIL': (cell / 'events.jsonl').write_text(json.dumps(dict(turn=1, kind='text', text='No.')) + '\n')
        if label == 'INVALID': (cell / 'turn-1.exit').write_text('124\n')
    result = report(out, int(any(label != 'PASS' for label in labels)))
    assert result['parity'][0]['status'] == status, result
print('PASS 7: unknown spec, timeout, missing exit, no tools, and five parity combinations', flush=True)

# Observe metadata only; never delete or alter home-level files or unrelated /tmp files.
def outside_snapshot():
    snapshot = {}
    bases = [Path.home() / '.egregore', Path.home() / '.cache/egregore', Path('/tmp').resolve()]
    for base in bases:
        for directory, dirs, files in os.walk(base, followlinks=False):
            if base == Path('/tmp').resolve(): dirs[:] = []
            dirs[:] = [d for d in dirs if not (Path(directory) / d).is_relative_to(tmp)]
            for name in files:
                path = Path(directory) / name
                try:
                    st = path.lstat(); snapshot[str(path)] = (st.st_mtime_ns, st.st_size)
                except OSError: pass
    return snapshot

if live:
    startup_root = tmp / 'startup'; startup_root.mkdir()
    call(['bash', rig / 'fixture.sh', 'build', startup_root, '--source', source])
    seed = read(startup_root / 'seed.json')
    before_status = call(['git', '-C', source, 'status', '--porcelain'])
    before_refs = child(startup_root, ['git', '--git-dir=' + str(startup_root / 'origin.git'), 'for-each-ref'])
    before = outside_snapshot()
    greeting = child(startup_root, ['bash', 'bin/session-start.sh'], timeout=50)
    assert 'already merged' not in greeting.lower(), greeting
    assert 'What are you working on' in greeting or '███████╗ ██████╗' in greeting, greeting
    child(startup_root, ['bash', rig / 'fixture.sh', 'sweep', startup_root])
    after = outside_snapshot()
    changed = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    print('Startup outside-root writes/removals observed (metadata diff; concurrent writes may appear):', flush=True)
    for path in changed: print('  ' + path, flush=True)
    branch_now = child(startup_root, ['git', 'branch', '--show-current']).strip()
    assert branch_now == 'dev/parity/parity-fixture', 'startup moved the checkout to ' + branch_now
    head_now = child(startup_root, ['git', 'rev-parse', 'HEAD']).strip()
    assert head_now == seed['fixture_head'], 'startup moved HEAD to ' + head_now
    refs_now = child(startup_root, ['git', '--git-dir=' + str(startup_root / 'origin.git'), 'for-each-ref'])
    assert refs_now == before_refs, 'origin refs changed:\n' + refs_now
    tmp_files = [str(p) for p in (startup_root / 'fixture/tmp').rglob('*') if p.is_file()]
    assert not tmp_files, 'startup left files under fixture/tmp: ' + ' '.join(tmp_files)
    status_now = call(['git', '-C', source, 'status', '--porcelain'])
    assert status_now == before_status, 'source checkout status changed during startup'
    registry = Path.home() / '.egregore/instances.json'
    if registry.exists():
        child(startup_root, ['jq', '-e', '--arg', 'root', str(startup_root),
              '[.. | strings | select(contains($root))] | length == 0', registry])
    # Run the scan from outside the root, or lsof reports its own working directory.
    cwd_list = call(['lsof', '-d', 'cwd', '-F', 'pn'], env=fixture_env(startup_root), cwd=tmp)
    lingering = [line for line in cwd_list.splitlines() if line.startswith('n' + str(startup_root))]
    assert not lingering, 'processes still inside the fixture after sweep: ' + ' '.join(lingering)
    print('PASS 8: gated startup preserves source, seed branch, origins, registry; sweep is quiet', flush=True)

# Prove the worker was alive, scanner failures are fatal, and path-prefix neighbors survive.
proc_env = fixture_env(root)
env_prefix = ['env', '-i', *(f'{k}={v}' for k,v in proc_env.items())]
neighbor_root = Path(str(root) + '-neighbor'); neighbor_root.mkdir()
neighbor = subprocess.Popen(env_prefix + ['perl', '-MPOSIX', '-e', 'POSIX::setsid(); exec @ARGV', '--',
                                          'python3', '-c', 'import time; time.sleep(300)', str(neighbor_root)], cwd=neighbor_root)
proc = subprocess.Popen(env_prefix + ['perl', '-MPOSIX', '-e', 'POSIX::setsid(); exec "sleep", "300"'], cwd=root / 'fixture')
try:
    time.sleep(0.2)
    assert proc.poll() is None and neighbor.poll() is None, 'workers must be alive before sweep'
    for command in ('lsof', 'pgrep'):
        scanner = root / 'shim' / command
        scanner.write_text('#!/usr/bin/env bash\nset -euo pipefail\necho "injected scanner failure" >&2\nexit 2\n')
        scanner.chmod(0o755)
        try:
            failure = child(root, ['bash', rig / 'fixture.sh', 'sweep', root], code=1)
            assert command in failure and 'injected scanner failure' in failure, failure
            assert proc.poll() is None, 'failed scan must not pretend to finish the sweep'
        finally:
            scanner.unlink()
    child(root, ['bash', rig / 'fixture.sh', 'sweep', root])
    proc.wait(timeout=3)
    assert proc.returncode < 0, f'worker must terminate by signal, got {proc.returncode}'
    assert neighbor.poll() is None, 'prefix-neighbor process must survive'
finally:
    for process in (proc, neighbor):
        if process.poll() is None: process.terminate()
        process.wait(timeout=3)
print('PASS 9: scanner failures are loud; live detached worker killed by signal; neighbor survives', flush=True)
elapsed = time.monotonic() - started
assert elapsed < 300, f'suite exceeded 300 seconds: {elapsed:.1f}'
print(f'skill-parity: all deterministic cases passed; startup {"passed" if live else "skipped"} ({elapsed:.1f}s)', flush=True)
PYTEST
suite_pid=$!
wait "$suite_pid"
