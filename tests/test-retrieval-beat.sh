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
grep -Fq 'message before the first tool call that performs the organizational recall' "$ROOT/CLAUDE.md" ||
  fail "Claude contract does not require a visible pre-tool beat"
grep -Fq 'Tool output does not satisfy it' "$ROOT/CLAUDE.md" ||
  fail "Claude contract permits a collapsed tool-output beat"
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
grep -Fq 'Organizational recall always enters Egregore Runtime' "$ROOT/CLAUDE.md" &&
grep -Fq 'model is' "$ROOT/CLAUDE.md" &&
grep -Fq 'semantic intent authority' "$ROOT/CLAUDE.md" &&
grep -Fq 'Prompt hooks attach identity and guidance only; they never retrieve evidence.' "$ROOT/CLAUDE.md" ||
  fail "global routing contract does not make model-led Runtime recall authoritative"
grep -Fq '/activity`, `/dashboard`, and `/project`' "$ROOT/CLAUDE.md" ||
  fail "status surfaces may still hijack specific continuation recall"
grep -Fq 'Explained syntheses of current organizational work' "$ROOT/CLAUDE.md" ||
  fail "analytical team questions may still be routed to a status card"
grep -Fq 'Do not run retrieval on unrelated prompts' "$ROOT/CLAUDE.md" ||
  fail "global routing contract does not preserve unrelated-prompt latency"
grep -Fq 'reuse its authorized evidence' "$ROOT/CLAUDE.md" ||
  fail "global contract does not retain precompiled evidence"
grep -Fq 'Never relax the date boundary' "$ROOT/CLAUDE.md" ||
  fail "global contract permits date-boundary relaxation"
grep -Fq 'Never infer graph' "$ROOT/CLAUDE.md" ||
  fail "global routing contract still permits intent-inferred graph retrieval"
! grep -Fq 'current work addressed to someone → `bash bin/graph-op.sh open-handoffs' "$ROOT/CLAUDE.md" ||
  fail "common handoff recall still routes directly to graph"
grep -Fq 'bash "$SCRIPT_DIR/bin/activity-data.sh"' "$ROOT/bin/lib/context.sh" &&
! grep -Fq 'graph-op.sh" open-handoffs' "$ROOT/bin/lib/context.sh" ||
  fail "startup handoff hydration still bypasses canonical Runtime status"
for skill in "$ROOT/.claude/skills/search/SKILL.md"; do
  grep -Fq 'reuse evidence already in context' "$skill" &&
  grep -Fq '8 discoveries, 20 source windows' "$skill" &&
  grep -Fq 'bin/search.sh find' "$skill" ||
    fail "canonical search workflow lacks retained, bounded Runtime investigation"
done
grep -Fq 'model decides from meaning, not trigger phrases' "$ROOT/.claude/skills/search/SKILL.md" ||
  fail "canonical search workflow still relies on phrase matching for semantic recall"
grep -Fq 'maintained body is `.claude/skills/search/SKILL.md`' "$ROOT/.codex/skills/search/SKILL.md" ||
  fail "search adapter does not run the canonical workflow"
grep -Fq 'Do not `cd` into the sibling memory repository.' "$ROOT/CLAUDE.md" ||
  fail "global routing contract still permits absolute sibling-memory traversal"
grep -Fq 'or direct QMD' "$ROOT/.claude/skills/search/SKILL.md" ||
  fail "Claude search skill permits a raw retrieval bypass"

jq -e '.permissions.additionalDirectories | index("memory") != null' "$ROOT/.claude/settings.json" >/dev/null ||
  fail "Claude does not register memory as an additional working directory"
jq -e '.permissions.allow | index("Bash(bash bin/search.sh investigate:*)") != null' "$ROOT/.claude/settings.json" >/dev/null ||
  fail "Claude auto mode is missing a narrow permission for Egregore search"
jq -e '.hooks.UserPromptSubmit[].hooks[].command | select(contains("bin/observe-context.sh claude"))' "$ROOT/.claude/settings.json" >/dev/null ||
  fail "Claude normal prompts do not enter the Observe context adapter"
jq -e '.hooks.UserPromptSubmit[].hooks[].command | select(contains("bin/observe-context.sh") and contains("codex"))' "$ROOT/.codex/hooks.json" >/dev/null ||
  fail "Codex normal prompts do not enter the Observe context adapter"

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

grep -Fq 'bin/observe-context.sh' "$ROOT/.claude/hooks/search-hint.sh" &&
  ! grep -Fq 'FIRST action:' "$ROOT/.claude/hooks/search-hint.sh" ||
  fail "Claude compatibility hook still injects a duplicate search instruction"
grep -Fq 'bin", "observe-context.sh' "$ROOT/.codex/hooks/search-hint.js" &&
  ! grep -Fq 'FIRST action:' "$ROOT/.codex/hooks/search-hint.js" ||
  fail "Codex compatibility hook still injects a duplicate search instruction"

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
  grep -Fq 'generated-by: bin/codex-sync-skills.sh' "$packaged_search" &&
    grep -Fq 'maintained body is `.claude/skills/search/SKILL.md`' "$packaged_search" ||
    fail "packaged $runtime search adapter does not run the canonical workflow"
  # Runtime bundles may omit the canonical tree: installed instances are
  # framework clones and resolve this pointer in their framework checkout.
  packaged_search="$ROOT/.claude/skills/search/SKILL.md"
  grep -Fq "$BEAT" "$packaged_search" ||
    fail "packaged $runtime search skill is missing the retrieval beat"
  grep -Fq 'assistant line' "$packaged_search" ||
    fail "packaged $runtime search skill permits a hidden retrieval beat"
done

echo "PASS: Egregore search beat is product-attributed across Claude, Codex, and Pi"
