Close your session with a personal summary. Saves everything.

Enriches the auto-captured Session node with topic, summary, and connections.

## When to invoke

User says: "done", "wrapping up", "that's it", "let me wrap", "I'm done for now", "good stopping point", "call it a day", "wrap up", "wrap it"
Not this: "hand off to X" → `/handoff` · "push" or "keep working" → `/save`

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## Execution rules

**Neo4j-first.** All queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl to Neo4j.
**WAL-first for writes.** All graph mutations go through `bash bin/graph-wal.sh append` first, then direct write as best-effort.
**CRITICAL: Suppress raw output.** Never show raw JSON to the user. All `bin/graph.sh` and `bin/graph-wal.sh` calls MUST redirect stdout: pipe to `/dev/null` or capture in a variable. Only show formatted progress lines.

- 1 Bash call: `git config user.name`
- Session ID from `~/.egregore/session-{hash}.id`
- Git log + diff stat for context
- 3-5 Neo4j queries for context gathering
- 1-2 AskUserQuestion calls for validation + link suggestions
- Graph writes via WAL + direct
- Wrap file to `memory/wraps/YYYY-MM/`
- Auto-save via `/save` flow
- Telemetry emit
- TUI confirmation

## Step 0: Gather context (parallel)

### Get current user and session ID

```bash
git config user.name
```

Derive author handle: lowercase first word of git user.name.

Read session ID:
```bash
PROJ_HASH=$(echo -n "$(pwd)" | md5 2>/dev/null || echo -n "$(pwd)" | md5sum 2>/dev/null | cut -d' ' -f1)
cat "$HOME/.egregore/session-${PROJ_HASH}.id" 2>/dev/null
```

### Git context (parallel)

Run in parallel:
1. `git log --oneline -20` — recent commits on current branch
2. `git diff --stat develop` — files changed vs develop
3. `git branch --show-current` — current branch name

### Graph context (parallel, suppress output)

Run in parallel:
1. Active todos for this user (LIMIT 10):
   ```cypher
   MATCH (t:Todo)-[:BY]->(p:Person)
   WHERE toLower(p.name) = $author AND t.status <> 'done'
   RETURN t.id AS id, t.text AS text, t.status AS status
   ORDER BY t.created DESC LIMIT 10
   ```

2. Active quests (LIMIT 10):
   ```cypher
   MATCH (q:Quest) WHERE q.status = 'active'
   RETURN q.id AS id, q.title AS title
   ORDER BY q.priority DESC LIMIT 10
   ```

3. Today's artifacts by this user:
   ```cypher
   MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person)
   WHERE toLower(p.name) = $author AND date(a.created) = date()
   RETURN a.id AS id, a.title AS title, a.type AS type
   LIMIT 10
   ```

## Step 1: Generate AI summary

Synthesize the conversation history + git activity into a structured summary:

- **Topic**: 3-6 word description of what was worked on (derive from commits + conversation)
- **Summary**: 2-4 sentences covering: what was worked on, key outcomes/decisions, current state
- **Open threads**: Bullet list of unfinished items or next steps

If `$ARGUMENTS` is provided, use it as the topic directly.

## Step 2: Validate summary (AskUserQuestion)

```
header: "Session"
question: "Does this capture your session?\n\n**Topic:** [topic]\n\n[summary]\n\n**Open threads:**\n[bullets]"
options:
  - label: "Yes, looks right"
    description: "Save as-is"
  - label: "Needs adjustment"
    description: "I'll refine the summary"
```

If "Needs adjustment": ask a follow-up AskUserQuestion with a text input to refine. Apply changes.

## Step 3: Link suggestions (AskUserQuestion, multiSelect)

Based on context from Step 0, suggest connections:

Build options list dynamically from:
- Quest links: quests whose topic overlaps with the session topic
- Todo completions: open todos that match accomplished work
- New todos: derived from open threads

Present with multiSelect:
```
header: "Links"
question: "Connect this session to any of these?"
options: [dynamically built from context — max 4]
multiSelect: true
```

If no relevant links found, skip this step entirely.

## Step 4: Execute batch

All writes go through WAL first (`bash bin/graph-wal.sh append`), then direct write (`bash bin/graph.sh query`). Suppress all output.

### 4.1 Update personal Session node

```cypher
MATCH (s:Session {id: $sid})
SET s.status = 'wrapped', s.topic = $topic, s.summary = $summary,
    s.wrappedAt = datetime(), s.filePath = $filePath,
    s.openThreads = $openThreads
RETURN s.id
```

Where `$openThreads` is a JSON array of strings from the "Open threads" list generated in Step 1 (e.g. `["finish retry logic", "review pricing copy"]`). This powers the "PICK UP WHERE YOU LEFT OFF" section in `/dashboard`.

If no Session node exists (auto-capture missed), create one:
```cypher
MERGE (s:Session {id: $sid})
ON CREATE SET s.date = date($date), s.status = 'wrapped',
  s.startedAt = datetime(), s.branch = $branch
SET s.topic = $topic, s.summary = $summary,
    s.wrappedAt = datetime(), s.filePath = $filePath,
    s.openThreads = $openThreads
WITH s
MATCH (p:Person) WHERE toLower(p.name) = $author
MERGE (s)-[:BY]->(p)
RETURN s.id
```

### 4.2 Link to quests (if selected in Step 3)

For each selected quest:
```cypher
MATCH (s:Session {id: $sid}), (q:Quest {id: $qId})
MERGE (s)-[:INVOLVES]->(q)
```

### 4.3 Complete todos (if selected in Step 3)

For each selected todo:
```cypher
MATCH (t:Todo {id: $tId})
SET t.status = 'done', t.completed = datetime()
RETURN t.id
```

### 4.4 Create new todos (if specified in Step 3)

Same pattern as `/todo` command — create Todo node, link to person, link to quest if relevant.

## Step 5: Write wrap file

Path: `memory/wraps/YYYY-MM/DD-author-topic-slug.md`

Create directory first: `mkdir -p memory/wraps/YYYY-MM`

Derive topic-slug: lowercase, replace spaces with hyphens, strip non-alphanumeric except hyphens, max 40 chars.

Write via Bash heredoc (memory/ symlink boundary):
```bash
cat > memory/wraps/YYYY-MM/DD-author-topic-slug.md << 'EOF'
# Wrap: [Topic]

**Date**: YYYY-MM-DD
**Author**: [author]
**Branch**: [branch]
**Session**: [session ID]

## Summary
[validated summary]

## What Changed
[files touched, commits — from git context]

## Open Threads
- [ ] [unfinished items from open threads]

## Connections
- Quest: [quest links, if any]
- Done: [completed todos, if any]
- Added: [new todos, if any]
EOF
```

Then commit and push from the memory repo:
```bash
cd memory && git add -A && git commit -m "Wrap: [topic-slug]" && git push && cd -
```

## Step 6: Auto-save

Run the `/save` flow: commit + push working branch, create PR to develop if needed. Follow the same logic as `/save` command.

## Step 7: Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"wrap"}' 2>/dev/null &
```

## Step 8: Confirmation TUI

Display the wrap confirmation using the standard TUI box format. 72-char outer width. 4 line patterns only (top `┌─┐`, separator `├─┤`, content `│ │`, bottom `└─┘`). No sub-boxes.

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◎ WRAP                                            cem · Feb 19     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  [topic]                                                             │
│  [branch]                                                            │
│                                                                      │
│  [2-3 line summary]                                                  │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ [completed todo] (done)                                           │
│  + [new todo] (added)                                                │
│  → [quest-id]                                                        │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                         │
│  Pick up where you left off with /activity.                          │
└──────────────────────────────────────────────────────────────────────┘
```

If no links were made, omit the links section (and its separator).

**Output the TUI box directly as a code block.** Do not narrate or explain it.
