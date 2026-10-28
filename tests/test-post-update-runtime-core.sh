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

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
