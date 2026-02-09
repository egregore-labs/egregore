Analyze quest drift and suggest restructuring. Runs sensemaking dialogue — always, no cooldown.

Arguments: $ARGUMENTS

## Usage

- `/quest suggest` — Analyze orphaned artifacts, stale quests, and emerging themes

This is the explicit entry point for quest sensemaking. Unlike the automatic check at `/activity` time (which runs once daily with cooldown), this always runs. `/activity` shows an orphan count hint pointing here.

## What to do

1. Run all 3 drift metrics queries in parallel via `bash bin/graph.sh query "..."`
2. Analyze the results against trigger thresholds
3. Compose a sensemaking observation with 2-3 natural language questions
4. Present options via AskUserQuestion
5. Act on user response
6. Update SensemakingCheck node

## Drift metrics — 3 parallel queries

**DM1 — Orphan ratio + topic clusters:**

```cypher
MATCH (a:Artifact) WHERE a.created >= date() - duration('P14D')
WITH count(a) AS totalRecent
MATCH (orphan:Artifact)
WHERE orphan.created >= date() - duration('P14D')
  AND NOT (orphan)-[:PART_OF]->(:Quest)
WITH totalRecent, collect(orphan) AS orphans, count(orphan) AS orphanCount
WITH totalRecent, orphanCount, orphans,
     CASE WHEN totalRecent > 0
       THEN toFloat(orphanCount) / toFloat(totalRecent)
       ELSE 0.0 END AS orphanRatio
UNWIND orphans AS o
UNWIND o.topics AS topic
WITH orphanRatio, orphanCount, totalRecent, topic, count(DISTINCT o) AS topicCount
ORDER BY topicCount DESC
RETURN orphanRatio, orphanCount, totalRecent,
       collect({topic: topic, count: topicCount})[..5] AS topClusters
```

**DM2 — Stale high-priority quests:**

```cypher
MATCH (q:Quest {status: 'active'})
WHERE q.priority >= 2
OPTIONAL MATCH (a:Artifact)-[:PART_OF]->(q)
WITH q, CASE WHEN count(a) > 0
  THEN duration.inDays(max(a.created), date()).days
  ELSE duration.inDays(q.started, date()).days END AS daysSince
WHERE daysSince >= 10
RETURN q.id AS quest, q.priority AS priority, daysSince
```

**DM3 — Quest topic coverage:**

```cypher
MATCH (q:Quest {status: 'active'})
WHERE q.topics IS NOT NULL
RETURN q.id AS quest, q.topics AS topics
```

## Trigger thresholds

Any of these means drift is detected:

| Condition | Threshold |
|-----------|-----------|
| Orphan ratio | > 40% of artifacts in last 14d have no quest |
| Stale priority | A quest with priority >= 2 has zero artifacts in 10+ days |
| Topic gap | 3+ orphaned artifacts share a topic not covered by any quest |

**If no thresholds are crossed**, say:

> Quest structure looks good. N artifacts in the last 14 days, M% linked to quests. No stale priorities detected.

And skip to updating SensemakingCheck.

## Sensemaking dialogue

When drift is detected, compose a structured observation. Use the metrics to generate 2-3 natural language questions.

Available data:
- orphanCount / totalRecent / orphanRatio
- topClusters: [{topic, count}] — what orphaned artifacts cluster around
- staleQuests: [{quest, priority, daysSince}] — declared-important but idle
- questTopicSets: [{quest, topics}] — what topics existing quests cover

Example output:

```
⚑ Quest check-in

I'm noticing 8 of your last 12 artifacts aren't connected to
any quest. Active quests focus on [grants, reliability, launch]
but recent work clusters around [architecture, pricing, onboarding].

A few questions:
1. Has your focus shifted? Should we create new quests for
   architecture or pricing?
2. Are some of these part of existing quests that just didn't
   get linked? (I can link them now)
3. The grants quest is high-priority but hasn't had activity
   in 12 days — still active?
```

Then use AskUserQuestion with options derived from the analysis:
- "Create new quests for [top cluster topics]"
- "Link orphaned artifacts to existing quests"
- "Pause/reprioritize stale quests" (only if stale quests detected)
- "Skip — structure is fine"

## Acting on responses

### "Create new quests"

Run `/quest new` flow with pre-filled title and slug from the top cluster topics. For each topic cluster the user confirms, create a quest.

### "Link orphaned artifacts to existing quests"

Run the topic overlap query to find best matches. Uses a frequency filter to exclude high-frequency topics (appearing in >30% of all artifacts):

```cypher
MATCH (all:Artifact) WHERE all.topics IS NOT NULL
WITH count(all) AS totalArtifacts
MATCH (all:Artifact) WHERE all.topics IS NOT NULL
UNWIND all.topics AS t
WITH totalArtifacts, t, count(DISTINCT all) AS freq
WHERE toFloat(freq) / toFloat(totalArtifacts) <= 0.3
WITH collect(t) AS discriminatingTopics

MATCH (a:Artifact)
WHERE NOT (a)-[:PART_OF]->(:Quest)
  AND a.topics IS NOT NULL
WITH a, discriminatingTopics,
     [t IN a.topics WHERE t IN discriminatingTopics] AS filteredTopics
MATCH (q:Quest {status: 'active'})
WHERE q.topics IS NOT NULL
WITH a, q, [t IN filteredTopics WHERE t IN q.topics] AS shared
WHERE size(shared) >= 2
RETURN a.id AS artifact, a.title AS artifactTitle,
       q.id AS quest, q.title AS questTitle,
       shared AS sharedTopics, size(shared) AS overlap
ORDER BY overlap DESC
```

Present as:
```
I'd link these — look right?

  "Go-to-Market Strategy" → egregore-reliability (3 shared: pricing, moat, go-to-market)
  "German Funding" → grants (2 shared: funding, nlnet)
```

User confirms → batch-create PART_OF relationships:

```cypher
MATCH (a:Artifact {id: $artifactId}), (q:Quest {id: $questId})
CREATE (a)-[:PART_OF]->(q)
```

Also update the artifact's markdown frontmatter — add the quest to the `quests:` list.

### "Pause/reprioritize stale quests"

For each stale quest listed, ask what to do:
- Pause → run `MATCH (q:Quest {id: $slug}) SET q.status = 'paused'`
- Deprioritize → run `MATCH (q:Quest {id: $slug}) SET q.priority = 0`
- Keep → no action

### "Skip — structure is fine"

Set skippedUntil on cooldown node:

```cypher
MERGE (sc:SensemakingCheck)
SET sc.lastRun = date(), sc.skippedUntil = date() + duration('P7D')
```

## Update SensemakingCheck (always, after any response)

```cypher
MERGE (sc:SensemakingCheck)
SET sc.lastRun = date()
```

## Rules

- All Neo4j queries via `bash bin/graph.sh query "..."` — never MCP, never direct curl
- Run DM1, DM2, DM3 in parallel (3 separate Bash calls)
- This command always runs — it does NOT check cooldown (explicit user request)
- After acting, always update SensemakingCheck.lastRun
