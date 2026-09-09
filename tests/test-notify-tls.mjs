// Synthetic curl failures only; no external endpoint is contacted.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const script = process.env.NOTIFY_SCRIPT || join(root, 'bin/notify.sh');
const bash = process.env.BASH_BIN || 'bash';

test('curl preserves output and status, adding a hint only for TLS handshake failures', () => {
  const temp = mkdtempSync(join(tmpdir(), 'egregore-notify-tls-'));
  mkdirSync(join(temp, 'bin'));
  writeFileSync(join(temp, 'egregore.json'), JSON.stringify({ mode: 'connected', slug: 'fixture' }));
  writeFileSync(join(temp, 'bin/curl'), '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$MOCK_CURL_LOG"\nprintf "synthetic response"\nif [ "$MOCK_CURL_EXIT" != 0 ]; then echo "synthetic transport failure" >&2; fi\nexit "$MOCK_CURL_EXIT"\n', { mode: 0o755 });
  const env = {
    ...process.env, EGREGORE_NOTIFY_PROJECT_DIR: temp.replaceAll('\\', '/'),
    EGREGORE_NOTIFY_STATE_DIR: join(temp, 'state').replaceAll('\\', '/'),
    EGREGORE_API_URL: 'http://127.0.0.1:1', EGREGORE_API_KEY: 'synthetic-key',
    MOCK_CURL_LOG: join(temp, 'curl.log').replaceAll('\\', '/'),
    MOCK_BIN: join(temp, 'bin').replaceAll('\\', '/'),
  };
  try {
    for (const code of [0, 35, 6, 60]) {
      writeFileSync(join(temp, 'curl.log'), '');
      const result = spawnSync(bash, ['-c', 'mock_dir=$(cd "$MOCK_BIN" && pwd); export PATH="$mock_dir:$PATH"; [ "$(command -v curl)" = "$mock_dir/curl" ] || exit 98; bash "$1" test', 'test', script], {
        env: { ...env, MOCK_CURL_EXIT: String(code) }, encoding: 'utf8', timeout: 20_000,
      });
      assert.equal(result.status, code, result.stderr);
      assert.equal(result.stdout, 'synthetic response');
      if (code === 0) assert.equal(result.stderr, '');
      else assert.match(result.stderr, /synthetic transport failure/);
      assert.equal(result.stderr.includes('TLS handshake failed (curl 35)'), code === 35);
      const calls = readFileSync(join(temp, 'curl.log'), 'utf8').trim().split(/\r?\n/);
      assert.equal(calls.length, 1, 'transport errors must not cause a retry');
      assert.doesNotMatch(calls[0], /--insecure|--ssl-no-revoke|(?:^| )-k(?: |$)/);
      assert.doesNotMatch(calls[0], /--retry/);
    }
  } finally {
    assert.ok(resolve(temp).startsWith(resolve(tmpdir()) + (process.platform === 'win32' ? '\\' : '/')));
    rmSync(temp, { recursive: true, force: true });
  }
});
