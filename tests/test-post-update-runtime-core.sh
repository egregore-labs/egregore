#!/usr/bin/env bash
# Regression test for the Runtime core migration in bin/post-update.sh.
#
# History: /update copied bin/ but not egregore_runtime/, so instances got the
# Runtime adapters without the module they import and every recall failed. The
# overlay running an /update is the instance's previous copy, loaded before
# bin/ changes, so the newly synced post-update.sh copies the core instead.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t egregore-post-update-core-XXXXXX)"
PASS=0
FAIL=0
trap 'rm -rf "$TMP"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
check() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1 — expected '$2', got '$3'"
  fi
}

echo "test-post-update-runtime-core"

make_instance() {
  local name="$1" upstream_has_core="$2"
  local dir="$TMP/$name"
  local repo="$dir/repo"
  local upstream_work="$dir/upstream-work"
  local upstream="$dir/upstream.git"

  mkdir -p "$dir"
  git init --bare --initial-branch=main --quiet "$upstream"
  git init --initial-branch=main --quiet "$upstream_work"
  git -C "$upstream_work" config user.name "Upstream Test"
  git -C "$upstream_work" config user.email "upstream@example.test"
  mkdir -p "$upstream_work/bin"
  printf 'echo adapter\n' > "$upstream_work/bin/search.sh"
  if [ "$upstream_has_core" = "true" ]; then
    mkdir -p "$upstream_work/egregore_runtime"
    printf '# upstream core\n' > "$upstream_work/egregore_runtime/runtime.py"
  fi
  git -C "$upstream_work" add -A
  git -C "$upstream_work" commit -m "Upstream framework" --quiet
  git -C "$upstream_work" remote add origin "$upstream"
  git -C "$upstream_work" push -u origin main --quiet

  git init --initial-branch=develop --quiet "$repo"
  git -C "$repo" config user.name "Post Update Test"
  git -C "$repo" config user.email "post-update@example.test"
  mkdir -p "$repo/bin/lib"
  cp "$ROOT/bin/post-update.sh" "$repo/bin/post-update.sh"
  cp "$ROOT/bin/lib/runtime-owned.sh" "$repo/bin/lib/runtime-owned.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/artifact-renderer-install.sh"
  printf 'echo adapter\n' > "$repo/bin/search.sh"
  printf '{"mode":"local","slug":"post-update-test"}\n' > "$repo/egregore.json"
  git -C "$repo" add -A
  git -C "$repo" commit -m "Seed instance" --quiet
  git -C "$repo" remote add upstream "$upstream"
  git -C "$repo" fetch upstream main --quiet

  printf '%s\n' "$repo"
}

run_post_update() {
  (cd "$1" && bash bin/post-update.sh)
}

# --- Adapters without the core: one /update brings it in -------------------
missing="$(make_instance missing true)"
output="$(run_post_update "$missing")"
check "post-update succeeds when the core is missing" "0" "$?"
check "core arrives from upstream" "# upstream core" "$(cat "$missing/egregore_runtime/runtime.py" 2>/dev/null)"
check "core is staged for the update commit" \
  "A  egregore_runtime/runtime.py" "$(git -C "$missing" status --porcelain -- egregore_runtime)"
check "migration reports the added core" \
  "  ✓ Added the Runtime core (egregore_runtime/)" "$(printf '%s\n' "$output" | grep -F 'Runtime core')"

# --- Core already present: left untouched ----------------------------------
present="$(make_instance present true)"
mkdir -p "$present/egregore_runtime"
printf '# local core\n' > "$present/egregore_runtime/runtime.py"
run_post_update "$present" >/dev/null
check "existing core is not overwritten" "# local core" "$(cat "$present/egregore_runtime/runtime.py")"

# --- Upstream without the core: nothing to copy, no failure -----------------
absent="$(make_instance absent false)"
run_post_update "$absent" >/dev/null
check "post-update succeeds when upstream lacks the core" "0" "$?"
check "no core is invented" "missing" "$([ -e "$absent/egregore_runtime" ] && echo present || echo missing)"

# --- Runtime-managed installation: the package owns the core ----------------
owned="$(make_instance owned true)"
mkdir -p "$owned/.egregore"
hash="$(printf '%064d' 0)"
jq -n --arg h "$hash" '{package:"create-egregore", version:"0.21.4",
  files:{"egregore_runtime/runtime.py":{hash:$h}, "egregore_runtime/harness_cli.py":{hash:$h}}}' \
  > "$owned/.egregore/claude-runtime-manifest.json"
run_post_update "$owned" >/dev/null
check "Runtime-managed installation is left alone" "missing" \
  "$([ -e "$owned/egregore_runtime" ] && echo present || echo missing)"

# --- Execute the skill's migration/commit blocks in their documented order --
# Model the first update through the old overlay: bin/ has arrived, but the
# core is still absent. The actual skill must commit the migration before it
# rebases the invoking worktree; testing post-update.sh alone misses this.
worktree_repo="$(make_instance worktree true)"
for dir in .claude .pi .prime loom skills .codex/skills; do
  mkdir -p "$worktree_repo/$dir"
  touch "$worktree_repo/$dir/.keep"
done
touch "$worktree_repo/CLAUDE.md" "$worktree_repo/AGENTS.md" "$worktree_repo/.codex/spec-manifest.json"
git -C "$worktree_repo" add -A
git -C "$worktree_repo" commit -qm "Seed framework paths"
git init --bare --initial-branch=develop --quiet "$TMP/worktree/origin.git"
git -C "$worktree_repo" remote add origin "$TMP/worktree/origin.git"
git -C "$worktree_repo" push -u origin develop --quiet
invoking="$TMP/worktree/task"
git -C "$worktree_repo" worktree add -qb task "$invoking"
printf 'echo updated adapter\n' > "$worktree_repo/bin/search.sh"

python3 - "$ROOT/.claude/skills/update/SKILL.md" "$worktree_repo" > "$TMP/worktree/finish.sh" <<'PY'
import pathlib
import re
import sys

skill = pathlib.Path(sys.argv[1]).read_text()
for block in re.findall(r"```bash\n(.*?)```", skill, re.S):
    if "bin/post-update.sh" not in block and "EGREGORE_FRAMEWORK_UPDATE=1" not in block:
        continue
    for key, value in {
        "main_dir": sys.argv[2], "in_worktree": "true", "base": "develop",
        "switched": "false", "current_branch": "task",
    }.items():
        block = block.replace("{" + key + "}", value)
    print(block)
PY

(cd "$invoking" && bash "$TMP/worktree/finish.sh") > "$TMP/worktree/result.log" 2>&1
check "documented worktree update completes" "0" "$?"
check "migration is included in the base commit" "# upstream core" \
  "$(git -C "$worktree_repo" show HEAD:egregore_runtime/runtime.py 2>/dev/null)"
check "first update delivers the core to the invoking worktree" "# upstream core" \
  "$(cat "$invoking/egregore_runtime/runtime.py" 2>/dev/null)"
check "migration leaves no staged core behind" "" \
  "$(git -C "$worktree_repo" status --porcelain -- egregore_runtime)"

# A failed migration must not publish the overlay or move the task branch.
base_before="$(git -C "$worktree_repo" rev-parse HEAD)"
task_before="$(git -C "$invoking" rev-parse HEAD)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$worktree_repo/bin/post-update.sh"
printf 'echo next adapter\n' > "$worktree_repo/bin/search.sh"
(cd "$invoking" && bash "$TMP/worktree/finish.sh") > "$TMP/worktree/failure.log" 2>&1
check "failed migration stops the documented workflow" "1" "$?"
check "failed migration does not commit the overlay" "$base_before" \
  "$(git -C "$worktree_repo" rev-parse HEAD)"
check "failed migration does not move the worktree" "$task_before" \
  "$(git -C "$invoking" rev-parse HEAD)"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
