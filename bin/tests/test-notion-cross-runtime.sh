#!/usr/bin/env bash
set -uo pipefail

# Test: selected-page Notion ingestion uses Notion's official MCP, lands in
# /ingest notion, and stays honest on runtimes without MCP support.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; return 0; }

echo "test-notion-cross-runtime"
echo ""

INGEST="$ROOT/.claude/skills/ingest-notion/SKILL.md"
CONNECT="$ROOT/.claude/skills/notion-connect/SKILL.md"

for f in "$INGEST" "$CONNECT"; do
  if [ -f "$f" ]; then
    pass "Skill exists: ${f#"$ROOT/"}"
  else
    fail "Skill missing: ${f#"$ROOT/"}"
  fi
done

if grep -q 'claude mcp add --transport http --scope project notion https://mcp\.notion\.com/mcp' "$CONNECT" \
   && grep -q 'claude mcp login notion' "$CONNECT"; then
  pass "Claude: guided project registration + OAuth are documented"
else
  fail "Claude: guided Notion MCP connection is incomplete"
fi

if grep -q '^\[mcp_servers\.notion\]$' "$ROOT/.codex/config.toml" \
   && grep -q '^url = "https://mcp\.notion\.com/mcp"$' "$ROOT/.codex/config.toml"; then
  pass "Codex: official Notion MCP is declared"
else
  fail "Codex: official Notion MCP declaration missing"
fi

for runtime in codex pi prime; do
  config="$ROOT/packages/create-egregore/runtime/$runtime/.codex/config.toml"
  if grep -q '^\[mcp_servers\.notion\]$' "$config" \
     && grep -q '^url = "https://mcp\.notion\.com/mcp"$' "$config"; then
    pass "Runtime bundle: $runtime carries the Notion MCP declaration"
  else
    fail "Runtime bundle: $runtime lost the Notion MCP declaration"
  fi
done

if grep -q 'notion ...' "$ROOT/.claude/skills/ingest/SKILL.md" \
   && grep -q 'route directly to `ingest-notion`' "$ROOT/.claude/skills/ingest/SKILL.md"; then
  pass "UI: /ingest routes Notion directly into the MCP ingest flow"
else
  fail "UI: /ingest does not own the Notion MCP flow"
fi

if grep -q 'notion-search' "$INGEST" && grep -q 'notion-fetch' "$INGEST"; then
  pass "MCP: ingest uses Notion search + fetch"
else
  fail "MCP: ingest does not require Notion search + fetch"
fi

if grep -q 'Normal Egregore session capture may' "$CONNECT" \
   && grep -q 'curated Notion source' "$CONNECT"; then
  pass "Privacy: session inspection and curated-memory boundaries are explicit"
else
  fail "Privacy: MCP inspection is described as more private than it is"
fi

if grep -q 'memory/knowledge/sources/notion/' "$INGEST" \
   && grep -q 'egregore-ingest-notion-mcp' "$INGEST" \
   && grep -q 'ingest-graph.sh validate' "$INGEST"; then
  pass "Memory: selected pages carry files + replayable provenance"
else
  fail "Memory: selected-page write contract is incomplete"
fi

if grep -q 'bash bin/connector-notion\.sh' "$INGEST" \
   || grep -q 'bash bin/connector-notion\.sh' "$CONNECT"; then
  fail "Migration: an active Notion skill still calls the legacy REST connector"
else
  pass "Migration: active Notion skills do not call the legacy REST connector"
fi

if grep -q 'Upgrade to Connected Tier' "$INGEST" \
   || grep -q 'Upgrade to Connected Tier' "$CONNECT"; then
  fail "Availability: Notion MCP is still incorrectly gated to Connected tier"
else
  pass "Availability: Notion MCP works in local and connected Egregores"
fi

if [ -x "$ROOT/bin/connector-notion.sh" ] \
   && [ -f "$ROOT/bin/connector-notion/src/index.ts" ]; then
  pass "Rollback: legacy REST connector remains present"
else
  fail "Rollback: legacy REST connector was removed before MCP smoke testing"
fi

for adapter in ingest-notion notion-connect; do
  if [ -f "$ROOT/.codex/skills/$adapter/SKILL.md" ]; then
    pass "Codex: $adapter adapter exists"
  else
    fail "Codex: $adapter adapter missing"
  fi
done

if bash "$ROOT/bin/codex-sync-skills.sh" --check >/dev/null 2>&1; then
  pass "Codex: generated skill adapters are current"
else
  fail "Codex: generated skill adapters are stale"
fi

if grep -q 'Pi does not provide MCP support' "$CONNECT" \
   && grep -q 'Do not fall back to the legacy REST connector' "$CONNECT"; then
  pass "Pi: unsupported MCP path is explicit and does not silently change transport"
else
  fail "Pi: missing honest unsupported-MCP path"
fi

if python3 -c "
import json,sys
d=json.load(open('$ROOT/capability-distribution.json'))
c=d['capabilities']['connectors.notion']
ok=(c.get('availability') == 'oss'
    and 'skill.ingest-notion' in c.get('requires',[])
    and 'skill.notion-connect' in c.get('requires',[])
    and 'npm.connector-notion' not in c.get('requires',[]))
sys.exit(0 if ok else 1)
"; then
  pass "Distribution: Notion MCP is OSS and independent of the REST package"
else
  fail "Distribution: Notion capability still depends on the REST connector"
fi

if python3 -c "
import re,sys
src=open('$ROOT/bin/ingest_graph.py').read()
m=re.search(r'SOURCE_KINDS = \{([^}]*)\}', src)
sys.exit(0 if m and '\"notion\"' in m.group(1) else 1)
"; then
  pass "Graph: notion remains a sanctioned knowledge-source kind"
else
  fail "Graph: notion source kind missing"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
