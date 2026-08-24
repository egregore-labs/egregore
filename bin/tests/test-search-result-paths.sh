#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

mkdir -p "$FIXTURE/bin" "$FIXTURE/fake-bin" "$FIXTURE/memory-repo/knowledge/decisions"
cp "$ROOT/bin/search.sh" "$FIXTURE/bin/search.sh"
ln -s "$FIXTURE/memory-repo" "$FIXTURE/memory"

printf '%s\n' \
  '{' \
  '  "org_name": "Fixture",' \
  '  "github_org": "fixture",' \
  '  "slug": "fixture",' \
  '  "mode": "connected",' \
  '  "api_url": "https://example.invalid"' \
  '}' > "$FIXTURE/egregore.json"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  collection) echo "fixture-memory  fixture" ;;' \
  '  update|embed) exit 0 ;;' \
  '  search|query|vsearch)' \
  '    resolved_memory=$(readlink -f "$TEST_MEMORY_PATH")' \
  '    printf '\''%s\n'\'' "---" "# Absolute result" "**file:** \`$resolved_memory/knowledge/decisions/absolute.md\`" "" "---" "# URI result" "**file:** \`qmd://fixture-memory/knowledge/decisions/uri.md\`"' \
  '    ;;' \
  'esac' > "$FIXTURE/fake-bin/qmd"
chmod +x "$FIXTURE/fake-bin/qmd"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "${@: -1}" > "$TEST_GRAPH_PARAMS"' \
  'printf '\''%s\n'\'' '\''{"values":[["knowledge/decisions/absolute.md",null,null,"decision",null]]}'\''' \
  > "$FIXTURE/bin/graph.sh"

OUTPUT=$(PATH="$FIXTURE/fake-bin:$PATH" \
  TEST_MEMORY_PATH="$FIXTURE/memory-repo" \
  TEST_GRAPH_PARAMS="$FIXTURE/graph-params.json" \
  EGREGORE_SEARCH_NO_WARM=1 \
  bash "$FIXTURE/bin/search.sh" query "fixture" --fast --enrich -n 2)

printf '%s\n' "$OUTPUT" | grep -Fq '· 2 hits ·' ||
  fail "mixed qmd path formats were not counted"
printf '%s\n' "$OUTPUT" | grep -Fq '**file:** `memory/knowledge/decisions/absolute.md`' ||
  fail "absolute qmd path was not normalized"
printf '%s\n' "$OUTPUT" | grep -Fq '**file:** `memory/knowledge/decisions/uri.md`' ||
  fail "qmd URI was not normalized"
printf '%s\n' "$OUTPUT" | grep -Fq '↳ graph · knowledge/decisions/absolute.md' ||
  fail "absolute-path result was not enriched from the graph"
grep -Fq '"knowledge/decisions/absolute.md"' "$FIXTURE/graph-params.json" ||
  fail "normalized absolute path was not sent to graph enrichment"
grep -Fq '"knowledge/decisions/uri.md"' "$FIXTURE/graph-params.json" ||
  fail "normalized qmd URI was not sent to graph enrichment"
if printf '%s\n' "$OUTPUT" | grep -Fq "$FIXTURE/memory-repo"; then
  fail "search output leaked the sibling memory repository path"
fi

echo "PASS: search counts, normalizes, and enriches qmd 2.5 result paths"
