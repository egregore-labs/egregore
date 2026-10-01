#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d -t handoff-preview-test-XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/bin/lib" "$FIXTURE/tmp" "$FIXTURE/packages/egregore-artifacts/bin" "$FIXTURE/previews" "$FIXTURE/memory/handoffs/2026-08"
cp "$ROOT/bin/handoff-preview.sh" "$FIXTURE/bin/handoff-preview.sh"
touch "$FIXTURE/packages/egregore-artifacts/bin/cli.js"

# The renderer stub records its argv and copies the Markdown it was handed
# (the source of a composed render, or the handoff itself).
cat > "$FIXTURE/bin/node-run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${PREVIEW_ARGS:?}"
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
[ ! -e "$FIXTURE/previews/$token.spec.json" ]

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

echo "PASS: handoff preview content is supplied once and approved by token, with or without a composed spec"
