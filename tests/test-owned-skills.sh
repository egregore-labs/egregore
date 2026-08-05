#!/usr/bin/env bash
# Tests for bin/restore-owned-skills.sh — the org-owned skills guarantee.
#
# Contract: skills named in egregore.json → owned_skills[] survive the /update
# framework overlay. Org-only skills are never touched (including uncommitted
# edits); on a name collision the org's committed version wins and the
# collision is reported; a collision with no committed org version keeps
# upstream's copy and says how to fix it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi
}

echo "test-owned-skills"

command -v jq >/dev/null 2>&1 || { echo "  ~ jq not available — skipping"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Fixture: an org repo with an upstream that collides -------------------
# upstream/main ships: skills "shared-name" (collides) and "framework-only".
# org HEAD ships: owned "shared-name" (different content) and owned
# "org-only", plus an unregistered "unowned" skill.
REPO="$TMP/org"
mkdir -p "$REPO"
git -C "$REPO" init --quiet -b main
git -C "$REPO" config user.email test@test && git -C "$REPO" config user.name test

mkdir -p "$REPO/.claude/skills/shared-name" "$REPO/.claude/skills/org-only" "$REPO/.claude/skills/unowned" "$REPO/bin"
echo "ORG VERSION" > "$REPO/.claude/skills/shared-name/SKILL.md"
echo "org only"    > "$REPO/.claude/skills/org-only/SKILL.md"
echo "unowned org" > "$REPO/.claude/skills/unowned/SKILL.md"
printf '{"org_name":"t","owned_skills":["shared-name","org-only","missing-local","../evil"]}\n' > "$REPO/egregore.json"
cp "$ROOT/bin/restore-owned-skills.sh" "$REPO/bin/"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "org state"

# Simulated upstream as a separate branch (stands in for upstream/main).
# Real upstream has no org skills — drop them from the upstream tree.
git -C "$REPO" checkout --quiet -b upstream-main
git -C "$REPO" rm -r --quiet .claude/skills/org-only .claude/skills/unowned
echo "UPSTREAM VERSION"   > "$REPO/.claude/skills/shared-name/SKILL.md"
echo "upstream extra"     > "$REPO/.claude/skills/shared-name/EXTRA.md"
mkdir -p "$REPO/.claude/skills/framework-only" "$REPO/.claude/skills/missing-local"
echo "framework skill"    > "$REPO/.claude/skills/framework-only/SKILL.md"
echo "upstream new"       > "$REPO/.claude/skills/missing-local/SKILL.md"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "upstream state"
git -C "$REPO" checkout --quiet main

# Uncommitted local edit to an org-only owned skill — must survive untouched.
echo "uncommitted edit" >> "$REPO/.claude/skills/org-only/SKILL.md"

# --- The /update overlay ----------------------------------------------------
git -C "$REPO" checkout upstream-main -- .claude/skills/ 2>/dev/null

OUT=$(cd "$REPO" && bash bin/restore-owned-skills.sh --upstream-ref upstream-main 2>&1)
STATUS=$?

check "script exits 0" "0" "$STATUS"
check "collision: org version restored" "ORG VERSION" "$(cat "$REPO/.claude/skills/shared-name/SKILL.md")"
if [ -f "$REPO/.claude/skills/shared-name/EXTRA.md" ]; then
  bad "collision: upstream-only file inside owned dir removed"
else
  ok "collision: upstream-only file inside owned dir removed"
fi
echo "$OUT" | grep -q "owned skill 'shared-name'" && ok "collision reported" || bad "collision reported — got: $OUT"
check "org-only owned skill keeps uncommitted edit" "uncommitted edit" "$(tail -1 "$REPO/.claude/skills/org-only/SKILL.md")"
check "unowned skill untouched by script" "unowned org" "$(cat "$REPO/.claude/skills/unowned/SKILL.md")"
check "framework skill adopted from upstream" "framework skill" "$(cat "$REPO/.claude/skills/framework-only/SKILL.md")"
check "owned-but-never-committed: upstream copy stays" "upstream new" "$(cat "$REPO/.claude/skills/missing-local/SKILL.md")"
echo "$OUT" | grep -q "missing-local" && ok "uncommitted-ownership warning emitted" || bad "uncommitted-ownership warning emitted"
echo "$OUT" | grep -q "invalid name" && ok "path-traversal name rejected" || bad "path-traversal name rejected"

# --- No owned_skills key → silent no-op ------------------------------------
printf '{"org_name":"t"}\n' > "$REPO/egregore.json"
OUT2=$(cd "$REPO" && bash bin/restore-owned-skills.sh --upstream-ref upstream-main 2>&1)
check "absent owned_skills exits 0" "0" "$?"
check "absent owned_skills is silent" "" "$OUT2"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
