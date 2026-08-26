import { once } from 'node:events';
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { appendJsonLine, isoNow, jsonError } from './lib.mjs';
import { Registry } from './registry.mjs';

const RETRYABLE_STATUS = new Set([408, 409, 425, 429]);
const SAFE_RESPONSE_HEADERS = [
  'content-type',
  'openai-organization',
  'openai-processing-ms',
  'openai-version',
  'x-request-id',
];

function bearerToken(request) {
  const header = request.headers.authorization ?? '';
  return header.startsWith('Bearer ') ? header.slice(7).trim() : '';
}

async function readBody(request, byteLimit) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > byteLimit) {
      const error = new Error('request body is too large');
      error.status = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  try {
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('not an object');
    return body;
  } catch {
    const error = new Error('request body must be valid JSON');
    error.status = 400;
    throw error;
  }
}

function sendJson(response, status, payload) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  response.end(typeof payload === 'string' ? payload : JSON.stringify(payload));
}

function retryable(status) {
  return RETRYABLE_STATUS.has(status) || status >= 500;
}

function providerHeaders(provider, requestId) {
  const key = process.env[provider.apiKeyEnv];
  if (!key) throw new Error(`provider ${provider.name} is missing ${provider.apiKeyEnv}`);
  return {
    authorization: `Bearer ${key}`,
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
    'x-workshop-request-id': requestId,
    ...(provider.headers ?? {}),
  };
}

async function callProvider(provider, body, requestId, signal) {
  const timeout = AbortSignal.timeout(provider.timeoutMs ?? 120000);
  const combinedSignal = AbortSignal.any([timeout, signal]);
  return fetch(`${provider.baseUrl.replace(/\/$/, '')}/responses`, {
    method: 'POST',
    headers: providerHeaders(provider, requestId),
    body: JSON.stringify({ ...body, model: provider.model ?? body.model }),
    signal: combinedSignal,
  });
}

async function chooseProvider(providers, body, requestId, signal) {
  const attempts = [];
  for (const provider of providers) {
    const startedAt = Date.now();
    try {
      const upstream = await callProvider(provider, body, requestId, signal);
      attempts.push({ provider: provider.name, status: upstream.status, latencyMs: Date.now() - startedAt });
      if (upstream.ok || !retryable(upstream.status)) return { upstream, provider, attempts };
      await upstream.body?.cancel();
    } catch (error) {
      attempts.push({
        provider: provider.name,
        status: error.name === 'TimeoutError' ? 'timeout' : 'network_error',
        latencyMs: Date.now() - startedAt,
      });
      if (signal.aborted) throw error;
    }
  }
  return { upstream: null, provider: null, attempts };
}

function copyResponseHeaders(upstream, response) {
  for (const name of SAFE_RESPONSE_HEADERS) {
    const value = upstream.headers.get(name);
    if (value) response.setHeader(name, value);
  }
  response.setHeader('cache-control', 'no-store');
}

function parseUsageFromJson(payload) {
  return payload?.usage ?? {};
}

function createSseUsageParser() {
  let buffer = '';
  let usage = {};
  return {
    push(chunk) {
      buffer += chunk.toString('utf8');
      const frames = buffer.split('\n\n');
      buffer = frames.pop() ?? '';
      for (const frame of frames) {
        for (const line of frame.split('\n')) {
          if (!line.startsWith('data:')) continue;
          const data = line.slice(5).trim();
          if (!data || data === '[DONE]') continue;
          try {
            const event = JSON.parse(data);
            if (event.type === 'response.completed') usage = event.response?.usage ?? usage;
          } catch {
            // Ignore partial or provider-specific events; the client still receives them verbatim.
          }
        }
      }
      if (buffer.length > 4 * 1024 * 1024) buffer = buffer.slice(-1024 * 1024);
    },
    value() {
      return usage;
    },
  };
}

async function relay(upstream, response) {
  copyResponseHeaders(upstream, response);
  response.statusCode = upstream.status;
  const contentType = upstream.headers.get('content-type') ?? 'application/json';

  if (!contentType.includes('text/event-stream')) {
    const buffer = Buffer.from(await upstream.arrayBuffer());
    response.end(buffer);
    try {
      return parseUsageFromJson(JSON.parse(buffer.toString('utf8')));
    } catch {
      return {};
    }
  }

  const parser = createSseUsageParser();
  for await (const chunk of upstream.body) {
    const bytes = Buffer.from(chunk);
    parser.push(bytes);
    if (!response.write(bytes)) {
      await Promise.race([
        once(response, 'drain'),
        once(response, 'close').then(() => {
          const error = new Error('client closed the stream');
          error.name = 'AbortError';
          throw error;
        }),
      ]);
    }
  }
  response.end();
  return parser.value();
}

export async function createGateway(config, { registry: suppliedRegistry } = {}) {
  const registry = suppliedRegistry ?? await Registry.open(config.gateway.registryPath);
  const auditPath = config.gateway.auditLogPath;
  const server = createServer(async (request, response) => {
    if (request.method === 'GET' && request.url === '/healthz') {
      return sendJson(response, 200, { ok: true, providers: config.providers.map(({ name }) => name) });
    }
    if (request.method !== 'POST' || request.url !== '/v1/responses') {
      return sendJson(response, 404, jsonError('not found', 'not_found'));
    }

    const requestId = randomUUID();
    const startedAt = Date.now();
    let participant;
    let estimatedInput = 0;
    let outputReservation = 0;
    const abortController = new AbortController();
    request.once('aborted', () => abortController.abort());
    response.once('close', () => {
      if (!response.writableEnded) abortController.abort();
    });

    try {
      const body = await readBody(request, config.gateway.requestBodyBytes ?? 2 * 1024 * 1024);
      const token = bearerToken(request);
      const requestedMax = Number.isInteger(body.max_output_tokens) && body.max_output_tokens > 0
        ? body.max_output_tokens
        : config.workshop.maxOutputTokensPerRequest;
      const cappedRequestedMax = Math.min(requestedMax, config.workshop.maxOutputTokensPerRequest);
      const admission = await registry.begin(token, body, cappedRequestedMax);
      if (admission.error) {
        await appendJsonLine(auditPath, {
          at: isoNow(), requestId, outcome: admission.error, status: admission.status,
        });
        return sendJson(response, admission.status, jsonError('workshop access denied', admission.error));
      }
      participant = admission.participant;
      estimatedInput = admission.estimatedInput;
      outputReservation = admission.outputReservation;

      const safeBody = {
        ...body,
        background: false,
        metadata: {},
        model: config.workshop.model,
        prompt_cache_key: participant.safetyId,
        store: false,
        safety_identifier: participant.safetyId,
        max_output_tokens: outputReservation,
      };
      delete safeBody.user;

      const { upstream, provider, attempts } = await chooseProvider(
        config.providers,
        safeBody,
        requestId,
        abortController.signal,
      );
      if (!upstream) {
        await registry.finish(participant.id, { estimatedInput, outputReservation });
        participant = null;
        await appendJsonLine(auditPath, {
          at: isoNow(), requestId, participantId: admission.participant.id,
          outcome: 'providers_unavailable', attempts, latencyMs: Date.now() - startedAt,
        });
        return sendJson(response, 503, jsonError('inference providers are temporarily unavailable', 'providers_unavailable'));
      }

      const usage = await relay(upstream, response);
      const completedParticipantId = participant.id;
      await registry.finish(participant.id, {
        ...usage,
        estimatedInput,
        outputReservation,
        chargeReservation: upstream.ok,
      });
      participant = null;
      await appendJsonLine(auditPath, {
        at: isoNow(), requestId, participantId: completedParticipantId, provider: provider.name,
        status: upstream.status, attempts, inputTokens: usage.input_tokens ?? estimatedInput,
        outputTokens: usage.output_tokens ?? (upstream.ok ? outputReservation : 0),
        usageEstimated: !Number.isFinite(usage.output_tokens), latencyMs: Date.now() - startedAt,
      });
    } catch (error) {
      if (participant) await registry.finish(participant.id, {
        estimatedInput,
        outputReservation,
        chargeReservation: true,
      }).catch(() => {});
      await appendJsonLine(auditPath, {
        at: isoNow(), requestId, participantId: participant?.id ?? null,
        outcome: error.name === 'AbortError' ? 'client_aborted' : 'gateway_error',
        status: error.status ?? 500, latencyMs: Date.now() - startedAt,
      }).catch(() => {});
      if (!response.headersSent) {
        sendJson(response, error.status ?? 500, jsonError(
          error.status ? error.message : 'gateway request failed',
          error.status ? 'bad_request' : 'gateway_error',
        ));
      } else if (!response.writableEnded) {
        response.destroy();
      }
    }
  });

  return { server, registry };
}
