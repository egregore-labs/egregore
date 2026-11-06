#!/usr/bin/env bash
set -uo pipefail

# Test: brown palette guidance ratchet (bin/tests/palette-guidance.mjs).
# Always-loaded instructions and skill text carry no brown palette guidance;
# colors come from the design system registry. The live tree sits at the
# ceiling, the retired lines are still caught, allowed mentions stay allowed,
# exemptions cannot go stale, and the rewritten guidance points at the
# registry, with a fallback for instances that do not carry the design package.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR" || exit 1
scan() { bash bin/node-run.sh bin/tests/palette-guidance.mjs "$@"; }
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Testing: brown palette guidance ratchet"
echo ""

# ============================================================
# 1. The live tree is at or under the ceiling
# ============================================================
OUT="$(scan 2>&1)"; RC=$?
if grep -q 'palette-guidance: skipped' <<< "$OUT"; then
  # An instance without the design package or the renderer's vendored copy.
  echo "  – skipped: no design system registry in this instance"
  exit 0
fi
[ "$RC" -eq 0 ] && pass "live tree: within the ceiling" || fail "live tree: brown palette guidance above the ceiling" "$OUT"
grep -q 'palette-guidance: 0 finding(s), ceiling 0' <<< "$OUT" \
  && pass "live tree: 0 findings, ceiling 0" \
  || fail "live tree: expected 0 findings at ceiling 0" "$OUT"

# ============================================================
# 2. Canary: the retired guidance is caught, line by line
# ============================================================
# Lines 8-9 name a registry id only in passing (inside voice-bedrock, as the
# .ledger class); lines 10-14 carry a negation that does not govern the term.
cat > "$TMP/retired.md" <<'EOF'
In the visual palette it is warm-brown (#1D1611), not cold-black. Terracotta (#D4875A) as accent.
- `dark-mode` — browser CSS, warm palette, token system
- Warm character first: dark surfaces are brown-black, not blue-black and not pure black.
| `--cream` | `#F5F2ED` | `#1D1611` | Page background; inverted selection text in dark |
8. Selection highlight inversion. The highlight stays terracotta; selected text flips to the dark background color.
A single self-contained HTML file in the Egregore brand (cream + terracotta, LT Superior Serif headings,
Use a parchment ground for the hero.
Shared aesthetic: voice-bedrock (`.claude/rules/voice-bedrock.md`), a warm-brown ground with a terracotta accent.
Use `.ledger` rows on a parchment ground.
No cool greys: dark surfaces are brown-black.
Never use cool greys, always a warm-brown ground.
If the page has no chart, use a terracotta accent.
Instead of steel, use terracotta for the accent.
Not a cream card but a cream page.
EOF
OUT="$(scan --files "$TMP/retired.md" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && pass "canary: exits non-zero above the ceiling" || fail "canary: retired guidance passed" "$OUT"
HITS="$(grep -c 'retired.md:' <<< "$OUT")"
[ "$HITS" -eq 14 ] && pass "canary: all 14 retired lines found" || fail "canary: expected 14 findings, got $HITS" "$OUT"
for expected in 'retired.md:1: #1D1611' 'retired.md:2: warm palette' 'retired.md:3: brown-black' \
  'retired.md:5: terracotta' 'retired.md:6: terracotta' 'retired.md:7: parchment' \
  'retired.md:8: warm-brown' 'retired.md:9: parchment' 'retired.md:10: brown-black' \
  'retired.md:11: warm-brown' 'retired.md:12: terracotta' 'retired.md:13: terracotta' \
  'retired.md:14: cream'; do
  grep -qF "$expected" <<< "$OUT" \
    && pass "canary: names '$expected'" \
    || fail "canary: missing '$expected'" "$OUT"
done

# ============================================================
# 3. Allowed mentions: a named registered pair, a prohibition, a token name
# ============================================================
cat > "$TMP/allowed.md" <<'EOF'
In rendered visuals it comes from restraint, spacing and type, not a brown ground.
  `meridian` (vellum / nocturne — navigator's-chart, brass-decided) ·
  `agronomic` (loam / soil — warm earth, soil-green) ·
--cream:var(--paper); --black:var(--ink); --terracotta:var(--t1); --terracotta-soft:var(--t1-bg);
No brown, cream, parchment, brass or terracotta grounds.
   pair, and point the scaffold's meridian-only names (`--prussian*`, `--brass`) at role tokens.
No warm-brown, brown-black or terracotta ground.
Use steel instead of terracotta.
**Never** a brown ground.
The meridian pair's brass accent marks what is decided.
EOF
OUT="$(scan --files "$TMP/allowed.md" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && pass "allowed: named pairs, prohibitions and token names pass" || fail "allowed: false positive" "$OUT"

# ============================================================
# 4. Exemptions match their lines; a stale exemption is a finding
# ============================================================
mkdir -p "$TMP/root/.claude/skills/press"
printf '%s\n' 'A single self-contained HTML file styled by assets/style.css.' > "$TMP/root/.claude/skills/press/SKILL.md"
OUT="$(scan --root "$TMP/root" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && pass "stale exemption: exits non-zero" || fail "stale exemption: passed" "$OUT"
grep -qF '.claude/skills/press/SKILL.md:0: stale exemption' <<< "$OUT" \
  && pass "stale exemption: names the press exemption" \
  || fail "stale exemption: press exemption not reported" "$OUT"
if grep -qF '.claude/skills/create-video/SKILL.md' <<< "$OUT"; then
  fail "stale exemption: an exemption for a file this instance does not ship was reported" "$OUT"
else
  pass "stale exemption: an exemption for a file this instance does not ship is inert"
fi

# ============================================================
# 5. A skill that sends the model to the design CSS also names the copy that
#    downstream instances carry
# ============================================================
# Public and downstream instances do not ship packages/design-system; the
# renderer ships the same files under lib/vendor/design-system/.
CSS_SOURCE='packages/design-system/dist/egregore-design.css'
CSS_VENDORED='lib/vendor/design-system/dist/egregore-design.css'
CITING="$(grep -rlF --include='*.md' "$CSS_SOURCE" .claude/rules .claude/skills | sort)"
[ -n "$CITING" ] && pass "fallback: skills name the design CSS" || fail "fallback: no skill names $CSS_SOURCE"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  grep -qF "$CSS_VENDORED" "$file" \
    && pass "fallback: $file also names the vendored CSS" \
    || fail "fallback: $file names $CSS_SOURCE without the vendored copy"
done <<< "$CITING"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
