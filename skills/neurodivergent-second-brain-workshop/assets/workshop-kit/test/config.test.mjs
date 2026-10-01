import assert from 'node:assert/strict';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { loadConfig, validateConfig } from '../src/config.mjs';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

test('the committed example is valid and resolves runtime paths inside the generated workshop', async () => {
  const config = await loadConfig(resolve(packageRoot, 'config/workshop.example.json'));
  assert.equal(config.gateway.publicUrl, 'https://workshop-gateway.example/v1');
  assert.equal(config.workshop.runtimeRoot, resolve(packageRoot, 'runtime/participants'));
});

test('rejects plaintext remote gateways and credentials embedded in provider headers', async () => {
  const config = await loadConfig(resolve(packageRoot, 'config/workshop.example.json'));
  config.gateway.publicUrl = 'http://workshop-gateway.example/v1';
  assert.throws(() => validateConfig(config), /must use HTTPS/);

  config.gateway.publicUrl = 'http://127.0.0.1:8787/v1';
  config.providers[0].headers = { Authorization: 'Bearer do-not-store-this-here' };
  assert.throws(() => validateConfig(config), /must use apiKeyEnv/);
});
