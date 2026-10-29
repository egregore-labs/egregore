import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { access, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import test from 'node:test';
import { promisify } from 'node:util';
import { destroyParticipant, exportParticipant } from '../src/lifecycle.mjs';
import { Registry } from '../src/registry.mjs';
import { provisionWorkshop } from '../src/workspaces.mjs';

const execFileAsync = promisify(execFile);

async function makeFramework(root) {
  await mkdir(resolve(root, 'bin'), { recursive: true });
  await mkdir(resolve(root, 'skills'), { recursive: true });
  await mkdir(resolve(root, '.codex/skills'), { recursive: true });
  await mkdir(resolve(root, '.claude/skills'), { recursive: true });
  await writeFile(resolve(root, 'bin/agent.sh'), '#!/usr/bin/env bash\n');
  await writeFile(resolve(root, 'skills/README.md'), '# skills\n');
  await writeFile(resolve(root, '.codex/skills/README.md'), '# codex skills\n');
  await writeFile(resolve(root, '.claude/skills/README.md'), '# source skills\n');
  await writeFile(resolve(root, 'LICENSE'), 'test\n');
}

test('provisions isolated workspaces, exports notes plus a private profile packet, then revokes and deletes', async () => {
  const directory = await mkdtemp(resolve(tmpdir(), 'egregore-workshop-lifecycle-'));
  const framework = resolve(directory, 'framework');
  await makeFramework(framework);
  const config = {
    gateway: {
      publicUrl: 'http://127.0.0.1:8787/v1',
      registryPath: resolve(directory, 'runtime/registry.json'),
    },
    workshop: {
      runtimeRoot: resolve(directory, 'runtime/participants'),
      exportRoot: resolve(directory, 'exports'),
      receiptsRoot: resolve(directory, 'receipts'),
      participantCount: 1,
      tokenLifetimeHours: 24,
      model: 'test-model',
      quotas: { requests: 20, inputTokens: 20000, outputTokens: 4000, concurrency: 1 },
    },
  };

  const [participant] = await provisionWorkshop(config, { count: 1, egregoreSource: framework });
  assert.equal(participant.id, 'participant-01');
  const token = (await readFile(resolve(participant.workspacePath, '.workshop/access.token'), 'utf8')).trim();
  const registryBefore = await readFile(config.gateway.registryPath, 'utf8');
  assert.doesNotMatch(registryBefore, new RegExp(token));
  const codexConfig = await readFile(resolve(participant.workspacePath, '.workshop/codex-home/config.toml'), 'utf8');
  assert.doesNotMatch(codexConfig, /provider-secret/);
  assert.match(codexConfig, /command = "node"/);
  assert.match(codexConfig, /\.\.\/.workshop\/read-token\.mjs/);
  const tokenResult = await execFileAsync(process.execPath, ['../.workshop/read-token.mjs'], {
    cwd: resolve(participant.workspacePath, 'egregore'),
  });
  assert.equal(tokenResult.stdout, token);
  const launcher = await readFile(resolve(participant.workspacePath, 'start-workshop.sh'), 'utf8');
  assert.doesNotMatch(launcher, new RegExp(directory.replaceAll('/', '\\/')));
  assert.match(launcher, /BASH_SOURCE/);

  const privateNote = 'My private workshop thought must not enter the emissary relay.';
  await writeFile(resolve(participant.vaultPath, 'Private Note.md'), privateNote);
  const receipt = await exportParticipant(config, participant.id, 'person@example.com');
  assert.equal(receipt.notesSentToRelay, false);
  assert.equal(await readFile(resolve(receipt.exportPath, 'vault/Private Note.md'), 'utf8'), privateNote);
  const emissary = JSON.parse(await readFile(resolve(receipt.exportPath, 'emissary-answers.json'), 'utf8'));
  assert.equal(emissary.distribution, 'person');
  assert.deepEqual(emissary.recipients, ['person@example.com']);
  assert.doesNotMatch(JSON.stringify(emissary), /private workshop thought/);
  assert.match(emissary.executable_spec.action, /Portable configuration profile/);

  const deletion = await destroyParticipant(config, participant.id, participant.id);
  assert.equal(deletion.tokenRevoked, true);
  assert.equal(deletion.status, 'deleted');
  await assert.rejects(access(participant.workspacePath));
  const registry = await Registry.open(config.gateway.registryPath);
  assert.equal(registry.data.participants[0].status, 'revoked');
});
