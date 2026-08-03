#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER="$ROOT/bin/render-card.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

choose_utf8_locale() {
  local current candidate
  current="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  case "$current" in
    *UTF-8*|*utf-8*|*utf8*) return 0 ;;
  esac
  for candidate in C.UTF-8 en_US.UTF-8; do
    if locale -a 2>/dev/null | awk -v want="$candidate" 'tolower($0) == tolower(want) { found = 1 } END { exit found ? 0 : 1 }'; then
      export LC_ALL="$candidate"
      return 0
    fi
  done
  export LC_ALL="${LANG:-en_US.UTF-8}"
}

choose_utf8_locale

TMPD="$(mktemp -d -t render-card-test-XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

TOP="┌──────────────────────────────────────────────────────────────────────┐"
SEP="├──────────────────────────────────────────────────────────────────────┤"
BOTTOM="└──────────────────────────────────────────────────────────────────────┘"

echo "Testing: render-card.sh"
echo ""

write_result_a() {
  local result="$TMPD/a-result.json"
  local handoff="$TMPD/a-handoff.md"
  cat > "$handoff" <<'EOF'
# Handoff: minimal

## Briefing
No repo state here.
EOF
  cat > "$result" <<EOF
{
  "mode": "local",
  "file": "handoffs/2026-07/03-fixtureauthor-long-topic.md",
  "absFile": "$handoff",
  "sessionId": "",
  "resolved": 0,
  "graphStatus": "skipped",
  "memoryStatus": "skipped (--no-push)",
  "notifyStatus": "skipped",
  "artifactUrl": "",
  "publishStatus": "relay-off",
  "recipient": "",
  "topic": "This topic is deliberately longer than fifty eight characters for truncation coverage",
  "author": "fixtureauthor",
  "subgraph": null,
  "artifacts": []
}
EOF
  printf '%s' "$result"
}

write_result_b() {
  local result="$TMPD/b-result.json"
  local handoff="$TMPD/b-handoff.md"
  cat > "$handoff" <<'EOF'
# Handoff: full

## Repo State

| Repo | Branch | PR | Base |
|------|--------|----|------|
| egregore | dev/fixture/render-card | #123 | develop |
| egregore-site | preview/render-card | — | main |
EOF
  cat > "$result" <<EOF
{
  "mode": "connected",
  "file": "handoffs/2026-07/03-cem-render-card-port.md",
  "absFile": "$handoff",
  "sessionId": "session-1",
  "resolved": 0,
  "graphStatus": "ok",
  "memoryStatus": "ok",
  "notifyStatus": "approval_required",
  "artifactUrl": "https://egregore.xyz/handoff/render-card-port?smoke=1",
  "recipient": "renc",
  "topic": "Render card port",
  "author": "cem",
  "subgraph": {},
  "artifacts": [
    {"title": "Renderer contract", "type": "Decision", "path": "memory/knowledge/decisions/render-card.md"},
    {"title": "Smoke sample", "type": "Finding", "path": "memory/knowledge/patterns/render-card.md"}
  ]
}
EOF
  printf '%s' "$result"
}

write_result_c() {
  local result="$TMPD/c-result.json"
  local handoff="$TMPD/c-handoff.md"
  cat > "$handoff" <<'EOF'
# Handoff: degraded
EOF
  cat > "$result" <<EOF
{
  "mode": "connected",
  "file": "handoffs/2026-07/03-cem-degraded-render.md",
  "absFile": "$handoff",
  "sessionId": "session-2",
  "resolved": 0,
  "graphStatus": "offline",
  "memoryStatus": "failed",
  "notifyStatus": "unavailable",
  "artifactUrl": "",
  "recipient": "oz",
  "topic": "Degraded render",
  "author": "cem",
  "subgraph": null,
  "artifacts": []
}
EOF
  printf '%s' "$result"
}

write_result_d() {
  local result="$TMPD/d-result.json"
  local handoff="$TMPD/d-handoff.md"
  cat > "$handoff" <<'EOF'
# Handoff: long token
EOF
  cat > "$result" <<EOF
{
  "mode": "local",
  "file": "handoffs/2026-07/03-cem-long-token.md",
  "absFile": "$handoff",
  "sessionId": "",
  "resolved": 0,
  "graphStatus": "skipped",
  "memoryStatus": "skipped",
  "notifyStatus": "skipped",
  "artifactUrl": "",
  "recipient": "",
  "topic": "Long token wrap",
  "author": "cem",
  "subgraph": null,
  "artifacts": []
}
EOF
  printf '%s' "$result"
}

extract_box() {
  awk '
    /^```$/ { fence += 1; next }
    fence == 1 { print }
  ' "$1"
}

assert_box_widths() {
  local output="$1"
  local label="$2"
  local bad
  bad="$(
    extract_box "$output" | while IFS= read -r line; do
      len="$(printf '%s' "$line" | jq -Rs 'length')"
      if [ "$len" -ne 72 ]; then
        printf '%s:%s:%s\n' "$(( ${line_no:-0} + 1 ))" "$len" "$line"
      fi
      line_no=$(( ${line_no:-0} + 1 ))
    done
  )"
  if [ -z "$bad" ]; then
    pass "$label: every fenced line is 72 columns"
  else
    fail "$label: fenced line width mismatch" "$bad"
  fi
}

assert_frame_lines() {
  local output="$1"
  local label="$2"
  local box="$TMPD/${label}-box.txt"
  extract_box "$output" > "$box"
  if [ "$(sed -n '1p' "$box")" = "$TOP" ]; then
    pass "$label: top border exact"
  else
    fail "$label: top border mismatch"
  fi
  if awk -v sep="$SEP" '/^├/ && $0 != sep { bad = 1 } END { exit bad ? 1 : 0 }' "$box"; then
    pass "$label: separator borders exact"
  else
    fail "$label: separator border mismatch"
  fi
  if [ "$(tail -n 1 "$box")" = "$BOTTOM" ]; then
    pass "$label: bottom border exact"
  else
    fail "$label: bottom border mismatch"
  fi
}

assert_no_warnings() {
  local output="$1"
  local label="$2"
  if awk 'BEGIN { ok = 1 } /^```$/ { exit ok ? 0 : 1 } /^⚠/ { ok = 0 }' "$output"; then
    pass "$label: no warnings above fence"
  else
    fail "$label: unexpected warning above fence"
  fi
}

A_RESULT="$(write_result_a)"
B_RESULT="$(write_result_b)"
C_RESULT="$(write_result_c)"
D_RESULT="$(write_result_d)"

printf 'A compact briefing for local mode.' | bash "$RENDER" --result "$A_RESULT" > "$TMPD/a.out"
printf 'This briefing proves wrapping across a few short operational sentences without redesigning the card.' | bash "$RENDER" --result "$B_RESULT" > "$TMPD/b.out"
printf 'Degraded path briefing.' | bash "$RENDER" --result "$C_RESULT" > "$TMPD/c.out"
LONG_URL='https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
printf 'Use %s for verification.' "$LONG_URL" | bash "$RENDER" --result "$D_RESULT" > "$TMPD/d.out"
bash "$RENDER" --result "$A_RESULT" < /dev/null > "$TMPD/abs.out"
printf 'Override briefing wins.' > "$TMPD/override-briefing.txt"
bash "$RENDER" --result "$A_RESULT" --briefing-file "$TMPD/override-briefing.txt" < /dev/null > "$TMPD/override.out"

for label in a b c d abs override; do
  assert_box_widths "$TMPD/$label.out" "$label"
  assert_frame_lines "$TMPD/$label.out" "$label"
done

assert_no_warnings "$TMPD/a.out" "a"
assert_no_warnings "$TMPD/b.out" "b"

if grep -q 'To:' "$TMPD/a.out"; then
  fail "a: no To line"
else
  pass "a: no To line"
fi
if grep -q 'REPOS' "$TMPD/a.out" || grep -q '◉ ' "$TMPD/a.out"; then
  fail "a: omitted sections leaked"
else
  pass "a: no REPOS or artifacts sections"
fi
if grep -qx '`/view handoff long-topic` (open locally)' "$TMPD/a.out"; then
  pass "a: links line is only the /view hint with local suffix"
else
  fail "a: links line mismatch" "$(tail -n 1 "$TMPD/a.out")"
fi
if grep -q '✓ saved · not published' "$TMPD/a.out"; then
  pass "a: relay-off status is visible"
else
  fail "a: relay-off status bit missing"
fi
if grep -Fq 'Not published — this handoff stayed on your machine.' "$TMPD/a.out" &&
   grep -Fq 'bin/settings.sh relay on' "$TMPD/a.out"; then
  pass "a: relay-off explanation names the opt-in"
else
  fail "a: relay-off explanation missing"
fi
if grep -q 'Topic: This topic is deliberately longer than fifty eight charac…' "$TMPD/a.out"; then
  pass "a: long topic truncates with ellipsis"
else
  fail "a: long topic truncation missing"
fi

if grep -q 'To:    Renc' "$TMPD/b.out"; then
  pass "b: To line present"
else
  fail "b: To line missing"
fi
if grep -q '◈ egregore: dev/fixture/render-card → PR #123 to develop' "$TMPD/b.out" &&
   grep -q '◈ egregore-site: preview/render-card → main' "$TMPD/b.out"; then
  pass "b: REPOS rows render PR and non-PR formats"
else
  fail "b: REPOS rows missing"
fi
if grep -q '◉ Decision: Renderer contract' "$TMPD/b.out" &&
   grep -q '◉ Finding: Smoke sample' "$TMPD/b.out"; then
  pass "b: artifact rows present"
else
  fail "b: artifact rows missing"
fi
if grep -q 'published' "$TMPD/b.out"; then
  pass "b: published status bit present"
else
  fail "b: published status bit missing"
fi
if grep -qx '\[view this handoff →\](https://egregore.xyz/handoff/render-card-port?smoke=1)  ·  `/view handoff render-card-port` (open locally)' "$TMPD/b.out"; then
  pass "b: full links line present with local suffix"
else
  fail "b: full links line mismatch" "$(tail -n 1 "$TMPD/b.out")"
fi

if awk 'NR == 1 && $0 == "⚠ graph indexing failed — will sync on next /save" { g = 1 }
        NR == 2 && $0 == "⚠ memory push failed — commits are local" { m = 1 }
        NR == 3 && $0 == "Notification unavailable — no message was sent." { n = 1 }
        END { exit (g && m && n) ? 0 : 1 }' "$TMPD/c.out"; then
  pass "c: all degraded warnings above fence"
else
  fail "c: degraded warnings mismatch" "$(sed -n '1,3p' "$TMPD/c.out")"
fi

if grep -q 'No repo state here.' "$TMPD/abs.out"; then
  pass "absFile fallback: no input renders ## Briefing section"
else
  fail "absFile fallback: briefing section missing"
fi

if extract_box "$TMPD/d.out" | sed 's/^│  //; s/[[:space:]]*│$//' | tr -d '\n' | grep -q "$LONG_URL"; then
  pass "d: 90-char URL preserved across wrapped lines"
else
  fail "d: long URL not preserved across wrapped lines"
fi

set +e
bash "$RENDER" --result "$C_RESULT" < /dev/null > "$TMPD/no-briefing.out" 2> "$TMPD/no-briefing.err"
no_briefing_ec=$?
set -e
if [ "$no_briefing_ec" -ne 0 ] &&
   [ ! -s "$TMPD/no-briefing.out" ] &&
   grep -q 'briefing input is empty' "$TMPD/no-briefing.err"; then
  pass "missing briefing: nonzero exit, stderr message, no stdout"
else
  fail "missing briefing behavior mismatch" "exit=$no_briefing_ec stdout=$(cat "$TMPD/no-briefing.out") stderr=$(cat "$TMPD/no-briefing.err")"
fi

if grep -q 'Override briefing wins.' "$TMPD/override.out" &&
   ! grep -q 'No repo state here.' "$TMPD/override.out"; then
  pass "--briefing-file overrides absFile briefing"
else
  fail "--briefing-file override behavior mismatch"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
