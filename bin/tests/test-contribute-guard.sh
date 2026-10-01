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

assert_scan() {
  local expected_status="$1" actual_status=0
  shift
  bash "$ROOT/bin/contribute-guard.sh" scan --config "$FIXTURE/egregore.json" "$@" \
    >"$FIXTURE/out" 2>"$FIXTURE/err" || actual_status=$?
  [ "$actual_status" -eq "$expected_status" ] ||
    fail "scan exited $actual_status, expected $expected_status"
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

write_config '{"upstream_url":"none","org_name":"Example Org","github_org":"example-team","slug":"example-org"}'
printf '%s\n' 'public framework' 'Example Org lives here' 'example-team owns this' 'slug: example-org' \
  > "$FIXTURE/refs with spaces.md"
printf '%s\n' 'public framework only' > "$FIXTURE/clean.md"
assert_scan 1 "$FIXTURE/refs with spaces.md" "$FIXTURE/clean.md"
printf '%s\n' \
  "$FIXTURE/refs with spaces.md:2:Example Org lives here" \
  "$FIXTURE/refs with spaces.md:3:example-team owns this" \
  "$FIXTURE/refs with spaces.md:4:slug: example-org" > "$FIXTURE/expected"
diff -u "$FIXTURE/expected" "$FIXTURE/out" || fail 'scan did not print path:line:match rows'
[ ! -s "$FIXTURE/err" ] || fail 'successful scan emitted an error'

assert_scan 0 "$FIXTURE/clean.md"
[ ! -s "$FIXTURE/out" ] || fail 'clean scan emitted matches'
assert_scan 0
[ ! -s "$FIXTURE/out" ] || fail 'empty file list emitted matches'
assert_scan 0 --stdin < /dev/null
assert_scan 0 "$FIXTURE/deleted.md"
[ ! -s "$FIXTURE/out" ] && [ ! -s "$FIXTURE/err" ] || fail 'deleted path was not skipped'
printf '%s\n\n' "$FIXTURE/clean.md" > "$FIXTURE/files"
printf '%s' "$FIXTURE/refs with spaces.md" >> "$FIXTURE/files"
assert_scan 1 --stdin < "$FIXTURE/files"
diff -u "$FIXTURE/expected" "$FIXTURE/out" || fail 'stdin paths were not scanned intact'
assert_scan 1 -- "$FIXTURE/refs with spaces.md"
assert_scan 2 --stdin "$FIXTURE/clean.md" < /dev/null
assert_scan 2 --unknown
assert_scan 2 --config
assert_scan 2 "$FIXTURE"
assert_scan 2 "$FIXTURE/refs with spaces.md" "$FIXTURE"
[ ! -s "$FIXTURE/out" ] || fail 'invalid file list emitted partial matches'

write_config '{}'
assert_scan 0 "$FIXTURE/refs with spaces.md"
[ ! -s "$FIXTURE/out" ] || fail 'missing identifiers matched every line'
write_config '{"org_name":"Example O.g","github_org":"","slug":null}'
assert_scan 1 "$FIXTURE/refs with spaces.md"
[ "$(cat "$FIXTURE/out")" = "$FIXTURE/refs with spaces.md:2:Example Org lives here" ] ||
  fail 'scan changed existing regex matching or treated an empty identifier as a match'
write_config '{"org_name":false}'
assert_scan 2 "$FIXTURE/clean.md"
write_config '{'
assert_scan 2 "$FIXTURE/clean.md"
assert_scan 2 --config "$FIXTURE/missing.json" "$FIXTURE/clean.md"
write_config '{"org_name":"["}'
assert_scan 2 "$FIXTURE/clean.md"

echo 'PASS: contribution scan reports configured references and handles empty, deleted, invalid, and stdin inputs'
