import { existsSync } from 'node:fs';
import { cp, chmod, lstat, mkdir, readFile, symlink, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { newToken, sha256, stableSafetyId, writeJsonAtomic } from './lib.mjs';
import { Registry } from './registry.mjs';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function discoverEgregoreSource(start) {
  let candidate = resolve(start);
  while (true) {
    const required = ['bin/agent.sh', '.codex/skills', '.claude/skills', 'LICENSE'];
    if (required.every((entry) => existsSync(resolve(candidate, entry)))) return candidate;
    const parent = dirname(candidate);
    if (parent === candidate) return null;
    candidate = parent;
  }
}

function tomlString(value) {
  return JSON.stringify(value);
}

function participantId(index) {
  return `participant-${String(index + 1).padStart(2, '0')}`;
}

async function pathExists(path) {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

async function copyFramework(source, destination) {
  const entries = ['bin', 'skills', '.codex/skills', '.claude/skills', 'LICENSE'];
  for (const entry of entries) {
    await cp(resolve(source, entry), resolve(destination, entry), {
      recursive: true,
      force: false,
      errorOnExist: true,
      filter(path) {
        return !path.includes('/.claude/worktrees/') && !path.endsWith('/.env');
      },
    });
  }
}

function workshopAgentInstructions(id) {
  return `# Workshop Egregore\n\nYou are the participant's second-brain configuration partner for an in-person neurodivergent workshop.\n\n## Boundaries\n\n- The participant owns the neighboring Obsidian vault at \`../vault\`. Prefer internal wikilinks between notes.\n- Ask before reading or changing personal notes. Never infer or request a diagnosis.\n- Offer spoken, written, or step-by-step interaction; the participant may pass, pause, leave, or return.\n- Make the smallest useful change. Keep every workflow usable without AI.\n- Never reveal, copy, or discuss files under \`../.workshop\`. The workshop gateway handles access.\n- Do not place provider credentials, workshop access tokens, or private note contents in Egregore memory or emissaries.\n- Update \`../vault/.second-brain/configuration-profile.json\` only with the participant's explicit preferences.\n- Keep the human-readable profile at \`../vault/System/Configuration Profile.md\` aligned with it.\n\n## Stable core\n\nHelp the participant practice this loop: capture → add context → resurface → re-enter. Start from [[Home]], [[Inbox]], [[Now]], and [[Re-entry]]. Personalize labels and cues without adding maintenance-heavy structure.\n\n## Session identity\n\nThis isolated workspace is ${id}. It will be revoked and deleted after export. The Obsidian vault is the durable take-home artifact.\n`;
}

function codexConfig(config) {
  return `model = ${tomlString(config.workshop.model)}\nmodel_provider = "workshop_gateway"\napproval_policy = "on-request"\nsandbox_mode = "workspace-write"\n\n[model_providers.workshop_gateway]\nname = "Facilitator-funded workshop gateway"\nbase_url = ${tomlString(config.gateway.publicUrl.replace(/\/$/, ''))}\nwire_api = "responses"\n\n[model_providers.workshop_gateway.auth]\ncommand = "node"\nargs = ["../.workshop/read-token.mjs"]\ntimeout_ms = 3000\nrefresh_interval_ms = 60000\n`;
}

function launcherScript() {
  return `#!/usr/bin/env bash\nset -euo pipefail\nWORKSHOP_ROOT="$(cd -- "$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"\nexec node "$WORKSHOP_ROOT/start-workshop.mjs" "$@"\n`;
}

const tokenReader = `import { readFile } from 'node:fs/promises';\nconst token = (await readFile(new URL('./access.token', import.meta.url), 'utf8')).trim();\nif (!token) process.exit(1);\nprocess.stdout.write(token);\n`;

const nodeLauncher = `import { spawn } from 'node:child_process';\nimport { dirname, resolve } from 'node:path';\nimport { fileURLToPath } from 'node:url';\nconst root = dirname(fileURLToPath(import.meta.url));\nconst child = spawn('codex', ['--add-dir', resolve(root, 'vault'), ...process.argv.slice(2)], {\n  cwd: resolve(root, 'egregore'),\n  env: { ...process.env, CODEX_HOME: resolve(root, '.workshop/codex-home') },\n  stdio: 'inherit',\n});\nchild.once('error', (error) => { process.stderr.write(\`Could not start Codex: \${error.message}\\n\`); process.exitCode = 1; });\nchild.once('exit', (code, signal) => { if (signal) process.kill(process.pid, signal); else process.exitCode = code ?? 1; });\n`;

function startHere(id, expiresAt) {
  return `# Start here — ${id}\n\n1. Open the \`vault\` folder in Obsidian. Start at \`Home.md\`.\n2. Run \`./start-workshop.sh\` on macOS/Linux or \`node start-workshop.mjs\` on Windows.\n3. Tell the agent what you want help remembering, returning to, or making easier. You may also work entirely in Obsidian.\n4. Before leaving the workshop, ask the facilitator to run the verified export with you.\n\nYour workshop access expires at ${expiresAt}. The provider keys are never stored here. Your access token is temporary, quota-bound, and removed when this workspace is deleted.\n`;
}

export async function provisionWorkshop(config, options = {}) {
  const count = Number(options.count ?? config.workshop.participantCount);
  if (!Number.isInteger(count) || count < 1 || count > 20) throw new Error('participant count must be between 1 and 20');
  const discoveredSource = options.egregoreSource ?? discoverEgregoreSource(packageRoot) ?? discoverEgregoreSource(process.cwd());
  if (!discoveredSource) {
    throw new Error('could not find an Egregore checkout; pass --egregore-source <path>');
  }
  const source = resolve(discoveredSource);
  const registry = await Registry.open(config.gateway.registryPath);
  const expiresAt = new Date(Date.now() + config.workshop.tokenLifetimeHours * 3600_000).toISOString();
  const created = [];

  const plannedIds = Array.from({ length: count }, (_, index) => participantId(index));
  for (const id of plannedIds) {
    if (registry.data.participants.some((participant) => participant.id === id)) {
      throw new Error(`${id} already exists in the registry`);
    }
    if (await pathExists(resolve(config.workshop.runtimeRoot, id))) {
      throw new Error(`${id} already exists in the participant runtime root`);
    }
  }

  await mkdir(config.workshop.runtimeRoot, { recursive: true });
  for (let index = 0; index < count; index += 1) {
    const id = participantId(index);
    const workspacePath = resolve(config.workshop.runtimeRoot, id);
    const egregorePath = resolve(workspacePath, 'egregore');
    const vaultPath = resolve(workspacePath, 'vault');
    const memoryPath = resolve(workspacePath, 'memory');
    const privatePath = resolve(workspacePath, '.workshop');
    const codexHome = resolve(privatePath, 'codex-home');
    const token = newToken();
    const tokenReaderPath = resolve(privatePath, 'read-token.mjs');

    await mkdir(workspacePath, { recursive: false });
    await mkdir(egregorePath, { recursive: false });
    await mkdir(memoryPath, { recursive: false });
    await mkdir(codexHome, { recursive: true });
    await copyFramework(source, egregorePath);
    await cp(resolve(packageRoot, 'templates/vault'), vaultPath, { recursive: true, force: false });
    await mkdir(resolve(memoryPath, 'people'), { recursive: true });
    await mkdir(resolve(memoryPath, 'knowledge'), { recursive: true });
    await writeFile(resolve(memoryPath, 'people/participant.md'), `# ${id}\n\nWorkshop participant pseudonym. No diagnosis or private notes belong here.\n`);
    await symlink('../memory', resolve(egregorePath, 'memory'));

    await writeFile(resolve(egregorePath, 'AGENTS.md'), workshopAgentInstructions(id));
    await writeJsonAtomic(resolve(egregorePath, 'egregore.json'), {
      mode: 'local',
      org_name: `Second Brain Workshop — ${id}`,
      slug: `second-brain-${id}`,
      memory_repo: '../memory',
      repos: [{ name: 'vault', description: 'Participant-owned Obsidian second brain' }],
    }, 0o644);
    await writeFile(resolve(privatePath, 'access.token'), `${token}\n`, { mode: 0o600 });
    await writeFile(tokenReaderPath, tokenReader, { mode: 0o700 });
    await writeFile(resolve(codexHome, 'config.toml'), codexConfig(config), { mode: 0o600 });
    await writeJsonAtomic(resolve(privatePath, 'participant.json'), { id, expiresAt }, 0o600);
    await writeFile(resolve(workspacePath, 'start-workshop.sh'), launcherScript(), { mode: 0o700 });
    await writeFile(resolve(workspacePath, 'start-workshop.mjs'), nodeLauncher, { mode: 0o700 });
    await writeFile(resolve(workspacePath, 'START-HERE.md'), startHere(id, expiresAt), { mode: 0o644 });
    await chmod(resolve(workspacePath, 'start-workshop.sh'), 0o700);

    const profilePath = resolve(vaultPath, '.second-brain/configuration-profile.json');
    const profile = JSON.parse(await readFile(profilePath, 'utf8'));
    profile.participantId = id;
    profile.updatedAt = new Date().toISOString();
    await writeJsonAtomic(profilePath, profile, 0o600);

    created.push({ id, workspacePath, vaultPath, expiresAt, tokenHash: sha256(token) });
  }

  await registry.transact((data) => {
    const duplicate = created.find((item) => data.participants.some((participant) => participant.id === item.id));
    if (duplicate) throw new Error(`${duplicate.id} already exists in the registry`);
    for (const item of created) {
      data.participants.push({
        id: item.id,
        tokenHash: item.tokenHash,
        safetyId: stableSafetyId(item.id, data.safetySalt),
        status: 'active',
        createdAt: new Date().toISOString(),
        expiresAt: item.expiresAt,
        quotas: { ...config.workshop.quotas },
        usage: { requests: 0, inputTokens: 0, outputTokens: 0, outputReserved: 0, active: 0 },
      });
    }
  });

  return created.map(({ tokenHash, ...item }) => item);
}
