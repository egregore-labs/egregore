#!/usr/bin/env bash
# Settings drift healer: launcher/installer modifications to org-config
# surfaces must not silently strand the checkout behind the base branch.
# Verifies: adapter-clobber restore (and its user-work guard), egregore.json
# key re-apply across the fast-forward, and unshared-settings reporting.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-drift.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

make_fixture() {
  # Fresh origin + clone, both on develop; v1 committed, v2 on origin only.
  rm -rf "$WORK/origin" "$WORK/clone" "$WORK/seed"
  git init --bare --quiet -b develop "$WORK/origin"
  git init --quiet -b develop "$WORK/seed"
  (
    cd "$WORK/seed" || exit 1
    git config user.email t@t && git config user.name t
    mkdir -p .claude
    cat > .claude/settings.json <<'EOF'
{"permissions":{"allow":["Bash","Read"]},"hooks":{"SessionStart":[{"x":1}],"PreCompact":[{"x":1}],"Stop":[{"x":1}]}}
EOF
    printf '{"slug":"acme","org_name":"Acme","mode":"local","features":{"pulse":true}}\n' > egregore.json
    git add -A && git commit --quiet -m v1
    git remote add origin "$WORK/origin" && git push --quiet origin develop
  )
  git clone --quiet "$WORK/origin" "$WORK/clone" 2>/dev/null
  (cd "$WORK/clone" || exit 1; git config user.email t@t && git config user.name t)
  (
    cd "$WORK/seed" || exit 1
    printf '{"slug":"acme","org_name":"Acme","mode":"local","features":{"pulse":true},"schema_version":"egregore-config/v1"}\n' > egregore.json
    cat > .claude/settings.json <<'EOF'
{"permissions":{"allow":["Bash","Read"]},"hooks":{"SessionStart":[{"x":2}],"PreCompact":[{"x":1}],"Stop":[{"x":1}]}}
EOF
    git add -A && git commit --quiet -m v2 && git push --quiet origin develop
  )
  (cd "$WORK/clone" || exit 1; git fetch --quiet origin)
}

drive() {
  # Run heal → ff-merge → reapply → report inside the clone.
  (
    cd "$WORK/clone" || exit 1
    export BASE_BRANCH="develop"
    # shellcheck source=/dev/null
    source "$ROOT/bin/lib/settings-drift.sh"
    settings_drift_heal
    git merge --ff-only "origin/develop" --quiet 2>/dev/null || true
    settings_drift_reapply
    settings_drift_report
    printf '%s\n%s\n%s\n' "$SETTINGS_ADAPTER_RESTORED" "$UNSHARED_SETTINGS_KEYS" "$(git rev-parse HEAD)"
  )
}

# ── 1. clobbered adapter + launcher egregore.json writes heal through ────
make_fixture
(
  cd "$WORK/clone" || exit 1
  # Installer clobber: reduced adapter (subset of hooks, subset of allows)
  printf '{"permissions":{"allow":["Bash"]},"hooks":{"SessionStart":[{"x":1}]}}\n' > .claude/settings.json
  # Launcher writes: posture + tombstones
  jq '.boundary = {posture: "open"} | .people_removed = ["ghost"]' egregore.json > e.tmp && mv e.tmp egregore.json
)
OUT=$(drive)
RESTORED=$(printf '%s' "$OUT" | sed -n 1p)
UNSHARED=$(printf '%s' "$OUT" | sed -n 2p)
HEAD_AFTER=$(printf '%s' "$OUT" | sed -n 3p)
REMOTE=$(git -C "$WORK/clone" rev-parse origin/develop)
[ "$HEAD_AFTER" = "$REMOTE" ] && pass "blocked fast-forward completes after healing" || fail "checkout still behind" "$OUT"
[ "$RESTORED" = "true" ] && pass "reduced generated adapter restored to the org settings" || fail "adapter not restored"
git -C "$WORK/clone" diff --quiet -- .claude/settings.json && pass "settings.json clean against merged base" || fail "settings.json still dirty"
jq -e '.schema_version == "egregore-config/v1" and .boundary.posture == "open" and .people_removed == ["ghost"]' "$WORK/clone/egregore.json" >/dev/null \
  && pass "incoming keys and launcher-written keys both survive the merge" || fail "egregore.json merge lost a side" "$(cat "$WORK/clone/egregore.json")"
case "$UNSHARED" in *boundary*people_removed*|*people_removed*boundary*) pass "unshared settings keys reported for the greeting" ;; *) fail "unshared keys wrong" "$UNSHARED" ;; esac

# ── 2. user-enriched settings.json is never restored ─────────────────────
make_fixture
(
  cd "$WORK/clone" || exit 1
  # User work: adds a hook event the committed file lacks
  printf '{"permissions":{"allow":["Bash","Read"]},"hooks":{"SessionStart":[{"x":1}],"UserExtra":[{"y":1}]}}\n' > .claude/settings.json
)
OUT=$(drive)
RESTORED=$(printf '%s' "$OUT" | sed -n 1p)
[ "$RESTORED" = "false" ] && pass "user-enriched settings.json left untouched" || fail "user settings clobbered by healer"
jq -e '.hooks.UserExtra' "$WORK/clone/.claude/settings.json" >/dev/null && pass "user hook still present" || fail "user hook lost"

# ── 3. clean tree fast-forwards untouched ────────────────────────────────
make_fixture
OUT=$(drive)
HEAD_AFTER=$(printf '%s' "$OUT" | sed -n 3p)
[ "$HEAD_AFTER" = "$(git -C "$WORK/clone" rev-parse origin/develop)" ] && pass "clean checkout fast-forwards normally" || fail "clean ff broken"

# ── 4. drift with no pending merge still reports unshared keys ───────────
make_fixture
(cd "$WORK/clone" || exit 1; git merge --ff-only origin/develop --quiet)
(cd "$WORK/clone" || exit 1; jq '.base_branch = "develop"' egregore.json > e.tmp && mv e.tmp egregore.json)
OUT=$(drive)
UNSHARED=$(printf '%s' "$OUT" | sed -n 2p)
[ "$UNSHARED" = "base_branch" ] && pass "up-to-date checkout still reports unshared settings" || fail "no-merge report wrong" "$UNSHARED"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
