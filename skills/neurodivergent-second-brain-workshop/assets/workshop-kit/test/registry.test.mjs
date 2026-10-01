import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import test from 'node:test';
import { sha256 } from '../src/lib.mjs';
import { Registry } from '../src/registry.mjs';

test('reserves output quota across concurrent requests', async () => {
  const directory = await mkdtemp(resolve(tmpdir(), 'egregore-workshop-registry-'));
  const registry = await Registry.open(resolve(directory, 'registry.json'));
  const token = 'quota-token';
  await registry.transact((data) => data.participants.push({
    id: 'participant-01', tokenHash: sha256(token), safetyId: 'ws_test', status: 'active',
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
    quotas: { requests: 10, inputTokens: 10000, outputTokens: 150, concurrency: 2 },
    usage: { requests: 0, inputTokens: 0, outputTokens: 0, outputReserved: 0, active: 0 },
  }));

  const first = await registry.begin(token, { input: 'one' }, 100);
  const second = await registry.begin(token, { input: 'two' }, 100);
  assert.equal(first.outputReservation, 100);
  assert.equal(second.outputReservation, 50);
  assert.equal(registry.data.participants[0].usage.outputReserved, 150);

  await registry.finish('participant-01', {
    outputReservation: first.outputReservation,
    output_tokens: 20,
    estimatedInput: first.estimatedInput,
  });
  await registry.finish('participant-01', {
    outputReservation: second.outputReservation,
    chargeReservation: true,
    estimatedInput: second.estimatedInput,
  });
  assert.equal(registry.data.participants[0].usage.outputReserved, 0);
  assert.equal(registry.data.participants[0].usage.outputTokens, 70);
});

test('separate gateway and admin processes observe provisioning and revocation through the registry file', async () => {
  const directory = await mkdtemp(resolve(tmpdir(), 'egregore-workshop-registry-sync-'));
  const path = resolve(directory, 'registry.json');
  const gatewayRegistry = await Registry.open(path);
  const adminRegistry = await Registry.open(path);
  const token = 'late-provisioned-token';

  await adminRegistry.transact((data) => data.participants.push({
    id: 'participant-01', tokenHash: sha256(token), safetyId: 'ws_test', status: 'active',
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
    quotas: { requests: 10, inputTokens: 10000, outputTokens: 100, concurrency: 1 },
    usage: { requests: 0, inputTokens: 0, outputTokens: 0, outputReserved: 0, active: 0 },
  }));

  const admitted = await gatewayRegistry.begin(token, { input: 'hello' }, 10);
  assert.equal(admitted.participant.id, 'participant-01');
  await gatewayRegistry.finish('participant-01', {
    outputReservation: admitted.outputReservation,
    output_tokens: 1,
    estimatedInput: admitted.estimatedInput,
  });

  await adminRegistry.revoke('participant-01');
  const denied = await gatewayRegistry.begin(token, { input: 'again' }, 10);
  assert.deepEqual(denied, { error: 'revoked_token', status: 401 });
});
