#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${GUARD_HOOK_OVERRIDE:-$ROOT/.codex/hooks/branch-guard.js}"
TMPD="$(mktemp -d -t egregore-codex-guard-XXXXXX)"
WT=""
SIBLING=""
MEMORY=""
cleanup() {
  rm -rf "$TMPD"
  [ -z "$WT" ] || rm -rf "$WT"
  [ -z "$SIBLING" ] || rm -rf "$SIBLING"
  [ -z "$MEMORY" ] || rm -rf "$MEMORY"
}
trap cleanup EXIT

git -C "$TMPD" init --quiet
git -C "$TMPD" config user.name "Codex Guard Test"
git -C "$TMPD" config user.email "codex-guard@test.local"
git -C "$TMPD" checkout -b develop --quiet
printf '# test\n' > "$TMPD/README.md"
git -C "$TMPD" add README.md
git -C "$TMPD" commit -m "init" --quiet

MEMORY="$(mktemp -d -t egregore-codex-memory-XXXXXX)"
git -C "$MEMORY" init --quiet
git -C "$MEMORY" config user.name "Codex Guard Test"
git -C "$MEMORY" config user.email "codex-guard@test.local"
git -C "$MEMORY" checkout -b main --quiet
git -C "$MEMORY" commit --allow-empty -m init --quiet
ln -s "$MEMORY" "$TMPD/memory"

payload_patch='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: src/app.js\n+console.log(1)\n*** End Patch\n"}}'
out="$(printf '%s' "$payload_patch" | node "$HOOK")"
grep -q '"permissionDecision":"deny"' <<< "$out"
grep -q 'bin/agent.sh branch' <<< "$out"
grep -q 'automatically' <<< "$out"
if grep -q 'Ask the user how to proceed' <<< "$out"; then
  echo "branch guard regressed to interrupting users for routine Git choices" >&2
  exit 1
fi

payload_exempt='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: .codex/tmp.txt\n+ok\n*** End Patch\n"}}'
out="$(printf '%s' "$payload_exempt" | node "$HOOK")"
[ -z "$out" ]

payload_mixed_patch='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: memory/harvest.md\n+ok\n*** Add File: src/app.js\n+blocked\n*** End Patch\n"}}'
out="$(printf '%s' "$payload_mixed_patch" | EGREGORE_CODEX_PROJECT_DIR="$TMPD" node "$HOOK")"
grep -q '"permissionDecision":"deny"' <<< "$out"

payload_write='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TMPD"'/src/app.js","content":"x"}}'
out="$(printf '%s' "$payload_write" | node "$HOOK")"
grep -q '"permissionDecision":"deny"' <<< "$out"

payload_edit_exempt='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$TMPD"'/.codex/tmp.txt","old_string":"a","new_string":"b"}}'
out="$(printf '%s' "$payload_edit_exempt" | node "$HOOK")"
[ -z "$out" ]

payload_branch='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"bin/agent.sh branch --topic codex guard"}}'
out="$(printf '%s' "$payload_branch" | node "$HOOK")"
[ -z "$out" ]

payload_unsafe_branch='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"bin/agent.sh branch --topic codex-guard && touch src/should-block"}}'
out="$(printf '%s' "$payload_unsafe_branch" | node "$HOOK")"
grep -q '"permissionDecision":"deny"' <<< "$out"

payload_read_redirect='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"git status --short 2>/dev/null"}}'
out="$(printf '%s' "$payload_read_redirect" | node "$HOOK")"
[ -z "$out" ]

payload_quoted_search='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"rg -n '"'"'git commit|mkdir|tee|x >= y'"'"' ."}}'
out="$(printf '%s' "$payload_quoted_search" | node "$HOOK")"
[ -z "$out" ]

payload_write_redirect='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"printf hello > src/app.js"}}'
out="$(printf '%s' "$payload_write_redirect" | node "$HOOK")"
grep -q '"permissionDecision":"deny"' <<< "$out"

payload_memory_dir='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"mkdir -p memory/knowledge/harvests/test"}}'
out="$(printf '%s' "$payload_memory_dir" | node "$HOOK")"
[ -z "$out" ]

payload_project_dir='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"mkdir -p src/generated"}}'
out="$(printf '%s' "$payload_project_dir" | node "$HOOK")"
grep -q '"permissionDecision":"deny"' <<< "$out"

payload_memory_redirect='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"printf hello > \"memory/harvest.md\""}}'
out="$(printf '%s' "$payload_memory_redirect" | node "$HOOK")"
[ -z "$out" ]

payload_consent='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"echo '"'"'develop'"'"' > .egregore-branch-consent"}}'
out="$(printf '%s' "$payload_consent" | node "$HOOK")"
[ -z "$out" ]

payload_unsafe_consent='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"echo develop > .egregore-branch-consent && touch src/should-block"}}'
out="$(printf '%s' "$payload_unsafe_consent" | node "$HOOK")"
grep -q '"permissionDecision":"deny"' <<< "$out"

printf 'develop\n' > "$TMPD/.egregore-branch-consent"
out="$(printf '%s' "$payload_write" | node "$HOOK")"
[ -z "$out" ]
rm "$TMPD/.egregore-branch-consent"

git -C "$TMPD" checkout -b dev/alice/codex-guard --quiet
out="$(printf '%s' "$payload_patch" | node "$HOOK")"
[ -z "$out" ]

git -C "$TMPD" checkout develop --quiet
printf '{"base_branch":"trunk"}\n' > "$TMPD/egregore.json"
git -C "$TMPD" checkout -b trunk --quiet
out="$(printf '%s' "$payload_write" | node "$HOOK")"
grep -q '"permissionDecision":"deny"' <<< "$out"
printf 'trunk\n' > "$TMPD/.egregore-branch-consent"
out="$(printf '%s' "$payload_write" | node "$HOOK")"
[ -z "$out" ]
rm "$TMPD/.egregore-branch-consent"
git -C "$TMPD" checkout develop --quiet

git -C "$TMPD" branch dev/oz/worktree-cwd-guard HEAD
WT="$TMPD-wt"
git -C "$TMPD" worktree add "$WT" dev/oz/worktree-cwd-guard --quiet
payload_worktree='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$WT"'","command":"chmod +x bin/new-script.sh"}}'
out="$(printf '%s' "$payload_worktree" | EGREGORE_CODEX_PROJECT_DIR="$TMPD" node "$HOOK")"
[ -z "$out" ]

payload_worktree_write='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$WT"'/src/app.js","content":"x"}}'
out="$(printf '%s' "$payload_worktree_write" | EGREGORE_CODEX_PROJECT_DIR="$TMPD" node "$HOOK")"
[ -z "$out" ]

payload_worktree_git_c='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"git -C '"$WT"' commit -m test"}}'
out="$(printf '%s' "$payload_worktree_git_c" | EGREGORE_CODEX_PROJECT_DIR="$TMPD" node "$HOOK")"
[ -z "$out" ]

SIBLING="$(mktemp -d -t egregore-codex-sibling-XXXXXX)"
git -C "$SIBLING" init --quiet
git -C "$SIBLING" config user.name "Codex Guard Test"
git -C "$SIBLING" config user.email "codex-guard@test.local"
git -C "$SIBLING" checkout -b main --quiet
git -C "$SIBLING" commit --allow-empty -m init --quiet
payload_sibling_write='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$SIBLING"'/notes.md","content":"x"}}'
out="$(printf '%s' "$payload_sibling_write" | EGREGORE_CODEX_PROJECT_DIR="$TMPD" node "$HOOK")"
[ -z "$out" ]

payload_main='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"workdir":"'"$TMPD"'","command":"chmod +x bin/new-script.sh"}}'
out="$(printf '%s' "$payload_main" | EGREGORE_CODEX_PROJECT_DIR="$TMPD" node "$HOOK")"
grep -q '"permissionDecision":"deny"' <<< "$out"

# Native patch payloads and worktree routing must agree with Edit/Write.
GUARD_FIXTURE="$TMPD" GUARD_WORKTREE="$WT" GUARD_HOOK="$HOOK" node <<'NODE'
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { GUARD_FIXTURE: hub, GUARD_WORKTREE: wt, GUARD_HOOK: hook } = process.env;
let failures = 0;
function check(label, input, denied) {
  const result = spawnSync(process.execPath, [hook], {
    cwd: hub,
    env: { ...process.env, EGREGORE_CODEX_PROJECT_DIR: hub },
    input: JSON.stringify({ cwd: hub, ...input, tool_input:
      input.tool_name === "Bash" && !input.lossy
        ? { workdir: input.cwd || hub, ...input.tool_input } : input.tool_input,
    }), encoding: "utf8",
  });
  try {
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.includes('"permissionDecision":"deny"'), denied);
    if (input.advisory) assert.ok(JSON.parse(result.stdout).hookSpecificOutput.additionalContext);
    console.log(`ok — ${label}`);
  } catch (error) {
    failures++;
    console.error(`FAIL — ${label}: ${error.message}`);
  }
}
const patch = target => `*** Begin Patch\n*** Add File: ${target}\n+ok\n*** End Patch\n`;
for (const [label, wrap] of [
  ["raw", value => value],
  ["command", value => ({ command: value })],
  ["input", value => ({ input: value })],
  ["patch", value => ({ patch: value })],
]) {
  check(`${label} patch to task worktree`, { tool_name: "apply_patch", tool_input: wrap(patch(`${wt}/src/new.js`)) }, false);
  check(`${label} patch to memory`, { tool_name: "apply_patch", tool_input: wrap(patch("memory/new.md")) }, false);
  check(`${label} patch to develop`, { tool_name: "apply_patch", tool_input: wrap(patch("src/new.js")) }, true);
}
check("patch relative to explicit task workdir", {
  tool_name: "apply_patch", tool_input: { workdir: wt, command: patch("src/new.js") },
}, false);
check("native exec_command honors cmd and workdir", {
  tool_name: "exec_command", tool_input: { workdir: wt, cmd: "touch src/new.js" },
}, false);
check("native exec_command protects develop", {
  tool_name: "exec_command", tool_input: { workdir: hub, cmd: "touch src/new.js" },
}, true);
check("lossy live shell payload gives guidance without blocking", {
  lossy: true, advisory: true, tool_name: "Bash", tool_input: { command: "git add -N bin/new.js" },
}, false);
check("lossy shell payload still protects explicit hub destination", {
  lossy: true, tool_name: "Bash", tool_input: { command: `git -C "${hub}" add src/new.js` },
}, true);
check("lossy shell payload still protects absolute file writes", {
  lossy: true, tool_name: "Bash", tool_input: { command: `touch "${hub}/src/new.js"` },
}, true);
check("lossy shell payload allows explicit task workspace", {
  lossy: true, tool_name: "Bash", tool_input: { command: `git -C "${wt}" add src/new.js` },
}, false);
check("task git command cannot hide a protected output redirect", {
  lossy: true, tool_name: "Bash", tool_input: { command: `git -C "${wt}" commit -m test > "${hub}/src/log.txt"` },
}, true);
check("patch rename into protected hub", {
  cwd: wt, tool_name: "apply_patch", tool_input: {
    patch: `*** Begin Patch\n*** Update File: ${wt}/src/old.js\n*** Move to: ${hub}/src/new.js\n@@\n-old\n+new\n*** End Patch\n`,
  },
}, true);
check("task cwd cannot mask patch into protected hub", {
  cwd: wt, tool_name: "apply_patch", tool_input: { command: patch(`${hub}/src/new.js`) },
}, true);
check("cd into task worktree before writing", {
  tool_name: "Bash", tool_input: { command: `cd "${wt}" && touch src/new.js` },
}, false);
check("worktree git operation followed by protected write", {
  tool_name: "Bash", tool_input: { command: `git -C "${wt}" status && touch src/new.js` },
}, true);
check("task cwd cannot mask shell write into protected hub", {
  cwd: wt, tool_name: "Bash", tool_input: { command: `touch "${hub}/src/new.js"` },
}, true);
check("read-only heredoc", {
  tool_name: "Bash", tool_input: { command: "python3 - <<'PY'\nprint('hello')\nPY" },
}, false);
check("heredoc data is not executed as shell commands", {
  tool_name: "Bash", tool_input: { command: `cat <<'EXAMPLE'\ngit -C "${hub}" push origin develop\nEXAMPLE` },
}, false);
check("heredoc opener still protects its output destination", {
  tool_name: "Bash", tool_input: { command: `cat <<'EXAMPLE' > "${hub}/src/new.js"\nhello\nEXAMPLE` },
}, true);
check("read-only command with attached stderr redirect", {
  tool_name: "Bash", tool_input: { command: "git status 2>/dev/null" },
}, false);
for (const runtime of [".claude", ".codex", ".pi", ".prime"]) {
  check(`${runtime} state write`, {
    tool_name: "Write", tool_input: { file_path: `${runtime}/state.json` },
  }, false);
}
check("relative write from nested cwd", {
  cwd: `${hub}/src`, tool_name: "Write", tool_input: { file_path: "../README.md" },
}, true);
if (failures) process.exit(1);
NODE

echo "codex branch guard ok"
