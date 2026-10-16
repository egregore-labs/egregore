import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import test from 'node:test';
import { createGateway } from '../src/gateway.mjs';
import { sha256, stableSafetyId } from '../src/lib.mjs';
import { Registry } from '../src/registry.mjs';

async function listen(server) {
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  const { port } = server.address();
  return `http://127.0.0.1:${port}`;
}

async function close(server) {
  await new Promise((done) => server.close(done));
}

async function fixture(t, handlers, quotas = {}) {
  const directory = await mkdtemp(resolve(tmpdir(), 'egregore-workshop-gateway-'));
  const calls = [];
  const providerServers = [];
  const providers = [];
  for (const [index, handler] of handlers.entries()) {
    const server = createServer(async (request, response) => {
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const call = {
        headers: request.headers,
        body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
        provider: index,
      };
      calls.push(call);
      await handler(request, response, call);
    });
    const url = await listen(server);
    providerServers.push(server);
    const env = `TEST_PROVIDER_${index}_KEY`;
    process.env[env] = `provider-secret-${index}`;
    providers.push({ name: `provider-${index}`, baseUrl: url, apiKeyEnv: env, timeoutMs: 2000 });
  }

  const config = {
    gateway: {
      host: '127.0.0.1', port: 0, publicUrl: '',
      registryPath: resolve(directory, 'registry.json'),
      auditLogPath: resolve(directory, 'audit.jsonl'),
      requestBodyBytes: 100000,
    },
    workshop: {
      model: 'test-model', maxOutputTokensPerRequest: 100,
    },
    providers,
  };
  const registry = await Registry.open(config.gateway.registryPath);
  const token = 'participant-test-token';
  await registry.transact((data) => data.participants.push({
    id: 'participant-01', tokenHash: sha256(token), safetyId: stableSafetyId('participant-01', data.safetySalt),
    status: 'active', expiresAt: new Date(Date.now() + 60_000).toISOString(),
    quotas: { requests: 10, inputTokens: 10000, outputTokens: 1000, concurrency: 2, ...quotas },
    usage: { requests: 0, inputTokens: 0, outputTokens: 0, active: 0 },
  }));
  const { server: gateway } = await createGateway(config, { registry });
  const gatewayUrl = await listen(gateway);
  t.after(async () => {
    await close(gateway);
    for (const server of providerServers) await close(server);
  });
  return { directory, calls, config, registry, token, gatewayUrl };
}

test('authenticates a workshop token, overrides cost controls, and keeps secrets and prompts out of logs', async (t) => {
  const fx = await fixture(t, [async (_request, response) => {
    response.writeHead(200, { 'content-type': 'application/json', 'x-request-id': 'upstream-1' });
    response.end(JSON.stringify({ id: 'resp_test', usage: { input_tokens: 12, output_tokens: 7, total_tokens: 19 } }));
  }]);

  const denied = await fetch(`${fx.gatewayUrl}/v1/responses`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ input: 'private thought' }),
  });
  assert.equal(denied.status, 401);

  const accepted = await fetch(`${fx.gatewayUrl}/v1/responses`, {
    method: 'POST',
    headers: { authorization: `Bearer ${fx.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      model: 'expensive-model', input: 'private thought', store: true, background: true,
      metadata: { email: 'private@example.com' }, user: 'private@example.com',
      prompt_cache_key: 'private@example.com', max_output_tokens: 9000,
    }),
  });
  assert.equal(accepted.status, 200);
  assert.equal((await accepted.json()).id, 'resp_test');
  assert.equal(fx.calls[0].body.model, 'test-model');
  assert.equal(fx.calls[0].body.store, false);
  assert.equal(fx.calls[0].body.background, false);
  assert.deepEqual(fx.calls[0].body.metadata, {});
  assert.equal(fx.calls[0].body.user, undefined);
  assert.equal(fx.calls[0].body.prompt_cache_key, fx.calls[0].body.safety_identifier);
  assert.equal(fx.calls[0].body.max_output_tokens, 100);
  assert.match(fx.calls[0].body.safety_identifier, /^ws_[a-f0-9]{48}$/);
  assert.equal(fx.calls[0].headers.authorization, 'Bearer provider-secret-0');

  await fx.registry.transact(() => {});
  const audit = await readFile(fx.config.gateway.auditLogPath, 'utf8');
  assert.doesNotMatch(audit, /private thought/);
  assert.doesNotMatch(audit, /participant-test-token/);
  assert.doesNotMatch(audit, /provider-secret/);
  assert.equal(fx.registry.data.participants[0].usage.outputTokens, 7);
  assert.equal(fx.registry.data.participants[0].usage.active, 0);
});

test('fails over only after a retryable provider failure', async (t) => {
  const fx = await fixture(t, [
    async (_request, response) => {
      response.writeHead(503, { 'content-type': 'application/json' });
      response.end('{"error":{"message":"down"}}');
    },
    async (_request, response) => {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ id: 'secondary', usage: { input_tokens: 3, output_tokens: 2 } }));
    },
  ]);
  const response = await fetch(`${fx.gatewayUrl}/v1/responses`, {
    method: 'POST', headers: { authorization: `Bearer ${fx.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ input: 'hello' }),
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).id, 'secondary');
  assert.deepEqual(fx.calls.map((call) => call.provider), [0, 1]);
});

test('passes SSE through and accounts usage from response.completed', async (t) => {
  const fx = await fixture(t, [async (_request, response) => {
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.write('event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"hello"}\n\n');
    response.end('event: response.completed\ndata: {"type":"response.completed","response":{"usage":{"input_tokens":9,"output_tokens":4,"total_tokens":13}}}\n\n');
  }]);
  const response = await fetch(`${fx.gatewayUrl}/v1/responses`, {
    method: 'POST', headers: { authorization: `Bearer ${fx.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ input: 'stream', stream: true }),
  });
  assert.equal(response.status, 200);
  assert.match(await response.text(), /response.completed/);
  await fx.registry.transact(() => {});
  assert.equal(fx.registry.data.participants[0].usage.outputTokens, 4);
  assert.equal(fx.registry.data.participants[0].usage.active, 0);
});

test('enforces request quota before reaching a provider', async (t) => {
  const fx = await fixture(t, [async (_request, response) => {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ usage: { input_tokens: 1, output_tokens: 1 } }));
  }], { requests: 1 });
  const makeRequest = () => fetch(`${fx.gatewayUrl}/v1/responses`, {
    method: 'POST', headers: { authorization: `Bearer ${fx.token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ input: 'quota' }),
  });
  assert.equal((await makeRequest()).status, 200);
  assert.equal((await makeRequest()).status, 429);
  assert.equal(fx.calls.length, 1);
});
