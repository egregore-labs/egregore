Report an issue. Captures context and routes to the right place.

## When to invoke

User says: "this is broken", "bug in", "something's wrong with", "file an issue", "report a problem", "[command] isn't working"
Not this: personal task → `/todo` · team exploration → `/quest`

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after (create mode only).

## Mode detection

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

**Local mode** (`mode === "local"`): Skip ALL `bin/graph.sh` and `bin/notify.sh` calls — do NOT run them. Do NOT show any graph-related messaging ("Graph offline", "will sync", Neo4j, etc.).

Local-mode flow:
- **Create mode**: Step 0 context capture — run Bash call 1 (git identity + state) normally; skip Bash call 2's `bin/graph.sh test` line (keep the memory-symlink and egregore.json checks); skip the Neo4j recent-session query entirely. Steps 1-2 (description, smart routing) work normally. Step 3 — write the markdown file to `memory/knowledge/issues/` normally, but skip the Neo4j `CREATE (i:Issue)` node and the progress message referencing "graph". Step 4 — skip graph routing updates (Neo4j node creation, relationship updates), but preserve `gh issue create` if the smart routing targets a GitHub repo (GitHub CLI is independent of the graph). Skip Step 5 notifications entirely. Steps 6-7 (auto-save, confirmation TUI) work normally — in the TUI, show `✓ Saved to memory` (omit "graphed" and "team notified").
- **List mode**: Read issues from `memory/knowledge/issues/` directory — derive `id` from filename (e.g., `2026-03-30-memory-bug.md` → `memory-bug`), parse frontmatter for `title`, `status`, `recipient`, `date` (display as created), `topics`, `author` (display as reportedBy). Render same TUI.
- **Close mode**: Find issue file in `memory/knowledge/issues/`, update frontmatter `status: closed` + add `closed: {date}`. Skip graph update. If frontmatter has `github_url`, still run `gh issue close "{github_url}" 2>/dev/null` — GitHub CLI is independent of the graph.
- **Search mode**: Grep through `memory/knowledge/issues/` files for matching text. Render same TUI.
- **Notifications**: Skip entirely — do not mention notifications.

**Connected mode**: Full behavior including graph nodes and notifications as specified below.

## Execution rules

**Neo4j-first.** All queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl to Neo4j.
**Notifications via `bash bin/notify.sh`**. No direct curl to Telegram.

## Argument routing

Parse `$ARGUMENTS` to determine mode:

- **Empty** or `list` → List mode (show open issues)
- `list open` → List mode (open only)
- `list closed` → List mode (closed only)
- `list all` → List mode (all statuses)
- `close [id-or-title]` → Close mode
- `search [term]` → Search mode
- **Anything else** → Create mode (existing Steps 0–7 below)

---

## List mode

### Query

```cypher
MATCH (i:Issue)
OPTIONAL MATCH (i)-[:REPORTED_BY]->(p:Person)
RETURN i.id AS id, i.title AS title, i.status AS status,
       i.recipient AS recipient, i.created AS created,
       i.topics AS topics, p.name AS reportedBy,
       i.github_url AS githubUrl
ORDER BY i.created DESC
```

If `list open` or `list closed` was specified, add `WHERE i.status = 'open'` or `WHERE i.status = 'closed'` to the query.

### Display

TUI box — same boundary rules as all commands (72 chars, no sub-boxes).

```
┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUES                                            alice · Feb 10    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  OPEN                                                                │
│    memory-symlink-breaks-after-pull                                  │
│    Memory symlink breaks after pull (bob, Feb 09)                    │
│                                                                      │
│    save-fails-silently                                               │
│    /save fails silently when graph offline (alice, Feb 08) · #42        │
│                                                                      │
│  CLOSED                                                              │
│    im-hungry                                                         │
│    Im hungry (bob, Feb 09)                                           │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  /issue [description] to create · /issue close [id] to resolve       │
└──────────────────────────────────────────────────────────────────────┘
```

**Format per issue**: Two lines per issue:
- Line 1: `{id}` (dimmed/secondary — the slug identifier)
- Line 2: `{title} ({reportedBy}, {date})` + `· #{number}` if github_url exists

Group by status: OPEN first, then CLOSED. Separate groups with a blank line.

If no issues exist: show `No issues found.` in the box body.

If only listing one status (e.g., `list open`), omit the status headers and show a flat list.

---

## Close mode

### Step 1: Resolve target

If `$ARGUMENTS` contains an ID or title after `close`:
```cypher
MATCH (i:Issue {status: 'open'})
WHERE i.id CONTAINS toLower($term) OR toLower(i.title) CONTAINS toLower($term)
OPTIONAL MATCH (i)-[:REPORTED_BY]->(p:Person)
RETURN i.id AS id, i.title AS title, p.name AS reportedBy
```

- **1 match** → proceed to close
- **Multiple matches** → present AskUserQuestion picker with matched issues
- **0 matches** → "No open issue matching '{term}'."

If no term provided after `close`, list all open issues as AskUserQuestion picker.

### Step 2: Close the issue

```cypher
MATCH (i:Issue {id: $id})
SET i.status = 'closed', i.closedAt = datetime()
RETURN i.id, i.title, i.status, i.github_url
```

### Step 3: Close GitHub issue (if linked)

If `github_url` is set:
```bash
gh issue close "{github_url}" 2>/dev/null
```

Show warning if this fails — don't block the close.

### Step 4: Update memory file

If `memory/knowledge/issues/{id}.md` exists, update the frontmatter `status: closed` field.

### Step 5: Confirmation

```
✓ Closed: {title}
```

If GitHub issue was also closed: `✓ Closed: {title} · GitHub #{number} closed`

No auto-save for close operations (lightweight).

---

## Search mode

### Query

```cypher
MATCH (i:Issue)
WHERE toLower(i.title) CONTAINS toLower($term)
   OR toLower(i.id) CONTAINS toLower($term)
   OR ANY(t IN i.topics WHERE toLower(t) CONTAINS toLower($term))
OPTIONAL MATCH (i)-[:REPORTED_BY]->(p:Person)
RETURN i.id AS id, i.title AS title, i.status AS status,
       p.name AS reportedBy, i.created AS created,
       i.github_url AS githubUrl
ORDER BY i.created DESC LIMIT 10
```

### Display

Same TUI format as list mode, but no grouping by status — results are relevance-ordered. Show status inline: `{title} ({reportedBy}, {date}) [open]` or `[closed]`.

If no results: `No issues matching '{term}'.`

---

## Create mode (existing flow)

## Step 0: Context Capture (silent, parallel)

Fire all three in parallel before prompting. The user should never describe their environment.

**Bash call 1 — identity + git state:**
```bash
git config user.name && echo "---" && \
git branch --show-current && echo "---" && \
git status --short && echo "---" && \
git log --oneline -5
```

Map git username → short name: "Alice Smith" → alice, "Bob Jones" → bob, "Bob J" → bob, "Carol" → carol

**Bash call 2 — environment health:**
```bash
[ -L memory ] && echo "memory:linked" || echo "memory:MISSING"
bash bin/graph.sh test 2>&1
jq -r '.org_name,.github_org,.slug,.repos[]' egregore.json 2>/dev/null
```

**Neo4j — recent session context:**
```cypher
MATCH (s:Session)-[:BY]->(p:Person {name: $me})
WHERE date(left(toString(s.date), 10)) >= date() - duration('P3D')
RETURN s.topic, s.date ORDER BY s.date DESC LIMIT 5
```

## Step 1: Description

- If `$ARGUMENTS` is non-empty and doesn't start with `egregore:` → use as description
- If `$ARGUMENTS` starts with `egregore:` → strip prefix, use rest as description, pre-set recipient to `egregore`
- If empty → prompt: *"What's the issue?"* (plain text, wait for user response)

## Step 2: Smart Routing

Infer the most likely destination from the description content, then confirm. Only ask an open "Who's this for?" when the destination is genuinely ambiguous.

Read org config values (needed for matching):
```bash
jq -r '.org_name,.github_org,.repos[]' egregore.json
```

**If the user used the `egregore:` prefix in Step 1**, skip this step entirely — recipient is already `egregore`.

### Routing inference

Analyze the description for signals:

| Signal | Inferred destination |
|---|---|
| Mentions a slash command (`/save`, `/reflect`, `/activity`, etc.) | `{github_org}/egregore-core` |
| Mentions `bin/`, `egregore.json`, `.claude/commands/`, onboarding, graph.sh | `{github_org}/egregore-core` |
| Mentions a managed repo name from `.repos[]` (e.g., "frontend", "backend") | `{github_org}/{repo}` |
| Mentions "memory", "handoff", "knowledge graph", "Neo4j", "sync" | `{github_org}/egregore-core` |
| General/vague, no code or system references | Just memory |
| `egregore:` prefix (already handled above) | `egregore` upstream |

### Confidence-based flow

**High confidence** (description clearly matches one destination):

Present a single confirmation via AskUserQuestion:
```
question: "This looks like an egregore-core issue. File it on {github_org}/egregore-core?"
header: "Route"
multiSelect: false
options:
  - label: "Yes, file on {github_org}/egregore-core"
    description: "Creates a GitHub issue on the org's fork"
  - label: "Just memory"
    description: "Track locally only — visible on /activity"
```

The first option is always the inferred destination. "Just memory" is always the second option (lightweight fallback). If the user picks "Other", trigger a second-round AskUserQuestion with the full destination list (all repos + egregore upstream).

**Low confidence** (ambiguous — no clear signals, or signals point to multiple destinations):

Fall back to the full destination picker:
```
question: "Where should this be filed?"
header: "Route"
multiSelect: false
options:
  - label: "Just memory"
    description: "Tracked in the knowledge graph, visible on /activity"
  - label: "egregore"
    description: "Sent to Egregore maintainers (sanitized)"
  - label: "{github_org}/egregore-core"
    description: "Filed on the org's fork"
  - (for each repo in .repos[]):
    label: "{github_org}/{repo}"
    description: "Filed on {repo}"
```

## Step 3: Write to Memory

Every issue, regardless of recipient, gets a markdown file and a graph node.

### Generate metadata

- **Title**: derive from description — short, descriptive (max 60 chars)
- **Slug**: from title — lowercase, hyphens, no special chars, max 50 chars
- **Topics**: auto-detect 2-4 topic tags from the description content
- **Date**: today `YYYY-MM-DD`

### Write file

Path: `memory/knowledge/issues/YYYY-MM-DD-{slug}.md`

Write using Bash (memory is outside project):
```bash
cat > "memory/knowledge/issues/YYYY-MM-DD-{slug}.md" << 'ISSUEEOF'
---
title: {title}
date: YYYY-MM-DD
author: {short name}
category: issue
status: open
recipient: {selected recipient}
topics: [{topic1}, {topic2}]
github_url:
---

## Description

{user's description}

## Context

- **Branch**: {branch from Step 0}
- **Recent commits**: {last 5 oneline from Step 0}
- **Uncommitted changes**: {git status short from Step 0}
- **Memory**: {linked/missing from Step 0}
- **Graph**: {connected/offline from Step 0; local mode: omit this line}
- **Recent sessions**: {topic list from Neo4j Step 0; local mode: omit this line}
ISSUEEOF
```

### Neo4j node

```cypher
MATCH (p:Person {name: $author})
CREATE (i:Issue {
  id: $id,
  title: $title,
  status: 'open',
  recipient: $recipient,
  created: datetime(),
  topics: $topics
})
CREATE (i)-[:REPORTED_BY]->(p)
RETURN i.id
```

Where:
- `$id` = `YYYY-MM-DD-{slug}` (matches filename without extension)
- `$author` = short name (alice, bob, carol)
- `$title` = derived title
- `$recipient` = selected recipient string
- `$topics` = array of topic strings

Show progress:
```
  [1/N] ✓ Issue saved to memory + graph
        → memory/knowledge/issues/YYYY-MM-DD-{slug}.md
```

## Step 4: Route by Recipient

Simple conditional on the selected recipient value.

### "Just memory" → Done

No external action. Issue lives in the graph and memory. Skip to Step 5.

### "egregore" → Sanitize + Send Upstream

**Sanitize** — replace before sending:

| Pattern | Replacement |
|---|---|
| Org name (from `egregore.json .org_name`) | `[org]` |
| GitHub org (from `egregore.json .github_org`) | `[github-org]` |
| Managed repo names (from `egregore.json .repos[]`) | `[repo]` |
| `ek_*`, `ghp_*`, `gho_*` token patterns | `[redacted]` |
| Person names (filenames from `memory/people/*.md`, excluding index.md) | `[person-N]` |
| `memory/people/*.md` paths | `memory/people/[redacted].md` |

**Show sanitized body to user.** They review and confirm or cancel.

If confirmed, construct a report payload and submit via `bin/session-report.sh`:
```bash
echo '{"report_type":"issue","topic":"$TITLE","summary":"$SANITIZED_DESCRIPTION","description":"$USER_DESCRIPTION","system_info":{"mode":"...","platform":"...","shell":"..."}}' \
  | bash bin/session-report.sh submit 2>/dev/null
```

**Gate**: Check if `report_url` is configured in `egregore.json`. If not, show the sanitized body in a code block for manual sharing:
```
Report URL not configured. Here's the sanitized body you can share manually:
```

**GitHub issue (ask each time)**:

If `gh auth status` succeeds, AskUserQuestion:
```
header: "GitHub"
question: "Also create a GitHub issue on egregore-labs/egregore?"
options:
  - label: "Yes, create issue"
    description: "Public issue with sanitized content"
  - label: "No"
    description: "Report submitted to Supabase only"
```

If yes:
```bash
gh issue create --repo egregore-labs/egregore \
  --title "$TITLE" \
  --body "$SANITIZED_BODY"
```

Capture the returned URL. Update local Neo4j node:
```cypher
MATCH (i:Issue {id: $id})
SET i.github_url = $url, i.upstreamRef = $url
RETURN i.id
```

### Any GitHub repo → `gh issue create`

Compose the issue body from the memory file content (description + context).

```bash
gh issue create \
  --repo {selected-repo} \
  --title "{title}" \
  --body "$(cat memory/knowledge/issues/YYYY-MM-DD-{slug}.md)"
```

Capture the returned URL. Update memory file frontmatter `github_url:` field and Neo4j node:

```cypher
MATCH (i:Issue {id: $id})
SET i.github_url = $url
RETURN i.id
```

Show progress:
```
  [2/N] ✓ Filed on {repo} · #{issue_number}
```

### "Other" → Ask for repo, then same as GitHub repo above

Prompt: *"Which repo? (owner/name)"* — then use `gh issue create` with that repo.

## Step 5: Notify (org issues only)

**Only for org-level issues** (GitHub repos or "Just memory"). Skip for `egregore` upstream.

```bash
bash bin/notify.sh group "Issue reported by {author}: {title}"
```

If notification fails, show warning but don't fail:
```
Notification failed — team can see this on /activity
```

Show progress:
```
  [3/N] ✓ Team notified
```

## Step 6: Auto-save

Run the full `/save` flow:

1. Commit changes in memory repo and push directly to main (pull-rebase-push with retry)
2. Commit any egregore changes and push working branch + PR to develop

Show progress:
```
  [N/N] ✓ Auto-saved
```

## Step 7: Confirmation TUI

~72 char width. Sigil: `✱ ISSUE CAPTURED` or `✱ ISSUE REPORTED` (if filed externally).

### Boundary handling (CRITICAL)

**No sub-boxes. No inner `┌─┐`/`└─┘` borders.** Sub-boxes break because the model can't count character widths precisely enough.

Only **4 line patterns** exist:

1. **Top**: `┌` + 70×`─` + `┐` (72 chars)
2. **Separator**: `├` + 70×`─` + `┤` (72 chars)
3. **Content**: `│` + 2 spaces + text + pad spaces to 68 chars + `│` (72 chars)
4. **Bottom**: `└` + 70×`─` + `┘` (72 chars)

The separator lines are ALWAYS identical — copy-paste the same 72-char string. Content lines have ONLY the outer frame `│` as borders. Pad every content line with trailing spaces so the closing `│` is at position 72.

### "Just memory" variant:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE CAPTURED                              {author} · {Mon DD}  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: {title}                                                      │
│  For: just memory                                                    │
│                                                                      │
│  ✓ Saved to memory · graphed · team notified                         │
│  → memory/knowledge/issues/YYYY-MM-DD-{slug}.md                     │
└──────────────────────────────────────────────────────────────────────┘
```

### GitHub repo variant:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE REPORTED                              {author} · {Mon DD}  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: {title}                                                      │
│  For: {org}/{repo} · issue #{number}                                 │
│                                                                      │
│  ✓ Saved to memory · graphed · team notified                         │
│  → memory/knowledge/issues/YYYY-MM-DD-{slug}.md                     │
└──────────────────────────────────────────────────────────────────────┘
```

### Egregore upstream variant:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE REPORTED                              {author} · {Mon DD}  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: {title}                                                      │
│  For: egregore maintainers                                           │
│                                                                      │
│  ✓ Sent upstream (sanitized) · saved to memory · graphed             │
│  ✓ GitHub #N (if created)                                            │
└──────────────────────────────────────────────────────────────────────┘
```

### TUI rules

- Header row: sigil left, `author · Mon DD` right — both inside the 72-char frame
- `├───┤` separator between header and content
- Title always shown (truncate at 45 chars with `...` if needed)
- "For:" line shows recipient
- Status line: `✓ Saved to memory · graphed · team notified` (adjust per variant)
- File path with `→` (omit for egregore upstream)
- **No sub-boxes** — only outer frame `│` borders and `├────┤` separators

## Edge cases

| Scenario | Handling |
|----------|----------|
| Neo4j unavailable | Still create issue file. Show warning: "Graph offline — file saved, will sync on next /save". Skip Neo4j node creation. |
| Memory symlink missing | Error: "Run /setup first — memory not linked" |
| `gh` not authenticated | Show warning: "GitHub CLI not authenticated. Issue saved to memory only. Run `gh auth login` to enable filing." |
| GitHub repo not accessible | Show error from `gh`, save to memory only |
| Notification fails | Show warning but don't fail the issue |
| File already exists at path | Append timestamp to slug to avoid collision |
| Empty description | Ask: "What's the issue?" — don't proceed without content |
| `bin/issue.sh` missing for egregore route | Show "(coming soon)" message with sanitized body for manual sharing |

## Full example: smart routing (high confidence → egregore-core)

```
> /issue /save Neo4j sync drops CONTRIBUTED_BY links

  [1/4] ✓ Issue saved to memory + graph
        → memory/knowledge/issues/2026-02-10-save-sync-drops-contributed-by.md

This looks like an egregore-core issue. File it on acme-org/egregore-core?
  1. Yes, file on acme-org/egregore-core
  2. Just memory — track locally only

> 1

  [2/4] ✓ Filed on acme-org/egregore-core · #27
  [3/4] ✓ Team notified
  [4/4] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE REPORTED                                bob · Feb 10       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: /save sync drops CONTRIBUTED_BY links                        │
│  For: acme-org/egregore-core · issue #27                           │
│                                                                      │
│  ✓ Saved to memory · graphed · team notified                         │
│  → memory/knowledge/issues/2026-02-10-save-sync-drops-...            │
└──────────────────────────────────────────────────────────────────────┘
```

## Full example: smart routing → user overrides to memory

```
> /issue the memory symlink breaks after pull

  [1/3] ✓ Issue saved to memory + graph
        → memory/knowledge/issues/2026-02-09-memory-symlink-breaks-after-pull.md

This looks like an egregore-core issue. File it on acme-org/egregore-core?
  1. Yes, file on acme-org/egregore-core
  2. Just memory — track locally only

> 2

  [2/3] ✓ Team notified
  [3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE CAPTURED                                bob · Feb 09       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: Memory symlink breaks after pull                             │
│  For: just memory                                                    │
│                                                                      │
│  ✓ Saved to memory · graphed · team notified                         │
│  → memory/knowledge/issues/2026-02-09-memory-symlink.md              │
└──────────────────────────────────────────────────────────────────────┘
```

## Full example: egregore shorthand

```
> /issue egregore: /save fails silently when graph is offline

  [1/4] ✓ Issue saved to memory + graph
        → memory/knowledge/issues/2026-02-09-save-fails-silently.md

Here's the sanitized version that will be sent:

    Title: /save fails silently when graph is offline
    Description: /save fails silently when [github-org] graph is offline.
    No error message shown to user.
    Branch: dev/[person-1]/2026-02-09-session
    Graph: connected

Send this to Egregore maintainers?
  1. Yes, send it
  2. Cancel

> 1

  [2/4] ✓ Sent upstream (sanitized)

Also create a GitHub issue on egregore-labs/egregore?
  1. Yes, create issue
  2. No

> 2

  [3/4] ✓ Team notified
  [4/4] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE REPORTED                                bob · Feb 09       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: /save fails silently when graph is offline                   │
│  For: egregore maintainers                                           │
│                                                                      │
│  ✓ Sent upstream (sanitized) · saved to memory · graphed             │
│  → memory/knowledge/issues/2026-02-09-save-fails-silently.md         │
└──────────────────────────────────────────────────────────────────────┘
```

## Full example: ambiguous (low confidence → full picker)

```
> /issue our team alignment on pricing feels off

  [1/3] ✓ Issue saved to memory + graph
        → memory/knowledge/issues/2026-02-10-team-pricing-alignment.md

Where should this be filed?
  1. Just memory — tracked in knowledge graph, visible on /activity
  2. egregore — (coming soon — Phase B)
  3. acme-org/egregore-core — filed on the org's fork
  4. acme-org/frontend — filed on frontend

> 1

  [2/3] ✓ Team notified
  [3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE CAPTURED                                bob · Feb 10       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: Team pricing alignment feels off                             │
│  For: just memory                                                    │
│                                                                      │
│  ✓ Saved to memory · graphed · team notified                         │
│  → memory/knowledge/issues/2026-02-10-team-pricing-alignment.md      │
└──────────────────────────────────────────────────────────────────────┘
```

## Full example: interactive (no args)

```
> /issue

What's the issue?

> The graph query for sessions returns duplicates when a session
> has multiple HANDED_TO relationships

  [1/4] ✓ Issue saved to memory + graph
        → memory/knowledge/issues/2026-02-09-session-query-duplicates.md

This looks like an egregore-core issue. File it on acme-org/egregore-core?
  1. Yes, file on acme-org/egregore-core
  2. Just memory — track locally only

> 1

  [2/4] ✓ Filed on acme-org/egregore-core · #43
  [3/4] ✓ Team notified
  [4/4] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE REPORTED                                bob · Feb 09       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: Session query returns duplicates with multiple...            │
│  For: acme-org/egregore-core · issue #43                           │
│                                                                      │
│  ✓ Saved to memory · graphed · team notified                         │
│  → memory/knowledge/issues/2026-02-09-session-query-duplicates.md    │
└──────────────────────────────────────────────────────────────────────┘
```
