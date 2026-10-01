#!/usr/bin/env bash
# Deterministic shell contract: no actual network or provider writes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 -I - "$ROOT/bin/tests/test-mcp-register-roundtrip.sh" <<'PY'
import json, os
from pathlib import Path
import subprocess, sys, tempfile

smoke = sys.argv[1]
secret = 'private-fixture-credential'
token = 'fixture-bearer-token-0123456789'
relay = 'https://relay-fixture.invalid'
mock = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == '--disable'
for flag, value in [('--connect-timeout', '5'), ('--max-time', '15'),
                    ('--max-filesize', '65536'), ('--proto', '=http,https'),
                    ('--retry', '0'), ('--write-out', '%{http_code}')]:
    assert args[args.index(flag) + 1] == value
assert '--silent' in args and '--globoff' in args and '--location' not in args and '-L' not in args
calls = Path(os.environ['CURL_CALLS'])
number = len(calls.read_text().splitlines()) + 1 if calls.exists() else 1
with calls.open('a') as stream:
    stream.write(json.dumps(args) + '\n')
mode = os.environ['MOCK_MODE']
print(os.environ['PRIVATE'] + ' ' + args[-1], file=sys.stderr)
if mode == 'network-' + str(number):
    raise SystemExit(28)
status = [200, 200, 404, 200, 404, 422, 422][number - 1]
identity_path = calls.with_suffix('.identity')
token = os.environ['TOKEN']
url = args[-1]
if number == 1:
    assert url == os.environ['RELAY'] + '/api/mcp/register'
    assert args[args.index('-X') + 1] == 'POST'
    identity = json.loads(args[args.index('--data') + 1])
    identity_path.write_text(json.dumps(identity))
    body = {**identity, 'token': token, 'mcp_url': 'https://mcp-fixture.invalid/mcp/u/' + token}
elif number == 2:
    assert url == os.environ['RELAY'] + '/api/mcp/u/' + token
    body = json.loads(identity_path.read_text())
elif number == 3:
    assert url.endswith('/api/mcp/u/this-token-does-not-exist-abc123')
    body = {'detail': os.environ['PRIVATE']}
elif number == 4:
    assert url == os.environ['RELAY'] + '/api/mcp/handoffs?token=' + token + '&limit=10'
    body = {'count': 0, 'handoffs': []}
elif number == 5:
    assert url.endswith('/api/mcp/handoffs?token=this-token-does-not-exist')
    body = {'detail': os.environ['PRIVATE']}
else:
    assert url == os.environ['RELAY'] + '/api/mcp/register'
    supplied = json.loads(args[args.index('--data') + 1])
    assert supplied == ({'email': 'not-an-email', 'name': 'Test'} if number == 6 else {'email': '', 'name': ''})
    body = {'detail': os.environ['PRIVATE']}
if mode == 'http-' + str(number):
    status, body = 503, {'detail': os.environ['PRIVATE'], 'token': token}
if mode == 'redirect':
    status, body = 302, {'location': 'https://mcp-fixture.invalid/mcp/u/' + token}
if mode == 'bad-token':
    body['token'] = '../' + os.environ['PRIVATE']
if mode == 'wrong-url':
    body['mcp_url'] += '-wrong'
if mode == 'wrong-identity' and number == 2:
    body['email'] = os.environ['PRIVATE']
if mode == 'nonempty-list' and number == 4:
    body = {'count': 0, 'handoffs': [{'private': os.environ['PRIVATE']}]}
Path(args[args.index('--output') + 1]).write_text(os.environ['PRIVATE'] if mode == 'invalid-json' else json.dumps(body))
print(os.environ['PRIVATE'] if mode == 'invalid-status' else status, end='')
'''

with tempfile.TemporaryDirectory(prefix='mcp-smoke-contract-') as directory:
    root = Path(directory)
    curl = root / 'curl'
    curl.write_text(mock)
    curl.chmod(0o755)
    calls = root / 'calls'
    env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
           'CURL_CALLS': str(calls), 'PRIVATE': secret, 'TOKEN': token}
    env.pop('EGREGORE_MCP_LIVE_SMOKE', None)
    env.pop('RELAY', None)
    cases = 0

    def run(settings, *, expected, count, trace=False):
        global cases
        calls.unlink(missing_ok=True)
        result = subprocess.run(['bash', *(['-x'] if trace else []), smoke],
                                env={**env, **settings}, capture_output=True, text=True, timeout=5)
        assert (result.returncode == 0) == expected, (settings, result.stdout, result.stderr)
        output = result.stdout + result.stderr
        for private in [secret, token, relay, 'mcp-fixture.invalid', 'egregore-production']:
            assert private not in output, (settings, 'private value appeared in output')
        actual = calls.read_text().splitlines() if calls.exists() else []
        assert len(actual) == count, (settings, len(actual), count)
        cases += 1
        return result

    for settings in [{}, {'RELAY': relay}, {'EGREGORE_MCP_LIVE_SMOKE': 'true', 'RELAY': relay}]:
        result = run(settings, expected=True, count=0)
        assert result.stdout.startswith('SKIP:') and len(result.stdout.splitlines()) == 1
    run({'EGREGORE_MCP_LIVE_SMOKE': '1'}, expected=False, count=0)
    for invalid in ['ftp://relay-fixture.invalid', 'https://user:' + secret + '@relay-fixture.invalid',
                    relay + '?token=' + secret, relay + '#token', ' ' + relay]:
        run({'EGREGORE_MCP_LIVE_SMOKE': '1', 'RELAY': invalid}, expected=False, count=0)
    opted = {'EGREGORE_MCP_LIVE_SMOKE': '1', 'RELAY': relay, 'MOCK_MODE': 'success'}
    result = run(opted, expected=True, count=7, trace=True)
    assert result.stdout.endswith('7 passed, 0 failed\n')
    for number in range(1, 8):
        for mode in ['network-', 'http-']:
            run({**opted, 'MOCK_MODE': mode + str(number)}, expected=False, count=number, trace=True)
    for mode, count in [('redirect', 1), ('invalid-json', 1), ('invalid-status', 1),
                        ('bad-token', 1), ('wrong-url', 1), ('wrong-identity', 2), ('nonempty-list', 4)]:
        run({**opted, 'MOCK_MODE': mode}, expected=False, count=count, trace=True)
    run({**opted, 'MOCK_MODE': 'wrong-identity', 'PYTHONOPTIMIZE': '1'}, expected=False, count=2)
    run({**opted, 'RELAY': relay + '?token=' + secret, 'PYTHONOPTIMIZE': '1'}, expected=False, count=0)
    print(f'MCP smoke shell contract: {cases} cases passed; no network used')
PY
