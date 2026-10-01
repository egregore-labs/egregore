import { mkdir, readFile, rm, stat } from 'node:fs/promises';
import { dirname } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { estimateInputTokens, isoNow, secureEqual, sha256, writeJsonAtomic } from './lib.mjs';

export class Registry {
  constructor(path, data) {
    this.path = path;
    this.data = data;
    this.queue = Promise.resolve();
  }

  static async open(path) {
    let data;
    try {
      data = JSON.parse(await readFile(path, 'utf8'));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      data = { version: 1, safetySalt: sha256(`${Date.now()}:${path}`), participants: [] };
    }
    const registry = new Registry(path, data);
    await registry.transact(() => {});
    return registry;
  }

  async transact(callback) {
    const operation = this.queue.then(async () => {
      const lockPath = `${this.path}.lock`;
      await mkdir(dirname(this.path), { recursive: true });
      let acquired = false;
      for (let attempt = 0; attempt < 500; attempt += 1) {
        try {
          await mkdir(lockPath);
          acquired = true;
          break;
        } catch (error) {
          if (error.code !== 'EEXIST') throw error;
          try {
            const lock = await stat(lockPath);
            if (Date.now() - lock.mtimeMs > 30_000) {
              await rm(lockPath, { recursive: true, force: true });
              continue;
            }
          } catch (statError) {
            if (statError.code !== 'ENOENT') throw statError;
          }
          await delay(10);
        }
      }
      if (!acquired) throw new Error(`timed out waiting for registry lock: ${lockPath}`);
      try {
        try {
          this.data = JSON.parse(await readFile(this.path, 'utf8'));
        } catch (error) {
          if (error.code !== 'ENOENT') throw error;
        }
        const result = await callback(this.data);
        await writeJsonAtomic(this.path, this.data);
        return result;
      } finally {
        await rm(lockPath, { recursive: true, force: true });
      }
    });
    this.queue = operation.catch(() => {});
    return operation;
  }

  async begin(token, body, requestedOutputTokens) {
    return this.transact((data) => {
      const digest = sha256(token);
      const participant = data.participants.find((item) => secureEqual(item.tokenHash, digest));
      if (!participant) return { error: 'invalid_token', status: 401 };
      if (participant.status !== 'active') return { error: 'revoked_token', status: 401 };
      if (Date.parse(participant.expiresAt) <= Date.now()) return { error: 'expired_token', status: 401 };

      const estimatedInput = estimateInputTokens(body);
      const { quotas, usage } = participant;
      usage.outputReserved ??= 0;
      if (usage.active >= quotas.concurrency) return { error: 'concurrency_quota', status: 429 };
      if (usage.requests + 1 > quotas.requests) return { error: 'request_quota', status: 429 };
      if (usage.inputTokens + estimatedInput > quotas.inputTokens) return { error: 'input_token_quota', status: 429 };
      const outputRemaining = quotas.outputTokens - usage.outputTokens - usage.outputReserved;
      if (outputRemaining < 1) return { error: 'output_token_quota', status: 429 };
      const outputReservation = Math.min(requestedOutputTokens, outputRemaining);

      usage.requests += 1;
      usage.inputTokens += estimatedInput;
      usage.outputReserved += outputReservation;
      usage.active += 1;
      usage.lastRequestAt = isoNow();
      return { participant, estimatedInput, outputReservation };
    });
  }

  async finish(participantId, usage = {}) {
    return this.transact((data) => {
      const participant = data.participants.find((item) => item.id === participantId);
      if (!participant) return;
      participant.usage.active = Math.max(0, participant.usage.active - 1);
      participant.usage.outputReserved = Math.max(
        0,
        (participant.usage.outputReserved ?? 0) - (usage.outputReservation ?? 0),
      );
      if (Number.isFinite(usage.input_tokens)) {
        const reserved = usage.estimatedInput ?? 0;
        participant.usage.inputTokens += usage.input_tokens - reserved;
      }
      if (Number.isFinite(usage.output_tokens)) participant.usage.outputTokens += usage.output_tokens;
      else if (usage.chargeReservation) participant.usage.outputTokens += usage.outputReservation ?? 0;
      participant.usage.lastCompletedAt = isoNow();
    });
  }

  async revoke(participantId) {
    return this.transact((data) => {
      const participant = data.participants.find((item) => item.id === participantId);
      if (!participant) throw new Error(`unknown participant: ${participantId}`);
      participant.status = 'revoked';
      participant.revokedAt = isoNow();
    });
  }

  publicStatus() {
    return this.data.participants.map(({ tokenHash, safetyId, ...participant }) => participant);
  }
}
