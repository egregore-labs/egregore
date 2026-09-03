#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER="$ROOT/bin/codex-render-spec.mjs"
AGENTS="$ROOT/AGENTS.md"
MANIFEST="$ROOT/.codex/spec-manifest.json"

# 1. Renderer runs green and the committed output is current (--check).
node "$RENDER" --check

# 2. Manifest is valid JSON and covers every H2 section of CLAUDE.md.
jq -e '.sections | length >= 15' "$MANIFEST" >/dev/null
claude_sections="$(awk '/^```/{f=!f} !f && /^## /' "$ROOT/CLAUDE.md" | wc -l | tr -d ' ')"
manifest_sections="$(jq '[.sections[] | select(.section != "(intro)")] | length' "$MANIFEST")"
[ "$claude_sections" = "$manifest_sections" ]

# 3. Every manifest entry has an action and a non-empty note.
jq -e '[.sections[] | select(.action != "keep" and .action != "replace")] | length == 0' "$MANIFEST" >/dev/null
jq -e '[.sections[] | select((.note | length) == 0)] | length == 0' "$MANIFEST" >/dev/null

# 4. Generated block exists in AGENTS.md and stays inside Codex's 32 KiB
#    project-doc budget.
grep -q 'BEGIN GENERATED EGREGORE CODEX SPEC' "$AGENTS"
grep -q 'END GENERATED EGREGORE CODEX SPEC' "$AGENTS"
size="$(wc -c < "$AGENTS" | tr -d ' ')"
[ "$size" -lt 32768 ]

# 5. No Claude-only mechanisms survive in the generated block.
block="$(sed -n '/BEGIN GENERATED EGREGORE CODEX SPEC/,/END GENERATED EGREGORE CODEX SPEC/p' "$AGENTS")"
if printf '%s' "$block" | grep -q 'EnterWorktree\|AskUserQuestion\|ExitPlanMode\|plan mode\|Plan mode'; then
  echo "Claude-only mechanism leaked into the rendered Codex spec" >&2
  exit 1
fi

# 6. The Codex translations are present. Grep a temp file, not a pipe:
# `printf | grep -q` races — grep exits on first match, printf takes EPIPE,
# and under pipefail that kills the test (reproduced on Linux runners only).
block_file="$(mktemp)"
trap 'rm -f "$block_file"' EXIT
printf '%s' "$block" > "$block_file"
grep -q 'bin/agent.sh branch --topic' "$block_file"
grep -q 'git checkout --no-track -b dev/{author}/{slug} origin/{base}' "$block_file"
grep -q 'Do not merge, cherry-pick, or rebase another task' "$block_file"
grep -q 'numbered' "$block_file"
grep -q '\.codex/hooks/branch-guard\.js' "$block_file"
grep -q '`\$save`' "$block_file"
grep -q 'Your stable project is protected' "$block_file"
grep -q '↳ Context restored:' "$block_file"
grep -q 'intent → safe workspace → relevant context → consequential assumptions → execution' "$block_file"

# 7. The thin universal protocol stays above the generated block.
head -1 "$AGENTS" | grep -q '^# Egregore Agent Protocol'

echo "codex spec render ok"
