Capture insights from your work. The system uses graph context to surface what's worth reflecting on, asks Socratic follow-ups, and auto-classifies what emerges.

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## Three Modes

| Invocation | Mode | AskUserQuestion calls |
|---|---|---|
| `/reflect` | **Deep** — full Socratic flow | 2-3 |
| `/reflect [content]` | **Quick** — rapid capture, auto-classify | 0-1 |
| `/reflect about [topic]` | **Focused** — deep but pre-seeded | 1-2 |

**Mode detection:**
- No arguments → Deep mode
- Arguments start with `about ` → Focused mode (topic = everything after "about ")
- Arguments match `[category]: [content]` (decision/finding/pattern prefix) → Quick mode with category override
- Any other arguments → Quick mode

## Execution rules

**Neo4j-first.** All queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl to Neo4j.

- 1 Bash call: `git config user.name`
- 5-6 Neo4j queries for context gathering (run in parallel)
- 0-3 AskUserQuestion calls depending on mode
- 1-3 Neo4j queries for Artifact creation + relation detection
- Auto-save via `/save` flow
- Progress shown incrementally

## Step 0: Identity + Context (parallel, all modes)

### Get current user

```bash
git config user.name
```

Map to Person node: "Oguzhan Yayla" -> oz, "Cem Dagdelen" -> cem, "Ali" -> ali

### Context queries (run ALL in parallel)

Execute each with `bash bin/graph.sh query "..." '{"param": "value"}'`.

**Q1 — Recent sessions (7 days):**
```cypher
MATCH (s:Session)-[:BY]->(p:Person {name: $me})
WHERE s.date >= date() - duration('P7D')
RETURN s.topic AS topic, s.date AS date, s.summary AS summary
ORDER BY s.date DESC LIMIT 5
```

**Q2 — Active quests I'm involved in:**
```cypher
MATCH (q:Quest {status: 'active'})
OPTIONAL MATCH (a:Artifact)-[:PART_OF]->(q)
OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(p:Person {name: $me})
WITH q, count(DISTINCT a) AS myArtifacts
RETURN q.id AS quest, q.title AS title, myArtifacts
ORDER BY myArtifacts DESC
```

**Q3 — Recent artifacts by me (14 days):**
```cypher
MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person {name: $me})
WHERE a.created >= datetime() - duration('P14D')
OPTIONAL MATCH (a)-[:PART_OF]->(q:Quest)
RETURN a.title AS title, a.type AS type, a.topics AS topics, a.created AS created, q.id AS quest
ORDER BY a.created DESC LIMIT 10
```

**Q4 — Knowledge gaps (sessions without corresponding artifacts):**
```cypher
MATCH (s:Session)-[:BY]->(p:Person {name: $me})
WHERE s.date >= date() - duration('P14D')
OPTIONAL MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p)
WHERE a.created >= datetime({year: s.date.year, month: s.date.month, day: s.date.day})
  AND a.created < datetime({year: s.date.year, month: s.date.month, day: s.date.day}) + duration('P1D')
WITH s, count(a) AS artifactCount
WHERE artifactCount = 0
RETURN s.topic AS topic, s.date AS date
ORDER BY s.date DESC
```

**Q5 — Recent decisions (30 days):**
```cypher
MATCH (a:Artifact {type: 'decision'})
WHERE a.created >= datetime() - duration('P30D')
RETURN a.title AS title, a.topics AS topics, a.filePath AS path
ORDER BY a.created DESC LIMIT 10
```

**Q6 — Topic deep-dive (Focused mode only):**
Only run this when mode is Focused. Query everything the graph knows about the given topic:
```cypher
MATCH (a:Artifact)
WHERE a.title CONTAINS $topic OR $topic IN a.topics
OPTIONAL MATCH (a)-[:PART_OF]->(q:Quest)
OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(p:Person)
RETURN a.title AS title, a.type AS type, a.topics AS topics, a.created AS created, q.id AS quest, p.name AS author
ORDER BY a.created DESC LIMIT 10
```

If Neo4j is unavailable, skip context gathering and proceed to Quick mode behavior (auto-classify with no context).

## Step 1: Context-Aware Opening (Deep + Focused modes only)

Synthesize query results into 1-3 sentences demonstrating graph awareness, then ask an opening question via AskUserQuestion.

### Opportunity detection

Analyze Q1-Q5 results (and Q6 for Focused mode) to identify which opportunity type to surface. Check in this priority order:

| Opportunity | Signal | Example opening |
|---|---|---|
| **Knowledge gap** | Q4 returns sessions without artifacts | "You had a session on MCP auth 3 days ago but nothing was captured. Did anything come out of that?" |
| **Pattern emergence** | Q3 shows 3+ artifacts sharing topics | "Three recent artifacts touch [pricing, positioning, defensibility]. What ties these together?" |
| **Decision tension** | Q5 shows decisions with overlapping topics | "The business model decision says X, but the go-to-market decision implies Y. Has your thinking evolved?" |
| **Quest momentum** | Q2 shows quest with lots of recent artifacts | "You've added 4 artifacts to the grants quest this week. What's crystallizing?" |
| **Fresh territory** | Q1 shows session topic not in any quest/artifact | "Your session on 'game engine multiagent' doesn't connect to anything else. New direction?" |

If no clear opportunity, fall back to a general opening based on the most recent session.

### AskUserQuestion options

Options must be drawn from **actual graph data** — specific session topics, quest names, artifact themes. Never generic options like "A decision" or "Something I learned".

Example (knowledge gap detected):
```
question: "You had a session on MCP auth 3 days ago but nothing was captured. What came out of it?"
header: "Reflect on"
options:
  - label: "MCP auth session"
    description: "Capture what came out of the Feb 06 session"
  - label: "Pricing evolution"
    description: "3 recent artifacts touch pricing — tie them together"
  - label: "Something else"
    description: "Reflect on a different topic"
```

**Skip to Step 2** with the user's response.

**Quick mode**: Skip Step 1 entirely. The user's content IS the reflection.

## Step 2: Deepening (Deep + Focused modes only)

Based on Step 1 response, generate 1-2 follow-up questions that dig deeper. Style depends on what the user focused on:

| User focused on | Follow-up style |
|---|---|
| A session | "What was the key takeaway? What changed your thinking?" |
| A decision tension | "Which framing is more accurate now? What resolved it?" |
| A pattern | "Is this prescriptive (do this) or descriptive (this happens)?" |
| A quest | "What's the next move? What's still unclear?" |
| Fresh territory | "Is this a new quest or a one-off exploration?" |

Use AskUserQuestion with options drawn from the user's response + graph context.

**Max 3 total AskUserQuestion rounds** (Step 1 + Step 2 combined). Skip to Step 3 if:
- User's response is already rich (>50 characters of freeform text)
- User selected "Something else" and provided detailed text
- 3 rounds already used

## Step 3: Auto-Classification

Determine artifact type(s) from the conversation. **The user never picks a category.**

### Classification signals (priority order)

1. **Category override**: If arguments matched `[category]: [content]`, use that category directly
2. **Language cues**: "we decided" / "the choice is" → decision. "I found" / "turns out" / "discovered" → finding. "I keep seeing" / "every time" / "the pattern is" → pattern
3. **Structural cues**: Binary choice with rationale → decision. Before/after comparison → finding. Generalization from examples → pattern
4. **Graph context**: Topic matches existing findings → finding. Recurring theme across sessions → pattern. New territory → thought (classify as finding)

**Default**: When ambiguous, classify as **finding** (least prescriptive). Never ask the user to classify.

### Multi-artifact detection

One reflection can produce up to 3 artifacts. Look for:
- A decision AND the underlying finding that supports it
- A pattern AND a specific finding that exemplifies it
- Multiple distinct insights in one response

### Extract from content

For each artifact, extract:
- **Title** — short descriptive title (for filename and Neo4j)
- **Content** — the insight itself
- **Context** — what led to it (auto-populate from session context if not explicit)
- **Rationale** — why it matters
- **Topics** — 2-4 topic tags derived from content + graph context

### Present proposal

Show proposed artifacts as plain text (NOT AskUserQuestion):

```
Based on what you've shared:

  1. Decision: "Gate by usage patterns, not Claude tier"
     → pricing-strategy quest

  2. Pattern: "Agents as individual PMF"
     → individual-tier · egregore-reliability

Adjust? (y/edit/skip)
```

Wait for user response:
- **y** or empty → proceed with all artifacts
- **edit** → user modifies, then proceed
- **skip** → abort without saving

## Step 4: Relation Detection

For each artifact, run targeted Cypher queries in parallel to find:

**Quest links (topic overlap):**
```cypher
MATCH (q:Quest {status: 'active'})
WHERE q.topics IS NOT NULL
WITH q, [t IN q.topics WHERE t IN $artifactTopics] AS shared
WHERE size(shared) >= 1
RETURN q.id AS quest, q.title AS title, shared AS sharedTopics
ORDER BY size(shared) DESC LIMIT 3
```

**Related artifacts (shared topics):**
```cypher
MATCH (a:Artifact)
WHERE a.topics IS NOT NULL AND a.id <> $artifactId
WITH a, [t IN a.topics WHERE t IN $artifactTopics] AS shared
WHERE size(shared) >= 2
RETURN a.id AS artifact, a.title AS title, a.type AS type, shared AS sharedTopics
ORDER BY size(shared) DESC LIMIT 3
```

Present relation suggestions alongside Step 3's proposal. If no relations found, skip silently.

## Step 5: Create files

For each artifact, generate slug from title: lowercase, hyphens, no special chars, max 50 chars.

File path: `memory/knowledge/{category}s/{YYYY-MM-DD}-{slug}.md`

Note: directories are `decisions/`, `findings/`, `patterns/` (plural).

Write each file using Bash (memory is outside project, avoids permission issues):

```bash
cat > "memory/knowledge/{category}s/{YYYY-MM-DD}-{slug}.md" << 'REFLECTEOF'
# {Title}

**Date**: {YYYY-MM-DD}
**Author**: {author}
**Category**: {category}
**Topics**: {topic1}, {topic2}, {topic3}

## Context

{Context — what led to this}

## Content

{The decision/finding/pattern itself}

## Rationale

{Why this matters}

## Related

- Quest: {quest-id}
- Artifact: {artifact-id}
REFLECTEOF
```

Omit the Related section if no links. Omit Topics line if none derived.

Show progress:
```
  [1/3] ✓ Writing knowledge/{category}s/{date}-{slug}.md
```

## Step 6: Neo4j Artifact creation

For each artifact, run via `bash bin/graph.sh query "..." '{"param": "value"}'`:

**With quest links:**
```cypher
MATCH (p:Person {name: $author})
CREATE (a:Artifact {
  id: $artifactId,
  title: $title,
  type: $category,
  topics: $topics,
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
  type: $category,
  topics: $topics,
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
- `$artifactId` = `{YYYY-MM-DD}-{slug}` (matches filename without extension)
- `$author` = short name (oz, cem, ali)
- `$category` = decision | finding | pattern
- `$topics` = array of topic strings
- `$filePath` = `knowledge/{category}s/{YYYY-MM-DD}-{slug}.md`
- `$questIds` = array of linked quest IDs (empty array if none)

Show progress:
```
  [2/3] ✓ Indexed in knowledge graph
```

## Step 7: Auto-save

Run the full `/save` flow:

1. Commit changes in memory repo and push (contribution branch + PR + auto-merge)
2. Commit any egregore changes and push working branch + PR to develop

This is the same flow as `/save`. Follow its logic exactly.

Show progress:
```
  [3/3] ✓ Auto-saved
```

## Step 8: Confirmation TUI

Display the confirmation box. ~72 char width. Sigil: `◎ REFLECTION`.

### Boundary handling (CRITICAL)

**No sub-boxes. No inner `┌─┐`/`└─┘` borders.** Sub-boxes break because the model can't count character widths precisely enough.

Only **4 line patterns** exist:

1. **Top**: `┌` + 70×`─` + `┐` (72 chars)
2. **Separator**: `├` + 70×`─` + `┤` (72 chars)
3. **Content**: `│` + 2 spaces + text + pad spaces to 68 chars + `│` (72 chars)
4. **Bottom**: `└` + 70×`─` + `┘` (72 chars)

The separator lines are ALWAYS identical — copy-paste the same 72-char string. Content lines have ONLY the outer frame `│` as borders. Pad every content line with trailing spaces so the closing `│` is at position 72.

### Multi-artifact confirmation:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◎ REFLECTION                                        cem · Feb 08   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  2 insights captured:                                                │
│                                                                      │
│  ◉ Decision: Gate by usage patterns, not Claude tier                 │
│    → pricing-strategy                                                │
│                                                                      │
│  ◉ Pattern: Agents as individual PMF                                 │
│    → individual-tier · egregore-reliability                          │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### Single artifact confirmation:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◎ REFLECTION                                        cem · Feb 08   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ Finding: Neo4j HTTP API faster than Bolt for small...             │
│    → benchmark-eval                                                  │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### TUI rules

- Header row: sigil + command name left, author + date right
- `├───┤` separator between header and content
- For multi-artifact: "N insights captured:" header line
- `◉` for each artifact with Type: Title
- `→` for linked quests (indented under each artifact)
- `├───┤` separator before status footer
- Status line: `✓ Saved · graphed · pushed`
- Footer: "Visible in /activity."
- Truncate artifact titles at 45 chars with `...` if needed
- **No sub-boxes** — only outer frame `│` borders and `├────┤` separators

## Quick Mode Flow

When arguments are provided (not starting with "about "):

1. **Step 0**: Run identity + 2 parallel Neo4j queries (Q2 for quests, Q5 for recent decisions) — lighter context
2. **Auto-classify**: Apply classification signals to the provided content. If arguments match `[category]: [content]`, use category override
3. **Step 4**: Run relation detection queries
4. **Present proposal**: Same format as Step 3 — show proposed artifact(s) with `y/edit/skip`
5. **If genuinely ambiguous** (equal signals for 2+ categories): 1 AskUserQuestion max
6. **Steps 5-8**: Create file, Neo4j, auto-save, TUI — identical to deep mode

Quick mode should complete with 0-1 AskUserQuestion calls total.

## Backwards Compatibility

- `/reflect decision: use stdio for MCP` still works — category prefix = classification override
- `/reflect finding: ...` and `/reflect pattern: ...` also work
- File locations unchanged: `memory/knowledge/{type}s/`
- Neo4j schema unchanged: Artifact nodes, same properties + relationships
- Auto-save flow unchanged

## Edge cases

| Scenario | Handling |
|----------|----------|
| Neo4j unavailable | Skip context gathering and relation linking. Still create file. Show warning: "Graph offline — file saved, will sync on next /save" |
| No quests/projects | Skip relation step silently |
| All context queries empty | Fall back to: "What's on your mind? I'll capture it." (simple prompt, no graph-aware opening) |
| Quick mode, genuinely ambiguous | Ask 1 clarifying AskUserQuestion max |
| User says "skip" at any prompt | Save what you have so far, or abort if nothing captured yet |
| Empty content | Don't create anything, tell user "Nothing to reflect on yet" |
| File already exists at path | Append timestamp to slug to avoid collision |
| Memory symlink missing | Error: "Run /setup first — memory not linked" |
| User says "edit" at proposal | Let them modify titles, categories, or quest links in freeform text, then re-parse |

## Full interactive example (Deep mode)

```
> /reflect

You had a session on individual tier strategy 2 days ago but nothing
was captured. And three recent artifacts touch pricing, positioning,
and defensibility — there might be a pattern forming.

What's on your mind?
  1. Individual tier session — capture what came out of it
  2. Pricing/positioning pattern — what ties recent work together
  3. Something else

> 2

Three artifacts touch this: the pricing doc, the competitive analysis,
and the defensibility framework. What's the thread?

> The real insight is that agents ARE the individual PMF. We don't need
> dashboards or analytics for individuals — the Claude Code agent with
> graph access is the product. And we should gate by usage patterns,
> not by which Claude tier someone has.

Based on what you've shared:

  1. Decision: "Gate by usage patterns, not Claude tier"
     → pricing-strategy

  2. Pattern: "Agents as individual PMF"
     → individual-tier · egregore-reliability

Adjust? (y/edit/skip)
> y

Creating reflection...

  [1/3] ✓ Writing knowledge/decisions/2026-02-08-gate-by-usage-patterns.md
        ✓ Writing knowledge/patterns/2026-02-08-agents-as-individual-pmf.md
  [2/3] ✓ Indexed in knowledge graph
  [3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ◎ REFLECTION                                        cem · Feb 08   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  2 insights captured:                                                │
│                                                                      │
│  ◉ Decision: Gate by usage patterns, not Claude tier                 │
│    → pricing-strategy                                                │
│                                                                      │
│  ◉ Pattern: Agents as individual PMF                                 │
│    → individual-tier · egregore-reliability                          │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

## Quick mode example

```
> /reflect Neo4j HTTP API is faster than Bolt for small queries

  ◉ Finding: "Neo4j HTTP API faster than Bolt for small queries"
    → benchmark-eval

Adjust? (y/edit/skip)
> y

Creating reflection...

  [1/3] ✓ Writing knowledge/findings/2026-02-08-neo4j-http-api-faster...
  [2/3] ✓ Indexed in knowledge graph
  [3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ◎ REFLECTION                                        cem · Feb 08   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ Finding: Neo4j HTTP API faster than Bolt for small...             │
│    → benchmark-eval                                                  │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

## Quick mode with category override

```
> /reflect decision: use stdio for MCP

  ◉ Decision: "Use stdio for MCP"

Adjust? (y/edit/skip)
> y

Creating reflection...

  [1/3] ✓ Writing knowledge/decisions/2026-02-08-use-stdio-for-mcp.md
  [2/3] ✓ Indexed in knowledge graph
  [3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ◎ REFLECTION                                        cem · Feb 08   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ Decision: Use stdio for MCP                                       │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

## Focused mode example

```
> /reflect about pricing

Here's what the graph knows about pricing:

  ◉ Decision: Five-tier pricing model (Feb 07)
  ◉ Decision: $9/mo annual for individual tier (Feb 08)
  ◉ Finding: Competitive analysis — Obsidian/Notion gaps (Feb 08)
  → pricing-strategy quest (3 artifacts)

Has your thinking on pricing evolved since these?

  1. Pricing model has changed — update needed
  2. New competitive insight to capture
  3. Something else about pricing

> 1

What shifted? The tier structure, the price points, or the gating logic?

> The gating logic. We realized we should gate by usage patterns,
> not by Claude tier. Heavy graph users get prompted to upgrade
> regardless of whether they're on Claude Free or Pro.

Based on what you've shared:

  1. Decision: "Gate by usage patterns, not Claude tier"
     → pricing-strategy
     ↔ relates to: 2026-02-08-individual-tier-pricing

Adjust? (y/edit/skip)
> y

...
```
