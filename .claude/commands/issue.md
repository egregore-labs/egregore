Report an issue. Captures context automatically, routes to memory/graph/GitHub.

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## Execution rules

**Neo4j-first.** All queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl to Neo4j.
**Notifications via `bash bin/notify.sh`**. No direct curl to Telegram.

## Step 0: Context Capture (silent, parallel)

Fire all three in parallel before prompting. The user should never describe their environment.

**Bash call 1 — identity + git state:**
```bash
git config user.name && echo "---" && \
git branch --show-current && echo "---" && \
git status --short && echo "---" && \
git log --oneline -5
```

Map git username → short name: "Oguzhan Yayla" → oz, "Cem Dagdelen" → cem, "Cem F" → cem, "Ali" → ali

**Bash call 2 — environment health:**
```bash
[ -L memory ] && echo "memory:linked" || echo "memory:MISSING"
bash bin/graph.sh test 2>&1
jq -r '.org_name,.github_org,.slug,.repos[]' egregore.json 2>/dev/null
```

**Neo4j — recent session context:**
```cypher
MATCH (s:Session)-[:BY]->(p:Person {name: $me})
WHERE s.date >= date() - duration('P3D')
RETURN s.topic, s.date ORDER BY s.date DESC LIMIT 5
```

## Step 1: Description

- If `$ARGUMENTS` is non-empty and doesn't start with `egregore:` → use as description
- If `$ARGUMENTS` starts with `egregore:` → strip prefix, use rest as description, pre-set recipient to `egregore`
- If empty → prompt: *"What's the issue?"* (plain text, wait for user response)

## Step 2: Recipient

One AskUserQuestion. Build options dynamically from `egregore.json`.

Read org config values:
```bash
jq -r '.org_name,.github_org,.repos[]' egregore.json
```

Present:
```
question: "Who's this for?"
header: "Route"
multiSelect: false
options:
  - label: "Just memory"
    description: "Tracked in the knowledge graph, visible on /activity"
  - label: "egregore"
    description: "(coming soon — Phase B)" OR "Sent to Egregore maintainers (sanitized)" if bin/issue.sh exists
  - label: "{github_org}/egregore-core"
    description: "Filed on the org's fork"
  - (for each repo in .repos[]):
    label: "{github_org}/{repo}"
    description: "Filed on {repo}"
```

**If the user used the `egregore:` prefix in Step 1**, skip this step — recipient is already `egregore`.

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
- **Graph**: {connected/offline from Step 0}
- **Recent sessions**: {topic list from Neo4j Step 0}
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
- `$author` = short name (oz, cem, ali)
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

**Phase B gate**: Check if `bin/issue.sh` exists.

If `bin/issue.sh` does NOT exist:
```
Egregore upstream reporting is coming in Phase B.

For now, your issue is saved locally. If urgent, you can share it
manually — here's the sanitized body:
```
Then show the sanitized description (with replacements below applied) in a code block the user can copy. Skip to Step 5.

If `bin/issue.sh` exists:

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

If confirmed:
```bash
echo '$PAYLOAD_JSON' | bash bin/issue.sh report
```

Update local Neo4j node with `upstreamRef`:
```cypher
MATCH (i:Issue {id: $id})
SET i.upstreamRef = $ref
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

1. Commit changes in memory repo and push (contribution branch + PR + auto-merge)
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
│  For: egregore maintainers · triage #{ref}                           │
│                                                                      │
│  ✓ Sent upstream (sanitized) · saved to memory · graphed             │
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

## Full example: memory only

```
> /issue the memory symlink breaks after pull

  [1/3] ✓ Issue saved to memory + graph
        → memory/knowledge/issues/2026-02-09-memory-symlink-breaks-after-pull.md

Who's this for?
  1. Just memory — tracked in knowledge graph, visible on /activity
  2. egregore — (coming soon — Phase B)
  3. Curve-Labs/egregore-core — filed on the org's fork
  4. Curve-Labs/lace — filed on lace

> 1

  [2/3] ✓ Team notified
  [3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE CAPTURED                                cem · Feb 09       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: Memory symlink breaks after pull                             │
│  For: just memory                                                    │
│                                                                      │
│  ✓ Saved to memory · graphed · team notified                         │
│  → memory/knowledge/issues/2026-02-09-memory-symlink.md              │
└──────────────────────────────────────────────────────────────────────┘
```

## Full example: GitHub repo

```
> /issue the memory symlink breaks after pull

  [1/4] ✓ Issue saved to memory + graph
        → memory/knowledge/issues/2026-02-09-memory-symlink-breaks-after-pull.md

Who's this for?
  ...

> Curve-Labs/egregore-core

  [2/4] ✓ Filed on Curve-Labs/egregore-core · #42
  [3/4] ✓ Team notified
  [4/4] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE REPORTED                                cem · Feb 09       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: Memory symlink breaks after pull                             │
│  For: Curve-Labs/egregore-core · issue #42                           │
│                                                                      │
│  ✓ Saved to memory · graphed · team notified                         │
│  → memory/knowledge/issues/2026-02-09-memory-symlink.md              │
└──────────────────────────────────────────────────────────────────────┘
```

## Full example: egregore shorthand

```
> /issue egregore: /save fails silently when graph is offline

  [1/2] ✓ Issue saved to memory + graph
        → memory/knowledge/issues/2026-02-09-save-fails-silently.md

Egregore upstream reporting is coming in Phase B.

For now, your issue is saved locally. If urgent, you can share it
manually — here's the sanitized body:

    Title: /save fails silently when graph is offline
    Description: /save fails silently when [github-org] graph is offline.
    No error message shown to user.
    Branch: dev/[person-1]/2026-02-09-session
    Graph: connected

  [2/2] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE CAPTURED                                cem · Feb 09       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: /save fails silently when graph is offline                   │
│  For: egregore (local — upstream coming soon)                        │
│                                                                      │
│  ✓ Saved to memory · graphed                                         │
│  → memory/knowledge/issues/2026-02-09-save-fails-silently.md         │
└──────────────────────────────────────────────────────────────────────┘
```

## Full example: interactive (no args)

```
> /issue

What's the issue?

> The graph query for sessions returns duplicates when a session
> has multiple HANDED_TO relationships

  [1/3] ✓ Issue saved to memory + graph
        → memory/knowledge/issues/2026-02-09-session-query-duplicates.md

Who's this for?
  ...

> Just memory

  [2/3] ✓ Team notified
  [3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ✱ ISSUE CAPTURED                                cem · Feb 09       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Title: Session query returns duplicates with multiple...            │
│  For: just memory                                                    │
│                                                                      │
│  ✓ Saved to memory · graphed · team notified                         │
│  → memory/knowledge/issues/2026-02-09-session-query-duplicates.md    │
└──────────────────────────────────────────────────────────────────────┘
```
