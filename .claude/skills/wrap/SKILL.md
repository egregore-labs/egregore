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

## Step 2.5: Infrastructure harvest

Scan the session for infrastructure mentions not yet in the registry.

### Detect unregistered infrastructure

1. Read the observation buffer for this session:
   ```bash
   SID=$(cat .egregore-session-id 2>/dev/null)
   cat /tmp/egregore-obs-${SID}.jsonl 2>/dev/null
   ```

2. Also scan the conversation history for mentions of:
   - Platform names: netlify, vercel, railway, supabase, heroku, fly.io, render, docker
   - URL patterns: `*.netlify.app`, `*.railway.app`, `*.vercel.app`, `*.supabase.co`, `*.fly.dev`
   - CLI commands: `netlify deploy`, `railway up`, `vercel --prod`, `docker push`
   - Service names that look like infrastructure (site names, project IDs, database instances)

3. Load existing registry:
   ```bash
   cat memory/infrastructure/services.yml 2>/dev/null
   ```

4. Compare: identify any infrastructure mentioned in the session that is NOT already registered.

### Offer to register

If unregistered infrastructure is found, use AskUserQuestion:

```
header: "Infrastructure"
question: "I noticed infrastructure not in the service registry:\n\n{list of detected services with URLs if found}\n\nRegister these so other sessions can find them?"
options:
  - label: "Yes, register all"
    description: "Add to memory/infrastructure/services.yml"
  - label: "Pick which ones"
    description: "I'll select from the list"
  - label: "Skip"
    description: "Don't register now"
```

If "Yes, register all" or selected items:
- For each service, derive: name, type, url (from context), credentials ("unknown — ask {author}"), notes (from conversation context)
- Append entries to `memory/infrastructure/services.yml`
- Set `added_by` to current author, `added_date` to today

If "Skip" or no infrastructure detected: proceed silently to Step 3.

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

## Step 3.5: Notify handoff authors (if implementing)

Check if this session implements any handoffs:
```bash
bash bin/graph-op.sh check-implements "$SID" 2>/dev/null
```

If results are returned (this session IMPLEMENTS a handoff):
1. Collect what was produced this session: PRs (from `git log`), files changed, commits
2. For each implemented handoff, notify the original author via Telegram:
   ```bash
   bash bin/notify.sh send "$AUTHOR_NAME" "$IMPLEMENTOR worked on your handoff '$TOPIC' — $SUMMARY" 2>/dev/null &
   ```
   Where `$SUMMARY` is a brief description like "PR #265 opened, 3 commits" or "3 files changed".
3. Mark the handoff as `done`:
   ```bash
   bash bin/graph-op.sh mark-done "$HANDOFF_SESSION_ID" 2>/dev/null &
   ```

This fires only when someone explicitly claimed a handoff at session start. No false positives.

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

## Step 7.5: Session Report (optional)

<!-- This step runs in BOTH local and connected modes — gated only on report_url, NOT on mode. -->

**Gate**: Check if `report_url` is configured in `egregore.json`:
```bash
jq -r '.report_url // empty' egregore.json
```
If empty, skip this entire step. If `report_url` is set, **always run this step regardless of mode** (local or connected).

### 7.5.1 Ask to share

AskUserQuestion:
```
header: "Share"
question: "Share a session report with the Egregore team? Helps us improve the product."
options:
  - label: "Yes, share report"
    description: "Sends an AI-analyzed summary + your description. Never sends code or conversation content."
  - label: "No thanks"
    description: "Skip — your session stays private"
```

If "No thanks" → skip to Step 7.6.

### 7.5.2 Generate structured report

The agent generates a JSON report from the session context already gathered in Steps 0–1:

```json
{
  "report_type": "session",
  "topic": "{topic from Step 1}",
  "summary": "{summary from Step 1}",
  "gaps": [
    {"type": "missing_skill|missing_tool|repeated_failure|wrong_info|confusing_ux", "detail": "..."}
  ],
  "system_info": {"mode": "local|connected", "framework_version": "2", "platform": "darwin|linux", "shell": "zsh|bash"},
  "session_duration_ms": 0,
  "message_count": 0
}
```

The `gaps` array is the agent's introspective analysis of the session: commands the user wanted but didn't exist, repeated errors, confusing moments, missing information. If the session went smoothly, `gaps` can be empty.

### 7.5.3 Ask for user note

AskUserQuestion:
```
header: "Details"
question: "Anything specific you'd like to share? (bugs, suggestions, what went well)"
options:
  - label: "Just the summary"
    description: "Send the AI analysis only"
  - label: "Add a note"
    description: "I'll write a brief description"
```

If "Add a note": wait for the user's free-text response. Set it as the `description` field in the report JSON.

### 7.5.4 Ask about GitHub issue

First check if `gh` is available:
```bash
gh auth status 2>/dev/null
```

If `gh` is authenticated, AskUserQuestion:
```
header: "GitHub"
question: "Also create a GitHub issue on egregore-labs/egregore?"
options:
  - label: "Yes, create issue"
    description: "Public issue with sanitized content — helps us track and prioritize"
  - label: "No"
    description: "Report goes to Supabase only"
```

If `gh` is not authenticated, skip this step.

### 7.5.5 Submit

Pipe the report JSON to the submission script:
```bash
echo '$REPORT_JSON' | bash bin/session-report.sh submit 2>/dev/null
```

Show progress: `✓ Report shared`

### 7.5.6 Create GitHub issue (if selected)

Apply sanitization rules (same as `/issue` Step 4 — replace org name, person names, token patterns):

```bash
gh issue create --repo egregore-labs/egregore \
  --title "Session report: $TOPIC" \
  --body "$SANITIZED_BODY"
```

Capture the returned URL. Show: `✓ GitHub issue #N created`

Set `github_issue_url` on the report if the Supabase insert already succeeded (best-effort update).

### 7.5.7 Record in TUI

Add a line to the Step 8 confirmation box status section:
- If report shared + GitHub issue: `✓ Report shared · GitHub #N`
- If report shared only: `✓ Report shared`
- If skipped: omit

## Step 7.6: Worktree

Do NOT call ExitWorktree or clean up the worktree. The WorktreeRemove hook handles cleanup automatically when the session ends.

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
│  ✓ Report shared · GitHub #42                                        │
│  Pick up where you left off with /activity.                          │
└──────────────────────────────────────────────────────────────────────┘
```

If no links were made, omit the links section (and its separator).

The `✓ Report shared` line only appears if the user shared a session report in Step 7.5. Include `· GitHub #N` if a GitHub issue was created. Omit the entire line if the user declined or reporting was not configured.

**Output the TUI box directly as a code block.** Do not narrate or explain it.
