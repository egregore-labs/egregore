#!/usr/bin/env bash
set -uo pipefail

# Test: publish-references.sh self-ref guard + artifact-id.sh extension handling
# Covers:
#   - bin/lib/artifact-id.sh case-insensitive extension match (parity with JS)
#   - bin/publish-references.sh self-ref comparison on repo-relative path
#     (not basename, so unrelated files sharing a filename still publish)

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: publish-references self-ref guard + artifact-id case-insensitive ext"
echo ""

# shellcheck source=/dev/null
. "$SCRIPT_DIR/bin/lib/artifact-id.sh"

# --- 1. artifact_id_from_path: uppercase extensions ---
echo "1. Uppercase extension parity"

ID_LOWER="$(artifact_id_from_path "memory/foo.md" || true)"
ID_UPPER="$(artifact_id_from_path "memory/foo.MD" || true)"
ID_MIXED="$(artifact_id_from_path "memory/foo.Md" || true)"

if [[ "$ID_LOWER" =~ ^m-[0-9a-f]{12}$ ]]; then
  pass ".md produces m-<12hex>"
else
  fail ".md did not produce expected id" "got: $ID_LOWER"
fi

if [[ "$ID_UPPER" =~ ^m-[0-9a-f]{12}$ ]]; then
  pass ".MD produces m-<12hex> (case-insensitive ext match)"
else
  fail ".MD produced no id or wrong format" "got: $ID_UPPER"
fi

if [[ "$ID_MIXED" =~ ^m-[0-9a-f]{12}$ ]]; then
  pass ".Md produces m-<12hex>"
else
  fail ".Md produced no id or wrong format" "got: $ID_MIXED"
fi

# Canonical path is hashed verbatim — case differences in path change the id.
if [ "$ID_LOWER" != "$ID_UPPER" ]; then
  pass "different-case paths produce different ids (path case preserved in hash)"
else
  fail "upper/lower paths collided" "both=$ID_LOWER — hashing was case-folded"
fi

ID_HTML_UPPER="$(artifact_id_from_path "memory/reports/INDEX.HTML" || true)"
if [[ "$ID_HTML_UPPER" =~ ^h-[0-9a-f]{12}$ ]]; then
  pass ".HTML produces h-<12hex>"
else
  fail ".HTML produced no id or wrong format" "got: $ID_HTML_UPPER"
fi

ID_UNSUP="$(artifact_id_from_path "memory/notes.txt" 2>/dev/null || true)"
if [ -z "$ID_UNSUP" ]; then
  pass ".txt returns empty (unsupported extension)"
else
  fail ".txt should have returned empty" "got: $ID_UNSUP"
fi

# --- 2. publish-references.sh self-ref guard — full path comparison ---
echo ""
echo "2. Self-ref guard compares repo-relative path, not basename"

# Create an isolated git repo with two files sharing a basename
TMP_ROOT="$(mktemp -d -t publish-refs-test-XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/memory/handoffs/2026-04" "$TMP_ROOT/memory/knowledge/decisions"

cat > "$TMP_ROOT/memory/handoffs/2026-04/24-foo.md" <<'EOF'
# Parent handoff

This is the parent handoff. It references:
- `memory/knowledge/decisions/24-foo.md` (unrelated file, same basename)
- `memory/handoffs/2026-04/24-foo.md` (itself — must be skipped)
EOF

cat > "$TMP_ROOT/memory/knowledge/decisions/24-foo.md" <<'EOF'
# Unrelated decision that happens to share the parent's basename.
EOF

(
  cd "$TMP_ROOT" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q -m init
)

# Stub publish-artifact.sh so it records each ref instead of calling the API.
# publish-references.sh invokes: bash "$SCRIPT_DIR/bin/publish-artifact.sh" <type> <path> --id <id> --no-references
# We need to override the SCRIPT_DIR it computes, which is (dirname $0)/.. → the caller's repo.
STUB_ROOT="$TMP_ROOT/stub"
mkdir -p "$STUB_ROOT/bin/lib"
cp "$SCRIPT_DIR/bin/publish-references.sh" "$STUB_ROOT/bin/publish-references.sh"
cp "$SCRIPT_DIR/bin/lib/artifact-id.sh" "$STUB_ROOT/bin/lib/artifact-id.sh"

cat > "$STUB_ROOT/bin/publish-artifact.sh" <<STUB
#!/usr/bin/env bash
# Stub: record each invocation so the test can assert which refs got published.
echo "PUBLISH \$*" >> "$TMP_ROOT/published.log"
exit 0
STUB
chmod +x "$STUB_ROOT/bin/publish-artifact.sh"

# Trick the connected-mode gate — publish-references.sh requires an API key.
# Set via env so the stub fires.
export EGREGORE_API_KEY="test-key"

# Run the script against the parent handoff. Use the stub's copy so its
# SCRIPT_DIR resolves to $STUB_ROOT and it finds our stub publish-artifact.sh.
> "$TMP_ROOT/published.log"
bash "$STUB_ROOT/bin/publish-references.sh" "$TMP_ROOT/memory/handoffs/2026-04/24-foo.md" >/dev/null 2>&1 || true

# Give background jobs a moment to flush.
sleep 0.3

if grep -q "memory/knowledge/decisions/24-foo.md" "$TMP_ROOT/published.log"; then
  pass "unrelated file with same basename was published (not falsely skipped)"
else
  fail "unrelated same-basename file was skipped" \
    "published.log: $(cat "$TMP_ROOT/published.log" 2>/dev/null || echo empty)"
fi

if grep -q "memory/handoffs/2026-04/24-foo.md" "$TMP_ROOT/published.log"; then
  fail "source file was published (self-ref guard failed)" \
    "published.log: $(cat "$TMP_ROOT/published.log" 2>/dev/null || echo empty)"
else
  pass "source file itself was correctly skipped"
fi

unset EGREGORE_API_KEY

# --- Summary ---
echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
