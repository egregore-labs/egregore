Deep analysis — cross-reference an insight against your knowledge base.

Evidence-based deep analysis with signal-aware ontology. Iterative retrieval + multi-sample Opus reasoning over actual artifact content. Surfaces *signals* — any structurally significant relationship between the candidate insight and the existing knowledge base.

## When to invoke

User says: "deep dive on", "cross-reference this", "what does the knowledge base say about", "analyze this against what we know", "connect the dots"
Not this: quick insight capture → `/reflect` · private thought → `/note` · AI steering pattern → `/archive`
Prerequisite: needs 10+ existing artifacts in the graph to be useful

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## Modes

### By depth

| Invocation | Mode | Opus calls | Est. latency |
|---|---|---|---|
| `/deep-reflect` | **Deep** — 3-sample consensus | 5 (Candidate + 3×Analysis + Aggregator) | ~60-90s |
| `/deep-reflect focused "topic"` | **Focused** — topic-filtered | 2 (Candidate + Analysis) | ~30-45s |
| `/deep-reflect quick [category]: content` | **Quick** — fused single-pass | 1 (fused Candidate+Analysis) | ~20-30s |

### By direction

**Undirected** — no arguments, or a bare insight (`finding: Neo4j queries are slow`). Pipeline runs open-ended analysis. DeepAnalysis asks: *"What is the most important thing the existing knowledge base says about this insight?"*

**Directed** — user phrases a question: `on X`, `about the relationship between X and Y`, `how does this fit in the command ecology`. Pipeline extracts a **lens** and passes it to DeepAnalysis as an analytical constraint.

Detection heuristic:
- Contains "on", "about", "how", "why", "what does", "relationship between", "place in", "role of" → **directed**. Extract everything after the directive word as the lens.
- Only a category/content pattern or no arguments → **undirected**

The lens doesn't replace the open question — it constrains it. Directed prompt addition: *"The user wants to understand: {lens}. Analyze through this lens. Surface signals beyond the user's frame only if significant enough to warrant it."*

**Depth detection:**
- No arguments → Deep mode
- First word is `focused` → Focused mode (topic = rest of args)
- First word is `quick`, or matches `[category]: [content]` → Quick mode
- Any other arguments → Quick mode (direction detected separately)

## Signal Ontology

A **signal** is any structurally significant relationship between the candidate insight and the existing knowledge base. Signals replace the v1 split of "tensions + cross-references."

### Signal types

| Type | What it means |
|---|---|
| `tension` | Direct conflict or contradiction |
| `convergence` | Independent artifacts arriving at the same conclusion |
| `gap` | Absence in the graph this insight exposes |
| `dependency` | Can't land without something else happening first |
| `phase_shift` | Marks an evolution in thinking — earlier artifacts assumed differently |
| `redundancy` | Already exists, phrased differently |
| `emergence` | Multiple artifacts together imply something nobody named |
| `reinforcement` | Strengthens an existing artifact's claim |

This list is **open** — the model may name a custom signal type if the relationship genuinely doesn't fit. Instruction: "Name the signal type. If none of the standard types fit, create one and define it."

### Signal schema

```json
{
  "signal_type": "tension|convergence|gap|dependency|phase_shift|redundancy|emergence|reinforcement|{custom}",
  "confidence": 0.0-1.0,
  "description": "One sentence: what is this signal?",
  "evidence": {
    "artifact_ids": ["..."],
    "excerpts": ["..."],
    "reasoning": "Why this evidence supports this signal"
  },
  "weight": "primary|secondary|ambient",
  "action_required": true|false,
  "action_suggestion": "What to do about it, if anything"
}
```

**Weight** — not all signals matter equally:
- `primary` — should change what the user does next
- `secondary` — worth knowing, doesn't demand action
- `ambient` — enriches understanding, requires nothing

### Graph edges

**RELATES_TO** — for non-conflicting signals (convergence, dependency, reinforcement, emergence, redundancy, gap):
```
{ signal_type, family, label, confidence, weight, reasoning, evidence_ids, runId, updated }
```

**TENSION_WITH** — for conflicting signals (tension, phase_shift):
```
{ signal_type, type, confidence, weight, description, resolution_suggestion, evidence_ids, verdict, runId, updated }
```

## Execution rules

**Neo4j-first.** All queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl.
**CRITICAL: Suppress raw output.** Never show raw JSON to the user. Capture in variables, show formatted status lines only.

- 1 Bash call: `git config user.name`
- 6-8 Neo4j queries for context (parallel)
- 0-4 AskUserQuestion calls depending on mode
- 1-5 background Opus Task calls (CandidateSelection, DeepAnalysis, Aggregator)
- Evidence fetch: Neo4j filePath queries + file reads
- 1+ Neo4j queries for Artifact creation + edges
- Auto-save via `/save` flow
- Progress shown incrementally

## Step 0: Parse + Identity (all modes)

### Parse arguments

```
MODE = "deep"          # deep | focused | quick
DIRECTION = "undirected"  # undirected | directed
LENS = null            # extracted from directed phrasing
CATEGORY_HINT = null
FOCUS = null
RUN_ID = "dr-{YYYY-MM-DD}-{4-char-random-hex}"
```

Detection order:
1. No arguments → `MODE = "deep"`, `DIRECTION = "undirected"`
2. Starts with `focused ` → `MODE = "focused"`, `FOCUS = rest of args`. Check direction on FOCUS.
3. Starts with `quick ` → `MODE = "quick"`, content = rest of args. Check direction on content.
4. Matches `(decision|finding|pattern): (.*)` → `MODE = "quick"`, `CATEGORY_HINT = $1`, content = `$2`. `DIRECTION = "undirected"`.
5. Otherwise → `MODE = "quick"`, content = full args. Check direction on content.

Direction check: if content contains "on ", "about ", "how ", "why ", "what does ", "relationship between ", "place in ", "role of " → `DIRECTION = "directed"`, `LENS = extracted phrase`.

### Get current user

```bash
git config user.name
```

Derive handle: lowercase first word (e.g. "Alice Smith" → "alice").

Generate RUN_ID:

```bash
echo "dr-$(date +%Y-%m-%d)-$(openssl rand -hex 2)"
```

## Step 1: Context Queries (all modes, parallel)

Execute each with `bash bin/graph.sh query "..." '{"param": "value"}'`. Run all in parallel.

**Q1 — Recent sessions (7 days):**
```cypher
MATCH (s:Session)-[:BY]->(p:Person {name: $me})
WHERE date(left(toString(s.date), 10)) >= date() - duration('P7D')
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

**Q4 — Knowledge gaps (sessions without artifacts):**
```cypher
MATCH (s:Session)-[:BY]->(p:Person {name: $me})
WITH s, p, date(left(toString(s.date), 10)) AS sDate
WHERE sDate >= date() - duration('P14D')
OPTIONAL MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p)
WHERE a.created >= datetime({year: sDate.year, month: sDate.month, day: sDate.day})
  AND a.created < datetime({year: sDate.year, month: sDate.month, day: sDate.day}) + duration('P1D')
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
```cypher
MATCH (a:Artifact)
WHERE a.title CONTAINS $topic OR $topic IN a.topics
OPTIONAL MATCH (a)-[:PART_OF]->(q:Quest)
OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(p:Person)
RETURN a.title AS title, a.type AS type, a.topics AS topics, a.created AS created, q.id AS quest, p.name AS author
ORDER BY a.created DESC LIMIT 10
```

**Q7 — Knowledge landscape (all artifacts):**
```cypher
MATCH (a:Artifact)
OPTIONAL MATCH (a)-[:PART_OF]->(q:Quest)
RETURN a.id AS id, a.title AS title, a.type AS type, a.topics AS topics, q.id AS quest
ORDER BY coalesce(a.created, datetime('2026-01-01')) DESC
```
Note: No LIMIT — CandidateSelection needs full landscape. No filePath/author — fetched in Step 3B for selected subset only. `coalesce` ensures null `created` sorts last instead of unpredictably.

**Q8 — Active quests with descriptions:**
```cypher
MATCH (q:Quest {status: 'active'})
OPTIONAL MATCH (a:Artifact)-[:PART_OF]->(q)
WITH q, count(a) AS artifactCount
RETURN q.id AS quest, q.title AS title, q.description AS description, artifactCount
ORDER BY artifactCount DESC LIMIT 10
```

**Quick mode**: Only Q2, Q5, Q7, Q8.

### Sparse graph check

Count artifacts from Q7. If < 10:

> Graph too sparse for deep analysis — you have {N} artifacts. Deep analysis unlocks once you have ~10+. Falling back to `/reflect`.

Delegate to `/reflect` with same arguments and stop.

Neo4j unavailable → delegate to `/reflect` with note: "Graph offline — falling back to `/reflect`."

## Step 2: Graph-Grounded Dialogue (Deep + Focused modes only)

Make a specific, falsifiable observation about what the graph reveals, then ask the user to confirm, correct, or react. The user's response IS the reflection content.

**The old approach was wrong.** Template slots ("ship vs. polish", "what's crystallizing", "where's the tension") produce generic coaching with graph data as decoration. The model fills a frame and adds specificity. This is AI slop.

### How to construct the observation

Read Q1-Q8 results. Look for one of these **concrete patterns** (not abstract frames):

**Behavioral patterns** — what the user is doing vs. what they say they're doing:
- "You've added 5 artifacts to quest A this week but quest B — which you described as urgent — has had nothing for 10 days."
- "Your last 3 decisions all touch infrastructure. Before that, 4 straight on product strategy. Something shifted."
- "You had a session on X but didn't capture anything from it. The last time that happened was with Y, which turned into Z two weeks later."

**Structural patterns** — what the graph's shape implies:
- "egregore-reliability has 22 artifacts. egregore-launch has 13. But 5 of the launch artifacts are actually about reliability. The distinction might not be real."
- "Your last 4 decisions share no topics with each other. That's unusual — before this week, decisions clustered tightly around pricing and command design."
- "Three artifacts from three different quests all reference 'design partners.' That phrase doesn't have its own quest or artifact yet."

**Absence patterns** — what's NOT in the graph:
- "You've made 12 decisions in the last 2 weeks but zero findings. You're deciding without discovering — or the discoveries aren't being captured."
- "No artifacts reference onboarding, setup, or first-run experience. Every artifact assumes the user already knows how to use Egregore."

### What NOT to do

- Don't ask "what's on your mind" — therapy opener, not analytical
- Don't offer 3-4 abstract frames as options ("ship vs. polish", "post-launch identity") — generic, could apply to any project
- Don't use the word "tension" in the question — let the user name it if it exists
- Don't use "crystallizing", "emerging", "sensing" — coaching verbs, not analytical
- Don't ask what the user wants to reflect on — the graph should suggest it
- Options in AskUserQuestion should be **specific reactions to the observation**, not generic categories

### Turn count

Usually **1 turn is enough** if the observation is sharp. Max 2. If you need 3-4 turns, your opening wasn't specific enough.

**Turn 1:** Graph-grounded observation + one question. Options are specific reactions.

Example:
```
You made 5 infrastructure decisions today (API gateway, sandboxing, bash
toggle, focus testing, Telegram switch). All hardening egregore-reliability.
None touch egregore-launch, which hasn't had a new artifact in 4 days.

  1. "Reliability IS the launch blocker — these are prerequisites"
  2. "Launch is on a different track, I'll get to it"
  3. "Actually, I want to reflect on something else"
```

**Turn 2 (only if needed):** Sharpen based on response. If user selected option 1, follow up with specific graph data: "The last launch artifact was X on date Y. What's between that and shipping?" If user typed freeform, that's your content — move to Step 3.

### If the graph is boring

Sometimes the graph doesn't reveal anything interesting. Recent artifacts are routine, quests are progressing normally, no behavioral or structural anomaly. Say so:

> "The graph looks steady — egregore-reliability and egregore-launch are both progressing, no unusual patterns in the last week. What specifically do you want to capture?"

Don't manufacture an observation.

### The test

The dialogue should feel like someone who read your commit history and has a pointed question, not someone who read a coaching manual and is trying to help you "explore." The graph data should do the work, not generic frames applied to graph data.

**Quick mode**: Skip Step 2 entirely. Arguments ARE the reflection.

## Step 3: Build AnalysisInput

```
CANDIDATE = {
  raw_content: [user's responses concatenated],
  direction: DIRECTION,
  lens: LENS or null,
  category_hint: CATEGORY_HINT or null,
  topics_mentioned: [extracted from text + graph context],
  session_context: [Q1],
  quest_context: [Q2/Q8],
  recent_artifacts: [Q3 titles + types, no content]
}
```

## Step 3A: CandidateSelection (Opus background agent)

Spawn background Task (subagent_type: "general-purpose", model: "opus"). Returns JSON only.

**Prompt:**

> You are a graph-aware research assistant. Given a candidate insight and a landscape of existing artifacts (titles, topics, categories), select which artifacts to retrieve for full inspection.
>
> {IF DIRECTED} The user has a specific analytical lens: "{LENS}". Prioritize artifacts relevant to this lens, but include others if structurally significant. {/IF}
>
> You may hypothesize what signal types you expect (tension, convergence, gap, dependency, phase_shift, redundancy, emergence, reinforcement) but you may NOT assert any signal as real. That requires evidence you don't have yet.
>
> **Input:**
> - Candidate insight: {CANDIDATE.raw_content}
> - Category hint: {CANDIDATE.category_hint}
> - Topics mentioned: {CANDIDATE.topics_mentioned}
> - Knowledge landscape: {Q7 results}
> - Quest context: {Q8 results}
>
> **Return ONLY JSON:**
> ```json
> {
>   "candidates": [{"id": "artifact-id", "hypothesis": "expected signal type + reason"}],
>   "search_requests": ["grep strings for memory/"],
>   "gap_hypotheses": ["topics with no coverage this insight exposes"]
> }
> ```
> Max candidates: 12. Prefer breadth — convergence needs artifacts from different quests/categories.

**Quick mode**: Fused with DeepAnalysis in Step 3C.

## Step 3B: Evidence Fetch (main thread, sequential)

### 1. Get filePaths from Neo4j

```cypher
MATCH (a:Artifact) WHERE a.id IN $ids
RETURN a.id AS id, a.filePath AS filePath, a.title AS title
```

### 2. Batch-read all artifact files

Single Bash call with ID delimiters:

```bash
for fp in "path1" "path2" ...; do
  echo "---ARTIFACT:${ID}---"
  cat "memory/${fp}" 2>/dev/null || echo "(file not found)"
done
```

Parse combined output to extract content per artifact.

### 3. Run search queries (if any)

Use Grep tool for each `search_request`. Include 3 lines context.

### 4. Build evidence_bundle

```
EVIDENCE = {
  artifacts: { "id1": { title, filePath, content }, ... },
  search_results: [{ query, matches: [{ file, line, context }] }]
}
```

**Ghost artifacts** (filePath is null in the Neo4j response): Include as metadata-only entries in the evidence bundle:
```
{ title, type, topics, quest, content: "(graph-only artifact — no file on disk. Reference metadata but cannot cite text.)" }
```
These are insights extracted during sessions that were written to the graph but never materialized as markdown. The model should know they exist and can reason about them via title/topics/type, but cannot cite textual evidence from them.

No candidate IDs → skip evidence fetch, DeepAnalysis with baseline only.

## Step 3C: DeepAnalysis (Opus background agents)

**Deep**: 3 parallel Task agents. **Focused**: 1 agent. **Quick**: 1 fused agent.

**DeepAnalysis prompt:**

> You are an analyst with access to the full text of selected knowledge artifacts.
>
> {IF DIRECTED} The user wants to understand: "{LENS}". Analyze through this lens. You may surface signals beyond the user's frame if significant enough — but the lens is primary. {ELSE} No lens specified. Ask the open question: what is the most important thing the existing knowledge base says about this insight? {/IF}
>
> Identify the most significant SIGNALS — structurally important relationships between this insight and the existing knowledge base.
>
> Signal types: tension, convergence, gap, dependency, phase_shift, redundancy, emergence, reinforcement. You may define a custom type if needed.
>
> **HARD RULES:**
> - No signal without evidence excerpts (exception: gaps — evidenced by absence, cite what SHOULD exist but doesn't)
> - Weight every signal: primary (changes what to do next), secondary (worth knowing), ambient (context only)
> - If no signals are significant, say so. "Clean addition, no structural consequences" is a valid finding. Don't manufacture significance.
>
> **BODY INSTRUCTION:** Write the artifact body as free-form markdown. Whatever headings and structure best communicate this insight. Self-contained for a teammate finding it 3 months from now. Don't force empty sections.
>
> **Input:**
> - Candidate insight: {CANDIDATE.raw_content}
> - Category hint: {CANDIDATE.category_hint}
> - Evidence bundle: {EVIDENCE}
> - Quest context: {Q8}
> - Session context: {Q1}
>
> **Return ONLY JSON:**
> ```json
> {
>   "artifacts": [{
>     "category": "decision|finding|pattern",
>     "title": "Short descriptive title",
>     "topics": ["topic1", "topic2", "topic3"],
>     "body": "Free-form markdown body.",
>     "signals": [{
>       "signal_type": "...",
>       "target_id": "artifact-id or null for gaps/emergence",
>       "confidence": 0.0-1.0,
>       "description": "One sentence",
>       "evidence": { "artifact_ids": [...], "excerpts": [...], "reasoning": "..." },
>       "weight": "primary|secondary|ambient",
>       "action_required": true|false,
>       "action_suggestion": "..."
>     }],
>     "quest_links": ["quest-id"]
>   }],
>   "meta": {
>     "evidence_quality": "strong|moderate|thin",
>     "confidence": 0.0-1.0,
>     "limitations": ["..."]
>   }
> }
> ```

**Fused Quick mode prompt** — same as above but replace evidence bundle with:
> - Knowledge landscape: {Q7 results — titles, types, topics}
> - Note: You do NOT have full artifact content. Base signals on title/topic overlap and reasoning. Mark all signals as `confidence ≤ 0.5` since they lack textual evidence. Do NOT fabricate excerpts.

## Step 3D: Aggregator (Deep mode only)

**Prompt:**

> Merge 3 independent analyses into consensus. Keep signals with ≥2/3 support or exceptionally strong single-run evidence. Reconcile weight assignments by majority. Preserve disagreements explicitly. Select best-written body, enhance with unique insights from others.
>
> **Return same JSON schema** plus:
> ```json
> "meta": {
>   ...,
>   "disagreements": [{ "topic": "...", "positions": ["..."], "resolution": "..." }],
>   "sample_agreement": "3/3 | 2/3 on key claims"
> }
> ```

### JSON repair fallback

Invalid JSON from any agent:
1. Single Opus repair attempt
2. Still invalid → fall back to `/reflect` inline classification. Warning: "Deep analysis returned invalid output — falling back to inline classification."

## Step 4: Present Enriched Proposal

Three layers, always in this order.

### Layer 1: Meta-analysis (narrative prose)

Write 2-4 paragraphs of **opinionated synthesis** that tells the user something they don't already know. This justifies the compute. If you can't say anything the user wouldn't have figured out from the signal list, you've failed.

**Stance, not summary.** Take a position. Is it genuinely novel or restating what the graph already knows? Is the user circling a decision they haven't committed to? Is the real signal not in the list? Say so.

{IF DIRECTED} Begin by addressing the user's lens directly. Answer their question first, then expand. {/IF}

Address:
- **What this insight actually changes.** Not "how it connects" — what it *breaks*, *unlocks*, or *forces*. If nothing, say "clean addition, no structural consequences."
- **Where signals are real and where they're noise.** Name which are genuine constraints vs. integration chores vs. coincidences. Dismiss the weak ones explicitly.
- **What's missing.** The most important relationship might be between this insight and an assumption the user hasn't examined.
- **Confidence landscape, with teeth.** Interrogate scores. Low confidence + no evidence = guessing. High confidence + thin evidence = confabulating. Quick mode: "Structural priors, not evidence-backed claims."
- **One thing to do.** One action that matters most. Everything else is context.

**The test:** If the user feels slightly uncomfortable — like it named something they were avoiding — it's working. If it reads like a book report, rewrite it.

**Anti-patterns:**
- "This is an interesting insight that..." → you have nothing to say
- "The signals cluster around..." → describing data, not interpreting it
- Equal weight to everything → dismiss the weak ones
- "Worth watching" → demands action or doesn't

**Register:** A co-founder who's been in the codebase for 6 months and isn't afraid to tell you you're wrong. Invested, direct, says the uncomfortable thing because they want the product to be good.

### Layer 2: Structured details

**Artifact proposal:**
```
  ◉ {Category}: "{Title}"
    → {quest-links}
```

**Primary signals** (these matter):
```
  ◆ {signal_type}: {description} (confidence: {0.X})
    Evidence: "{excerpt}" — {artifact-title}
    {action_suggestion if action_required}
```

**Secondary signals** (worth knowing):
```
  ◇ {signal_type}: {description} (confidence: {0.X})
    → {artifact-title}
```

Ambient signals NOT shown in presentation — markdown file and graph only.

**Deep mode** disagreements: `⊘ {topic}: {resolution}`

Summary (deep mode): `{N} primary · {N} secondary · {N} ambient signals (3-sample consensus)`

### Layer 3: Signal verdicts via AskUserQuestion

Collect verdicts on **primary signals only**. Secondary/ambient auto-accepted.

Options must be **specific to that signal** — not generic accept/reject. Descriptions say what accepting or rejecting *this signal* means for the project.

Examples by signal type:

**Tension:** *"Generative bodies conflict with existing parsers."*
→ "Accept — schedule parser audit" / "Reject — parsers already handle freeform" / "Defer — check after first design partner"

**Convergence:** *"Three artifacts point to Opus-only."*
→ "Accept — Opus-only is settled" / "Reject — still evaluating Sonnet" / "Accept with note — settled for now"

**Gap:** *"No artifacts cover onboarding."*
→ "Accept — add to backlog" / "Reject — intentionally deferred" / "Note — real but not blocking"

**Dependency:** *"Can't ship without parser updates."*
→ "Accept — block on this" / "Reject — can ship incrementally" / "Defer"

If 1-4 primary signals: one AskUserQuestion with each signal as a separate question. If 0 primary signals: skip verdicts entirely.

**Final confirmation** (always):

```
AskUserQuestion:
  question: "Save this reflection?"
  header: "Confirm"
  options:
    - label: "Save as-is"
      description: "Write artifact, graph it, push"
    - label: "Edit first"
      description: "Modify before saving"
    - label: "Skip"
      description: "Discard without saving"
```

## Step 5: Write Enriched Markdown Files

Slug: lowercase, hyphens, no special chars, max 50 chars.

Path: `memory/knowledge/{category}s/{YYYY-MM-DD}-{slug}.md`

Write using Bash (memory is outside project):

```bash
cat > "memory/knowledge/{category}s/{YYYY-MM-DD}-{slug}.md" << 'REFLECTEOF'
# {Title}

**Date**: {YYYY-MM-DD}
**Author**: {author}
**Category**: {category}
**Topics**: {topics}
**Analysis**: deep-reflect {MODE} {DIRECTION}
**Lens**: {LENS or "open"}
**Run ID**: {RUN_ID}

{body — generative, written by Opus}

---

## Signals

### {signal_type}: {description}
- **Confidence**: {0.X}
- **Weight**: {primary|secondary|ambient}
- **Evidence**: {excerpts with artifact IDs}
- **Action**: {suggestion or "None required"}
- **Verdict**: {accept|reject|defer|auto-accepted}

---

## Provenance

- Pipeline: deep-reflect v2
- Mode: {quick|focused|deep}
- Direction: {directed|undirected}
- Lens: {LENS or "open"}
- Agents: {e.g. "CandidateSelection, DeepAnalysis x3, Aggregator"}
- Evidence inspected: {list of artifact IDs}
- Evidence quality: {strong|moderate|thin}
- Run ID: {RUN_ID}

## Feedback

- User confirmation: {accepted|edited|rejected}
- Signal verdicts: {per-signal verdict list}
REFLECTEOF
```

The `body` from Opus IS the main content — free-form markdown, generative structure. Header and footer are fixed; body between them is whatever the model wrote.

File collision → append 4-char random hex to slug.

Progress: `[1/3] ✓ Writing knowledge/{category}s/{date}-{slug}.md`

## Step 6: Neo4j — Artifact + Edges

### Create Artifact node

**With quest links:**
```cypher
MATCH (p:Person {name: $author})
CREATE (a:Artifact {
  id: $artifactId,
  title: $title,
  type: $category,
  topics: $topics,
  filePath: $filePath,
  created: datetime(),
  analysis: 'deep-reflect',
  runId: $runId
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
  created: datetime(),
  analysis: 'deep-reflect',
  runId: $runId
})
CREATE (a)-[:CONTRIBUTED_BY]->(p)
RETURN a.id
```

### Create RELATES_TO edges (non-conflicting signals)

For signals with type: convergence, dependency, reinforcement, emergence, redundancy, gap:

```cypher
MATCH (a:Artifact {id: $artifactId}), (b:Artifact {id: $targetId})
CREATE (a)-[:RELATES_TO {
  signal_type: $signalType,
  family: $family,
  label: $label,
  confidence: $confidence,
  weight: $weight,
  reasoning: $reasoning,
  evidence_ids: $evidenceIds,
  runId: $runId,
  updated: datetime()
}]->(b)
```

`$family` ∈ reinforces | extends | evolves | complements | questions | specializes | generalizes (mapped from signal context).

### Create TENSION_WITH edges (conflicting signals)

For signals with type: tension, phase_shift:

```cypher
MATCH (a:Artifact {id: $artifactId}), (b:Artifact {id: $targetId})
CREATE (a)-[:TENSION_WITH {
  signal_type: $signalType,
  type: $tensionType,
  confidence: $confidence,
  weight: $weight,
  description: $description,
  resolution_suggestion: $suggestion,
  evidence_ids: $evidenceIds,
  verdict: $verdict,
  runId: $runId,
  updated: datetime()
}]->(b)
```

`$tensionType` ∈ contradicts | supersedes | narrows | broadens | complicates
`$verdict` = user's feedback from Step 4 (accept | reject | defer | auto-accepted)

Run all edge-creation queries in parallel.

Progress: `[2/3] ✓ Indexed in knowledge graph ({N} signals)`

## Step 7: Auto-save

Full `/save` flow:
1. Commit memory repo, push to main (pull-rebase-push with retry)
2. Commit egregore changes, push working branch + PR to develop

Progress: `[3/3] ✓ Auto-saved`

## Step 8: TUI Confirmation

72-char width. Sigil: `◎ DEEP REFLECTION`.

### Boundary handling (CRITICAL)

**No sub-boxes.** Only 4 line patterns:

1. **Top**: `┌` + 70×`─` + `┐`
2. **Separator**: `├` + 70×`─` + `┤`
3. **Content**: `│` + 2 spaces + text padded to 68 chars + `│`
4. **Bottom**: `└` + 70×`─` + `┘`

### Single artifact:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◎ DEEP REFLECTION                                  cem · Feb 16    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ Finding: Neo4j HTTP faster than Bolt for small...                 │
│    → benchmark-eval                                                  │
│    ◆ 1 primary · ◇ 2 secondary signals                              │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### Multi-artifact (deep mode):

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◎ DEEP REFLECTION                                  cem · Feb 16    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  2 insights captured:                                                │
│                                                                      │
│  ◉ Decision: Gate by usage patterns, not Claude tier                 │
│    → pricing-strategy                                                │
│    ◆ 2 primary · ◇ 1 secondary                                      │
│                                                                      │
│  ◉ Pattern: Agents as individual PMF                                 │
│    → individual-tier · egregore-reliability                          │
│    ◆ 1 primary · ◇ 2 secondary                                      │
│                                                                      │
│  3 primary · 3 secondary · 4 ambient (3-sample consensus)           │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### TUI rules

- Header: `◎ DEEP REFLECTION` left, author + date right
- `├───┤` separator between header and content
- Multi-artifact: "N insights captured:" header
- `◉` per artifact with Category: Title (truncate at 45 chars)
- `→` for quest links
- `◆`/`◇` signal count per artifact
- Deep mode summary line before footer separator
- `├───┤` before footer
- `✓ Saved · graphed · pushed`
- "Visible in /activity."

## Fallback Ladder

| # | Condition | Fallback |
|---|-----------|----------|
| 1 | Sparse graph (< 10 artifacts) | Degrade to `/reflect` |
| 2 | Neo4j down | `/reflect` Quick mode |
| 3 | Invalid JSON | Repair → `/reflect` inline |
| 4 | Thin evidence (0-2 candidates) | Signals with confidence=low + limitation note |
| 5 | No candidate IDs | DeepAnalysis with baseline only |
| 6 | Memory symlink missing | Error: "Run /setup first" |
| 7 | Empty content | "Nothing to reflect on yet" |
| 8 | File collision | Append hex to slug |
| 9 | No primary signals | "Clean addition" in meta-analysis. Don't manufacture significance. |
| 10 | Directed lens yields nothing | Acknowledge lens, explain what graph covers, suggest related lenses |

## Full Example (Quick Directed Mode)

```
> /deep-reflect on what we just built and its place in the command ecology

Analyzing... (Quick mode, directed lens: "its place in the command ecology")

[meta-analysis — 2-3 paragraphs of opinionated synthesis addressing the
lens first, then the broader picture. Takes a stance. Names the one
thing to do. Dismisses weak signals explicitly. Register: co-founder
who's been in the codebase.]

  ◉ Decision: "/deep-reflect — Evidence-Based Deep Analysis Command"
    → egregore-reliability

  Primary signals:
  ◆ dependency: Generative bodies require parser audit (0.45)
    → Egregore Efficiency and Unit Economics
    Action: Audit parsers before design partner launch

  ◆ phase_shift: From capture-only to read-own-memory (0.65)
    → Reflect Skill Test, Egregore Form Factor
    Action: Document command ecology explicitly

  Secondary signals:
  ◇ reinforcement: Multi-sample consensus aligns with Opus-judge decision (0.7)
    → Opus Judges Required for Unbiased Evaluation
  ◇ convergence: "Environment not tool" finding echoed by this design (0.6)
    → Egregore Form Factor: Environment, Not Tool

[AskUserQuestion for primary signal verdicts — 2 questions, signal-specific options]

[AskUserQuestion for save confirmation]

Creating deep reflection...
  [1/3] ✓ Writing knowledge/decisions/2026-02-16-deep-reflect-command-ecology.md
  [2/3] ✓ Indexed in knowledge graph (6 signals)
  [3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ◎ DEEP REFLECTION                                  cem · Feb 16    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ Decision: /deep-reflect — command ecology position                │
│    → egregore-reliability                                            │
│    ◆ 2 primary · ◇ 2 secondary                                      │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

## Reuse from /reflect

- Q1-Q6 Cypher queries (verbatim)
- Step 2 Socratic dialogue flow (opportunity detection, AskUserQuestion)
- File path convention: `memory/knowledge/{category}s/YYYY-MM-DD-{slug}.md`
- Auto-save (delegates to `/save`)
- Edge case handling (Neo4j down, no quests, empty content, collision)

## Backwards Compatibility

- `/reflect` unchanged — `/deep-reflect` is separate
- Same file locations: `memory/knowledge/{type}s/`
- Same Artifact node schema + new optional properties (`analysis`, `runId`)
- `TENSION_WITH` edge type (new)
- `RELATES_TO` gains optional properties (`signal_type`, `family`, `confidence`, `weight`)
- Old edges without these properties continue to work

## Future (v3)

- **Signal history**: Track accept/reject rates per signal type. Surface calibration drift.
- **Cross-run emergence**: Meta-analysis across deep-reflect outputs. Cross-session > within-session.
- **Lens library**: Accumulate useful directed lenses. Suggest when users invoke undirected.
- **Signal decay**: Confidence drops with evidence age. Tension with 3-month-old artifact may not be live.
