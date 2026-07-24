#!/usr/bin/env node
import { chmod, copyFile, cp, mkdir, readdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, parse, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--output') {
      result.output = argv[index + 1];
      index += 1;
      continue;
    }
    if (argv[index] === '--help' || argv[index] === '-h') result.help = true;
  }
  return result;
}

async function directoryIsEmpty(path) {
  try {
    return (await readdir(path)).length === 0;
  } catch (error) {
    if (error.code === 'ENOENT') return true;
    throw error;
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write('Usage: node scaffold.mjs [--output <directory>]\n');
    return;
  }

  const output = resolve(args.output ?? 'workshops/neurodivergent-second-brain');
  if ([parse(output).root, resolve(homedir()), resolve(process.cwd())].includes(output)) {
    throw new Error('refusing to scaffold into a filesystem root, home directory, or current directory');
  }
  if (!await directoryIsEmpty(output)) throw new Error(`destination is not empty: ${output}`);

  const skillRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const template = resolve(skillRoot, 'assets/workshop-kit');
  await mkdir(output, { recursive: true });
  await cp(template, output, { recursive: true, force: false, errorOnExist: true });
  await copyFile(resolve(output, 'config/workshop.example.json'), resolve(output, 'config/workshop.json'));
  await copyFile(resolve(output, '.env.example'), resolve(output, '.env'));
  await chmod(resolve(output, '.env'), 0o600).catch(() => {});

  process.stdout.write(`Workshop scaffolded at ${output}\n`);
  process.stdout.write('Next: edit config/workshop.json and .env, then run npm test.\n');
}

main().catch((error) => {
  process.stderr.write(`Error: ${error.message}\n`);
  process.exitCode = 1;
});
