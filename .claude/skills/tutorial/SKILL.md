---
name: tutorial
description: "Interactive walkthrough of Egregore's core loop — /activity, /reflect, and /quest or /add — with adaptive questions and real artifacts. Use for /tutorial or 'walk me through Egregore'."
---

Interactive walkthrough of Egregore's core loop.

## When to invoke

User says: "/tutorial", "walk me through Egregore", "show me how this works", "teach me the core loop", or is a new user ready to try the `/activity` → `/reflect` → `/quest`/`/add` loop hands-on.
Not this: first-time identity/org setup → `/onboarding`

Arguments: $ARGUMENTS

## Tagging rule (applies to ALL artifacts and quests created during the tutorial)

Every artifact and quest created during the tutorial MUST include `tutorial-generated` in its topics array. This tag lets `/handoff`, `/activity`, and other commands distinguish tutorial outputs from organic session work. Handoffs exclude `tutorial-generated` artifacts from the Session Artifacts section.

This applies to: Step 2 reflect artifacts, Step 3 quests, Step 3 source artifacts, and the Step 4 journey log.

**CRITICAL: Suppress raw output.** Never show raw JSON to the user. All `bin/graph.sh` and `bin/notify.sh` calls MUST capture output in a variable and only show formatted status lines.

## Mode detection

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

**Local mode** (`mode === "local"`): Skip ALL `bin/graph.sh` and `bin/notify.sh` calls — do NOT run them. Do NOT show any graph-related messaging (knowledge graph, Neo4j, nodes, relationships, edges, "linked", "synced to graph", etc.). The tutorial in local mode is markdown-only: it creates artifact files in `memory/knowledge/{findings,patterns,decisions}/`, quest files in `memory/quests/`, and a journey log. No graph queries, no node creation, no edge counts. When the tutorial talks about what the team knows, refer to "shared memory" or "memory files" — not "the knowledge graph." Show `(feature of hosted version — coming soon)` where a graph-only capability is referenced.

## Step 0: State Check

Read `.egregore-state.json`. Extract `usage_type`, `tutorial_complete`, and any existing tutorial state (`domain`, `stage`, `team_or_solo`).

**Check for harvest data from `/onboarding`:** If the state file contains `onboarding.harvest_rounds`, the user already answered identity and connection questions during onboarding. Extract and map this data so Step 1 can skip redundant questions:
- `role` from harvest round 1 → can inform `domain` (e.g., `engineering` → `software`, `research` → `research`)
- `focus` from harvest round 2 → contextual seed for Step 2 questions

If `domain` is already set in state (from harvest or a previous tutorial run), Step 1 will skip Q1 and use the stored value.

**Detect `usage_type`** if missing:
1. Check `egregore.json` for `org_name` — if set, it's a group context
2. Check `.egregore-state.json` for onboarding path clues:
   - Founder who set up the org → `founder_group`
   - Joiner who joined an existing org → `joiner_group`
   - `onboarding.type` = `"joiner"` → `joiner_group`
   - No org → `personal`
3. If ambiguous, default to `personal`
4. Save detected `usage_type` to `.egregore-state.json`

**`personal_agent`** variant: if `usage_type` is `personal` and the user mentioned agents/automation during onboarding (check state for keywords), use `personal_agent`. Otherwise stick with `personal`.

**Reset handling:** If `$ARGUMENTS` is `reset`, clear `tutorial_complete`, `domain`, `stage`, `team_or_solo`, `tutorial_step` from `.egregore-state.json`. Then proceed from Step 1.

**Already complete:** If `tutorial_complete` is `true` and no `reset` argument:
> You've already run through the tutorial. Run `/tutorial reset` to do it again, or just ask me anything.

Then stop.

**Resume:** If `tutorial_step` exists in state but `tutorial_complete` is not true, resume from that step. Use stored `domain`, `stage`, etc. to skip re-asking earlier questions.

---

## Step 1: Orient — `/activity` checkpoint

Save `tutorial_step: 1` to state.

### Questions

**Skip logic:** If `domain` already exists in state (set by `/onboarding` harvest or a previous tutorial run), skip Q1 entirely and use the stored value. If `stage` also exists, skip Q2 as well. Jump directly to "Run `/activity`" below.

If `domain` was inferred from harvest `role` (e.g., `engineering` → `software`), confirm briefly: "Based on your role, I'll tailor this to software work." Then skip Q1.

Use AskUserQuestion with 2 sequential questions (only for questions not already answered).

**Q1** — varies by `usage_type`:

- **founder_group / joiner_group**:
  ```
  question: "What does your team work on?"
  header: "Your work"
  options:
    - label: "We build software"
      description: "Product development, engineering, shipping code"
    - label: "Research & knowledge"
      description: "Exploring ideas, papers, analysis, documentation"
    - label: "Exploring something new"
      description: "Early-stage, figuring things out"
  ```

- **personal / personal_agent**:
  ```
  question: "What are you working on?"
  header: "Your work"
  options:
    - label: "Building software"
      description: "Product development, side projects, shipping code"
    - label: "Research & knowledge"
      description: "Exploring ideas, papers, analysis, documentation"
    - label: "Exploring something new"
      description: "Early-stage, figuring things out"
  ```

Save the answer as `domain` in state. Map: "We build software"/"Building software" → `software`, "Research & knowledge" → `research`, "Exploring something new" → `exploring`. Freeform → `other`.

**Q2** — follow-up keyed to Q1 answer:

- **software**:
  ```
  question: "What stage?"
  header: "Stage"
  options:
    - label: "Early product"
      description: "Building the first version, finding PMF"
    - label: "Scaling"
      description: "Growing users, team, or infrastructure"
    - label: "Maintenance"
      description: "Stable product, iterating and improving"
  ```

- **research**:
  ```
  question: "What domain?"
  header: "Domain"
  options:
    - label: "Technical"
      description: "Engineering, systems, architecture"
    - label: "Scientific"
      description: "Academic research, experiments, papers"
    - label: "Design"
      description: "Product design, UX, creative work"
    - label: "Mixed"
      description: "Cross-disciplinary, a bit of everything"
  ```

- **exploring**:
  ```
  question: "How long have you been at it?"
  header: "Duration"
  options:
    - label: "Just starting"
      description: "Days or weeks in"
    - label: "Months in"
      description: "Some traction, still finding the path"
    - label: "Ongoing"
      description: "Long-running exploration, no end date"
  ```

- **other** (freeform from Q1): Skip Q2.

Save Q2 answer as `stage` in state.

### Run `/activity`

Run the real activity data fetch:

```bash
bash bin/activity-data.sh
```

Render the activity dashboard following the `/activity` command spec. For a new user it will be mostly empty.

**After the dashboard**, narrate what each section will show. Keyed to `usage_type`:

- **founder_group**: "Right now it's quiet — but as your team starts using `/handoff` and `/reflect`, this fills up. You'll see who's working on what, what's waiting for you, and which quests are active."
- **joiner_group**: "This is where you'll see what happened while you were away — handoffs to read, questions to answer, quests to join."
- **personal / personal_agent**: "This is your command center. Sessions, insights, and quests — all in one place. Gets more interesting the more you use it."

Then:

> `/activity` is always your starting point.

Save `tutorial_step: 2` to state.

---

## Step 2: Capture — `/reflect` checkpoint

### Questions — graph-seeded, not canned

Step 1 already fetched the activity data. Use it. The questions should reference the user's REAL sessions, handoffs, and quests — not generic categories.

**Q1** — seeded from activity data:

Analyze the user's recent sessions, handoffs, and quests from the Step 1 activity data. Cluster by theme (2-3 clusters max). Generate a question and options from the actual data.

```
question: "You've had sessions on {theme1} and {theme2} recently. What's the throughline?"
header: "Throughline"
```

Options should be 2-3 specific threads drawn from the session topics, plus freeform. Example for a user with architecture + UX + onboarding sessions:
```
options:
  - label: "{theme1 cluster name}"
    description: "Sessions on {topic1}, {topic2} — what connects them?"
  - label: "{theme2 cluster name}"
    description: "Sessions on {topic3}, {topic4} — what's emerging?"
  - label: "Something else"
    description: "A thought that doesn't fit the recent sessions"
```

**For new users with no sessions:** Fall back to the domain context from Step 1:
```
question: "What's the hardest thing you're working through right now?"
header: "Hardest"
options:
  - label: "A problem I keep hitting"
    description: "Something that blocks progress repeatedly"
  - label: "A question without an answer"
    description: "Something I need to figure out"
  - label: "A bet I'm not sure about"
    description: "A direction I've committed to but have doubts"
```

**Q2** — context capture, always fires:

Q1 gives the topic. Q2 gives the substance. Together they produce enough material for a real artifact. Never skip Q2.

Generate Q2 from Q1's answer — push toward the specific insight, tension, or realization. The question should make the user articulate something they haven't said yet.

```
question: "{Context-specific follow-up drawn from Q1}"
header: "Capture"
```

Options: 2-3 concrete angles on what the user said in Q1. Each option should surface a different dimension — what changed, what's blocking, what they realized. Draw from the session data and Q1 answer, not abstract categories.

Example — if Q1 answer was about architecture sessions:
```
options:
  - label: "The tradeoff I keep hitting"
    description: "There's a tension in the architecture work that won't resolve"
  - label: "What I realized this week"
    description: "Something clicked across the recent sessions"
  - label: "What the team doesn't see yet"
    description: "A perspective that hasn't surfaced in handoffs"
```

### Run the Quick Reflect flow

Using the user's Q1 and Q2 answers, construct a reflection. This is the real `/reflect` flow (Quick mode) — follow Steps 3-8 of the `/reflect` command spec:

1. **Auto-classify** the content based on Q1+Q2 answers. Use classification signals from `/reflect` spec. Default to `finding`.
2. **Extract**: Title from Q1 topic + user's freeform elaboration. Content from Q1+Q2 combined. Context from Step 1 data (domain, stage). **Always include `tutorial-generated` in the topics array** — this tags the artifact so handoffs and other commands can distinguish tutorial artifacts from organic session work.
3. **Relation detection**: Run the quest link and related artifact queries from `/reflect` Step 4.
4. **Auto-confirm**: During tutorial, skip the `y/edit/skip` proposal. Just show what's being created and proceed. The flow should not break for confirmation — this is a guided experience, not a dialog.
5. **Create file**: Write to `memory/knowledge/{category}s/{YYYY-MM-DD}-{slug}.md` using the `/reflect` file format.
6. **Neo4j**: Create Artifact node, link to author + any quests.
7. **Auto-save**: Commit + push memory repo changes.
8. **Render TUI confirmation**: Same format as `/reflect` — 72-char box with sigil, artifact details, status footer.

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◎ REFLECTION                                     {author} · {date}  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ {Type}: {Title}                                                   │
│    → {quest link if any}                                             │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

After the TUI:

> That's your first artifact. It's in the knowledge graph now — linked to your name, today's date, and the topics it touches. Over time, `/reflect` gets smarter: it sees your past work and surfaces what's worth thinking about.

**Important:** The artifact content is about their REAL work thought (from Q1+Q2), not meta-commentary about Egregore.

Save `tutorial_step: 3` to state.

---

## Step 3: Connect — path-dependent checkpoint

### Founder/group path → Create a quest

**Q1**: Use AskUserQuestion.
```
question: "Based on what you just captured — what's the bigger question behind it?"
header: "Quest"
```

Generate 2-3 quest title suggestions derived from Steps 1+2 context. For example, if they talked about a process breaking down in software:
- "How might we make [process] more reliable?"
- "What does good [domain] look like for us?"

These become the AskUserQuestion options. Each option's description should be 1 sentence explaining the quest scope.

**Q2**:
```
question: "Who else on the team thinks about this?"
header: "Who"
options:
  - label: "The whole team"
    description: "Everyone's affected"
  - label: "A few people"
    description: "I know who cares about this"
  - label: "Just me for now"
    description: "I'll invite others later"
```

**If "A few people"** → query Neo4j for team members (suppress raw output — capture in variable):

```bash
RESULT=$(bash bin/graph.sh query "MATCH (p:Person) RETURN p.name AS name" 2>/dev/null)
```

Then use AskUserQuestion with multiSelect to let them pick:

```
question: "Who should know about this quest?"
header: "Hand off to"
multiSelect: true
options: (one per Person node, max 4)
  - label: "{name}"
    description: "Link them to the quest; notification is offered separately"
```

Freeform is always available for names not in the graph.

After selection:
- **Person exists in graph** → add the INVOLVES relationship in Neo4j: `MATCH (q:Quest {id: $slug}), (p:Person {name: $name}) CREATE (q)-[:INVOLVES]->(p)`. After the quest is saved, follow `.claude/context/notification-consent.md` and offer a separate exact notification to that person.
- **Person typed in freeform (not in graph)** → acknowledge: "{name} isn't on this egregore yet. The quest will be waiting for them when they join." Do NOT create a Person node.

**If "The whole team"** → after the quest is saved, prepare
`bash bin/notify.sh plan group "New quest: {title} — {question}"`, then show a
separate exact Send / Edit / Cancel checkpoint.

**If "Just me for now"** → no notification, proceed silently.

**Then:** Run the real `/quest new` flow:
1. Generate a slug from the quest title (lowercase, hyphens, max 30 chars)
2. Create `memory/quests/{slug}.md` with proper frontmatter (title, slug, status: active, started: today, started_by: author)
3. Add the quest question from Q1. Generate 2-4 threads from Steps 1+2 context.
4. Create Quest node in Neo4j via `bash bin/graph.sh query "..."` following `/quest` spec
5. Link the Step 2 artifact to this quest: `bash bin/graph.sh query "MATCH (a:Artifact {id: $artifactId}), (q:Quest {id: $questId}) CREATE (a)-[:PART_OF]->(q)"` with params
6. Auto-save (commit + push memory)
7. Offer each selected notification separately. The "Who should know"
   selection is not dispatch consent; never batch approvals.
8. **Render TUI confirmation** — 72-char box, quest details, linked artifact, threads:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⚑ QUEST STARTED                                 {author} · {date}  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  {Quest title}                                                       │
│                                                                      │
│  {Quest question, wrapped at ~60 chars}                              │
│                                                                      │
│  Threads:                                                            │
│  ○ {thread 1}                                                        │
│  ○ {thread 2}                                                        │
│  ○ {thread 3}                                                        │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ◉ {Type}: {Step 2 artifact title}                                   │
│    → {quest slug}                                                    │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### Quest refinement (all paths that create a quest)

After rendering the quest TUI, refine it with 1-2 context-rich questions. By this point you have: domain from Step 1, the reflect artifact from Step 2, the quest title and question, and the threads. Use ALL of this context to generate specific, non-generic follow-ups.

**Q3** — refine the quest scope. Use AskUserQuestion. Generate options from the accumulated context — reference the actual quest title, artifact content, and domain. Never use generic options.

```
question: "What would make {quest title} feel answered?"
header: "Success"
```

Options should be 2-3 concrete outcomes derived from the quest question + reflect artifact. For example, if the quest is "What makes onboarding feel alive?" and the artifact was about tutorial UX:
- "A new user completes the tutorial and says 'whoa'" — The emotional response test
- "The graph has 3+ real nodes after first session" — The mechanical proof
- "Someone refers back to it unprompted" — The retention signal

**Q4** (optional — only if Q3 answer suggests it): Sharpen the first thread into an actionable next step.

```
question: "What's the first thing to try?"
header: "First move"
```

Options drawn from the quest threads + user's Q3 answer. Concrete actions, not categories.

After Q3 (and Q4 if asked), update the quest file and Neo4j node:
- Add success criteria to the quest markdown (new `## Success looks like` section)
- Update threads if Q4 refined the first one
- Commit + push memory

Then:

> That quest is live. Anyone on the team can contribute artifacts to it. When someone runs `/activity`, they'll see it.

### Joiner/group path → Explore existing work

Query Neo4j for active quests and recent handoffs:

```bash
bash bin/graph.sh query "MATCH (q:Quest {status: 'active'}) OPTIONAL MATCH (a:Artifact)-[:PART_OF]->(q) RETURN q.id AS quest, q.title AS title, count(a) AS artifacts ORDER BY count(a) DESC LIMIT 3"
```

```bash
bash bin/graph.sh query "MATCH (s:Session)-[:HANDED_TO]->(p:Person {name: $me}) WHERE date(left(toString(s.date), 10)) >= date() - duration('P7D') MATCH (s)-[:BY]->(author:Person) RETURN s.topic AS topic, author.name AS author, s.filePath AS filePath LIMIT 3" '{"me": "<author>"}'
```

**If quests/handoffs exist:** Show the top quest with its artifacts. Walk through a handoff if one exists for them.

Then ask:
```
question: "What would you add to this?"
header: "Contribute"
options:
  - label: "I have thoughts on this"
    description: "Add my perspective to the quest"
  - label: "I have a related question"
    description: "Something this raises for me"
  - label: "Nothing yet"
    description: "I'll contribute as I learn more"
```

If user wants to contribute, run Quick Reflect with their input linked to the quest. Auto-confirm (no `y/edit/skip`). Render the reflect TUI confirmation box.

**If empty (brand new org):** Create a quest from their Step 2 reflection, following the founder path above (including TUI).

### Personal path → Add a source

**Q1**:
```
question: "What's something you've been reading, building, or referencing?"
header: "Source"
options:
  - label: "An article or paper"
    description: "Something you read that's relevant"
  - label: "A repo or project"
    description: "Code you're working with or studying"
  - label: "A concept or framework"
    description: "A mental model you find useful"
```

**Q2**:
```
question: "How does it connect to what you just reflected on?"
header: "Connection"
options:
  - label: "It inspired the thought"
    description: "This source led to the reflection"
  - label: "It contradicts it"
    description: "An opposing perspective"
  - label: "It extends it"
    description: "Takes the idea further"
```

**Then:** Run the real `/add` flow:
1. Ask for a title/URL (brief freeform follow-up if needed)
2. Create artifact file in `memory/artifacts/` with proper frontmatter
3. Create Artifact node in Neo4j, link to author
4. Link to Step 2 artifact via RELATES_TO
5. Auto-save
6. **Render TUI confirmation** — 72-char box:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◎ SOURCE ADDED                                   {author} · {date}  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ◉ {Type}: {Title}                                                   │
│    ↔ relates to: {Step 2 artifact title}                             │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

After the TUI:

> Every source you add becomes a node in your graph. Over time, `/reflect` will notice connections between them.

### Personal + agents path → Seed project context

**Q1**:
```
question: "What should an agent know before working on this?"
header: "Context"
options:
  - label: "The goal"
    description: "What we're trying to achieve"
  - label: "The constraints"
    description: "What limits or shapes the work"
  - label: "The current state"
    description: "Where things stand right now"
```

**Then:**
1. Create a source artifact with the project context in `memory/artifacts/`
2. Create a quest around their core exploration (generate title from Steps 1+2)
3. Link Step 2 artifact + this source to the quest
4. Neo4j nodes for both + quest
5. Auto-save
6. **Render TUI confirmation** — combined quest + source box:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⚑ QUEST STARTED                                 {author} · {date}  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  {Quest title}                                                       │
│                                                                      │
│  {Quest question, wrapped at ~60 chars}                              │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ◉ Source: {Project context title}                                   │
│  ◉ {Type}: {Step 2 artifact title}                                   │
│    → {quest slug}                                                    │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

After the TUI:

> When an agent starts a session, it sees this context. The more you capture, the more useful the graph becomes.

Save `tutorial_step: 4` to state.

---

## Step 4: Close

**Do NOT list the command cycle.** The user just experienced three of the four steps. The cycle is implicit.

### Show what accumulated

Query Neo4j for the user's graph state:

```bash
bash bin/graph.sh query "MATCH (n) WHERE (n:Artifact OR n:Quest OR n:Session) AND ((n)-[:CONTRIBUTED_BY]->(:Person {name: $me}) OR (n)-[:STARTED_BY]->(:Person {name: $me}) OR (n)-[:BY]->(:Person {name: $me})) RETURN labels(n)[0] AS type, count(n) AS count" '{"me": "<author>"}'
```

```bash
bash bin/graph.sh query "MATCH ()-[r]->() WHERE type(r) IN ['CONTRIBUTED_BY', 'PART_OF', 'RELATES_TO', 'STARTED_BY', 'BY'] RETURN count(r) AS edges"
```

Display:

```
Your graph so far:
  {N} nodes · {N} edges
  {artifact names, types, connections listed}
  {quest name if created}
```

### One personalized next-step

- **founder_group**: "Try `/handoff` at the end of your next real session. Your team will see it tomorrow."
- **joiner_group**: "Run `/activity` tomorrow morning. You'll see what changed while you were away."
- **personal**: "Use `/reflect` whenever something clicks. Patterns will emerge."
- **personal_agent**: "The more you capture, the smarter the graph gets. Start with `/add` for your key sources."

### Feedback capture

Before closing, ask one feedback question:

```
question: "How did that feel?"
header: "Feedback"
options:
  - label: "Made sense"
    description: "I get how this works now"
  - label: "Too many questions"
    description: "I wanted to get to work faster"
  - label: "Wanted more depth"
    description: "I had more to say than the questions allowed"
  - label: "Felt mechanical"
    description: "It worked but didn't feel alive"
```

### Save journey log

Write the full tutorial journey to `memory/knowledge/findings/tutorial-journey-{author}.md`. This captures the complete experience for iteration. Use Bash (memory is outside project):

```bash
cat > "memory/knowledge/findings/tutorial-journey-{author}.md" << 'JOURNEYEOF'
# Tutorial Journey: {Name}

**Date**: {YYYY-MM-DD}
**Usage type**: {usage_type}
**Duration**: Steps 1-4

## Step 1: Orient
- **Q1 (Your work)**: {answer}
- **Q2 (Follow-up)**: {answer or "skipped — freeform Q1"}
- **Dashboard state**: {empty / sparse / active}

## Step 2: Capture
- **Q1 (Throughline/Hardest)**: {answer}
- **Q2 (Capture)**: {answer}
- **Artifact created**: {title} ({category})
- **Topics**: {topics}

## Step 3: Connect
- **Quest title**: {title}
- **Quest question**: {question}
- **Handed off to**: {names or "whole team" or "just me"}
- **Success criteria**: {answer}
- **First move**: {answer}

## Step 4: Close
- **Graph state**: {N} nodes · {N} edges
- **Feedback**: {answer}

## Raw Observations
{Any freeform feedback the user gave during the flow — capture verbatim anything
they typed that wasn't a direct answer, including complaints, suggestions, and
moments where they went off-script.}
JOURNEYEOF
```

Commit and push to memory. Also create a lightweight Artifact node in Neo4j so the journey is queryable:

```bash
bash bin/graph.sh query "MATCH (p:Person {name: $author}) CREATE (a:Artifact {id: $artifactId, title: $title, type: 'finding', topics: ['tutorial', 'feedback', 'onboarding'], filePath: $filePath, created: datetime()}) CREATE (a)-[:CONTRIBUTED_BY]->(p) RETURN a.id"
```

### Finalize

Save `tutorial_complete: true` to `.egregore-state.json`.

End with: **"What are you working on?"**
