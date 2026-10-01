import { homedir } from 'node:os';
import { dirname, parse, resolve } from 'node:path';
import { readJson, resolveFrom } from './lib.mjs';

export async function loadConfig(configPath) {
  const absolutePath = resolve(configPath);
  const baseDir = dirname(absolutePath);
  const config = await readJson(absolutePath);

  for (const key of ['registryPath', 'auditLogPath']) {
    config.gateway[key] = resolveFrom(baseDir, config.gateway[key]);
  }
  for (const key of ['runtimeRoot', 'exportRoot', 'receiptsRoot']) {
    config.workshop[key] = resolveFrom(baseDir, config.workshop[key]);
  }
  config.__configPath = absolutePath;
  config.__baseDir = baseDir;
  validateConfig(config);
  return config;
}

export function validateConfig(config, { requireProviderKeys = false } = {}) {
  if (!config.gateway?.publicUrl || !config.gateway?.registryPath) {
    throw new Error('gateway.publicUrl and gateway.registryPath are required');
  }
  if (!config.workshop?.runtimeRoot || !config.workshop?.model) {
    throw new Error('workshop.runtimeRoot and workshop.model are required');
  }
  if (!Number.isInteger(config.workshop.maxOutputTokensPerRequest) || config.workshop.maxOutputTokensPerRequest < 1) {
    throw new Error('workshop.maxOutputTokensPerRequest must be a positive integer');
  }
  if (!Number.isFinite(config.workshop.tokenLifetimeHours) || config.workshop.tokenLifetimeHours <= 0) {
    throw new Error('workshop.tokenLifetimeHours must be a positive number');
  }
  const runtimeRoot = resolve(config.workshop.runtimeRoot);
  if ([parse(runtimeRoot).root, resolve(homedir())].includes(runtimeRoot)) {
    throw new Error('workshop.runtimeRoot cannot be a filesystem root or home directory');
  }
  if (new Set([
    resolve(config.workshop.runtimeRoot),
    resolve(config.workshop.exportRoot),
    resolve(config.workshop.receiptsRoot),
  ]).size !== 3) {
    throw new Error('runtimeRoot, exportRoot, and receiptsRoot must be different directories');
  }
  const quotas = config.workshop.quotas ?? {};
  for (const key of ['requests', 'inputTokens', 'outputTokens', 'concurrency']) {
    if (!Number.isInteger(quotas[key]) || quotas[key] < 1) throw new Error(`workshop.quotas.${key} must be a positive integer`);
  }
  let gatewayUrl;
  try {
    gatewayUrl = new URL(config.gateway.publicUrl);
  } catch {
    throw new Error('gateway.publicUrl must be a valid URL');
  }
  if (!gatewayUrl.pathname.replace(/\/$/, '').endsWith('/v1')) {
    throw new Error('gateway.publicUrl must end with /v1');
  }
  const loopbackHosts = new Set(['127.0.0.1', 'localhost', '::1']);
  if (gatewayUrl.protocol !== 'https:' && !loopbackHosts.has(gatewayUrl.hostname)) {
    throw new Error('gateway.publicUrl must use HTTPS unless it is loopback-only');
  }
  if (!Array.isArray(config.providers) || config.providers.length < 1) {
    throw new Error('at least one provider is required');
  }
  for (const provider of config.providers) {
    if (!provider.name || !provider.baseUrl || !provider.apiKeyEnv) {
      throw new Error('each provider needs name, baseUrl, and apiKeyEnv');
    }
    let providerUrl;
    try {
      providerUrl = new URL(provider.baseUrl);
    } catch {
      throw new Error(`provider ${provider.name} baseUrl must be a valid URL`);
    }
    if (providerUrl.protocol !== 'https:' && !loopbackHosts.has(providerUrl.hostname)) {
      throw new Error(`provider ${provider.name} baseUrl must use HTTPS unless it is loopback-only`);
    }
    if (Object.keys(provider.headers ?? {}).some((name) => name.toLowerCase() === 'authorization')) {
      throw new Error(`provider ${provider.name} must use apiKeyEnv instead of an authorization header in config`);
    }
    if (requireProviderKeys && !process.env[provider.apiKeyEnv]) {
      throw new Error(`missing provider secret in ${provider.apiKeyEnv}`);
    }
  }
  if (new Set(config.providers.map(({ name }) => name)).size !== config.providers.length) {
    throw new Error('provider names must be unique');
  }
}
