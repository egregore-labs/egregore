---
name: test
description: "Validate changes before /save — static analysis plus live Cypher validation against the graph, rendered as a pass/fail gate. Use for /test or 'test my changes'."
---

Validate changes before /save.

## When to invoke

User says: "/test", "test my changes", "run tests before I save", "validate this before /save"
Not this: broad end-to-end responsibility for shipping a change safely → `/qa`

Topic: $ARGUMENTS

## Execution rules

**Neo4j-first.** All queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl to Neo4j.
**CRITICAL: Suppress raw output.** Never show raw JSON to the user. All `bin/graph.sh` calls MUST capture output in a variable and only show formatted status lines.

- 1 Bash call: `bash bin/test-changes.sh` for static analysis
- 1 Bash call: `git config user.name`
- N Neo4j queries: live Cypher validation (one per extracted query block)
- Progress shown incrementally
- Gate verdict at the end

## Step 0: Identity + Scope

```bash
git config user.name
```

Derive handle: lowercase first word of git user.name (e.g. "Alice Smith" → "alice").

Determine scope:
- `$ARGUMENTS` contains file paths → scan those files
- `$ARGUMENTS` contains `--all` → scan all command and script files
- Empty → scan changed files vs develop

## Step 1: Static Analysis

Run the static analyzer:

```bash
bash bin/test-changes.sh [args]
```

Where `[args]` depends on scope detection from Step 0.

Capture output. Parse the JSON summary on the last line: `{"pass":N,"fail":N,"warn":N}`.

If the script reports no testable files:
> No testable changes found. Run `/test --all` to scan everything.

Then stop.

Display each check result using the script's output (it handles formatting with ✓/✗/⚠).

Track `static_fails` and `static_warns` from the JSON.

## Step 2: Extract Cypher Blocks from Changed Files

Get the list of changed `.md` files:

```bash
git diff origin/develop --name-only | grep '\.md$'
```

For each changed `.md` file, extract Cypher blocks — lines between ` ```cypher ` and ` ``` `. Collect:
- File name
- Block start line number
- The query text
- Any parameter references (`$me`, `$author`, `$topic`, etc.)

If no Cypher blocks found in changed files:
> No Cypher queries to validate.

Skip to Step 5.

## Step 3: Live Cypher Validation

For each extracted Cypher query:

### 3a: Substitute test parameters

Replace parameter references with real values:
- `$me` / `$author` → the actual user handle from Step 0
- `$topic` / `$artifactId` / `$questId` → `"test"`
- `$artifactTopics` / `$topics` / `$questIds` → `["test"]`
- `$ids` → `["test"]`
- `$year` → current year
- `$month` → current month
- `$day` → current day
- `$name` → the actual user handle

### 3b: Run via graph.sh

Execute each query with a 15-second timeout. Capture result and timing:

```bash
START_MS=$(ruby -e 'puts (Time.now.to_f * 1000).to_i' 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)
RESULT=$(timeout 15 bash bin/graph.sh query "$QUERY" "$PARAMS" 2>&1)
EXIT_CODE=$?
END_MS=$(ruby -e 'puts (Time.now.to_f * 1000).to_i' 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)
ELAPSED=$((END_MS - START_MS))
```

### 3c: Validate result

For each query, check:
1. **Exit code** — 0 is pass, non-zero is fail
2. **Error strings** — check for Neo4j error messages (`"errors"`, `"Neo.ClientError"`, `"Type mismatch"`)
3. **Valid JSON** — result should be parseable JSON
4. **Timeout** — if command timed out (exit 124), report as warning

Track per-query: file, query number, status (pass/fail/warn), elapsed ms.

### 3d: Date type check (for date-involving queries)

If the query involves `date()` or `datetime()` on session/artifact fields, run a supplementary check:

```bash
bash bin/graph.sh query "MATCH (s:Session) WHERE s.date IS NOT NULL RETURN DISTINCT 'type' AS key, apoc.meta.cypher.type(s.date) AS type LIMIT 5" 2>/dev/null
```

If this returns mixed types (both STRING and some temporal type), add context to the output:
> ⚠ Mixed date types in Session.date — toString() guard required

## Step 4: Graph connectivity check

Before running live queries, verify graph is reachable:

```bash
bash bin/graph.sh test 2>/dev/null
```

If graph is offline:
> Graph offline — skipping live Cypher validation. Static analysis only.

Skip Steps 3 and proceed to Step 5 with static results only.

## Step 5: Render TUI Result Box

72-char width. Sigil: `✧ TEST`.

### Boundary handling (CRITICAL)

**No sub-boxes. No inner `┌─┐`/`└─┘` borders.** Sub-boxes break because the model can't count character widths precisely enough.

Only **4 line patterns** exist:

1. **Top**: `┌` + 70×`─` + `┐` (72 chars)
2. **Separator**: `├` + 70×`─` + `┤` (72 chars)
3. **Content**: `│` + 2 spaces + text + pad spaces to 68 chars + `│` (72 chars)
4. **Bottom**: `└` + 70×`─` + `┘` (72 chars)

### Layout

```
┌──────────────────────────────────────────────────────────────────────┐
│  ✧ TEST                                            oz · Feb 17       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  STATIC ANALYSIS                                                     │
│    ✓ No unguarded date() calls                                       │
│    ✓ No .year/.month/.day on mixed-type fields                       │
│    ✓ macOS-compatible bash                                           │
│    ⚠ Missing LIMIT on quest-suggest.md:137                           │
│                                                                      │
│  LIVE QUERIES (2 files, 8 queries)                                   │
│    deep-reflect.md                                                   │
│      ✓ Q1: Recent sessions                         42ms              │
│      ✓ Q4: Knowledge gaps                          65ms              │
│      ✓ Q7: Knowledge landscape                     38ms              │
│    save.md                                                           │
│      ✓ Type backfill                                31ms             │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ 11 passed · 0 failed · 1 warning                                 │
│  Safe to /save.                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### TUI rules

- Header: `✧ TEST` left, `author · Mon DD` right
- `├───┤` separator between header and content
- **STATIC ANALYSIS** section: one line per check from `bin/test-changes.sh`
  - `✓` for pass, `✗` for fail, `⚠` for warn
  - Include file:line for failures and warnings
- **LIVE QUERIES** section (only if Cypher blocks were found and graph is online):
  - Header: `LIVE QUERIES (N files, N queries)`
  - Group by file name
  - Each query: `✓`/`✗`/`⚠` + short description + elapsed ms right-aligned
- `├───┤` separator before verdict
- **Verdict line**: `✓ N passed · N failed · N warnings` (total across static + live)
- **Gate**: `Safe to /save.` or `Fix N failure(s) before /save.`
- **No sub-boxes** — only outer frame `│` borders and `├────┤` separators

### Verdict logic

- **Safe to /save**: 0 failures (static or live)
- **Fix before /save**: any failures
- Warnings alone don't block — note them but allow save

### No changes variant

```
┌──────────────────────────────────────────────────────────────────────┐
│  ✧ TEST                                            oz · Feb 17       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  No testable changes found.                                          │
│  Run /test --all to scan everything.                                 │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### Graph offline variant

```
┌──────────────────────────────────────────────────────────────────────┐
│  ✧ TEST                                            oz · Feb 17       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  STATIC ANALYSIS                                                     │
│    ✓ No unguarded date() calls                                       │
│    ✓ macOS-compatible bash                                           │
│                                                                      │
│  LIVE QUERIES                                                        │
│    Graph offline — skipped                                           │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ 8 passed · 0 failed · 0 warnings (static only)                   │
│  Safe to /save.                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

## Execution order

The actual execution order is:

1. Step 0 — identity + scope
2. Step 1 — static analysis (always runs first)
3. Step 4 — graph connectivity check
4. Step 2 — extract Cypher blocks
5. Step 3 — live validation (if graph is online and blocks exist)
6. Step 5 — render TUI

Step 4 comes before Steps 2-3 to avoid unnecessary Cypher extraction when graph is offline.

## Edge cases

| Scenario | Handling |
|----------|----------|
| No changed files | "No testable changes" box |
| Graph offline | Static analysis only, note in TUI |
| Query timeout (15s) | Report as warning, not failure |
| All queries pass | "Safe to /save." |
| Static failures only | "Fix N failure(s) before /save." |
| Live failures only | "Fix N failure(s) before /save." |
| Mixed failures + warnings | Show all, gate on failures only |
| `--all` flag | Scan all .md and .sh files, extract all Cypher blocks |
| Specific files as args | Scan only those files |
| CREATE/MERGE queries | Skip live validation — only run read-only queries (MATCH...RETURN) |
| Queries with UNWIND $param | Substitute with test array |

## Query safety

**Only execute read-only queries live.** Skip any query that contains:
- `CREATE`
- `MERGE`
- `SET`
- `DELETE`
- `REMOVE`
- `DROP`

Report these as `⊘ Skipped (write query)` in the TUI.
