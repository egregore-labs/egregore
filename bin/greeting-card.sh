#!/usr/bin/env bash
# greeting-card.sh — print the cached greeting card for external launchers.
#
# bin/session-start.sh writes the visible card here at the end of every boot
# in the main checkout (worktree boots don't write — their branch/status would
# clobber the main card). A launcher can print it instantly (data is at most
# one session stale), then start Claude Code with EGREGORE_CARD_SHOWN=1 so the
# session skips the in-chat re-render and the model replies with fresh signal
# lines only:
#
#   bash bin/greeting-card.sh 2>/dev/null
#   EGREGORE_CARD_SHOWN=1 claude "start"
#
# Exit 0 with the card on stdout when a fresh cached card exists; exit 1
# silently otherwise (first boot, stale cache >7 days, or a card written by a
# different framework version).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve the MAIN checkout — worktrees have .git as a file pointing into the
# main repo's .git/worktrees/. Must match session-start.sh's key derivation.
MAIN_PROJECT_DIR="$SCRIPT_DIR"
if [ -f "$SCRIPT_DIR/.git" ]; then
  WT_GITDIR=$(sed 's/^gitdir: //' "$SCRIPT_DIR/.git" 2>/dev/null || true)
  if [ -n "$WT_GITDIR" ]; then
    MAIN_PROJECT_DIR=$(cd "$WT_GITDIR/../../.." 2>/dev/null && pwd || echo "$SCRIPT_DIR")
  fi
fi

# The cache key carries the framework version (read from the same tree that
# writes the card) so a greeting format change invalidates old cards instead
# of replaying them.
FRAMEWORK_VERSION=$(sed -n 's/^FRAMEWORK_VERSION="\([^"]*\)".*/\1/p' "$SCRIPT_DIR/bin/session-start.sh" 2>/dev/null | head -1)
[ -n "$FRAMEWORK_VERSION" ] || exit 1

CARD_FILE="$HOME/.egregore/greeting-card-v${FRAMEWORK_VERSION}-$(echo -n "$MAIN_PROJECT_DIR" | cksum | cut -d' ' -f1)"
[ -s "$CARD_FILE" ] || exit 1
# Refuse cards older than 7 days — better a cold boot than week-old numbers.
[ -z "$(find "$CARD_FILE" -mtime +7 2>/dev/null)" ] || exit 1
cat "$CARD_FILE"
