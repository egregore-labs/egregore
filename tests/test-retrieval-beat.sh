#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BEAT='⌕ Egregore · searching your organization’s memory'
GRAPH_BEAT='⌕ Egregore Connect · searching your organization’s memory and relationships'

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

grep -Fq "$BEAT" "$ROOT/CLAUDE.md" ||
  fail "Claude behavioral contract is missing the retrieval beat"
grep -Fq "$GRAPH_BEAT" "$ROOT/CLAUDE.md" ||
  fail "Claude behavioral contract is missing graph attribution"
grep -Fq 'standalone assistant message before the first Bash, Grep, Glob, Read' "$ROOT/CLAUDE.md" ||
  fail "Claude contract does not require a visible pre-tool beat"
grep -Fq 'Shell/tool output does not satisfy this requirement' "$ROOT/CLAUDE.md" ||
  fail "Claude contract still permits a collapsed tool-output beat"
grep -Fq 'Do not paraphrase the line' "$ROOT/CLAUDE.md" ||
  fail "Claude contract permits generic retrieval narration"
grep -Fq "$BEAT" "$ROOT/AGENTS.md" ||
  fail "Codex behavioral contract is missing the retrieval beat"
grep -Fq "$BEAT" "$ROOT/.pi/APPEND_SYSTEM.md" ||
  fail "Pi behavioral contract is missing the retrieval beat"
grep -Fq 'local line="⌕ ${product} · ${surface}' "$ROOT/bin/search.sh" ||
  fail "search output is not product-attributed"
grep -Fq 'Never name `Egregore Connect` unless a graph read will actually run.' "$ROOT/CLAUDE.md" ||
  fail "graph attribution truthfulness guard is missing"
grep -Fq 'organizational recall starts with `bash bin/search.sh query`' "$ROOT/CLAUDE.md" ||
  fail "global routing contract does not require the Egregore search entry point"
grep -Fq 'Do not `cd` into the sibling memory repository.' "$ROOT/CLAUDE.md" ||
  fail "global routing contract still permits absolute sibling-memory traversal"
grep -Fq 'Do not resolve `memory/` to its sibling Git repository' "$ROOT/.claude/skills/search/SKILL.md" ||
  fail "Claude search skill does not prohibit raw sibling-memory traversal"
grep -Fq 'bash bin/search.sh query "your query" -n 6' "$ROOT/.codex/skills/search/SKILL.md" ||
  fail "Codex search skill does not use the cross-runtime search entry point"

jq -e '.permissions.additionalDirectories | index("memory") != null' "$ROOT/.claude/settings.json" >/dev/null ||
  fail "Claude does not register memory as an additional working directory"
jq -e '.permissions.allow | index("Bash(bash bin/search.sh query:*)") != null' "$ROOT/.claude/settings.json" >/dev/null ||
  fail "Claude auto mode is missing a narrow permission for Egregore search"

grep -Fq 'function claudeLaunchArgs(egregoreDir)' "$ROOT/packages/create-egregore/assets/egregore-launcher.js" ||
  fail "installed launcher does not build Claude memory-workspace arguments"
grep -Fq 'args.push("--add-dir", memoryDir)' "$ROOT/packages/create-egregore/assets/egregore-launcher.js" ||
  fail "installed launcher does not declare resolved memory with --add-dir"
grep -Fq 'function claudeLaunchArgs(egregoreDir)' "$ROOT/packages/create-egregore/lib/setup.js" ||
  fail "first-run autolaunch does not build Claude memory-workspace arguments"
grep -Fq 'claude_args+=("--add-dir" "$target_path/memory")' "$ROOT/packages/create-egregore/assets/egregore-launcher.sh" ||
  fail "shell launcher fallback does not declare memory with --add-dir"
grep -Fq 'CLAUDE_ARGS+=("--add-dir" "$HOME/egregore/memory")' "$ROOT/bin/workspace-init.sh" ||
  fail "hosted workspace launcher does not declare memory with --add-dir"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/bin/search.sh"
printf 'retrieval-beat-test-%s\n' "$$" > "$fixture/.egregore-session-id"
rm -f "/tmp/egregore-search-hint-retrieval-beat-test-$$"
hint=$(printf '%s\n' '{"prompt":"what are our paid and free tiers?"}' |
  CLAUDE_PROJECT_DIR="$fixture" bash "$ROOT/.claude/hooks/search-hint.sh")
printf '%s' "$hint" | grep -Fq 'FIRST action: `bash bin/search.sh query' ||
  fail "Claude prompt hook does not route pricing/tier recall through Egregore search"
rm -f "/tmp/egregore-search-hint-retrieval-beat-test-$$"
codex_hint=$(printf '%s\n' '{"prompt":"what are our paid and free tiers?"}' |
  CLAUDE_PROJECT_DIR="$fixture" node "$ROOT/.codex/hooks/search-hint.js")
printf '%s' "$codex_hint" | grep -Fq 'FIRST action: `bash bin/search.sh query' ||
  fail "Codex prompt hook does not route pricing/tier recall through Egregore search"

for runtime in codex pi prime; do
  test -f "$ROOT/packages/create-egregore/runtime/$runtime/bin/search.sh" ||
    fail "packaged $runtime runtime is missing bin/search.sh"
  # The search SKILL is distribution-gated: when skill.search is queued (not
  # yet 'available' for oss) the bundle legitimately ships without it. Assert
  # the beat only on bundles that actually carry the skill, so this suite
  # tracks the retrieval contract rather than the release schedule.
  packaged_search="$ROOT/packages/create-egregore/runtime/$runtime/.codex/skills/search/SKILL.md"
  if [ ! -f "$packaged_search" ]; then
    echo "  ○ $runtime bundle ships no search skill (queued in capability-distribution) — beat assertions skipped"
    continue
  fi
  grep -Fq "$BEAT" "$packaged_search" ||
    fail "packaged $runtime search skill is missing the retrieval beat"
  grep -Fq 'command output does not satisfy this requirement' "$packaged_search" ||
    fail "packaged $runtime search skill permits a hidden retrieval beat"
done

echo "PASS: Egregore search beat is product-attributed across Claude, Codex, and Pi"
