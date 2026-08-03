#!/usr/bin/env node
// Unit tests for bin/pi-branch-policy.mjs — the Pi branch-guard heuristic.
// Run directly (node tests/bin/pi-branch-policy.test.mjs) or via
// tests/bin/pi-branch-policy.bats.

import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const {
  isMutatingBash,
  isRuntimeStatePath,
  mutatesOnlyRuntimeState,
} = await import(resolve(here, "../../bin/pi-branch-policy.mjs"));

const cases = [
  // --- read-only: must NOT be flagged ---
  [false, "ls -la | head -20"],
  [false, "git status"],
  [false, "git log --pretty=format:%s | head"],
  [false, "echo done 2>&1"],
  [false, "bash bin/foo.sh >/dev/null 2>&1"],
  [false, 'bash bin/graph.sh query "MATCH (s:Session) WHERE s.started_at >= datetime() RETURN s LIMIT 5"'],
  [false, "bash bin/graph.sh query \"MATCH (x) WHERE duration('P2D') >= x.at RETURN x\""],
  [false, 'python3 -c "import sys; [print(f\'{a} -> {b}\') for a,b in rows]"'],
  [false, "echo '2 > 1'"],
  [false, "grep -E '(mode|api_url)' egregore.json"],
  [false, "curl -s https://example.com | jq '.a > .b'"],
  // --- mutating: MUST be flagged ---
  [true, "echo hi > /tmp/x"],
  [true, "echo hi >> /tmp/x"],
  [true, 'echo hi > "/tmp/x"'],
  [true, "bash bin/activity-data.sh 2>&1 > /tmp/activity.json"],
  [true, "rm -rf /tmp/x"],
  [true, "mkdir -p /tmp/x"],
  [true, "sudo mkdir -p /tmp/x"],
  [true, "echo hi | tee /tmp/x"],
  [true, "git add ."],
  [true, "git commit -m 'x'"],
  [true, "git push origin develop"],
  [true, "npm install"],
  [true, "pnpm add lodash"],
  [true, "sed s/a/b/ -i file.txt"],
];

let failures = 0;
for (const [expected, cmd] of cases) {
  const got = isMutatingBash(cmd);
  if (got !== expected) {
    failures++;
    console.error(`FAIL expected=${expected} got=${got} :: ${cmd}`);
  }
}
if (failures) {
  console.error(`${failures}/${cases.length} cases failed`);
  process.exit(1);
}
console.log(`ok — ${cases.length} cases passed`);

const root = resolve(here, "../..");
assert.equal(isRuntimeStatePath("memory/knowledge/harvests/test", root), true);
assert.equal(isRuntimeStatePath(".egregore-branch-consent", root), true);
assert.equal(isRuntimeStatePath(".codex/runtime-state.json", root), true);
assert.equal(isRuntimeStatePath("src/app.js", root), false);
assert.equal(isRuntimeStatePath(".claude/worktrees/topic/src/app.js", root), false);

assert.equal(mutatesOnlyRuntimeState("mkdir -p memory/knowledge/harvests/test", root), true);
assert.equal(mutatesOnlyRuntimeState("sudo mkdir -p memory/knowledge/harvests/test", root), true);
assert.equal(mutatesOnlyRuntimeState('echo hi > "memory/harvest.md"', root), true);
assert.equal(mutatesOnlyRuntimeState("echo hi | tee memory/harvest.md", root), true);
assert.equal(mutatesOnlyRuntimeState("echo develop > .egregore-branch-consent", root), true);
assert.equal(mutatesOnlyRuntimeState("mkdir -p src/generated", root), false);
assert.equal(mutatesOnlyRuntimeState("echo hi > src/app.js", root), false);
assert.equal(
  mutatesOnlyRuntimeState("echo develop > .egregore-branch-consent && touch src/app.js", root),
  false,
);
console.log("ok — runtime-state exemptions passed");
