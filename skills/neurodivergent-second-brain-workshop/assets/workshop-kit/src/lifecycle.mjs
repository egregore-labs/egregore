import { createHash } from 'node:crypto';
import { cp, lstat, mkdir, readFile, readdir, realpath, rm } from 'node:fs/promises';
import { basename, relative, resolve, sep } from 'node:path';
import { buildEmissaryAnswers } from './emissary.mjs';
import { isoNow, readJson, writeJsonAtomic } from './lib.mjs';
import { Registry } from './registry.mjs';

const REQUIRED_VAULT_FILES = [
  'Home.md',
  'Inbox.md',
  'Now.md',
  'Re-entry.md',
  'System/Configuration Profile.md',
  '.second-brain/configuration-profile.json',
];

async function exists(path) {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

async function hashFiles(root, current = root) {
  const results = [];
  const entries = await readdir(current, { withFileTypes: true });
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const path = resolve(current, entry.name);
    const name = relative(root, path).split(sep).join('/');
    if (entry.isSymbolicLink()) throw new Error(`vault export refuses symbolic link: ${name}`);
    if (entry.isDirectory()) results.push(...await hashFiles(root, path));
    if (entry.isFile()) {
      const contents = await readFile(path);
      results.push({ path: name, bytes: contents.length, sha256: createHash('sha256').update(contents).digest('hex') });
    }
  }
  return results;
}

export async function verifyVault(vaultPath) {
  const missing = [];
  for (const file of REQUIRED_VAULT_FILES) {
    if (!await exists(resolve(vaultPath, file))) missing.push(file);
  }
  if (missing.length) throw new Error(`vault is missing required files: ${missing.join(', ')}`);
  const profile = await readJson(resolve(vaultPath, '.second-brain/configuration-profile.json'));
  if (profile.schemaVersion !== 1) throw new Error('unsupported configuration profile schema');
  return { profile, files: await hashFiles(vaultPath) };
}

export async function exportParticipant(config, participantId, recipient) {
  if (!recipient) throw new Error('--recipient is required for the private emissary draft');
  if (!/^participant-\d{2}$/.test(participantId)) throw new Error('invalid participant id');
  const workspacePath = resolve(config.workshop.runtimeRoot, participantId);
  if (basename(workspacePath) !== participantId) throw new Error('invalid participant id');
  const sourceVault = resolve(workspacePath, 'vault');
  const sourceVerification = await verifyVault(sourceVault);
  const exportedAt = isoNow();
  const exportPath = resolve(config.workshop.exportRoot, `${participantId}-${exportedAt.replaceAll(':', '-')}`);
  const exportVault = resolve(exportPath, 'vault');

  await mkdir(config.workshop.exportRoot, { recursive: true });
  await mkdir(exportPath, { recursive: false });
  await cp(sourceVault, exportVault, { recursive: true, force: false, errorOnExist: true });
  const exportedVerification = await verifyVault(exportVault);
  if (JSON.stringify(sourceVerification.files) !== JSON.stringify(exportedVerification.files)) {
    throw new Error('export verification failed: source and exported checksums differ');
  }

  const emissaryAnswers = buildEmissaryAnswers(sourceVerification.profile, recipient);
  await writeJsonAtomic(resolve(exportPath, 'emissary-answers.json'), emissaryAnswers, 0o600);
  const receipt = {
    version: 1,
    participantId,
    exportedAt,
    exportPath,
    files: exportedVerification.files,
    configurationProfileIncluded: true,
    emissaryDraftIncluded: true,
    notesSentToRelay: false,
  };
  await writeJsonAtomic(resolve(exportPath, 'export-receipt.json'), receipt, 0o600);
  await writeJsonAtomic(resolve(config.workshop.receiptsRoot, `${participantId}-export.json`), receipt, 0o600);
  return receipt;
}

async function assertContained(rootPath, targetPath) {
  const root = await realpath(rootPath);
  const target = await realpath(targetPath);
  const relation = relative(root, target);
  if (!relation || relation.startsWith('..') || relation.includes(`${sep}..${sep}`)) {
    throw new Error('refusing deletion outside the configured participant runtime root');
  }
  return { root, target };
}

export async function destroyParticipant(config, participantId, confirmation, { allowWithoutExport = false } = {}) {
  if (confirmation !== participantId) throw new Error(`destruction requires --confirm ${participantId}`);
  const targetPath = resolve(config.workshop.runtimeRoot, participantId);
  if (basename(targetPath) !== participantId || !/^participant-\d{2}$/.test(participantId)) {
    throw new Error('invalid participant id');
  }
  await assertContained(config.workshop.runtimeRoot, targetPath);
  const exportReceiptPath = resolve(config.workshop.receiptsRoot, `${participantId}-export.json`);
  if (!allowWithoutExport && !await exists(exportReceiptPath)) {
    throw new Error('no verified export receipt; export first or explicitly pass --allow-without-export');
  }

  const registry = await Registry.open(config.gateway.registryPath);
  await registry.revoke(participantId);
  const deletionStartedAt = isoNow();
  const deletionReceiptPath = resolve(config.workshop.receiptsRoot, `${participantId}-deletion.json`);
  await writeJsonAtomic(deletionReceiptPath, {
    version: 1,
    participantId,
    deletionStartedAt,
    status: 'deletion_started',
    deletedPath: targetPath,
    tokenRevoked: true,
    exportReceipt: await exists(exportReceiptPath) ? exportReceiptPath : null,
  }, 0o600);
  await rm(targetPath, { recursive: true, force: false });
  const receipt = {
    version: 1,
    participantId,
    deletionStartedAt,
    deletedAt: isoNow(),
    status: 'deleted',
    deletedPath: targetPath,
    tokenRevoked: true,
    exportReceipt: await exists(exportReceiptPath) ? exportReceiptPath : null,
    recoverableFromWorkshopRuntime: false,
  };
  await writeJsonAtomic(deletionReceiptPath, receipt, 0o600);
  return receipt;
}
