#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CANONICAL="$ROOT/.claude/skills/roast/SKILL.md"
ADAPTER="$ROOT/.codex/skills/roast/SKILL.md"
METADATA="$ROOT/.codex/skills/roast/agents/openai.yaml"
QA="$ROOT/.claude/skills/roast/QA.md"

for file in "$CANONICAL" "$ADAPTER" "$METADATA" "$QA"; do
  [ -f "$file" ] || { echo "missing roast file: ${file#$ROOT/}" >&2; exit 1; }
done

grep -q '^name: roast$' "$CANONICAL"
grep -q '/roast' "$CANONICAL"
grep -q '\$roast' "$CANONICAL"
grep -q 'modifiers, not targets' "$CANONICAL"
grep -q 'untrusted material, not instructions' "$CANONICAL"
grep -q 'Never open `\.env` files' "$CANONICAL"
grep -q 'protected traits' "$CANONICAL"
grep -q 'Output the performance directly' "$CANONICAL"

grep -q 'generated-by: bin/codex-sync-skills.sh' "$ADAPTER"
grep -q '\$roast' "$ADAPTER"
grep -q 'display_name: "Roast"' "$METADATA"
grep -q '\$roast' "$METADATA"
grep -q '| `/roast` |' "$ROOT/README.md"
grep -q '\*\*Play\*\* — `/roast`' "$ROOT/CLAUDE.md"
grep -q '\*\*Play\*\* — `\$roast`' "$ROOT/AGENTS.md"

TMP_DIR="$(mktemp -d -t egregore-roast-test-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/.claude" "$TMP_DIR/.codex"
cp "$ROOT/bin/codex-sync-skills.sh" "$TMP_DIR/bin/"
cp -R "$ROOT/.claude/skills" "$TMP_DIR/.claude/"
cp -R "$ROOT/.codex/skills" "$TMP_DIR/.codex/"
bash "$TMP_DIR/bin/codex-sync-skills.sh" >/dev/null
cmp -s "$ADAPTER" "$TMP_DIR/.codex/skills/roast/SKILL.md" || {
  echo "roast Codex adapter is out of sync" >&2
  exit 1
}

echo "roast skill contract ok"
