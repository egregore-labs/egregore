#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d -t handoff-preview-test-XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ORIGINAL_PATH="$PATH"
export EGREGORE_USE_PUBLISHED=0

for renderer_kind in path managed; do
FIXTURE="$TMP_ROOT/$renderer_kind downstream instance"
SHIMS="$FIXTURE/system commands"
mkdir -p "$FIXTURE/bin/lib" "$FIXTURE/tmp" "$SHIMS" "$FIXTURE/previews" "$FIXTURE/memory/handoffs/2026-08"
cp "$ROOT/bin/handoff-preview.sh" "$FIXTURE/bin/handoff-preview.sh"
cp "$ROOT/bin/artifact-renderer.sh" "$FIXTURE/bin/artifact-renderer.sh"
cp -R "$ROOT/bin/lib/artifact-renderer" "$FIXTURE/bin/lib/artifact-renderer"

# Run the real production resolver in a downstream-shaped tree, not a fake
# packages/ checkout. Keep the developer's own renderer and package managers
# out of PATH so neither can make a missing-install test pass accidentally.
for command_name in awk bash cat chmod cmp cp date dirname find grep jq mkdir mktemp mv openssl python3 readlink realpath rm rmdir sed shasum sha256sum touch; do
  command_path="$(command -v "$command_name" || true)"
  [ -z "$command_path" ] || ln -s "$command_path" "$SHIMS/$command_name"
done
cat > "$SHIMS/npm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "${NETWORK_CALLS:?}"
exit 91
SH
cp "$SHIMS/npm" "$SHIMS/npx"
cp "$SHIMS/npm" "$FIXTURE/bin/artifact-renderer-install.sh"
chmod +x "$SHIMS/npm" "$SHIMS/npx"
if [ "$renderer_kind" = path ]; then
  EXPECTED_CLI="$SHIMS/egregore-artifacts"
else
  install_id="$(python3 - "$FIXTURE/bin/lib/artifact-renderer" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1])
print(json.loads((p/'dependencies.json').read_text())['dependencies']['egregore-artifacts'] + '-' + hashlib.sha256((p/'dependencies-lock.json').read_bytes()).hexdigest()[:16])
PY
)"
  managed="$FIXTURE/.egregore/tools/artifact-renderer/$install_id"
  EXPECTED_CLI="$managed/node_modules/egregore-artifacts/bin/cli.js"
  mkdir -p "$(dirname "$EXPECTED_CLI")" "$managed/node_modules/react"
  cp "$FIXTURE/bin/lib/artifact-renderer/dependencies.json" "$managed/package.json"
  cp "$FIXTURE/bin/lib/artifact-renderer/dependencies-lock.json" "$managed/package-lock.json"
fi
touch "$EXPECTED_CLI"
chmod +x "$EXPECTED_CLI"

# The renderer stub records its argv and copies the Markdown it was handed
# (the source of a composed render, or the handoff itself).
cat > "$FIXTURE/bin/node-run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${PREVIEW_ARGS:?}"
if [ "${PREVIEW_RENDER_EXIT:-0}" != 0 ]; then
  echo 'fixture renderer rejected content' >&2
  exit "$PREVIEW_RENDER_EXIT"
fi
if [ "$2" = "composed" ]; then
  cp "$5" "${PREVIEW_CAPTURE:?}"
  cp "$3" "${PREVIEW_SPEC_CAPTURE:?}"
else
  cp "$3" "${PREVIEW_CAPTURE:?}"
fi
printf 'preview rendered\n'
SH

cat > "$FIXTURE/bin/artifact-writeback.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "${WRITEBACK_CALLS:?}"
if [ "$1" = "create" ]; then
  printf '%s\n' "$@" > "${CREATE_ARGS:?}"
  cp "$5" "${CREATE_CAPTURE:?}"
  exit 0
fi
printf '%s\n' "$@" > "${WRITEBACK_ARGS:?}"
cat > "${WRITEBACK_CAPTURE:?}"
cp "$WRITEBACK_CAPTURE" "$FIXTURE_CANONICAL"
jq -nc --arg absFile "$FIXTURE_CANONICAL" '{absFile:$absFile}' \
  > "${TMPDIR:?}/capture-run-result.json"
printf '⇌ saved\n'
SH

cat > "$FIXTURE/bin/render-card.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ -s "${2:?}" ]
printf 'canonical result card\n'
SH

chmod +x "$FIXTURE/bin/"*.sh

export EGREGORE_HANDOFF_PREVIEW_DIR="$FIXTURE/previews"
export PREVIEW_ARGS="$FIXTURE/preview.args"
export PREVIEW_CAPTURE="$FIXTURE/preview.md"
export PREVIEW_SPEC_CAPTURE="$FIXTURE/preview.spec.json"
export WRITEBACK_CAPTURE="$FIXTURE/writeback.md"
export WRITEBACK_ARGS="$FIXTURE/writeback.args"
export CREATE_ARGS="$FIXTURE/create.args"
export CREATE_CAPTURE="$FIXTURE/create.json"
export FIXTURE_CANONICAL="$FIXTURE/canonical.md"
export WRITEBACK_CALLS="$FIXTURE/writeback.calls"
export NETWORK_CALLS="$FIXTURE/network.calls"
export PATH="$SHIMS"

cat > "$FIXTURE/input.md" <<'MD'
---
capture_schema: egregore-capture/v1
capture_mode: addressed
kind: addressed
from: oz
addressed_to: oz
date: 2026-08-30
topic: preview-token-test
intent: action
content_mode: generated
claim: The exact preview is written once.
ask: Resume this work.
---

## Briefing

The approved bytes must not be regenerated.
MD

# ── Markdown-only preview and approval (the /handoff path) ──────────────
preview_output="$(bash "$FIXTURE/bin/handoff-preview.sh" preview \
  --author oz --recipient oz --topic preview-token-test \
  --intent action --content-mode generated < "$FIXTURE/input.md")"
token="$(printf '%s\n' "$preview_output" | sed -n 's/^HANDOFF_PREVIEW_TOKEN=//p')"
[[ "$token" =~ ^[a-f0-9]{32}$ ]]
cmp "$FIXTURE/input.md" "$FIXTURE/preview.md"
cmp "$FIXTURE/input.md" "$FIXTURE/previews/$token.md"
grep -Fxq -- 'handoff' "$FIXTURE/preview.args"
grep -Fxq -- '--verify-fidelity' "$FIXTURE/preview.args"
[ "$(sed -n '1p' "$FIXTURE/preview.args")" = "$EXPECTED_CLI" ]
[ ! -e "$FIXTURE/previews/$token.spec.json" ]
[ ! -e "$WRITEBACK_CALLS" ]
[ ! -e "$FIXTURE/packages" ]

approval_output="$(bash "$FIXTURE/bin/handoff-preview.sh" approve "$token")"
cmp "$FIXTURE/input.md" "$FIXTURE/writeback.md"
grep -Fxq -- '--recipient' "$FIXTURE/writeback.args"
if grep -Fxq -- '--composed' "$FIXTURE/writeback.args"; then
  echo "markdown-only approval must not pass --composed" >&2
  exit 1
fi
grep -Fq 'canonical result card' <<< "$approval_output"
[ ! -e "$FIXTURE/previews/$token.md" ]
[ ! -e "$FIXTURE/previews/$token.json" ]
if bash "$FIXTURE/bin/handoff-preview.sh" approve "$token" >/dev/null 2>&1; then
  echo "single-use preview token was accepted twice" >&2
  exit 1
fi

# ── Composed (staircase) preview and approval (the /handoff-staircase path) ──
printf '%s\n' '{"kind":"staircase","schema":"egregore-staircase/v1"}' > "$FIXTURE/spec.json"
export FIXTURE_CANONICAL="$FIXTURE/memory/handoffs/2026-08/30-oz-preview-token-test.md"
: > "$FIXTURE/preview.args"
cp "$WRITEBACK_CALLS" "$FIXTURE/writeback.before-preview"

composed_output="$(bash "$FIXTURE/bin/handoff-preview.sh" preview \
  --author oz --recipient oz --topic preview-token-test \
  --intent action --content-mode generated --composed "$FIXTURE/spec.json" \
  < "$FIXTURE/input.md")"
ctoken="$(printf '%s\n' "$composed_output" | sed -n 's/^HANDOFF_PREVIEW_TOKEN=//p')"
[[ "$ctoken" =~ ^[a-f0-9]{32}$ ]]
[ "$ctoken" != "$token" ]
grep -Fxq -- 'composed' "$FIXTURE/preview.args"
grep -Fxq -- '--source' "$FIXTURE/preview.args"
grep -Fxq -- '--verify-fidelity' "$FIXTURE/preview.args"
[ "$(sed -n '1p' "$FIXTURE/preview.args")" = "$EXPECTED_CLI" ]
cmp "$WRITEBACK_CALLS" "$FIXTURE/writeback.before-preview"
cmp "$FIXTURE/input.md" "$FIXTURE/preview.md"
cmp "$FIXTURE/spec.json" "$FIXTURE/preview.spec.json"
cmp "$FIXTURE/spec.json" "$FIXTURE/previews/$ctoken.spec.json"
[ -f "$FIXTURE/spec.json" ] # A caller's document outside tmp remains intact.
jq -e '.specDigest | length == 64' "$FIXTURE/previews/$ctoken.json" >/dev/null

# The previewed spec is bound by digest: a changed spec is refused at approval.
cp "$FIXTURE/previews/$ctoken.spec.json" "$FIXTURE/spec.backup.json"
printf '%s\n' '{"kind":"staircase","schema":"egregore-staircase/v1","tampered":true}' \
  > "$FIXTURE/previews/$ctoken.spec.json"
if bash "$FIXTURE/bin/handoff-preview.sh" approve "$ctoken" >/dev/null 2>&1; then
  echo "approval accepted a composed spec that changed after preview" >&2
  exit 1
fi
cp "$FIXTURE/spec.backup.json" "$FIXTURE/previews/$ctoken.spec.json"
[ -e "$FIXTURE/previews/$ctoken.md" ]

composed_approval="$(bash "$FIXTURE/bin/handoff-preview.sh" approve "$ctoken")"
cmp "$FIXTURE/input.md" "$FIXTURE/writeback.md"
grep -Fxq -- '--composed' "$FIXTURE/writeback.args"
grep -Fxq -- '--recipient' "$FIXTURE/writeback.args"
grep -Fq 'canonical result card' <<< "$composed_approval"
# The spec is persisted beside the canonical record through the writeback bridge.
grep -Fxq -- 'create' "$FIXTURE/create.args"
grep -Fxq -- 'memory/handoffs/2026-08/30-oz-preview-token-test.staircase.json' "$FIXTURE/create.args"
cmp "$FIXTURE/spec.json" "$FIXTURE/create.json"
[ ! -e "$FIXTURE/previews/$ctoken.md" ]
[ ! -e "$FIXTURE/previews/$ctoken.json" ]
[ ! -e "$FIXTURE/previews/$ctoken.spec.json" ]
if bash "$FIXTURE/bin/handoff-preview.sh" approve "$ctoken" >/dev/null 2>&1; then
  echo "single-use composed preview token was accepted twice" >&2
  exit 1
fi

# A composed scratch spec survives preview for publish-artifact's later read.
cp "$FIXTURE/spec.json" "$FIXTURE/tmp/spec.json"
bash "$FIXTURE/bin/handoff-preview.sh" preview \
  --author oz --recipient oz --topic scratch-preservation \
  --intent action --content-mode generated --composed "$FIXTURE/tmp/spec.json" \
  < "$FIXTURE/input.md" > "$FIXTURE/scratch-preview.out"
cmp "$FIXTURE/spec.json" "$FIXTURE/tmp/spec.json"
cmp "$FIXTURE/spec.json" "$FIXTURE/preview.spec.json"
# Failed validation also leaves the shared spec to the session sweep.
printf 'not json' > "$FIXTURE/tmp/invalid.json"
if bash "$FIXTURE/bin/handoff-preview.sh" preview \
  --author oz --recipient oz --topic scratch-preservation \
  --intent action --content-mode generated --composed "$FIXTURE/tmp/invalid.json" \
  < "$FIXTURE/input.md" > /dev/null 2> "$FIXTURE/invalid.stderr"; then
  echo "--composed accepted invalid scratch JSON" >&2
  exit 1
fi
[ "$(cat "$FIXTURE/tmp/invalid.json")" = 'not json' ]
grep -Fq 'handoff preview --composed file is not JSON' "$FIXTURE/invalid.stderr"

if bash "$FIXTURE/bin/handoff-preview.sh" preview \
  --author oz --recipient oz --topic preview-token-test \
  --intent action --content-mode supplied --composed "$FIXTURE/spec.json" \
  < "$FIXTURE/input.md" >/dev/null 2>&1; then
  echo "--composed was accepted with supplied content" >&2
  exit 1
fi
printf 'not json' > "$FIXTURE/bad.json"
if bash "$FIXTURE/bin/handoff-preview.sh" preview \
  --author oz --recipient oz --topic preview-token-test \
  --intent action --content-mode generated --composed "$FIXTURE/bad.json" \
  < "$FIXTURE/input.md" >/dev/null 2>&1; then
  echo "--composed accepted a non-JSON spec" >&2
  exit 1
fi

# Rendering failure must leave no approval token, private Markdown, metadata or
# composed spec behind, and must never cross the canonical writeback boundary.
cp "$WRITEBACK_CALLS" "$FIXTURE/writeback.before-failure"
for preview_mode in handoff composed; do
  failure_store="$FIXTURE/failed $preview_mode previews"
  preview_args=(--author oz --recipient oz --topic rejected-preview --intent action --content-mode generated)
  if [ "$preview_mode" = composed ]; then
    preview_args+=(--composed "$FIXTURE/spec.json")
  fi
  if EGREGORE_HANDOFF_PREVIEW_DIR="$failure_store" PREVIEW_RENDER_EXIT=23 \
    bash "$FIXTURE/bin/handoff-preview.sh" preview "${preview_args[@]}" \
    < "$FIXTURE/input.md" > "$FIXTURE/failure.stdout" 2> "$FIXTURE/failure.stderr"; then
    echo "$preview_mode preview ignored renderer failure" >&2
    exit 1
  fi
  ! grep -Fq 'HANDOFF_PREVIEW_TOKEN=' "$FIXTURE/failure.stdout"
  [ -z "$(find "$failure_store" -type f -print)" ]
  grep -Fq 'fixture renderer rejected content' "$FIXTURE/failure.stderr"
  cmp "$WRITEBACK_CALLS" "$FIXTURE/writeback.before-failure"
done

# The unavailable-install path uses the same cleanup behavior and emits an
# explicit repair instruction without secretly invoking the installer/npm.
rm -f "$EXPECTED_CLI"
failure_store="$FIXTURE/missing renderer previews"
if EGREGORE_HANDOFF_PREVIEW_DIR="$failure_store" \
  bash "$FIXTURE/bin/handoff-preview.sh" preview \
  --author oz --recipient oz --topic missing-renderer --intent action --content-mode generated \
  < "$FIXTURE/input.md" > "$FIXTURE/missing.stdout" 2> "$FIXTURE/missing.stderr"; then
  echo "preview succeeded without an installed renderer" >&2
  exit 1
fi
! grep -Fq 'HANDOFF_PREVIEW_TOKEN=' "$FIXTURE/missing.stdout"
[ -z "$(find "$failure_store" -type f -print)" ]
grep -Fq 'artifact-renderer-install.sh' "$FIXTURE/missing.stderr"
cmp "$WRITEBACK_CALLS" "$FIXTURE/writeback.before-failure"
[ ! -e "$NETWORK_CALLS" ]
echo "PASS: $renderer_kind renderer previews preserve approval, fidelity, cleanup and offline boundaries"
export PATH="$ORIGINAL_PATH"
done

echo "PASS: handoff previews work without packages/ using managed or PATH renderers"
