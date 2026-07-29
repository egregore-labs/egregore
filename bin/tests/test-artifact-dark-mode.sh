#!/usr/bin/env bash
set -uo pipefail

# Test: egregore-artifacts dark mode — regression guard for PR #556.
# Ensures the document renderer emits no inline hex/rgba colors that
# dark mode CSS overrides cannot reach.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PKG_DIR="$SCRIPT_DIR/packages/egregore-artifacts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: artifact dark mode (PR #556)"
echo ""

# Ensure deps are present
if [ ! -d "$PKG_DIR/node_modules/react-dom" ]; then
  echo "  ⊘ react-dom not installed in $PKG_DIR — skipping"
  exit 0
fi

# --- Fixture ---
cat > "$TMP/doc.md" << 'MD'
---
title: Dark Mode Test
author: qa
---

Lead paragraph with **bold** and `code`.

## Section A

Body text.

- bullet one
- bullet two

## Section B

| col | val |
|-----|-----|
| a   | 1   |
MD

# --- Render ---
cd "$PKG_DIR"
if ! node --input-type=module -e "
  import { generateArtifact } from './lib/index.js';
  import fs from 'node:fs';
  const html = await generateArtifact('document', '$TMP/doc.md');
  fs.writeFileSync('$TMP/out.html', html);
" 2>"$TMP/err.log"; then
  fail "render failed" "$(cat "$TMP/err.log")"
  echo ""
  echo "$PASS passed, $FAIL failed"
  exit 1
fi
pass "document renders without error"

OUT="$TMP/out.html"

# --- 1. Theme scaffolding present ---
grep -q 'data-theme="light"' "$OUT" && pass "html has data-theme attribute" || fail "missing data-theme"
grep -q '\[data-theme="dark"\]' "$OUT" && pass "dark mode CSS override block present" || fail "missing dark override"
grep -q 'eg-theme-toggle' "$OUT" && pass "theme toggle button present" || fail "missing toggle button"
grep -q 'eg-theme-mode' "$OUT" && pass "localStorage key referenced" || fail "missing localStorage persistence"
grep -q 'prefers-color-scheme' "$OUT" && pass "OS preference detection present" || fail "missing prefers-color-scheme"
if grep -q "@media print" "$OUT" && awk '/@media print/,/^  }/' "$OUT" | grep -q "eg-theme-toggle.*display: none"; then
  pass "toggle hidden on print"
else
  fail "toggle not hidden on print"
fi

# --- 2. Body content has no inline hex/rgb in style="..." ---
# Allow rgba(255,255,255,...) on the terminal/code pre which is always dark.
BODY_START=$(grep -n '<body>' "$OUT" | head -1 | cut -d: -f1)
BAD=$(tail -n +"$BODY_START" "$OUT" \
  | grep -oE 'style="[^"]*"' \
  | grep -E '#[0-9a-fA-F]{3,8}|rgb\(' \
  | grep -v 'rgba(255,[[:space:]]*255,[[:space:]]*255' || true)
if [ -z "$BAD" ]; then
  pass "document body inline styles use var() only (no hex/rgb leakage)"
else
  fail "document body has hardcoded inline colors" "$BAD"
fi

# --- 3. Toggle cycle sanity ---
grep -q "MODES = \['light', 'auto', 'dark'\]" "$OUT" && pass "3-mode cycle defined" || fail "unexpected MODES order"

# --- 4. All non-document templates also emit only var() in their output ---
# Render each template type against minimal synthetic data and assert the
# same no-hex/rgb leakage property. Board/network have inline ROLE_COLORS /
# PRIORITY bars that are semantic, not theme surfaces — allow those.
node --input-type=module -e "
  import { renderToStaticMarkup } from 'react-dom/server';
  import fs from 'node:fs';
  import { boardTemplate } from './lib/templates/board.js';
  import { activityTemplate } from './lib/templates/activity.js';
  import { handoffTemplate } from './lib/templates/handoff.js';
  import { networkTemplate } from './lib/templates/network.js';

  const boardData = {
    title: 'T', date: '2026-04-14', updatedBy: 'qa',
    summary: { byPriority: { P0: 1, P1: 1, P2: 0, P3: 0 }, byStatus: { 'in-progress': 1, todo: 1, review: 0, done: 0 }, totalCards: 2 },
    activities: [{ id: 'a', label: 'Activity', cards: [
      { priority: 0, title: 'card', status: 'in-progress', owners: ['oz'] },
      { priority: 1, title: 'other', status: 'done', owners: [] },
    ]}],
    people: [{ name: 'oz', stats: { total: 1, p0: 1, inProgress: 1 }, cards: [] }],
    timeline: [], allCards: [],
  };
  const activityData = {
    title: 'A', date: '2026-04-14', me: 'qa', mySessions: [{date:'1', topic:'t'}],
    teamSessions: [], quests: [{name:'q', artifacts: 1, daysSince: 0}], prs: [],
    todos: { activeTodoCount: 0 }, handoffsToMe: [], pendingQuestions: [],
    trends: { cadence: [{sessions:1},{sessions:0}], recentCaptureRatio: 0.5 },
  };
  const handoffData = {
    title: 'H', date: '2026-04-14', author: 'qa', to: ['oz'],
    source: 's', branch: 'b', summary: 'hi', decisions: ['x'],
    openThreads: [{text:'t',done:false}], nextSteps: ['one'], entryPoints: ['e'],
  };
  const networkData = {
    title: 'N', date: '2026-04-14', updatedBy: 'qa',
    allRoles: ['Alpha Tester'], summary: { totalPeople: 1, byRole: {'Alpha Tester': 1} },
    people: [{ name: 'p', organization: 'org', roles: ['Alpha Tester'], notes: 'n' }],
  };

  const outputs = {
    board: renderToStaticMarkup(boardTemplate(boardData)),
    activity: renderToStaticMarkup(activityTemplate(activityData)),
    handoff: renderToStaticMarkup(handoffTemplate(handoffData)),
    network: renderToStaticMarkup(networkTemplate(networkData)),
  };
  fs.writeFileSync('$TMP/templates.json', JSON.stringify(outputs));
" 2>"$TMP/tmpl-err.log"
if [ ! -f "$TMP/templates.json" ]; then
  fail "template render batch failed" "$(cat "$TMP/tmpl-err.log")"
else
  pass "all template types render without error"
  # Scan each template's inline styles for hex/rgb leakage.
  # Allowed: rgba(255,255,255,…) on always-dark code pre; network ROLE_COLORS
  # applied as inline background (semantic node labels, not surfaces);
  # board PRIORITY bars already use var() so they won't match.
  for tmpl in board activity handoff network; do
    BODY=$(node --input-type=module -e "
      import fs from 'node:fs';
      const all = JSON.parse(fs.readFileSync('$TMP/templates.json', 'utf8'));
      process.stdout.write(all['$tmpl']);
    ")
    BAD=$(echo "$BODY" \
      | grep -oE 'style="[^"]*"' \
      | grep -E '#[0-9a-fA-F]{3,8}|rgb\(' \
      | grep -v 'rgba(255,[[:space:]]*255,[[:space:]]*255' \
      | grep -v 'background:#[0-9A-Fa-f]' \
      || true)
    if [ -z "$BAD" ]; then
      pass "$tmpl template uses var() only in inline styles"
    else
      # network intentionally ships role-label hex backgrounds — allow if the
      # only leakage is a background on a role badge.
      NON_ROLE=$(echo "$BAD" | grep -v 'background:#' || true)
      if [ "$tmpl" = "network" ] && [ -z "$NON_ROLE" ]; then
        pass "network template only leaks intentional role-badge hex (ok)"
      else
        fail "$tmpl template has hardcoded inline colors" "$BAD"
      fi
    fi
  done
fi

# --- 5. Pre-existing markdown loop regression: H1/H2 in body must terminate ---
if node --input-type=module -e "
  import { renderToStaticMarkup } from 'react-dom/server';
  import { renderMarkdown } from './lib/markdown.js';
  const el = renderMarkdown('# Title\\n\\npara\\n\\n## Sub\\n\\nbody');
  const html = renderToStaticMarkup(el);
  if (html.length < 20) { process.exit(1); }
" 2>/dev/null; then
  pass "renderMarkdown handles bare # and ## without infinite loop"
else
  fail "renderMarkdown still loops on bare # or ## lines"
fi

# --- Summary ---
echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
