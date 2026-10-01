#!/usr/bin/env node
// Exercise the workflow's own inline scripts with local GitHub/checker doubles.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const workflow = fs.readFileSync(path.join(root, '.github/workflows/pr-format.yml'), 'utf8');
const readout = fs.readFileSync(path.join(root, '.github/workflows/prose-check.yml'), 'utf8');
const parts = workflow.split(/(?=^      - name: )/m);
const step = name => {
  const found = parts.find(part => part.startsWith(`      - name: ${name}\n`));
  assert.ok(found, `missing step ${name}`);
  return found;
};
const format = step('Check PR format');
const checkout = step('Checkout prose checker');
const setup = step('Set up Node for prose checker');
const collect = step('Collect prose inputs');
const render = step('Render advisory prose');
const prose = step('Publish advisory prose');
const script = text => {
  const lines = text.slice(text.indexOf('          script: |\n') + 20).trimEnd().split('\n');
  assert.ok(lines.every(line => !line.trim() || line.startsWith('            ')));
  return lines.map(line => line.slice(12)).join('\n');
};
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const formatScript = new AsyncFunction('github', 'context', 'core', script(format));
const collectScript = new AsyncFunction('github', 'context', 'core', 'require', script(collect));
const proseScript = new AsyncFunction('github', 'context', 'core', 'require', script(prose));
const nativeRequire = createRequire(import.meta.url);
const basePr = {
  number: 7, title: 'fix(ci): keep metadata checks', body: '## What\n- Fix checks.\n## Why\nKeep feedback useful.\n## Verification\nLocal fixtures.',
  draft: false, user: { type: 'User' }, head: { sha: 'a'.repeat(40) },
};
const condition = (text, pr = basePr, outcomes = {}, cancelled = false) => {
  const expr = text.match(/^\s+if: \$\{\{ (.*) \}\}$/m)?.[1];
  assert.ok(expr, 'explicit status condition required');
  return new Function('github', 'steps', 'cancelled', 'startsWith', `return (${expr});`)(
    { event: { pull_request: pr } }, outcomes, () => cancelled, (value, prefix) => value.startsWith(prefix),
  );
};
function fixture({ pr = {}, comments = [], commits = [], files = [{ filename: 'code.py' }] } = {}) {
  const writes = [], failures = [], summaries = [], outputs = {};
  const rest = {
    pulls: { listFiles: Symbol('files'), listCommits: Symbol('commits') },
    issues: {
      listComments: Symbol('comments'),
      createComment: async data => writes.push({ method: 'create', ...data }),
      updateComment: async data => writes.push({ method: 'update', ...data }),
    },
  };
  return {
    writes, failures, summaries, outputs,
    github: { rest, paginate: async method => {
      if (method === rest.pulls.listFiles) return files;
      if (method === rest.pulls.listCommits) return commits;
      assert.equal(method, rest.issues.listComments);
      return comments;
    } },
    context: { repo: { owner: 'fixture', repo: 'fixture' }, payload: { pull_request: { ...basePr, ...pr } } },
    core: { info() {}, setOutput: (name, value) => { outputs[name] = value; }, setFailed: message => failures.push(message), summary: {
      addRaw(body) { summaries.push(body); return this; }, async write() {},
    } },
  };
}
async function runProse(f, { total = 0, failure, inputs = [] } = {}) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'metadata-workflow-'));
  const previous = { RUNNER_TEMP: process.env.RUNNER_TEMP, PROSE_INPUTS: process.env.PROSE_INPUTS };
  process.env.RUNNER_TEMP = temp;
  const report = `<!-- prose-check -->\n✅ prose check: no findings\n<!-- prose-check-data {"total":${total}} -->`;
  try {
    await collectScript(f.github, f.context, f.core, nativeRequire);
    const directory = f.outputs.directory;
    // Execute the workflow's actual shell block against a deterministic checker,
    // with the shell step's own environment, outside the token-bearing action.
    fs.mkdirSync(path.join(temp, 'bin'));
    fs.writeFileSync(path.join(temp, 'bin/prose-check.mjs'), `
      import fs from 'node:fs';
      import path from 'node:path';
      import assert from 'node:assert/strict';
      assert.equal(process.env['INPUT_GITHUB-TOKEN'], undefined);
      const args = process.argv.slice(2);
      if (args[0] === ${JSON.stringify(failure || '')}) {
        process.stdout.write('partial report');
        console.error('checker unavailable');
        process.exit(2);
      }
      if (args[0] === 'report') {
        assert.deepEqual(args.slice(0, 7), ['report', '--surface', 'git', '--meta', 'pr=7', '--meta', ${JSON.stringify(`sha=${basePr.head.sha}`)}]);
        const captured = args.slice(7).map(file => ({name: path.basename(file), text: fs.readFileSync(file, 'utf8')}));
        fs.writeFileSync('captured.json', JSON.stringify(captured));
        process.stdout.write(${JSON.stringify(report)});
      }
    `);
    const shell = render.split('        run: |\n')[1].trimEnd().split('\n').map(line => line.slice(10)).join('\n');
    execFileSync('bash', ['-e', '-o', 'pipefail', '-c', shell], {
      cwd: temp, stdio: 'pipe', env: {
        PATH: process.env.PATH, PROSE_INPUTS: directory,
        PR_NUMBER: String(basePr.number), HEAD_SHA: basePr.head.sha,
        GITHUB_STEP_SUMMARY: path.join(temp, 'summary.md'),
      },
    });
    inputs.push(...JSON.parse(fs.readFileSync(path.join(temp, 'captured.json'), 'utf8')));
    f.summaries.push(fs.readFileSync(path.join(temp, 'summary.md'), 'utf8'));
    process.env.PROSE_INPUTS = directory;
    await proseScript(f.github, f.context, f.core, nativeRequire);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

test('one strict Slim PR job; readiness, draft exemptions and cancellation are retained', () => {
  assert.deepEqual([...workflow.matchAll(/^  ([\w-]+):\n    name:/gm)].map(m => m[1]), ['pr-format']);
  assert.match(parts[0], /runs-on: ubuntu-slim/);
  assert.doesNotMatch(parts[0], /continue-on-error/);
  assert.doesNotMatch(format, /continue-on-error/);
  assert.match(parts[0], /types: \[opened, edited, reopened, synchronize, ready_for_review\]/);
  assert.match(parts[0], /group: pr-format-\$\{\{ github.ref \}\}/);
  assert.match(parts[0], /cancel-in-progress: true/);
  assert.equal(condition(parts[0]), true);
  assert.equal(condition(parts[0], { ...basePr, draft: true }), false);
  assert.equal(parts[1], format, 'trusted gate runs before PR checkout');
});

test('prose steps are advisory, run after format failure and require successful prerequisites', () => {
  for (const text of [checkout, setup, collect, render, prose]) {
    assert.match(text, /^        continue-on-error: true$/m);
    assert.match(text, /if: \$\{\{ !cancelled\(\)/);
  }
  assert.match(render, /timeout-minutes: 2/);
  assert.doesNotMatch(render, /uses:|GITHUB.TOKEN|github.token/);
  for (const text of [format, collect, prose]) assert.doesNotMatch(script(text), /child_process|execFile|execSync|spawn|\.exec\(/);
  assert.match(checkout, /ref: \$\{\{ github.event.pull_request.head.sha \}\}/);
  assert.match(checkout, /persist-credentials: false/);
  assert.equal(condition(checkout), true);
  for (const pr of [{ ...basePr, user: { type: 'Bot' } }, { ...basePr, title: 'release: candidate' }, { ...basePr, title: 'release(ci): candidate' }]) {
    assert.equal(condition(checkout, pr), false);
  }
  for (const [text, key] of [[setup, 'prose_checkout'], [collect, 'prose_node'], [render, 'prose_inputs'], [prose, 'prose_report']]) {
    assert.equal(condition(text, basePr, { [key]: { outcome: 'success' } }), true);
    for (const outcome of ['failure', 'skipped', 'cancelled']) assert.equal(condition(text, basePr, { [key]: { outcome } }), false);
    assert.equal(condition(text, basePr, { [key]: { outcome: 'success' } }, true), false);
  }
});

test('format still rejects missing or empty sections and code without verification', async () => {
  for (const body of ['', '## What\n\n## Why\nReason', '## What\nChange\n## Why\nReason']) {
    const f = fixture({ pr: { body } });
    await formatScript(f.github, f.context, f.core);
    assert.equal(f.failures.length, 1);
    assert.equal(f.writes.length, 1);
    assert.match(f.writes[0].body, /❌ PR format check/);
  }
});

test('format accepts valid descriptions, markdown-only changes and advisory title grammar', async () => {
  for (const options of [{}, { pr: { title: 'Nonconventional title' } }, { pr: { body: '## What\nChange\n## Why\nReason' }, files: [{ filename: 'docs.md' }] }]) {
    const f = fixture(options);
    await formatScript(f.github, f.context, f.core);
    assert.deepEqual(f.failures, []);
  }
});

test('clean prose stays quiet; findings create or update; cleared findings resolve', async () => {
  for (const total of [0, 2]) for (const existing of [false, true]) {
    const f = fixture({ comments: existing ? [{ id: 12, body: '<!-- prose-check --> old findings' }] : [] });
    await runProse(f, { total });
    assert.deepEqual(f.failures, []);
    assert.equal(f.summaries.length, 1);
    assert.equal(f.writes.length, total || existing ? 1 : 0);
    if (f.writes.length) assert.equal(f.writes[0].method, existing ? 'update' : 'create');
    if (existing && !total) assert.match(f.writes[0].body, /resolved, no findings/);
  }
});

test('checker failures publish no partial or resolved receipt and do not erase format failure', async () => {
  for (const failure of ['validate', 'report']) {
    const f = fixture({ pr: { body: '' }, comments: [{ id: 12, body: '<!-- prose-check --> old findings' }] });
    await formatScript(f.github, f.context, f.core);
    await assert.rejects(runProse(f, { failure }), /checker unavailable/);
    assert.equal(f.failures.length, 1);
    assert.equal(f.writes.length, 1, 'only the failed format receipt was published');
    assert.deepEqual(f.summaries, []);
  }
});

test('prose receives literal body and commit text, skipping native Git messages', async () => {
  const body = 'Literal $(touch /never) and `text`';
  const messages = ['fix(ci): keep body\n\nLiteral $(never)', 'Merge branch x', 'Revert "change"', 'fixup! old', 'squash! old', 'feat(ci): merge parent'];
  const f = fixture({ pr: { body }, commits: messages.map((message, index) => ({
    sha: String(index + 1).repeat(40), parents: index === 5 ? [{}, {}] : [{}], commit: { message },
  })) });
  const inputs = [];
  await runProse(f, { inputs });
  assert.deepEqual(inputs, [{ name: 'pr-body.md', text: body + '\n' }, { name: 'commit-1111111.md', text: messages[0] + '\n' }]);
});

test('dated readout is manual-only and serialized, retaining its issue guard and tally', () => {
  assert.match(readout, /^on:\n  workflow_dispatch:\n/m);
  assert.doesNotMatch(readout, /^  (pull_request|push|schedule):/m);
  assert.match(readout, /group: prose-read-out\n  cancel-in-progress: false/);
  assert.match(readout, /READ_OUT_DATE: "20261008"/);
  assert.match(readout, /WINDOW_SINCE: "2026-09-10"/);
  assert.match(readout, /gh issue list .*--state all --search/);
  assert.match(readout, /prose-check-tally.sh --repo/);
  assert.match(readout, /gh issue create/);
  assert.match(readout, /^  issues: write$/m);
  assert.match(readout, /flip the rule to blocking in .*pr-format.yml/);
});
