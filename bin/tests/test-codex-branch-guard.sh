#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.codex/hooks/branch-guard.js"
TMPD="$(mktemp -d -t egregore-codex-guard-XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

git -C "$TMPD" init --quiet
git -C "$TMPD" config user.name "Codex Guard Test"
git -C "$TMPD" config user.email "codex-guard@test.local"
git -C "$TMPD" checkout -b develop --quiet
printf '# test\n' > "$TMPD/README.md"
git -C "$TMPD" add README.md
git -C "$TMPD" commit -m "init" --quiet

payload_patch='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: src/app.js\n+console.log(1)\n*** End Patch\n"}}'
out="$(printf '%s' "$payload_patch" | node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'
echo "$out" | grep -q 'bin/agent.sh branch'

payload_exempt='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: .codex/tmp.txt\n+ok\n*** End Patch\n"}}'
out="$(printf '%s' "$payload_exempt" | node "$HOOK")"
[ -z "$out" ]

payload_write='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TMPD"'/src/app.js","content":"x"}}'
out="$(printf '%s' "$payload_write" | node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'

payload_edit_exempt='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$TMPD"'/.codex/tmp.txt","old_string":"a","new_string":"b"}}'
out="$(printf '%s' "$payload_edit_exempt" | node "$HOOK")"
[ -z "$out" ]

payload_branch='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"bin/agent.sh branch --topic codex guard"}}'
out="$(printf '%s' "$payload_branch" | node "$HOOK")"
[ -z "$out" ]

payload_read_redirect='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status --short 2>/dev/null"}}'
out="$(printf '%s' "$payload_read_redirect" | node "$HOOK")"
[ -z "$out" ]

payload_write_redirect='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf hello > src/app.js"}}'
out="$(printf '%s' "$payload_write_redirect" | node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'

git -C "$TMPD" checkout -b dev/alice/codex-guard --quiet
out="$(printf '%s' "$payload_patch" | node "$HOOK")"
[ -z "$out" ]

git -C "$TMPD" checkout develop --quiet
git -C "$TMPD" branch dev/oz/worktree-cwd-guard HEAD
WT="$TMPD-wt"
git -C "$TMPD" worktree add "$WT" dev/oz/worktree-cwd-guard --quiet
payload_worktree='{"cwd":"'"$WT"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"chmod +x bin/new-script.sh"}}'
out="$(printf '%s' "$payload_worktree" | EGREGORE_CODEX_PROJECT_DIR="$TMPD" node "$HOOK")"
[ -z "$out" ]

payload_main='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"chmod +x bin/new-script.sh"}}'
out="$(printf '%s' "$payload_main" | EGREGORE_CODEX_PROJECT_DIR="$TMPD" node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'

echo "codex branch guard ok"
