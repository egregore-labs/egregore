#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMPD="$(mktemp -d -t handoff-fidelity-XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

SB="$TMPD/instance"
mkdir -p "$SB/bin" "$SB/memory/handoffs" "$TMPD/results"
cp "$ROOT/bin/handoff-run.sh" "$SB/bin/handoff-run.sh"
printf '# Handoffs\n\n' > "$SB/memory/handoffs/index.md"
printf '%s\n' '{"mode":"local"}' > "$SB/egregore.json"

cat > "$SB/bin/repo-state.sh" <<'SH'
#!/bin/bash
printf '## Repo State\n\n| Repo | Branch |\n| --- | --- |\n| should-not | appear |\n'
SH
chmod +x "$SB/bin/"*.sh

cat > "$TMPD/approved.md" <<'MD'
# Handoff: Approved body

## Briefing

This text is authoritative.

## Current State

1. Preserve this first.
2. Preserve this second.

```bash
egregore connect cadence
```

## Open Threads

- Keep this section.
MD

echo "test-handoff-content-fidelity"

if TMPDIR="$TMPD/results" bash "$SB/bin/handoff-run.sh" \
  --author alice \
  --topic "missing recipient" \
  --content-mode supplied \
  --no-push --no-publish --no-notify \
  < "$TMPD/approved.md" >"$TMPD/no-recipient.out" 2>"$TMPD/no-recipient.err"; then
  if [ "$(jq -r '.recipient' "$TMPD/results/handoff-run-result.json")" = "" ]; then
    pass "recipient-less supplied handoff retains the current optional-address behavior"
  else
    fail "recipient-less supplied handoff gained an unexpected recipient"
  fi
else
  fail "recipient-less supplied handoff was rejected"
fi

rm -f "$TMPD/results/handoff-run-result.json"
TMPDIR="$TMPD/results" bash "$SB/bin/handoff-run.sh" \
  --author alice \
  --topic "approved body" \
  --recipient bob \
  --content-mode supplied \
  --no-push --no-publish --no-notify \
  < "$TMPD/approved.md" >/dev/null

RESULT="$TMPD/results/handoff-run-result.json"
SAVED="$(jq -r '.absFile' "$RESULT")"
EXPECTED="$(cat "$TMPD/approved.md")"
VISIBLE="$(awk '
  /^---$/ { separators++; next }
  separators >= 2 { print }
' "$SAVED")"

if [ "$VISIBLE" = "$EXPECTED" ]; then
  pass "supplied visible body is preserved exactly"
else
  fail "supplied visible body changed"
fi

if grep -q '^content_mode: supplied$' "$SAVED"; then
  pass "supplied content mode is recorded in invisible frontmatter"
else
  fail "supplied content mode metadata is missing"
fi

if ! grep -q '^## Repo State$' "$SAVED" \
  && ! grep -q '^## Session Artifacts$' "$SAVED"; then
  pass "supplied mode adds no repo state or session artifacts"
else
  fail "supplied mode appended generated context"
fi

if [ "$(jq -r '.recipient' "$RESULT")" = "bob" ] \
  && [ "$(jq -r '.notifyStatus' "$RESULT")" = "skipped" ]; then
  pass "dry-run capture retains the recipient without notifying"
else
  fail "recipient or dry-run notification status is wrong"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
