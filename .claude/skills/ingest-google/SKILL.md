Google Workspace content ingestion — promote personal Google content to shared memory.

Arguments: $ARGUMENTS (Optional: service name, search query, or --auto flag)

## When to invoke

Routed from `/ingest` when content type is Google Workspace. Not invoked directly by users.

## Prerequisites

Before starting, verify:
1. `google_connector: true` in `.egregore-state.json`
2. `google_auth_complete: true` in `.egregore-state.json`

If not met: "Google connector not set up. Run `/connect google` first."

## What to do

### Step 1: Select content

**If $ARGUMENTS specifies a service and ID** (e.g., "drive 1BxiMVs0XRA5"):
- Fetch directly: `bash bin/connector-google.sh <service> get <id>`

**If $ARGUMENTS specifies a service** (e.g., "drive", "gmail"):
- List recent items: `bash bin/connector-google.sh <service> list`
- Show the user a summary of available items
- AskUserQuestion: which item to promote

**If $ARGUMENTS has a search query** (e.g., "quarterly report"):
- Search across services: `bash bin/connector-google.sh drive search "<query>"`
- Show results
- AskUserQuestion: which result to promote

**If $ARGUMENTS is empty or ambiguous:**
- AskUserQuestion:
  ```
  question: "What Google content do you want to bring in?"
  options:
    - label: "Drive file"
      description: "A file or folder from Google Drive"
    - label: "Gmail thread"
      description: "An email conversation"
    - label: "Calendar event"
      description: "A meeting or event"
    - label: "Google Doc"
      description: "A document (exported as text)"
    - label: "Google Sheet"
      description: "A spreadsheet"
  ```
- Then list/search within the selected service

### Step 2: Fetch content

Use the connector CLI to fetch the selected item:

```bash
bash bin/connector-google.sh <service> get <id>
```

Parse the JSON output. The content is now in the personal cache at `~/.egregore/context/google/`.

### Step 3: Analyze content

**This is where Claude adds value.** Read the content and extract:

1. **Summary** — 2-3 sentences capturing the key points
2. **Topics** — 3-5 tags describing the content themes
3. **Mentioned people** — match names/emails against org members:
   ```bash
   bash bin/graph.sh query "MATCH (p:Person) RETURN p.name, p.github"
   ```
4. **Related quests** — match themes against active quests:
   ```bash
   bash bin/graph.sh query "MATCH (q:Quest) WHERE q.status <> 'closed' RETURN q.name, q.description"
   ```

### Step 4: PII scan

Check for PII that shouldn't cross the personal→shared boundary:
- Email addresses outside the org domain
- Phone numbers
- Physical addresses

If found, flag to the user: "This content contains external email addresses. Include them in shared memory?"

### Step 5: Review (interactive, default)

Show the user:
```
Content: [title]
Summary: [extracted summary]
Topics: [tag1, tag2, tag3]
Mentions: [alice, bob] (matched from org graph)
Quests: [quest-name] (matched from active quests)
```

AskUserQuestion:
```
question: "Review the extraction. Confirm or edit?"
options:
  - label: "Confirm"
    description: "Promote to shared memory as-is"
  - label: "Edit topics"
    description: "Add or remove topic tags"
  - label: "Edit connections"
    description: "Change mentioned people or related quests"
  - label: "Cancel"
    description: "Don't promote this content"
```

If user says "just do it" at any point, switch to auto mode for remainder.

**Auto mode** (when --auto flag passed or user opted in):
Skip interactive review, auto-promote with Claude's extraction.

### Step 6: Write to shared memory

Generate the markdown file:

```bash
# Get the promotion payload
bash bin/connector-google.sh promote <service> <id>
```

Then write the markdown file to `memory/knowledge/sources/google/`:

File naming: `YYYY-MM-DD-<service>-<slug>.md`

Content format:
```yaml
---
title: "<title>"
type: source
origin: google-<service>
google_id: <id>
author: <username>
date: YYYY-MM-DD
summary: "<summary>"
topics: [topic1, topic2, topic3]
mentions: [person1, person2]
quests: [quest-name]
---

<content>
```

### Step 7: Update graph

Create the Artifact node and connections via graph queries:

```bash
# Core artifact
bash bin/graph.sh query "MERGE (a:Artifact {google_id: \$googleId})
ON CREATE SET a.id = randomUUID(), a.title = \$title, a.type = 'source',
  a.origin = \$origin, a.created = date(), a.filePath = \$filePath,
  a.summary = \$summary, a.topics = \$topics
ON MATCH SET a.summary = \$summary, a.topics = \$topics, a.updated = date()
RETURN a.id" '{"googleId":"<id>","title":"<title>","origin":"google-<service>","filePath":"<path>","summary":"<summary>","topics":["t1","t2"]}'

# Author link
bash bin/graph.sh query "MATCH (a:Artifact {google_id: \$googleId}), (p:Person {github: \$author})
MERGE (a)-[:CONTRIBUTED_BY]->(p)" '{"googleId":"<id>","author":"<username>"}'

# Mentioned people
bash bin/graph.sh query "MATCH (a:Artifact {google_id: \$googleId})
UNWIND \$mentions AS name
MATCH (p:Person {name: name})
MERGE (a)-[:MENTIONS]->(p)" '{"googleId":"<id>","mentions":["alice","bob"]}'

# Quest connections
bash bin/graph.sh query "MATCH (a:Artifact {google_id: \$googleId})
UNWIND \$quests AS qname
MATCH (q:Quest {name: qname})
MERGE (a)-[:RELATES_TO]->(q)" '{"googleId":"<id>","quests":["quest-name"]}'
```

### Step 8: Confirm

"Promoted **[title]** to shared memory.
- File: `memory/knowledge/sources/google/[filename]`
- Topics: [tags]
- Mentions: [people]
- Quests: [quests]

Run `/save` to push to the remote."

### Step 9: Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"ingest-google","service":"<service>"}' 2>/dev/null &
```
