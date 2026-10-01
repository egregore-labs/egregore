---
name: summon
description: "Design and launch a persistent agent (a spirit) that runs on a schedule or watches for conditions, via adaptive questioning that produces a reviewable spec before launch."
---

# /summon — Design and Launch a Persistent Agent Process

Summon a spirit — a persistent agent that runs on a schedule or watches for conditions. Unlike `/loop` (dumb scheduler), `/summon` designs the process through adaptive questioning, produces a reviewable spec, then launches it.

## When to invoke

**Trigger phrases**: "summon", "create a loop", "set up a recurring", "watch for", "monitor", "keep an eye on", "babysit", "run something every", "I want an agent that"

**Not this command**:
- Quick one-shot schedule → `/loop` directly (user already knows what they want)
- One-time task → just do it, no spirit needed

## Mode detection

```bash
bash bin/config-get.sh mode
```

Use the printed value as `{mode}`; quote it in single quotes when you use it in a command, and write any single quote inside the value as `'\''`.

**Local mode** (`{mode}` is `local`): Skip ALL `bin/graph-op.sh` and `bin/notify.sh` calls — do NOT run them. Do NOT show any graph-related messaging.

Local-mode adjustments:
- **Phase 1**: Skip the graph scan. Generate options from conversation context, `memory/quests/` files, and `.spirits/` directory instead of the graph.
- **Phase 5**: Skip Spirit node creation in Neo4j. Write the spec file to `.spirits/{name}.json`. **Claude Code:** create the scheduled job — this works without the graph.
- **Phase 6**: Skip LoopReport creation in Neo4j. The TUI report still renders, but the graph artifact is not created.
- **Managing Spirits**: Read from `.spirits/` directory instead of querying the graph. **Claude Code:** suspend/resume only deletes or creates the scheduled job, without graph updates.

## Instructions

### Phase 1: Intent Discovery

Start with one open question: ask with a structured question when available and permitted in this session; otherwise ask in plain text:

```
What should this spirit do?
```

**Connected mode:** Options should be derived from current graph context — not hardcoded. Before asking, run a lightweight graph scan to understand what's happening:

```bash
mkdir -p tmp
```

```bash
bash bin/graph-op.sh spirit-context > tmp/summon-context.json
```

Read the active quests, recent sessions, and spirit health signals:

```bash
jq '.values[0][0] // {}' tmp/summon-context.json
```

Use the printed results as `{context}` for the options below.

Use this context to generate options that are relevant — e.g. if there are dormant quests, offer "reconcile dormant work"; if there's a PR-heavy period, offer "watch PRs". Always include a free-text option.

**Local mode:** Skip the graph scan. Instead, derive options from:
- Active quests in `memory/quests/` (parse frontmatter for status)
- Recent handoffs in `memory/handoffs/index.md`
- Existing spirits in `.spirits/` directory
- Conversation context
Always include a free-text option.

The agent has full discretion to decide what context is relevant given the user's stated intent.

### Phase 2: Adaptive Convergence

Ask questions iteratively with a structured question when available and permitted in this session; otherwise ask in plain text. Each round is informed by previous answers AND graph context. The questioning is non-linear — the agent decides what to ask based on where the interesting tension is, not a fixed script.

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
  "name": "memory-gardener",
  "type": "recurring",
  "purpose": "Maintain the optional relationship index — fix structural issues, infer new relationships, report drift",
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
┌ Spirit: memory-gardener ───────────────────────────┐
│                                                    │
│  Purpose:  Maintain the relationship index         │
│  Type:     Recurring                               │
│  Cadence:  Daily at 3:03 AM                        │
│                                                    │
│  Auto-fix: stale handoffs, date types,             │
│            dormant quests, topic links              │
│  Suggest:  duplicate persons, disconnected arts     │
│  Flag:     ghosts, orphans                         │
│                                                    │
│  Reporting: TUI + saved report each cycle        │
│  Boundaries: No person/quest deletion              │
│                                                    │
└────────────────────────────────────────────────────┘
```

Ask: "Launch this spirit?" with options: Launch, Edit (back to questioning), Cancel.

### Phase 5: Launch

Use scheduling only when available and permitted in this session;
otherwise write the spec file `.spirits/{name}.json`, report that no job was
scheduled, and stop before the remaining launch steps.
**Claude Code:** use the native session scheduler for the scheduling steps
below.

1. **Write spec file**: `.spirits/{name}.json`
2. **Create Spirit node in graph** — **CONNECTED MODE ONLY**:
   **Skip this step in local mode.** Use the spec fields with the named operation:
   ```bash
   bash bin/graph-op.sh spirit-create --name '{name}' --type '{type}' --purpose '{purpose}' --cadence '{cadence}' --status 'active' --author '{author}'
   ```
3. **Create the scheduled job**:
   - Prompt is the spirit's execution prompt (constructed from spec)
   - For recurring: standard cron
   - For watchdog: polling cron + condition check prefix
4. **Confirm**: Show job ID and how to cancel. **Claude Code:** include the 3-day auto-expiry note.

### Phase 6: Cycle Reporting (attached to each execution)

When a spirit runs (via `/loop` invoking its prompt), each cycle MUST:

1. **Run the work** defined in the spec
2. **Produce TUI report**:
   ```
   ┌ memory-gardener · Cycle 4 · 2026-03-09 ─────────┐
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

3. **Write LoopReport to graph** — **CONNECTED MODE ONLY**:
   **Skip this step in local mode.** The named update records this cycle's report; the TUI report still renders locally.
   ```bash
   bash bin/graph-op.sh spirit-update --name '{name}' --id '{id}' --title '{title}' --metrics '{metrics}'
   ```

4. **Insights**: The report should include one model-generated insight per cycle — a pattern, question, or observation that emerges from the data but wasn't explicitly programmed. This is the inferential layer growing.

### Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"summon"}' 2>/dev/null &
```

## Managing Spirits

**Connected mode:**
- **List active**: `bash bin/graph-op.sh spirit-list`
- **Suspend**: Set `sp.status = 'suspended'` and delete the scheduled job
- **Resume**: Set `sp.status = 'active'` and create the scheduled job
- **View history**: `MATCH (lr:Artifact {origin: 'spirit'})-[:GENERATED_BY]->(sp:Spirit {name: $name}) RETURN lr ORDER BY lr.created DESC`

**Local mode:**
- **List active**: Read `.spirits/*.json` files, filter by `"status": "active"`. Display name, type, cadence from each spec file.
- **Suspend**: Update spec file `"status": "suspended"` and delete the scheduled job
- **Resume**: Update spec file `"status": "active"` and create the scheduled job
- **View history**: Not available in local mode (no graph artifact storage). Show: `Spirit history requires connected mode.`

## Design Principles

1. **Bitter lesson**: The agent decides what context is relevant, not a fixed query set. More compute, less hand-engineering.
2. **Adaptive convergence**: Questions stop when the spec is clear, not after N rounds.
3. **Specs are forkable**: `.spirits/` is git-tracked. Fork the egregore, inherit its spirits.
4. **Spirits compound**: Each cycle's LoopReport feeds future cycles. The spirit gets smarter about what to surface.
5. **Watchdogs are deferred hooks**: Poll-on-cron now, proper event-driven hooks when infrastructure exists.
