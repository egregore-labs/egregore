#!/usr/bin/env bash
set -uo pipefail

# Test: publish-references.sh self-ref guard + artifact-id.sh extension handling
# Covers:
#   - bin/lib/artifact-id.sh case-insensitive extension match (parity with JS)
#   - bin/publish-references.sh self-ref comparison on repo-relative path
#     (not basename, so unrelated files sharing a filename still publish)
#   - bin/lib/hosted-ref-id.sh: referenced files are hosted under a random id,
#     never the path-derived one, and keep it on republish; the parent page
#     links to the same id (end to end through publish-artifact.sh with a
#     fake renderer and a fake upload)

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
WORK="$(mktemp -d -t publish-refs-hosted-XXXXXX)"
trap 'rm -rf "$TMP_ROOT" "$WORK"' EXIT
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
cp "$SCRIPT_DIR/bin/lib/hosted-ref-id.sh" "$STUB_ROOT/bin/lib/hosted-ref-id.sh"

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

# --- 3. hosted-ref-id.sh building blocks ---
echo ""
echo "3. Hosted ids: random, format-checked, rewritten only for this org"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/bin/lib/hosted-ref-id.sh"

CANON_FOO="$(artifact_id_from_path "memory/knowledge/decisions/24-foo.md")"
MINT_A="$(hosted_ref_id_mint "$CANON_FOO" || true)"
MINT_B="$(hosted_ref_id_mint "$CANON_FOO" || true)"
if [[ "$MINT_A" =~ ^m-[0-9a-f]{32}$ ]] && [ "$MINT_A" != "$MINT_B" ]; then
  pass "mint gives m-<32 hex> (128 random bits), different each time"
else
  fail "mint output wrong" "got: '$MINT_A' and '$MINT_B'"
fi

REG="$WORK/registry"
mkdir -p "$REG"
printf -- '---\nid: "%s"\nurl: "https://egregore.xyz/view/other/%s"\ncanonical_id: "%s"\n---\n' \
  "$MINT_A" "$MINT_A" "$CANON_FOO" > "$REG/2026-09-20-unknown-24-foo-$CANON_FOO.md"
if [ -z "$(hosted_ref_id_lookup "$REG" acme "$CANON_FOO")" ]; then
  pass "a record whose URL is another org's is not reused"
else
  fail "lookup reused another org's hosted id"
fi

printf '<a href="https://egregore.xyz/view/acme/%s">a</a><a href="https://egregore.xyz/view/other/%s">b</a>\n' \
  "$CANON_FOO" "$CANON_FOO" > "$WORK/page.html"
hosted_ref_rewrite_links "$WORK/page.html" "https://egregore.xyz/view/acme" \
  "memory/knowledge/decisions/24-foo.md $MINT_A"
if grep -qF "https://egregore.xyz/view/acme/$MINT_A\"" "$WORK/page.html" \
  && ! grep -qF "https://egregore.xyz/view/acme/$CANON_FOO\"" "$WORK/page.html" \
  && grep -qF "https://egregore.xyz/view/other/$CANON_FOO\"" "$WORK/page.html"; then
  pass "rewrite points this org's link at the hosted id and leaves others alone"
else
  fail "rewrite result wrong" "$(cat "$WORK/page.html")"
fi

# --- 4. End to end: publish-artifact.sh → publish-references.sh → registry ---
echo ""
echo "4. A parent publish hosts its references under random ids, stable on republish"

INST="$WORK/instance"
FAKE="$WORK/fake-bin"
UPLOADS="$WORK/uploads"
mkdir -p "$INST/bin/lib" "$INST/memory/handoffs/2026-09" "$INST/memory/knowledge/decisions" \
  "$INST/memory/artifacts" "$FAKE" "$UPLOADS"
for helper in publish-artifact.sh publish-references.sh artifact-register.sh node-run.sh; do
  cp "$SCRIPT_DIR/bin/$helper" "$INST/bin/$helper"
done
cp "$SCRIPT_DIR"/bin/lib/*.sh "$INST/bin/lib/"
printf '{"slug":"acme","mode":"connected","api_url":"https://api.example.invalid"}\n' > "$INST/egregore.json"

PARENT_REL="memory/handoffs/2026-09/24-parent.md"
REF_DECISION="memory/knowledge/decisions/24-foo.md"
REF_HANDOFF="memory/handoffs/2026-09/23-earlier.md"
REF_LEGACY="memory/knowledge/decisions/legacy.md"
printf '# Parent\n\nSee `%s`, `%s` and `%s`. Again: `%s`.\n' \
  "$REF_DECISION" "$REF_HANDOFF" "$REF_LEGACY" "$REF_DECISION" > "$INST/$PARENT_REL"
printf '# Decision\n\nA decision.\n' > "$INST/$REF_DECISION"
printf '# Earlier\n\nAn earlier handoff.\n' > "$INST/$REF_HANDOFF"
printf '# Legacy\n\nPublished before random ids.\n' > "$INST/$REF_LEGACY"
CANON_DECISION="$(artifact_id_from_path "$REF_DECISION")"
CANON_HANDOFF="$(artifact_id_from_path "$REF_HANDOFF")"
CANON_LEGACY="$(artifact_id_from_path "$REF_LEGACY")"
# A record from before random ids: hosted under the path-derived id itself.
printf -- '---\nid: %s\nurl: https://egregore.xyz/view/acme/%s\ncanonical_id: %s\n---\n' \
  "$CANON_LEGACY" "$CANON_LEGACY" "$CANON_LEGACY" > "$INST/memory/artifacts/2020-01-01-unknown-legacy.md"

# Fake upload: keeps each page under the id it was sent with and answers the
# way /api/artifacts/publish does.
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
id="" file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -F)
      case "$2" in
        artifact_id=*) id="${2#artifact_id=}" ;;
        file=@*) file="${2#file=@}" ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$id" ] || id="page-$$"
cp "$file" "$UPLOADS/$id.html"
printf '%s\n' "$id" >> "$UPLOADS/log"
printf '{"status":"published","id":"%s","url":"https://egregore.xyz/view/acme/%s"}\n' "$id" "$id"
EOF
# Fake renderer: links each `memory/…` mention the way lib/markdown.js does.
cat > "$FAKE/egregore-artifacts" <<'EOF'
#!/usr/bin/env node
const fs = require('node:fs');
const crypto = require('node:crypto');
const args = process.argv.slice(2);
const flag = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : null);
const org = flag('--org-slug');
const base = flag('--view-base');
let body = '';
for (const m of fs.readFileSync(args[1], 'utf8').matchAll(/`(memory\/[^`\s]+\.(md|html))`/g)) {
  const id = `${m[2] === 'md' ? 'm' : 'h'}-${crypto.createHash('sha256').update(m[1]).digest('hex').slice(0, 12)}`;
  body += org ? `<a href="${base}/${org}/${id}"><code>${m[1]}</code></a>\n` : `<code>${m[1]}</code>\n`;
}
fs.writeFileSync(flag('--output'), `<html><body>${body}</body></html>\n`);
EOF
chmod +x "$FAKE/curl" "$FAKE/egregore-artifacts"

publish_parent() {
  (
    cd "$INST" && PATH="$FAKE:$PATH" UPLOADS="$UPLOADS" EGREGORE_API_KEY=ek_acme_test \
      EGREGORE_USE_PUBLISHED=1 GIT_CEILING_DIRECTORIES="$WORK" \
      bash bin/publish-artifact.sh handoff "$PARENT_REL" --title Parent 2>/dev/null
  )
}

# Children publish in the background; wait for their uploads and records.
wait_for() { # <uploads> <records>
  local tries=0
  while [ "$tries" -lt 100 ]; do
    if [ "$(wc -l < "$UPLOADS/log" 2>/dev/null | tr -d ' ')" = "$1" ] \
      && [ "$(grep -rl '^canonical_id: "' "$INST/memory/artifacts" 2>/dev/null | wc -l | tr -d ' ')" -ge "$2" ]; then
      return 0
    fi
    sleep 0.2
    tries=$((tries + 1))
  done
  return 1
}

hosted_link() { # <page> <canonical id's kind> → hosted ids linked from the page
  grep -oE "https://egregore\.xyz/view/acme/$2-[0-9a-f]{32}\"" "$1" | sed 's#.*/##; s/"$//' | LC_ALL=C sort -u
}

PARENT_URL="$(publish_parent)"
wait_for 4 3 || fail "reference publishes did not finish" "$(cat "$UPLOADS/log" 2>/dev/null)"
PARENT_PAGE="$UPLOADS/${PARENT_URL##*/}.html"

if [ -f "$PARENT_PAGE" ] \
  && ! grep -qE "/view/acme/($CANON_DECISION|$CANON_HANDOFF|$CANON_LEGACY)\"" "$PARENT_PAGE"; then
  pass "the parent page links to no path-derived id"
else
  fail "parent page still links a path-derived id" "$(cat "$PARENT_PAGE" 2>/dev/null)"
fi

FIRST_IDS=""
ALL_HOSTED=1
for pair in "$REF_DECISION:$CANON_DECISION" "$REF_HANDOFF:$CANON_HANDOFF" "$REF_LEGACY:$CANON_LEGACY"; do
  ref="${pair%%:*}"
  canon="${pair##*:}"
  record="$(grep -rl "^canonical_id: \"$canon\"" "$INST/memory/artifacts" | head -1)"
  hosted="$(sed -n 's/^url: "https:\/\/egregore\.xyz\/view\/acme\/\(.*\)"$/\1/p' "$record" 2>/dev/null)"
  if ! [[ "$hosted" =~ ^m-[0-9a-f]{32}$ ]] || [ ! -f "$UPLOADS/$hosted.html" ] \
    || ! grep -qF "/view/acme/$hosted\"" "$PARENT_PAGE"; then
    ALL_HOSTED=0
    fail "$ref not hosted under a random id the parent links to" "record: $record hosted: $hosted"
  fi
  FIRST_IDS="$FIRST_IDS $hosted"
done
[ "$ALL_HOSTED" -eq 1 ] && pass "each reference is uploaded under a random id, recorded, and linked from the parent"

HANDOFF_RECORD="$(grep -rl '^canonical_id: "'"$CANON_HANDOFF"'"' "$INST/memory/artifacts" 2>/dev/null | head -1)"
HANDOFF_HOSTED="$(sed -n 's/^url: "https:\/\/egregore\.xyz\/view\/acme\/\(.*\)"$/\1/p' "$HANDOFF_RECORD" 2>/dev/null)"
case "$HANDOFF_HOSTED:$HANDOFF_RECORD" in
  m-*:*-"$HANDOFF_HOSTED".md)
    pass "a referenced handoff gets a registry record named with its hosted id" ;;
  *) fail "referenced handoff was not recorded under its hosted id" "record: $HANDOFF_RECORD" ;;
esac

if grep -qx "$CANON_LEGACY" "$UPLOADS/log"; then
  fail "the legacy path-derived id was published again"
else
  pass "a record from before random ids is not reused"
fi

: > "$UPLOADS/log"
SECOND_URL="$(publish_parent)"
wait_for 4 3 || fail "republished reference publishes did not finish" "$(cat "$UPLOADS/log" 2>/dev/null)"
# shellcheck disable=SC2086
EXPECTED="$(printf '%s\n' $FIRST_IDS | LC_ALL=C sort | tr '\n' ' ')"
REPUBLISHED="$(grep -v '^page-' "$UPLOADS/log" | LC_ALL=C sort | tr '\n' ' ')"
if [ "$REPUBLISHED" = "$EXPECTED" ]; then
  pass "republishing uploads every reference under the id it already had"
else
  fail "hosted ids changed on republish" "first: $EXPECTED republished: $REPUBLISHED"
fi
SECOND_PAGE="$UPLOADS/${SECOND_URL##*/}.html"
if [ "$(hosted_link "$SECOND_PAGE" m | tr '\n' ' ')" = "$EXPECTED" ]; then
  pass "the republished parent links to the same hosted ids"
else
  fail "republished parent links changed" "$(cat "$SECOND_PAGE" 2>/dev/null)"
fi

# --- Summary ---
echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
