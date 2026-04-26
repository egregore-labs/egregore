#!/bin/bash
# Reproducible two-agent smoke test for the runtime-neutral protocol.
#
# It creates two isolated Egregore checkouts backed by the same local bare
# memory repo, then verifies that two simulated Codex agents can exchange a
# handoff, a question, and an answer without Claude Code.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t egregore-agent-protocol-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

copy_runtime() {
  local dest="$1"
  mkdir -p "$dest/bin" "$dest/bin/lib"
  cp "$ROOT/bin/agent.sh" "$dest/bin/agent.sh"
  cp "$ROOT/bin/handoff-run.sh" "$dest/bin/handoff-run.sh"
  cp "$ROOT/bin/repo-state.sh" "$dest/bin/repo-state.sh"
  cp "$ROOT/bin/index-handoff.sh" "$dest/bin/index-handoff.sh"
  cp "$ROOT/bin/graph.sh" "$dest/bin/graph.sh"
  cp "$ROOT/bin/graph-wal.sh" "$dest/bin/graph-wal.sh"
  cp "$ROOT/bin/handoff-pr-backfill.sh" "$dest/bin/handoff-pr-backfill.sh"
  cp "$ROOT/bin/publish-artifact.sh" "$dest/bin/publish-artifact.sh"
  cp -R "$ROOT/bin/lib/." "$dest/bin/lib/"
}

write_config() {
  local dest="$1"
  cat > "$dest/egregore.json" <<'JSON'
{
  "mode": "local",
  "org_name": "Agent Protocol Smoke",
  "github_org": "local",
  "slug": "agent-protocol-smoke",
  "repo_name": "egregore",
  "repos": []
}
JSON
  cat > "$dest/.egregore-state.json" <<'JSON'
{
  "github_username": "codex",
  "github_name": "Codex",
  "onboarding_complete": true
}
JSON
}

setup_instance() {
  local name="$1"
  local person="$2"
  local base="$TMP/$name"
  local core="$base/egregore"
  local memory="$base/memory"

  mkdir -p "$core"
  copy_runtime "$core"
  write_config "$core"
  git -C "$core" init --quiet
  git -C "$core" config user.name "$person"
  git -C "$core" config user.email "$person@example.test"

  git clone --quiet "$TMP/memory.git" "$memory"
  git -C "$memory" config user.name "$person"
  git -C "$memory" config user.email "$person@example.test"
  ln -s "$memory" "$core/memory"
}

# Seed the shared memory remote.
git init --bare --quiet "$TMP/memory.git"
git init --quiet "$TMP/seed"
git -C "$TMP/seed" config user.name seed
git -C "$TMP/seed" config user.email seed@example.test
mkdir -p "$TMP/seed/people" "$TMP/seed/handoffs" "$TMP/seed/knowledge/questions"
cat > "$TMP/seed/people/codex-a.md" <<'EOF'
---
name: codex-a
github: codex-a
---
EOF
cat > "$TMP/seed/people/codex-b.md" <<'EOF'
---
name: codex-b
github: codex-b
---
EOF
printf '# Handoffs\n\n' > "$TMP/seed/handoffs/index.md"
git -C "$TMP/seed" add -A
git -C "$TMP/seed" commit -m "Seed memory" --quiet
git -C "$TMP/seed" branch -M main
git -C "$TMP/seed" remote add origin "$TMP/memory.git"
git -C "$TMP/seed" push --quiet -u origin main

setup_instance "agent-a" "codex-a"
setup_instance "agent-b" "codex-b"

A="$TMP/agent-a/egregore"
B="$TMP/agent-b/egregore"

bash "$A/bin/agent.sh" handoff \
  --from codex-a \
  --to codex-b \
  --topic "relay smoke" \
  --body "codex-a leaves a runtime-neutral handoff for codex-b."

bash "$B/bin/agent.sh" sync
ACTIVITY_B="$(bash "$B/bin/agent.sh" activity --for codex-b)"
echo "$ACTIVITY_B" | grep -q "relay smoke"
echo "$ACTIVITY_B" | grep -q "codex-a"

bash "$B/bin/agent.sh" ask \
  --from codex-b \
  --to codex-a \
  --topic "relay smoke" \
  --question "What should codex-b verify next?"

bash "$A/bin/agent.sh" sync
ACTIVITY_A="$(bash "$A/bin/agent.sh" activity --for codex-a)"
echo "$ACTIVITY_A" | grep -q "What should codex-b verify next" || echo "$ACTIVITY_A" | grep -q "relay smoke"

QUESTION_FILE="$(find "$A/memory/knowledge/questions" -type f -name '*relay-smoke*.md' | head -1)"
[ -n "$QUESTION_FILE" ]

bash "$A/bin/agent.sh" answer \
  --from codex-a \
  --question "$QUESTION_FILE" \
  --body "Verify the exchange from a fresh memory clone."

bash "$B/bin/agent.sh" sync
ANSWERED_FILE="$(find "$B/memory/knowledge/questions" -type f -name '*relay-smoke*.md' | head -1)"
grep -q "status: answered" "$ANSWERED_FILE"
grep -q "Verify the exchange from a fresh memory clone." "$ANSWERED_FILE"

echo "agent protocol smoke: ok"
