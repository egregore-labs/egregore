#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/artifact-writeback-XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
INSTANCE_DIR="$FIXTURE_DIR/fixture instance"
MEMORY_DIR="$INSTANCE_DIR/memory"
ORIGIN_DIR="$FIXTURE_DIR/memory-origin.git"
mkdir -p "$INSTANCE_DIR/bin" "$MEMORY_DIR" "$FIXTURE_DIR/fake-bin"
cp "$ROOT_DIR/bin/artifact-writeback.sh" "$INSTANCE_DIR/bin/artifact-writeback.sh"
cp -R "$ROOT_DIR/egregore_runtime" "$INSTANCE_DIR/egregore_runtime"

# Exercise the real Runtime and Git transport, with every writable state path
# inside this fixture. Retrieval deliberately fails offline; partial receipts
# must still report successful canonical commits and remote delivery.
export PYTHONDONTWRITEBYTECODE=1
export EGREGORE_NO_TELEMETRY=1
export EGREGORE_TELEMETRY_DIR="$FIXTURE_DIR/telemetry"
export EGREGORE_QMD_RUNTIME_DIR="$FIXTURE_DIR/qmd"
export EGREGORE_RUNTIME_ROOT="$FIXTURE_DIR/runtime"
export EGREGORE_QMD_PERSISTENT=0
export EGREGORE_SEARCH_NO_WARM=1
export EGREGORE_QMD_BIN="$FIXTURE_DIR/fake-bin/qmd"
export EGREGORE_SESSION_ID="session-writeback-fixture"
export EGREGORE_RUNTIME="codex"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="/dev/null"
export GIT_ALLOW_PROTOCOL="file"
export GIT_TERMINAL_PROMPT=0
cat > "$EGREGORE_QMD_BIN" <<'SH'
#!/usr/bin/env bash
echo 'fixture: retrieval unavailable offline' >&2
exit 1
SH
chmod +x "$EGREGORE_QMD_BIN"
cat > "$INSTANCE_DIR/egregore.json" <<'JSON'
{"mode":"local","org_id":"org-writeback-fixture","org_name":"Writeback fixture","slug":"writeback-fixture"}
JSON
cat > "$INSTANCE_DIR/.egregore-state.json" <<'JSON'
{"account_id":"account-fixture","actor_id":"actor-fixture","membership_id":"membership-fixture","display_name":"Fixture writer","membership_status":"active","onboarding_complete":true}
JSON

git init --quiet "$MEMORY_DIR"
git -C "$MEMORY_DIR" config user.name 'Fixture writer'
git -C "$MEMORY_DIR" config user.email 'fixture@example.test'
printf '# Memory fixture\n' > "$MEMORY_DIR/README.md"
git -C "$MEMORY_DIR" add -- 'README.md'
git -C "$MEMORY_DIR" commit --quiet -m 'Seed fixture'
git -C "$MEMORY_DIR" branch -M main
git init --bare --quiet "$ORIGIN_DIR"
git -C "$MEMORY_DIR" remote add origin "$ORIGIN_DIR"
git -C "$MEMORY_DIR" push --quiet -u origin main

receipt_revision() {
  jq -er '.git_revision | sub("^git:"; "")' "$1"
}

check_receipt() {
  local receipt="$1" canonical_path="$2"
  jq -e --arg canonical_path "$canonical_path" '
    (.status == "accepted" or .status == "partial") and
    (.canonical_path == $canonical_path) and
    (.git_revision | startswith("git:")) and
    (.warnings | type == "array") and
    (.permission_decision.allowed == true) and
    (.permission_decision.actor_id == "actor-fixture")
  ' "$receipt" >/dev/null
  [ "$(receipt_revision "$receipt")" = "$(git -C "$MEMORY_DIR" rev-parse HEAD)" ]
  git -C "$MEMORY_DIR" log -1 --format=%B | grep -Fx >/dev/null 'Egregore-Session: session-writeback-fixture'
  git -C "$MEMORY_DIR" log -1 --format=%B | grep -Fx >/dev/null 'Egregore-Harness: codex'
}

wait_for_origin() {
  local expected="$1" attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(git -C "$ORIGIN_DIR" rev-parse refs/heads/main)" = "$expected" ] && return 0
    sleep 1
  done
  echo 'FAIL: background Runtime delivery did not advance the local bare origin' >&2
  return 1
}

expect_exit() {
  local expected="$1" actual=0
  shift
  bash "$INSTANCE_DIR/bin/artifact-writeback.sh" "$@" \
    > "$FIXTURE_DIR/last.stdout" 2> "$FIXTURE_DIR/last.stderr" || actual=$?
  if [ "$actual" -ne "$expected" ]; then
    cat "$FIXTURE_DIR/last.stderr" >&2
    echo "FAIL: expected exit $expected, got $actual for $*" >&2
    exit 1
  fi
}

run_skill_command() {
  python3 - "$ROOT_DIR" "$INSTANCE_DIR" "$1" "$2" <<'PY'
import re
import shlex
import subprocess
import sys
from pathlib import Path

root, instance, skill, verb = sys.argv[1:]
sources = {
    "emissary": ".claude/skills/emissary/SKILL.md",
    "graph-diagnostic": ".claude/skills/graph-diagnostic/SKILL.md",
    "infra": ".claude/skills/infra/SKILL.md",
}
blocks = re.findall(r"```bash\n(.*?)\n```", (Path(root) / sources[skill]).read_text(), re.S)
commands = [block.strip() for block in blocks if block.strip().startswith(f"bash bin/artifact-writeback.sh {verb} ")]
assert len(commands) == 1, (skill, verb, commands)
command = commands[0]
assert "\n" not in command, "adapter fences must contain one command"
for key, value in {
    "pointer_path": "handoffs/outbound/skill-pointer.md",
    "topic": "fixture's emissary",
    "today": "2026-09-23",
    "service-name": "fixture's service",
}.items():
    command = command.replace("{" + key + "}", value.replace("'", "'\\''"))
raise SystemExit(subprocess.run(shlex.split(command), cwd=instance).returncode)
PY
}

mkdir -p "$MEMORY_DIR/handoffs/outbound" "$MEMORY_DIR/infrastructure"
cat > "$MEMORY_DIR/handoffs/outbound/emissary-pointer.md" <<'MD'
# Emissary: fixture

**Date**: 2026-09-23
**Author**: Fixture writer
**Kind**: report
**Distribution**: public
**Recipients**: public link
**URL**: https://example.test/emissary-fixture

## Claim

A fixture pointer for the rendered emissary.
MD
printf 'unrelated staged edit\n' > "$MEMORY_DIR/unrelated.txt"
git -C "$MEMORY_DIR" add -- 'unrelated.txt'
before="$(git -C "$MEMORY_DIR" rev-list --count HEAD)"
bash "$INSTANCE_DIR/bin/artifact-writeback.sh" adopt 'handoffs/outbound/emissary-pointer.md' \
  > "$FIXTURE_DIR/adopt.json"
check_receipt "$FIXTURE_DIR/adopt.json" 'handoffs/outbound/emissary-pointer.md'
[ "$(git -C "$MEMORY_DIR" rev-list --count HEAD)" -eq "$((before + 1))" ]
[ "$(git -C "$MEMORY_DIR" diff-tree --no-commit-id --name-only -r HEAD)" = 'handoffs/outbound/emissary-pointer.md' ]
[ "$(git -C "$MEMORY_DIR" diff --cached --name-only)" = 'unrelated.txt' ]
wait_for_origin "$(receipt_revision "$FIXTURE_DIR/adopt.json")"
echo 'PASS: adopt commits one emissary pointer and delivers its Runtime receipt to the bare origin'

printf 'services:\n  fixture:\n    url: https://example.test\n' > "$MEMORY_DIR/infrastructure/services.yml"
before="$(git -C "$MEMORY_DIR" rev-list --count HEAD)"
run_skill_command infra commit > "$FIXTURE_DIR/commit.json"
check_receipt "$FIXTURE_DIR/commit.json" 'infrastructure/services.yml'
[ "$(git -C "$MEMORY_DIR" rev-list --count HEAD)" -eq "$((before + 1))" ]
[ "$(git -C "$MEMORY_DIR" diff-tree --no-commit-id --name-only -r HEAD)" = 'infrastructure/services.yml' ]
[ "$(git -C "$MEMORY_DIR" diff --cached --name-only)" = 'unrelated.txt' ]
# Shared ledgers push synchronously: the origin has the commit when the verb
# returns, with no polling and nothing left to a detached process.
[ "$(git -C "$ORIGIN_DIR" rev-parse refs/heads/main)" = "$(receipt_revision "$FIXTURE_DIR/commit.json")" ]
echo 'PASS: commit delivers only the named YAML file synchronously with its receipt'

remote_before="$(git -C "$ORIGIN_DIR" rev-parse refs/heads/main)"
printf '# Handoffs\n\n- fixture emissary\n' > "$MEMORY_DIR/handoffs/index.md"
printf '  added: true\n' >> "$MEMORY_DIR/infrastructure/services.yml"
before="$(git -C "$MEMORY_DIR" rev-list --count HEAD)"
bash "$INSTANCE_DIR/bin/artifact-writeback.sh" commit \
  --path 'infrastructure/services.yml' --path 'handoffs/index.md' \
  --message 'docs(memory): record fixture registry and index' --no-push \
  > "$FIXTURE_DIR/no-push.json"
check_receipt "$FIXTURE_DIR/no-push.json" 'infrastructure/services.yml'
[ "$(git -C "$MEMORY_DIR" rev-list --count HEAD)" -eq "$((before + 1))" ]
[ "$(git -C "$MEMORY_DIR" diff-tree --no-commit-id --name-only -r HEAD)" = "$(printf '%s\n' 'handoffs/index.md' 'infrastructure/services.yml')" ]
[ "$(git -C "$ORIGIN_DIR" rev-parse refs/heads/main)" = "$remote_before" ]
jq -e '.canonical_paths == ["infrastructure/services.yml", "handoffs/index.md"]' "$FIXTURE_DIR/no-push.json" >/dev/null

# A second rendered legacy document avoids changing an immutable canonical id.
cat > "$MEMORY_DIR/handoffs/outbound/second-pointer.md" <<'MD'
---
type: handoff
date: 2026-09-23
author: fixture-author
topic: second fixture emissary
---
# Emissary: second fixture
MD
bash "$INSTANCE_DIR/bin/artifact-writeback.sh" adopt 'handoffs/outbound/second-pointer.md' --no-push \
  > "$FIXTURE_DIR/adopt-no-push.json"
check_receipt "$FIXTURE_DIR/adopt-no-push.json" 'handoffs/outbound/second-pointer.md'
sleep 1
[ "$(git -C "$ORIGIN_DIR" rev-parse refs/heads/main)" = "$remote_before" ]
echo 'PASS: repeated commit paths and both no-push verbs preserve the remote revision'

cat > "$MEMORY_DIR/handoffs/outbound/skill-pointer.md" <<'MD'
# Emissary: fixture's emissary

**Date**: 2026-09-23
**Author**: Fixture writer
**Kind**: report
**Distribution**: public
**Recipients**: public link
**URL**: https://example.test/skill-emissary
MD
before="$(git -C "$MEMORY_DIR" rev-list --count HEAD)"
run_skill_command emissary adopt > "$FIXTURE_DIR/skill-adopt.json"
check_receipt "$FIXTURE_DIR/skill-adopt.json" 'handoffs/outbound/skill-pointer.md'
[ "$(git -C "$MEMORY_DIR" rev-list --count HEAD)" -eq "$((before + 1))" ]
[ "$(git -C "$ORIGIN_DIR" rev-parse refs/heads/main)" = "$remote_before" ]
printf '\n- 2026-09-23 — fixture: emissary pointer\n' >> "$MEMORY_DIR/handoffs/index.md"
run_skill_command emissary commit > "$FIXTURE_DIR/skill-index.json"
check_receipt "$FIXTURE_DIR/skill-index.json" 'handoffs/index.md'
[ "$(git -C "$MEMORY_DIR" rev-list --count HEAD)" -eq "$((before + 2))" ]
# The ledger commit's synchronous push delivers the adopted pointer with it.
[ "$(git -C "$ORIGIN_DIR" rev-parse refs/heads/main)" = "$(receipt_revision "$FIXTURE_DIR/skill-index.json")" ]

mkdir -p "$MEMORY_DIR/diagnostics"
cat > "$MEMORY_DIR/diagnostics/graph-diagnostic-2026-09-23.md" <<'MD'
# Egregore Graph Diagnostic — 2026-09-23

Generated at 2026-09-23T10:00:00Z

## Node Labels

```
fixture raw graph output
```

---
Total sections: 1
MD
before="$(git -C "$MEMORY_DIR" rev-list --count HEAD)"
run_skill_command graph-diagnostic adopt > "$FIXTURE_DIR/skill-diagnostic.json"
check_receipt "$FIXTURE_DIR/skill-diagnostic.json" 'diagnostics/graph-diagnostic-2026-09-23.md'
[ "$(git -C "$MEMORY_DIR" rev-list --count HEAD)" -eq "$((before + 1))" ]
wait_for_origin "$(receipt_revision "$FIXTURE_DIR/skill-diagnostic.json")"
echo 'PASS: emissary, graph-diagnostic, and infra skill fences execute through the Runtime'

# A second diagnostic for the same date re-renders one file, not a conflict.
revision_before="$(grep '^revision:' "$MEMORY_DIR/diagnostics/graph-diagnostic-2026-09-23.md")"
printf '\n## Node Labels (recount)\n\nfixture second pass\n' \
  >> "$MEMORY_DIR/diagnostics/graph-diagnostic-2026-09-23.md"
run_skill_command graph-diagnostic adopt > "$FIXTURE_DIR/skill-diagnostic-2.json"
check_receipt "$FIXTURE_DIR/skill-diagnostic-2.json" 'diagnostics/graph-diagnostic-2026-09-23.md'
[ "$(git -C "$MEMORY_DIR" rev-list --count HEAD)" -eq "$((before + 2))" ]
[ "$(ls "$MEMORY_DIR/diagnostics" | wc -l | tr -d ' ')" = '1' ]
[ "$(grep '^revision:' "$MEMORY_DIR/diagnostics/graph-diagnostic-2026-09-23.md")" != "$revision_before" ]
grep -Fq 'fixture second pass' "$MEMORY_DIR/diagnostics/graph-diagnostic-2026-09-23.md"
wait_for_origin "$(receipt_revision "$FIXTURE_DIR/skill-diagnostic-2.json")"
echo 'PASS: re-adopting a re-rendered report keeps one file and records a new revision'

# Point 2: the envelope cannot be bypassed by committing the raw artifact.
head_before="$(git -C "$MEMORY_DIR" rev-parse HEAD)"
expect_exit 1 commit --path 'handoffs/outbound/emissary-pointer.md' \
  --message 'docs(memory): bypass the envelope'
grep -Fq 'adopt' "$FIXTURE_DIR/last.stderr"
cat > "$MEMORY_DIR/handoffs/legacy-typed.md" <<'MD'
---
type: handoff
date: 2026-09-23
author: fixture-author
---
# Legacy typed handoff
MD
expect_exit 1 commit --path 'handoffs/legacy-typed.md' \
  --message 'docs(memory): bypass the envelope'
grep -Fq 'adopt' "$FIXTURE_DIR/last.stderr"
[ "$(git -C "$MEMORY_DIR" rev-parse HEAD)" = "$head_before" ]
[ "$(git -C "$MEMORY_DIR" diff --cached --name-only)" = 'unrelated.txt' ]
echo 'PASS: commit refuses store-managed canonical documents and names adopt'

remote_before="$(git -C "$ORIGIN_DIR" rev-parse refs/heads/main)"

expect_exit 2
expect_exit 2 unknown
expect_exit 2 adopt
expect_exit 2 adopt 'handoffs/outbound/emissary-pointer.md' --unknown
expect_exit 2 adopt 'handoffs/outbound/missing.md'
expect_exit 2 adopt '../egregore.json'
expect_exit 2 commit
expect_exit 2 commit --path 'infrastructure/services.yml'
expect_exit 2 commit --message fixture
expect_exit 2 commit --path 'infrastructure/services.yml' --message
expect_exit 2 commit --path 'infrastructure/services.yml' --message ''
expect_exit 2 commit --path 'missing.yml' --message fixture
expect_exit 2 commit --path '../egregore.json' --message fixture
expect_exit 2 commit --path "$INSTANCE_DIR/egregore.json" --message fixture
expect_exit 2 commit --path 'infrastructure/services.yml' --message fixture --unknown

mv "$INSTANCE_DIR/.egregore-state.json" "$FIXTURE_DIR/actor.json"
expect_exit 2 adopt
expect_exit 2 adopt 'handoffs/outbound/missing.md'
expect_exit 2 adopt '../egregore.json'
expect_exit 2 commit --path 'infrastructure/services.yml'
expect_exit 2 commit --path 'infrastructure/services.yml' --message ''
expect_exit 2 commit --path 'missing.yml' --message fixture
expect_exit 2 commit --path '../egregore.json' --message fixture
expect_exit 0 adopt --help
[ "$(grep -c '^usage:' "$FIXTURE_DIR/last.stdout")" -eq 1 ]
expect_exit 0 commit --help
[ "$(grep -c '^usage:' "$FIXTURE_DIR/last.stdout")" -eq 1 ]
mv "$FIXTURE_DIR/actor.json" "$INSTANCE_DIR/.egregore-state.json"
echo 'PASS: syntax and canonical path usage errors exit 2, even without configured identity'

jq '.membership_status = "suspended"' "$INSTANCE_DIR/.egregore-state.json" > "$FIXTURE_DIR/suspended.json"
mv "$FIXTURE_DIR/suspended.json" "$INSTANCE_DIR/.egregore-state.json"
before="$(git -C "$MEMORY_DIR" rev-parse HEAD)"
printf '  forbidden: true\n' >> "$MEMORY_DIR/infrastructure/services.yml"
expect_exit 1 commit --path 'infrastructure/services.yml' --message forbidden
expect_exit 1 adopt 'handoffs/outbound/second-pointer.md'
[ "$(git -C "$MEMORY_DIR" rev-parse HEAD)" = "$before" ]
[ "$(git -C "$ORIGIN_DIR" rev-parse refs/heads/main)" = "$remote_before" ]
echo 'PASS: suspended actors cannot pass the adapter authorization preflight'
