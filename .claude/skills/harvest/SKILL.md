Run an adaptive harvest — directed elicitation that extracts, deepens, and synthesizes what people actually think about a topic.

## When to invoke

User says: "harvest", "run a harvest", "I want to understand what the team thinks about", "elicit", "let's do a structured interview about", "harvest the team on", "I need to align the team on"

Not this: casual question → just answer · survey/form → different tool · unstructured chat → just talk

Arguments: $ARGUMENTS (Optional: [topic] [--respondents name1,name2] [--seed path])

**Rendered surface:** `/harvest` is the only command. When a round's findings are decision-shaped (each a real fork with 2–4 distinct options), `/harvest` renders them as an interactive Meridian **decision surface** the respondent decides *on* and pastes back, instead of asking inline. *Decision surface* is the rendered format `/harvest` produces — not a separate command. See the rendered-surface section below.

## What to do

**This command is a thin entry point.** The intelligence lives in the sibling contracts next to this file — `.claude/skills/harvest/PROCESS.md` (the cognitive process), `.claude/skills/harvest/QUESTION_PALETTE.md` (question intent → move → answer shape), `.claude/skills/harvest/FORMAT.md` (synthesis format), `.claude/skills/harvest/AUDIT.md` (persistence contracts + design audit; §14 owns the rendered-surface absorb machine). Load and apply them.

### Step 0: Parse invocation

From `$ARGUMENTS`, extract:
- **topic** — what the harvest is about (freeform text, everything that isn't a flag)
- **respondents** — if `--respondents` provided, parse comma-separated names. Otherwise, determine from context or ask.
- **seed** — if `--seed` provided, read the file as seed context

Get current user:
```bash
git config user.name
```

### Step 0.5: Check graph availability

```bash
GRAPH_OK=$(bash bin/graph.sh test 2>/dev/null | jq -r '.status // "offline"')
```

If not `"ok"`: note "Graph offline — running solo harvest." All graph-op calls below are non-fatal — skip them and continue conversationally. The synthesis file is the canonical record.

### Step 1: Seed context

Run in parallel (all queries are non-fatal — continue without graph context if they fail):
```bash
# Who exists in the graph
bash bin/graph.sh query "MATCH (p:Person) RETURN p.name AS name, p.role AS role, p.domain AS domain" 2>/dev/null || true

# Prior harvests on this topic (if any)
bash bin/graph.sh query "MATCH (h:Harvest) WHERE h.topic CONTAINS \$topic RETURN h.id, h.status, h.created ORDER BY h.created DESC LIMIT 3" '{"topic":"$TOPIC"}' 2>/dev/null || true

# Recent artifacts related to topic
bash bin/graph.sh query "MATCH (a:Artifact) WHERE a.title CONTAINS \$topic OR \$topic IN a.topics RETURN a.title, a.type, a.created ORDER BY a.created DESC LIMIT 5" '{"topic":"$TOPIC"}' 2>/dev/null || true
```

If `--seed` path provided, read the file.

### Step 2: Create harvest in graph

```bash
bash bin/graph-op.sh create-harvest "$HARVEST_ID" "$TOPIC" "$INTENT" "$INITIATOR" 2>/dev/null || true
```

If this fails, continue — the synthesis file is the canonical record.

Where `$HARVEST_ID` = `harvest-{YYYY-MM-DD}-{topic-slug}`.

### Step 3: Clarify intent (if needed)

If topic is clear and respondents are known, proceed. Otherwise, use AskUserQuestion to clarify:
- What dimensions to explore
- Who to harvest
- What's already known vs. what needs discovering

### Step 4: Run the harvest

**Apply `.claude/skills/harvest/PROCESS.md` from here.** It describes the cognitive process — seeding, question generation, evaluation, checkpoints, cascade, synthesis. Follow its rhythm.

For each respondent, create a HarvestSession (non-fatal — continue if graph is unavailable). `$HARVEST_SESSION_ID` is the harvest's own session id (`{harvest_id}-{handle}`), distinct from the framework's `$SESSION_ID`:
```bash
bash bin/graph-op.sh create-harvest-session "$HARVEST_ID" "$HARVEST_SESSION_ID" "$PERSON_NAME" 2>/dev/null || true
```

For each question-answer turn (non-fatal — continue if graph is unavailable):
```bash
bash bin/graph-op.sh record-harvest-turn "$HARVEST_SESSION_ID" "$TURN_NUMBER" "$QUESTION" "$QUESTION_INTENT" "$ANSWER" "$EVALUATION" 2>/dev/null || true
```

### Step 5: Synthesize

When all respondents are done (or solo harvest finishes), produce synthesis artifact.

Write to `memory/knowledge/harvests/{YYYY-MM-DD}-{topic-slug}.md` using Bash:
```bash
cat > "memory/knowledge/harvests/{date}-{slug}.md" << 'HARVESTEOF'
{synthesis content — format per skill guidance}
HARVESTEOF
```

Create Artifact node and link (non-fatal — the synthesis file is the canonical record):
```bash
bash bin/graph-op.sh complete-harvest "$HARVEST_ID" "$ARTIFACT_PATH" 2>/dev/null || true
```

### Step 6: Confirm

Show completion. Sigil: `⊙ HARVEST`.

Footer varies based on graph availability:
- **Graph available:** `✓ Harvested · synthesized · graphed · pushed`
- **Graph offline:** `✓ Harvested · synthesized · saved to memory`

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

### Decision surface — harvest's rendered mode

`/harvest` is the only command. When a round's findings are **decision-shaped** — each a real fork with 2–4 distinct options — render them as an interactive Meridian **decision surface** (the rendered format) instead of asking inline. The respondent decides *on* the page — clicking an option per card, noting reasoning — and hits **copy decisions**, which emits a stable paste-back block:

```
#{slug}-decisions:v1
surface: {surface_id}
harvest: {harvest_id}      # directed surfaces only
date: {YYYY-MM-DD}

Q1 {decision-id}: {option-key}  ("{label}")
   note: {reasoning}
Q2 {decision-id}: UNDECIDED
Q3 {decision-id}: [{key-a}, {key-b}]  ("{Label A}" + "{Label B}")   # multi
Q4 {decision-id}: {key-a} > {key-c} > {key-b}                      # rank
Q5 {decision-id}: {position}  ({left-pole}→{right-pole})           # spectrum
Q6 {decision-id}: {key-a}:60 {key-b}:40                            # weight
```

**Design the surface strategically — this is where harvest's craft shows.** A flat verdict form wastes the surface. Instead:
- A card earns its place only as a genuine fork (≥3 interrelated forks → a surface; 1–2 quick choices → ask inline).
- Each option carries a structural **visual** of what it *means* (mono mock / diagram / badges), honest `+/−` tradeoffs (every option needs ≥1 real minus — an option with no minus is propaganda), and at most one recommendation that's a position to push on.
- **Order for cascade**: open with the choice that frames the rest; let later cards build on earlier ones. Surface the real tension instead of flattening it — the goal is to extract sharp judgment and its *why* (the note rides back), not collect a checklist.

**Pick an answer mode per card — explicitly.** `QUESTION_PALETTE.md`
is the canonical intent-to-shape rubric and owns the probe moves and
hard bans. The renderer ships five modes; this table owns only their
data fields and return shapes:

| `mode` | Card fields | Returned answer |
|---|---|---|
| `single` | `options[]` | one option key |
| `multi` | `options[]` + optional `max` | selected key array |
| `rank` | `options[]` | ordered keys |
| `weight` | `options[]` | `key:amount` allocations |
| `spectrum` | `ends: ["{left}", "{right}"]` | position between the labeled poles |

Absent `mode` falls back to `single` for backward compatibility only.
Never rely on that default in a new surface.

**Grouping (optional):** a top-level `sections: [{id, label, desc}]` plus a `section: "<id>"` per decision renders a category rail; without it the surface stays flat. Additive — old surfaces are unaffected.

Each mode returns its own line shape in the paste-back block (examples above); `UNDECIDED` and an indented `note:` are valid under every mode. Absorb on `--resume` handles all five.

**Render** the data model (JSON) — see `packages/egregore-artifacts/lib/parsers/decision-surface.js` for the shape:
```bash
node packages/egregore-artifacts/bin/cli.js decision-surface {surface}.json --output {out}.html
# published form (post-publish): npx egregore-artifacts decision-surface {surface}.json
```
Renderer type: `decision-surface` (meridian-locked). Visuals use a **safe structured schema** (`mono`/`badges`/`diagram`) — never raw HTML/SVG, since directed surfaces are sent to others.

- **Self** (no `--to`): render, open locally, fill, paste back into this session.
- **Directed** (`--to <name>`): render + publish, deliver the link via `/ask` with the async-harvest frontmatter (`harvest_id`, `harvest_session_id`, `context_mode`); mark the HarvestSession `pending`. At dispatch, declare the **review gate**: **gated** (the default; the author reviews the return) or **trusted** (add this named respondent to the surface's `trusted` list for auto-absorb). Social-choice mechanisms such as voting and quorum are future work, not v1.

**Absorb on `--resume`:** the canonical statement of the absorb & review machine — event grammar, author/trusted gate, accept / decline-with-required-reason / synthesize dispositions, idempotent `turn-applied` — is `AUDIT.md` §14 (*Absorb & review*). Apply it exactly; this file does not restate it. `UNDECIDED` lines stay open — never force a pick.

The block is the **transport-agnostic return contract**: `/harvest --resume` absorbs it today; an emissary response (`kind: decision`) will carry the identical payload for people without egregore (designed, not built — AUDIT §14).

### Async harvest (multi-person, not all present)

When respondents aren't in the current session:
1. Generate questions for each absent respondent from intent, seed context, RoleSheet, and only the prior-answer context allowed by `PROCESS.md` §3.5. In a blind shared-artifact round, dispatch the frozen question set unchanged.
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
