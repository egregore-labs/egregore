#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.codex/hooks/branch-guard.js"
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
echo "$out" | grep -q '"permissionDecision":"deny"'
echo "$out" | grep -q 'bin/agent.sh branch'
echo "$out" | grep -q 'automatically'
if echo "$out" | grep -q 'Ask the user how to proceed'; then
  echo "branch guard regressed to interrupting users for routine Git choices" >&2
  exit 1
fi

payload_exempt='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: .codex/tmp.txt\n+ok\n*** End Patch\n"}}'
out="$(printf '%s' "$payload_exempt" | node "$HOOK")"
[ -z "$out" ]

payload_mixed_patch='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: memory/harvest.md\n+ok\n*** Add File: src/app.js\n+blocked\n*** End Patch\n"}}'
out="$(printf '%s' "$payload_mixed_patch" | EGREGORE_CODEX_PROJECT_DIR="$TMPD" node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'

payload_write='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TMPD"'/src/app.js","content":"x"}}'
out="$(printf '%s' "$payload_write" | node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'

payload_edit_exempt='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$TMPD"'/.codex/tmp.txt","old_string":"a","new_string":"b"}}'
out="$(printf '%s' "$payload_edit_exempt" | node "$HOOK")"
[ -z "$out" ]

payload_branch='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"bin/agent.sh branch --topic codex guard"}}'
out="$(printf '%s' "$payload_branch" | node "$HOOK")"
[ -z "$out" ]

payload_unsafe_branch='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"bin/agent.sh branch --topic codex-guard && touch src/should-block"}}'
out="$(printf '%s' "$payload_unsafe_branch" | node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'

payload_read_redirect='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status --short 2>/dev/null"}}'
out="$(printf '%s' "$payload_read_redirect" | node "$HOOK")"
[ -z "$out" ]

payload_quoted_search='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rg -n '"'"'git commit|mkdir|tee|x >= y'"'"' ."}}'
out="$(printf '%s' "$payload_quoted_search" | node "$HOOK")"
[ -z "$out" ]

payload_write_redirect='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf hello > src/app.js"}}'
out="$(printf '%s' "$payload_write_redirect" | node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'

payload_memory_dir='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mkdir -p memory/knowledge/harvests/test"}}'
out="$(printf '%s' "$payload_memory_dir" | node "$HOOK")"
[ -z "$out" ]

payload_project_dir='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mkdir -p src/generated"}}'
out="$(printf '%s' "$payload_project_dir" | node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'

payload_memory_redirect='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf hello > \"memory/harvest.md\""}}'
out="$(printf '%s' "$payload_memory_redirect" | node "$HOOK")"
[ -z "$out" ]

payload_consent='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo '"'"'develop'"'"' > .egregore-branch-consent"}}'
out="$(printf '%s' "$payload_consent" | node "$HOOK")"
[ -z "$out" ]

payload_unsafe_consent='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo develop > .egregore-branch-consent && touch src/should-block"}}'
out="$(printf '%s' "$payload_unsafe_consent" | node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'

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
echo "$out" | grep -q '"permissionDecision":"deny"'
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

payload_worktree_git_c='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git -C '"$WT"' commit -m test"}}'
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

payload_main='{"cwd":"'"$TMPD"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"chmod +x bin/new-script.sh"}}'
out="$(printf '%s' "$payload_main" | EGREGORE_CODEX_PROJECT_DIR="$TMPD" node "$HOOK")"
echo "$out" | grep -q '"permissionDecision":"deny"'

echo "codex branch guard ok"
