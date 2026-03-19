Analyze user interview transcripts. Uses a multi-dimensional analysis pipeline with 3 analyst agents + Opus synthesis to extract rich, structured insights from user research sessions.

Arguments: $ARGUMENTS (Optional: search term, file path, or "synthesis" for cross-interview patterns)

## Usage

- `/ingest user-interview` — Interactive: choose source (Granola, paste, file)
- `/ingest user-interview <path>` — Process a specific transcript file
- `/ingest user-interview <search>` — Find interview in Granola by title

## When to invoke

**Trigger phrases:**
- "process the interview", "analyze the user interview", "ingest the interview"
- "onboarding interview", "user research session", "research call"
- "user feedback session", "interview with [name]"

## Architecture

Multi-dimensional analysis pipeline with 3 Sonnet analyst agents + Opus synthesis:

```
Input (transcript) → Pass 0 (Opus, inline): scaffold
Cross-interview context → 4 Neo4j queries → graph context
                ┌─────────────────────────────────────────┐
          JOURNEY (Sonnet)    SENTIMENT (Sonnet)    PRODUCT (Sonnet)
          transcript+scaffold  transcript (fresh)    transcript+scaffold+quests
          friction, aha,       emotions, confusion,  feature discovery,
          task flow, stuck     delight, frustration,  mental models,
          points, drop-off     engagement arc         unmet needs
                └──────────────┬──────────────────────┘
                    SYNTHESIS (Opus, inline)
                    → Interview Analysis Briefing
                    → Enriched insight list
```

## Cost & Resource Budget

Target per interview:
- **Bash calls**: ~6-10 (source fetch, graph batches, file writes, git)
- **Task agents**: 3 Sonnet (parallel, inline — NOT background)
- **AskUserQuestion**: 0-2 (source selection, participant info)
- **Graph batches**: 2-3 (1 context read, 1-2 artifact write batches at <=20 queries each)
- **Token-heavy**: Journey + Sentiment agents receive full transcript (~6K words each)

## What to do

### Step 0: Source selection

Determine transcript source from `$ARGUMENTS`:

**If $ARGUMENTS is a file path** (contains `/` or ends in `.txt`/`.md`/`.json`):
Read the file directly. Parse for speaker turns.

**If $ARGUMENTS is a search term** (non-empty, not a path):
Search Granola via MCP: use the `get_meetings` MCP tool to search by title/content.
If one match, use it. If multiple, present via AskUserQuestion. If none, say so.

**If $ARGUMENTS is empty**, present source picker:

```
AskUserQuestion:
  question: "Where is the interview transcript?"
  header: "Source"
  options:
    - label: "Granola recording"
      description: "Select from recent Granola meetings"
    - label: "Paste transcript"
      description: "Paste the interview text directly"
    - label: "File path"
      description: "Provide a path to a .txt, .md, or .json transcript file"
```

**For Granola source:**
Check Granola MCP availability: use `ToolSearch` with query `"granola"` to check if MCP tools are loaded.

If not available: "Granola not connected. Run `/connect granola` to set it up."

If available: use the `list_meetings` MCP tool to get recent meetings, then present via AskUserQuestion for selection. Use `get_meeting_transcript` to fetch the selected interview's transcript.

**For paste source:**
Tell the user: "Paste the interview transcript below. I'll look for speaker turns (Name: or [timestamp] patterns)."

Wait for user to paste. Parse the pasted text for structure.

**For file path source:**
Ask the user for the file path, then read it.

### Step 0.5: Gather participant info

Ask for participant details if not inferrable from transcript:

```
AskUserQuestion:
  question: "Who was interviewed? (first name or handle)"
  header: "Participant"
  options:
    - label: "Enter name"
      description: "The person being interviewed (not the researcher)"
```

Also determine:
- **Researcher**: default to user's name from `.egregore-state.json` → `name`
- **Interview type**: infer from context, or ask:

```
AskUserQuestion:
  question: "What type of interview is this?"
  header: "Type"
  options:
    - label: "Onboarding"
      description: "First-time user setup and initial experience"
    - label: "Feedback"
      description: "Existing user sharing thoughts on the product"
    - label: "Research"
      description: "Exploratory conversation about needs/workflows"
    - label: "Exit"
      description: "User leaving or churning — understanding why"
```

### Step 1: Load cross-interview context (single batch call)

Run 4 queries in a **single `bash bin/graph-batch.sh` call**:

```bash
bash bin/graph-batch.sh '[
  {"statement": "MATCH (a:Artifact) WHERE a.origin STARTS WITH '"'"'interview:'"'"' AND a.created >= datetime() - duration('"'"'P90D'"'"') RETURN a.id, a.title, a.type, a.topics, a.interviewParticipant, a.interviewDate, a.confidence ORDER BY a.created DESC LIMIT 15"},
  {"statement": "MATCH (a:Artifact) WHERE a.origin STARTS WITH '"'"'interview:'"'"' AND a.type = '"'"'friction'"'"' WITH a.title AS friction, count(*) AS mentions, collect(DISTINCT a.interviewParticipant)[..5] AS participants WHERE mentions >= 2 RETURN friction, mentions, participants ORDER BY mentions DESC LIMIT 10"},
  {"statement": "MATCH (a:Artifact) WHERE a.origin STARTS WITH '"'"'interview:'"'"' AND a.topics IS NOT NULL UNWIND a.topics AS topic WITH topic, count(DISTINCT a.interviewParticipant) AS participantCount, collect(DISTINCT a.interviewParticipant)[..5] AS participants WHERE participantCount >= 2 RETURN topic, participantCount, participants ORDER BY participantCount DESC LIMIT 10"},
  {"statement": "MATCH (q:Quest {status: '"'"'active'"'"'}) WHERE q.topics IS NOT NULL RETURN q.id, q.title, q.topics"}
]'
```

Result mapping:
- `results[0]` → Q1: Recent interview-extracted artifacts (90d)
- `results[1]` → Q2: Recurring friction points across participants
- `results[2]` → Q3: Feature/topic patterns across participants
- `results[3]` → Q4: Active quests (for linking)

**If the batch call fails**, continue without cross-interview context. It's enrichment, not required. Empty results are expected for the first few interviews — handle gracefully.

### Step 2: Pass 0 — Interview Scaffold (Opus, inline)

Read the transcript text (panel text if Granola, pasted text, or file contents). Produce a **scaffold** — a JSON array of extracted items:

```json
[
  {"id": "s1", "category": "friction", "title": "Confused by setup step 3", "brief": "Participant couldn't find where to enter API key", "gap": false},
  {"id": "s2", "category": "aha", "title": "Discovered shared memory", "brief": "Moment of clarity when they saw how memory persists", "gap": false},
  {"id": "s3", "category": "feature_gap", "title": "Wanted team dashboard", "brief": "Expected to see team activity overview", "gap": false},
  {"id": "gap1", "category": "unknown", "title": "Mentioned something about permissions", "brief": "Referenced but not elaborated", "gap": true}
]
```

Classification signals:

| Category | Signals | Example |
|----------|---------|---------|
| **friction** | struggled, confused, couldn't find, "I don't understand", repeated attempts, pauses, sighs | "Couldn't find the API key field" |
| **aha** | "oh!", "I see", excitement, sudden understanding, "that's cool", "wait, so..." | "Realized memory persists across sessions" |
| **feature_gap** | "I expected", "I wish", "where is the...", "can I...", "it would be nice" | "Expected a team activity dashboard" |
| **mental_model** | assumptions about how things work, analogies used, vocabulary choices | "Thought memory was per-session like ChatGPT" |
| **feature_discovery** | found something unexpected, "oh I didn't know", positive surprise | "Discovered /activity command by accident" |
| **suggestion** | explicit suggestions, "you should", "it would help if", "what if" | "Could you add email notifications?" |
| **unknown** | Referenced but not elaborated — gaps for transcript to fill | "Something about permissions" |

**Gap items**: Things hinted at but not elaborated. Mark with `"gap": true` — the transcript pass should look for these specifically.

Don't extract trivia. Only insights worth preserving for product development.

### Step 3: Dispatch 3 analyst agents (parallel, Sonnet)

Spawn **3 Sonnet sub-agents** in parallel using the Task tool with `model: "sonnet"` and `subagent_type: "general-purpose"`. **Do NOT use `run_in_background: true`** — run them as standard parallel Task calls so results are returned directly.

#### Agent 1: Journey Analyst

**Input**: transcript + scaffold from Pass 0 + Q1 results (recent interview artifacts) + participant's previous interview data (if any from Q1)

**Task tool prompt** (substitute actual data for placeholders):

```
You are the Journey Analyst for a user interview analysis pipeline. Your job is to map the participant's JOURNEY through the product — where they got stuck, where they had breakthroughs, what tasks they tried to complete, and where they dropped off or got lost.

## Participant

{INSERT PARTICIPANT NAME + INTERVIEW TYPE}

## Scaffold (from initial pass)

{INSERT SCAFFOLD JSON}

## Previous Interview Artifacts (from this and other participants)

{INSERT Q1 RESULTS — or "No previous interview data. This is an early interview." if empty}

## Transcript

{INSERT TRANSCRIPT}

## Instructions

Analyze the transcript through the lens of JOURNEY: what the participant tried to do, where they succeeded or failed, what path they took through the product.

Return a JSON object with this structure:

{
  "journey_stages": [
    {"stage": "...", "description": "free-form: what the participant was trying to do and what happened",
     "task": "...", "outcome": "completed|abandoned|struggled|skipped",
     "friction_points": [{"description": "...", "severity": "blocker|frustration|minor", "quote": "..."}],
     "aha_moments": [{"description": "...", "quote": "..."}],
     "time_spent_estimate": "brief|moderate|extended",
     "assistance_needed": true}
  ],
  "critical_path": [
    {"step": "...", "description": "free-form: the ideal path vs what actually happened",
     "deviation": "on_track|minor_detour|major_detour|lost"}
  ],
  "drop_off_risks": [
    {"point": "...", "description": "free-form: where and why the user might give up",
     "severity": "high|medium|low", "quote": "..."}
  ],
  "task_completion": {
    "attempted": 0,
    "completed": 0,
    "abandoned": 0,
    "success_rate_description": "free-form: overall assessment of task completion"
  },
  "enrichments": [
    {"scaffold_id": "s1|new", "category": "friction|aha|feature_gap|mental_model|feature_discovery|suggestion",
     "title": "...", "brief": "...", "evidence_quote": "...",
     "speaker": "participant|researcher",
     "severity": "blocker|frustration|minor|null",
     "stage": "which journey stage this belongs to"}
  ],
  "_raw_notes": "Multi-paragraph prose: your full read on the participant's journey. Include the narrative arc — where they started, where they ended up, what the experience felt like from their perspective. Note patterns that connect to previous interview data if available."
}

## Rules

1. Match scaffold items to transcript segments. For gap items (gap: true), try especially hard to find evidence.
2. Extract the richest quote — prioritize signal over length. Max 120 chars per quote.
3. Find items the scaffold missed — things discussed substantively but not in the scaffold. Use scaffold_id: "new".
4. Do NOT extract small talk, logistics, or off-topic tangents.
5. If a scaffold item has no transcript evidence, omit it from enrichments (don't fabricate).
6. Tag fields are optional suggestions. If no predefined tag fits, leave null and let description carry signal.
7. The _raw_notes section is critical — this is where your nuanced journey narrative goes.

Return ONLY valid JSON. No markdown fences, no explanation.
```

#### Agent 2: Sentiment Analyst

**Input**: transcript + participant context. NO scaffold, NO graph (fresh emotional read).

**Task tool prompt**:

```
You are the Sentiment Analyst for a user interview analysis pipeline. Your job is to read the EMOTIONAL texture of the interview — what the participant felt, where they were confused or delighted or frustrated. You receive NO prior analysis intentionally — we want a fresh emotional read without anchoring.

## Participant

{INSERT PARTICIPANT NAME + INTERVIEW TYPE}

## Transcript

{INSERT TRANSCRIPT}

## Instructions

Analyze the transcript through the lens of SENTIMENT: what the participant felt, how their emotions evolved, where they experienced confusion, delight, or frustration.

Return a JSON object with this structure:

{
  "emotional_arc": {
    "opening": "free-form: emotional state at the start of the interview",
    "closing": "free-form: emotional state at the end",
    "trajectory": "free-form: how emotions evolved throughout",
    "peaks": [
      {"moment": "...", "emotion": "...", "intensity": "high|medium|low", "quote": "..."}
    ]
  },
  "confusion_signals": [
    {"description": "free-form: what confused the participant and how they expressed it",
     "quote": "...", "resolution": "resolved|unresolved|workaround"}
  ],
  "delight_signals": [
    {"description": "free-form: what delighted or positively surprised the participant",
     "quote": "..."}
  ],
  "frustration_signals": [
    {"description": "free-form: what frustrated the participant and how they expressed it",
     "quote": "...", "severity": "high|medium|low"}
  ],
  "engagement_assessment": {
    "description": "free-form: how engaged the participant was overall",
    "level": "high|medium|low|mixed",
    "energy_moments": [
      {"moment": "...", "energy": "high|low", "quote": "..."}
    ]
  },
  "trust_signals": [
    {"description": "free-form: moments indicating trust or distrust in the product/team",
     "direction": "trust|distrust", "quote": "..."}
  ],
  "_raw_notes": "Multi-paragraph prose: your full emotional read of the interview. What was the participant's overall experience? Where did they feel supported vs abandoned? What was unsaid? Where did energy spike or drop? What did their tone reveal that their words didn't?"
}

## Rules

1. Read emotions from word choice, pacing, emphasis, hesitation, laughter, sighs — not just explicit statements.
2. Distinguish between expressed emotions and inferred emotions. Be explicit about which is which.
3. Look for emotional transitions — moments where the participant's state shifted.
4. The _raw_notes section is where your real analysis lives. Be honest about uncertainty.
5. Pay attention to what the participant does NOT say — avoidance can signal discomfort.
6. Note the researcher's emotional impact — did their questions help or hinder openness?

Return ONLY valid JSON. No markdown fences, no explanation.
```

#### Agent 3: Product Insights Analyst

**Input**: transcript + scaffold from Pass 0 + Q3 results (feature/topic patterns) + Q4 results (active quests)

**Task tool prompt**:

```
You are the Product Insights Analyst for a user interview analysis pipeline. Your job is to extract PRODUCT insights — what features the participant discovered or wanted, what mental models they brought, what unmet needs they expressed, and how their experience maps to active product development.

## Participant

{INSERT PARTICIPANT NAME + INTERVIEW TYPE}

## Scaffold (from initial pass)

{INSERT SCAFFOLD JSON}

## Feature/Topic Patterns Across Participants

{INSERT Q3 RESULTS — or "No cross-participant patterns yet. This is an early interview." if empty}

## Active Quests

{INSERT Q4 RESULTS — or "No active quests." if empty}

## Transcript

{INSERT TRANSCRIPT}

## Instructions

Analyze the transcript through the lens of PRODUCT: what the participant's experience reveals about features, mental models, unmet needs, and product direction.

Return a JSON object with this structure:

{
  "feature_discovery": [
    {"feature": "...", "description": "free-form: how the participant discovered/used this feature",
     "reaction": "positive|negative|neutral|confused",
     "quote": "...", "discoverability": "intuitive|guided|accidental|missed"}
  ],
  "mental_model_mismatches": [
    {"expected": "what the participant thought would happen or exist",
     "actual": "what actually happens or exists",
     "description": "free-form: the mismatch and its impact on the experience",
     "quote": "...", "severity": "high|medium|low"}
  ],
  "unmet_needs": [
    {"need": "...", "description": "free-form: what the participant needs that the product doesn't provide",
     "evidence_type": "explicit_request|implicit_behavior|workaround|comparison",
     "quote": "...", "priority_signal": "high|medium|low"}
  ],
  "suggestions": [
    {"suggestion": "...", "description": "free-form: what the participant suggested and the underlying need",
     "quote": "...", "feasibility_note": "free-form: quick assessment of implementation complexity"}
  ],
  "enrichments": [
    {"scaffold_id": "s1|new", "category": "friction|aha|feature_gap|mental_model|feature_discovery|suggestion",
     "title": "...", "brief": "...", "evidence_quote": "...",
     "speaker": "participant|researcher",
     "quest_link": "quest-id or null",
     "priority_tag": "p0_blocker|p1_important|p2_nice_to_have|null"}
  ],
  "competitive_signals": [
    {"competitor": "...", "description": "free-form: what the participant compared to or referenced",
     "quote": "...", "implication": "free-form: what this means for our product"}
  ],
  "_raw_notes": "Multi-paragraph prose: your full product read of the interview. What does this participant's experience tell us about where the product is strong, where it's weak, and where it should go next? Connect to active quests if relevant. Note cross-participant patterns if provided."
}

## Rules

1. Match scaffold items to transcript segments. For gap items (gap: true), try especially hard to find evidence.
2. Extract the richest quote — prioritize signal over length. Max 120 chars per quote.
3. Find items the scaffold missed — things discussed substantively but not in the scaffold. Use scaffold_id: "new".
4. Do NOT extract trivia or off-topic tangents.
5. If a scaffold item has no transcript evidence, omit it from enrichments (don't fabricate).
6. Tag fields are optional suggestions. If no predefined tag fits, leave null and let description carry signal.
7. For quest_link: match artifact topics to active quest topics. Only link if genuinely relevant.
8. priority_tag: p0 = blocks adoption, p1 = significantly impacts experience, p2 = would be nice.
9. The _raw_notes section is critical — this is where your nuanced product analysis goes.

Return ONLY valid JSON. No markdown fences, no explanation.
```

**Parse all 3 agent results**: Extract the JSON from each response. If an agent returns invalid JSON or fails, log the failure and continue with whatever agents succeeded. The synthesis step works with partial input.

### Step 4: Synthesis (Opus, inline)

Read the 3 agent outputs + scaffold. Produce two things:

#### 1. Enriched insight list

For each scaffold item (and new items from enrichments), merge dimensional data from all three agents:

- **From Journey**: friction points, aha moments, task completion, drop-off risks, stage context
- **From Sentiment**: emotional peaks, confusion/delight/frustration signals, engagement level
- **From Product**: feature discovery, mental model mismatches, unmet needs, quest links, priority

Each merged insight gets:
- `category`: from scaffold (or enrichment for new items)
- `title`: from scaffold (or enrichment)
- `content`: synthesized from scaffold brief + Journey context + Product context
- `severity`: from Journey (blocker/frustration/minor) or Product (p0/p1/p2)
- `emotional_context`: from Sentiment — what the participant felt at this moment
- `evidence_quote`: best quote from any agent
- `speaker`: "participant" or "researcher"
- `topics`: 2-5 tags derived from content
- `stage`: from Journey — where in the journey this occurred
- `quest_link`: from Product — linked quest if relevant
- `priority_tag`: from Product (p0_blocker/p1_important/p2_nice_to_have)
- `cross_participant`: boolean — does this echo a pattern from Q2/Q3?
- `confidence`: based on evidence strength (0.9 = explicit + emotional alignment, 0.7 = explicit only, 0.5 = inferred)

Separate **action items** (things the researcher committed to) from insights. Actions don't become Artifact files.

#### 2. Interview Analysis Briefing

Synthesize all agent outputs into a coherent briefing document:

**Meta-Analysis synthesis guidance:**

Write 3-5 paragraphs of opinionated analysis. Not a summary — a reading of the interview that tells someone something they wouldn't get from skimming the transcript.

Structure around four lenses:

1. **Heart of the interview.** What was this really about? Not the interview guide — the actual gravitational center. What is this participant struggling with, excited about, or trying to tell us? First paragraph, get there fast.

2. **Journey assessment.** How did the participant's experience map to what we designed? Where did reality diverge from intent? What was the critical path and where did it break? Reference specific friction points and aha moments.

3. **Emotional read.** What did the participant FEEL? Not just what they said — what their tone, pace, energy, and word choice revealed. Where did we earn trust and where did we lose it? What went unsaid?

4. **Product implications.** What should change based on this interview? Be specific — not "improve onboarding" but "step 3 needs a visual indicator for the API key field because 2/3 participants missed it." Connect to active quests. Distinguish blockers from nice-to-haves.

**Register:** A researcher briefing the team. Direct, evidence-based, doesn't over-generalize from one participant but names what's worth paying attention to.

**Anti-patterns:**
- "The interview covered several areas..." → you have nothing to say
- Restating what's in the insight list → the list exists for that
- Equal weight to everything discussed → prioritize ruthlessly
- "We should consider improving..." → who, what, by when, or don't say it
- Over-generalizing from one participant → "this participant experienced X" not "users experience X"

```markdown
# Interview Analysis: {Participant} — {Type} Interview

**Date**: YYYY-MM-DD
**Participant**: {name}
**Researcher**: {researcher}
**Type**: {onboarding|feedback|research|exit}
**Source**: {Granola (doc-id) | file path | pasted}
**Emotional Arc**: {opening} → {closing}
**Engagement**: {level}

## Meta-Analysis

{3-5 paragraphs — heart of the interview, journey assessment, emotional read, product implications. See guidance above.}

## Journey Map

{From Journey analyst — stage by stage}

| Stage | Task | Outcome | Friction | Aha | Time |
|-------|------|---------|----------|-----|------|
| ... | ... | completed/abandoned | count | count | brief/extended |

### Critical Path

{From Journey analyst}
- {step}: {on_track|deviation} — {description}

### Drop-Off Risks

{From Journey analyst}
- **{point}** ({severity}): {description}
  > "{quote}"

## Friction Points

{Merged from all analysts}

| # | Friction Point | Severity | Stage | Emotional Signal | Evidence |
|---|---------------|----------|-------|-----------------|----------|
| 1 | ... | blocker | ... | frustration | "quote" |

## Aha Moments

{From Journey + Sentiment}

| # | Moment | Stage | Emotional Signal | Evidence |
|---|--------|-------|-----------------|----------|
| 1 | ... | ... | delight | "quote" |

## Feature Discovery

{From Product analyst}

| Feature | Reaction | Discoverability | Evidence |
|---------|----------|-----------------|----------|
| ... | positive | accidental | "quote" |

## Mental Model Mismatches

{From Product analyst}

| Expected | Actual | Severity | Evidence |
|----------|--------|----------|----------|
| ... | ... | high | "quote" |

## Unmet Needs & Suggestions

{From Product analyst}

| Need/Suggestion | Priority | Evidence Type | Evidence |
|----------------|----------|--------------|----------|
| ... | p1_important | explicit_request | "quote" |

## Internal Tensions

{Where analytical lenses DISAGREE — this section is critical signal}
When Opus detects contradictions between agents (e.g., Journey says task completed but Sentiment reads frustration, or Product says feature discovered but Journey shows it was missed):
- **{topic}**: {Agent A reads as X}, but {Agent B reads as Y} — {implication}

If no inter-agent tensions exist, omit this section.

## Insights Extracted

{List of insights with confidence + quest links}

| # | Category | Title | Confidence | Priority | Quest |
|---|----------|-------|------------|----------|-------|
| 1 | friction | ... | 0.9 | p0_blocker | quest-id |

## Open Questions

{Unresolved from the interview — things to explore in follow-ups}
- {question}

## Participant Journey Note

{Brief note for memory/research/participants/{slug}.md — track this person's journey across sessions}
```

#### 3. Detect inter-agent tensions

Specifically look for these contradiction patterns:
- Journey says "completed" but Sentiment reads frustration at that stage → tension
- Journey says "abandoned" but Sentiment reads engagement/curiosity → tension
- Product says feature "discovered" but Journey shows participant missed it → tension
- Sentiment reads "delight" but Product notes a mental model mismatch at that moment → tension
- Journey reports "blocker" severity but Sentiment reads only mild frustration → tension

Record these in the "Internal Tensions" section. These disagreements ARE signal.

### Step 5: Present proposal

Show the meta-analysis preview + merged insights. Same interaction model as meeting pipeline.

```
From interview with {Participant} ({type}, {date}):
Emotional arc: {opening} → {closing} | Engagement: {level}

  {2-3 sentence meta-analysis preview — heart of the interview + key product implication}

  ◉ Friction: {title}                                    [{confidence}]
    "{quote}" — participant
    Severity: {blocker|frustration|minor} | Stage: {stage}
    Priority: {p0|p1|p2}
    → {quest-id}

  ◉ Aha: {title}                                         [{confidence}]
    "{quote}" — participant
    Stage: {stage}

  ◉ Feature Gap: {title}                                 [{confidence}]
    "{quote}" — participant
    Priority: {p0|p1|p2}
    * cross-participant (seen in N interviews)
    → {quest-id}

  ◉ Mental Model: {title}                                [{confidence}]
    Expected: {expected} → Actual: {actual}
    Severity: {high|medium|low}

  Tensions:
    * "{topic}" — Journey reads as {X}, but Sentiment reads as {Y}

  Actions:
    * {researcher} — {action}

Adjust? (y/edit/skip)
```

Display rules:
- Emotional arc + engagement at top
- Meta-analysis preview: 2-3 sentences from "heart" + "product implications" lenses
- `[0.9]` confidence score right-aligned after title
- Evidence quote with speaker attribution
- Severity + stage + priority on context lines
- `* cross-participant` flag when pattern appears in Q2/Q3
- `→ quest-id` for linked quests
- Tensions section after insights
- Actions listed separately at the end

Wait for user response:
- **y** or empty → proceed to write artifacts
- **edit** → user modifies, then proceed
- **skip** → abort this interview

### Step 6: Create artifacts + interview analysis

**First, ensure all output directories exist:**
```bash
mkdir -p memory/research/interviews memory/research/participants memory/knowledge/findings memory/knowledge/patterns
```

#### Step 6a: Write Interview Analysis Briefing

Write the briefing file:
```bash
cat > "memory/research/interviews/{YYYY-MM-DD}-{participant-slug}.md" << 'BRIEFINGEOF'
{INTERVIEW ANALYSIS BRIEFING CONTENT from Step 4}
BRIEFINGEOF
```

File naming: `{YYYY-MM-DD}-{participant-slug}.md` where slug is lowercase, hyphens, max 50 chars, derived from participant name.

#### Step 6b: Update interview index

Append to `memory/research/interviews/index.md`:
```bash
# Count insights
INSIGHT_COUNT=...
# Append row
echo "| {YYYY-MM-DD} | {participant} | {researcher} | $INSIGHT_COUNT | [{participant-slug}]({YYYY-MM-DD}-{participant-slug}.md) |" >> memory/research/interviews/index.md
```

#### Step 6c: Write/update participant file

Check if `memory/research/participants/{participant-slug}.md` exists.

**If new participant:**
```bash
cat > "memory/research/participants/{participant-slug}.md" << 'PARTICIPANTEOF'
# {Participant Name}

**First interview**: {YYYY-MM-DD}
**Interview count**: 1
**Type**: {onboarding|feedback|research|exit}

## Journey

| Date | Type | Key Friction | Key Aha | Engagement |
|------|------|-------------|---------|------------|
| {date} | {type} | {top friction} | {top aha} | {level} |

## Notes

{Participant journey note from briefing}
PARTICIPANTEOF
```

**If existing participant:**
Append a new row to the Journey table and update interview count.

#### Step 6d: Write individual artifact files

For each insight (friction, aha, feature_gap, mental_model, feature_discovery, suggestion — NOT actions):

```bash
cat > "memory/knowledge/{category_dir}/{YYYY-MM-DD}-{slug}.md" << 'ARTIFACTEOF'
# {Title}

**Date**: {YYYY-MM-DD}
**Author**: interview
**Category**: {category}
**Confidence**: {0.0-1.0}
**Source**: Interview with {participant}
**Topics**: {topic1}, {topic2}
**Participant**: {participant}
**Interview Type**: {type}
**Priority**: {p0_blocker|p1_important|p2_nice_to_have}
**Severity**: {blocker|frustration|minor}

## Context

{What was happening when this insight emerged — from Journey stage context}

## Content

{Synthesized from scaffold + Journey + Product — the actual insight}

## Emotional Context

{From Sentiment — what the participant felt at this moment}

## Evidence

> "{evidence_quote}" — {speaker}

## Related

- Quest: {quest-id}
- Cross-participant: {yes/no — seen in N other interviews}
ARTIFACTEOF
```

Category to directory mapping:
- `friction` → `knowledge/findings/`
- `aha` → `knowledge/findings/`
- `feature_gap` → `knowledge/findings/`
- `mental_model` → `knowledge/patterns/`
- `feature_discovery` → `knowledge/findings/`
- `suggestion` → `knowledge/findings/`

Omit sections that have no data.

#### Step 6e: Batch Neo4j operations

Build a JSON array of queries for `bash bin/graph-batch.sh` calls.

**Batch limit: API accepts max 20 queries per `graph-batch.sh` call.** Count total queries before executing. If >20, split into chunks of <=20 and execute sequentially.

**Interview node** (new):
```json
{
  "statement": "MERGE (i:Interview {id: $interviewId}) SET i.title = $title, i.date = date($date), i.participant = $participant, i.researcher = $researcher, i.interviewType = $interviewType, i.source = $source, i.emotionalArc = $emotionalArc, i.engagementLevel = $engagementLevel, i.frictionCount = $frictionCount, i.ahaCount = $ahaCount, i.featureGapCount = $featureGapCount, i.filePath = $filePath, i.artifactCount = $artifactCount, i.processed = datetime() RETURN i.id",
  "parameters": {
    "interviewId": "interview-{YYYY-MM-DD}-{participant-slug}",
    "title": "Interview: {participant} ({type})",
    "date": "{YYYY-MM-DD}",
    "participant": "{participant name}",
    "researcher": "{researcher name}",
    "interviewType": "{onboarding|feedback|research|exit}",
    "source": "{granola:doc-id | file:path | paste}",
    "emotionalArc": "{opening} → {closing}",
    "engagementLevel": "{high|medium|low|mixed}",
    "frictionCount": 0,
    "ahaCount": 0,
    "featureGapCount": 0,
    "filePath": "research/interviews/{YYYY-MM-DD}-{participant-slug}.md",
    "artifactCount": 0
  }
}
```

**Interview → Person (researcher) relationship** (CONDUCTED_BY):
```json
{
  "statement": "MATCH (i:Interview {id: $interviewId}) MATCH (p:Person {name: $personName}) MERGE (i)-[:CONDUCTED_BY]->(p)",
  "parameters": {"interviewId": "...", "personName": "{researcher graph name}"}
}
```

**Artifact nodes** (enhanced with interview-specific properties):
```json
{
  "statement": "MERGE (a:Artifact {id: $artifactId}) SET a.title = $title, a.type = $category, a.topics = $topics, a.filePath = $filePath, a.origin = $origin, a.interviewParticipant = $participant, a.interviewDate = $interviewDate, a.confidence = $confidence, a.speaker = $speaker, a.priorityTag = $priorityTag, a.severity = $severity, a.stage = $stage, a.crossParticipant = $crossParticipant, a.created = datetime() WITH a OPTIONAL MATCH (p:Person {name: $author}) FOREACH (_ IN CASE WHEN p IS NOT NULL THEN [1] ELSE [] END | MERGE (a)-[:CONTRIBUTED_BY]->(p)) RETURN a.id",
  "parameters": {
    "artifactId": "{YYYY-MM-DD}-{slug}",
    "title": "{title}",
    "category": "{category}",
    "topics": ["topic1", "topic2"],
    "filePath": "knowledge/{category_dir}/{YYYY-MM-DD}-{slug}.md",
    "origin": "interview:{interviewId}",
    "participant": "{participant name}",
    "interviewDate": "{YYYY-MM-DD}",
    "confidence": 0.9,
    "speaker": "participant",
    "priorityTag": "p1_important",
    "severity": "frustration",
    "stage": "setup",
    "crossParticipant": false,
    "author": "{researcher name}"
  }
}
```

**Artifact → Interview relationships** (FROM_INTERVIEW):
```json
{
  "statement": "MATCH (a:Artifact {id: $artifactId}), (i:Interview {id: $interviewId}) MERGE (a)-[:FROM_INTERVIEW]->(i)",
  "parameters": {"artifactId": "...", "interviewId": "..."}
}
```

**Quest linking** — same pattern as meeting pipeline:
```json
{
  "statement": "MATCH (a:Artifact {id: $artifactId}), (q:Quest {id: $questId}) MERGE (a)-[:PART_OF]->(q)",
  "parameters": {"artifactId": "...", "questId": "..."}
}
```

Execute the batch:
```bash
bash bin/graph-batch.sh '[{...}, {...}, ...]'
```

Show progress:
```
Creating artifacts...

  [1/5] ✓ Writing research/interviews/{date}-{slug}.md (analysis briefing)
  [2/5] ✓ Writing knowledge/findings/{date}-{slug}.md (×N insights)
  [3/5] ✓ Updated participant file
  [4/5] ✓ Indexed in knowledge graph (batch: N queries)
  [5/5] ✓ Linked to N quests
```

### Step 7: Confirmation TUI

Display the confirmation box. ~72 char width. Sigil: `INTERVIEW`.

**Boundary handling (CRITICAL)** — No sub-boxes. Only 4 line patterns:

1. **Top**: `┌` + 70x`─` + `┐` (72 chars)
2. **Separator**: `├` + 70x`─` + `┤` (72 chars)
3. **Content**: `│` + 2 spaces + text + pad to 68 chars + `│` (72 chars)
4. **Bottom**: `└` + 70x`─` + `┘` (72 chars)

```
┌──────────────────────────────────────────────────────────────────────┐
│  INTERVIEW                                          cem · Feb 19    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Interview: {Participant} ({type})                                   │
│  Researcher: {name}                                                  │
│  Emotional Arc: {opening} → {closing} | Engagement: {level}         │
│                                                                      │
│  N insights extracted:                                               │
│                                                                      │
│  ◉ Friction: {title}                             [{confidence}]     │
│    "{quote}" — participant                                           │
│    Severity: {severity} | Priority: {priority}                       │
│    → {quest-id}                                                      │
│                                                                      │
│  ◉ Aha: {title}                                  [{confidence}]     │
│    "{quote}" — participant                                           │
│                                                                      │
│  ◉ Feature Gap: {title}                          [{confidence}]     │
│    * cross-participant                                               │
│    Priority: {priority}                                              │
│    → {quest-id}                                                      │
│                                                                      │
│  Analysis: memory/research/interviews/{date}-{slug}.md              │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### After confirmation

Run the `/save` flow to commit and push changes.

---

## Graph Schema Reference

### Interview Node

```
(Interview {
  id,                    // "interview-YYYY-MM-DD-participant-slug"
  title,                 // "Interview: {participant} ({type})"
  date,                  // date
  participant,           // participant name
  researcher,            // researcher name
  interviewType,         // onboarding|feedback|research|exit
  source,                // "granola:{doc-id}" | "file:{path}" | "paste"
  emotionalArc,          // "{opening} → {closing}"
  engagementLevel,       // high|medium|low|mixed
  frictionCount,         // int
  ahaCount,              // int
  featureGapCount,       // int
  filePath,              // relative path to briefing
  artifactCount,         // int
  processed              // datetime
})
```

### Relationships

```
(Interview)-[:CONDUCTED_BY]->(Person)        // researcher
(Artifact)-[:FROM_INTERVIEW]->(Interview)    // insight source
(Artifact)-[:CONTRIBUTED_BY]->(Person)       // researcher as author
(Artifact)-[:PART_OF]->(Quest)               // quest linking
```

### Artifact Extensions

Artifacts from interviews get these additional optional properties:
- `interviewParticipant`: participant name
- `interviewDate`: date string
- `priorityTag`: p0_blocker|p1_important|p2_nice_to_have
- `severity`: blocker|frustration|minor
- `stage`: journey stage name
- `crossParticipant`: boolean

## Extraction Schema Reference

| Dimension | Source | Description |
|-----------|--------|-------------|
| **category** | Scaffold (Pass 0) | friction / aha / feature_gap / mental_model / feature_discovery / suggestion |
| **title** | Scaffold (Pass 0) | Short descriptive title |
| **content** | Synthesis merge | Full insight with context |
| **severity** | Journey analyst | blocker / frustration / minor |
| **emotional_context** | Sentiment analyst | What participant felt at this moment |
| **evidence_quote** | Best from any agent | Supporting quote |
| **speaker** | Agent enrichment | "participant" or "researcher" |
| **topics** | Synthesis merge | 2-5 tags for quest linking |
| **stage** | Journey analyst | Journey stage name |
| **quest_link** | Product analyst | Linked quest if relevant |
| **priority_tag** | Product analyst | p0_blocker / p1_important / p2_nice_to_have |
| **cross_participant** | Synthesis + Q2/Q3 | Seen in other interviews? |
| **confidence** | Synthesis merge | 0.9 (explicit + emotional) / 0.7 (explicit) / 0.5 (inferred) |

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Granola not installed (Granola source) | Stop with clear message — suggest paste or file path instead |
| Empty transcript | "No content found. Try pasting the transcript or providing a file path." |
| Very short transcript (<500 chars) | Warn: "Transcript is very short. Analysis will be limited." Still process. |
| Participant name unknown | Use "anonymous-{date}" as slug. Ask researcher to name later. |
| Researcher not in graph | Create Person node during graph batch |
| Neo4j unavailable | Still create files, skip graph ops. Warn: "Graph offline — files saved, will sync on next /save" |
| No quest matches | Create artifacts without quest links (no warning needed) |
| Journey agent fails | Fall back to scaffold-only. Omit journey map from briefing. |
| Sentiment agent fails | Omit emotional context from artifacts and briefing. |
| Product agent fails | Omit feature discovery / mental models. Keep friction + aha from Journey. |
| All agents fail | Fall back to scaffold-only (confidence 0.5 for all items) |
| Agent returns invalid JSON | Same as agent failure — continue with whatever agents succeeded |
| Memory symlink missing | Error: "Run /setup first — memory not linked" |
| Cross-interview queries return empty | Expected for first few interviews. Pipeline handles gracefully. |
| Same participant interviewed twice | Append to existing participant file, new briefing file per interview |
| Transcript has no clear speaker turns | Treat entire text as single-speaker (participant). Note in briefing. |
| Non-English transcript | Process normally — agents handle multilingual input. Note language in briefing. |

## Full Interactive Example

```
> /ingest user-interview

Where is the interview transcript?
  1. Granola recording
  2. Paste transcript
  3. File path

> 2

Paste the interview transcript below. I'll look for speaker turns.

> [user pastes transcript]

Who was interviewed?
> Sarah

What type of interview is this?
  1. Onboarding
  2. Feedback
  3. Research
  4. Exit

> 1

Analyzing interview...

  Pass 0: Scanning transcript...
  Loading cross-interview context (4 queries)...
  Dispatching analysts...
    → Journey Analyst (Sonnet)...
    → Sentiment Analyst (Sonnet)...
    → Product Insights Analyst (Sonnet)...
  Synthesizing results...

From interview with Sarah (onboarding, 2026-02-19):
Emotional arc: curious → frustrated → relieved | Engagement: high

  Sarah's core struggle was with the mental model — she expected
  per-session memory like ChatGPT and didn't realize the graph
  persists. Once that clicked (step 5), everything accelerated.
  The API key field in step 3 is a known friction point (3rd
  participant to stumble here).

  ◉ Friction: API key field hidden in setup                [0.9]
    "I looked everywhere for it" — participant
    Severity: blocker | Stage: setup-step-3
    Priority: p0_blocker
    * cross-participant (seen in 3 interviews)
    → onboarding-flow

  ◉ Aha: Memory persists across sessions                   [0.9]
    "wait, so it remembers everything?" — participant
    Stage: first-activity-check

  ◉ Mental Model: Expected per-session memory              [0.7]
    Expected: memory resets each session → Actual: graph persists
    Severity: medium

  ◉ Feature Gap: No visual progress indicator              [0.7]
    "I didn't know how far along I was" — participant
    Priority: p1_important

  Tensions:
    * "Setup completion" — Journey reads as abandoned (left step 3),
      but Sentiment detected persistent curiosity throughout

  Actions:
    * cem — prototype progress indicator for onboarding

Adjust? (y/edit/skip)
> y

Creating artifacts...

  [1/5] ✓ Writing research/interviews/2026-02-19-sarah.md
  [2/5] ✓ Writing knowledge/findings/2026-02-19-api-key-field-hidden.md
        ✓ Writing knowledge/findings/2026-02-19-memory-persists-aha.md
        ✓ Writing knowledge/patterns/2026-02-19-per-session-memory-model.md
        ✓ Writing knowledge/findings/2026-02-19-no-progress-indicator.md
  [3/5] ✓ Created participant file: sarah
  [4/5] ✓ Indexed in knowledge graph (batch: 10 queries)
  [5/5] ✓ Linked to 1 quest

┌──────────────────────────────────────────────────────────────────────┐
│  INTERVIEW                                          cem · Feb 19    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Interview: Sarah (onboarding)                                       │
│  Researcher: cem                                                     │
│  Emotional Arc: curious → frustrated → relieved                      │
│  Engagement: high                                                    │
│                                                                      │
│  4 insights extracted:                                               │
│                                                                      │
│  ◉ Friction: API key field hidden in setup           [0.9]          │
│    "I looked everywhere for it" — participant                        │
│    Severity: blocker | Priority: p0_blocker                          │
│    * cross-participant (3 interviews)                                │
│    → onboarding-flow                                                 │
│                                                                      │
│  ◉ Aha: Memory persists across sessions              [0.9]          │
│    "wait, so it remembers everything?"                               │
│                                                                      │
│  ◉ Mental Model: Expected per-session memory         [0.7]          │
│    Expected: per-session → Actual: persistent graph                  │
│                                                                      │
│  ◉ Feature Gap: No visual progress indicator         [0.7]          │
│    Priority: p1_important                                            │
│                                                                      │
│  Analysis: memory/research/interviews/2026-02-19-sarah.md           │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

## Next

Run `/save` to share, or `/activity` to see the knowledge graph impact.
