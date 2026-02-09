Manage quests — open-ended explorations that anyone can contribute to.

Arguments: $ARGUMENTS (Optional: quest name, or subcommand)

## Usage

- `/quest` — List active quests
- `/quest [name]` — Show quest details and linked artifacts
- `/quest new` — Create a new quest interactively
- `/quest contribute [name]` — Add a contribution entry
- `/quest prioritize [name] [high|medium|low|none]` — Set quest priority
- `/quest pause [name]` — Pause a quest
- `/quest complete [name]` — Complete with outcome

## Quest file location

All quests live in `memory/quests/[slug].md`

## Quest frontmatter

```yaml
---
title: Evaluation Benchmark for Dynamic Ontologies
slug: benchmark-eval
status: active | paused | completed
projects: [tristero]
started: 2026-01-26
started_by: Oz
priority: 0
completed: null
---
```

Priority values: `0` (none/default), `1` (low), `2` (medium), `3` (high). Used by `/activity` scoring.

## Neo4j Quest creation (via bin/graph.sh, on `/quest new`)

Run with `bash bin/graph.sh query "..." '{"param": "value"}'`

```cypher
MATCH (p:Person {name: $author})
CREATE (q:Quest {
  id: $slug,
  title: $title,
  status: 'active',
  started: date(),
  question: $question,
  filePath: $filePath,
  priority: 0
})
CREATE (q)-[:STARTED_BY]->(p)
WITH q
UNWIND $projects AS projName
MATCH (proj:Project {name: projName})
CREATE (q)-[:RELATES_TO]->(proj)
RETURN q.id
```

## Neo4j status update (via bin/graph.sh, on `/quest pause` or `/quest complete`)

```cypher
MATCH (q:Quest {id: $slug})
SET q.status = $status, q.completed = CASE WHEN $status = 'completed' THEN date() ELSE null END
RETURN q.id, q.status
```

## Neo4j priority update (via bin/graph.sh, on `/quest prioritize`)

Maps: high=3, medium=2, low=1, none=0.

```cypher
MATCH (q:Quest {id: $slug})
SET q.priority = $priority
RETURN q.id, q.priority
```

Also update the quest markdown file — add or replace `priority:` in frontmatter.

```
> /quest prioritize grants high

✓ grants priority set to high (3)
  Updated Neo4j and memory/quests/grants.md
```

## Example (list)

```
> /quest

Active Quests
─────────────

| Quest | Project | Artifacts | Contributors |
|-------|---------|-----------|--------------|
| benchmark-eval | tristero | 4 | Oz, Ali |
| research-agent | lace, tristero | 1 | Oz |

Paused: (none)

To see details: /quest benchmark-eval
To create: /quest new
```

## Example (show)

```
> /quest benchmark-eval

Quest: Evaluation Benchmark for Dynamic Ontologies
──────────────────────────────────────────────────

Status: active
Projects: tristero
Started: 2026-01-26 by Oz

The Question:
  What does it mean for a dynamic ontology to be "good"?
  How do we measure emergence, coherence, utility over time?

Threads:
  - [ ] Survey existing ontology evaluation methods
  - [ ] Define "dynamic" — what changes, how fast?
  - [x] Look at HELM for inspiration

Artifacts (4):
  → 2026-01-26 [source] HELM Framework Review
  → 2026-01-26 [thought] Temporal dimension in evaluation (Oz)
  → 2026-01-27 [source] Benchmarking LLM Reasoning
  → 2026-01-27 [finding] HELM adaptable with modifications (Ali)

Todos:
  □ cem: fix retry logic in graph.sh (2d ago)
  □ oz: investigate connection pooling (today)

Contributors: Oz, Ali

Entry points:
  - Read the HELM finding
  - Check tristero/benchmarks/ for prototype
```

## Example (new)

```
> /quest new

Creating a new quest...

What's the question or goal?
> Build a research agent that can autonomously explore topics

Short slug (lowercase, hyphens):
> research-agent

Which projects does this relate to?
  [x] tristero
  [x] lace
  [ ] infrastructure

✓ Created memory/quests/research-agent.md

Add initial threads? (or skip)
> - Survey existing research agent architectures
> - Define scope: what does "research" mean here?
> - Prototype with Claude tool use
> done

Recording in knowledge graph...
  ✓ Quest node created, linked to tristero + lace

✓ Quest created. Run /save to share.
```

## Notifications

When creating a quest that involves specific people, notify them:

**Detection**: "quest involving cem and oz" → notify both

**Notification API**:
```bash
bash bin/notify.sh send "cem" "message"
```

**Message format**:
```
Hey Cem, oz started a quest you're involved in: {title}

"{question}"
```

## Linked Todos (in detail view)

When showing quest details (`/quest [name]`), query linked todos:

```bash
bash bin/graph.sh query "MATCH (t:Todo {status: 'open'})-[:PART_OF]->(q:Quest {id: '$questSlug'}) MATCH (t)-[:BY]->(p:Person) RETURN t.text AS text, p.name AS by, t.created AS created ORDER BY t.created DESC"
```

Display after Threads section, before Artifacts:
```
Todos:
  □ cem: fix retry logic in graph.sh (2d ago)
  □ oz: investigate connection pooling (today)
```

Omit the Todos section entirely if no todos are linked to the quest.

## Next

Use `/add` to attach artifacts, `/save` to share.
