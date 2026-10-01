#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for skill in "$ROOT/.claude/skills/meeting/SKILL.md"; do
  [ "$(grep -c 'bash bin/research-ingest.sh meeting' "$skill")" = "1" ]
done

for skill in "$ROOT/.claude/skills/ingest-user-interview/SKILL.md"; do
  [ "$(grep -c 'bash bin/research-ingest.sh interview' "$skill")" = "1" ]
done

for skill in \
  "$ROOT/.claude/skills/meeting/SKILL.md" \
  "$ROOT/.claude/skills/ingest-user-interview/SKILL.md"; do
  ! grep -Eq '^[[:space:]]*(bash[[:space:]]+)?bin/(graph|graph-op|graph-batch|ingest-graph)\.sh' "$skill"
  ! grep -Eq '^[[:space:]]*(git[[:space:]]|gh[[:space:]]|curl[[:space:]])' "$skill"
  ! grep -Eq '^[[:space:]]*(cat|echo|printf)[[:space:]].*>[>]?[[:space:]]*memory/' "$skill"
  grep -Fq 'EGREGORE_ORG_CONTEXT_V1' "$skill"
done

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/fakebin"
cat > "$TMPD/fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
printf '%s\n' '{"status":"accepted","artifacts":[]}'
SH
chmod +x "$TMPD/fakebin/python3"
printf '%s\n' '{}' > "$TMPD/package.json"
CALL_LOG="$TMPD/calls" PATH="$TMPD/fakebin:$PATH" \
  bash "$ROOT/bin/research-ingest.sh" meeting --input "$TMPD/package.json" >/dev/null
[ "$(wc -l < "$TMPD/calls" | tr -d ' ')" = "1" ]
grep -Fq -- '-m egregore_runtime.research_ingest_cli meeting' "$TMPD/calls"

echo "PASS: meeting and interview skills use one typed Runtime write call"
