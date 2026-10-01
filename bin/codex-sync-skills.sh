#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="$SCRIPT_DIR/.claude/skills"
CODEX_DIR="$SCRIPT_DIR/.codex/skills"
CHECK=0

# Full source checkouts use the capability inventory. Public installs omit the
# development manifest/engine, so inspect only their delivered file union and
# never reconstruct an unknown missing implementation from a source file.
NATIVE_SKILLS=()
native_total=0
OWNED_SKILLS=()
INSTALLED_SUBSET=0
LIST_NATIVE=0

STRUCTURED_UX_SKILLS=(
  handoff-staircase
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

GENERATED_MARKER='generated-by: bin/codex-sync-skills.sh'

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --list-native) LIST_NATIVE=1; shift ;;
    --help|-h)
      echo "usage: bin/codex-sync-skills.sh [--check|--list-native]"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -f "$SCRIPT_DIR/bin/capability-distribution.mjs" ] && [ -f "$SCRIPT_DIR/capability-distribution.json" ]; then
  inventory="$(bash "$SCRIPT_DIR/bin/node-run.sh" "$SCRIPT_DIR/bin/capability-distribution.mjs" skill-inventory --root "$SCRIPT_DIR")"
else
  INSTALLED_SUBSET=1
  inventory="$(bash "$SCRIPT_DIR/bin/node-run.sh" - "$SCRIPT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const config = path.join(root, 'egregore.json');
const owned = new Set(fs.existsSync(config) ? JSON.parse(fs.readFileSync(config, 'utf8')).owned_skills || [] : []);
const names = new Set();
for (const runtime of ['.claude', '.codex']) {
  const dir = path.join(root, runtime, 'skills');
  if (!fs.existsSync(dir)) continue;
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    if (entry.isDirectory() && fs.existsSync(path.join(dir, entry.name, 'SKILL.md'))) names.add(entry.name);
  }
}
for (const name of [...names].sort()) {
  const file = path.join(root, '.codex/skills', name, 'SKILL.md');
  const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  const owner = owned.has(name) ? 'org' : 'framework';
  const type = text.includes('generated-by: bin/codex-sync-skills.sh') ? 'generated'
    : owner === 'org' && text.includes('org-owned skill adapter') ? 'pointer' : 'native';
  process.stdout.write(`${name}\t${type}\t${owner}\n`);
}
NODE
)"
fi
while IFS=$'\t' read -r name implementation owner; do
  [ -n "$name" ] || continue
  [ "$owner" != "org" ] || OWNED_SKILLS+=("$name")
  if [ "$implementation" = "native" ]; then
    NATIVE_SKILLS+=("$name")
    native_total=$((native_total + 1))
  fi
done <<< "$inventory"
if [ "$LIST_NATIVE" = "1" ]; then
  for name in ${NATIVE_SKILLS[@]+"${NATIVE_SKILLS[@]}"}; do printf '%s\n' "$name"; done
  exit 0
fi

is_owned() {
  local owned
  for owned in ${OWNED_SKILLS[@]+"${OWNED_SKILLS[@]}"}; do
    [ "$1" = "$owned" ] && return 0
  done
  return 1
}

is_native() {
  local name="$1"
  local native
  for native in ${NATIVE_SKILLS[@]+"${NATIVE_SKILLS[@]}"}; do
    [ "$name" = "$native" ] && return 0
  done
  return 1
}

is_structured_ux() {
  local name="$1"
  local structured
  for structured in "${STRUCTURED_UX_SKILLS[@]}"; do
    [ "$name" = "$structured" ] && return 0
  done
  return 1
}

skill_description() {
  local file="$1"
  awk '
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { exit }
    in_fm && /^description:/ {
      sub(/^description:[[:space:]]*/, "")
      # Block scalars (description: >) keep the text on continuation lines we
      # do not read. Emit nothing so the caller falls back, which the skill-v1
      # contract check reports, rather than publishing the indicator itself.
      if ($0 ~ /^[>|][-+]?[[:space:]]*$/) { exit }
      if ($0 ~ /^".*"$/) { gsub(/^"|"$/, "") }
      else if ($0 ~ /^\047.*\047$/) { gsub(/^\047|\047$/, ""); gsub(/\047\047/, "\047") }
      print
      exit
    }
  ' "$file"
}

yaml_single_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/''/g")"
}

render_adapter() {
  local name="$1"
  local source="$2"
  local description="$3"
  local structured="$4"
  [ -n "$description" ] || description="Fallback Codex adapter for the Egregore ${name} workflow."
  local description_yaml
  description_yaml="$(yaml_single_quote "$description")"
  cat <<EOF
---
name: ${name}
description: ${description_yaml}
---

<!-- ${GENERATED_MARKER} -->

# Egregore ${name} Adapter

This adapter runs the canonical Egregore workflow for \`${name}\`. Its one
maintained body is \`${source}\`; read that file completely and follow it here.

Use the project shell and filesystem directly. Do not invoke Claude Code
commands. Translate interactive choices to structured Codex question tooling
when it is available; otherwise render compact numbered choices with an
\`Other:\` option and wait for the user.

EOF
  if [ "$structured" = "1" ]; then
    cat <<EOF
## Structured UX parity

This workflow has a Claude skill with user-visible structured output. After
reading \`${source}\`, reproduce the same visible UX in Codex:

- Preserve TUI boxes, markdown tables, rich cards, browser artifact rendering,
  exact confirmation blocks, and "no preamble" rules from the source skill.
- Use the source skill's frame width, section order, labels, status footer,
  and examples as the contract for the final response.
- Never replace a required box/table/card/artifact view with a prose summary
  unless the user explicitly asks for a summary.
- When the source says to output a TUI box directly, paste that box as the
  visible response, preferably in a \`text\` fenced block.
- If the canonical body says the command's stdout is the card and must not
  be repeated, that rule assumes a host that displays command output in full;
  in Codex, paste the card once as the visible response in a \`text\` fenced
  block and do not print it a second time.
- Never show raw JSON, raw command output, or unformatted script output when
  the source skill requires formatted status or rendered output.

EOF
  fi
  cat <<EOF
1. Read \`${source}\` for the workflow details.
2. Run the referenced \`bin/\` scripts directly from Codex.
3. Treat graph and publish steps as best-effort unless that workflow explicitly
   says they are required.
4. For every external notification, follow
   \`.claude/context/notification-consent.md\`: plan without sending, then show
   a separate exact Send / Edit / Cancel checkpoint. Never infer notification
   consent from the workflow request or a batch approval.
5. Keep local-mode behavior filesystem-first and avoid graph or notification
   calls when \`egregore.json\` declares \`"mode": "local"\`.
6. Never call the deprecated \`egregore-handoff\` CLI for Egregore project
   handoffs.
EOF
}

[ -d "$CLAUDE_DIR" ] || { echo "missing Claude skills directory: $CLAUDE_DIR" >&2; exit 1; }
mkdir -p "$CODEX_DIR"

changed=0
missing=0
native_present=0
adapter_present=0

for native in ${NATIVE_SKILLS[@]+"${NATIVE_SKILLS[@]}"}; do
  if [ -f "$CODEX_DIR/$native/SKILL.md" ]; then
    native_present=$((native_present + 1))
  else
    echo "missing native Codex skill: $native" >&2
    missing=1
  fi
done

# Unknown missing files cannot safely be treated as generated adapters. A
# runtime reinstall restores their recorded implementations. Ownership always
# wins, including an owned file that still bears an old generated marker.
while IFS=$'\t' read -r name implementation owner; do
  [ -n "$name" ] || continue
  if [ ! -f "$CLAUDE_DIR/$name/SKILL.md" ] || { [ ! -f "$CODEX_DIR/$name/SKILL.md" ] && { [ "$INSTALLED_SUBSET" = "1" ] || [ "$owner" = "org" ]; }; }; then
    echo "missing skill counterpart: $name — restore the installed runtime or both org-owned files" >&2
    missing=1
  fi
done <<< "$inventory"
[ "$missing" = "0" ] || exit 1

while IFS= read -r source_file; do
  name="$(basename "$(dirname "$source_file")")"
  is_native "$name" && continue
  is_owned "$name" && continue

  target_dir="$CODEX_DIR/$name"
  target_file="$target_dir/SKILL.md"
  if [ -f "$target_file" ] && ! grep -q "$GENERATED_MARKER" "$target_file" 2>/dev/null; then
    continue
  fi

  description="$(skill_description "$source_file")"
  rel_source=".claude/skills/$name/SKILL.md"
  structured=0
  is_structured_ux "$name" && structured=1
  tmp="$(mktemp -t codex-skill-adapter-XXXXXX)"
  render_adapter "$name" "$rel_source" "$description" "$structured" > "$tmp"

  if [ ! -f "$target_file" ] || ! cmp -s "$tmp" "$target_file"; then
    changed=1
    if [ "$CHECK" = "1" ]; then
      echo "adapter out of date: $name"
    else
      mkdir -p "$target_dir"
      cp "$tmp" "$target_file"
      echo "generated adapter: $name"
    fi
  fi
  rm -f "$tmp"
done < <(find "$CLAUDE_DIR" -mindepth 2 -maxdepth 2 -name SKILL.md | sort)

adapter_present="$({ grep -rl "$GENERATED_MARKER" "$CODEX_DIR"/*/SKILL.md 2>/dev/null || true; } | wc -l | tr -d ' ')"

if [ "$CHECK" = "1" ] && [ "$changed" -ne 0 ]; then
  echo "codex skills out of sync (native: $native_present/$native_total, adapters: $adapter_present)" >&2
  exit 1
fi

echo "codex skills synced (native: $native_present/$native_total, adapters: $adapter_present)"
