#!/bin/bash
# Make Egregore's project-local Codex skills available without duplicating
# them in CODEX_HOME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$SCRIPT_DIR/.codex/skills"
HOOKS_FILE="$SCRIPT_DIR/.codex/hooks.json"
HOOKS_DIR="$SCRIPT_DIR/.codex/hooks"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
TARGET_DIR="$CODEX_HOME_DIR/skills"

[ -d "$SOURCE_DIR" ] || exit 0

# Current Codex discovers project skills via .agents/skills (and follows
# symlinks). The repo commits .agents/skills -> ../.codex/skills; repair it
# here for checkouts that lost the symlink (zip downloads, some Windows
# clones). Never clobber a real directory the user created.
AGENTS_DIR="$SCRIPT_DIR/.agents"
AGENTS_LINK="$AGENTS_DIR/skills"
if [ ! -e "$AGENTS_LINK" ] && [ ! -L "$AGENTS_LINK" ]; then
  mkdir -p "$AGENTS_DIR"
  ln -s ../.codex/skills "$AGENTS_LINK" 2>/dev/null || true
fi

is_egregore_skill() {
  local file="$1"
  [ -f "$file" ] || return 1
  grep -q 'Egregore' "$file" 2>/dev/null || return 1
  grep -Eq 'bin/agent\.sh|bin/activity-data\.sh|bin/codex-skill-render\.mjs|Native Codex|generated-by: bin/codex-sync-skills\.sh|\.claude/skills' "$file" 2>/dev/null
}

installed=0
for skill_dir in "$SOURCE_DIR"/*; do
  [ -d "$skill_dir" ] || continue
  [ -f "$skill_dir/SKILL.md" ] || continue
  installed=$((installed + 1))
done

# Current Codex loads project-local .codex/skills from --cd. Older Egregore
# builds copied the same skills globally, which makes Codex show duplicates.
# Default to local-only and remove legacy global copies that are recognizably
# Egregore-managed. Set EGREGORE_CODEX_INSTALL_GLOBAL=1 for older Codex builds.
if [ "${EGREGORE_CODEX_INSTALL_GLOBAL:-0}" != "1" ]; then
  removed=0
  if [ -d "$TARGET_DIR" ]; then
    for skill_dir in "$SOURCE_DIR"/*; do
      [ -d "$skill_dir" ] || continue
      [ -f "$skill_dir/SKILL.md" ] || continue
      name="$(basename "$skill_dir")"
      target="$TARGET_DIR/$name/SKILL.md"
      if cmp -s "$skill_dir/SKILL.md" "$target" 2>/dev/null || is_egregore_skill "$target"; then
        rm -rf "$TARGET_DIR/$name"
        removed=$((removed + 1))
      fi
    done
  fi
  hooks_ready=0
  if [ -f "$HOOKS_FILE" ] && [ -d "$HOOKS_DIR" ]; then
    hooks_ready=1
  fi
  echo "codex project skills ready: $installed (removed global duplicates: $removed; hooks ready: $hooks_ready)"
  exit 0
fi

mkdir -p "$TARGET_DIR"

copied=0
for skill_dir in "$SOURCE_DIR"/*; do
  [ -d "$skill_dir" ] || continue
  [ -f "$skill_dir/SKILL.md" ] || continue
  name="$(basename "$skill_dir")"
  mkdir -p "$TARGET_DIR/$name"
  cp -R "$skill_dir/." "$TARGET_DIR/$name/"
  copied=$((copied + 1))
done

echo "codex global skills installed: $copied"
