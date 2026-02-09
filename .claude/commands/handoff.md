End a session with a summary for the next person (or future you).

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## Execution rules

**Neo4j-first.** All queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl to Neo4j.
**Notifications via `bash bin/notify.sh send`**. No direct curl to Telegram.

- 1 Bash call: `git config user.name`
- 1 Neo4j query: Session creation (with HANDED_TO if recipient)
- 1 Neo4j query: Artifact lookup (today's artifacts by author)
- Auto-save via `/save` flow
- 1 notification via `bin/notify.sh send` (if recipient specified)
- Progress shown incrementally, step by step

## Step 0: Get current user

```bash
git config user.name
```

Map to Person node: "Oguzhan Yayla" -> oz, "Cem Dagdelen" -> cem, "Ali" -> ali

## Step 1: Parse arguments

Parse `$ARGUMENTS` for topic and recipient.

**Recipient detection** — understand from natural language who the handoff is for:
- "defensibility architecture to oz" -> topic: "defensibility architecture", recipient: oz
- "mcp auth for cem to pick up" -> topic: "mcp auth", recipient: cem
- "ali should look at this: graph schema" -> topic: "graph schema", recipient: ali
- "handoff blog styling" -> topic: "blog styling", recipient: none

Team members: oz, ali, cem

If no recipient detected, the handoff is general (for the team or future self).

## Step 2: Summarize the session

Analyze the conversation context to produce:

1. **Session summary** — 2-3 sentences on what was accomplished
2. **Key decisions** — any decisions made with rationale
3. **Current state** — what's working, in progress, blocked
4. **Open threads** — unfinished items with enough context to pick up
5. **Next steps** — clear actions with entry points
6. **Project** — which project this relates to (LACE/Tristero/Research/Egregore)

## Step 3: Create handoff file

File path: `memory/handoffs/YYYY-MM/DD-[author]-[topic-slug].md`

Example: `memory/handoffs/2026-02/07-cem-defensibility-architecture.md`

Generate slug from topic: lowercase, hyphens, no special chars, max 50 chars.

Ensure the directory exists:
```bash
mkdir -p memory/handoffs/YYYY-MM
```

Write the file using Bash (memory is outside project, avoids permission issues):

```bash
cat > "memory/handoffs/YYYY-MM/DD-author-topic-slug.md" << 'HANDOFFEOF'
# Handoff: [Topic]

**Date**: YYYY-MM-DD
**Author**: [from git config user.name]
**To**: [recipient, if specified]
**Project**: [LACE/Tristero/Research/Egregore]

## Session Summary

[2-3 sentences on what was accomplished]

## Key Decisions

- **[Decision]**: [Rationale]

## Current State

[What's working, what's in progress, what's blocked]

## Open Threads

- [ ] [Unfinished item with context]

## Session Artifacts

- [Type]: [Title] -> [shortened file path]

## Next Steps

1. [Clear action with entry point]

## Entry Points

For the next session, start by:
- Reading: [specific file]
- Running: [specific command]
HANDOFFEOF
```

Omit the **To** line if no recipient. Omit **Key Decisions** if none. Omit **Session Artifacts** section if the artifact query (Step 5) returns empty. The Session Artifacts section is populated after the Neo4j query in Step 5 — leave a placeholder during file creation, then update the file after the query.

Show progress:
```
[1/5] ✓ Conversation file
```

## Step 4: Update conversation index

Prepend to `memory/handoffs/index.md`:

```markdown
- **YYYY-MM-DD** — [author]: [topic] ([handoff to recipient] | [handoff])
```

Show progress:
```
[2/5] ✓ Index updated
```

## Step 5: Create Session node in Neo4j + query artifacts

### Session creation (with HANDED_TO)

Run via `bash bin/graph.sh query "..." '{"param": "value"}'`:

```cypher
MATCH (p:Person {name: $author})
CREATE (s:Session {
  id: $sessionId,
  date: date($date),
  topic: $topic,
  summary: $summary,
  filePath: $filePath,
  handoffStatus: 'pending'
})
CREATE (s)-[:BY]->(p)
WITH s
OPTIONAL MATCH (proj:Project {name: $project})
FOREACH (_ IN CASE WHEN proj IS NOT NULL THEN [1] ELSE [] END |
  CREATE (s)-[:ABOUT]->(proj)
)
WITH s
OPTIONAL MATCH (target:Person {name: $recipient})
FOREACH (_ IN CASE WHEN target IS NOT NULL THEN [1] ELSE [] END |
  CREATE (s)-[:HANDED_TO]->(target)
)
RETURN s.id
```

Where:
- `$sessionId` = `YYYY-MM-DD-author-topic-slug` (matches filename without extension)
- `$author` = short name (oz, cem, ali)
- `$date` = `YYYY-MM-DD`
- `$topic` = the topic string
- `$summary` = 1-2 sentence summary
- `$filePath` = `handoffs/YYYY-MM/DD-author-topic-slug.md`
- `$project` = project name if identified (can be empty string if none)
- `$recipient` = recipient short name if specified (can be empty string if none)

If no recipient, pass `$recipient` as empty string — the OPTIONAL MATCH will simply not match and FOREACH won't execute.

**CRITICAL: This step is NOT optional.** Without the Neo4j Session node, the handoff won't appear in `/activity`.

### Artifact query

Query for artifacts created today by the author:

```cypher
MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person {name: $author})
WHERE a.created >= datetime({year: $year, month: $month, day: $day})
RETURN a.title AS title, a.type AS type, a.filePath AS path
ORDER BY a.created DESC
```

Run this in parallel with the Session creation query.

If artifacts are found, update the handoff file's Session Artifacts section with the results. Format each artifact as:
```
- [Type capitalized]: [Title] -> [shortened file path]
```

Show progress:
```
[3/5] ✓ Session -> knowledge graph
```

## Step 6: Auto-save

Run the full `/save` flow:

1. Commit changes in memory repo and push (contribution branch + PR + auto-merge)
2. Commit any egregore changes and push working branch + PR to develop

This is the same flow as `/save`. Follow its logic exactly.

Show progress:
```
[4/5] ✓ Pushed + PR created
```

## Step 7: Notify recipient

**Only if a recipient was specified.**

Send via `bash bin/notify.sh send`:

```bash
bash bin/notify.sh send "$RECIPIENT" "$MESSAGE"
```

**Telegram message format**:

```
Handoff from [Author]: [Topic]

"[1-2 sentence summary from the session]"

[If artifacts found:]
Session included N artifacts:
  - [Type]: [Title]
  - [Type]: [Title]

Entry point: memory/[handoff file path]
```

Example:
```
Handoff from Cem: Defensibility architecture

"Analyzed five-layer moat framework. Server-side intelligence is the biggest gap. Full artifact in knowledge/decisions/."

Session included 2 artifacts:
  - Decision: Defensibility architecture framework
  - Finding: Harvest flywheel as training surface

Entry point: memory/handoffs/2026-02/07-cem-defensibility-architecture.md
```

Show progress:
```
[5/5] ✓ [Recipient] notified
```

**If no recipient**: step 5 becomes "✓ Team sees this on /activity" and no notification is sent (show only 4 progress steps total, renumbered).

## Step 8: Display sender TUI confirmation

~72 char width. Sigil: `⇌ HANDOFF SENT`.

### Boundary handling (CRITICAL)

**No sub-boxes. No inner `┌─┐`/`└─┘` borders.** Sub-boxes break because the model can't count character widths precisely enough.

Only **4 line patterns** exist:

1. **Top**: `┌` + 70×`─` + `┐` (72 chars)
2. **Separator**: `├` + 70×`─` + `┤` (72 chars)
3. **Content**: `│` + 2 spaces + text + pad spaces to 68 chars + `│` (72 chars)
4. **Bottom**: `└` + 70×`─` + `┘` (72 chars)

The separator lines are ALWAYS identical — copy-paste the same 72-char string. Content lines have ONLY the outer frame `│` as borders. Pad every content line with trailing spaces so the closing `│` is at position 72.

### Content priority

The session summary is the primary content — what was actually handed off. The progress checklist is already shown incrementally during execution; repeating it wastes space. Collapse progress to a single status line.

### With recipient and artifacts:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF SENT                                     cem · Feb 07     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: Defensibility architecture                                   │
│  To: Oz                                                              │
│                                                                      │
│  Analyzed five-layer moat framework for Egregore. Server-side        │
│  intelligence is the biggest gap and biggest opportunity.             │
│  Defined pricing tiers and go-to-market sequence.                    │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ◉ Decision: Defensibility architecture framework                    │
│  ◉ Finding: Harvest flywheel as training surface                     │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed · Oz notified                            │
│  Team sees this on /activity.                                        │
└──────────────────────────────────────────────────────────────────────┘
```

### Without recipient, no artifacts:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF SENT                                      oz · Feb 07     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: MCP auth flow                                                │
│                                                                      │
│  Implemented OAuth device flow for MCP authentication.               │
│  Token refresh works end-to-end. Needs error handling                │
│  for expired sessions.                                               │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Team sees this on /activity.                                        │
└──────────────────────────────────────────────────────────────────────┘
```

### TUI rules

- Header row: `⇌ HANDOFF SENT` left, `author · Mon DD` right — both inside the 72-char frame
- `├───┤` separator between header and content
- Topic always shown
- "To:" line only if recipient specified
- **Session summary** — 2-3 sentences from Step 2, wrapped at ~60 chars. This is the primary content.
- Artifacts section (between `├───┤` dividers): `◉` for each artifact. Omit entirely if no artifacts.
- **Status line** — single line collapsing all progress: `✓ Saved · graphed · pushed` (add `· {Recipient} notified` if recipient)
- Footer: "Team sees this on /activity."
- Truncate topic at 45 chars with `...` if needed
- **No sub-boxes** — only outer frame `│` borders and `├────┤` separators

## Receiver View (for /activity integration)

When a recipient reads a handoff directed at them (e.g., from an `/activity` action item), display this format.

Same boundary rules apply — 4 line patterns only, no sub-boxes, 72-char outer width.

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF FROM CEM                                     Feb 07       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: Defensibility architecture                                   │
│                                                                      │
│  Analyzed Egregore defensibility — five-layer moat from              │
│  convenience to network effects. Server-side intelligence            │
│  is the biggest gap and biggest opportunity.                         │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  OPEN THREADS                                                        │
│  ○ API proxy architecture — before or after org #2?                  │
│  ○ Person node schema — org-scoped vs platform-level                 │
│  ○ First premium agent design                                        │
├──────────────────────────────────────────────────────────────────────┤
│  ◉ Decision: Defensibility architecture framework                    │
│  ◉ Finding: Harvest flywheel as training surface                     │
├──────────────────────────────────────────────────────────────────────┤
│  → memory/knowledge/decisions/2026-02-07-defensibility-...           │
│  → memory/handoffs/2026-02/07-cem-defensibility-...             │
└──────────────────────────────────────────────────────────────────────┘
```

### Receiver TUI rules

- Header: `⇌ HANDOFF FROM [AUTHOR uppercase]` left, `Mon DD` right
- Summary: wrap at ~60 chars — the primary content
- Open Threads section (between `├───┤` dividers): `○` for each thread. Omit entirely if none.
- Artifacts section: `◉` for each artifact. Omit entirely if none.
- Entry points: `→` for file paths, shortened to last 2-3 segments with `...` if needed
- Omit empty sections entirely
- **No sub-boxes** — only outer frame `│` borders and `├────┤` separators

### When /activity shows handoffs

In `/activity` action items, handoffs directed at the current user appear as:
```
[2] ⇌ Handoff from cem: Defensibility architecture (today)
```

When the user selects that numbered item, display the receiver view above by reading the handoff file from the path in the Session node's `filePath` property.

## Step 9: Reflection prompt

After displaying the TUI confirmation, check if today's sessions produced no artifacts. Query:

```cypher
MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person {name: $me})
WHERE a.created >= datetime({year: $year, month: $month, day: $day})
RETURN count(a) AS artifactCount
```

If `artifactCount = 0`, show a one-line suggestion (not a blocker — no AskUserQuestion):

```
This session had insights worth capturing. Quick /reflect?
```

If artifacts exist, skip this step silently.

## Edge cases

| Scenario | Handling |
|----------|----------|
| Neo4j unavailable | Still create handoff file and index. Show warning: "Graph offline — file saved, will sync on next /save". Skip artifact query. |
| No artifacts today | Omit Session Artifacts sub-box from TUI and Telegram message |
| Notification fails | Show warning but don't fail the handoff: "Notification failed — [recipient] can see this on /activity" |
| Memory symlink missing | Error: "Run /setup first — memory not linked" |
| Recipient not a known Person | Warn: "[name] not found in graph — handoff saved but not directed. Create them with /invite?" |
| No topic in $ARGUMENTS | Summarize the session and generate a topic from the conversation context |
| Empty session (nothing happened) | Ask: "Nothing to hand off yet. Want to leave a note instead?" |
| File already exists at path | Append timestamp to slug to avoid collision |

## Full example: with recipient

```
> /handoff defensibility architecture to oz

Creating handoff...

Summarizing session...

  [1/5] ✓ Conversation file
        → memory/handoffs/2026-02/07-cem-defensibility-architecture.md

  [2/5] ✓ Index updated

  [3/5] ✓ Session -> knowledge graph

  [4/5] ✓ Pushed + PR created

  [5/5] ✓ Oz notified

┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF SENT                                     cem · Feb 07     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: Defensibility architecture                                   │
│  To: Oz                                                              │
│                                                                      │
│  Analyzed five-layer moat framework for Egregore. Server-side        │
│  intelligence is the biggest gap and biggest opportunity.             │
│  Defined pricing tiers and go-to-market sequence.                    │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ◉ Decision: Defensibility architecture framework                    │
│  ◉ Finding: Harvest flywheel as training surface                     │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed · Oz notified                            │
│  Team sees this on /activity.                                        │
└──────────────────────────────────────────────────────────────────────┘
```

## Full example: no recipient

```
> /handoff mcp auth flow

Creating handoff...

Summarizing session...

  [1/4] ✓ Conversation file
        → memory/handoffs/2026-02/07-oz-mcp-auth-flow.md

  [2/4] ✓ Index updated

  [3/4] ✓ Session -> knowledge graph

  [4/4] ✓ Pushed + PR created

┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF SENT                                      oz · Feb 07     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: MCP auth flow                                                │
│                                                                      │
│  Implemented OAuth device flow for MCP authentication.               │
│  Token refresh works end-to-end. Needs error handling                │
│  for expired sessions.                                               │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Team sees this on /activity.                                        │
└──────────────────────────────────────────────────────────────────────┘
```
