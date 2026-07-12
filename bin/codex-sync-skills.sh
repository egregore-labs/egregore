#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="$SCRIPT_DIR/.claude/skills"
CODEX_DIR="$SCRIPT_DIR/.codex/skills"
CHECK=0

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
  view
  scroll
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
  scroll
  visual-explain
  tui-design
)

GENERATED_MARKER='generated-by: bin/codex-sync-skills.sh'

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --help|-h)
      echo "usage: bin/codex-sync-skills.sh [--check]"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

is_native() {
  local name="$1"
  local native
  for native in "${NATIVE_SKILLS[@]}"; do
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
      gsub(/^"|"$/, "")
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

This is fallback coverage for a long-tail Egregore workflow that has not been
ported to a hand-written Codex-native skill yet.

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
- Never show raw JSON, raw command output, or unformatted script output when
  the source skill requires formatted status or rendered output.

EOF
  fi
  cat <<EOF
1. Read \`${source}\` for the workflow details.
2. Run the referenced \`bin/\` scripts directly from Codex.
3. Treat graph, publish, and notify steps as best-effort unless that workflow
   explicitly says they are required.
4. Keep local-mode behavior filesystem-first and avoid graph or notification
   calls when \`egregore.json\` declares \`"mode": "local"\`.
5. Never call the deprecated \`egregore-handoff\` CLI for Egregore project
   handoffs.
EOF
}

[ -d "$CLAUDE_DIR" ] || { echo "missing Claude skills directory: $CLAUDE_DIR" >&2; exit 1; }
mkdir -p "$CODEX_DIR"

changed=0
native_present=0
adapter_present=0

for native in "${NATIVE_SKILLS[@]}"; do
  if [ -f "$CODEX_DIR/$native/SKILL.md" ]; then
    native_present=$((native_present + 1))
  else
    echo "missing native Codex skill: $native" >&2
    changed=1
  fi
done

while IFS= read -r source_file; do
  name="$(basename "$(dirname "$source_file")")"
  is_native "$name" && continue

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
  echo "codex skills out of sync (native: $native_present/${#NATIVE_SKILLS[@]}, adapters: $adapter_present)" >&2
  exit 1
fi

echo "codex skills synced (native: $native_present/${#NATIVE_SKILLS[@]}, adapters: $adapter_present)"
