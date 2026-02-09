Ingest an artifact with minimal friction. The system suggests relations.

Arguments: $ARGUMENTS (Optional: URL to fetch, or leave empty for interactive mode)

## Usage

- `/add` — Interactive mode, prompts for content
- `/add [url]` — Fetch and ingest external source

## What to do

1. If URL provided, fetch and extract content
2. Ask for or infer content type
3. Suggest relevant quests based on content
4. Suggest topics
5. Create artifact file with proper frontmatter
6. Create Artifact node in Neo4j via `bash bin/graph.sh query "..."` (never MCP)
7. Confirm relations created

## Artifact types

- `source` — External content (papers, articles, docs)
- `thought` — Original thinking, hypotheses, intuitions
- `finding` — Discoveries, what worked or didn't
- `decision` — Choices made with rationale

## File naming

- Thoughts: `YYYY-MM-DD-[author]-[short-title].md`
- Sources: `YYYY-MM-DD-[short-title]-source.md`

All artifacts go in `memory/artifacts/`

## Frontmatter format

```yaml
---
title: HELM Framework Review
type: source | thought | finding | decision
author: Oz (or "external" for sources)
origin: https://... (for external sources)
date: 2026-01-26
quests: [benchmark-eval, research-agent]
topics: [evaluation, benchmarks, llm]
---

[Content here]
```

## Neo4j Artifact creation (via bin/graph.sh)

Run with `bash bin/graph.sh query "..." '{"param": "value"}'`

```cypher
MATCH (p:Person {name: $author})
CREATE (a:Artifact {
  id: $artifactId,
  title: $title,
  type: $type,
  created: date(),
  filePath: $filePath,
  origin: $origin,
  topics: $topics
})
CREATE (a)-[:CONTRIBUTED_BY]->(p)
WITH a
UNWIND $quests AS questId
MATCH (q:Quest {id: questId})
CREATE (a)-[:PART_OF]->(q)
RETURN a.id
```

Where:
- `$artifactId` = filename without extension (e.g., `2026-01-26-oz-temporal-thought`)
- `$type` = source | thought | finding | decision
- `$origin` = URL for external sources, null for thoughts
- `$topics` = array of topic strings from frontmatter (e.g., `["evaluation", "benchmarks", "llm"]`)

## Example (external source)

```
> /add https://arxiv.org/abs/2311.04934

Fetching...

This looks like: "Benchmarking LLM Reasoning"
Type: source (external)

I see relevance to:
  → Quest: benchmark-eval (high)
  → Quest: research-agent (medium)
  → Topics: [evaluation, reasoning, llm]

[x] benchmark-eval
[ ] research-agent
[ ] No quest (general research)

Confirm? (y / edit tags / n)
> y

✓ memory/artifacts/2026-01-26-benchmarking-llm-reasoning.md
✓ Artifact node created in knowledge graph
✓ Linked: benchmark-eval → tristero

To see the graph: /quest benchmark-eval
```

## Example (thought)

```
> /add

What do you have?
> I'm thinking that dynamic ontologies need a temporal dimension
> in their evaluation - not just "is this good" but "how does
> goodness change as the ontology evolves"

Type: thought
Author: Oz (from git config)

Relevant quests:
  → benchmark-eval (this extends the core question)

Topics: [evaluation, temporality, dynamic-ontologies]

✓ memory/artifacts/2026-01-26-oz-temporal-evaluation-thought.md
✓ Artifact node created, linked to oz
✓ Linked to quest: benchmark-eval
```

## Next

Run `/save` to share, or `/quest [name]` to see the graph.
