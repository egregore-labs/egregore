#!/usr/bin/env bash
# Regression tests for the migrations in bin/post-update.sh: the Runtime core
# and the saved hosted address.
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
  cp "$ROOT/bin/lib/config.sh" "$repo/bin/lib/config.sh"
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
printf '#!/usr/bin/env bash\nexit 1\n' > "$worktree_repo/bin/artifact-renderer-install.sh"
printf 'echo next adapter\n' > "$worktree_repo/bin/search.sh"
(cd "$invoking" && bash "$TMP/worktree/finish.sh") > "$TMP/worktree/failure.log" 2>&1
check "failed migration stops the documented workflow" "1" "$?"
check "failed migration does not commit the overlay" "$base_before" \
  "$(git -C "$worktree_repo" rev-parse HEAD)"
check "failed migration does not move the worktree" "$task_before" \
  "$(git -C "$invoking" rev-parse HEAD)"

# --- Saved hosted address: the retired origin is rewritten once ------------
# History: Connected setups before 22 Oct 2026 saved the hosted API's Railway
# origin, which the October security reset retired. /update rewrites exactly
# that value, keeps every other key, stages it for the update commit, and does
# nothing on a second run or for any other address.
RETIRED="https://egregore-production-55f2.up.railway.app"
seed_config() { # seed_config <repo> <json>: commit a 2-space egregore.json
  printf '%s\n' "$2" | jq --indent 2 . > "$1/egregore.json"
  git -C "$1" add egregore.json
  git -C "$1" commit -qm "Seed config"
}

address="$(make_instance address true)"
seed_config "$address" "{\"org_name\":\"Acme\",\"mode\":\"connected\",\"api_url\":\"$RETIRED/\",\"slug\":\"acme\",\"repos\":[\"code\",{\"name\":\"site\",\"base_branch\":\"main\"}],\"features\":{\"publishing\":false}}"
before="$(jq -S 'del(.api_url)' "$address/egregore.json")"
output="$(run_post_update "$address")"
check "post-update succeeds on a retired address" "0" "$?"
check "the retired address becomes the hosted API" "https://api.egregore.xyz" "$(jq -r .api_url "$address/egregore.json")"
check "every other key is kept" "$before" "$(jq -S 'del(.api_url)' "$address/egregore.json")"
check "key order and the repository's 2-space JSON are kept" \
  "$(git -C "$address" show HEAD:egregore.json | jq --indent 2 --arg u https://api.egregore.xyz '.api_url = $u')" \
  "$(cat "$address/egregore.json")"
check "the rewrite is staged for the update commit" "M  egregore.json" "$(git -C "$address" status --porcelain -- egregore.json)"
check "migration reports the new address in plain words" \
  "  ✓ Hosted services address updated after the October security reset" \
  "$(printf '%s\n' "$output" | grep -F 'Hosted services address')"
git -C "$address" commit -qm "Update Egregore framework from upstream"
second="$(run_post_update "$address")"
check "a second run changes nothing" "" "$(git -C "$address" status --porcelain -- egregore.json)"
check "a second run reports no address change" "" "$(printf '%s\n' "$second" | grep -F 'Hosted services address')"

mixed="$(make_instance mixed true)"
seed_config "$mixed" '{"mode":"connected","api_url":"https://EGREGORE-Production-55F2.UP.Railway.App","slug":"acme"}'
run_post_update "$mixed" >/dev/null
check "any case in the retired host is rewritten" "https://api.egregore.xyz" "$(jq -r .api_url "$mixed/egregore.json")"

kept_index=0
for kept in "https://api.egregore.xyz" "https://egregore.example.org" "https://egregore.example.org/" "http://127.0.0.1:8765" "$RETIRED/api/v1"; do
  kept_index=$((kept_index + 1))
  other="$(make_instance "kept-$kept_index" true)"
  seed_config "$other" "{\"mode\":\"connected\",\"api_url\":\"$kept\",\"slug\":\"acme\"}"
  snapshot="$(cat "$other/egregore.json")"
  run_post_update "$other" >/dev/null
  check "$kept is left as saved" "$snapshot" "$(cat "$other/egregore.json")"
done

local_cfg="$(make_instance local true)"
snapshot="$(cat "$local_cfg/egregore.json")"
run_post_update "$local_cfg" >/dev/null
check "a Local config is left untouched" "$snapshot" "$(cat "$local_cfg/egregore.json")"
check "a Local config stages nothing" "" "$(git -C "$local_cfg" status --porcelain -- egregore.json)"

local_retired="$(make_instance local-retired true)"
seed_config "$local_retired" "{\"mode\":\"local\",\"api_url\":\"$RETIRED\",\"slug\":\"acme\"}"
snapshot="$(cat "$local_retired/egregore.json")"
run_post_update "$local_retired" >/dev/null
check "a Local config that still names the retired address is left untouched" "$snapshot" \
  "$(cat "$local_retired/egregore.json")"
check "a Local config with the retired address stages nothing" "" \
  "$(git -C "$local_retired" status --porcelain -- egregore.json)"

# An unrelated edit someone left in egregore.json stays theirs: only the
# address reaches the index, so /update never commits or pushes the edit.
dirty="$(make_instance dirty true)"
seed_config "$dirty" "{\"mode\":\"connected\",\"api_url\":\"$RETIRED\",\"slug\":\"acme\",\"features\":{\"publishing\":false}}"
jq --indent 2 '.features.publishing = true' "$dirty/egregore.json" > "$dirty/edited.json"
mv "$dirty/edited.json" "$dirty/egregore.json"
output="$(run_post_update "$dirty")"
check "a dirty egregore.json still gets the new address" "https://api.egregore.xyz" \
  "$(jq -r .api_url "$dirty/egregore.json")"
check "the unrelated edit stays in the working file" "true" "$(jq -r .features.publishing "$dirty/egregore.json")"
check "the index carries the new address" "https://api.egregore.xyz" \
  "$(git -C "$dirty" show :egregore.json | jq -r .api_url)"
check "the index does not carry the unrelated edit" "false" \
  "$(git -C "$dirty" show :egregore.json | jq -r .features.publishing)"
check "the unrelated edit is still unstaged" "MM egregore.json" \
  "$(git -C "$dirty" status --porcelain -- egregore.json)"
check "a dirty run reports the new address" \
  "  ✓ Hosted services address updated after the October security reset" \
  "$(printf '%s\n' "$output" | grep -F 'Hosted services address')"
git -C "$dirty" commit -qm "Update Egregore framework from upstream"
check "the update commit changes only the address" '[["api_url"]]' \
  "$(jq -c -n --slurpfile a <(git -C "$dirty" show HEAD~1:egregore.json) --slurpfile b <(git -C "$dirty" show HEAD:egregore.json) \
    '[($a[0] | paths(scalars)) as $p | select(($a[0] | getpath($p)) != ($b[0] | getpath($p))) | $p]')"
check "the edit remains for its author after the commit" " M egregore.json" \
  "$(git -C "$dirty" status --porcelain -- egregore.json)"

# A staged edit is kept too: the index copy changes only its address.
staged="$(make_instance staged true)"
seed_config "$staged" "{\"mode\":\"connected\",\"api_url\":\"$RETIRED\",\"slug\":\"acme\",\"org_name\":\"Acme\"}"
jq --indent 2 '.org_name = "Acme Labs"' "$staged/egregore.json" > "$staged/edited.json"
mv "$staged/edited.json" "$staged/egregore.json"
git -C "$staged" add egregore.json
run_post_update "$staged" >/dev/null
check "a staged edit keeps its value in the index" "Acme Labs https://api.egregore.xyz" \
  "$(git -C "$staged" show :egregore.json | jq -r '"\(.org_name) \(.api_url)"')"
check "a staged edit leaves index and working file equal" "M  egregore.json" \
  "$(git -C "$staged" status --porcelain -- egregore.json)"

# --- Saved hosted address: unusual files never stop /update -----------------
# Each case: post-update exits 0, never corrupts or truncates egregore.json,
# keeps its mode, and warns on stderr when it skips.
run_edge() { # run_edge <repo> [PATH]: sets EDGE_STATUS; output in $TMP/edge.out, .err
  local repo="$1" path="${2:-$PATH}"
  EDGE_STATUS=0
  (cd "$repo" && PATH="$path" bash bin/post-update.sh) > "$TMP/edge.out" 2> "$TMP/edge.err" || EDGE_STATUS=$?
}
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
warned() { grep -c -F "$1" "$TMP/edge.err" | tr -d ' '; }
nothing_staged() { git -C "$1" diff --cached --name-only -- egregore.json; }
RETIRED_JSON="{\"mode\":\"connected\",\"api_url\":\"$RETIRED\",\"slug\":\"acme\",\"org_name\":\"Acme\"}"

# A link: its target may belong to something else, so it is left as is.
linked="$(make_instance linked true)"
mkdir -p "$linked/conf"
printf '%s\n' "$RETIRED_JSON" | jq --indent 2 . > "$linked/conf/egregore.real.json"
rm "$linked/egregore.json"
ln -s conf/egregore.real.json "$linked/egregore.json"
git -C "$linked" add -A
git -C "$linked" commit -qm "Config behind a link"
target_before="$(cat "$linked/conf/egregore.real.json")"
run_edge "$linked"
check "a linked egregore.json does not stop /update" "0" "$EDGE_STATUS"
check "the link stays a link" "link" "$([ -L "$linked/egregore.json" ] && echo link)"
check "the link's target is left as is" "$target_before" "$(cat "$linked/conf/egregore.real.json")"
check "a link stages nothing" "" "$(git -C "$linked" diff --cached --name-only -- egregore.json conf)"
check "a link warns where to change the address" "1" "$(warned 'egregore.json is a link')"

# CRLF line endings stay CRLF in both copies.
crlf="$(make_instance crlf true)"
git -C "$crlf" config core.autocrlf false
printf '{\r\n  "mode": "connected",\r\n  "api_url": "%s",\r\n  "slug": "acme"\r\n}\r\n' "$RETIRED" > "$crlf/egregore.json"
git -C "$crlf" add egregore.json
git -C "$crlf" commit -qm "CRLF config"
run_edge "$crlf"
check "a CRLF egregore.json does not stop /update" "0" "$EDGE_STATUS"
check "a CRLF egregore.json gets the new address" "https://api.egregore.xyz" "$(jq -r .api_url "$crlf/egregore.json")"
check "every line of the CRLF working file keeps its CR" "0" \
  "$(awk '!/\r$/ { bad++ } END { print bad + 0 }' "$crlf/egregore.json")"
check "every line of the CRLF index copy keeps its CR" "0" \
  "$(git -C "$crlf" show :egregore.json | awk '!/\r$/ { bad++ } END { print bad + 0 }')"
check "a CRLF rewrite is staged whole" "M  egregore.json" "$(git -C "$crlf" status --porcelain -- egregore.json)"

# An executable file keeps 0755 in the working tree and 100755 in the index.
exec_cfg="$(make_instance exec true)"
seed_config "$exec_cfg" "$RETIRED_JSON"
chmod 755 "$exec_cfg/egregore.json"
git -C "$exec_cfg" update-index --chmod=+x egregore.json
git -C "$exec_cfg" commit -qm "Executable config"
run_edge "$exec_cfg"
check "an executable egregore.json does not stop /update" "0" "$EDGE_STATUS"
check "an executable egregore.json keeps mode 755" "755" "$(file_mode "$exec_cfg/egregore.json")"
check "an executable egregore.json keeps index mode 100755" "100755" \
  "$(git -C "$exec_cfg" ls-files -s -- egregore.json | cut -d' ' -f1)"
check "an executable rewrite is staged" "M  egregore.json" "$(git -C "$exec_cfg" status --porcelain -- egregore.json)"

# A private file keeps 0600.
private_cfg="$(make_instance private true)"
seed_config "$private_cfg" "$RETIRED_JSON"
chmod 600 "$private_cfg/egregore.json"
run_edge "$private_cfg"
check "a private egregore.json does not stop /update" "0" "$EDGE_STATUS"
check "a private egregore.json keeps mode 600" "600" "$(file_mode "$private_cfg/egregore.json")"
check "a private egregore.json gets the new address" "https://api.egregore.xyz" "$(jq -r .api_url "$private_cfg/egregore.json")"

# Sparse: skip-worktree with the file absent from this checkout.
sparse="$(make_instance sparse true)"
seed_config "$sparse" "$RETIRED_JSON"
git -C "$sparse" update-index --skip-worktree egregore.json
rm "$sparse/egregore.json"
run_edge "$sparse"
check "a sparse egregore.json does not stop /update" "0" "$EDGE_STATUS"
check "a sparse egregore.json stays absent" "absent" "$([ -e "$sparse/egregore.json" ] || echo absent)"
check "a sparse egregore.json stages nothing" "" "$(nothing_staged "$sparse")"
check "a sparse egregore.json keeps its committed copy" "$RETIRED" "$(git -C "$sparse" show :egregore.json | jq -r .api_url)"
check "a sparse egregore.json warns" "1" "$(grep -c 'committed hosted address was left as is' "$TMP/edge.err" | tr -d ' ')"

# Skip-worktree with the file present: the working copy changes, the index does not.
set_aside="$(make_instance set-aside true)"
seed_config "$set_aside" "$RETIRED_JSON"
git -C "$set_aside" update-index --skip-worktree egregore.json
run_edge "$set_aside"
check "a set-aside egregore.json does not stop /update" "0" "$EDGE_STATUS"
check "a set-aside egregore.json stages nothing" "" "$(nothing_staged "$set_aside")"
check "a set-aside egregore.json keeps its committed copy" "$RETIRED" "$(git -C "$set_aside" show :egregore.json | jq -r .api_url)"
check "a set-aside egregore.json warns" "1" "$(warned 'is set aside from this checkout')"

# Untracked: removed from the index with git rm --cached.
untracked="$(make_instance untracked true)"
seed_config "$untracked" "$RETIRED_JSON"
git -C "$untracked" rm --cached -q egregore.json
run_edge "$untracked"
check "an untracked egregore.json does not stop /update" "0" "$EDGE_STATUS"
check "an untracked egregore.json gets the new address" "https://api.egregore.xyz" "$(jq -r .api_url "$untracked/egregore.json")"
check "an untracked egregore.json is not added back" "" "$(git -C "$untracked" ls-files -- egregore.json)"
check "an untracked egregore.json keeps only its staged removal" "D	egregore.json" \
  "$(git -C "$untracked" diff --cached --name-status -- egregore.json)"

# Local in either copy: nothing is rewritten.
worktree_local="$(make_instance worktree-local true)"
seed_config "$worktree_local" "$RETIRED_JSON"
jq --indent 2 '.mode = "local"' "$worktree_local/egregore.json" > "$worktree_local/edited.json"
mv "$worktree_local/edited.json" "$worktree_local/egregore.json"
snapshot="$(cat "$worktree_local/egregore.json")"
run_edge "$worktree_local"
check "a working copy switched to Local does not stop /update" "0" "$EDGE_STATUS"
check "a working copy switched to Local is left as is" "$snapshot" "$(cat "$worktree_local/egregore.json")"
check "its Connected index copy is left as is" "$RETIRED" "$(git -C "$worktree_local" show :egregore.json | jq -r .api_url)"
check "a Local working copy stages nothing" "" "$(nothing_staged "$worktree_local")"
check "a Local working copy warns" "1" "$(warned 'Local in one copy and Connected in the other')"

index_local="$(make_instance index-local true)"
seed_config "$index_local" "{\"mode\":\"local\",\"api_url\":\"$RETIRED\",\"slug\":\"acme\"}"
jq --indent 2 '.mode = "connected"' "$index_local/egregore.json" > "$index_local/edited.json"
mv "$index_local/edited.json" "$index_local/egregore.json"
snapshot="$(cat "$index_local/egregore.json")"
run_edge "$index_local"
check "a Local index copy does not stop /update" "0" "$EDGE_STATUS"
check "a Connected working copy over a Local index copy is left as is" "$snapshot" "$(cat "$index_local/egregore.json")"
check "a Local index copy stages nothing" "" "$(nothing_staged "$index_local")"
check "a Local index copy warns" "1" "$(warned 'Local in one copy and Connected in the other')"

# A failing mv leaves the file whole and stages nothing.
mv_fail="$(make_instance mv-fail true)"
seed_config "$mv_fail" "$RETIRED_JSON"
cp "$mv_fail/egregore.json" "$TMP/mv-fail-before.json"
mkdir -p "$TMP/mv-shim"
printf '#!/bin/sh\nexit 1\n' > "$TMP/mv-shim/mv"
chmod +x "$TMP/mv-shim/mv"
run_edge "$mv_fail" "$TMP/mv-shim:$PATH"
check "a failing mv does not stop /update" "0" "$EDGE_STATUS"
check "a failing mv leaves egregore.json byte for byte" "same" \
  "$(cmp -s "$TMP/mv-fail-before.json" "$mv_fail/egregore.json" && echo same)"
check "a failing mv leaves no temporary file" "" "$(cd "$mv_fail" && ls egregore.json.* 2>/dev/null)"
check "a failing mv stages nothing" "" "$(nothing_staged "$mv_fail")"
check "a failing mv warns" "1" "$(warned 'Could not update the hosted services address')"
check "a failing mv reports no update" "0" "$(grep -c -F 'Hosted services address updated' "$TMP/edge.out" | tr -d ' ')"
check "a failing mv puts the index back to the committed copy" "$(git -C "$mv_fail" rev-parse HEAD:egregore.json)" \
  "$(git -C "$mv_fail" ls-files -s -- egregore.json | cut -d' ' -f2)"

# --- Saved hosted address: only the value changes, byte for byte ------------
# commit_raw <repo> <file>: commit <file>'s exact bytes as egregore.json.
commit_raw() {
  cp "$2" "$1/egregore.json"
  git -C "$1" add egregore.json
  git -C "$1" commit -qm "Hand-written config"
}
same_bytes() { cmp -s "$1" "$2" && echo same; }
index_bytes() { git -C "$1" cat-file blob ":egregore.json" > "$2"; }
updated_lines() { grep -c -F 'Hosted services address updated' "$TMP/edge.out" | tr -d ' '; }

# Hand formatting, an inline array and \/ escapes elsewhere all stay.
hand="$(make_instance hand true)"
hand_format='{\n    "org_name" : "Acme",\n  "mode":"connected", "api_url" :  "%s",\n  "repos": ["code", "site"],\n  "docs": "https:\\/\\/example.org\\/guide"\n}\n'
# shellcheck disable=SC2059
printf "$hand_format" "$RETIRED" > "$TMP/hand-before.json"
# shellcheck disable=SC2059
printf "$hand_format" "https://api.egregore.xyz" > "$TMP/hand-after.json"
commit_raw "$hand" "$TMP/hand-before.json"
run_edge "$hand"
check "a hand-formatted egregore.json does not stop /update" "0" "$EDGE_STATUS"
check "a hand-formatted working file changes only its address" "same" "$(same_bytes "$TMP/hand-after.json" "$hand/egregore.json")"
index_bytes "$hand" "$TMP/hand-index.json"
check "a hand-formatted index copy changes only its address" "same" "$(same_bytes "$TMP/hand-after.json" "$TMP/hand-index.json")"
check "a hand-formatted rewrite reports the new address" "1" "$(updated_lines)"

# No trailing newline: none is added.
bare="$(make_instance bare true)"
printf '{"mode":"connected","api_url":"%s","slug":"acme"}' "$RETIRED" > "$TMP/bare-before.json"
printf '{"mode":"connected","api_url":"%s","slug":"acme"}' "https://api.egregore.xyz" > "$TMP/bare-after.json"
commit_raw "$bare" "$TMP/bare-before.json"
run_edge "$bare"
check "a file without a final newline changes only its address" "same" "$(same_bytes "$TMP/bare-after.json" "$bare/egregore.json")"
index_bytes "$bare" "$TMP/bare-index.json"
check "its index copy gains no newline either" "same" "$(same_bytes "$TMP/bare-after.json" "$TMP/bare-index.json")"

# A byte-order mark stays where it is.
bom="$(make_instance bom true)"
printf '\357\273\277{\n  "mode": "connected",\n  "api_url": "%s"\n}\n' "$RETIRED" > "$TMP/bom-before.json"
if printf '\357\273\277{}' | jq -e . >/dev/null 2>&1; then
  printf '\357\273\277{\n  "mode": "connected",\n  "api_url": "%s"\n}\n' "https://api.egregore.xyz" > "$TMP/bom-after.json"
else
  cp "$TMP/bom-before.json" "$TMP/bom-after.json"  # this jq can't read it, so it is left as is
fi
commit_raw "$bom" "$TMP/bom-before.json"
run_edge "$bom"
check "a byte-order mark does not stop /update" "0" "$EDGE_STATUS"
check "a byte-order mark is kept" "same" "$(same_bytes "$TMP/bom-after.json" "$bom/egregore.json")"

# Written any other way, the address is left for the person to change.
for odd in duplicate escaped; do
  odd_repo="$(make_instance "odd-$odd" true)"
  case "$odd" in
    duplicate) printf '{\n  "mode": "connected",\n  "api_url": "%s",\n  "slug": "acme",\n  "api_url": "%s"\n}\n' "$RETIRED" "$RETIRED" > "$TMP/odd-before.json" ;;
    escaped) printf '{\n  "mode": "connected",\n  "api_url": "https:\\/\\/egregore-production-55f2.up.railway.app",\n  "slug": "acme"\n}\n' > "$TMP/odd-before.json" ;;
  esac
  commit_raw "$odd_repo" "$TMP/odd-before.json"
  run_edge "$odd_repo"
  check "a $odd api_url does not stop /update" "0" "$EDGE_STATUS"
  check "a $odd api_url is left byte for byte" "same" "$(same_bytes "$TMP/odd-before.json" "$odd_repo/egregore.json")"
  check "a $odd api_url stages nothing" "" "$(nothing_staged "$odd_repo")"
  check "a $odd api_url asks for the change by hand" "1" "$(warned "can't change safely")"
  check "a $odd api_url reports no update" "0" "$(updated_lines)"
done

# An unreadable file is left as is, with a warning.
unreadable="$(make_instance unreadable true)"
seed_config "$unreadable" "$RETIRED_JSON"
cp "$unreadable/egregore.json" "$TMP/unreadable-before.json"
chmod 000 "$unreadable/egregore.json"
if [ -r "$unreadable/egregore.json" ]; then
  chmod 644 "$unreadable/egregore.json"
  echo "  - skipped: running as a user who can read any file"
else
  run_edge "$unreadable"
  chmod 644 "$unreadable/egregore.json"
  check "an unreadable egregore.json does not stop /update" "0" "$EDGE_STATUS"
  check "an unreadable egregore.json is left byte for byte" "same" \
    "$(same_bytes "$TMP/unreadable-before.json" "$unreadable/egregore.json")"
  check "an unreadable egregore.json stages nothing" "" "$(nothing_staged "$unreadable")"
  check "an unreadable egregore.json warns" "1" "$(warned "egregore.json can't be read")"
fi

# Staging fails (another git process holds the index): the working file is
# never written, so the two copies stay in step.
index_lock="$(make_instance index-lock false)"
seed_config "$index_lock" "$RETIRED_JSON"
cp "$index_lock/egregore.json" "$TMP/index-lock-before.json"
: > "$index_lock/.git/index.lock"
run_edge "$index_lock"
rm -f "$index_lock/.git/index.lock"
check "a locked index does not stop /update" "0" "$EDGE_STATUS"
check "a locked index leaves the working file byte for byte" "same" \
  "$(same_bytes "$TMP/index-lock-before.json" "$index_lock/egregore.json")"
check "a locked index stages nothing" "" "$(nothing_staged "$index_lock")"
check "a locked index warns" "1" "$(warned 'Could not stage the hosted services address')"
check "a locked index reports no update" "0" "$(updated_lines)"


source_cfg="$(make_instance source true)"
seed_config "$source_cfg" "{\"mode\":\"connected\",\"api_url\":\"$RETIRED\",\"slug\":\"acme\",\"upstream_url\":\"none\"}"
run_post_update "$source_cfg" >/dev/null
check "a source instance, which skips the update commit, is left to the resolver" "$RETIRED" \
  "$(jq -r .api_url "$source_cfg/egregore.json")"

# The documented /update flow commits the rewrite with the framework update.
flow="$(make_instance flow true)"
seed_config "$flow" "{\"mode\":\"connected\",\"api_url\":\"$RETIRED\",\"slug\":\"acme\"}"
for dir in .claude .pi .prime loom skills .codex/skills; do
  mkdir -p "$flow/$dir"
  touch "$flow/$dir/.keep"
done
touch "$flow/CLAUDE.md" "$flow/AGENTS.md" "$flow/.codex/spec-manifest.json"
git -C "$flow" add -A
git -C "$flow" commit -qm "Seed framework paths"
git init --bare --initial-branch=develop --quiet "$TMP/flow/origin.git"
git -C "$flow" remote add origin "$TMP/flow/origin.git"
git -C "$flow" push -u origin develop --quiet
flow_task="$TMP/flow/task"
git -C "$flow" worktree add -qb task "$flow_task"
python3 - "$ROOT/.claude/skills/update/SKILL.md" "$flow" > "$TMP/flow/finish.sh" <<'PY'
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
(cd "$flow_task" && bash "$TMP/flow/finish.sh") > "$TMP/flow/result.log" 2>&1
check "documented worktree update completes with the address migration" "0" "$?"
check "the base commit carries the new address" "https://api.egregore.xyz" \
  "$(git -C "$flow" show HEAD:egregore.json | jq -r .api_url)"
check "the update leaves egregore.json clean" "" "$(git -C "$flow" status --porcelain -- egregore.json)"
check "the invoking worktree receives the new address" "https://api.egregore.xyz" \
  "$(jq -r .api_url "$flow_task/egregore.json")"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
