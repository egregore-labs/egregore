Run an adaptive harvest — directed elicitation that extracts, deepens, and synthesizes what people actually think about a topic.

## When to invoke

User says: "harvest", "run a harvest", "I want to understand what the team thinks about", "elicit", "let's do a structured interview about", "harvest the team on", "I need to align the team on"

Not this: casual question → just answer · survey/form → different tool · unstructured chat → just talk

Arguments: $ARGUMENTS (Optional: [topic] [--respondents name1,name2] [--seed path])

## What to do

**This command is a thin entry point.** The intelligence lives in `skills/harvest/SKILL.md`. Load and apply it.

### Step 0: Parse invocation

From `$ARGUMENTS`, extract:
- **topic** — what the harvest is about (freeform text, everything that isn't a flag)
- **respondents** — if `--respondents` provided, parse comma-separated names. Otherwise, determine from context or ask.
- **seed** — if `--seed` provided, read the file as seed context

Get current user:
```bash
git config user.name
```

### Step 1: Seed context

Run in parallel:
```bash
# Who exists in the graph
bash bin/graph.sh query "MATCH (p:Person) RETURN p.name AS name, p.role AS role, p.domain AS domain"

# Prior harvests on this topic (if any)
bash bin/graph.sh query "MATCH (h:Harvest) WHERE h.topic CONTAINS \$topic RETURN h.id, h.status, h.created ORDER BY h.created DESC LIMIT 3" '{"topic":"$TOPIC"}'

# Recent artifacts related to topic
bash bin/graph.sh query "MATCH (a:Artifact) WHERE a.title CONTAINS \$topic OR \$topic IN a.topics RETURN a.title, a.type, a.created ORDER BY a.created DESC LIMIT 5" '{"topic":"$TOPIC"}'
```

If `--seed` path provided, read the file.

### Step 2: Create harvest in graph

```bash
bash bin/graph-op.sh create-harvest "$HARVEST_ID" "$TOPIC" "$INTENT" "$INITIATOR"
```

Where `$HARVEST_ID` = `harvest-{YYYY-MM-DD}-{topic-slug}`.

### Step 3: Clarify intent (if needed)

If topic is clear and respondents are known, proceed. Otherwise, use AskUserQuestion to clarify:
- What dimensions to explore
- Who to harvest
- What's already known vs. what needs discovering

### Step 4: Run the harvest

**Apply `skills/harvest/SKILL.md` from here.** The skill describes the cognitive process — seeding, question generation, evaluation, checkpoints, cascade, synthesis. Follow its rhythm.

For each respondent, create a HarvestSession:
```bash
bash bin/graph-op.sh create-harvest-session "$HARVEST_ID" "$SESSION_ID" "$PERSON_NAME"
```

For each question-answer turn:
```bash
bash bin/graph-op.sh record-harvest-turn "$SESSION_ID" "$TURN_NUMBER" "$QUESTION" "$QUESTION_INTENT" "$ANSWER" "$EVALUATION"
```

### Step 5: Synthesize

When all respondents are done (or solo harvest finishes), produce synthesis artifact.

Write to `memory/knowledge/harvests/{YYYY-MM-DD}-{topic-slug}.md` using Bash:
```bash
cat > "memory/knowledge/harvests/{date}-{slug}.md" << 'HARVESTEOF'
{synthesis content — format per skill guidance}
HARVESTEOF
```

Create Artifact node and link:
```bash
bash bin/graph-op.sh complete-harvest "$HARVEST_ID" "$ARTIFACT_PATH"
```

### Step 6: Confirm

Show completion. Sigil: `⊙ HARVEST`.

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⊙ HARVEST                                        cem · Mar 10      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: Launch strategy alignment                                    │
│  Respondents: cem, renc, oz                                          │
│                                                                      │
│  ◉ Synthesis: knowledge/harvests/2026-03-10-launch-st...             │
│    3 decisions · 2 divergences · 1 pattern                           │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Harvested · synthesized · graphed · pushed                        │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### Self-harvest (solo)

When someone runs `/harvest` alone or on themselves — "I need to think through my position on X" — skip cascade logic. The model interviews them directly, goes deep, and produces a structured artifact of their thinking. Same process, one respondent.

### Async harvest (multi-person, not all present)

When respondents aren't in the current session:
1. Generate questions for each absent respondent based on intent + seed context + any completed sessions
2. Deliver via `/ask [person]` with harvest context
3. Mark HarvestSession as `pending`
4. When answers arrive (via graph — QuestionSet answered), resume synthesis

## Edge cases

| Scenario | Handling |
|----------|----------|
| Neo4j unavailable | Run harvest conversationally, skip graph writes, save synthesis file only |
| Respondent says "I'm done" mid-harvest | Respect it. Synthesize what you have. |
| Topic overlaps prior harvest | Show prior results as seed context, ask if this is a continuation or fresh start |
| Single respondent, clear topic | Skip cascade, go straight to deep elicitation |
| No seed context at all | That's fine — generate from intent alone, first questions will be broader |
| Initiator is not a respondent | They set up the harvest and receive the synthesis, but don't answer questions |
