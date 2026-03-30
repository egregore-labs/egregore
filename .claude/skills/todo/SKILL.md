Manage personal todos.

## When to invoke

User says: "I need to remember", "add to my list", "what's on my plate", "mark done", "remind me to", "don't let me forget"
Not this: team-level exploration → `/quest` · something is broken → `/issue`

Arguments: $ARGUMENTS (Optional: text to add, "done N", "cancel N", quest slug, or "all")

## Usage

- `/todo` — List open todos
- `/todo [text]` — Add items from natural language
- `/todo done [N or text]` — Mark complete
- `/todo cancel [N or text]` — Mark cancelled
- `/todo check` — Walk through open items interactively
- `/todo check [quest-slug]` — Quest-scoped check-in
- `/todo [quest-slug]` — Quest-scoped view
- `/todo all` — Include done/cancelled (14 days)

## Step 0: Mode detection

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

**Local mode** (`mode === "local"`): Skip ALL `bin/graph.sh` calls — do NOT run them. Do NOT show any graph-related messaging ("Graph offline", "will sync", Neo4j, etc.).

Local-mode storage: `memory/todos/{person}.md` — a YAML-frontmatter markdown file per user.

Local-mode flow:
- **All routes** (add, list, done, cancel, check): same UX and TUI rendering, backed by YAML parse/write instead of Cypher queries.
- **Quest matching**: check `memory/quests/` directory for active quest files instead of graph query.
- **Person detection**: check `memory/people/` directory for person files instead of graph query.
- **CheckIn persistence**: not available in local mode (no graph storage). The check-in flow still works interactively but check-in history is not persisted.
- **Notifications**: skip entirely — do not mention notifications.

### Local-mode file format

File: `memory/todos/{person}.md`

```yaml
---
todos:
  - id: "2026-03-30-bartu-001"
    text: "review bugs manually"
    status: open
    priority: 0
    created: "2026-03-30T22:00:00Z"
    completed: null
    quest: null
    source: manual
    blockedBy: null
    deferredUntil: null
    lastNote: null
    lastTransition: null
---
```

### Local-mode route adjustments

- **Add**: Parse text, determine priority, check `memory/quests/` for quest matching (read frontmatter `status: active` from quest files). Append to the YAML `todos` array. Write file.
- **List**: Read the YAML file, filter by status, sort by priority desc then created desc. Render same TUI.
- **Done/Cancel**: Read file, find item by position or text match, update status + completed timestamp, write file.
- **Check**: Read file, filter active items, walk through with AskUserQuestion (same UX). Update statuses in YAML after each item. Skip CheckIn node creation.
- **Quest view**: Read file, filter todos where `quest` matches the slug. Same TUI with quest header.

**Connected mode**: Full behavior including graph nodes and notifications as specified below.

## Step 1: Get Current User

```bash
git config user.name
```

Map to short name: "Alice Smith" → alice, "Bob Jones" → bob, "Carol" → carol, "Dave" → dave

## Step 2: Parse Arguments

Parse `$ARGUMENTS` to determine route:

| Input | Route |
|-------|-------|
| (empty) | **List** open todos |
| `done [N or text]` | **Complete** — mark matching todo(s) done |
| `cancel [N or text]` | **Cancel** — mark matching todo(s) cancelled |
| `check` | **Check** — interactive walk-through of all active items |
| `check [quest-slug]` | **Check** — quest-scoped walk-through |
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

Query active todos (open, blocked, deferred):
```bash
bash bin/graph.sh query "MATCH (t:Todo)-[:BY]->(p:Person {name: '$me'}) WHERE t.status IN ['open', 'blocked', 'deferred'] OPTIONAL MATCH (t)-[:PART_OF]->(q:Quest) RETURN t.id AS id, t.text AS text, t.priority AS priority, t.status AS status, t.created AS created, t.source AS source, t.blockedBy AS blockedBy, t.deferredUntil AS deferredUntil, t.lastNote AS lastNote, q.id AS quest ORDER BY t.priority DESC, t.created DESC"
```

**If no results:** `No open todos. /todo [text] to add one.`

**If results exist, render TUI:**

```
┌──────────────────────────────────────────────────────────────────────┐
│  □ TODO                                                bob · Feb 09  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  [1] ★ fix retry logic in graph.sh                                   │
│      → egregore-reliability · 2d ago                                 │
│                                                                      │
│  [2] revisit pricing page copy                                       │
│      → pricing-strategy · today                                      │
│                                                                      │
│  [3] revisit pricing page copy                                       │
│      ✗ blocked: "waiting on design review" · 3d ago                  │
│                                                                      │
│  [4] finalize tier naming                                            │
│      ↓ deferred until Feb 15 · 5d ago                                │
│                                                                      │
│  [5] ask alice about MCP auth                                           │
│      ? pending ask · today                                           │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  5 active · /todo done [N] to complete · /todo check to review       │
└──────────────────────────────────────────────────────────────────────┘
```

Formatting rules:
- Filled star (★) prefix for priority >= 2
- Arrow (→) quest link + time ago on second line
- Question mark (?) prefix on second line for items with MENTIONS relationship (ask-routed)
- Status `blocked`: show `✗ blocked: "{blockedBy}" · {time ago}` on second line
- Status `deferred`: show `↓ deferred until {deferredUntil} · {time ago}` on second line
- Overdue deferred items (deferredUntil < today): show `↓ ★ overdue — deferred until {date}` on second line
- Time ago: under 1h show "Nm ago", 1-23h show "Nh ago", 1d "yesterday", 2-6d "Nd ago", 7d+ "Mon DD"
- Numbers are positional (based on display order, not stored IDs)
- Footer count says "active" (not "open") since it includes blocked + deferred

### List with `all` flag

Include done/cancelled from last 14 days alongside active items:
```bash
bash bin/graph.sh query "MATCH (t:Todo)-[:BY]->(p:Person {name: '$me'}) WHERE t.status IN ['open', 'blocked', 'deferred'] OR (t.status IN ['done', 'cancelled'] AND t.completed >= datetime() - duration('P14D')) OPTIONAL MATCH (t)-[:PART_OF]->(q:Quest) RETURN t.id AS id, t.text AS text, t.priority AS priority, t.status AS status, t.created AS created, t.completed AS completed, t.blockedBy AS blockedBy, t.deferredUntil AS deferredUntil, q.id AS quest ORDER BY t.status, t.priority DESC, t.created DESC"
```

Show status indicators:
```
│  ✓ fix retry logic in graph.sh (done 2d ago)                         │
│  ✗ old thing (cancelled yesterday)                                   │
│  ✗ blocked: waiting on design review (3d ago)                        │
│  ↓ deferred until Feb 15 (5d ago)                                    │
```

---

## Route: Quest View

Query todos linked to a specific quest (all active statuses):
```bash
bash bin/graph.sh query "MATCH (t:Todo)-[:PART_OF]->(q:Quest {id: '$questSlug'}) WHERE t.status IN ['open', 'blocked', 'deferred'] MATCH (t)-[:BY]->(p:Person) RETURN t.id AS id, t.text AS text, t.priority AS priority, t.status AS status, t.created AS created, t.blockedBy AS blockedBy, t.deferredUntil AS deferredUntil, p.name AS by ORDER BY t.priority DESC, t.created DESC"
```

Render same TUI as List but with quest name in header:
```
┌──────────────────────────────────────────────────────────────────────┐
│  □ TODO · egregore-reliability                         bob · Feb 09  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  [1] ★ fix retry logic in graph.sh (bob, 2d ago)                     │
│  [2] investigate connection pooling (alice, today)                      │
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
│  □ TODO ADDED                                          bob · Feb 09  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ✓ fix retry logic in graph.sh                                       │
│    → egregore-reliability                                            │
│                                                                      │
│  ✓ revisit pricing page copy                                         │
│    → pricing-strategy                                                │
│                                                                      │
│  ✓ ask alice about MCP auth                                             │
│    ? queued for alice · notified                                        │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  3 added · 7 open total                                              │
│  /todo to see all · /todo done [N] to complete                       │
└──────────────────────────────────────────────────────────────────────┘
```

For ask-routed items, show `? queued for [person] · notified` on the second line.

---

## Route: Check

Interactive walk-through of active items. Captures non-binary state transitions with freeform context. Each check-in is archived as a graph event.

### Step 1: Fetch active items

If a quest-slug argument was provided (`/todo check [quest-slug]`), scope to that quest:
```bash
bash bin/graph.sh query "MATCH (t:Todo)-[:PART_OF]->(q:Quest {id: '$questSlug'}) WHERE t.status IN ['open', 'blocked', 'deferred'] MATCH (t)-[:BY]->(p:Person) RETURN t.id AS id, t.text AS text, t.status AS status, t.priority AS priority, t.created AS created, t.blockedBy AS blockedBy, t.deferredUntil AS deferredUntil, t.lastNote AS lastNote, q.id AS quest, p.name AS by ORDER BY t.priority DESC, t.created DESC"
```

Otherwise, fetch all active items for the current user:
```bash
bash bin/graph.sh query "MATCH (t:Todo)-[:BY]->(p:Person {name: '$me'}) WHERE t.status IN ['open', 'blocked', 'deferred'] OPTIONAL MATCH (t)-[:PART_OF]->(q:Quest) RETURN t.id AS id, t.text AS text, t.status AS status, t.priority AS priority, t.created AS created, t.blockedBy AS blockedBy, t.deferredUntil AS deferredUntil, t.lastNote AS lastNote, q.id AS quest ORDER BY t.priority DESC, t.created DESC"
```

**If no results:** `No active todos to review. /todo [text] to add one.`

### Step 2: 20+ items guard

If 20+ items returned, show AskUserQuestion first:
```
header: "Scope"
question: "You have N active todos. Walk through all, or focus on a quest?"
options:
  - label: "All items"
    description: "Walk through all N todos"
  - label: "{quest-slug-1}"
    description: "{count} items in this quest"
  - label: "{quest-slug-2}"
    description: "{count} items in this quest"
  - label: "Unlinked only"
    description: "{count} items not linked to any quest"
```

If a quest is selected, re-filter the items to that quest only.

### Step 3: Display check-in dashboard

Render TUI showing items grouped by quest, with overdue deferred items surfaced first:

```
┌──────────────────────────────────────────────────────────────────────┐
│  □ CHECK-IN                                            bob · Feb 10  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ↓ ★ OVERDUE                                                         │
│  [1] ↓ finalize tier naming (deferred until Feb 08)                  │
│                                                                      │
│  → egregore-reliability                                              │
│  [2]   fix retry logic in graph.sh                                   │
│  [3] ✗ investigate connection pooling (blocked)                      │
│                                                                      │
│  → pricing-strategy                                                  │
│  [4]   revisit pricing page copy                                     │
│                                                                      │
│  ○ unlinked                                                          │
│  [5]   ask alice about MCP auth                                         │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  5 items to review · walking through now                             │
└──────────────────────────────────────────────────────────────────────┘
```

Status indicators in dashboard: `✗` blocked, `↓` deferred, blank for open.

### Step 4: Walk through each item

Present one AskUserQuestion per item. Options adapt based on current status:

**For `open` items:**
```
header: "Todo N/M"
question: "{todo text}\n{quest link if any} · {time ago}"
options:
  - label: "Done"
    description: "Mark complete — optionally add outcome note"
  - label: "Progressing"
    description: "Still working — optionally add progress note"
  - label: "Blocked"
    description: "Something is blocking this (required: what)"
  - label: "Evolved"
    description: "Has changed — close this, create new todo(s)"
  - label: "Deferred"
    description: "Postpone — required: when to revisit"
  - label: "Dropped"
    description: "No longer needed — optionally say why"
multiSelect: false
```

**For `blocked` items:**
```
header: "Todo N/M"
question: "{todo text}\n✗ blocked: \"{blockedBy}\" · {time ago}"
options:
  - label: "Still blocked"
    description: "No change — skip this item"
  - label: "Unblocked → Progressing"
    description: "Blocker resolved, back to active"
  - label: "Done"
    description: "Completed despite blocker"
  - label: "Evolved"
    description: "Has changed — close this, create new todo(s)"
  - label: "Dropped"
    description: "No longer needed"
multiSelect: false
```

**For `deferred` items:**
```
header: "Todo N/M"
question: "{todo text}\n↓ deferred until {deferredUntil} · {time ago}"
options:
  - label: "Still deferred"
    description: "Not ready yet — skip this item"
  - label: "Reactivate → Progressing"
    description: "Ready to work on again"
  - label: "Done"
    description: "Already handled"
  - label: "Dropped"
    description: "No longer needed"
multiSelect: false
```

If user selects "Other" (skip), no mutation — move to next item.

### Step 5: Context capture after state selection

After each state selection, capture context where required:

| State | Context | Handling |
|-------|---------|----------|
| **Done** | Optional note | Ask "Any notes on the outcome? (enter to skip)" — if provided, store as `lastNote` |
| **Progressing** | Optional note | Ask "Progress note? (enter to skip)" — if provided, store as `lastNote` |
| **Blocked** | Required | Ask "What's blocking this?" — must provide answer, store as `blockedBy` |
| **Evolved** | Required | Ask "How has this changed? Describe the new todo(s)." — parse into new todo text(s) |
| **Deferred** | Required | Ask "When should this be revisited? (e.g., 'next week', 'Feb 20', '3 days')" — parse into date, store as `deferredUntil` |
| **Dropped** | Optional | Ask "Why dropped? (enter to skip)" — if provided, store as `lastNote` |

Use AskUserQuestion for required context, freeform text input via "Other" for optional context.

### Step 6: Apply graph mutation immediately

After each item (not batched — prevents data loss on interrupted sessions):

**Done:**
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$todoId'}) SET t.status = 'done', t.completed = datetime(), t.lastCheckIn = date(), t.lastTransition = 'done', t.lastTransitionDate = datetime(), t.lastNote = '$note' RETURN t.id"
```

**Progressing:**
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$todoId'}) SET t.lastCheckIn = date(), t.lastTransition = 'progressing', t.lastTransitionDate = datetime(), t.lastNote = '$note' RETURN t.id"
```

**Blocked:**
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$todoId'}) SET t.status = 'blocked', t.blockedBy = '$blockerText', t.lastCheckIn = date(), t.lastTransition = 'blocked', t.lastTransitionDate = datetime() RETURN t.id"
```

**Evolved:** Close original, create new todo(s):
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$todoId'}) SET t.status = 'done', t.completed = datetime(), t.lastCheckIn = date(), t.lastTransition = 'evolved', t.lastTransitionDate = datetime(), t.evolvedTo = '$newTodoIds', t.lastNote = '$description' RETURN t.id"
```
Then create new todo(s) using the same Add route logic (ID generation, quest inheritance, person link). New todos inherit the quest link from the original.

**Deferred:**
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$todoId'}) SET t.status = 'deferred', t.deferredUntil = date('$parsedDate'), t.priority = CASE WHEN t.priority > 0 THEN t.priority - 1 ELSE 0 END, t.lastCheckIn = date(), t.lastTransition = 'deferred', t.lastTransitionDate = datetime() RETURN t.id"
```

**Dropped:**
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$todoId'}) SET t.status = 'cancelled', t.completed = datetime(), t.lastCheckIn = date(), t.lastTransition = 'dropped', t.lastTransitionDate = datetime(), t.lastNote = '$note' RETURN t.id"
```

**Unblocked → Progressing:**
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$todoId'}) SET t.status = 'open', t.blockedBy = null, t.lastCheckIn = date(), t.lastTransition = 'unblocked', t.lastTransitionDate = datetime() RETURN t.id"
```

**Reactivate → Progressing:**
```bash
bash bin/graph.sh query "MATCH (t:Todo {id: '$todoId'}) SET t.status = 'open', t.deferredUntil = null, t.lastCheckIn = date(), t.lastTransition = 'reactivated', t.lastTransitionDate = datetime() RETURN t.id"
```

**Still blocked / Still deferred / Skip:** No mutation — track in summary counters only.

### Step 7: Create CheckIn node

After all items are reviewed, create a CheckIn node in Neo4j:

```bash
bash bin/graph.sh query "MATCH (p:Person {name: '$me'}) CREATE (c:CheckIn {id: '$checkinId', date: date(), summary: '$summary', totalItems: $total, itemsDone: $done, itemsProgressing: $progressing, itemsBlocked: $blocked, itemsEvolved: $evolved, itemsDeferred: $deferred, itemsDropped: $dropped, itemsSkipped: $skipped}) CREATE (c)-[:BY]->(p) RETURN c.id"
```

CheckIn ID format: `checkin-YYYY-MM-DD-{person}-NNN`

Link CheckIn to all reviewed todos:
```bash
bash bin/graph.sh query "MATCH (c:CheckIn {id: '$checkinId'}) MATCH (t:Todo) WHERE t.id IN \$todoIds CREATE (c)-[:REVIEWED]->(t)" '{"todoIds": ["id1", "id2"]}'
```

If quest-scoped, also link to quest:
```bash
bash bin/graph.sh query "MATCH (c:CheckIn {id: '$checkinId'}) MATCH (q:Quest {id: '$questSlug'}) CREATE (c)-[:DURING]->(q)"
```

### Step 8: Show summary TUI

Render check-in summary with state distribution + quest pulse:

```
┌──────────────────────────────────────────────────────────────────────┐
│  □ CHECK-IN COMPLETE                                   bob · Feb 10  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ✓ 1 done · → 2 progressing · ✗ 1 blocked · ↓ 1 deferred           │
│                                                                      │
│  ⚑ QUEST PULSE                                                      │
│  egregore-reliability    → →  ✗                     2/3 moving       │
│  pricing-strategy        → ✓                        1/1 done         │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  /todo to see active · /activity for dashboard                       │
└──────────────────────────────────────────────────────────────────────┘
```

State sigils: `✓` done, `→` progressing, `✗` blocked, `↻` evolved, `↓` deferred, `✕` dropped, `·` skipped

Quest Pulse shows per-quest distribution as a row of sigils with a health summary:
- All progressing/done → `{n}/{total} moving`
- >50% blocked → `stalling`
- All deferred → `hibernating`
- Mixed → `{n}/{total} moving`

### Step 9: Offer blocker routing

If any items were marked "Blocked" and the blocker text mentions a person name (cross-reference against people in graph):

```bash
bash bin/graph.sh query "MATCH (p:Person) RETURN p.name AS name"
```

If a person is mentioned in a blocker, offer:
```
"{person}" was mentioned as a blocker. Route to /ask {person}?
```

Use AskUserQuestion with options: "Yes, ask {person}" and "No, skip".

If yes, invoke the `/ask` flow targeting that person with the blocked todo context.

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
| Neo4j unavailable (connected mode) | Still attempt file-based save. Show warning: "Graph offline — file saved, will sync on next /save" |
| Local mode | Skip all graph calls silently — no warnings, no "graph offline" messaging. YAML file is the source of truth. TUI renders identically. |
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
  id: String,                  // "2026-02-09-bob-001"
  text: String,                // "fix retry logic in graph.sh"
  status: String,              // "open" | "done" | "cancelled" | "blocked" | "deferred"
  created: datetime(),
  completed: datetime(),       // null until done
  priority: Integer,           // 0-3
  topics: [String],            // auto-detected for quest matching
  source: String,              // "manual" | "handoff" | "session"
  lastCheckIn: date(),         // date of last check-in review
  lastNote: String,            // freeform context from last transition
  lastTransition: String,      // "done" | "progressing" | "blocked" | "evolved" | "deferred" | "dropped" | "unblocked" | "reactivated"
  lastTransitionDate: datetime(),
  blockedBy: String,           // what's blocking (set when status=blocked)
  deferredUntil: date(),       // when to revisit (set when status=deferred)
  evolvedTo: String            // comma-separated IDs of successor todos
})

(:CheckIn {
  id: String,              // "checkin-2026-02-09-bob-001"
  date: date(),
  summary: String,         // "1 done, 2 progressing, 1 blocked"
  totalItems: Integer,
  itemsDone: Integer,
  itemsProgressing: Integer,
  itemsBlocked: Integer,
  itemsEvolved: Integer,
  itemsDeferred: Integer,
  itemsDropped: Integer,
  itemsSkipped: Integer
})

Relationships:
  (Todo)-[:BY]->(Person)           // owner
  (Todo)-[:PART_OF]->(Quest)       // linked quest (optional)
  (Todo)-[:MENTIONS]->(Person)     // for /ask routing (optional)
  (CheckIn)-[:BY]->(Person)        // who did the check-in
  (CheckIn)-[:REVIEWED]->(Todo)    // which todos were reviewed
  (CheckIn)-[:DURING]->(Quest)     // quest scope (if quest-scoped check-in)
```

## Rules

- **All Neo4j via bin/graph.sh** — never construct curl calls directly
- **All notifications via bin/notify.sh** — never curl to APIs directly
- **Graph-only** — no markdown files for todos
- **Positional numbers** — always re-query to map positions, never cache
- **Ask routing** — when a todo mentions a person + implies a question, create both Todo and QuestionSet
- **No sub-boxes** — only outer frame `│` and `├────┤` separators
- **DO NOT output reasoning** — render directly
