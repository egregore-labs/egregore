#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PALETTE="$ROOT_DIR/.claude/skills/harvest/QUESTION_PALETTE.md"
PORTABLE_PALETTE="$ROOT_DIR/.codex/skills/harvest/QUESTION_PALETTE.md"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$(basename "$file") missing: $text"
}

[ -s "$PALETTE" ] || fail "harvest question palette is missing or empty"
[ -s "$PORTABLE_PALETTE" ] || fail "portable question palette mirror is missing or empty"
cmp -s "$PALETTE" "$PORTABLE_PALETTE" || fail "Codex/Pi palette mirror drifted from the canonical harvest file"

require_text "$ROOT_DIR/.claude/skills/harvest/SKILL.md" ".claude/skills/harvest/QUESTION_PALETTE.md"
require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "[\`QUESTION_PALETTE.md\`](./QUESTION_PALETTE.md)"
require_text "$ROOT_DIR/.claude/skills/harvest/FORMAT.md" "[\`QUESTION_PALETTE.md\`](./QUESTION_PALETTE.md)"
require_text "$ROOT_DIR/.claude/skills/scroll/SKILL.md" ".claude/skills/harvest/QUESTION_PALETTE.md"
require_text "$ROOT_DIR/.codex/skills/harvest/SKILL.md" 'Read `QUESTION_PALETTE.md` completely.'

scroll_refs="$(grep -Fc '.claude/skills/harvest/QUESTION_PALETTE.md' "$ROOT_DIR/.claude/skills/scroll/SKILL.md")"
[ "$scroll_refs" -eq 1 ] || fail "scroll must reference the canonical palette exactly once; found $scroll_refs"

require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "explain why the chosen answer shape fits it"
require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" 'An answer shape selected from `QUESTION_PALETTE.md`.'
if grep -Fq '2–3 **options**' "$ROOT_DIR/.claude/skills/harvest/PROCESS.md"; then
  fail "PROCESS still requires option cards for every question"
fi
for move in "ladder" "critical incident" "triad" "best-worst" "swing question" "mirrored-inference check"; do
  require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "$move"
done
require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "Satisficing watch"
require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "Sycophancy guard"

require_text "$PALETTE" "No agree/disagree, true/false, or yes/no stems"
require_text "$PALETTE" "No draggable sliders with a preset thumb"
require_text "$PALETTE" "No batteries of stacked identical gauges"
require_text "$PALETTE" "Nothing pre-selected, ever"
require_text "$PALETTE" "No dropdowns in surfaces; >4 genuine options means an unsplit fork"
require_text "$PALETTE" "There is no shape quota or preset flow."
require_text "$PALETTE" "no default per-section controls"
require_text "$ROOT_DIR/.claude/skills/scroll/SKILL.md" "never make every face section reactable"
if grep -Eiq 'reaction blocks?' \
  "$PALETTE" "$ROOT_DIR/.claude/skills/scroll/SKILL.md" "$ROOT_DIR/.codex/skills/scroll/SKILL.md"; then
  fail "show-then-ask still promises a reaction block"
fi
require_text "$PALETTE" "Default to blind independent collection"
require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "other respondents' answer content neither appears nor shapes their questions"
require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "the completion count is the number"
require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "A majority is not collective alignment"
require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "There is no"
require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "automatic second pass after disclosure"
require_text "$ROOT_DIR/.claude/skills/harvest/PROCESS.md" "Never turn attributed positions into an anonymous or aggregate claim"
require_text "$ROOT_DIR/.claude/skills/harvest/SKILL.md" "dispatch the frozen question set unchanged"
require_text "$ROOT_DIR/.codex/skills/harvest/SKILL.md" "After the declared"
if grep -REiq 'use an .?IDEA round|private revision after disclosure|completes the IDEA structure|rounds capped 2.?3' \
  "$ROOT_DIR/.claude/skills/harvest" "$ROOT_DIR/.codex/skills/harvest" \
  "$ROOT_DIR/docs/specs/scroll-harvest-iteration.md"; then
  fail "harvest contracts still require post-disclosure revision machinery"
fi
if grep -REiq 'window(ed)? deadline|deadline passes' \
  "$ROOT_DIR/.claude/skills/harvest" "$ROOT_DIR/.codex/skills/harvest"; then
  fail "harvest contracts restored a deadline trigger without stored deadline state"
fi

if grep -REn 'use (at least|exactly) [0-9]+ (answer )?(modes|shapes)|minimum of [0-9]+ (answer )?(modes|shapes)|[0-9]+ modes per' \
  "$ROOT_DIR/.claude/skills/harvest" "$ROOT_DIR/.claude/skills/scroll/SKILL.md"; then
  fail "question contracts contain a mode/shape quota"
fi

echo "ok — harvest question palette is canonical, cross-runtime, referenced, and lintable"
