#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CODEX_DIR="$ROOT/.codex/skills"
RENDER="$ROOT/bin/codex-skill-render.mjs"

NATIVE_SKILLS=(
  activity
  handoff
  wrap
  announce
  harvest
  the-spiral
  dashboard
  deep-reflect
  quest
  invite
  ask
  save
)

STRUCTURED_UX_SKILLS=(
  activity
  dashboard
  handoff
  wrap
  todo
  quest
  project
  issue
  test
  qa
  checkup
  infra
  graph-maintain
  telemetry-admin
  waitlist
  hosting
  review-pr
  triage
  eval
  eval-multiagent
  summon
  reflect
  deep-reflect
  archive
  meeting
  ingest-user-interview
  harvest
  tutorial
  onboarding
  emissary
  launch-site
  view
  visual-explain
  tui-design
)

for skill in "${NATIVE_SKILLS[@]}"; do
  file="$CODEX_DIR/$skill/SKILL.md"
  [ -f "$file" ] || { echo "missing native skill: $skill" >&2; exit 1; }
  ! grep -q 'generated-by: bin/codex-sync-skills.sh' "$file" || { echo "native skill is generated: $skill" >&2; exit 1; }
  ! grep -qiE 'Codex adapter|canonical.*\.claude/skills|read .*\.claude/skills|\.claude/skills/.*canonical' "$file" || {
    echo "native skill points at Claude skill as canonical: $skill" >&2
    exit 1
  }
  ! grep -qE 'EnterWorktree|AskUserQuestion|askUserQuestionsTool' "$file" || {
    echo "native skill contains Claude-only primitive: $skill" >&2
    exit 1
  }
  description_line="$(awk '/^description:/ { print; exit }' "$file")"
  echo "$description_line" | grep -q "\$$skill" || {
    echo "native skill description is missing \$$skill skill token: $skill" >&2
    exit 1
  }
done

native_count=0
for skill in "${NATIVE_SKILLS[@]}"; do
  [ -f "$CODEX_DIR/$skill/SKILL.md" ] && native_count=$((native_count + 1))
done
[ "$native_count" -eq 12 ]

adapter_count="$(grep -rl 'generated-by: bin/codex-sync-skills.sh' "$CODEX_DIR"/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
[ "${adapter_count:-0}" -gt 0 ] || { echo "expected generated adapter skills" >&2; exit 1; }

while IFS= read -r adapter_file; do
  description_line="$(awk '/^description:/ { print; exit }' "$adapter_file")"
  echo "$description_line" | grep -Eq "^description: ['\"]" || {
    echo "generated adapter description is not YAML-quoted: ${adapter_file#$ROOT/}" >&2
    exit 1
  }
done < <(grep -rl 'generated-by: bin/codex-sync-skills.sh' "$CODEX_DIR"/*/SKILL.md 2>/dev/null)

for skill in "${STRUCTURED_UX_SKILLS[@]}"; do
  # Skills whose Claude source is not in this distribution (internal-only
  # skills are excluded from the public template) have no adapter either.
  [ -f "$ROOT/.claude/skills/$skill/SKILL.md" ] || continue
  file="$CODEX_DIR/$skill/SKILL.md"
  [ -f "$file" ] || { echo "missing structured UX skill: $skill" >&2; exit 1; }
  grep -q 'Structured UX parity' "$file" || {
    echo "structured UX skill is missing parity instructions: $skill" >&2
    exit 1
  }
done

bash "$ROOT/bin/codex-sync-skills.sh" --check >/tmp/codex-sync-check.out

card="$(bash "$ROOT/bin/codex-session-start.sh" --card)"
! echo "$card" | grep -q 'egregore-site:'
! echo "$card" | grep -q 'egregore-videos:'
! echo "$card" | grep -q 'codex harness active'
! echo "$card" | grep -q 'Codex skills:'
! echo "$card" | grep -q 'More skills:'
! echo "$card" | grep -q 'Trusted Codex:'
! echo "$card" | grep -q 'Adapter skills:'

prompt="$(bash "$ROOT/bin/codex-session-start.sh" --prompt)"
echo "$prompt" | grep -q 'Trusted Codex: full shell/network access is enabled'
echo "$prompt" | grep -q 'Codex reserves leading slash commands for built-ins'
echo "$prompt" | grep -q 'adapter skills'
echo "$prompt" | grep -q '\$activity'
echo "$prompt" | grep -q '\$deep-reflect'
echo "$prompt" | grep -q '\$save'

! grep -q 'UserPromptSubmit' "$ROOT/.codex/hooks.json" || {
  echo "UserPromptSubmit hook must not be installed; it creates visible hook-completed transcript noise" >&2
  exit 1
}
! grep -q 'prompt-context.js' "$ROOT/.codex/hooks.json" || {
  echo "prompt-context hook must not be installed" >&2
  exit 1
}
grep -q 'PreToolUse' "$ROOT/.codex/hooks.json"
grep -q 'branch-guard.js' "$ROOT/.codex/hooks.json"

initial='{"graph_status":"offline","graph_reason":"unreachable"}'
retry_connected='{"graph_status":"connected"}'
retry_offline='{"graph_status":"offline","graph_reason":"unreachable"}'

echo "$initial" | node "$RENDER" classify-graph --mode connected | grep -q '"status":"retry"'
echo "$initial" | node "$RENDER" classify-graph --mode connected | grep -q '"retry":true'
echo "$retry_connected" | node "$RENDER" classify-graph --mode connected --attempt retry | grep -q '"status":"connected"'
echo "$retry_offline" | node "$RENDER" classify-graph --mode connected --attempt retry | grep -q '"status":"offline"'
echo "$retry_offline" | node "$RENDER" classify-graph --mode connected --attempt retry | grep -q '"retry":false'

echo "codex native skills ok"
