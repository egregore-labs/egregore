#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# This suite executes bin/codex-session-start.sh against the live repo. A
# real session start parks the checkout on the base branch (autosave + push
# + checkout in git-sync); from a test that rewrites the developer's working
# tree mid-run and poisons every later assertion. Render-only, mutate nothing.
export EGREGORE_GIT_SYNC_READONLY=1
CODEX_DIR="$ROOT/.codex/skills"
RENDER="$ROOT/bin/codex-skill-render.mjs"

# Inventory and sync share the same classification, including installed subsets.
NATIVE_SKILLS=()
native_inventory_count=0
native_listing="$(bash "$ROOT/bin/codex-sync-skills.sh" --list-native)"
while IFS= read -r skill; do
  if [ -n "$skill" ]; then
    NATIVE_SKILLS+=("$skill")
    native_inventory_count=$((native_inventory_count + 1))
  fi
done <<< "$native_listing"

# Framework names must remain pointers even if their manifest classification
# is accidentally changed back to native. Org-owned implementations, including
# framework name overrides, stay covered by the native loop below; installed
# subsets may omit the development manifest.
node - "$ROOT" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
function checkFrameworkPointers(root) {
  const manifestPath = path.join(root, 'capability-distribution.json');
  if (!fs.existsSync(manifestPath)) return;
  const configPath = path.join(root, 'egregore.json');
  const config = fs.existsSync(configPath)
    ? JSON.parse(fs.readFileSync(configPath, 'utf8')) : {};
  const ownedSkills = new Set(config.owned_skills || []);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  for (const component of Object.values(manifest.components)) {
    if (component.type !== 'skill' || ownedSkills.has(component.name)) continue;
    const file = path.join(root, '.codex/skills', component.name, 'SKILL.md');
    if (!fs.existsSync(file)) continue; // Missing files are checked by sync.
    const text = fs.readFileSync(file, 'utf8');
    if (!text.includes('generated-by: bin/codex-sync-skills.sh') &&
        !text.includes('org-owned skill adapter')) {
      throw new Error(`framework Codex skill must be a pointer: ${component.name}`);
    }
  }
}
checkFrameworkPointers(process.argv[2]);

// Exercise ownership precedence with the same guard used for the live tree.
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-pointer-contract-'));
try {
  const skillDir = path.join(fixture, '.codex/skills/activity');
  const skillFile = path.join(skillDir, 'SKILL.md');
  const configFile = path.join(fixture, 'egregore.json');
  fs.mkdirSync(skillDir, { recursive: true });
  fs.writeFileSync(path.join(fixture, 'capability-distribution.json'), JSON.stringify({
    components: { activity: { type: 'skill', name: 'activity', codex: 'native' } },
  }));
  fs.writeFileSync(skillFile, '# Organization-owned full implementation\n');
  const missingPointer = /framework Codex skill must be a pointer: activity/;
  assert.throws(() => checkFrameworkPointers(fixture), missingPointer, 'missing config means no owned skills');
  fs.writeFileSync(configFile, '{}');
  assert.throws(() => checkFrameworkPointers(fixture), missingPointer, 'missing owned_skills means no owned skills');
  fs.writeFileSync(configFile, JSON.stringify({ owned_skills: ['org-only'] }));
  assert.throws(() => checkFrameworkPointers(fixture), missingPointer, 'unowned framework bodies still require pointers');
  fs.writeFileSync(configFile, JSON.stringify({ owned_skills: ['activity'] }));
  assert.doesNotThrow(() => checkFrameworkPointers(fixture), 'org ownership overrides a framework name');
  fs.writeFileSync(configFile, JSON.stringify({ owned_skills: [] }));
  for (const marker of ['generated-by: bin/codex-sync-skills.sh', 'org-owned skill adapter']) {
    fs.writeFileSync(skillFile, `<!-- ${marker} -->\n`);
    assert.doesNotThrow(() => checkFrameworkPointers(fixture), 'framework pointers remain valid');
  }
} finally {
  fs.rmSync(fixture, { recursive: true, force: true });
}
NODE

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
  scroll
  visual-explain
  tui-design
)

for skill in ${NATIVE_SKILLS[@]+"${NATIVE_SKILLS[@]}"}; do
  file="$CODEX_DIR/$skill/SKILL.md"
  [ -f "$file" ] || { echo "missing native skill: $skill" >&2; exit 1; }
  ! grep -q 'generated-by: bin/codex-sync-skills.sh' "$file" || { echo "native skill is generated: $skill" >&2; exit 1; }
  ! grep -qE 'EnterWorktree|AskUserQuestion|askUserQuestionsTool' "$file" || {
    echo "native skill contains Claude-only primitive: $skill" >&2
    exit 1
  }
  grep -q '^## When to invoke$' "$file" || {
    echo "native skill has no invocation section: $skill" >&2
    exit 1
  }
done

[ -f "$CODEX_DIR/view/assets/compose-scaffold.html" ] || {
  echo "missing native view composition scaffold" >&2
  exit 1
}
if [ -f "$CODEX_DIR/scroll/SKILL.md" ]; then
[ -f "$CODEX_DIR/scroll/assets/shell.html" ] || {
  echo "missing native scroll shell" >&2
  exit 1
}
grep -q '\$scroll' "$CODEX_DIR/scroll/agents/openai.yaml"
! grep -q 'paste into Claude' "$CODEX_DIR/scroll/assets/shell.html"
fi
grep -q '\$view' "$CODEX_DIR/view/agents/openai.yaml"

native_count=0
for skill in ${NATIVE_SKILLS[@]+"${NATIVE_SKILLS[@]}"}; do
  [ -f "$CODEX_DIR/$skill/SKILL.md" ] && native_count=$((native_count + 1))
done
[ "$native_count" -eq "$native_inventory_count" ]

adapter_count="$(grep -rl 'generated-by: bin/codex-sync-skills.sh' "$CODEX_DIR"/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
[ "${adapter_count:-0}" -gt 0 ] || { echo "expected generated adapter skills" >&2; exit 1; }

while IFS= read -r adapter_file; do
  description_line="$(awk '/^description:/ { print; exit }' "$adapter_file")"
  grep -Eq "^description: ['\"]" <<< "$description_line" || {
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
  grep -Eq 'Structured UX parity|Runtime' "$file" || {
    echo "structured UX skill is missing parity instructions: $skill" >&2
    exit 1
  }
done

bash "$ROOT/bin/codex-sync-skills.sh" --check

# Exercise the real prompt branch with deterministic native inventories, without
# running live identity, Git sync, connector refresh, or other startup effects.
prompt_fixture="$(mktemp -d)"
trap 'rm -rf "$prompt_fixture"' EXIT
mkdir -p "$prompt_fixture/bin" "$prompt_fixture/home"
cat > "$prompt_fixture/bin/codex-sync-skills.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = "--list-native" ] || exit 1
cat "$(dirname "$0")/native-skills"
SH
sed -n '/^case "${1:---card}" in/,$p' "$ROOT/bin/codex-session-start.sh" > "$prompt_fixture/prompt.sh"
render_test_prompt() {
  # The fixture is a throwaway workspace: sandbox HOME so nothing registers under ~/.egregore.
  HOME="$prompt_fixture/home" SCRIPT_DIR="$prompt_fixture" ORG_NAME=Fixture AUTHOR=fixture bash "$prompt_fixture/prompt.sh" --prompt
}
: > "$prompt_fixture/bin/native-skills"
empty_prompt="$(render_test_prompt)"
grep -Fq 'Codex reserves leading slash commands for built-ins' <<< "$empty_prompt"
grep -Fq 'Every Egregore workflow is a $name skill whose adapter names the canonical workflow it runs.' <<< "$empty_prompt"
! grep -Fq 'Maintained native Codex skills:' <<< "$empty_prompt"
! grep -Eq '\$([^[:alnum:]_]|$)' <<< "$empty_prompt"
printf '%s\n' org-fixture org-second > "$prompt_fixture/bin/native-skills"
native_prompt="$(render_test_prompt)"
grep -Fq 'Maintained native Codex skills: $org-fixture, $org-second.' <<< "$native_prompt"
! grep -Eq '\$([^[:alnum:]_]|$)' <<< "$native_prompt"

# Preflight consumes that same inventory; it must accept zero natives, detect
# missing implementations, and fail closed if inventory resolution fails.
sed -n '/^# CHECK 5:/,/^# SUMMARY/p' "$ROOT/bin/preflight.sh" > "$prompt_fixture/preflight-native.sh"
cat > "$prompt_fixture/check-preflight.sh" <<'SH'
set -euo pipefail
SCRIPT_DIR="$1"
expected="$2"
violations=0
violation() { printf '%s\n' "$1"; violations=$((violations + 1)); }
bash() {
  [ "$2" = "--list-native" ] || return 2
  [ "${PREFLIGHT_INVENTORY_RC:-0}" -eq 0 ] || return "$PREFLIGHT_INVENTORY_RC"
  printf '%s\n' "${PREFLIGHT_NATIVE_LIST:-}"
}
. "$3"
[ "$violations" -eq "$expected" ]
SH
PREFLIGHT_NATIVE_LIST='' bash "$prompt_fixture/check-preflight.sh" "$ROOT" 0 "$prompt_fixture/preflight-native.sh" > "$prompt_fixture/preflight-output"
PREFLIGHT_NATIVE_LIST=view bash "$prompt_fixture/check-preflight.sh" "$ROOT" 0 "$prompt_fixture/preflight-native.sh" > "$prompt_fixture/preflight-output"
PREFLIGHT_NATIVE_LIST=codex-pointer-retirement-test-missing bash "$prompt_fixture/check-preflight.sh" "$ROOT" 1 "$prompt_fixture/preflight-native.sh" > "$prompt_fixture/preflight-output"
grep -Fq 'Native Codex skill declared but missing' "$prompt_fixture/preflight-output"
PREFLIGHT_INVENTORY_RC=1 bash "$prompt_fixture/check-preflight.sh" "$ROOT" 1 "$prompt_fixture/preflight-native.sh" > "$prompt_fixture/preflight-output"
grep -Fq 'Native skill inventory unavailable' "$prompt_fixture/preflight-output"

if [ "${1:-}" = "--skills-only" ]; then
  echo "codex native skill contracts ok"
  exit 0
fi

card="$(bash "$ROOT/bin/codex-session-start.sh" --card)"
! grep -q 'egregore-site:' <<< "$card"
! grep -q 'egregore-videos:' <<< "$card"
! grep -q 'codex harness active' <<< "$card"
! grep -q 'Codex skills:' <<< "$card"
! grep -q 'More skills:' <<< "$card"
! grep -q 'Trusted Codex:' <<< "$card"
! grep -q 'Adapter skills:' <<< "$card"
if jq -e '(.mode // "") != "local" and ((.api_url // "") | length > 0)' "$ROOT/egregore.json" >/dev/null 2>&1; then
  grep -q '◆ CONNECTED' <<< "$card"
else
  grep -q '◇ LOCAL' <<< "$card"
fi

prompt="$(bash "$ROOT/bin/codex-session-start.sh" --prompt)"
# grep -q can close its input as soon as it finds a match. Here-strings avoid
# treating a large prompt producer's SIGPIPE as a failed assertion under pipefail.
grep -q 'Trusted Codex: full shell/network access is enabled' <<< "$prompt"
grep -q 'Codex reserves leading slash commands for built-ins' <<< "$prompt"
grep -Fq 'Every Egregore workflow is a $name skill whose adapter names the canonical workflow it runs.' <<< "$prompt"
if [ "$native_inventory_count" -eq 0 ]; then
  ! grep -Fq 'Maintained native Codex skills:' <<< "$prompt"
else
  grep -Fq 'Maintained native Codex skills:' <<< "$prompt"
fi
! grep -Eq '\$([^[:alnum:]_]|$)' <<< "$prompt"
for skill in ${NATIVE_SKILLS[@]+"${NATIVE_SKILLS[@]}"}; do
  grep -Fq "\$$skill" <<< "$prompt" || {
    echo "startup prompt omitted installed native skill: $skill" >&2
    exit 1
  }
done

# UserPromptSubmit hooks create visible hook-completed transcript noise
# (removed 2026-06-01, 74ea0ced). observe-context.sh is the one sanctioned
# exception: it compiles bounded authorized context and stays silent on
# non-matching prompts. Any OTHER prompt hook still fails.
prompt_hooks="$(node -e '
  const j = require("'"$ROOT"'/.codex/hooks.json");
  for (const m of j.hooks.UserPromptSubmit || [])
    for (const h of m.hooks || []) console.log(h.command);
')"
if grep -qv -e '^$' -e 'observe-context.sh' <<< "$prompt_hooks"; then
  echo "unexpected UserPromptSubmit hook installed (only observe-context.sh is sanctioned); prompt hooks create visible transcript noise" >&2
  exit 1
fi
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

activity_with_handoff='{"org":"Curve Labs","date":"Jul 06","graph_status":"connected","handoffs_to_me":[{"author":"oguzhan","topic":"Ripcord: PR review checklist rules","status":"pending","intent":"action","ageDays":8}]}'
echo "$activity_with_handoff" | node "$RENDER" activity-card - | grep -q '\[1\] ● ⇌ oguzhan: Ripcord: PR review checklist'
echo "$activity_with_handoff" | node "$RENDER" activity-card - | grep -q 'Handoff actions: done N · expire N · reopen N'
activity_with_question='{"org":"Curve Labs","date":"Jul 06","graph_status":"connected","pending_questions":[{"from":"cem","topic":"launch-strategy"}]}'
echo "$activity_with_question" | node "$RENDER" activity-card - | grep -q '● cem: launch-strategy'

echo "codex native skills ok"
