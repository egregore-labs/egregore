#!/usr/bin/env bash
# Reproducible two-agent smoke test for the runtime-neutral protocol.
#
# It creates two isolated Egregore checkouts backed by the same local bare
# memory repo, then verifies that two simulated Codex agents can exchange a
# handoff, a question, and an answer without Claude Code.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t egregore-agent-protocol-XXXXXX)"
# Exercise real local Git/Runtime transactions, never the launching session's
# credentials, runtime indexes, global Git configuration or package installers.
trap 'rm -rf "$TMP"' EXIT
while IFS='=' read -r fixture_name _; do
  case "$fixture_name" in
    EGREGORE_*|QMD_*|CODEX_THREAD_ID|CLAUDE_SESSION_ID|GIT_CONFIG_*|GIT_DIR|GIT_WORK_TREE)
      unset "$fixture_name" ;;
  esac
done < <(env)
export HOME="$TMP/home"
export XDG_CACHE_HOME="$HOME/.cache" XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_ALLOW_PROTOCOL=file PYTHONPATH=""
export EGREGORE_CANONICAL_ONLY=1 EGREGORE_NO_TELEMETRY=1
export EGREGORE_LIFECYCLE_STATE_DIR="$TMP/lifecycle"
export EGREGORE_QMD_BIN="$TMP/fake-bin/qmd" EGREGORE_QMD_PERSISTENT=0
export FIXTURE_EXTERNAL_CALLS="$TMP/external-calls"
mkdir -p "$HOME" "$TMP/fake-bin"
# Search/index provisioning is outside this protocol test. An unavailable QMD
# must not prevent canonical memory exchanges, and must not trigger npm installs.
cat > "$EGREGORE_QMD_BIN" <<'EOF'
#!/bin/sh
printf 'qmd\n' >> "$FIXTURE_EXTERNAL_CALLS"
printf 'QMD unavailable in the isolated protocol fixture\n' >&2
exit 1
EOF
for fixture_command in npm npx gh curl wget ssh; do
  cat > "$TMP/fake-bin/$fixture_command" <<'EOF'
#!/bin/sh
printf 'unexpected:%s\n' "${0##*/}" >> "$FIXTURE_EXTERNAL_CALLS"
exit 1
EOF
done
chmod +x "$TMP/fake-bin/"*
export PATH="$TMP/fake-bin:$PATH"

# Canonical synchronization still runs through the actual Runtime. Its expected
# degraded exit must name our retrieval double, not conceal a Git/sync failure.
sync_canonical() {
  local output result=0
  output="$(bash "$1/bin/agent.sh" sync)" || result=$?
  [ "$result" -eq 1 ] || return 1
  grep -q '^synchronization: degraded$' <<< "$output" || return 1
  grep -q '^canonical current: yes$' <<< "$output" || return 1
  grep -q 'QMD unavailable in the isolated protocol fixture' <<< "$output" || return 1
  printf '%s\n' "$output"
}

copy_runtime() {
  local dest="$1"
  mkdir -p "$dest/bin" "$dest/bin/lib"
  cp "$ROOT/bin/agent.sh" "$dest/bin/agent.sh"
  cp "$ROOT/bin/worktree.sh" "$dest/bin/worktree.sh"
  cp "$ROOT/bin/capture-run.sh" "$dest/bin/capture-run.sh"
  cp "$ROOT/bin/capture-reconcile.sh" "$dest/bin/capture-reconcile.sh"
  cp "$ROOT/bin/handoff-run.sh" "$dest/bin/handoff-run.sh"
  cp "$ROOT/bin/repo-state.sh" "$dest/bin/repo-state.sh"
  cp "$ROOT/bin/index-handoff.sh" "$dest/bin/index-handoff.sh"
  cp "$ROOT/bin/graph.sh" "$dest/bin/graph.sh"
  cp "$ROOT/bin/graph-wal.sh" "$dest/bin/graph-wal.sh"
  cp "$ROOT/bin/handoff-pr-backfill.sh" "$dest/bin/handoff-pr-backfill.sh"
  cp "$ROOT/bin/publish-artifact.sh" "$dest/bin/publish-artifact.sh"
  cp "$ROOT/bin/artifact-writeback.sh" "$dest/bin/artifact-writeback.sh"
  cp "$ROOT/bin/question.sh" "$dest/bin/question.sh"
  cp -R "$ROOT/bin/lib/." "$dest/bin/lib/"
  cp -R "$ROOT/egregore_runtime" "$dest/egregore_runtime"
}

write_config() {
  local dest="$1"
  local person="$2"
  cat > "$dest/egregore.json" <<'JSON'
{
  "mode": "local",
  "org_name": "Agent Protocol Smoke",
  "github_org": "local",
  "slug": "agent-protocol-smoke",
  "repo_name": "egregore",
  "base_branch": "main",
  "repos": []
}
JSON
  cat > "$dest/.egregore-state.json" <<JSON
{
  "github_username": "$person",
  "github_name": "$person",
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
  write_config "$core" "$person"
  cat > "$core/.gitignore" <<'EOF'
memory
.env
.egregore-state.json
.egregore-session-id
EOF
  git -C "$core" init --quiet
  git -C "$core" config user.name "$person"
  git -C "$core" config user.email "$person@example.test"
  # The runtime package is tracked like it is in a real instance, so a raw
  # worktree of the instance carries its own copy (launchers no longer fall
  # back to whatever package sits in the working directory).
  git -C "$core" add bin egregore_runtime egregore.json .gitignore
  git -C "$core" commit -m "Init portable agent runtime" --quiet
  git -C "$core" branch -M main
  git init --bare --initial-branch=main --quiet "$base/origin.git"
  git -C "$core" remote add origin "$base/origin.git"
  git -C "$core" push --quiet -u origin main

  git clone --quiet "$TMP/memory.git" "$memory"
  git -C "$memory" config user.name "$person"
  git -C "$memory" config user.email "$person@example.test"
  ln -s "$memory" "$core/memory"
}

# Seed the shared memory remote.
git init --bare --initial-branch=main --quiet "$TMP/memory.git"
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
cat > "$TMP/seed/people/prime-c.md" <<'EOF'
---
name: prime-c
github: prime-c
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
setup_instance "agent-c" "prime-c"

A="$TMP/agent-a/egregore"
B="$TMP/agent-b/egregore"
C="$TMP/agent-c/egregore"

git -C "$A" branch raw-codex-worktree HEAD
RAW_WT="$TMP/raw-codex-worktree"
git -C "$A" worktree add "$RAW_WT" raw-codex-worktree --quiet
RAW_SYNC="$(sync_canonical "$RAW_WT")"
grep -q "synchronization:" <<< "$RAW_SYNC"
[ -L "$RAW_WT/memory" ]
[ -L "$RAW_WT/.egregore-state.json" ]

# Reproduce the legacy bug: task branches created from the configured base used to
# inherit it as their upstream. Reusing the branch must repair that state.
git -C "$A" branch dev/codex/codex-branch-smoke origin/main --quiet
BRANCH_OUT="$(bash "$A/bin/agent.sh" branch --topic "codex branch smoke")"
grep -q "branch: dev/codex-a/codex-branch-smoke" <<< "$BRANCH_OUT"
BRANCH_WT="$(echo "$BRANCH_OUT" | sed -n 's/^worktree: //p' | head -1)"
[ -d "$BRANCH_WT" ]
[ -L "$BRANCH_WT/memory" ]
[ "$(git -C "$BRANCH_WT" branch --show-current)" = "dev/codex-a/codex-branch-smoke" ]
if git -C "$BRANCH_WT" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  echo "task branch unexpectedly tracks the integration branch" >&2
  exit 1
fi

printf 'portable save smoke\n' > "$BRANCH_WT/save-smoke.txt"
SAVE_OUT="$(bash "$BRANCH_WT/bin/agent.sh" save --message "Save: codex branch smoke" --topic "codex branch smoke" --no-pr)"
grep -q "branch: dev/codex-a/codex-branch-smoke" <<< "$SAVE_OUT"
grep -q "commit: true" <<< "$SAVE_OUT"
LAST_COMMIT="$(git -C "$BRANCH_WT" log -1 --format=%s)"
grep -q "Save: codex branch smoke" <<< "$LAST_COMMIT"

WRAP_OUT="$(bash "$A/bin/agent.sh" wrap \
  --from codex-a \
  --topic "wrap smoke" \
  --summary "codex-a verified portable wrap." \
  --body "The wrap command writes to memory/wraps and pushes through the shared memory repo.")"
grep -q "wrap: memory/wraps/" <<< "$WRAP_OUT"
[ -n "$(find "$A/memory/wraps" -type f -name '*wrap-smoke.md' | head -1)" ]
grep -q '^\*\*Capture Schema\*\*: egregore-capture/v1$' \
  "$(find "$A/memory/wraps" -type f -name '*wrap-smoke.md' | head -1)"

HANDOFF_OUT="$(bash "$A/bin/agent.sh" handoff \
  --from codex-a \
  --to codex-b \
  --topic "relay smoke" \
  --body "codex-a leaves a runtime-neutral handoff for codex-b." \
  --no-publish \
  --no-notify)"
grep -q "status: ⇌ saved" <<< "$HANDOFF_OUT"
grep -q "handoff: memory/handoffs/" <<< "$HANDOFF_OUT"
grep -q "result: " <<< "$HANDOFF_OUT"
HANDOFF_FILE="$(find "$A/memory/handoffs" -type f -name '*relay-smoke.md' | head -1)"
[ -n "$HANDOFF_FILE" ]
grep -Eq '^intent: "?action"?$' "$HANDOFF_FILE"
grep -Eq '^capture_schema: "?egregore-capture/v1"?$' "$HANDOFF_FILE"
grep -Eq '^capture_mode: "?addressed"?$' "$HANDOFF_FILE"
grep -Eq '^content_mode: "?supplied"?$' "$HANDOFF_FILE"
grep -q '^addressed_to: "codex-b"$' "$HANDOFF_FILE"
grep -q '^codex-a leaves a runtime-neutral handoff for codex-b\.$' "$HANDOFF_FILE"
! grep -q '^## Next Steps$' "$HANDOFF_FILE"

sync_canonical "$B"
ACTIVITY_B="$(bash "$B/bin/agent.sh" activity --for codex-b)"
grep -q "relay smoke" <<< "$ACTIVITY_B"
grep -q "codex-a" <<< "$ACTIVITY_B"

bash "$B/bin/agent.sh" ask \
  --from codex-b \
  --to codex-a \
  --topic "relay smoke" \
  --question "What should codex-b verify next?"

sync_canonical "$A"
ACTIVITY_A="$(bash "$A/bin/agent.sh" activity --for codex-a)"
grep -q "What should codex-b verify next" <<< "$ACTIVITY_A" || grep -q "relay smoke" <<< "$ACTIVITY_A"

QUESTION_FILE="$(find "$A/memory/knowledge/questions" -type f -name '*relay-smoke*.md' | head -1)"
[ -n "$QUESTION_FILE" ]

bash "$A/bin/agent.sh" answer \
  --from codex-a \
  --question "$QUESTION_FILE" \
  --body "Verify the exchange from a fresh memory clone."

sync_canonical "$B"
ANSWERED_FILE="$(find "$B/memory/knowledge/questions" -type f -name '*relay-smoke*.md' | head -1)"
grep -Eq '^status: "?answered"?$' "$ANSWERED_FILE"
grep -q "Verify the exchange from a fresh memory clone." "$ANSWERED_FILE"

# Third simulated runtime (Prime Agent's shell surface drives the identical
# protocol): the exchange must be runtime-count-independent.
sync_canonical "$C"
ACTIVITY_C="$(bash "$C/bin/agent.sh" activity --for prime-c)"
grep -qv "error" <<< "$ACTIVITY_C"

HANDOFF_C_OUT="$(bash "$C/bin/agent.sh" handoff \
  --from prime-c \
  --to codex-a \
  --topic "prime relay smoke" \
  --body "prime-c leaves a runtime-neutral handoff for codex-a." \
  --no-publish \
  --no-notify)"
grep -q "status: ⇌ saved" <<< "$HANDOFF_C_OUT"
HANDOFF_C_FILE="$(find "$C/memory/handoffs" -type f -name '*prime-relay-smoke.md' | head -1)"
[ -n "$HANDOFF_C_FILE" ]
grep -Eq '^capture_schema: "?egregore-capture/v1"?$' "$HANDOFF_C_FILE"
grep -q '^addressed_to: "codex-a"$' "$HANDOFF_C_FILE"

sync_canonical "$A"
ACTIVITY_A2="$(bash "$A/bin/agent.sh" activity --for codex-a)"
grep -q "prime relay smoke" <<< "$ACTIVITY_A2"
grep -q "prime-c" <<< "$ACTIVITY_A2"

[ -s "$FIXTURE_EXTERNAL_CALLS" ]
if grep -q '^unexpected:' "$FIXTURE_EXTERNAL_CALLS"; then
  echo "protocol fixture attempted an external command" >&2
  exit 1
fi
echo "agent protocol smoke: ok"
