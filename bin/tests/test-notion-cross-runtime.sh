#!/usr/bin/env bash
set -uo pipefail

# Test: the Notion connector works on every runtime it claims (Claude, Codex, Pi)
#       and its mechanics stay runtime-neutral.
# Covers: .claude/skills/{connect,ingest,ingest-notion}/SKILL.md, bin/connector-notion.sh,
#         bin/connector-notion/, bin/ingest_graph.py, capability-distribution.json,
#         .pi/settings.json corpus wiring.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; return 0; }

echo "test-notion-cross-runtime"
echo ""

# --- 1. Claude Code -----------------------------------------------------------

for f in ".claude/skills/ingest-notion/SKILL.md" ".claude/skills/notion-connect/SKILL.md" "bin/connector-notion.sh" "bin/connector-notion/src/index.ts"; do
  if [ -f "$ROOT/$f" ]; then
    pass "Claude: $f exists"
  else
    fail "Claude: $f is missing"
  fi
done

if [ -x "$ROOT/bin/connector-notion.sh" ]; then
  pass "Claude: bin/connector-notion.sh is executable"
else
  fail "Claude: bin/connector-notion.sh is not executable"
fi

if grep -q 'notion ...' "$ROOT/.claude/skills/ingest/SKILL.md"; then
  pass "Claude: /ingest routes notion to the ingest-notion skill"
else
  fail "Claude: /ingest has no notion route"
fi

if grep -q '"notion"' "$ROOT/.claude/skills/connect/SKILL.md" || grep -q 'connect notion' "$ROOT/.claude/skills/connect/SKILL.md"; then
  pass "Claude: /connect handles notion"
else
  fail "Claude: /connect does not mention notion"
fi

# --- 2. Codex -----------------------------------------------------------------
# ingest-notion is a generated adapter (not NATIVE_SKILLS): the sync script must
# have produced .codex/skills/ingest-notion and --check must stay clean.

for adapter in ingest-notion notion-connect; do
  if [ -f "$ROOT/.codex/skills/$adapter/SKILL.md" ]; then
    pass "Codex: .codex/skills/$adapter/SKILL.md exists"
  else
    fail "Codex: $adapter adapter missing — run bash bin/codex-sync-skills.sh"
  fi
done

if bash "$ROOT/bin/codex-sync-skills.sh" --check >/dev/null 2>&1; then
  pass "Codex: bin/codex-sync-skills.sh --check passes"
else
  fail "Codex: bin/codex-sync-skills.sh --check fails" \
       "$(bash "$ROOT/bin/codex-sync-skills.sh" --check 2>&1 | head -2 | tr '\n' ' ')"
fi

# --- 3. Pi --------------------------------------------------------------------
# Pi loads the shared .codex/skills corpus; a SKILL.md there means /ingest-notion
# registers automatically. Guard against a name collision with Pi built-ins.

PI_SKILLS_REF="$(python3 -c "
import json,sys
try:
    print((json.load(open('$ROOT/.pi/settings.json')).get('skills') or [''])[0])
except Exception:
    print('')
" 2>/dev/null)"

if [ "$PI_SKILLS_REF" = "../.codex/skills" ]; then
  if [ -f "$ROOT/.codex/skills/ingest-notion/SKILL.md" ]; then
    pass "Pi: /ingest-notion is registerable from the shared .codex/skills corpus"
  else
    fail "Pi: /ingest-notion will not be registered"
  fi
else
  fail "Pi: .pi/settings.json no longer points at ../.codex/skills" \
       "found: '$PI_SKILLS_REF' — this test's assumption needs updating"
fi

if grep -qE '"(ingest-notion|notion-connect)"' "$ROOT/.pi/extensions/egregore.ts"; then
  fail "Pi: a notion skill name collides with a BUILTIN/PRODUCT command in egregore.ts"
else
  pass "Pi: no command-name collision in egregore.ts"
fi

# The always-land privacy message must stay in the guided skill.
if grep -q "Egregore Labs has no access" "$ROOT/.claude/skills/notion-connect/SKILL.md"; then
  pass "UX: notion-connect carries the org-private / no-vendor-access framing"
else
  fail "UX: the privacy framing was removed from notion-connect"
fi

# --- 4. Runtime-neutral mechanics ---------------------------------------------
# The skill's documented entry points must be plain shell (bin/), not
# harness-specific tools. MCP must not be a dependency of this connector.

if grep -qE 'bash bin/connector-notion\.sh' "$ROOT/.claude/skills/ingest-notion/SKILL.md" \
   && grep -qE 'bash bin/ingest\.sh add' "$ROOT/.claude/skills/ingest-notion/SKILL.md"; then
  pass "Neutral: ingest-notion drives bin/ scripts only"
else
  fail "Neutral: ingest-notion skill does not document the bin/ entry points"
fi

if grep -qiE 'mcp' "$ROOT/bin/connector-notion/src/index.ts"; then
  fail "Neutral: connector-notion references MCP — spec §1 forbids an MCP dependency"
else
  pass "Neutral: connector-notion has no MCP dependency"
fi

# --- 4b. OSS upsell gate --------------------------------------------------------
# Oz's exact upsell copy must survive in both skills; the gate is the OSS story.

for f in ".claude/skills/notion-connect/SKILL.md" ".claude/skills/ingest-notion/SKILL.md"; do
  if grep -q "Upgrade to Connected Tier to accelerate" "$ROOT/$f" \
     && grep -q "egregore connect" "$ROOT/$f"; then
    pass "Upsell: $f carries the verbatim tier message + sanctioned upgrade path"
  else
    fail "Upsell: $f lost the tier upsell gate or the egregore connect path"
  fi
done

# --- 5. Graph contract --------------------------------------------------------

if python3 -c "
import re,sys
src = open('$ROOT/bin/ingest_graph.py').read()
m = re.search(r'SOURCE_KINDS = \{([^}]*)\}', src)
sys.exit(0 if m and '\"notion\"' in m.group(1) else 1)
"; then
  pass "Graph: notion is a sanctioned knowledge-source kind"
else
  fail "Graph: notion missing from SOURCE_KINDS in bin/ingest_graph.py"
fi

# --- 6. Distribution registration ---------------------------------------------

if python3 -c "
import json,sys
d = json.load(open('$ROOT/capability-distribution.json'))
ok = ('skill.ingest-notion' in d['components']
      and 'npm.connector-notion' in d['components']
      and 'connectors.notion' in d['capabilities'])
sys.exit(0 if ok else 1)
"; then
  pass "Distribution: connectors.notion capability + components registered"
else
  fail "Distribution: capability-distribution.json entries missing"
fi

# --- 7. Connector e2e suite (fixture mode, no credentials) --------------------

if [ -d "$ROOT/bin/connector-notion/node_modules" ]; then
  if (cd "$ROOT/bin/connector-notion" && ./node_modules/.bin/tsx test/e2e.ts >/dev/null 2>&1); then
    pass "e2e: connector-notion fixture suite passes"
  else
    fail "e2e: connector-notion fixture suite fails" \
         "(cd bin/connector-notion && npm test) for details"
  fi
else
  pass "e2e: skipped (node_modules not installed — run npm install in bin/connector-notion)"
fi

# --- Summary ------------------------------------------------------------------
echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
