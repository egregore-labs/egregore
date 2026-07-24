import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, resolve } from 'node:path';

export function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function stableSafetyId(participantId, salt) {
  return `ws_${sha256(`${salt}:${participantId}`).slice(0, 48)}`;
}

export function newToken() {
  return `egw_${randomBytes(32).toString('base64url')}`;
}

export function secureEqual(left, right) {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function jsonError(message, code = 'workshop_error') {
  return JSON.stringify({ error: { message, type: 'workshop_gateway_error', code } });
}

export function estimateInputTokens(body) {
  const clone = { ...body };
  delete clone.safety_identifier;
  return Math.ceil(JSON.stringify(clone).length / 4);
}

export function resolveFrom(baseDir, path) {
  return isAbsolute(path) ? path : resolve(baseDir, path);
}

export async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

export async function writeJsonAtomic(path, value, mode = 0o600) {
  await mkdir(dirname(path), { recursive: true });
  const temp = `${path}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  await writeFile(temp, `${JSON.stringify(value, null, 2)}\n`, { mode });
  await rename(temp, path);
}

export async function appendJsonLine(path, value) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value)}\n`, { flag: 'a', mode: 0o600 });
}

export function isoNow() {
  return new Date().toISOString();
}

export function parseArgs(argv) {
  const result = { _: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if (!item.startsWith('--')) {
      result._.push(item);
      continue;
    }
    const key = item.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith('--')) {
      result[key] = true;
    } else {
      result[key] = next;
      index += 1;
    }
  }
  return result;
}

export function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`${label} is required`);
  }
  return value;
}
