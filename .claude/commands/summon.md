# /summon — Design and Launch a Persistent Agent Process

Summon a spirit — a persistent agent that runs on a schedule or watches for conditions. Unlike `/loop` (dumb scheduler), `/summon` designs the process through adaptive questioning, produces a reviewable spec, then launches it.

## When to invoke

**Trigger phrases**: "summon", "create a loop", "set up a recurring", "watch for", "monitor", "keep an eye on", "babysit", "run something every", "I want an agent that"

**Not this command**:
- Quick one-shot schedule → `/loop` directly (user already knows what they want)
- One-time task → just do it, no spirit needed

## Instructions

### Phase 1: Intent Discovery

Start with one open question via AskUserQuestion:

```
What should this spirit do?
```

Options should be derived from current graph context — not hardcoded. Before asking, run a lightweight graph scan to understand what's happening:

```bash
# Get active quests, recent sessions, health signals
CONTEXT=$(bash bin/graph-batch.sh '[
  {"statement": "MATCH (q:Quest) WHERE q.status IN [\"active\", \"in-progress\"] RETURN q.id, q.title LIMIT 10", "parameters": {}},
  {"statement": "MATCH (s:Session)-[:BY]->(p:Person) RETURN s.topic, p.name, toString(s.date) AS date ORDER BY s.date DESC LIMIT 5", "parameters": {}},
  {"statement": "MATCH (s:Spirit) RETURN s.name, s.type, s.status LIMIT 10", "parameters": {}}
]')
```

Use this context to generate options that are relevant — e.g. if there are dormant quests, offer "reconcile dormant work"; if there's a PR-heavy period, offer "watch PRs". Always include a free-text option.

The agent has full discretion to decide what graph context is relevant given the user's stated intent. Do not follow a fixed query set. Pull whatever slice of the graph illuminates the design space.

### Phase 2: Adaptive Convergence

Ask questions iteratively. Each round is informed by previous answers AND graph context. The questioning is non-linear — the agent decides what to ask based on where the interesting tension is, not a fixed script.

**Dimensions to explore** (not necessarily in order — the agent picks what matters):

- **Scope**: What exactly does the spirit observe? What can it act on? What's off-limits?
- **Cadence**: How often? Time-driven (cron) or condition-driven (watchdog)? Or both?
- **Boundaries**: What should it never do? What requires human approval vs auto-action?
- **Reporting**: What does the user want to see? Metrics? Narrative? Diffs? Alerts only?
- **Failure modes**: What happens when the spirit finds something it can't handle?
- **Evolution**: Should the spirit's behavior change as it learns? How?

**Convergence signal**: When the user's answers start narrowing to specifics (concrete conditions, specific quests, named thresholds), propose the spec. Don't ask more than 6 rounds unless the user is actively expanding scope.

**For watchdog spirits** (event-driven):
- Define the condition to watch for (as a Cypher query or graph pattern)
- Define the action on trigger (notify, auto-fix, flag, escalate)
- Cadence is polling interval (cron-based for now, hookable later)

### Phase 3: Spec Generation

Produce a spirit spec as JSON. Write to `.spirits/{name}.json`:

```json
{
  "name": "graph-gardener",
  "type": "recurring",
  "purpose": "Maintain knowledge graph health — fix structural issues, infer new relationships, report drift",
  "cadence": "0 3 * * *",
  "cadence_human": "Daily at 3:03 AM",
  "scope": {
    "reads": ["Quest", "Artifact", "Session", "Person"],
    "writes": ["Artifact", "Quest"],
    "relationships": ["PART_OF", "RELATES_TO", "BUILDS_ON"],
    "off_limits": ["Person deletion", "Quest deletion"]
  },
  "actions": {
    "auto": ["resolve stale handoffs", "migrate date types", "mark dormant quests", "link artifacts by topic"],
    "suggest": ["merge duplicate persons", "link disconnected artifacts"],
    "flag": ["ghost artifacts", "orphaned sessions"]
  },
  "reporting": {
    "tui": true,
    "graph_artifact": true,
    "notify": false
  },
  "watchdog": null,
  "created_by": "cem",
  "created_at": "2026-03-09T10:00:00Z",
  "version": 1
}
```

For watchdog spirits, the `watchdog` field contains:

```json
{
  "condition": "MATCH (s:Session) WHERE s.date > date() - duration('P1D') AND s.handoffStatus = 'pending' RETURN count(s) > 3",
  "action": "notify",
  "message_template": "{{count}} handoffs piling up — someone should triage"
}
```

### Phase 4: Review

Present the spec as a TUI box:

```
┌ Spirit: graph-gardener ───────────────────────────┐
│                                                    │
│  Purpose:  Maintain knowledge graph health         │
│  Type:     Recurring                               │
│  Cadence:  Daily at 3:03 AM                        │
│                                                    │
│  Auto-fix: stale handoffs, date types,             │
│            dormant quests, topic links              │
│  Suggest:  duplicate persons, disconnected arts     │
│  Flag:     ghosts, orphans                         │
│                                                    │
│  Reporting: TUI + Graph artifact each cycle        │
│  Boundaries: No person/quest deletion              │
│                                                    │
└────────────────────────────────────────────────────┘
```

Ask: "Launch this spirit?" with options: Launch, Edit (back to questioning), Cancel.

### Phase 5: Launch

1. **Write spec file**: `.spirits/{name}.json`
2. **Create Spirit node in graph**:
   ```bash
   bash bin/graph.sh query "
     MERGE (sp:Spirit {name: \$name})
     SET sp.type = \$type, sp.purpose = \$purpose, sp.cadence = \$cadence,
         sp.status = 'active', sp.createdAt = datetime(), sp.createdBy = \$author,
         sp.version = 1
     RETURN sp.name
   " '{"name":"...","type":"...","purpose":"...","cadence":"...","author":"..."}'
   ```
3. **Schedule via CronCreate**:
   - Prompt is the spirit's execution prompt (constructed from spec)
   - For recurring: standard cron
   - For watchdog: polling cron + condition check prefix
4. **Confirm**: Show job ID, how to cancel, 3-day auto-expiry note.

### Phase 6: Cycle Reporting (attached to each execution)

When a spirit runs (via `/loop` invoking its prompt), each cycle MUST:

1. **Run the work** defined in the spec
2. **Produce TUI report**:
   ```
   ┌ graph-gardener · Cycle 4 · 2026-03-09 ─────────┐
   │                                                   │
   │  ✦ Fixed: 3 stale handoffs resolved              │
   │  ✦ Fixed: 12 date types migrated                 │
   │  ◇ Inferred: 8 new RELATES_TO edges              │
   │  ⚠ Flagged: 2 ghost artifacts                    │
   │                                                   │
   │  Health: 412 nodes · 891 edges · 1.2% orphan     │
   │  Delta:  +15 edges since last cycle               │
   │  Drift:  dormant quest count stable (26)          │
   │                                                   │
   │  Insight: "3 artifacts about 'governance' appeared│
   │  this week but aren't linked to any quest —       │
   │  emerging theme?"                                 │
   │                                                   │
   └───────────────────────────────────────────────────┘
   ```

3. **Write LoopReport to graph**:
   ```bash
   bash bin/graph.sh query "
     MATCH (sp:Spirit {name: \$name})
     CREATE (lr:Artifact {
       id: \$id, type: 'loop-report', title: \$title,
       created: date(), origin: 'spirit',
       metrics: \$metrics
     })
     CREATE (lr)-[:GENERATED_BY]->(sp)
     RETURN lr.id
   " '{"name":"...","id":"...","title":"...","metrics":"..."}'
   ```

4. **Insights**: The report should include one model-generated insight per cycle — a pattern, question, or observation that emerges from the data but wasn't explicitly programmed. This is the inferential layer growing.

### Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"summon"}' 2>/dev/null &
```

## Managing Spirits

- **List active**: `bash bin/graph.sh query "MATCH (sp:Spirit {status: 'active'}) RETURN sp.name, sp.type, sp.cadence"`
- **Suspend**: Set `sp.status = 'suspended'` + CronDelete
- **Resume**: Set `sp.status = 'active'` + CronCreate
- **View history**: `MATCH (lr:Artifact {origin: 'spirit'})-[:GENERATED_BY]->(sp:Spirit {name: $name}) RETURN lr ORDER BY lr.created DESC`

## Design Principles

1. **Bitter lesson**: The agent decides what context is relevant, not a fixed query set. More compute, less hand-engineering.
2. **Adaptive convergence**: Questions stop when the spec is clear, not after N rounds.
3. **Specs are forkable**: `.spirits/` is git-tracked. Fork the egregore, inherit its spirits.
4. **Spirits compound**: Each cycle's LoopReport feeds future cycles. The spirit gets smarter about what to surface.
5. **Watchdogs are deferred hooks**: Poll-on-cron now, proper event-driven hooks when infrastructure exists.
