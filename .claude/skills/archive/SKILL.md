---
name: archive
description: "Capture an effective prompting technique or steering pattern as reusable knowledge. Use for /archive, or when a prompt worked especially well and is worth reusing — not insight about the work itself (/reflect)."
---

Capture effective prompt patterns and store them as reusable knowledge.

Sequences of human steering interventions that produced good AI reasoning — stored in the shared knowledge base as reusable patterns.

## When to invoke

User says: "that prompt worked well", "save this prompting technique", "archive this steering pattern", "the way I phrased that got great results"
Not this: insight about the work itself → `/reflect` · private thought → `/note`

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## Two Modes

| Invocation | Mode | AskUserQuestion calls |
|---|---|---|
| `/archive` | **Interactive** — model reads session context, extracts prompt chains | 1-2 |
| `/archive [description]` | **Quick** — user provides the pattern directly | 0-1 |

**Mode detection:**
- No arguments → Interactive mode
- Any arguments → Quick mode

## Mode detection

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

**Local mode** (`mode === "local"`): Skip ALL `bin/graph.sh` calls — do NOT run them. Do NOT show any graph-related messaging ("Graph offline", "will sync", Neo4j, etc.).

Local-mode flow:
- **Step 0**: Get user via `git config user.name`. Skip ALL context queries (Q1-Q4) — do not run them.
- **Step 1**: Extract moves from session context only (no graph-aware suggestions).
- **Step 3**: Skip relation detection entirely — do not run quest/artifact queries.
- **Step 4**: Create pattern file — same as connected mode.
- **Step 5**: Skip entirely — no Neo4j Artifact creation.
- **Step 6**: Auto-save — same as connected mode.
- **Step 7**: TUI — use `✓ Saved · pushed` (not "graphed"). Use `/activity to see it.` as footer.

**Connected mode**: Full behavior as specified below.

## Execution rules

**Neo4j-first.** All queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl to Neo4j.
**CRITICAL: Suppress raw output.** Never show raw JSON to the user. All `bin/graph.sh` calls MUST capture output in a variable and only show formatted status lines.

- 1 Bash call: `git config user.name`
- 4 Neo4j queries for context gathering (run in parallel) — **connected mode only**
- 0-2 AskUserQuestion calls depending on mode
- 1-2 Neo4j queries for Artifact creation + relation detection — **connected mode only**
- Auto-save via `/save` flow
- Progress shown incrementally

## Step 0: Identity + Context (parallel, all modes)

### Get current user

```bash
git config user.name
```

Map to Person node: "Alice Smith" -> alice, "Bob Jones" -> bob, "Carol" -> carol

### Context queries (run ALL in parallel) — CONNECTED MODE ONLY

**Skip this entire section in local mode.** Do not run any of these queries.

Execute each with `bash bin/graph.sh query "..." '{"param": "value"}'`.

**Q1 — Recent sessions (7 days):**
```cypher
MATCH (s:Session)-[:BY]->(p:Person {name: $me})
WHERE date(left(toString(s.date), 10)) >= date() - duration('P7D')
RETURN s.topic AS topic, s.date AS date, s.summary AS summary
ORDER BY s.date DESC LIMIT 5
```

**Q2 — Existing prompt-chain patterns (all time):**
```cypher
MATCH (a:Artifact {type: 'pattern'})
WHERE 'prompt-chain' IN a.topics
RETURN a.id AS id, a.title AS title, a.topics AS topics, a.created AS created
ORDER BY a.created DESC LIMIT 10
```

**Q3 — Active quests:**
```cypher
MATCH (q:Quest {status: 'active'})
RETURN q.id AS quest, q.title AS title, q.topics AS topics
ORDER BY q.title
```

**Q4 — Recent artifacts by me (14 days):**
```cypher
MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person {name: $me})
WHERE a.created >= datetime() - duration('P14D')
OPTIONAL MATCH (a)-[:PART_OF]->(q:Quest)
RETURN a.title AS title, a.type AS type, a.topics AS topics, a.created AS created, q.id AS quest
ORDER BY a.created DESC LIMIT 10
```

If Neo4j is unavailable, skip context gathering and proceed with whatever the model can extract from session context alone.

## Step 1: Move Extraction

### Interactive mode

Scan the conversation for steering interventions — moments where the human redirected the AI's reasoning trajectory. Each move has:

- **type**: Open taxonomy. Initial vocabulary: inversion, calibration, scoping, elevation, reframing, grounding, sequencing, contradiction, analogy, provocation. Name new types when existing ones don't fit. The taxonomy emerges from usage.
- **trigger**: What the model was doing wrong
- **effect**: How behavior changed
- **principle**: Distilled heuristic ("When X, do Y")

Present via AskUserQuestion:

```
question: "I found a {N}-move chain: {chain name}. Looks right?"
header: "Archive"
options:
  - label: "Yes, archive it"
    description: "Save this {N}-move chain to the knowledge base"
  - label: "Different pattern"
    description: "I want to archive a different pattern from this session"
  - label: "Describe manually"
    description: "I'll describe the pattern to archive"
```

- **"Yes, archive it"** → proceed to Step 2
- **"Different pattern"** → re-scan conversation with user's guidance, present again
- **"Describe manually"** → switch to Quick mode flow with user's description

**Session too short (<4 turns):** Switch to Quick mode with AskUserQuestion:

```
question: "Session is short — describe a pattern to archive?"
header: "Archive"
options:
  - label: "Describe a pattern"
    description: "I'll describe the prompt pattern to capture"
  - label: "Skip"
    description: "Nothing to archive right now"
```

### Quick mode

Parse `$ARGUMENTS` into chain name + moves. Single principle → 1-move chain. Multi-line or comma-separated → multi-move chain.

Extract move types, triggers, effects, and principles from the description. If the description is terse (just a principle), create a single-move chain with the principle as-is.

## Step 2: Chain Refinement (Interactive mode, 3+ moves only)

For chains with 3 or more moves, show the full breakdown as plain text (NOT AskUserQuestion):

```
Chain: {chain-name}

  1. [{move_type}] {summary}
     Trigger: ...
     Effect: ...

  2. [{move_type}] {summary}
     Trigger: ...
     Effect: ...

  ...

Outcome: {what the chain produced}

Adjust? (y/edit/skip)
```

Wait for user response:
- **y** or empty → proceed
- **edit** → user modifies, then proceed
- **skip** → abort without saving

For chains with 1-2 moves, skip this step — go straight to Step 3.

## Step 3: Relation Detection — CONNECTED MODE ONLY

**Skip this entire step in local mode.** Do not run any relation queries.

Run targeted Cypher queries in parallel to find links:

**Quest links (topic overlap):**
```cypher
MATCH (q:Quest {status: 'active'})
WHERE q.topics IS NOT NULL
WITH q, [t IN q.topics WHERE t IN $artifactTopics] AS shared
WHERE size(shared) >= 1
RETURN q.id AS quest, q.title AS title, shared AS sharedTopics
ORDER BY size(shared) DESC LIMIT 3
```

**Related patterns (shared topics):**
```cypher
MATCH (a:Artifact)
WHERE a.topics IS NOT NULL AND a.id <> $artifactId
WITH a, [t IN a.topics WHERE t IN $artifactTopics] AS shared
WHERE size(shared) >= 2
RETURN a.id AS artifact, a.title AS title, a.type AS type, shared AS sharedTopics
ORDER BY size(shared) DESC LIMIT 3
```

**Similar prompt-chain patterns:**
```cypher
MATCH (a:Artifact {type: 'pattern'})
WHERE 'prompt-chain' IN a.topics AND a.id <> $artifactId
RETURN a.id AS id, a.title AS title, a.moveTypes AS moveTypes
ORDER BY a.created DESC LIMIT 3
```

Present alongside the chain. If a similar pattern exists, ask via AskUserQuestion:

```
question: "A similar pattern exists: '{existing title}'. Update it or create new?"
header: "Duplicate?"
options:
  - label: "Create new"
    description: "Archive as a separate pattern"
  - label: "Update existing"
    description: "Replace the existing pattern with this version"
```

If no relations or similar patterns found, skip silently.

## Step 4: Create Pattern File

Generate slug from chain name: lowercase, hyphens, no special chars, max 50 chars.

Path: `memory/knowledge/patterns/YYYY-MM-DD-{slug}.md`

Write via Bash (memory is outside project):

```bash
cat > "memory/knowledge/patterns/YYYY-MM-DD-{slug}.md" << 'ARCHIVEEOF'
# {Chain Name}

**Date**: YYYY-MM-DD
**Author**: {author}
**Category**: pattern
**Subtype**: prompt-chain
**Topics**: {topic1}, {topic2}
**Move types**: {type1}, {type2}, ...

## When to Use

{1-3 sentences. When does this chain apply?}

## Chain

### Move 1: {Move Type} — {Short Title}

**Trigger**: {what model was doing wrong}
**Intervention**: {what the human said/did}
**Effect**: {how behavior changed}
**Principle**: {distilled heuristic}

### Move 2: {Move Type} — {Short Title}

**Trigger**: ...
**Intervention**: ...
**Effect**: ...
**Principle**: ...

## Outcome

{What the chain produced. 2-3 sentences.}

## Related

- Quest: {quest-id}
- Pattern: {related-pattern-id}
ARCHIVEEOF
```

Omit the Related section if no links. For single-move chains, the Chain section has just one move block.

Show progress:
```
  [1/3] ✓ Writing knowledge/patterns/{date}-{slug}.md
```

## Step 5: Neo4j Artifact Creation — CONNECTED MODE ONLY

**Skip this entire step in local mode.** Do not run any graph queries.

Run via `bash bin/graph.sh query "..." '{"param": "value"}'`:

**With quest links:**
```cypher
MATCH (p:Person {name: $author})
CREATE (a:Artifact {
  id: $artifactId,
  title: $title,
  type: 'pattern',
  topics: $topics,
  moveTypes: $moveTypes,
  filePath: $filePath,
  created: datetime()
})
CREATE (a)-[:CONTRIBUTED_BY]->(p)
WITH a
UNWIND $questIds AS qId
MATCH (q:Quest {id: qId})
CREATE (a)-[:PART_OF]->(q)
RETURN a.id
```

**Without quest links:**
```cypher
MATCH (p:Person {name: $author})
CREATE (a:Artifact {
  id: $artifactId,
  title: $title,
  type: 'pattern',
  topics: $topics,
  moveTypes: $moveTypes,
  filePath: $filePath,
  created: datetime()
})
CREATE (a)-[:CONTRIBUTED_BY]->(p)
RETURN a.id
```

**For related artifacts (RELATES_TO):**
```cypher
MATCH (a:Artifact {id: $artifactId}), (b:Artifact {id: $relatedId})
CREATE (a)-[:RELATES_TO]->(b)
```

Where:
- `$artifactId` = `YYYY-MM-DD-{slug}` (matches filename without extension)
- `$author` = short name (alice, bob, carol)
- `$topics` = array of topic strings, always includes `'prompt-chain'`
- `$moveTypes` = array of move type strings (e.g., `['inversion', 'calibration', 'scoping']`)
- `$filePath` = `knowledge/patterns/YYYY-MM-DD-{slug}.md`
- `$questIds` = array of linked quest IDs (empty array if none)

Show progress:
```
  [2/3] ✓ Indexed in knowledge graph
```

## Step 6: Auto-save

Run the full `/save` flow:

1. Commit changes in memory repo and push directly to main (pull-rebase-push with retry)
2. Commit any egregore changes and push working branch + PR to develop

This is the same flow as `/save`. Follow its logic exactly.

Show progress:
```
  [3/3] ✓ Auto-saved
```

## Step 7: Confirmation TUI

Display the confirmation box. ~72 char width. Sigil: `◇ ARCHIVE`.

### Boundary handling (CRITICAL)

**No sub-boxes. No inner `┌─┐`/`└─┘` borders.** Sub-boxes break because the model can't count character widths precisely enough.

Only **4 line patterns** exist:

1. **Top**: `┌` + 70×`─` + `┐` (72 chars)
2. **Separator**: `├` + 70×`─` + `┤` (72 chars)
3. **Content**: `│` + 2 spaces + text + pad spaces to 68 chars + `│` (72 chars)
4. **Bottom**: `└` + 70×`─` + `┘` (72 chars)

The separator lines are ALWAYS identical — copy-paste the same 72-char string. Content lines have ONLY the outer frame `│` as borders. Pad every content line with trailing spaces so the closing `│` is at position 72.

### Multi-move chain confirmation:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◇ ARCHIVE                                          bob · Feb 10    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ The Bitter Lesson Chain                                           │
│    5 moves: inversion → calibration → scoping → elevation →...      │
│                                                                      │
│    Outcome: Redesigned commands for tool provision over...           │
│    → egregore-reliability                                            │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  /activity to see it.                                                │
└──────────────────────────────────────────────────────────────────────┘
```

### Single-move pattern confirmation:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◇ ARCHIVE                                          bob · Feb 10    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ Flip the question to removal                                     │
│    1 move: inversion                                                 │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  /activity to see it.                                                │
└──────────────────────────────────────────────────────────────────────┘
```

### TUI rules

- Header row: `◇ ARCHIVE` left, `author · Mon DD` right
- `├───┤` separator between header and content
- `◉` for the pattern with chain name
- Move count + type sequence (truncate with `...` if >45 chars)
- Outcome line (only for 3+ move chains, truncated at 50 chars with `...`)
- `→` for linked quests (indented under the pattern)
- `├───┤` separator before status footer
- Status line: `✓ Saved · graphed · pushed`
- Footer: `/activity to see it.`
- **No sub-boxes** — only outer frame `│` borders and `├────┤` separators

## Quick Mode Flow

When arguments are provided:

1. **Step 0**: Run identity + 2 parallel Neo4j queries (Q2 for existing chains, Q3 for quests) — lighter context
2. **Parse**: Extract chain name and moves from `$ARGUMENTS`
3. **Step 3**: Run relation detection queries
4. **If similar pattern exists**: 1 AskUserQuestion max (update existing or create new?)
5. **Steps 4-7**: Create file, Neo4j, auto-save, TUI — identical to interactive mode

Quick mode should complete with 0-1 AskUserQuestion calls total.

## Move Type Vocabulary

These are starting vocabulary, not a fixed schema. Name new types when these don't fit.

| Type | Description |
|------|-------------|
| **inversion** | Flip the question — ask the opposite |
| **calibration** | Adjust scope, confidence, or precision |
| **scoping** | Narrow or expand the problem boundary |
| **elevation** | Move up one abstraction level |
| **reframing** | Change the lens entirely |
| **grounding** | Pull from abstract to concrete |
| **sequencing** | Reorder the approach |
| **contradiction** | Point out internal inconsistency |
| **analogy** | Import a pattern from another domain |
| **provocation** | Deliberately destabilize to find new ground |

## Edge cases

| Scenario | Handling |
|----------|----------|
| Neo4j unavailable (connected mode) | Create file, show "Graph offline — will sync on /save" |
| Local mode | Skip all graph calls silently — no warnings, no "graph offline" messaging. File creation + auto-save work normally. TUI shows `✓ Saved · pushed` |
| No chain found in session | Switch to Quick mode: "Describe a pattern to archive" |
| Session too short (<4 turns) | Suggest Quick mode |
| Similar pattern exists | AskUserQuestion: update existing or create new? |
| Memory symlink missing | Error: "Run /setup first — memory not linked" |
| User says "skip" | Abort without saving |
| Empty arguments in Quick mode | Switch to Interactive mode |
| File already exists at path | Append timestamp to slug to avoid collision |

## Integration

- `/activity` picks up archived patterns as `◉ Pattern: {name}` automatically (same Artifact type)
- `/reflect` could suggest `/archive` when it detects prompt pattern language
- `/save` sync already scans `memory/knowledge/patterns/`
- `/quest` links work via topic overlap, same as any artifact

## Full interactive example

```
> /archive

Scanning session...

I found a 5-move chain in this conversation:

  "The Bitter Lesson Chain" — a sequence of steering interventions
  that shifted the design from rule-following to tool provision.

  1. [inversion] Flip from "what rules" to "what tools"
  2. [calibration] Adjust confidence on rule-based approach
  3. [scoping] Narrow to the three commands that matter
  4. [elevation] Abstract to the bitter lesson principle
  5. [grounding] Concrete implementation in /save, /handoff, /reflect

Archive this chain?
  1. Yes, archive it
  2. Different pattern
  3. Describe manually

> 1

Chain: the-bitter-lesson

  1. [inversion] Flip from rules to tools
     Trigger: Model was following formatting rules instead of using tools
     Effect: Shifted focus to providing rich context via queries

  2. [calibration] Adjust confidence on rules
     Trigger: Over-reliance on prescriptive instructions
     Effect: Recognized rules as fragile, tools as robust

  3. [scoping] Narrow to three commands
     Trigger: Trying to fix all commands at once
     Effect: Focused on /save, /handoff, /reflect as proof points

  4. [elevation] Abstract to bitter lesson
     Trigger: Fixing symptoms, not root cause
     Effect: Named the general principle

  5. [grounding] Concrete implementation
     Trigger: Principle without action
     Effect: Redesigned commands with tool-first approach

Outcome: Redesigned three core commands to provision tools (Neo4j
queries, graph context) rather than follow formatting rules.

Adjust? (y/edit/skip)
> y

Creating archive...

  [1/3] ✓ Writing knowledge/patterns/2026-02-10-the-bitter-lesson.md
  [2/3] ✓ Indexed in knowledge graph
  [3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ◇ ARCHIVE                                          bob · Feb 10    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ The Bitter Lesson Chain                                           │
│    5 moves: inversion → calibration → scoping → elevation →...      │
│                                                                      │
│    Outcome: Redesigned commands for tool provision over...           │
│    → egregore-reliability                                            │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  /activity to see it.                                                │
└──────────────────────────────────────────────────────────────────────┘
```

## Quick mode example

```
> /archive flip the question to removal instead of addition

  ◉ Pattern: "Flip the question to removal"
    1 move: inversion
    → No quest links

Adjust? (y/edit/skip)
> y

Creating archive...

  [1/3] ✓ Writing knowledge/patterns/2026-02-10-flip-question-to-removal.md
  [2/3] ✓ Indexed in knowledge graph
  [3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ◇ ARCHIVE                                          bob · Feb 10    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ Flip the question to removal                                     │
│    1 move: inversion                                                 │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  /activity to see it.                                                │
└──────────────────────────────────────────────────────────────────────┘
```
