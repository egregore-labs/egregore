#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

write_config() {
  printf '%s\n' "$1" > "$FIXTURE/egregore.json"
}

write_config '{"upstream_url":"none"}'
if bash "$ROOT/bin/contribute-guard.sh" --config "$FIXTURE/egregore.json" >"$FIXTURE/out" 2>"$FIXTURE/err"; then
  fail 'source repository was allowed to contribute externally'
fi
grep -Fq 'this checkout is a framework source' "$FIXTURE/err" ||
  fail 'source-repository refusal did not explain the correct save path'
[ ! -s "$FIXTURE/out" ] || fail 'source-repository refusal emitted a target'

write_config '{}'
[ "$(bash "$ROOT/bin/contribute-guard.sh" --config "$FIXTURE/egregore.json")" = 'egregore-labs/egregore' ] ||
  fail 'missing upstream_url did not use the official downstream default'

write_config '{"upstream_url":"https://github.com/acme/framework.git"}'
[ "$(bash "$ROOT/bin/contribute-guard.sh" --config "$FIXTURE/egregore.json")" = 'acme/framework' ] ||
  fail 'custom HTTPS upstream was not normalized'
bash "$ROOT/bin/contribute-guard.sh" --config "$FIXTURE/egregore.json" --expect acme/framework >/dev/null ||
  fail 'matching expected target was refused'
if bash "$ROOT/bin/contribute-guard.sh" --config "$FIXTURE/egregore.json" --expect egregore-labs/egregore >/dev/null 2>&1; then
  fail 'changed contribution target was accepted'
fi

write_config '{"upstream_url":false}'
if bash "$ROOT/bin/contribute-guard.sh" --config "$FIXTURE/egregore.json" >/dev/null 2>&1; then
  fail 'non-string upstream_url was accepted'
fi

write_config '{"upstream_url":"https://github.com/acme/framework/issues/1"}'
if bash "$ROOT/bin/contribute-guard.sh" --config "$FIXTURE/egregore.json" >/dev/null 2>&1; then
  fail 'non-repository GitHub URL was accepted'
fi

write_config '{'
if bash "$ROOT/bin/contribute-guard.sh" --config "$FIXTURE/egregore.json" >/dev/null 2>&1; then
  fail 'malformed configuration defaulted to a public target'
fi

for spec in \
  "$ROOT/CLAUDE.md" \
  "$ROOT/AGENTS.md" \
  "$ROOT/.pi/APPEND_SYSTEM.md" \
  "$ROOT/.prime/agent/APPEND_SYSTEM.md"; do
  grep -Fq 'upstream_url' "$spec" ||
    fail "$(basename "$spec") does not derive framework direction from upstream_url"
  grep -Fq '**Source**' "$spec" ||
    fail "$(basename "$spec") does not preserve source-repository behavior"
done

grep -Fq '.claude/skills/contribute/SKILL.md' "$ROOT/.codex/skills/contribute/SKILL.md" ||
  fail 'Codex contribution adapter no longer routes to the canonical skill'
[ "$(grep -Fc 'bash bin/contribute-guard.sh' "$ROOT/.claude/skills/contribute/SKILL.md")" -ge 4 ] ||
  fail 'contribution workflow does not revalidate before every external mutation'

echo 'PASS: contribution targeting fails closed for source and invalid repositories'
