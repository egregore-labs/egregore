#!/usr/bin/env bash
set -uo pipefail

# Test: prose rule contract (docs/specs/prose-rule-v1.md).
# The shipped rules validate against their own examples; the validator
# rejects a rule whose examples misbehave (fixture canary); check scopes by
# surface, exempts code and quoted speech, and exits by severity.

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR" || exit 1
pc() { bash bin/node-run.sh bin/prose-check.mjs "$@"; }
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Testing: prose rule contract"
echo ""

# ============================================================
# 1. Shipped rules satisfy the contract and their own examples
# ============================================================
OUT="$(pc validate 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && pass "validate: shipped rules pass" || fail "validate: shipped rules fail" "$OUT"
RULE_COUNT="$(ls bin/prose-rules/*.md | wc -l | tr -d ' ')"
grep -q "prose-check: $RULE_COUNT rules valid" <<< "$OUT" \
  && pass "validate: reports all $RULE_COUNT rule files" \
  || fail "validate: rule count mismatch" "$OUT"
MECH="$(pc list | grep -c ' mechanical ')"
[ "$MECH" -ge 10 ] && pass "list: $MECH mechanical rules shipped" || fail "list: expected ≥10 mechanical rules, got $MECH"

# ============================================================
# 2. Fixture canary: a broken rule fails validation, by name
# ============================================================
cp -R bin/prose-rules "$TMP/rules"
cat > "$TMP/rules/canary-broken.md" <<'EOF'
---
name: canary-broken
description: A rule whose Fails example never matches.
tier: mechanical
severity: block
surfaces: all
fix: none
patterns:
  - '\bzzzz\b'
---

A rule whose failing example does not trigger its own pattern.

## Fails

- this sentence never says the word

## Passes

- neither does this one
EOF
OUT="$(pc validate --rules-dir "$TMP/rules" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && pass "canary: validate exits non-zero on a broken rule" || fail "canary: validate passed a broken rule" "$OUT"
grep -q 'canary-broken.md: Fails item does not match' <<< "$OUT" \
  && pass "canary: names the rule and the failing example" \
  || fail "canary: missing diagnostic" "$OUT"
rm "$TMP/rules/canary-broken.md"

cat > "$TMP/rules/canary-leaky.md" <<'EOF'
---
name: canary-leaky
description: A rule whose Passes example matches.
tier: mechanical
severity: warn
surfaces: [git]
fix: none
patterns:
  - '\bfine\b'
---

A rule whose passing example trips its own pattern.

## Fails

- fine

## Passes

- this is fine
EOF
OUT="$(pc validate --rules-dir "$TMP/rules" 2>&1)"; RC=$?
grep -q 'canary-leaky.md: Passes item matches pattern' <<< "$OUT" && [ "$RC" -ne 0 ] \
  && pass "canary: a Passes item that matches fails validation" \
  || fail "canary: leaky Passes item not caught" "$OUT"
rm "$TMP/rules/canary-leaky.md"

cat > "$TMP/rules/canary-shape.md" <<'EOF'
---
name: wrong-name
description: Frontmatter that breaks the contract in several ways.
tier: vibes
severity: block
surfaces: [git, telepathy]
---

Body.

## Fails

- x
EOF
OUT="$(pc validate --rules-dir "$TMP/rules" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && pass "canary: shape violations exit non-zero" || fail "canary: shape violations exited 0" "$OUT"
for NEEDLE in "must equal file basename" "tier must be one of" "unknown surface 'telepathy'" "fix is required" "## Passes needs at least one item"; do
  grep -q "$NEEDLE" <<< "$OUT" && pass "canary: contract check '$NEEDLE'" || fail "canary: missing '$NEEDLE'" "$OUT"
done
rm "$TMP/rules/canary-shape.md"

cat > "$TMP/rules/canary-judgment.md" <<'EOF'
---
name: canary-judgment
description: A judgment rule that tries to block and carry patterns.
tier: judgment
severity: block
surfaces: all
fix: none
patterns:
  - '\bx\b'
---

Body.

## Fails

- x

## Passes

- y
EOF
OUT="$(pc validate --rules-dir "$TMP/rules" 2>&1)"; RC=$?
grep -q "judgment rules carry no patterns" <<< "$OUT" && grep -q "judgment rules are warn only" <<< "$OUT" && [ "$RC" -ne 0 ] \
  && pass "canary: judgment tier cannot block or carry patterns" \
  || fail "canary: judgment tier constraints not enforced" "$OUT"

# ============================================================
# 3. check: findings, severity exit, advisory, formats
# ============================================================
cat > "$TMP/dirty.md" <<'EOF'
## What

- We're excited to announce that we leverage the graph to delve into handoffs!
- Addressed review feedback on the checker, updated per our discussion.
- This isn't just a linter. It's a very robust gate.

## Why

In today's fast-paced world, teams might potentially lose context.
An innovative approach.
EOF
OUT="$(pc check --surface git "$TMP/dirty.md" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && pass "check: exits 1 on block findings" || fail "check: expected exit 1, got $RC" "$OUT"
for RULE in passive-enthusiasm banned-vocabulary exclamation process-narration not-x-but-y filler-intensifiers temporal-handwave hedging-stack self-praise; do
  grep -q "  $RULE (" <<< "$OUT" && pass "check: $RULE fires" || fail "check: $RULE did not fire" "$OUT"
done
grep -q 'dirty.md:3:' <<< "$OUT" && pass "check: line numbers point at the source line" || fail "check: line numbers wrong" "$OUT"

pc check --surface git --advisory "$TMP/dirty.md" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && pass "check: --advisory exits 0 with block findings" || fail "check: --advisory exited $RC"

JSON="$(pc check --surface git --format json "$TMP/dirty.md" 2>/dev/null)"
printf '%s' "$JSON" | bash bin/node-run.sh -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const a=JSON.parse(s);if(!Array.isArray(a)||!a.length||!a[0].rule||!a[0].fix)process.exit(1)})' \
  && pass "check: --format json is a findings array with rule and fix" \
  || fail "check: json output malformed" "$JSON"

printf 'The build passed.\n' > "$TMP/tidy.md"
CLEAN_JSON="$(pc check --surface git --format json "$TMP/tidy.md" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(printf '%s' "$CLEAN_JSON" | tr -d '[:space:]')" = "[]" ] \
  && pass "check: --format json emits [] on a clean document" \
  || fail "check: clean json output is not []" "$CLEAN_JSON"

GH="$(pc check --surface git --format github "$TMP/dirty.md" 2>/dev/null)"
grep -q '^::error file=.*line=3.*title=prose banned-vocabulary::' <<< "$GH" \
  && pass "check: --format github emits workflow annotations" \
  || fail "check: github format wrong" "$GH"

STDIN_OUT="$(printf 'We are thrilled to share this.\n' | pc check --surface memory - 2>&1)"
grep -q '<stdin>:1:' <<< "$STDIN_OUT" && pass "check: reads stdin with -" || fail "check: stdin not read" "$STDIN_OUT"

# ============================================================
# 4. Surface scoping
# ============================================================
EXT="$(pc check --surface external "$TMP/dirty.md" 2>&1)"
grep -q 'filler-intensifiers\|process-narration' <<< "$EXT" \
  && fail "surface: git-only rules leaked into external" "$EXT" \
  || pass "surface: filler-intensifiers and process-narration do not run on external"
grep -q 'banned-vocabulary' <<< "$EXT" && pass "surface: surfaces=all rules still run on external" || fail "surface: all-surface rule missing on external" "$EXT"
pc check --surface telepathy "$TMP/dirty.md" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && pass "surface: unknown surface is a usage error" || fail "surface: unknown surface exited $RC"

# The skill audit uses findMatches on raw lines: tool identifiers are invalid
# even in code spans and fences, which ordinary prose preprocessing exempts.
for PHRASE in 'Write tool' 'Read tool' 'Edit tool' 'MultiEdit tool' 'Bash tool' \
  'Glob tool' 'Grep tool' 'Task tool' 'Agent tool' 'WebFetch tool' \
  'WebSearch tool' 'NotebookEdit tool' AskUserQuestion EnterWorktree ExitWorktree TodoWrite; do
  HIT="$(printf 'Use %s here.\n' "$PHRASE" | pc check --surface harness - 2>&1)"; RC=$?
  [ "$RC" -eq 1 ] && grep -q 'harness-tool-names (block)' <<< "$HIT" \
    && pass "harness vocabulary: $PHRASE is blocked" \
    || fail "harness vocabulary: $PHRASE was not blocked" "$HIT"
done
OUT="$(bash bin/node-run.sh --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { loadRules, findMatches } from './bin/prose-check.mjs';
const rule = loadRules().find(rule => rule.meta.name === 'harness-tool-names');
const identifierRule = { ...rule, regexes: [rule.regexes.at(-1)] };
for (const name of ['AskUserQuestion', 'EnterWorktree', 'ExitWorktree', 'TodoWrite',
  'NotebookEdit', 'MultiEdit', 'WebFetch', 'WebSearch']) {
  const hits = findMatches(identifierRule, ['Use `' + name + '` here.']);
  assert.equal(hits.length, 1, name);
  assert.equal(hits[0].match, '`' + name + '`');
}
for (const name of ['Write', 'Read', 'Edit', 'Bash', 'Glob', 'Grep', 'Task', 'Agent']) {
  assert.deepEqual(findMatches(rule, ['Use `' + name + '` here.']), [], name);
  for (const phrase of [name + ' tool', '`' + name + ' tool`', '`' + name + '` tool']) {
    assert.equal(findMatches(rule, ['Use ' + phrase + ' here.']).length, 1, phrase);
  }
}
for (const text of [
  'Run the script with `bash`.',
  'Authorize `read` on the identity.',
  'Offer `Save`, `Edit`, or `Skip` as choices.',
]) assert.deepEqual(findMatches(rule, [text]), [], text);
assert.equal(findMatches(rule, ['Use `Write tool`.']).length, 1);
assert.ok(findMatches(rule, ['Call `AskUserQuestion`.']).length > 0);
assert.deepEqual(findMatches(rule, [
  'write the file; read `tmp/x.json`; edit the file; a task; Task; agent',
  'Run `bin/agent.sh` and use the loom-executor agent.',
]), []);
NODE
)"; RC=$?
[ "$RC" -eq 0 ] \
  && pass "harness vocabulary: unambiguous identifiers and tool phrases match; capabilities, labels, and script paths do not" \
  || fail "harness vocabulary: raw identifier or negative cases failed" "$OUT"
OUT="$(printf 'Call AskUserQuestion.\n' | pc check --surface external - 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ! grep -q 'harness-tool-names' <<< "$OUT" \
  && pass "harness vocabulary: scoped to harness text" \
  || fail "harness vocabulary: leaked into external text" "$OUT"

# ============================================================
# 5. Preprocessing exemptions and the opening position
# ============================================================
cat > "$TMP/clean.md" <<'EOF'
---
title: delve into synergy
---
# Heading

The checker strips code, quotes, and links before it reads.

```
leverage the synergy! delve deep
```

> "Ship it!" said the reviewer, thrilled to share it.

Run `git status` and compare `!=` in the diff. <!-- circle back! -->
See [the guide](https://example.com/delve!) for details.
![banner!](banner.png)
What if the question comes later in the document?
EOF
OUT="$(pc check --surface memory "$TMP/clean.md" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'prose-check: 0 block, 0 warn' <<< "$OUT" \
  && pass "preprocess: frontmatter, headings, fences, blockquotes, inline code, comments, link targets, images exempt" \
  || fail "preprocess: false positives" "$OUT"

printf 'What if your team never lost context again?\n\nMore text.\n' > "$TMP/opener.md"
OPEN="$(pc check --surface external "$TMP/opener.md" 2>&1)"; grep -q 'rhetorical-opener' <<< "$OPEN" \
  && pass "opening: rhetorical-opener fires on the first paragraph" \
  || fail "opening: rhetorical-opener missed the opening"
printf '# Title\n\nThe fact comes first.\n\nWhat if the question comes later?\n' > "$TMP/later.md"
LATER="$(pc check --surface external "$TMP/later.md" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ! grep -q 'rhetorical-opener' <<< "$LATER" \
  && pass "opening: a later question is untouched (exit 0)" \
  || fail "opening: rhetorical-opener fired past the first paragraph or exit $RC" "$LATER"

# Preprocessing state must not swallow violations that follow exempt spans.
cat > "$TMP/state.md" <<'EOF2'
The opener token is `<!--` and this line is prose.
We're excited to announce the thing after the code span.
EOF2
STATE="$(pc check --surface git "$TMP/state.md" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && grep -q 'state.md:2:.*passive-enthusiasm' <<< "$STATE" \
  && pass "preprocess: a backtick-quoted comment opener does not hide later lines" \
  || fail "preprocess: inline <!-- swallowed the rest of the document" "$STATE"

cat > "$TMP/fences.md" <<'EOF2'
````markdown
```
delve into synergy
```
````
Prose after the four-backtick block.

```
~~~ not a closer
delve again
```
Thrilled to share this after the real close.
EOF2
FENCES="$(pc check --surface git "$TMP/fences.md" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ! grep -q 'banned-vocabulary' <<< "$FENCES" && grep -q 'fences.md:12:.*passive-enthusiasm' <<< "$FENCES" \
  && pass "preprocess: nested and mixed fences close only on a matching fence" \
  || fail "preprocess: fence tracking wrong" "$FENCES"

# ============================================================
# 6. compose: the instruction face
# ============================================================
COMP="$(pc compose --surface harness 2>&1)"
grep -q '^## mannered-prose' <<< "$COMP" && pass "compose: harness includes mannered-prose" || fail "compose: mannered-prose missing" "$COMP"
grep -q '^## process-narration' <<< "$COMP" && fail "compose: git-only rule leaked into harness" || pass "compose: process-narration excluded from harness"
grep -q '^Fix: ' <<< "$COMP" && grep -q '^Fails: ' <<< "$COMP" && pass "compose: each rule prints body, examples, and fix" || fail "compose: shape wrong" "$COMP"
JUDG="$(pc compose --surface git --tier judgment | grep -c '^## ')"
[ "$JUDG" -ge 3 ] && pass "compose: --tier judgment selects the judgment rules ($JUDG)" || fail "compose: judgment tier filter wrong ($JUDG)"

# ============================================================
# 7. Parity: the bedrock list and the banned-vocabulary rule agree
# ============================================================
BEDROCK=".claude/rules/voice-bedrock.md"
for WORD in delve utilize synergy holistic streamline seamlessly effortlessly game-changer "deep dive" cutting-edge state-of-the-art "touch base" "circle back" empower; do
  grep -qi -- "$WORD" "$BEDROCK" || { fail "parity: '$WORD' missing from voice-bedrock"; continue; }
  HIT="$(printf 'we %s the plan\n' "$WORD" | pc check --surface external - 2>&1)"
  grep -q 'banned-vocabulary' <<< "$HIT" && pass "parity: '$WORD' is banned in bedrock and fires in the rule" || fail "parity: '$WORD' is in bedrock but the rule does not fire" "$HIT"
done
for PATTERN_RULE in rhetorical-opener passive-enthusiasm self-praise hedging-stack not-x-but-y announcing-instead-of-doing exclamation temporal-handwave filler-intensifiers; do
  [ -f "bin/prose-rules/$PATTERN_RULE.md" ] && pass "parity: bedrock pattern has a rule file ($PATTERN_RULE)" || fail "parity: no rule file for bedrock pattern $PATTERN_RULE"
done

# ============================================================
# 8. report: the advisory comment face
# ============================================================
printf 'validate input before parsing; the old order crashed on empty bodies\n' > "$TMP/commit-abc1234.md"
REPORT="$(pc report --surface git --meta pr=42 --meta sha=abc1234 "$TMP/dirty.md" "$TMP/commit-abc1234.md" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && pass "report: exits 0 even with block findings (advisory by construction)" || fail "report: exited $RC" "$REPORT"
grep -q '^<!-- prose-check -->$' <<< "${REPORT%%$'\n'*}" && pass "report: opens with the sticky-comment marker" || fail "report: marker missing" "$REPORT"
grep -q '^| dirty | 3 | `banned-vocabulary` | leverage the |' <<< "$REPORT" && pass "report: table row names input, line, rule, match" || fail "report: table row wrong" "$REPORT"
grep -q '^| commit-abc1234 |' <<< "$REPORT" && fail "report: clean input produced a row" "$REPORT" || pass "report: clean input produces no row"
DATA="$(printf '%s\n' "$REPORT" | grep -o '<!-- prose-check-data {.*} -->' | sed -e 's/^<!-- prose-check-data //' -e 's/ -->$//')"
printf '%s' "$DATA" | jq -e '.pr == "42" and .sha == "abc1234" and .inputs == 2 and .total > 0 and .findings["banned-vocabulary"] >= 2' >/dev/null 2>&1 \
  && pass "report: data block carries meta, input count, totals, and per-rule hits" \
  || fail "report: data block wrong" "$DATA"
CLEAN_REPORT="$(pc report --surface git "$TMP/commit-abc1234.md" 2>&1)"
grep -q '^✅ prose check: no findings' <<< "$CLEAN_REPORT" && grep -q '"total":0' <<< "$CLEAN_REPORT" \
  && pass "report: clean run prints the one-line receipt and a zero data block" \
  || fail "report: clean shape wrong" "$CLEAN_REPORT"

# ============================================================
# 9. tally: reads the data blocks back (offline mode)
# ============================================================
printf '%s\n' "$DATA" > "$TMP/records.jsonl"
printf '%s\n' "$CLEAN_REPORT" | grep -o '<!-- prose-check-data {.*} -->' | sed -e 's/^<!-- prose-check-data //' -e 's/ -->$//' >> "$TMP/records.jsonl"
TALLY="$(bash bin/prose-check-tally.sh --from "$TMP/records.jsonl" --json 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$TALLY" | jq -e '.prs_checked == 2 and .prs_clean == 1 and .by_rule["banned-vocabulary"].hits >= 2 and .by_rule["banned-vocabulary"].prs == 1' >/dev/null 2>&1 \
  && pass "tally: sums PRs checked, PRs clean, and hits per rule from data blocks" \
  || fail "tally: aggregation wrong (exit $RC)" "$TALLY"
TALLY_TEXT="$(bash bin/prose-check-tally.sh --from "$TMP/records.jsonl" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && grep -q '^  banned-vocabulary' <<< "$TALLY_TEXT" && pass "tally: text table lists rules" || fail "tally: text table missing"
: > "$TMP/empty.jsonl"
bash bin/prose-check-tally.sh --from "$TMP/empty.jsonl" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && pass "tally: no records is an explicit non-zero exit, never an empty success" || fail "tally: empty input exited $RC"

# ============================================================
# 10. QA boundaries: empty input, truncation, unreadable input, bad records
# ============================================================
: > "$TMP/empty-body.md"
EMPTY="$(pc report --surface git "$TMP/empty-body.md" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && grep -q '"inputs":1,"total":0' <<< "$EMPTY" \
  && pass "boundary: an empty PR body reports clean with exit 0" \
  || fail "boundary: empty body wrong (exit $RC)" "$EMPTY"

seq 1 45 | sed 's/.*/we delve into it/' > "$TMP/many.md"
MANY="$(pc report --surface git "$TMP/many.md" 2>&1)"
[ "$(printf '%s\n' "$MANY" | grep -c '^| many |')" -eq 40 ] && grep -q '^| … | | | and 5 more | |' <<< "$MANY" && grep -q '"total":45' <<< "$MANY" \
  && pass "boundary: the table truncates at 40 rows while the data block keeps the full count" \
  || fail "boundary: truncation wrong" "$(printf '%s\n' "$MANY" | tail -3)"

MISSING="$(pc report --surface git "$TMP/does-not-exist.md" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && grep -q '^prose-check: cannot read .*does-not-exist.md: ENOENT$' <<< "$MISSING" && ! grep -q 'node:fs' <<< "$MISSING" \
  && pass "failure: an unreadable input is a one-line error with exit 2, not a stack trace" \
  || fail "failure: unreadable input handling wrong (exit $RC)" "$MISSING"
pc check --surface git "$TMP/does-not-exist.md" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && pass "failure: check exits 2 on an unreadable input" || fail "failure: check exited $RC on unreadable input"

printf '%s\n' '{"pr":"9","inputs":1,"total":1,"blocks":1,"warns":0,"findings":{"exclamation":1}}' 'not json' '{"unrelated":true}' > "$TMP/bad.jsonl"
BAD="$(bash bin/prose-check-tally.sh --from "$TMP/bad.jsonl" --json 2>"$TMP/bad.err")"; RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$BAD" | jq -e '.prs_checked == 1 and .by_rule.exclamation.hits == 1' >/dev/null 2>&1 && grep -q 'skipped 2 malformed record' "$TMP/bad.err" \
  && pass "failure: tally skips malformed records with a warning and sums the rest" \
  || fail "failure: tally malformed handling wrong (exit $RC)" "$(cat "$TMP/bad.err")"

if bash bin/node-run.sh --test bin/tests/test-pr-metadata-workflow.mjs; then
  pass "workflow: strict format gate, advisory prose behavior, and manual readout"
else
  fail "workflow: metadata behavior or admission contract failed"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
