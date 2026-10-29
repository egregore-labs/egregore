#!/usr/bin/env node
import { access, readFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, validateConfig } from './config.mjs';
import { createGateway } from './gateway.mjs';
import { destroyParticipant, exportParticipant } from './lifecycle.mjs';
import { parseArgs } from './lib.mjs';
import { Registry } from './registry.mjs';
import { provisionWorkshop } from './workspaces.mjs';

const packageRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));

async function loadEnv(path) {
  try {
    await access(path, constants.R_OK);
  } catch {
    return;
  }
  const text = await readFile(path, 'utf8');
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match || process.env[match[1]] !== undefined) continue;
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    process.env[match[1]] = value;
  }
}

function usage() {
  return `Usage:\n  node src/cli.mjs gateway --config <path>\n  node src/cli.mjs provision --config <path> [--count 4] [--egregore-source <path>]\n  node src/cli.mjs status --config <path>\n  node src/cli.mjs export <participant-01> --recipient <email-or-handle> --config <path>\n  node src/cli.mjs destroy <participant-01> --confirm <participant-01> --config <path> [--allow-without-export]\n`;
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);
  if (!command || command === '--help' || command === '-h' || args.help) {
    process.stdout.write(usage());
    return;
  }
  await loadEnv(resolve(args.env ?? resolve(packageRoot, '.env')));
  const configPath = resolve(args.config ?? process.env.WORKSHOP_CONFIG ?? resolve(packageRoot, 'config/workshop.json'));
  const config = await loadConfig(configPath);

  if (command === 'gateway') {
    validateConfig(config, { requireProviderKeys: true });
    const { server } = await createGateway(config);
    await new Promise((resolveListen) => server.listen(config.gateway.port, config.gateway.host, resolveListen));
    process.stdout.write(`Workshop gateway listening at ${config.gateway.publicUrl}\n`);
    const close = () => server.close(() => process.exit(0));
    process.once('SIGINT', close);
    process.once('SIGTERM', close);
    return;
  }

  if (command === 'provision') {
    const created = await provisionWorkshop(config, {
      count: args.count,
      egregoreSource: args['egregore-source'],
    });
    for (const participant of created) {
      process.stdout.write(`${participant.id}\t${participant.workspacePath}\texpires ${participant.expiresAt}\n`);
    }
    return;
  }

  if (command === 'status') {
    const registry = await Registry.open(config.gateway.registryPath);
    process.stdout.write(`${JSON.stringify(registry.publicStatus(), null, 2)}\n`);
    return;
  }

  if (command === 'export') {
    const participantId = args._[0];
    if (!participantId) throw new Error('participant id is required');
    const receipt = await exportParticipant(config, participantId, args.recipient);
    process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
    return;
  }

  if (command === 'destroy') {
    const participantId = args._[0];
    if (!participantId) throw new Error('participant id is required');
    const receipt = await destroyParticipant(config, participantId, args.confirm, {
      allowWithoutExport: Boolean(args['allow-without-export']),
    });
    process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
    return;
  }

  throw new Error(`unknown command: ${command}\n${usage()}`);
}

main().catch((error) => {
  process.stderr.write(`Error: ${error.message}\n`);
  process.exitCode = 1;
});
