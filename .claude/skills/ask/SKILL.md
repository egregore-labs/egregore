Ask a question — to a teammate, the org, or just think out loud.

## When to invoke

User says: "ask [name] about", "I need to check with [name]", "can you ask [name]", "question for [name]", "run this by [name]"
Not this: user is asking the agent a question it can answer from context — just answer directly

Arguments: $ARGUMENTS (Optional: [person] about [topic])

## Usage

- `/ask` or `/ask about [topic]` — Inward: reflect on your own context
- `/ask [person] about [topic]` — Outward: route questions to someone

## Step 1: Parse & Route

Parse `$ARGUMENTS`:
- **target**: first word if it matches a known person. **Connected mode:** query `MATCH (p:Person) RETURN p.name, p.github, p.fullName`. **Local mode:** read from `memory/people/` directory (filenames and frontmatter). Match against any of the three fields, case-insensitive. Else none.
- **topic**: everything after "about", or the full argument if no "about"

Strip `@` from names. Both `alice` and `@alice` work.

Get current user:
```bash
git config user.name
```
Map to short name: "Alice Smith" → alice, "Bob Jones" → bob, etc.

**If target is a person → Outward (Step 3)**
**Otherwise → Inward (Step 2)**

---

## Step 2: Inward Mode

## Mode detection

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

**Local mode** (`mode === "local"`): Skip ALL `bin/graph.sh` and `bin/notify.sh` calls — do NOT run them. Do NOT show any graph-related messaging ("Graph offline", Neo4j, QuestionSet, etc.).

Local-mode flow:
- **Step 1 (Parse)**: For person matching, read from `memory/people/` directory (list `.md` files, extract names) instead of querying the graph.
- **Step 2 (Inward)**: Skip ALL context queries. Answer from conversation context + memory files only (`memory/knowledge/`, `memory/handoffs/`, `memory/quests/`). Generate questions based on what you can see.
- **Step 3a (Outward harvest)**: Skip ALL graph context queries. Generate draft questions from conversation context only.
- **Step 3d (Store & notify)**: Do NOT create QuestionSet/Question nodes in Neo4j. Instead, save to `memory/knowledge/questions/{YYYY-MM-DD}-{topic-slug}.md` with frontmatter (from, to, topic, status: pending, questions list). Commit and push memory. Do NOT send notifications. Show: `✓ {n} questions saved to memory` (not "queued" or "notified").
- **Step 4 (Answer pending)**: Skip the pending questions query. Instead, scan `memory/knowledge/questions/` for files where the `to:` field matches the current user and `status: pending`. Present those for answering.

**Connected mode**: Full behavior including graph context, notifications, QuestionSet nodes.

---

### Context queries — CONNECTED MODE ONLY

**Skip this entire section in local mode.** Do not run any of these queries. Use conversation context and memory files instead.

**CRITICAL: Suppress raw output.** Never show raw JSON to the user. All `bin/graph.sh` and `bin/notify.sh` calls MUST capture output in a variable and only show formatted status lines.

```bash
# My recent sessions — capture output, don't display raw JSON
bash bin/graph.sh query "MATCH (s:Session)-[:BY]->(p:Person {name: '$me'}) RETURN s.topic AS topic, s.summary AS summary ORDER BY s.date DESC LIMIT 5"

# My active quests
bash bin/graph.sh query "MATCH (q:Quest {status: 'active'})-[:STARTED_BY|:CONTRIBUTED_BY*]->(p:Person {name: '$me'}) RETURN q.title AS title"

# Recent artifacts
bash bin/graph.sh query "MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person {name: '$me'}) RETURN a.title AS title, a.type AS type ORDER BY a.created DESC LIMIT 5"

# Org-wide recent activity (if topic provided, filter by topic)
bash bin/graph.sh query "MATCH (s:Session)-[:BY]->(p:Person) RETURN s.topic AS topic, p.name AS by, s.summary AS summary ORDER BY s.date DESC LIMIT 5"
```

Show a brief context summary, then generate 1-4 questions via AskUserQuestion.

**Question scope:**
- Topic is a specific decision → narrow (1-2 questions, single-select)
- Topic is exploratory/strategic → wide (3-4 questions, some multi-select)
- No topic → ask about priorities, open threads, stale quests

**Headers** (max 12 chars): Focus, Tradeoff, Blocker, Priority, Scope, Gap, Direction, Approach

**Options**: 2-4 per question, drawn from actual context. "Other" is automatic.

**After answers:**

```
Your responses captured.

Save as a reflection? I'll store it in the knowledge graph.
```

If yes → route to `/reflect` flow.

---

## Step 3: Outward Mode

### 3a: Harvest context (silent — no user interaction) — CONNECTED MODE ONLY

**Skip this entire section in local mode.** Generate draft questions from conversation context only.

Run in parallel:

```bash
# Sessions mentioning the topic
bash bin/graph.sh query "MATCH (s:Session)-[:BY]->(p:Person) WHERE toLower(s.summary) CONTAINS toLower('$topic') RETURN s.summary AS summary, p.name AS by ORDER BY s.date DESC LIMIT 5"

# Artifacts on the topic
bash bin/graph.sh query "MATCH (a:Artifact) WHERE toLower(a.title) CONTAINS toLower('$topic') OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(p:Person) RETURN a.title AS title, a.type AS type, p.name AS by ORDER BY a.created DESC LIMIT 5"

# Quests on the topic
bash bin/graph.sh query "MATCH (q:Quest) WHERE toLower(q.title) CONTAINS toLower('$topic') RETURN q.title AS title, q.status AS status"

# Target's recent work
bash bin/graph.sh query "MATCH (s:Session)-[:BY]->(p:Person {name: '$target'}) RETURN s.summary AS summary ORDER BY s.date DESC LIMIT 3"
```

### 3b: Generate draft questions using harvested context

Use the graph results as background to generate better questions — ones that don't ask what the graph already knows.

If the graph fully covers the topic, say so naturally:

```
The graph already has a lot on "$topic":
- [summary of what's known]

Still want to ask $target? Or is this enough?
```

If the user says enough → optionally offer `/reflect`. Done.

If the graph is thin or missing, proceed directly.

### 3c: Present draft questions — 1 interactive stop

Show what you'd send, with one AskUserQuestion:

```
Here's what I'd ask $target about "$topic":

1. [Draft question] [Header]
2. [Draft question] [Header]
```

AskUserQuestion:
- question: "Send these to $target, or adjust?"
- header: "Send"
- options:
  - "Send as-is" — Queue questions and notify $target
  - "Let me edit" — I'll adjust based on your input
- multiSelect: false

**If "Send as-is"** → store and notify (Step 3d)
**If "Let me edit"** → user provides edits via "Other", regenerate, then store

### 3d: Store & notify

**Connected mode:**

```bash
# Create QuestionSet + Questions in Neo4j
bash bin/graph.sh query "MATCH (asker:Person {name: '$me'}) MATCH (target:Person {name: '$target'}) CREATE (qs:QuestionSet {id: '$setId', topic: '$topic', created: datetime(), status: 'pending'}) CREATE (qs)-[:ASKED_BY]->(asker) CREATE (qs)-[:ASKED_TO]->(target) RETURN qs.id"
```

For each question:
```bash
bash bin/graph.sh query "MATCH (qs:QuestionSet {id: '$setId'}) CREATE (q:Question {id: '$qId', text: '$text', header: '$header'})-[:PART_OF]->(qs)"
```

Notify:
```bash
bash bin/notify.sh send "$target" "$me has questions about \"$topic\" — run /ask to answer"
```

Confirm:
```
✓ $n questions queued for $target
✓ Notified via Telegram
```

**Local mode:**

Do NOT create QuestionSet/Question nodes. Do NOT send notifications. Instead, save to markdown:

```bash
mkdir -p memory/knowledge/questions
cat > "memory/knowledge/questions/YYYY-MM-DD-${topic-slug}.md" << 'ASKEOF'
---
from: $me
to: $target
topic: $topic
status: pending
date: YYYY-MM-DD
---

## Questions

1. [$header] $text
2. [$header] $text
ASKEOF
```

Commit and push memory:
```bash
git -C memory add "knowledge/questions/"
git -C memory commit -m "ask: questions for $target about $topic" --quiet
git -C memory push origin main --quiet
```

Confirm:
```
✓ $n questions saved for $target
  → memory/knowledge/questions/YYYY-MM-DD-${topic-slug}.md
  $target will see these on their next /ask
```

Done. No further AskUserQuestion.

---

## Step 4: Answer Pending Questions

This triggers when `/activity` surfaces pending questions and the user acts on them, OR when the user runs `/ask` and has pending sets.

**Connected mode:**

```bash
bash bin/graph.sh query "MATCH (qs:QuestionSet {status: 'pending'})-[:ASKED_TO]->(p:Person {name: '$me'}) MATCH (qs)-[:ASKED_BY]->(asker:Person) RETURN qs.id AS setId, qs.topic AS topic, asker.name AS from ORDER BY qs.created DESC"
```

If multiple sets, AskUserQuestion to pick one.

Load questions → present via AskUserQuestion → store answers → update status → notify sender:

```bash
bash bin/notify.sh send "$asker" "$me answered your questions about \"$topic\""
```

**Local mode:**

Scan `memory/knowledge/questions/` for files where `to:` matches the current user and `status: pending`. Parse each file for questions. Present via AskUserQuestion. After answering, update the file's `status:` to `answered` and append the answers to the file. Commit and push memory. Do NOT send notifications.

---

## Error Handling

- **Person not found**: List known names (from graph in connected mode, from `memory/people/` in local mode), suggest checking spelling
- **Neo4j down (connected mode)**: Generate questions without context, skip graph storage, warn user
- **Local mode**: All operations use filesystem — no graph errors possible
- **No context for topic**: Skip harvest summary, proceed to draft questions directly

## Rules

- Generate questions dynamically — never hardcoded templates
- Reference actual context in questions (quest names, recent sessions, artifact titles)
- All Neo4j via `bin/graph.sh`, all notifications via `bin/notify.sh`
- Person-targeted is async — store, notify, exit
- Offer `/reflect` after inward mode answers
- `@` prefix optional on person names
