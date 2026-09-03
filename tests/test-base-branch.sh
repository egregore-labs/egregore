#!/usr/bin/env bash
# Base-branch resolution: the core repo's integration branch is configurable.
#
# History: _get_base_branch() early-returned the literal "develop" whenever it
# was called without a repo name — so managed repos could declare a base_branch
# and the instance's own repo could not. Solo operators who wanted one branch
# had no way to say so, and session start created (and pushed) a develop branch
# into their remote every session.
#
# The default must not move when a valid config omits base_branch. Resolution
# failures must stop: treating unreadable or invalid config as "develop" lets
# startup create and push a branch the operator explicitly removed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi
}
reject() { # reject <description> <json-body-or-empty> [repo-name]
  local description="$1" body="$2" repo_name="${3:-}" output status
  if [ -n "$body" ]; then
    printf '%s' "$body" > "$TMP/egregore.json"
    output=$(CONFIG="$TMP/egregore.json" _get_base_branch "$repo_name" 2>/dev/null)
    status=$?
  else
    output=$(CONFIG="$TMP/nope.json" _get_base_branch "$repo_name" 2>/dev/null)
    status=$?
  fi
  if [ "$status" -ne 0 ] && [ -z "$output" ]; then
    ok "$description"
  else
    bad "$description — expected nonzero with no branch, got status=$status output='$output'"
  fi
}

echo "test-base-branch"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=bin/lib/config.sh
SCRIPT_DIR="$ROOT" . "$ROOT/bin/lib/config.sh"

resolve() { # resolve <json-body> [repo-name]
  printf '%s' "$1" > "$TMP/egregore.json"
  CONFIG="$TMP/egregore.json" _get_base_branch "${2:-}"
}

# --- The default does not move ----------------------------------------------
check "no base_branch → develop (core)" \
  "develop" "$(resolve '{"slug":"acme"}')"
reject "missing config fails closed" ""
reject "malformed config fails closed" '{"base_branch": '

# --- Single-branch mode ------------------------------------------------------
check "base_branch:main → main (core)" \
  "main" "$(resolve '{"base_branch": "main"}')"
check "arbitrary base_branch is honored" \
  "trunk" "$(resolve '{"base_branch": "trunk"}')"
reject "wrong-typed core base_branch fails closed" \
  '{"base_branch": {"name": "main"}}'
reject "null core base_branch fails closed" \
  '{"base_branch": null}'
reject "invalid git ref fails closed" \
  '{"base_branch": "not a branch"}'

# --- Managed repos keep their own resolution ---------------------------------
check "managed repo reads its own base_branch" \
  "main" "$(resolve '{"base_branch":"trunk","repos":[{"name":"app","base_branch":"main"}]}' app)"
check "managed repo without base_branch → develop, not the core's" \
  "develop" "$(resolve '{"base_branch":"trunk","repos":[{"name":"app"}]}' app)"
check "unknown managed repo → develop" \
  "develop" "$(resolve '{"base_branch":"trunk","repos":[{"name":"app"}]}' ghost)"
check "string-form repo entry → develop" \
  "develop" "$(resolve '{"repos":["app"]}' app)"
reject "wrong-typed managed base_branch fails closed" \
  '{"repos":[{"name":"app","base_branch":false}]}' app

# --- Real main-only startup regression --------------------------------------
# Exercise session-start.sh in an actual repository/remote. The config was a
# valid main-only config and now contains an invalid explicit base (simulating
# a partial/corrupt edit). Startup must stop without recreating develop locally
# or pushing it to origin.
REMOTE="$TMP/main-only.git"
CHECKOUT="$TMP/main-only"
git init --bare -q "$REMOTE"
git clone -q "$REMOTE" "$CHECKOUT"
git -C "$CHECKOUT" checkout -qb main
printf '%s\n' base > "$CHECKOUT/README.md"
printf '%s\n' '{"base_branch":"main","mode":"local","upstream_url":"none"}' > "$CHECKOUT/egregore.json"
mkdir -p "$CHECKOUT/bin"
cp -R "$ROOT/bin/." "$CHECKOUT/bin/"
printf '%s\n' '{"github_username":"testuser","onboarding_complete":true}' > "$CHECKOUT/.egregore-state.json"
git -C "$CHECKOUT" add README.md egregore.json bin .egregore-state.json
git -C "$CHECKOUT" -c user.name=test -c user.email=test@example.com commit -qm init
git -C "$CHECKOUT" push -qu origin main
printf '%s\n' '{"base_branch":false,"mode":"local","upstream_url":"none"}' > "$CHECKOUT/egregore.json"

mkdir -p "$TMP/home"
if HOME="$TMP/home" bash "$CHECKOUT/bin/session-start.sh" >"$TMP/session.out" 2>"$TMP/session.err"; then
  bad "main-only startup accepts an invalid explicit base"
else
  ok "main-only startup stops on an invalid explicit base"
fi
if git -C "$CHECKOUT" show-ref --verify --quiet refs/heads/develop \
   || git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/develop; then
  bad "failed resolution created or pushed develop"
else
  ok "failed resolution leaves main-only local and remote branch sets unchanged"
fi
if HOME="$TMP/home" bash "$CHECKOUT/bin/agent.sh" branch --topic "must not branch" \
   >"$TMP/agent.out" 2>"$TMP/agent.err"; then
  bad "agent bridge branches after base resolution fails"
else
  ok "agent bridge stops before branching when base resolution fails"
fi
if git -C "$CHECKOUT" for-each-ref --format='%(refname:short)' refs/heads/dev/ | grep -q .; then
  bad "failed agent resolution created a working branch"
else
  ok "failed agent resolution leaves working branches unchanged"
fi

# --- The plumbing routes through it ------------------------------------------
# A literal `develop` left in the git machinery silently defeats the config.
for f in bin/session-start.sh bin/lib/git-sync.sh; do
  LEFTOVER=$(grep -nE "(checkout|branch -f|fetch origin|merge --ff-only|rev-list|show-ref)[^#]*[^/\$\"{]develop" "$ROOT/$f" \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  if [ -z "$LEFTOVER" ]; then
    ok "$f: no hardcoded develop in git operations"
  else
    bad "$f: git operations still name develop directly:"
    printf '%s\n' "$LEFTOVER" >&2
  fi
done

if grep -q 'origin/\${BASE_BRANCH}' "$ROOT/.claude/hooks/branch-guard.sh"; then
  ok "branch-guard tells the agent to branch from the configured base"
else
  bad "branch-guard still hardcodes the branch point"
fi

if grep -q '_get_base_branch' "$ROOT/.claude/skills/save/SKILL.md"; then
  ok "/save resolves the PR base instead of assuming develop"
else
  bad "/save no longer resolves the PR base"
fi

mkdir -p "$TMP/save-check/bin/lib"
cp "$ROOT/bin/lib/config.sh" "$TMP/save-check/bin/lib/config.sh"
printf '%s' '{"base_branch":"main"}' > "$TMP/save-check/egregore.json"
SAVE_BASE=$(cd "$TMP/save-check" && bash -c 'SCRIPT_DIR="$PWD"; CONFIG="$PWD/egregore.json"; . "$PWD/bin/lib/config.sh" 2>/dev/null && _get_base_branch')
check "/save resolver executes against the checkout config" "main" "$SAVE_BASE"

if grep -q '_get_base_branch' "$ROOT/bin/agent.sh" &&
   ! grep -qE '(fetch origin develop|--base develop|origin/develop\.\.\.HEAD)' "$ROOT/bin/agent.sh"; then
  ok "agent bridge branches and saves against the configured base"
else
  bad "agent bridge still assumes develop"
fi

if grep -q 'branch --no-track.*origin/\$BASE_BRANCH' "$ROOT/bin/worktree-create.sh"; then
  ok "worktree creator branches from the configured base without tracking it"
else
  bad "worktree creator does not safely detach task branches from the configured base"
fi

if grep -q 'fetch origin \$BASE_BRANCH' "$ROOT/bin/lib/greeting.sh" &&
   ! grep -q 'fetch origin develop' "$ROOT/bin/lib/greeting.sh"; then
  ok "first-session branch guidance uses the configured base"
else
  bad "first-session branch guidance still assumes develop"
fi

if grep -q 'configuredBaseBranch' "$ROOT/.codex/hooks/branch-guard.js" &&
   grep -q '_get_base_branch' "$ROOT/.codex/skills/save/SKILL.md"; then
  ok "Codex guard and save workflow honor the configured base"
else
  bad "Codex base-branch behavior is incomplete"
fi

if grep -q 'config.base_branch' "$ROOT/.pi/extensions/egregore.ts" &&
   grep -q 'origin/{base}' "$ROOT/.pi/APPEND_SYSTEM.md"; then
  ok "Pi guard and instructions honor the configured base"
else
  bad "Pi base-branch behavior is incomplete"
fi

if grep -q 'git status --porcelain' "$ROOT/bin/lib/git-sync.sh" &&
   grep -Fq '[ -z "$(git status --porcelain' "$ROOT/bin/lib/git-sync.sh"; then
  ok "base sync never hard-resets a dirty checkout"
else
  bad "base sync can hard-reset dirty work"
fi

for skill in branch commit pr pull push; do
  if grep -q '_get_base_branch' "$ROOT/.claude/skills/$skill/SKILL.md"; then
    ok "/$skill resolves the configured base"
  else
    bad "/$skill still assumes a fixed base"
  fi
done

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
