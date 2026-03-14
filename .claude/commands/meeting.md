Import and analyze a meeting from Granola.

Single-pass Opus 4.6 analysis on full transcript + panel notes + graph context. Accuracy and insight over structure. No sub-agents — the model reads everything directly.

Arguments: $ARGUMENTS (Optional: "sync" for batch mode, "backfill" to re-process historical meetings, or search term to find a specific meeting)

## Usage

- `/meeting` — Interactive: list recent unprocessed meetings, pick one
- `/meeting sync` — Batch: process all unprocessed meetings
- `/meeting [search]` — Find and process a specific meeting by title
- `/meeting backfill` — Re-process already-ingested meetings

## Architecture

Single-pass holistic analysis. Opus 4.6 reads everything — panel, transcript, graph context — and produces the full analysis inline. No delegation, no JSON intermediaries, no synthesis step.

```
Granola API → fetch meeting data (panel + transcript + attendees)
Neo4j → cross-meeting context (5 queries, 1 batch call)
         │
    OPUS 4.6 (inline, ultrathink)
    panel + transcript + graph context + attendee map
    → Meeting Intelligence Briefing (prose)
    → Extracted artifacts (structured)
    → Speaker attribution with confidence
    → Cross-meeting continuity
         │
    Write files → Graph → Save
```

The model reads the transcript directly. No intermediary agents, no scaffold pass, no structured JSON extraction step. The analysis is prose-first — accuracy and insight matter more than dimensional coverage.

## Cost & Resource Budget

Target per meeting:
- **Bash calls**: ~8-12 (API fetch, graph batches, file writes, git)
- **Sub-agents**: 0 — all analysis is inline Opus 4.6
- **AskUserQuestion**: 0-1 (only for unknown attendees without email)
- **Graph batches**: 2-3 (1 context read, 1-2 artifact write batches at <=20 queries each)
- **Token-heavy**: Full transcript goes directly to Opus (~6-15K words depending on meeting)

## What to do

### Step 0: Config check

Check if Granola API is reachable:
```bash
bash bin/granola-api.sh test
```

If it fails with "token expired", tell the user:
> Granola session expired — open the Granola app to refresh your login, then try again.

If it fails with "auth not found":
> Granola not found on this machine. Install Granola and sign in first.

### Step 0.5: Route subcommand

If `$ARGUMENTS` is `backfill`, jump to **Backfill Mode** (bottom of this document).

### Step 1: Fetch unprocessed meetings

Read processed meeting IDs:
```bash
jq -r '.processed_meetings // {} | keys[]' .egregore-state.json
```

Build exclude list (comma-separated IDs), then fetch:
```bash
bash bin/granola-api.sh list --exclude "id1,id2,..."
```

If `$ARGUMENTS` is a search term (not "sync", not "backfill", and not empty), use `bash bin/granola-api.sh search "$ARGUMENTS"`.

**Show the ingestion status.** When presenting meetings, cross-reference against existing briefing files in `memory/meetings/` to show which have already been ingested. This is important context for the user — they need to see what's done vs what's new.

### Step 2: Select meetings

**Interactive mode** (no arguments or search term):
Present unprocessed meetings via AskUserQuestion:
```
question: "Which meeting should I process?"
header: "Meeting"
options:
  - label: "Meeting Title (Feb 12)"
    description: "With: Alice, Bob — 45 min"
  - label: "Another Meeting (Feb 11)"
    description: "With: Carol — 30 min"
```

**Sync mode** (`/meeting sync`):
Process all unprocessed meetings. Show count:
> Processing N unprocessed meetings...

**Search mode** (`/meeting [search]`):
If exactly one match, use it. If multiple, present via AskUserQuestion. If none:
> No meetings found matching "[search]".

### Step 3: Process each meeting

For each selected meeting:

#### Step 3a: Fetch meeting data

```bash
bash bin/granola-api.sh get <doc-id>
```

Parse the output JSON. You now have: `panel_text`, `transcript_text`, `transcript_structured`, `title`, `date`, `attendees`.

#### Step 3b: Load cross-meeting context (single batch call)

Run ALL 5 queries in a **single `bash bin/graph-batch.sh` call** (1 network round-trip instead of 5). Parse `results[0]` through `results[4]`.

```bash
bash bin/graph-batch.sh '[
  {"statement": "MATCH (a:Artifact) WHERE a.origin STARTS WITH '"'"'granola:'"'"' AND a.created >= datetime() - duration('"'"'P30D'"'"') RETURN a.id, a.title, a.type, a.topics, a.meetingTitle, a.meetingDate, a.confidence ORDER BY a.created DESC LIMIT 15"},
  {"statement": "MATCH (a:Artifact) WHERE a.origin STARTS WITH '"'"'granola:'"'"' AND a.openQuestions IS NOT NULL RETURN a.title, a.openQuestions, a.meetingTitle, a.meetingDate ORDER BY a.created DESC LIMIT 10"},
  {"statement": "MATCH (a:Artifact) WHERE a.origin STARTS WITH '"'"'granola:'"'"' AND a.created >= datetime() - duration('"'"'P60D'"'"') UNWIND a.topics AS topic WITH topic, count(DISTINCT a.meetingTitle) AS meetingCount, collect(DISTINCT a.meetingTitle)[..5] AS meetings WHERE meetingCount >= 2 RETURN topic, meetingCount, meetings ORDER BY meetingCount DESC LIMIT 10"},
  {"statement": "MATCH (newer:Artifact)-[:SUPERSEDES]->(older:Artifact) WHERE newer.created >= datetime() - duration('"'"'P60D'"'"') RETURN newer.title AS current, older.title AS previous, newer.topics, newer.meetingTitle ORDER BY newer.created DESC LIMIT 10"},
  {"statement": "MATCH (q:Quest {status: '"'"'active'"'"'}) WHERE q.topics IS NOT NULL RETURN q.id, q.title, q.topics"}
]'
```

Result mapping:
- `results[0]` → Q1: Recent meeting artifacts (30d)
- `results[1]` → Q2: Open questions from previous meetings
- `results[2]` → Q3: Topic recurrence (60d)
- `results[3]` → Q4: Decision evolution chains
- `results[4]` → Q5: Active quests (for topic linking)

**If the batch call fails**, continue without cross-meeting context. It's enrichment, not required.

#### Step 3c: Resolve attendees

Read the attendee map:
```bash
jq -r '.attendee_map // {}' .egregore-state.json
```

For each attendee from the meeting data, look up their graph name in the map. If an attendee is NOT in the map, auto-derive from email before asking:

1. **If attendee has email**: derive short name = email local part before `@` (e.g., `bartu@gizatech.xyz` → `bartu`)
2. **Check graph**: `MATCH (p:Person) WHERE p.name = $derived RETURN p` — if person exists, auto-map silently
3. **If name is clean** (alphanumeric, not generic like "info" or "admin"): auto-map and show confirmation line (no AskUserQuestion): `Auto-mapped: {full name} → {derived} (from email)`
4. **Only use AskUserQuestion if**: no email available, email local part is ambiguous/generic, or multiple candidates exist

Save all new mappings to `.egregore-state.json` under `attendee_map`.

#### Step 3d: Holistic analysis (Opus 4.6, inline)

**This is the core of the pipeline.** You — Opus 4.6 — read the full transcript, panel notes, and graph context directly. No sub-agents, no JSON intermediaries.

**Think hard.** Use extended thinking / ultrathink. This is the one place where depth matters more than speed.

**What to produce:**

Read the panel notes first (high-signal, low-noise), then the full transcript (noisy but ground truth). Cross-reference with graph context for continuity.

Produce:

##### 1. Meeting Intelligence Briefing

A prose document that tells someone who wasn't there what happened and what it means. Structure:

```markdown
# Meeting Intelligence: {Title}

**Date**: YYYY-MM-DD
**Attendees**: {names}
**Source**: Granola ({doc-id})

## Speaker Attribution

Explain your method. Who is "microphone" (the user), who are the "system" speakers? When multiple people share the "system" source, explain how you're distinguishing them (content clues, role references, etc.). Be honest about uncertainty.

## What Actually Happened

Prose. Not a summary — an interpretation. What was the core question or tension? What positions were taken? Where did the conversation actually land vs where it started?

## Key Decisions & Open Questions

For each:
- What was decided (or left open)
- Who drove it
- What the implications are
- Evidence (quote if useful, with honest speaker attribution)

Distinguish between **actual decisions** and **things discussed but not decided**. This is critical — don't promote aspirations to decisions.

## Emotional Texture

Who cares about what? Where was there real tension vs polite agreement? Where did energy spike or drop? What was unsaid?

## What Matters Next

The 3-5 things from this meeting that will actually shape what happens. Not a summary of everything discussed — a judgment call about what's consequential.

## Cross-Meeting Context

(Only if graph context exists) How does this meeting connect to previous meetings, active quests, open threads? What evolved, what recurred, what was dropped?
```

**Writing guidance:**

- **Accuracy over insight.** Get the facts right first. What was actually said? What was actually decided? Don't project or over-interpret.
- **Speaker attribution matters.** When you attribute something to a specific person, explain WHY. When you can't tell, say so. "One of the system speakers" is better than a wrong attribution.
- **Register:** A trusted colleague who attended the meeting and is briefing someone who wasn't there. Direct, opinionated, doesn't waste words on obvious things.
- **Anti-patterns:** "The meeting covered several important topics..." → you have nothing to say. Restating what's in the panel → the panel exists for that. Equal weight to everything → prioritize ruthlessly.

##### 2. Extracted artifacts

From the analysis, identify discrete knowledge artifacts worth preserving:

- **Decisions**: Things actually decided, with rationale and implications
- **Findings**: Realizations, data points, patterns discovered
- **Patterns**: Recurring dynamics observed across discussions
- **Actions**: Commitments to do specific things (NOT artifacts — tracked separately)

For each artifact, capture:
- `category`: decision / finding / pattern
- `title`: Short descriptive title
- `content`: The substance — what was said, decided, or discovered
- `context`: What conversation led to this
- `confidence`: How confident the speakers were (0.0-1.0)
- `speaker`: Who drove it (use graph names, be honest about uncertainty)
- `topics`: 2-5 tags for quest linking
- `evidence_quote`: Supporting quote (max 120 chars)
- `open_questions`: Unresolved aspects
- `tradeoffs`: What was considered and rejected

**Rules:**
- Only extract things worth preserving. Not trivia, not logistics.
- If something was discussed but not decided, say so — don't promote it to a decision.
- Confidence reflects how settled the speakers were, not how important it is.
- Actions are listed in the briefing but do NOT become artifact files.

#### Step 3e: Present proposal

Show the briefing preview + extracted artifacts. The preview is the "What Actually Happened" section condensed to 2-3 sentences, plus the artifact list.

```
From "CORK: Launch Plan" (Mar 11, Kaan + Renc + Oz):

  This meeting was about whether to launch open source and commercial
  simultaneously or sequence them. The room converged toward free-to-paid
  first with open source deferred as "Egregore Mini," but no binding
  decision was made — homework was assigned for scenario planning.

  ◉ Decision: Free-to-paid first, open source deferred          [0.85]
    "let's push for product release with free version" — Oz (likely)
    Open: what does "Egregore Mini" actually contain?

  ◉ Finding: Target user = sub-10 teams, two profiles             [0.85]
    "coordination first...context use cases" — me
    Open: individual→team conversion flow design

  ◉ Finding: Git worktree is #1 technical blocker                 [0.9]
    "git thing is number one that needs to happen" — team consensus

  ◉ Finding: Claude Code licensing question unresolved            [0.7]
    "can you even not open source?" — me
    Open: can we run commercial service on Claude Code?

  Actions:
    * Renc — create multi-threaded timeline
    * Oz — git worktree implementation
    * Renc — lawyer meeting Monday (entity setup)

Adjust? (y/edit/skip)
```

Display rules:
- Briefing preview: 2-3 sentences. Heart of the conversation + what landed.
- `[0.85]` confidence after title
- Evidence quote with honest speaker attribution
- Open questions on `Open:` line
- Actions listed separately (not artifacts)

Wait for user response:
- **y** or empty → proceed to reflection checkpoint
- **edit** → user modifies, then proceed
- **skip** → skip this meeting, move to next

#### Step 3f: Reflection checkpoint

After the user approves, check the analysis for reflection triggers:

| Signal | Reflection prompt |
|---|---|
| A position shifted from a previous meeting | "Your position on {topic} has shifted from {old} to {new}. Is this intentional?" |
| An open thread from a previous meeting was addressed | "{Thread} from {meeting} appears to be resolved. Confirm?" |
| An open thread from a previous meeting was dropped | "{Thread} from {meeting} wasn't mentioned. Still relevant?" |
| A meta-pattern emerged | "Pattern detected: {description}. Is this becoming a principle?" |
| No meaningful signals | Skip reflection entirely |

If a meaningful trigger exists, surface it via AskUserQuestion. If not, skip silently.

### Step 4: Create artifacts + meeting intelligence

#### Step 4a: Write Meeting Intelligence Briefing

Write the briefing file:
```bash
cat > "memory/meetings/{YYYY-MM-DD}-{slug}.md" << 'MEETINGEOF'
{MEETING INTELLIGENCE BRIEFING CONTENT from Step 3d}
MEETINGEOF
```

File naming: `{YYYY-MM-DD}-{slug}.md` where slug is lowercase, hyphens, max 50 chars, derived from title.

#### Step 4b: Write individual artifact files

For each extraction (decisions, findings, patterns — NOT action items):

```bash
cat > "memory/knowledge/{category}s/{YYYY-MM-DD}-{slug}.md" << 'ARTIFACTEOF'
# {Title}

**Date**: {YYYY-MM-DD}
**Author**: meeting
**Category**: {category}
**Confidence**: {0.0-1.0}
**Source**: {meeting title}
**Topics**: {topic1}, {topic2}

## Context

{What conversation led to this}

## Content

{The actual substance}

## Rationale

{Why this matters}

## Tradeoffs

{Only include if non-empty}
- **Pro**: {pro}
- **Con**: {con}

## Open Questions

{Only include if non-empty}
- {question}

## Evidence

{Only include if non-empty}
> "{evidence_quote}" — {speaker}

## Related

- Quest: {quest-id}
- Related: {related-artifact-id} ({type})
ARTIFACTEOF
```

Omit sections that have no data.

#### Step 4c: Batch Neo4j operations

Build a JSON array of queries for `bash bin/graph-batch.sh` calls.

**Batch limit: API accepts max 20 queries per `graph-batch.sh` call.** Count total queries before executing. If >20, split into chunks of <=20 and execute sequentially.

**Meeting node**:
```json
{
  "statement": "MERGE (m:Meeting {id: $meetingId}) SET m.title = $title, m.date = date($date), m.granolaDocId = $docId, m.filePath = $filePath, m.artifactCount = $count, m.processed = datetime() RETURN m.id",
  "parameters": {
    "meetingId": "meeting-{YYYY-MM-DD}-{slug}",
    "title": "{meeting title}",
    "date": "{YYYY-MM-DD}",
    "docId": "{granola doc id}",
    "filePath": "meetings/{YYYY-MM-DD}-{slug}.md",
    "count": 3
  }
}
```

**Meeting → Person relationships** (INVOLVES):
```json
{
  "statement": "MATCH (m:Meeting {id: $meetingId}) MATCH (p:Person {name: $personName}) MERGE (m)-[:INVOLVES]->(p)",
  "parameters": {"meetingId": "...", "personName": "{graph name from attendee_map}"}
}
```

**Artifact nodes**:
```json
{
  "statement": "MERGE (a:Artifact {id: $artifactId}) SET a.title = $title, a.type = $category, a.topics = $topics, a.filePath = $filePath, a.origin = $origin, a.meetingTitle = $meetingTitle, a.meetingDate = $meetingDate, a.confidence = $confidence, a.speaker = $speaker, a.openQuestions = $openQuestions, a.created = datetime() WITH a OPTIONAL MATCH (p:Person {name: $author}) FOREACH (_ IN CASE WHEN p IS NOT NULL THEN [1] ELSE [] END | MERGE (a)-[:CONTRIBUTED_BY]->(p)) RETURN a.id",
  "parameters": {
    "artifactId": "{YYYY-MM-DD}-{slug}",
    "title": "{title}",
    "category": "{category}",
    "topics": ["topic1", "topic2"],
    "filePath": "knowledge/{category}s/{YYYY-MM-DD}-{slug}.md",
    "origin": "granola:{doc-id}",
    "meetingTitle": "{meeting title}",
    "meetingDate": "{meeting date}",
    "confidence": 0.9,
    "speaker": "them",
    "openQuestions": ["question1"],
    "author": "{short name}"
  }
}
```

**Artifact → Meeting relationships** (FROM_MEETING):
```json
{
  "statement": "MATCH (a:Artifact {id: $artifactId}), (m:Meeting {id: $meetingId}) MERGE (a)-[:FROM_MEETING]->(m)",
  "parameters": {"artifactId": "...", "meetingId": "..."}
}
```

**Quest linking** — detect topic overlap and add PART_OF relationships.

**SUPERSEDES** — if reflection produced an evolution, add SUPERSEDES relationship.

Execute the batch:
```bash
bash bin/graph-batch.sh '[{...}, {...}, ...]'
```

Show progress:
```
Creating artifacts...

  [1/5] ✓ Writing meetings/2026-03-11-cork-launch-plan.md (intelligence briefing)
  [2/5] ✓ Writing knowledge/decisions/2026-03-11-free-to-paid-first.md
        ✓ Writing knowledge/findings/2026-03-11-target-user-sub-10-teams.md
  [3/5] ✓ Indexed in knowledge graph (batch: 12 queries)
  [4/5] ✓ Linked to 2 quests
  [5/5] ✓ Auto-saved
```

### Step 5: Mark processed

Update `.egregore-state.json` with processed meeting:

```bash
jq --arg id "$DOC_ID" --arg title "$TITLE" --arg date "$(date +%Y-%m-%d)" --argjson count $ARTIFACT_COUNT '
  .processed_meetings //= {} |
  .processed_meetings[$id] = {
    title: $title,
    processed_at: $date,
    artifacts_created: $count
  }
' .egregore-state.json > tmp.$$.json && mv tmp.$$.json .egregore-state.json
```

### Step 6: Confirmation TUI

Display the confirmation box. ~72 char width. Sigil: `MEETING`.

**Boundary handling (CRITICAL)** — No sub-boxes. Only 4 line patterns:

1. **Top**: `┌` + 70x`─` + `┐` (72 chars)
2. **Separator**: `├` + 70x`─` + `┤` (72 chars)
3. **Content**: `│` + 2 spaces + text + pad to 68 chars + `│` (72 chars)
4. **Bottom**: `└` + 70x`─` + `┘` (72 chars)

### Single meeting:

```
┌──────────────────────────────────────────────────────────────────────┐
│  MEETING                                            cem · Mar 11    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  "CORK: Launch Plan"                                                 │
│  Attendees: Kaan, Renc, Oz                                           │
│                                                                      │
│  3 insights extracted:                                               │
│                                                                      │
│  ◉ Decision: Free-to-paid first, open source deferred    [0.85]     │
│  ◉ Finding: Target user = sub-10 teams                   [0.85]     │
│  ◉ Finding: Git worktree is #1 blocker                   [0.9]      │
│                                                                      │
│  Intelligence briefing: memory/meetings/2026-03-11-cork-...         │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### Batch (sync mode):

```
┌──────────────────────────────────────────────────────────────────────┐
│  MEETING SYNC                                       cem · Mar 12    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  3 meetings processed, 7 insights extracted:                         │
│                                                                      │
│  "CORK: Launch Plan" — 3 insights                                    │
│  "Design Review" — 2 insights                                        │
│  "Sprint Planning" — 2 insights                                      │
│                                                                      │
│  3 intelligence briefings in memory/meetings/                        │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### After confirmation

Run the `/save` flow to commit and push changes.

---

## Backfill Mode

Triggered by `/meeting backfill`. Re-processes already-ingested meetings with the full Opus analysis to enrich graph data.

### Backfill Steps

1. **List candidates**: Read `.egregore-state.json` → `processed_meetings`. Check which ones already have Meeting nodes.

2. **Confirm with user** via AskUserQuestion.

3. **Process each meeting**: Fetch via `bash bin/granola-api.sh get <doc-id>`, run full Opus analysis (same as Step 3d), patch Neo4j with enriched data.

4. **Show progress per meeting**.

---

## Edge cases

| Scenario | Handling |
|----------|----------|
| Granola token expired | "Open the Granola app to refresh your session, then try again." |
| Granola auth not found | "Install Granola and sign in first." |
| No unprocessed meetings | "All meetings are already processed. Nothing new to ingest." |
| Empty panel + empty transcript | Skip meeting: "No content found for this meeting." |
| Empty panel, has transcript | Run analysis on transcript only. Note lower confidence on panel-derived items. |
| Has panel, empty transcript | Run analysis on panel only. Note items are panel-sourced without transcript verification. |
| Meeting already processed | Skip silently (filtered by --exclude) |
| Neo4j unavailable | Still create files, skip graph ops. Warn: "Graph offline — files saved, will sync on next /save" |
| No quest matches | Create artifacts without quest links (no warning needed) |
| transcript_structured empty | Use transcript_text instead |
| Memory symlink missing | Error: "Run /setup first — memory not linked" |
| User skips all meetings | "Nothing to process. Run /meeting later when you're ready." |
| Reflection finds no tension | Skip reflection checkpoint entirely — don't force it |
| Graph queries fail during context load | Continue without cross-meeting context |
| Unknown attendee in meeting | Auto-derive from email, only AskUserQuestion if ambiguous |

## Next

Run `/save` to share, or `/activity` to see the knowledge graph impact.
