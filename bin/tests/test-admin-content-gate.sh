#!/usr/bin/env bash
# Admin-content publication gate — the refusal documented in
# bin/lib/permissions.sh, exercised through DIRECT publish-artifact.sh
# invocation (no launcher, no skill) so bypass-by-script is covered.
# A fake curl guarantees nothing is ever uploaded.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/egregore-admin-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/instance"
mkdir -p "$FIX/memory/fundraise" "$FIX/bin/lib" "$WORK/bin"

# Fixture instance: the gate resolves identity and config from its own root.
cp "$ROOT/bin/publish-artifact.sh" "$FIX/bin/"
cp "$ROOT/bin/lib/permissions.sh" "$FIX/bin/lib/"
cp -R "$ROOT/egregore_runtime" "$FIX/egregore_runtime"
for helper in artifact-register.sh publish-references.sh telemetry.sh; do
  [ -f "$ROOT/bin/$helper" ] && cp "$ROOT/bin/$helper" "$FIX/bin/" 2>/dev/null
done
mkdir -p "$FIX/bin/lib"
cp "$ROOT"/bin/lib/*.sh "$FIX/bin/lib/" 2>/dev/null || true

printf '{"slug":"acme","org_name":"Acme","org_id":"org-acme-1","admins":["admin-user"],"features":{"public_relay":true}}\n' > "$FIX/egregore.json"
printf 'gate-test-session\n' > "$FIX/.egregore-session-id"

printf -- '---\ntopic: restricted investor notes\nadmin: true\n---\n\n# Restricted\n\nInvestor content.\n' > "$FIX/memory/fundraise/restricted.md"
printf -- '---\ntopic: open note\n---\n\n# Open\n\nHarmless. See `memory/fundraise/restricted.md` for detail.\n' > "$FIX/memory/parent-with-admin-ref.md"
printf -- '---\ntopic: open note\n---\n\n# Open\n\nEntirely harmless.\n' > "$FIX/memory/open.md"

# Fake curl: records invocation, uploads nothing.
CURL_LOG="$WORK/curl.log"
printf '#!/usr/bin/env bash\necho "curl $*" >> "%s"\necho "{}"\n' "$CURL_LOG" > "$WORK/bin/curl"
chmod +x "$WORK/bin/curl"

# Fake installed renderer (a real node script — publish runs it through
# bin/node-run.sh; the npx/@latest fallback no longer exists).
cp "$ROOT/bin/node-run.sh" "$FIX/bin/"
cat > "$WORK/bin/egregore-artifacts" <<'EOF'
#!/usr/bin/env node
const i = process.argv.indexOf("--output");
if (i > -1) require("node:fs").writeFileSync(process.argv[i + 1], "<html></html>");
EOF
chmod +x "$WORK/bin/egregore-artifacts"

as_member() { printf '{"onboarding_complete":true,"github_username":"member-user","display_name":"Member"}\n' > "$FIX/.egregore-state.json"; }
as_admin()  { printf '{"onboarding_complete":true,"github_username":"admin-user","display_name":"Admin"}\n' > "$FIX/.egregore-state.json"; }
as_impostor() { printf '{"onboarding_complete":true,"github_username":"member-user","display_name":"admin-user"}\n' > "$FIX/.egregore-state.json"; }

publish() { (cd "$FIX" && PATH="$WORK/bin:$PATH" bash bin/publish-artifact.sh "$@" 2>"$WORK/err.txt"); }

as_member
publish document "$FIX/memory/fundraise/restricted.md"
[ $? -eq 5 ] && grep -q "non-admin" "$WORK/err.txt" \
  && pass "non-admin publish of admin-marked source is refused" \
  || fail "non-admin publish not refused" "$(cat "$WORK/err.txt")"
[ -s "$CURL_LOG" ] && fail "refusal still contacted the network" || pass "refusal happened before any upload"

publish document "$FIX/memory/fundraise/restricted.md" --allow-admin
[ $? -eq 5 ] && pass "--allow-admin grants nothing to a non-admin" \
  || fail "--allow-admin bypassed the gate for a non-admin"

publish document "$FIX/memory/parent-with-admin-ref.md"
[ $? -eq 5 ] && grep -q "restricted.md" "$WORK/err.txt" \
  && pass "admin file cannot be smuggled through a referencing parent" \
  || fail "referenced admin file not caught" "$(cat "$WORK/err.txt")"

as_impostor
publish document "$FIX/memory/fundraise/restricted.md" --allow-admin
[ $? -eq 5 ] && pass "display-name collision with an admin handle grants nothing" \
  || fail "impostor display name granted admin publish"

as_admin
publish document "$FIX/memory/fundraise/restricted.md"
[ $? -eq 5 ] && grep -q "re-run with --allow-admin" "$WORK/err.txt" \
  && pass "admin without --allow-admin still gets the separate confirmation step" \
  || fail "admin was not asked for explicit confirmation" "$(cat "$WORK/err.txt")"
[ -s "$CURL_LOG" ] && fail "admin refusal contacted the network" || pass "confirmation refusal happened before any upload"

: > "$CURL_LOG"
publish document "$FIX/memory/fundraise/restricted.md" --allow-admin
rc=$?
grep -q "admin" "$WORK/err.txt" && admin_refused=1 || admin_refused=0
[ "$rc" -ne 5 ] && [ "$admin_refused" -eq 0 ] \
  && pass "admin with --allow-admin passes the gate (rc=$rc, no admin refusal)" \
  || fail "admin with confirmation was still refused" "rc=$rc $(cat "$WORK/err.txt")"

as_member
: > "$CURL_LOG"
publish document "$FIX/memory/open.md"
rc=$?
[ "$rc" -ne 5 ] && pass "unmarked content publishes without the gate engaging (rc=$rc)" \
  || fail "gate misfired on unmarked content" "$(cat "$WORK/err.txt")"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
