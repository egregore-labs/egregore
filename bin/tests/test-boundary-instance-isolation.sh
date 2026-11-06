#!/usr/bin/env bash
set -uo pipefail

# Test: instance isolation across checkout topologies
# Identity model: a registered instance is excluded from denial only when
# proven same-identity — registry org_id equals the project's egregore.json
# org_id, or a caller-proven same-instance path (worktree-create passes the
# enclosing repo its git dir physically lives in). Ancestry and slug prove
# nothing; entries with a different or missing org_id fail closed. The
# enforcement layers' self-scope carve-out keeps a nested project usable while
# its unproven enclosing tree stays denied.
# Exercises: bin/boundary.sh compute-denied, bin/boundary.sh check, and
# .claude/hooks/boundary-check.sh. No real instance, org, or user paths.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$SCRIPT_DIR/.claude/hooks/boundary-check.sh"
BOUNDARY_SH="$SCRIPT_DIR/bin/boundary.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: instance isolation (org identity, nesting, traversal)"
echo ""

# --- Fixture topology (all synthetic) ---
# T/acme-hq                          ancestor instance, slug acme, org ORG_A
# T/acme-hq/.claude/worktrees/smoke  nested standalone clone = project, org ORG_A
# T/acme-laptop                      adjacent, slug acme, org ORG_A (same org)
# T/acme-impostor                    adjacent, slug acme, org ORG_B (same slug!)
# T/rival-inst                       foreign, slug rival, org ORG_B
# T/rival-inst-notes                 unregistered dir sharing rival-inst prefix
# T/acme-legacy                      adjacent, slug acme, no org_id (legacy)
# CLONE/.claude/worktrees/task1      child entry under the project, org ORG_B
# CLONE/.claude/worktrees/task2      child entry under the project, org ORG_A
#
# Keep fixtures in the writable workspace, outside system-allowed /tmp, and
# replace HOME before invoking the guard: never read the user's real registry.
mkdir -p "$SCRIPT_DIR/tmp"
T="$(mktemp -d "$SCRIPT_DIR/tmp/egregore-boundary-isolation-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
export HOME="$T/home"
mkdir -p "$HOME"
ORG_A="org-aaaa-1111-2222-3333"
ORG_B="org-bbbb-4444-5555-6666"
PARENT="$T/acme-hq"
CLONE="$PARENT/.claude/worktrees/smoke"
OTHER_SAME="$T/acme-laptop"
IMPOSTOR="$T/acme-impostor"
FOREIGN="$T/rival-inst"
FOREIGN_SIB="$T/rival-inst-notes"
LEGACY_ADJ="$T/acme-legacy"
WT_CHILD="$CLONE/.claude/worktrees/task1"
WT_CHILD_SAME="$CLONE/.claude/worktrees/task2"
mkdir -p "$CLONE" "$OTHER_SAME" "$IMPOSTOR" "$FOREIGN" "$FOREIGN_SIB" "$LEGACY_ADJ" "$WT_CHILD" "$WT_CHILD_SAME"
echo "readme" > "$CLONE/README.md"
echo "wt-secret" > "$WT_CHILD/wt-secret.txt"
echo "secret" > "$FOREIGN/secret.txt"
echo "data" > "$FOREIGN_SIB/data.txt"
echo "parentfile" > "$PARENT/parent-note.md"

REGISTRY="$T/registry.json"
cat > "$REGISTRY" <<EOF
[
  {"slug": "acme",  "name": "Acme",  "path": "$PARENT",     "org_id": "$ORG_A"},
  {"slug": "acme",  "name": "Acme",  "path": "$OTHER_SAME", "org_id": "$ORG_A"},
  {"slug": "acme",  "name": "Bcme",  "path": "$IMPOSTOR",   "org_id": "$ORG_B"},
  {"slug": "rival", "name": "Rival", "path": "$FOREIGN",    "org_id": "$ORG_B"},
  {"slug": "acme",  "name": "Acme",  "path": "$LEGACY_ADJ"},
  {"slug": "ghost", "name": "Ghost", "path": "$WT_CHILD",      "org_id": "$ORG_B"},
  {"slug": "acme",  "name": "Acme",  "path": "$WT_CHILD_SAME", "org_id": "$ORG_A"}
]
EOF

# Legacy variant: the ancestor itself carries no org_id
REGISTRY_LEGACY="$T/registry-legacy.json"
cat > "$REGISTRY_LEGACY" <<EOF
[
  {"slug": "acme",  "name": "Acme",  "path": "$PARENT"},
  {"slug": "rival", "name": "Rival", "path": "$FOREIGN", "org_id": "$ORG_B"}
]
EOF

HASH=$(echo -n "$CLONE" | md5 2>/dev/null || echo -n "$CLONE" | md5sum 2>/dev/null | cut -d' ' -f1)
BOUNDARY_FILE="/tmp/egregore-boundary-${HASH}.json"
export CLAUDE_PROJECT_DIR="$CLONE"

cleanup() {
  rm -rf "$T" "$BOUNDARY_FILE"
}
trap cleanup EXIT

run_hook() {
  local input="$1"
  local err rc
  err=$(echo "$input" | "$HOOK" 2>&1 >/dev/null)
  rc=$?
  printf '%s|%s' "$rc" "$err"
}

write_boundary() {
  # $1 = denied_paths JSON array
  cat > "$BOUNDARY_FILE" <<EOF
{
  "project_dir": "$CLONE",
  "memory_dir": "",
  "posture": "open",
  "locked": false,
  "read_roots": [],
  "managed_repos": [],
  "denied_paths": $1
}
EOF
}

denied_has() { echo "$1" | jq -e --arg p "$2" 'index($p) != null' >/dev/null 2>&1; }
denied_lacks() { echo "$1" | jq -e --arg p "$2" 'index($p) == null' >/dev/null 2>&1; }

# ============================================================
# 1. compute-denied: identity-proven exclusions, fail-closed otherwise
# ============================================================
echo "— compute-denied construction —"
DENIED=$(bash "$BOUNDARY_SH" compute-denied "$REGISTRY" "$CLONE" "$ORG_A")

denied_has "$DENIED" "$FOREIGN" \
  && pass "different-org instance denied" \
  || fail "different-org instance missing" "$DENIED"

denied_has "$DENIED" "$IMPOSTOR" \
  && pass "same-slug different-org instance denied" \
  || fail "same-slug different-org wrongly excluded" "$DENIED"

denied_has "$DENIED" "$LEGACY_ADJ" \
  && pass "legacy entry without org_id fails closed (denied)" \
  || fail "legacy entry wrongly excluded" "$DENIED"

denied_lacks "$DENIED" "$PARENT" \
  && pass "nested: same-org ancestor excluded" \
  || fail "same-org ancestor wrongly denied" "$DENIED"

denied_lacks "$DENIED" "$OTHER_SAME" \
  && pass "adjacent same-org checkout excluded" \
  || fail "same-org adjacent wrongly denied" "$DENIED"

denied_has "$DENIED" "$WT_CHILD" \
  && pass "different-org child under project's worktrees denied" \
  || fail "different-org child wrongly excluded" "$DENIED"

denied_lacks "$DENIED" "$WT_CHILD_SAME" \
  && pass "same-org child excluded through org_id, not residence" \
  || fail "same-org child wrongly denied" "$DENIED"

# Repro of the reported inference: a registry holding only a different-org
# child entry must not collapse to []
REGISTRY_CHILD="$T/registry-child.json"
printf '[{"slug":"ghost","name":"Ghost","path":"%s","org_id":"%s"}]\n' "$WT_CHILD" "$ORG_B" > "$REGISTRY_CHILD"
DENIED_CHILD=$(bash "$BOUNDARY_SH" compute-denied "$REGISTRY_CHILD" "$CLONE" "$ORG_A")
denied_has "$DENIED_CHILD" "$WT_CHILD" \
  && pass "child-only registry does not collapse to empty denied list" \
  || fail "child-only registry returned empty" "$DENIED_CHILD"

# Project without a recorded org identity: nothing can be proven — every
# other entry stays denied, ancestry included.
DENIED_NOORG=$(bash "$BOUNDARY_SH" compute-denied "$REGISTRY" "$CLONE" "")
denied_has "$DENIED_NOORG" "$PARENT" \
  && pass "no self org_id: ancestor fails closed (denied)" \
  || fail "no self org_id: ancestor wrongly excluded" "$DENIED_NOORG"
denied_has "$DENIED_NOORG" "$OTHER_SAME" \
  && pass "no self org_id: adjacent fails closed (denied)" \
  || fail "no self org_id: adjacent wrongly excluded" "$DENIED_NOORG"

# Legacy registry: the ancestor entry has no org_id — identity unproven.
DENIED_LEG=$(bash "$BOUNDARY_SH" compute-denied "$REGISTRY_LEGACY" "$CLONE" "$ORG_A")
denied_has "$DENIED_LEG" "$PARENT" \
  && pass "nested: legacy-identity ancestor fails closed (denied)" \
  || fail "legacy ancestor wrongly excluded" "$DENIED_LEG"

MISSING=$(bash "$BOUNDARY_SH" compute-denied "$T/does-not-exist.json" "$CLONE" "$ORG_A")
[ "$MISSING" = "[]" ] \
  && pass "missing registry yields empty denied list" \
  || fail "missing registry output" "$MISSING"

# ============================================================
# 2. Hook: correct cache (same-org world — denied = foreign entries only)
# ============================================================
echo ""
echo "— hook, correct cache —"
write_boundary "[\"$FOREIGN\"]"

OUT=$(run_hook "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$CLONE/README.md\"}}")
[ "${OUT%%|*}" = "0" ] && pass "Read own project file allowed" || fail "Read own file blocked" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$FOREIGN/secret.txt\"}}")
RC="${OUT%%|*}"; ERR="${OUT#*|}"
[ "$RC" = "2" ] && grep -q "another Egregore instance" <<< "$ERR" \
  && pass "Read foreign absolute path hard-blocked" \
  || fail "Read foreign absolute path" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$CLONE/../../../../rival-inst/secret.txt\"}}")
RC="${OUT%%|*}"; ERR="${OUT#*|}"
[ "$RC" = "2" ] && grep -q "another Egregore instance" <<< "$ERR" \
  && pass "Read ../ normalization escape hard-blocked" \
  || fail "Read normalization escape" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $FOREIGN/secret.txt\"}}")
RC="${OUT%%|*}"; ERR="${OUT#*|}"
[ "$RC" = "2" ] && grep -q "another Egregore instance" <<< "$ERR" \
  && pass "Bash foreign absolute path hard-blocked" \
  || fail "Bash foreign absolute path" "$OUT"

OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat ../../../../rival-inst/secret.txt"}}')
RC="${OUT%%|*}"; ERR="${OUT#*|}"
[ "$RC" = "2" ] && grep -q "another Egregore instance" <<< "$ERR" \
  && pass "Bash relative ../ traversal hard-blocked" \
  || fail "Bash relative traversal" "$OUT"

OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"echo x > ../../../../rival-inst/new-file.txt"}}')
RC="${OUT%%|*}"; ERR="${OUT#*|}"
[ "$RC" = "2" ] && grep -q "another Egregore instance" <<< "$ERR" \
  && pass "Bash traversal to nonexistent foreign target hard-blocked" \
  || fail "Bash traversal nonexistent target" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls $FOREIGN_SIB/data.txt\"}}")
[ "${OUT%%|*}" = "0" ] \
  && pass "Bash sibling sharing denied prefix not blocked (path-boundary match)" \
  || fail "Bash prefix-sibling false positive" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo $CLONE/somefile\"}}")
[ "${OUT%%|*}" = "0" ] \
  && pass "Bash mentioning own absolute path allowed" \
  || fail "Bash own absolute path" "$OUT"

OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"git log --oneline bin/search.sh dev/topic"}}')
[ "${OUT%%|*}" = "0" ] \
  && pass "Bash plain relative paths allowed" \
  || fail "Bash plain relative paths" "$OUT"

OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat ../smoke/README.md"}}')
[ "${OUT%%|*}" = "0" ] \
  && pass "Bash traversal resolving back into own project allowed" \
  || fail "Bash self-traversal" "$OUT"

# ============================================================
# 3. Hard tier is never relaxed (posture=open in the fixture; additionally
#    assert bypassPermissions does not skip it)
# ============================================================
echo ""
echo "— hard tier under relaxation —"
OUT=$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $FOREIGN/secret.txt\"},\"permission_mode\":\"bypassPermissions\"}")
[ "${OUT%%|*}" = "2" ] \
  && pass "Bash foreign path blocked despite bypassPermissions" \
  || fail "Bash bypassPermissions relaxed hard tier" "$OUT"

OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat ../../../../rival-inst/secret.txt"},"permission_mode":"bypassPermissions"}')
[ "${OUT%%|*}" = "2" ] \
  && pass "Bash relative traversal blocked despite bypassPermissions" \
  || fail "Bash traversal bypassPermissions relaxed hard tier" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$FOREIGN/secret.txt\"},\"permission_mode\":\"bypassPermissions\"}")
[ "${OUT%%|*}" = "2" ] \
  && pass "Read foreign path blocked despite bypassPermissions" \
  || fail "Read bypassPermissions relaxed hard tier" "$OUT"

# ============================================================
# 4. Hook: unproven ancestor stays denied, nested project stays usable
#    (cache as produced for a legacy or different-org ancestor; identical in
#    shape to a stale pre-fix cache)
# ============================================================
echo ""
echo "— hook, unproven-ancestor cache —"
write_boundary "[\"$PARENT\", \"$FOREIGN\"]"

OUT=$(run_hook "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$CLONE/README.md\"}}")
[ "${OUT%%|*}" = "0" ] \
  && pass "nested project's own file allowed (self-scope carve-out)" \
  || fail "own file blocked under denied ancestor" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$PARENT/parent-note.md\"}}")
RC="${OUT%%|*}"; ERR="${OUT#*|}"
[ "$RC" = "2" ] && grep -q "another Egregore instance" <<< "$ERR" \
  && pass "unproven enclosing tree denied (Read)" \
  || fail "unproven ancestor file not denied" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo $CLONE/x\"}}")
[ "${OUT%%|*}" = "0" ] \
  && pass "Bash own absolute path allowed under denied ancestor" \
  || fail "Bash own path blocked under denied ancestor" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $PARENT/parent-note.md\"}}")
RC="${OUT%%|*}"; ERR="${OUT#*|}"
[ "$RC" = "2" ] && grep -q "another Egregore instance" <<< "$ERR" \
  && pass "unproven enclosing tree denied (Bash absolute, via resolution pass)" \
  || fail "Bash ancestor file not denied" "$OUT"

OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat ../../../parent-note.md"}}')
RC="${OUT%%|*}"; ERR="${OUT#*|}"
[ "$RC" = "2" ] && grep -q "another Egregore instance" <<< "$ERR" \
  && pass "unproven enclosing tree denied (Bash relative traversal)" \
  || fail "Bash relative into ancestor not denied" "$OUT"

OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat ../smoke/README.md"}}')
[ "${OUT%%|*}" = "0" ] \
  && pass "traversal back into own project allowed under denied ancestor" \
  || fail "self-traversal blocked under denied ancestor" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$FOREIGN/secret.txt\"}}")
[ "${OUT%%|*}" = "2" ] \
  && pass "foreign instance still denied alongside ancestor" \
  || fail "foreign not denied in ancestor cache" "$OUT"

# ============================================================
# 4b. Hook: denied child inside the project — the carve-out is per entry, so
#     residence under the project does not shield an unproven child, while
#     the rest of the project stays usable (even with the ancestor denied too)
# ============================================================
echo ""
echo "— hook, denied child inside project —"
write_boundary "[\"$PARENT\", \"$WT_CHILD\", \"$FOREIGN\"]"

OUT=$(run_hook "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WT_CHILD/wt-secret.txt\"}}")
RC="${OUT%%|*}"; ERR="${OUT#*|}"
[ "$RC" = "2" ] && grep -q "another Egregore instance" <<< "$ERR" \
  && pass "different-org child file denied despite living inside project" \
  || fail "child file not denied" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$CLONE/README.md\"}}")
[ "${OUT%%|*}" = "0" ] \
  && pass "project file outside child still allowed" \
  || fail "project file blocked in child cache" "$OUT"

OUT=$(run_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat $WT_CHILD/wt-secret.txt\"}}")
[ "${OUT%%|*}" = "2" ] \
  && pass "Bash into denied child blocked" \
  || fail "Bash child access not denied" "$OUT"

OUT=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat .claude/worktrees/task1/wt-secret.txt"}}')
[ "${OUT%%|*}" = "2" ] \
  && pass "Bash relative path into denied child blocked" \
  || fail "Bash relative child access not denied" "$OUT"

# ============================================================
# 5. bin/boundary.sh check parity (copied into the fixture clone so its
#    SCRIPT_DIR — and boundary cache key — is the fixture project)
# ============================================================
echo ""
echo "— bin/boundary.sh check parity —"
mkdir -p "$CLONE/bin"
cp "$BOUNDARY_SH" "$CLONE/bin/boundary.sh"
cp "$SCRIPT_DIR/bin/boundary-guard.cjs" "$SCRIPT_DIR/bin/node-run.sh" "$CLONE/bin/"

write_boundary "[\"$FOREIGN\"]"
bash "$CLONE/bin/boundary.sh" check "$CLONE/README.md" >/dev/null 2>&1 \
  && pass "check: own file allowed" \
  || fail "check: own file blocked"
bash "$CLONE/bin/boundary.sh" check "$FOREIGN/secret.txt" >/dev/null 2>&1 \
  && fail "check: foreign file allowed" \
  || pass "check: foreign file blocked"

write_boundary "[\"$PARENT\", \"$FOREIGN\"]"
bash "$CLONE/bin/boundary.sh" check "$CLONE/README.md" >/dev/null 2>&1 \
  && pass "check: own file allowed under denied ancestor (carve-out)" \
  || fail "check: carve-out missing"
bash "$CLONE/bin/boundary.sh" check "$PARENT/parent-note.md" >/dev/null 2>&1 \
  && fail "check: unproven ancestor file allowed" \
  || pass "check: unproven ancestor file blocked"

write_boundary "[\"$WT_CHILD\"]"
bash "$CLONE/bin/boundary.sh" check "$WT_CHILD/wt-secret.txt" >/dev/null 2>&1 \
  && fail "check: denied child inside project allowed" \
  || pass "check: denied child inside project blocked"
bash "$CLONE/bin/boundary.sh" check "$CLONE/README.md" >/dev/null 2>&1 \
  && pass "check: project file outside child still allowed" \
  || fail "check: project file blocked in child cache"

# ============================================================
# 6. Worktree / session-start parity: both construct denied paths through
#    the same shared computation
# ============================================================
echo ""
echo "— worktree/session-start parity —"
for f in bin/worktree-create.sh bin/session-start.sh bin/codex-session-start.sh; do
  grep -q 'boundary-guard.cjs" write-cache' "$SCRIPT_DIR/$f" && ! grep -q 'compute-denied' "$SCRIPT_DIR/$f" \
    && pass "$f writes the boundary through the shared computation" \
    || fail "$f has its own boundary or denied-path logic"
done
grep -q 'boundary-guard.cjs' "$BOUNDARY_SH" \
  && pass "boundary.sh compute-denied delegates to the shared computation" \
  || fail "boundary.sh keeps its own denied-path logic"

# The worktree call passes its enclosing repo as the caller-proven allowance:
# on a legacy registry (no org_id anywhere) the enclosing repo must still be
# excluded while foreign instances stay denied — the backward-compatible path.
WT_SIM="$PARENT/.claude/worktrees/task-sim"
DENIED_WT=$(bash "$BOUNDARY_SH" compute-denied "$REGISTRY_LEGACY" "$WT_SIM" "" "$PARENT")
denied_lacks "$DENIED_WT" "$PARENT" \
  && pass "worktree: enclosing repo excluded via caller-proven allowance (legacy registry)" \
  || fail "worktree: enclosing repo denied on legacy registry" "$DENIED_WT"
denied_has "$DENIED_WT" "$FOREIGN" \
  && pass "worktree: foreign instance still denied" \
  || fail "worktree: foreign excluded" "$DENIED_WT"

# --- Summary ---
echo ""
echo "— shared per-user state, check CLI —"
mkdir -p "$HOME/.egregore/exports" "$HOME/.egregore/runtime" "$HOME/.egregore/mind"
printf '[]\n' > "$HOME/.egregore/instances.json"
ln -s "$HOME/.egregore/exports" "$HOME/.egregore/unknown-link"
ln -s "$HOME/.egregore/mind" "$HOME/.egregore/exports/mind-link"
for target in "$HOME/.egregore/runtime/new" "$HOME/.egregore/mind/new" \
  "$HOME/.egregore/unknown-link/new" "$HOME/.egregore/exports/mind-link/new"; do
  bash "$CLONE/bin/boundary.sh" check "$target" >/dev/null 2>&1 \
    && fail "check: protected shared state allowed: ${target#"$HOME/"}" \
    || pass "check: protected shared state blocked: ${target#"$HOME/"}"
done
for target in "$HOME/.egregore/exports/new" "$HOME/.egregore/instances.json"; do
  bash "$CLONE/bin/boundary.sh" check "$target" >/dev/null 2>&1 \
    && pass "check: documented shared path allowed: ${target#"$HOME/"}" \
    || fail "check: documented shared path blocked: ${target#"$HOME/"}"
done

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
