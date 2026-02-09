Manage personal todos — lightweight intent capture that flows into quests, asks, and activity.

Arguments: $ARGUMENTS (Optional: text to add, "done N", "cancel N", quest slug, or "all")

## Usage

- `/todo` — List open todos
- `/todo [text]` — Add items from natural language
- `/todo done [N or text]` — Mark complete
- `/todo cancel [N or text]` — Mark cancelled
- `/todo [quest-slug]` — Quest-scoped view
- `/todo all` — Include done/cancelled (14 days)

## Step 1: Get Current User

```bash
git config user.name
```

Map to short name: "Oguzhan Yayla" → oz, "Cem Dagdelen" → cem, "Ali" → ali, "Pali" → pali

## Step 2: Parse Arguments

Parse `$ARGUMENTS` to determine route:

| Input | Route |
|-------|-------|
| (empty) | **List** open todos |
| `done [N or text]` | **Complete** — mark matching todo(s) done |
| `cancel [N or text]` | **Cancel** — mark matching todo(s) cancelled |
| `all` | **List** including done/cancelled (14 days) |
| text matching an active quest slug | **Quest view** — quest-scoped list |
| anything else | **Add** — parse as new todo(s) |

To check if input matches a quest slug:
```bash
bash bin/graph.sh query "MATCH (q:Quest {status: 'active', id: '$input'}) RETURN q.id AS id" 2>/dev/null
```

If it returns a result, route to Quest View. Otherwise, route to Add.

---

## Route: List

Query open todos:
```bash
bash bin/graph.sh query "MATCH (t:Todo {status: 'open'})-[:BY]->(p:Person {name: '$me'}) OPTIONAL MATCH (t)-[:PART_OF]->(q:Quest) RETURN t.id AS id, t.text AS text, t.priority AS priority, t.created AS created, t.source AS source, q.id AS quest ORDER BY t.priority DESC, t.created DESC"
```

**If no results:** `No open todos. /todo [text] to add one.`

**If results exist, render TUI:**

```
┌──────────────────────────────────────────────────────────────────────┐
│  □ TODO                                                cem · Feb 09  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  [1] ! fix retry logic in graph.sh                                   │
│      → egregore-reliability · 2d ago                                 │
│                                                                      │
│  [2] revisit pricing page copy                                       │
│      → pricing-strategy · today                                      │
│                                                                      │
│  [3] ask oz about MCP auth                                           │
│      ? pending ask · today                                           │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  3 open · /todo done [N] to complete · /todo [text] to add          │
└──────────────────────────────────────────────────────────────────────┘
```

Formatting rules:
- Exclamation mark (!) prefix for priority >= 2
- Arrow (→) quest link + time ago on second line
- Question mark (?) prefix on second line for items with MENTIONS relationship (ask-routed)
- Time ago: under 1h show "Nm ago", 1-23h show "Nh ago", 1d "yesterday", 2-6d "Nd ago", 7d+ "Mon DD"
- Numbers are positional (based on display order, not stored IDs)

### List with `all` flag

Include done/cancelled from last 14 days:
```bash
bash bin/graph.sh query "MATCH (t:Todo)-[:BY]->(p:Person {name: '$me'}) WHERE t.status = 'open' OR (t.status IN ['done', 'cancelled'] AND t.completed >= datetime() - duration('P14D')) OPTIONAL MATCH (t)-[:PART_OF]->(q:Quest) RETURN t.id AS id, t.text AS text, t.priority AS priority, t.status AS status, t.created AS created, t.completed AS completed, q.id AS quest ORDER BY t.status, t.priority DESC, t.created DESC"
```

Show done items with `✓` and cancelled with `✗`:
```
│  ✓ fix retry logic in graph.sh (done 2d ago)                         │
│  ✗ old thing (cancelled yesterday)                                   │
```

---

## Route: Quest View

Query todos linked to a specific quest:
```bash
bash bin/graph.sh query "MATCH (t:Todo {status: 'open'})-[:PART_OF]->(q:Quest {id: '$questSlug'}) MATCH (t)-[:BY]->(p:Person) RETURN t.id AS id, t.text AS text, t.priority AS priority, t.created AS created, p.name AS by ORDER BY t.priority DESC, t.created DESC"
```

Render same TUI as List but with quest name in header:
```
┌──────────────────────────────────────────────────────────────────────┐
│  □ TODO · egregore-reliability                         cem · Feb 09  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  [1] ! fix retry logic in graph.sh (cem, 2d ago)                     │
│  [2] investigate connection pooling (oz, today)                      │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  2 open · /todo done [N] to complete · /todo [text] to add          │
└──────────────────────────────────────────────────────────────────────┘
```

Quest view shows all contributors' todos (not just the current user's).

---

## Route: Add

Parse natural language into discrete items. Comma-separated or line-separated text creates multiple items. Single phrase creates one item.

### For each item, determine:

**1. Priority** — auto-detect from language signals:
- "urgent"/"critical"/"ASAP"/"blocking" → 3 (high)
- "soon"/"important"/"need to" → 2 (medium)
- "eventually"/"maybe"/"consider" → 1 (low)
- No signal → 0 (none)

Strip priority words from the stored text.

**2. Person-mention detection**: If text matches "ask [person] about X" or "tell [person] about X" or mentions a known person name:

```bash
bash bin/graph.sh query "MATCH (p:Person) RETURN p.name AS name"
```

If a person is detected and the text implies a question/ask → route to `/ask` flow:
- Create the Todo node (with MENTIONS relationship)
- Also create a QuestionSet via the `/ask` person-targeted flow (Step 8c-8f in ask.md)
- The todo serves as the user's reminder; the QuestionSet is the async question

**3. Quest matching**: Extract topic words from the text. Match against active quests:

```bash
bash bin/graph.sh query "MATCH (q:Quest {status: 'active'}) RETURN q.id AS id, q.title AS title"
```

Auto-link if:
- Quest slug appears in the text (e.g., "fix retry in egregore-reliability")
- 2+ significant words overlap between todo text and quest title
- Otherwise, no quest link

### Create Todo node(s)

Generate ID: `YYYY-MM-DD-{person}-{NNN}` where NNN is a 3-digit sequence. Get next sequence:

```bash
bash bin/graph.sh query "MATCH (t:Todo)-[:BY]->(p:Person {name: '$me'}) WHERE t.id STARTS WITH '$datePrefix' RETURN count(t) AS count"
```

Create the node:
```bash
bash bin/graph.sh query "MATCH (p:Person {name: '$me'}) CREATE (t:Todo {id: '$id', text: '$text', status: 'open', created: datetime(), completed: null, priority: $priority, topics: \$topics, source: 'manual'}) CREATE (t)-[:BY]->(p) RETURN t.id" '{"topics": ["topic1", "topic2"]}'
```

If quest matched:
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$id'}) MATCH (q:Quest {id: '$questSlug'}) CREATE (t)-[:PART_OF]->(q)"
```

If person mentioned:
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$id'}) MATCH (p:Person {name: '$mentionedPerson'}) CREATE (t)-[:MENTIONS]->(p)"
```

### Confirmation UX

**Single item** — compact format (no TUI box):
```
✓ Todo: fix retry logic in graph.sh → egregore-reliability
  7 open todos · /todo to see all
```

**Multiple items** — TUI box:
```
┌──────────────────────────────────────────────────────────────────────┐
│  □ TODO ADDED                                          cem · Feb 09  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ✓ fix retry logic in graph.sh                                       │
│    → egregore-reliability                                            │
│                                                                      │
│  ✓ revisit pricing page copy                                         │
│    → pricing-strategy                                                │
│                                                                      │
│  ✓ ask oz about MCP auth                                             │
│    ? queued for oz · notified                                        │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  3 added · 7 open total                                              │
│  /todo to see all · /todo done [N] to complete                       │
└──────────────────────────────────────────────────────────────────────┘
```

For ask-routed items, show `? queued for [person] · notified` on the second line.

---

## Route: Complete (done)

Parse the argument after "done":
- Numbers: `/todo done 1`, `/todo done 1, 3` — positional references
- Text: `/todo done retry logic` — text fragment match

### Number-based completion

Re-query open todos with the same ORDER BY as the List route to map positions:
```bash
bash bin/graph.sh query "MATCH (t:Todo {status: 'open'})-[:BY]->(p:Person {name: '$me'}) OPTIONAL MATCH (t)-[:PART_OF]->(q:Quest) RETURN t.id AS id, t.text AS text ORDER BY t.priority DESC, t.created DESC"
```

Map position N to the Nth result's id. Then mark complete:
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$todoId'}) SET t.status = 'done', t.completed = datetime() RETURN t.text AS text"
```

### Text-based completion

```bash
bash bin/graph.sh query "MATCH (t:Todo {status: 'open'})-[:BY]->(p:Person {name: '$me'}) WHERE toLower(t.text) CONTAINS toLower('$fragment') RETURN t.id AS id, t.text AS text"
```

- **1 match** → complete it
- **Multiple matches** → show matches, use AskUserQuestion to disambiguate:
  ```
  Multiple todos match "retry":
  ```
  Then present options via AskUserQuestion with header "Which one?" and each match as an option.
- **0 matches** → `No open todo matching "$fragment". /todo to see all.`

### Completion output

```
✓ Done: fix retry logic in graph.sh
  3 open todos remaining
```

For multiple completions:
```
✓ Done: fix retry logic in graph.sh
✓ Done: revisit pricing page copy
  2 open todos remaining
```

---

## Route: Cancel

Same as Complete but sets `status: 'cancelled'`:
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$todoId'}) SET t.status = 'cancelled', t.completed = datetime() RETURN t.text AS text"
```

Output:
```
✗ Cancelled: old thing I don't need anymore
  3 open todos remaining
```

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Neo4j unavailable | "Graph offline — todos need the knowledge graph. Try again when connected." |
| No open todos (list) | "No open todos. /todo [text] to add one." |
| Text matches multiple (done/cancel) | Show matches, AskUserQuestion to pick |
| Person not in graph (mention) | Save todo without MENTIONS. Warn: "[name] not found in graph." |
| Duplicate exact text | "You already have this todo. Add anyway?" via AskUserQuestion |
| Very long text (>200 chars) | Truncate at 200 chars with `...` and warn |
| Invalid position number | "No todo at position [N]. You have [count] open todos." |

---

## Graph Model Reference

```
(:Todo {
  id: String,           // "2026-02-09-cem-001"
  text: String,         // "fix retry logic in graph.sh"
  status: String,       // "open" | "done" | "cancelled"
  created: datetime(),
  completed: datetime(), // null until done
  priority: Integer,    // 0-3
  topics: [String],     // auto-detected for quest matching
  source: String        // "manual" | "handoff" | "session"
})

Relationships:
  (todo)-[:BY]->(Person)           // owner
  (todo)-[:PART_OF]->(Quest)       // linked quest (optional)
  (todo)-[:MENTIONS]->(Person)     // for /ask routing (optional)
```

## Rules

- **All Neo4j via bin/graph.sh** — never construct curl calls directly
- **All notifications via bin/notify.sh** — never curl to APIs directly
- **Graph-only** — no markdown files for todos
- **Positional numbers** — always re-query to map positions, never cache
- **Ask routing** — when a todo mentions a person + implies a question, create both Todo and QuestionSet
- **No sub-boxes** — only outer frame `│` and `├────┤` separators
- **DO NOT output reasoning** — render directly
