#!/usr/bin/env bash
# Post-update migrations for Egregore framework.
#
# This script is synced from upstream on every /update. All migration
# logic lives here — not in the /update skill itself. This avoids the
# chicken-and-egg problem: the dumb syncer pulls this script, then
# this script handles whatever needs to happen.
#
# Migrations must be idempotent — they run on every update.

set -euo pipefail

MIGRATED=0

# --- Migration: commands → skills (CC 2.0+) ---
# CC 2.0 dropped .claude/commands/ support. If skills exist (synced from
# upstream) and commands still exist locally, remove commands to prevent
# duplicate entries in the slash menu.
if [ -d ".claude/skills" ] && [ -d ".claude/commands" ]; then
  CC_MAJOR=$(claude --version 2>/dev/null | grep -oE '^[0-9]+' || echo "0")
  if [ "${CC_MAJOR:-0}" -ge 2 ]; then
    git rm -r .claude/commands/ 2>/dev/null || rm -rf .claude/commands/
    echo "  ✓ Removed .claude/commands/ (migrated to skills)"
    MIGRATED=1
  fi
fi

# --- Future migrations go here ---
# Each migration should:
# 1. Check if it needs to run (idempotent guard)
# 2. Do the work
# 3. Echo a status line
# 4. Set MIGRATED=1

if [ "$MIGRATED" -eq 0 ]; then
  echo "  ✓ No migrations needed"
fi
