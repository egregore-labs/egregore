Deep research — ask a question, get a synthesis of what the org collectively knows.

Spawns an autonomous research agent that explores the knowledge graph through multi-hop traversal, returns prose synthesis including what the org doesn't know. Surfaces emergent insight that no single artifact contains but the graph collectively implies.

## When to invoke

User says: "what does the org know about", "deep dive on", "research across our knowledge", "connect the dots on", "what do we collectively know about", "synthesize what we know about"
Not this: quick insight capture → `/reflect` · private thought → `/note` · AI steering pattern → `/archive`

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## Depth modifiers

| Invocation | Budget hint |
|---|---|
| `/deep-reflect {query}` | ~12 actions (default) |
| `/deep-reflect brief {query}` | ~6 actions |
| `/deep-reflect deep {query}` | ~20 actions |

Parse: if first word is `brief` or `deep`, extract as depth modifier, rest is query. Otherwise full args = query.

## Execution rules

**Neo4j-first.** All queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl.
**CRITICAL: Suppress raw output.** Never show raw JSON to the user. Capture in variables, show formatted status lines only.

## Phase 1: Orientation (main thread)

### 1a. Identity

```bash
git config user.name
```

Derive handle: lowercase first word (e.g. "Cem Dagdelen" → "cem").

### 1b. Five parallel queries

Run ALL five in parallel. Capture results in variables — never display raw output.

**Q1 — Schema:**
```bash
bash bin/graph.sh schema
```

**Q2 — Topic landscape (top 30 by frequency):**
```cypher
MATCH (a:Artifact)
UNWIND a.topics AS topic
WITH topic, count(*) AS freq
RETURN topic, freq
ORDER BY freq DESC LIMIT 30
```

**Q3 — Entry points (artifacts matching query, limit 20):**
```cypher
MATCH (a:Artifact)
WHERE toLower(a.title) CONTAINS toLower($query)
   OR ANY(t IN a.topics WHERE toLower(t) CONTAINS toLower($query))
OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(p:Person)
RETURN a.id AS id, a.title AS title, a.type AS type, a.topics AS topics, a.filePath AS filePath, p.name AS author
ORDER BY coalesce(a.created, datetime('2026-01-01')) DESC LIMIT 20
```
params: `{"query": "<the user's query>"}`

**Q4 — Neighborhood edges (for entry point artifacts):**
```cypher
MATCH (a:Artifact)
WHERE toLower(a.title) CONTAINS toLower($query)
   OR ANY(t IN a.topics WHERE toLower(t) CONTAINS toLower($query))
WITH a LIMIT 20
OPTIONAL MATCH (a)-[r:PART_OF]->(q:Quest)
OPTIONAL MATCH (a)-[r2:RELATES_TO]-(b:Artifact)
OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(p:Person)
RETURN a.id AS source_id, a.title AS source_title,
       collect(DISTINCT {type: 'quest', id: q.id, title: q.title}) AS quests,
       collect(DISTINCT {type: 'related', id: b.id, title: b.title}) AS related,
       collect(DISTINCT p.name) AS contributors
```
params: `{"query": "<the user's query>"}`

**Q5 — Temporal spread:**
```cypher
MATCH (a:Artifact)
WHERE toLower(a.title) CONTAINS toLower($query)
   OR ANY(t IN a.topics WHERE toLower(t) CONTAINS toLower($query))
WITH a ORDER BY coalesce(a.created, datetime('2026-01-01')) ASC
WITH collect(a.created) AS dates
RETURN head(dates) AS earliest, last(dates) AS latest, size(dates) AS count
```
params: `{"query": "<the user's query>"}`

**Q6 — Graph health (two queries via graph-batch, run alongside Q1-Q5):**
```json
[
  {"statement": "MATCH (a:Artifact) RETURN count(a) AS total, sum(CASE WHEN a.topics IS NULL OR size(a.topics) = 0 THEN 1 ELSE 0 END) AS no_topics, sum(CASE WHEN a.filePath IS NULL THEN 1 ELSE 0 END) AS ghosts"},
  {"statement": "MATCH (iso:Artifact) WHERE NOT (iso)-[:PART_OF]->(:Quest) AND NOT (iso)-[:RELATES_TO]-(:Artifact) RETURN count(iso) AS isolated"}
]
```

### 1c. Assemble orientation brief

Combine results into a structured text block for the research agent. Include:
- Schema summary (node labels, relationship types)
- Topic landscape (top 30 topics with frequencies)
- Entry point artifacts (id, title, type, topics, filePath, author)
- Neighborhood map (quests, related artifacts, contributors per entry point)
- Temporal spread (earliest, latest, count)
- Graph health: `{total} artifacts, {pct}% have topics, {pct}% connected to other artifacts/quests, {ghosts} ghost artifacts`
- The user's query

**Graph health computation:** From Q6 results, compute: `topic_pct = round((total - no_topics) / total * 100)`, `connected_pct = round((total - isolated) / total * 100)`. Density label: connected >= 70% → "dense", >= 40% → "moderate", < 40% → "sparse".

Show brief progress to user: `Orienting... {N} entry points found across {date range}.`

## Phase 2: Research Agent (spawned Opus Task)

Spawn a single Task: `subagent_type: "general-purpose"`, `model: "opus"`, inline (not background).

The agent receives the full orientation brief and these behavioral instructions:

---

**RESEARCH AGENT PROMPT** (include verbatim in the Task prompt):

```
You are a research agent for an organization's knowledge graph. Your job: autonomously explore the graph to answer a question, then write an opinionated prose synthesis of what the org collectively knows — including what it doesn't know.

## Your question

{query}

## Your tools

- `bash bin/graph.sh query "CYPHER" '{"param":"value"}'` — run Cypher queries against Neo4j
- `bash bin/graph.sh schema` — see graph schema
- Read tool — read artifact files from memory/ paths
- Grep tool — full-text search across memory/

## Orientation (pre-gathered)

{orientation_brief}

## Graph health

This graph contains {total} artifacts. {topic_pct}% have topic tags, {connected_pct}% are connected to at least one other artifact or quest. {ghosts} artifacts have no file on disk. Calibrate accordingly — this is a {density_label} graph.

## How to research

You have two modes of action: **exploration** (querying graph structure — edges, paths, contributor patterns, quest membership, temporal sequences) and **exploitation** (reading artifact content deeply). Alternate between them based on returns. When reading artifacts keeps confirming what you already know, explore the graph for new structural connections. When you find a structurally interesting region, exploit it by reading the artifacts there.

**Exploration-exploitation as explicit choice.** At each step, decide: do I explore (query the graph for new connections, follow edges to unseen regions, check who else contributed to related work, look at temporal patterns) or exploit (read deeper into artifacts I've already found, follow their content)? When your recent actions have been producing diminishing returns on a thread, switch from exploitation to exploration. When you discover a structurally promising new region, switch from exploration to exploitation. The ratio emerges from the data — a well-connected dense subgraph might legitimately be 80% exploitation; a sparse or fragmented topic might be 80% exploration.

**Read before concluding.** When an artifact looks relevant, READ IT (use the Read tool with its filePath). Titles and topics are hints, not evidence. Your synthesis must be grounded in what artifacts actually say, not what their titles suggest.

**Multi-hop traversal.** Don't stop at direct matches. Follow edges: if artifact A relates to quest Q, what other artifacts are in Q? If person P contributed to A, what else did P write? If topic T appears in A, what other artifacts share T? The most valuable findings are often 2-3 hops from the query.

**Bridge node awareness.** Actively look for bridge nodes — artifacts, people, or topics that connect otherwise separate clusters in the graph. An artifact that's PART_OF two different quests, a person who's CONTRIBUTED_BY on artifacts in unrelated topic clusters, a topic that appears in otherwise disconnected artifact groups. Bridge nodes are where the most interesting cross-pollination lives. When you find one, name it as a bridge and explain what it connects.

**Insufficiency mapping.** When the graph is sparse on a topic, that IS a finding, not a failure. Report: what little is known, where evidence thins, what adjacent work exists, which people/quests are nearest, what artifacts should exist but don't. Insufficiency mapping is among the most valuable outputs.

**Self-termination.** Periodically ask yourself: can I already answer this question with what I have? If yes, further exploration is enrichment — valuable, but not infinite. Don't spend to budget if strong synthesis is found early. Continue past budget hint if still finding productive threads.

## Analytical tone

Your synthesis should be opinionated but not adversarial. These principles govern how you write:

- **Positive patterns matter as much as tensions.** Convergence, reinforcement, and crystallization are high-value signals — don't bury them under manufactured friction. If an evolution arc is going well (e.g., a thesis strengthening across artifacts), name it as a primary finding.
- **Be neutrally observant first, opinionated second.** Describe what the graph shows before judging it. Don't assume the org is avoiding something or making mistakes.
- **Never adopt an adversarial or patronizing tone.** You are an analyst, not a critic. "The graph shows X" is better than "The team is failing to Y." Frame observations as what you see, not what the reader should feel bad about.

The test: the reader should feel like the analysis noticed something useful — a pattern they hadn't named, a convergence worth celebrating, or a genuine gap worth addressing. If the synthesis reads like a performance review or a therapy session, rewrite it.

## Budget hint

~{budget} actions. This is a soft ceiling, not a turn limit. You decide when research has converged.

## Output format

When you're done researching, write your output in this exact format:

First, YAML frontmatter (MUST be present and machine-parseable):

---
type: research
query: "{the question}"
date: {YYYY-MM-DD}
researcher: "{member}"
artifacts_consulted: [list of artifact IDs you read during research]
artifacts_cited: [list of artifact IDs you reference in your synthesis]
open_loops: [unresolved threads you didn't finish exploring — free-form strings]
topics: [topics this research touches]
quests: [quest IDs this research relates to]
---

Then your synthesis as opinionated prose. Show your evidence — cite specific artifacts by title and relevant content. Note what's missing from the graph. Note what you didn't finish exploring. Include a condensed trail of your research path so the reader can see how you got there.

Write freely. Whatever structure best communicates what you found. The only hard requirement is the YAML frontmatter above.
```

---

## Phase 3: Presentation (main thread)

### 3a. Parse agent output

Extract YAML frontmatter (between `---` markers) and prose body. Parse YAML to get `artifacts_consulted`, `artifacts_cited`, `open_loops`, `topics`, `quests`.

### 3b. Show synthesis

Display the prose synthesis to the user. After it, show a collapsed trail line:

```
Research trail: {N} artifacts consulted, {M} cited
```

If `open_loops` is non-empty:
```
Open threads: {comma-separated list}
```

### 3c. Save confirmation

```
AskUserQuestion:
  question: "Save this research?"
  header: "Save"
  options:
    - label: "Save"
      description: "Write artifact, graph it, push"
    - label: "Edit first"
      description: "Modify before saving"
    - label: "Skip"
      description: "Discard without saving"
```

If "Skip" → stop. If "Edit first" → let user describe edits, apply them, then proceed.

### 3d. Write artifact file

Slug: lowercase query, hyphens, no special chars, max 50 chars.
Path: `memory/knowledge/research/{YYYY-MM-DD}-{slug}.md`

Check if file exists → append 4-char random hex if collision.

Write using Bash (memory is outside project via symlink):

```bash
mkdir -p memory/knowledge/research
cat > "memory/knowledge/research/{YYYY-MM-DD}-{slug}.md" << 'RESEARCHEOF'
{full agent output — YAML frontmatter + prose body}
RESEARCHEOF
```

Progress: `[1/3] ✓ Writing knowledge/research/{date}-{slug}.md`

### 3e. Create graph nodes and edges

**Create Artifact node + CONTRIBUTED_BY:**

With quest links:
```cypher
MATCH (p:Person {name: $author})
CREATE (a:Artifact {
  id: $artifactId,
  title: $title,
  type: 'research',
  topics: $topics,
  filePath: $filePath,
  created: datetime(),
  analysis: 'deep-reflect'
})
CREATE (a)-[:CONTRIBUTED_BY]->(p)
WITH a
UNWIND $questIds AS qId
MATCH (q:Quest {id: qId})
CREATE (a)-[:PART_OF]->(q)
RETURN a.id
```

Without quest links:
```cypher
MATCH (p:Person {name: $author})
CREATE (a:Artifact {
  id: $artifactId,
  title: $title,
  type: 'research',
  topics: $topics,
  filePath: $filePath,
  created: datetime(),
  analysis: 'deep-reflect'
})
CREATE (a)-[:CONTRIBUTED_BY]->(p)
RETURN a.id
```

**Create RELATES_TO edges** for cited artifacts (context: 'research'):
```cypher
MATCH (a:Artifact {id: $artifactId}), (b:Artifact {id: $citedId})
CREATE (a)-[:RELATES_TO {
  context: 'research',
  updated: datetime()
}]->(b)
```

Run edge queries in parallel.

Progress: `[2/3] ✓ Indexed in knowledge graph ({N} edges)`

### 3f. Auto-save

Delegate to `/save` flow.

Progress: `[3/3] ✓ Auto-saved`

### 3g. TUI confirmation

72-char width. Sigil: `◎ DEEP RESEARCH`. Only 4 line patterns (top/separator/content/bottom).

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◎ DEEP RESEARCH                                    cem · Mar 07    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  "{query}" (truncate at 55 chars)                                    │
│  {N} artifacts consulted · {M} cited                                 │
│  {open_loops count} open threads                                     │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

## Telemetry

After execution, fire-and-forget:
```bash
bash bin/telemetry.sh emit "command" '{"command":"deep-reflect"}' 2>/dev/null &
```

## Fallbacks

| Condition | Action |
|---|---|
| Neo4j unavailable | Error: "Graph offline — can't run deep research." Stop. |
| No entry points found | Agent still runs — insufficiency mapping IS valuable output |
| Memory symlink missing | Error: "Run /setup first." Stop. |
| Empty query | "What do you want to research?" and wait for input |
| File collision | Append 4-char hex to slug |
| Agent returns no YAML | Wrap output in minimal frontmatter, proceed |
