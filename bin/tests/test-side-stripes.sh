#!/usr/bin/env bash
set -uo pipefail

# Test: side-stripe ratchet (bin/tests/side-stripes.mjs).
# No coloured stripe down one side of a box, and no accent edge along its
# top or bottom, in canonical source: reading
# emphasis is a marker, a margin label or a hanging quote; status is a quiet
# panel with a shaped label (packages/egregore-artifacts/lib/recipe.js). The
# live tree sits at the ceiling, every detector form is still caught, lines
# that are structure stay allowed, rail exemptions cannot go stale, the scan
# reads every surface it claims to, and the design guidance names the recipe.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR" || exit 1
scan() { bash bin/node-run.sh bin/tests/side-stripes.mjs "$@"; }
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Testing: side-stripe ratchet"
echo ""

# ============================================================
# 1. The live tree is at the ceiling
# ============================================================
OUT="$(scan 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && pass "live tree: within the ceiling" || fail "live tree: side stripes above the ceiling" "$OUT"
grep -q 'side-stripes: 0 finding(s), ceiling 0' <<< "$OUT" \
  && pass "live tree: 0 findings, ceiling 0" \
  || fail "live tree: expected 0 findings at ceiling 0" "$OUT"

# ============================================================
# 2. Canary: every detector form is caught, in every source language
# ============================================================
cat > "$TMP/canary.css" <<'EOF'
.a{border-left:3px solid var(--t1)}
.b{border-right:1px solid var(--accent)}
.c{border-inline-start:2px solid var(--line)}
.d{border-left-color:var(--ok)}
.e{border-left-width:4px}
.f{border-width:0 0 0 3px;border-style:solid}
.g{box-shadow:inset 3px 0 0 var(--terracotta)}
.h{box-shadow:0 1px 2px var(--shadow),inset -4px 0 0 var(--warn)}
.i::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--t1)}
.j::after{content:"";position:absolute;right:0;top:0;height:100%;width:4px;background:var(--critical)}
.k{border-left:1px solid #d4875a}
.l{border-left:3px solid var(--line);border-bottom:1px solid var(--line)}
.m{border-inline-end:1px dashed var(--note)}
.n{border-top:3px solid var(--t1)}
.o{border-bottom:2px solid var(--line)}
.p{border-bottom:1px solid var(--accent)}
.q{border-block-end-color:var(--warn)}
.r{border-width:3px 0 0 0;border-style:solid}
.s{box-shadow:inset 0 -2px 0 var(--accent)}
.nav a{border-bottom:2px solid var(--crimson)}
EOF
cat > "$TMP/canary.jsx" <<'EOF'
const quote = <blockquote style={{ borderLeft: `2px solid ${C.gold}` }} />;
const item = <li style={{ borderInlineStart: '3px solid var(--t1)' }} />;
const bar = { boxShadow: 'inset 3px 0 0 var(--accent)' };
row.style.borderLeftColor = 'var(--warn)';
const tab = { borderBottom: active ? '2px solid var(--accent)' : 'none' };
const card = <div style={{ borderTop: `2px solid ${C.gold}` }} />;
const lid = { boxShadow: 'inset 0 3px 0 var(--ok)' };
EOF
cat > "$TMP/canary.py" <<'EOF'
CSS = f"""
.hero {{ border-left: 3px solid var(--terracotta); }}
"""
HTML = '<div style="border-left:4px solid var(--t2)">x</div>'
BANNER = b'<aside style="border-bottom:2px solid #ea580c">x</aside>'
EOF
cat > "$TMP/canary.html" <<'EOF'
<style>.x{border-inline-end:2px solid var(--note)}</style>
<div style="border-right: 3px solid var(--warn)"></div>
<div style="border-top: 4px solid var(--critical)"></div>
EOF
cat > "$TMP/canary.md" <<'EOF'
Prose that names border-left: 3px solid is not code and is not read.
```css
.callout { border-left: 3px solid var(--t2); }
```
EOF
OUT="$(cd "$TMP" && bash "$SCRIPT_DIR/bin/node-run.sh" "$SCRIPT_DIR/bin/tests/side-stripes.mjs" --files canary.css canary.jsx canary.py canary.html canary.md 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && pass "canary: exits non-zero above the ceiling" || fail "canary: stripes passed" "$OUT"
HITS="$(grep -cE '^canary\.' <<< "$OUT")"
[ "$HITS" -eq 34 ] && pass "canary: all 34 stripes found" || fail "canary: expected 34 findings, got $HITS" "$OUT"
for expected in \
  'canary.css:1: side-border' 'canary.css:2: side-border' 'canary.css:3: side-border' \
  'canary.css:4: side-border' 'canary.css:5: side-border' 'canary.css:6: border-width' \
  'canary.css:7: inset-shadow' 'canary.css:8: inset-shadow' 'canary.css:9: pseudo-bar' \
  'canary.css:10: pseudo-bar' 'canary.css:11: side-border' 'canary.css:12: side-border' \
  'canary.css:13: side-border' \
  'canary.css:14: edge-border' 'canary.css:15: edge-border' 'canary.css:16: edge-border' \
  'canary.css:17: edge-border' 'canary.css:18: border-width' 'canary.css:19: inset-shadow' \
  'canary.css:20: edge-border: .nav a' \
  'canary.jsx:1: inline-style' 'canary.jsx:2: inline-style' 'canary.jsx:3: inline-style' \
  'canary.jsx:4: inline-style' 'canary.jsx:5: inline-style' 'canary.jsx:6: inline-style' \
  'canary.jsx:7: inline-style' \
  'canary.py:2: side-border' 'canary.py:4: side-border: [style]' 'canary.py:5: edge-border: [style]' \
  'canary.html:1: side-border' 'canary.html:2: side-border: [style]' 'canary.html:3: edge-border: [style]' \
  'canary.md:3: side-border'; do
  grep -qF "$expected" <<< "$OUT" \
    && pass "canary: names '$expected'" \
    || fail "canary: missing '$expected'" "$OUT"
done

# ============================================================
# 3. Structure stays allowed: hairline dividers (any side), link and field
#    underlines, glyphs, spinner arcs, dots, inset rails, comments
# ============================================================
cat > "$TMP/allowed.css" <<'EOF'
.m{border-right:1px solid var(--line)}
.n{border-left:1px solid var(--line-soft)}
.o{border-left:none}
.p{border-left:0}
.q{border-bottom:1px solid var(--line-soft)}
.qq{border-top:1px solid var(--rule)}
.r{box-shadow:inset 0 0 0 1px var(--line)}
.hi{box-shadow:inset 0 1px 0 rgba(255,255,255,.08)}
.bar{border-bottom:1px solid color-mix(in srgb,var(--artifact-ink) 12%,transparent)}
.links a:hover{border-bottom-color:var(--t1)}
dfn{border-bottom:1px dotted var(--accent)}
textarea:focus, input:focus{border-bottom-color:rgba(200,165,90,.5) !important}
.spin{border:2px solid var(--line);border-top-color:var(--accent);border-radius:50%}
.s{border-left:1px dotted rgba(59,45,33,.4)}
.t{border-left:1px solid var(--ink-faint)}
.tick::after{content:"";border-right:2px solid var(--card);border-bottom:2px solid var(--card)}
.elbow::before{content:"";border-left:1px solid var(--ink-faint);border-bottom:1px solid var(--ink-faint)}
.dot::before{content:"";position:absolute;left:0;top:4px;width:6px;height:6px;border-radius:50%;background:var(--ok)}
.rail::before{content:"";position:absolute;left:15px;top:0;bottom:0;width:2px;background:var(--line)}
/* .old{border-left:3px solid var(--t1)} */
EOF
cat > "$TMP/allowed.jsx" <<'EOF'
const cell = <td style={{ borderRight: `1px solid ${C.warmGray}` }} />;
const lift = { boxShadow: '0 1px 2px var(--shadow)' };
const row = { borderBottom: last ? 'none' : '1px solid var(--hairline)' };
const spinner = <div style={{ border: `2px solid ${C.warmGray}`, borderTopColor: C.crimson, borderRadius: "50%" }} />;
EOF
OUT="$(cd "$TMP" && bash "$SCRIPT_DIR/bin/node-run.sh" "$SCRIPT_DIR/bin/tests/side-stripes.mjs" --files allowed.css allowed.jsx 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && pass "allowed: dividers, underlines, glyphs, spinners, dots, inset rails and comments pass" || fail "allowed: false positive" "$OUT"

# ============================================================
# 4. Rail exemptions match their selector only; a stale exemption is a finding
# ============================================================
mkdir -p "$TMP/root/packages/egregore-artifacts/lib"
printf '%s\n' '.edi .chainline{border-left:2px solid var(--e-win-border)}' > "$TMP/root/packages/egregore-artifacts/lib/editorial.js"
OUT="$(scan --root "$TMP/root" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && pass "exemption: the named rail passes" || fail "exemption: the named rail was reported" "$OUT"
printf '%s\n' '.edi .callout{border-left:2px solid var(--e-accent)}' > "$TMP/root/packages/egregore-artifacts/lib/editorial.js"
OUT="$(scan --root "$TMP/root" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && pass "exemption: a stripe in an exempted file is still caught" || fail "exemption: covered the whole file" "$OUT"
grep -qF 'packages/egregore-artifacts/lib/editorial.js:1: side-border: .edi .callout' <<< "$OUT" \
  && pass "exemption: names the non-rail stripe" \
  || fail "exemption: non-rail stripe not reported" "$OUT"
grep -qF 'packages/egregore-artifacts/lib/editorial.js:0: stale exemption' <<< "$OUT" \
  && pass "stale exemption: names the rail that is gone" \
  || fail "stale exemption: not reported" "$OUT"
if grep -qF 'api/handoff_render.py' <<< "$OUT"; then
  fail "stale exemption: an exemption for a file this instance does not ship was reported" "$OUT"
else
  pass "stale exemption: an exemption for a file this instance does not ship is inert"
fi

# ============================================================
# 5. The scan reads every surface it claims to, and no frozen fixture
# ============================================================
LIST="$(scan --list 2>&1)"
COUNT="$(grep -c . <<< "$LIST")"
[ "$COUNT" -ge 50 ] && pass "scope: reads $COUNT files" || fail "scope: only $COUNT files read" "$LIST"
for file in packages/egregore-artifacts/lib/markdown.js packages/egregore-artifacts/lib/recipe.js \
  packages/egregore-artifacts/lib/templates/board.js packages/design-system/dist/egregore-design.css \
  .claude/skills/scroll/assets/shell.html .claude/skills/view/compose-scaffold.html \
  .claude/skills/cards/assets/template.html .claude/skills/session-view/template.html \
  .claude/skills/press/assets/style.css api/handoff_render.py api/oauth.py bin/ingest-surface.html \
  loom/dashboard/render.mjs threads/render/strand.py threads/render/weaver_dashboard.py \
  site/src/DocsPage.jsx site/src/ArticlePage.jsx; do
  [ -f "$file" ] || continue
  grep -qxF "$file" <<< "$LIST" && pass "scope: reads $file" || fail "scope: does not read $file"
done
if grep -qE '^packages/design-system/fixtures/live/|/vendor/design-system/fixtures/|^bin/dataroom-renders/|node_modules/' <<< "$LIST"; then
  fail "scope: reads a frozen fixture, a dataroom render or node_modules" "$(grep -E 'fixtures/|dataroom-renders/|node_modules/' <<< "$LIST" | head -5)"
else
  pass "scope: frozen fixtures, dataroom renders and node_modules stay out"
fi

# ============================================================
# 6. The design system's own guidance names the rule and the kit classes
#    (runtime skills are not pinned by wording; the scan above reads them)
# ============================================================
for file in packages/design-system/skill/SKILL.md; do
  [ -f "$file" ] || continue
  grep -qi 'no side stripes' "$file" && pass "guidance: $file forbids side stripes" || fail "guidance: $file does not forbid side stripes"
  for class in eg-mark eg-margin eg-quote eg-panel eg-label; do
    grep -qF "$class" "$file" || { fail "guidance: $file does not name .$class"; continue 2; }
  done
  pass "guidance: $file names the recipe classes"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
