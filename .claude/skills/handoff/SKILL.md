End a session with a summary for the next person (or future you). With no arguments, triages open handoffs first.

## When to invoke

User says: "I'm done", "wrapping up", "leave a handoff", "pass this to [name]", "hand off", "done for now", "signing off"
Not this: user wants to push but keep working → `/save`

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## Mode detection

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

**Local mode** (`mode === "local"`): Skip ALL `bin/graph.sh`, `bin/graph-op.sh`, and `bin/index-handoff.sh` calls — do NOT run them. Do NOT show any graph-related messaging ("Graph offline", "will sync", Neo4j, etc.). `bin/notify.sh` IS allowed — it routes through the public relay for group messages.

Local-mode flow:
- **Step 0**: Get user via `git config user.name`. For team members: read from `memory/people/` directory (list `.md` files, extract names from filenames or frontmatter) instead of querying the graph.
- **Step 0.5 (Triage)**: Read open handoffs from `memory/handoffs/index.md` — filter for handoffs directed at the current user. Display the same triage UI, but skip all `bin/graph.sh` mark-read/mark-done calls. Triage responses are informational only in local mode — the user tracks status manually.
- **Steps 1-4**: Same as connected mode (parsing, briefing, file creation, index update).
- **Step 5**: Skip entirely — no `bin/index-handoff.sh`, no artifact query. Show progress as `[3/N] ✓ Skipped graph (local mode)` — actually, just renumber steps to exclude graph step.
- **Step 6**: Auto-save — same as connected mode.
- **Step 7**: If recipient specified and `telegram_chat_id` is set in `egregore.json`, send group notification via `bin/notify.sh send`. No DMs in local mode — notify.sh routes to group automatically. Skip if no Telegram configured.
- **Step 8**: TUI — use `✓ Saved · pushed` (not "graphed"). Show `· {Recipient} notified` if notification was sent.
- **Step 9**: Skip entirely — no reflection prompt query.

Progress steps in local mode (no recipient): `[1/3] ✓ Conversation file` → `[2/3] ✓ Index updated` → `[3/3] ✓ Pushed + PR created`
Progress steps in local mode (with recipient + Telegram configured): `[1/4] ✓ Conversation file` → `[2/4] ✓ Index updated` → `[3/4] ✓ Pushed + PR created` → `[4/4] ✓ {Recipient} notified`
Progress steps in local mode (with recipient, no Telegram): same as no-recipient — skip notification silently.

**Connected mode**: Full behavior as specified below.

## Execution rules

**Neo4j-first.** All queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl to Neo4j.
**Notifications via `bash bin/notify.sh send`**. No direct curl to Telegram.

**CRITICAL: Suppress raw output.** Never show raw JSON to the user. All `bin/graph.sh` and `bin/notify.sh` calls MUST redirect stdout: pipe to `/dev/null` or capture in a variable. Only show formatted progress lines. Example:
```bash
bash bin/graph.sh query "..." > /dev/null 2>&1
```
If you need to parse the result, capture it and only echo a status:
```bash
RESULT=$(bash bin/graph.sh query "..." 2>/dev/null) && echo "OK" || echo "FAILED"
```

- 1 Bash call: `git config user.name`
- 1 Neo4j query: Session creation (with HANDED_TO if recipient)
- 1 Neo4j query: Artifact lookup (today's artifacts by author)
- Auto-save via `/save` flow
- 1 notification via `bin/notify.sh send` (if recipient specified)
- Progress shown incrementally, step by step

## Step 0: Get current user and team members

```bash
git config user.name
```

Derive author handle: lowercase first word of git user.name (e.g. "Alice Smith" → "alice").

**Connected mode:** Query all team members from the graph (suppress raw output, parse names):
```bash
MEMBERS=$(bash bin/graph.sh query "MATCH (p:Person) RETURN p.name AS name, p.github AS github, p.fullName AS fullName" 2>/dev/null)
echo "$MEMBERS" | jq -r '.values[][] // empty' 2>/dev/null
```

**Local mode:** Read team members from `memory/people/` directory:
```bash
for f in memory/people/*.md; do
  [ -f "$f" ] || continue
  github=$(basename "$f" .md)
  display=$(head -1 "$f" | sed 's/^# //')
  echo "$github|$display"
done
```
This gives `github_username|Display Name` pairs. The file format is:
```
# Display Name
GitHub: username
Role: ...
```

Use this list for recipient matching in Step 1.
Match recipient names case-insensitively against display name (from `# ` header), github username (filename), or any partial match. The display name takes priority — if a user chose "oz" during onboarding, `/handoff oz` should resolve to their file even if the filename is their GitHub username.

## Step 0.5: Triage mode (no arguments + open handoffs)

**Trigger:** `$ARGUMENTS` is empty (user ran bare `/handoff`).

Before creating a new handoff, check for open handoffs directed at the current user.

**Connected mode:** Query the graph:
```cypher
MATCH (s:Session)-[:HANDED_TO]->(p:Person {name: $me})
WHERE coalesce(s.handoffStatus, 'pending') IN ['pending', 'read']
  AND date(left(toString(s.date), 10)) >= date() - duration('P14D')
MATCH (s)-[:BY]->(author:Person)
RETURN s.topic AS topic, s.date AS date, author.name AS author,
       s.filePath AS filePath, s.id AS sessionId,
       coalesce(s.handoffStatus, 'pending') AS status
ORDER BY
  CASE coalesce(s.handoffStatus, 'pending')
    WHEN 'pending' THEN 0 ELSE 1
  END,
  s.date DESC
LIMIT 8
```

**Local mode:** Read `memory/handoffs/index.md` and scan recent entries (last 14 days) for handoffs with `to: {current user}`. Read the handoff files to extract topic, date, author. All handoffs are treated as `pending` (no status tracking in local mode). Skip triage entirely if no recent handoffs mention the current user — fall through to Step 1.

**If no open handoffs** → skip triage, fall through to Step 1 (normal handoff flow with no-topic handling).

**If open handoffs exist** → enter triage mode. Route by count:

### Route A: Guided walk-through (1-3 handoffs)

Walk through each handoff one at a time, showing context and capturing the user's response.

For each handoff, in order:

**1. Show the handoff content.** Read the file at `filePath` from the query (prepend `memory/` to the path). Display the receiver TUI:

```
  ─── 1 of N ───

  ┌──────────────────────────────────────────────────────────────────────┐
  │  ⇌ HANDOFF FROM {AUTHOR uppercase}                      {when}     │
  ├──────────────────────────────────────────────────────────────────────┤
  │                                                                      │
  │  Topic: {topic}                                                      │
  │                                                                      │
  │  {summary from file, wrapped at ~60 chars}                           │
  │                                                                      │
  └──────────────────────────────────────────────────────────────────────┘
```

**2. Ask for status via AskUserQuestion:**

```
header: "Handoff"
question: "What's the status of {author}'s handoff on {topic}?"
multiSelect: false
options:
  - label: "Done"
    description: "I've addressed this"
  - label: "Still open"
    description: "Keep it visible — I'm still working on it"
  - label: "Not relevant"
    description: "Dismiss without action"
```

**3. Handle response:**

- **"Done" or "Not relevant"** → **Connected mode:** mark `done`: `bash bin/graph.sh query "MATCH (s:Session {id: '$sessionId'}) SET s.handoffStatus = 'done' RETURN s.id"`. **Local mode:** skip the graph call. Output: `✓ Resolved: {topic} from {author}`
- **"Still open"** → **Connected mode:** if currently `pending`, mark `read`: `bash bin/graph.sh query "MATCH (s:Session {id: '$sessionId'}) WHERE s.handoffStatus = 'pending' OR s.handoffStatus IS NULL SET s.handoffStatus = 'read', s.handoffReadDate = date() RETURN s.id"`. **Local mode:** skip the graph call. Output: `◐ Kept open: {topic} from {author}`. **Then auto-checkout repos**: if the handoff file has a `## Repo State` section, parse the table and for each repo fetch + checkout the branch:
  ```bash
  PARENT_DIR="$(cd .. && pwd)"
  # For each row in ## Repo State table:
  REPO_DIR="$PARENT_DIR/$REPO_NAME"
  git -C "$REPO_DIR" fetch origin "$BRANCH" --quiet 2>/dev/null
  git -C "$REPO_DIR" checkout "$BRANCH" 2>/dev/null || \
    git -C "$REPO_DIR" checkout -b "$BRANCH" "origin/$BRANCH" 2>/dev/null
  ```
  Report: `✓ Checked out {branch} in {repo1}, {repo2}`. If a branch no longer exists (PR merged): `◐ {repo}: PR #{N} merged — on {base}`. This works in both local and connected modes (pure git).
- **Freeform text (user typed something)** → **Connected mode:** mark `done` AND capture: `bash bin/graph.sh query "MATCH (s:Session {id: '$sessionId'}) SET s.handoffStatus = 'done', s.handoffResponse = '$response' RETURN s.id"`. **Local mode:** skip the graph call. Output: `✓ Resolved: {topic} from {author}` + `  Captured: "{first 60 chars}..."`

**4. Continue to next handoff**, or if all done:

```
All caught up.

Handing off this session? (topic, or enter to skip)
```

If user provides a topic → fall through to Step 1 with that topic. If empty/enter → exit without creating a new handoff.

### Route B: Batch triage (4+ handoffs)

Show all handoffs as a multiSelect AskUserQuestion for quick resolution.

```
header: "Triage"
question: "Which handoffs have you addressed?"
multiSelect: true
options: (one per handoff, max 4 shown)
  - label: "{author}: {topic}"
    description: "{status_icon} {when}"
```

Where `status_icon` is `●` for pending, `◐` for read.

If more than 4 handoffs, show the top 4 (pending first, then oldest read) and note: `Showing 4 of N — run /handoff again to triage the rest.`

**After selection:**

- Each selected handoff → **Connected mode:** mark `done`: `bash bin/graph.sh query "MATCH (s:Session {id: '$sessionId'}) SET s.handoffStatus = 'done' RETURN s.id"`. **Local mode:** skip the graph call.
- Unselected handoffs that are `pending` → **Connected mode:** mark `read`: `bash bin/graph.sh query "MATCH (s:Session {id: '$sessionId'}) WHERE s.handoffStatus = 'pending' OR s.handoffStatus IS NULL SET s.handoffStatus = 'read', s.handoffReadDate = date() RETURN s.id"`. **Local mode:** skip the graph call.
- Output: `✓ Resolved N handoffs` (and `◐ Kept N open` if any unselected)

Then:

```
Handing off this session? (topic, or enter to skip)
```

Same fall-through as Route A.

### Triage examples

**Guided (2 handoffs):**
```
> /handoff

  You have 2 open handoffs.

  ─── 1 of 2 ───

  ┌──────────────────────────────────────────────────────────────────────┐
  │  ⇌ HANDOFF FROM CAROL                                 yesterday   │
  ├──────────────────────────────────────────────────────────────────────┤
  │                                                                      │
  │  Topic: Slash Command Testing                                        │
  │                                                                      │
  │  Tested /activity, /reflect, /handoff. Found backtick eval           │
  │  bug in activity command. Provided test results with fixes.          │
  │                                                                      │
  └──────────────────────────────────────────────────────────────────────┘

  What's the status of carol's handoff on Slash Command Testing?
    1. Done
    2. Still open
    3. Not relevant

> "Fixed the backtick bug, activity works. Reflect still needs
   the rubric rewrite."

  ✓ Resolved: Slash Command Testing from carol
    Captured: "Fixed the backtick bug, activity works. Reflect
    still needs the rubric rewrite."

  ─── 2 of 2 ───

  ┌──────────────────────────────────────────────────────────────────────┐
  │  ⇌ HANDOFF FROM ALICE                                     2d ago    │
  ├──────────────────────────────────────────────────────────────────────┤
  │  ...                                                                 │
  └──────────────────────────────────────────────────────────────────────┘

  What's the status of alice's handoff on Setup flow?
> 1

  ✓ Resolved: New Egregore setup flow from alice

  All caught up.

  Handing off this session? (topic, or enter to skip)
> implicit handoff resolution to alice

  Creating handoff...
  ...
```

**Batch (5 handoffs):**
```
> /handoff

  You have 5 open handoffs. Which have you addressed?

  ☐ ● carol: Slash Command Testing (yesterday)
  ☐ ◐ alice: New Egregore setup flow (2d ago)
  ☐ ◐ alice: Infra fix after sync (3d ago)
  ☐ ● dave: Animation handoff (4d ago)

  Showing 4 of 5 — run /handoff again to triage the rest.

> [selects carol + alice setup flow]

  ✓ Resolved 2 handoffs
  ◐ Kept 2 open

  Handing off this session? (topic, or enter to skip)
> enter

  Done.
```

---

## Step 1: Parse arguments

**Only reached if `$ARGUMENTS` is non-empty OR user provided a topic after triage.**

Parse `$ARGUMENTS` for topic and recipient.

**Recipient detection** — understand from natural language who the handoff is for:
- "setup flow to oskar" → topic: "setup flow", recipient: oskar
- "mcp auth for alice to pick up" → topic: "mcp auth", recipient: alice
- "handoff blog styling" → topic: "blog styling", recipient: none

Team members: **from the graph query in Step 0** (not hardcoded).

Match recipient names case-insensitively against the Person names from the graph.

If `$ARGUMENTS` has no clear recipient, show a picker using AskUserQuestion:
- List each Person name from the graph (excluding the current user)
- Add a final option: "General (no specific recipient)"

If no recipient detected or user picks "General", the handoff is for the team or future self.

## Step 2: Brief the recipient

### Scope assessment

Before generating the briefing, consider whether this session covered multiple
distinct threads of work that a reader might not all need.

This is a judgment call. Most sessions don't need it. Skip it when:
- The session had one clear focus
- The user provided a specific topic in `/handoff` arguments that already narrows scope
- The conversation was short or exploratory

Ask when you'd genuinely be unsure what to include — when the session
switched between unrelated areas, or when briefing everything would
produce a handoff where the reader can't tell what to act on first.

If asking: use AskUserQuestion. The options must name the actual threads
from the conversation — not generic labels. Derive them from what was
discussed. Always include a "whole session" option. 2-4 options max.

    header: "Scope"
    question: "{your context-sensitive question}"
    options:
      - label: "{thread A — named from conversation}"
        description: "{what this covers}"
      - label: "{thread B — named from conversation}"
        description: "{what this covers}"
      - label: "Whole session"
        description: "Hand off everything we discussed"

This counts toward the 1-2 AskUserQuestion budget for the handoff command.
If the recipient picker in Step 1 already used 1, skip scope assessment.

### Generate briefing

Synthesize the session into a briefing for the recipient (or future reader).
This is not a transcript — actively interpret what happened, connect it to
team context (active quests, recent handoffs, known priorities), and tell the
reader what matters and why.

If a scope was selected above, constrain the briefing to the selected scope.
Material from unselected threads should not appear.

Produce:

1. **Briefing** — 2-4 sentences. What happened, why it matters, how it connects
   to what the team is working on. Situate the work — don't just describe it.
2. **Key decisions** — any decisions made, with rationale and implications
3. **Current state** — what's working, in progress, blocked
4. **Open threads** — unfinished items with enough context to pick up
5. **Next steps** — clear actions with entry points
6. **Project** — which project this relates to (identify from context)

## Step 2.5: Detect touched repos

Scan the core repo and all managed repos from `egregore.json` to capture which repos have work on non-base branches. This works in **both local and connected modes** — pure git, no graph dependency.

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
EGREGORE_ROOT="$(pwd)"
PARENT_DIR="$(cd .. && pwd)"
GITHUB_ORG=$(jq -r '.github_org // empty' egregore.json 2>/dev/null)
CORE_REPO=$(jq -r '.repo_name // "egregore"' egregore.json 2>/dev/null)
MANAGED_REPOS=$(jq -r '(.repos[]? // empty) | if type == "object" then .name else . end' egregore.json 2>/dev/null)
```

For the core repo and each managed repo:

1. **Resolve path**: core repo = `$EGREGORE_ROOT`, managed = `$PARENT_DIR/{name}`
2. **Get branch**: `git -C "$REPO_DIR" branch --show-current`
3. **Get base branch**: read from `egregore.json` (object format has `base_branch`, default `"develop"`)
4. **Skip** if on the base branch AND no uncommitted changes (`git -C "$REPO_DIR" status --porcelain | head -1` is empty)
5. **Count commits ahead**: `git -C "$REPO_DIR" rev-list "origin/${BASE}..HEAD" --count 2>/dev/null || echo "0"`
6. **If touched** (on non-base branch with commits ahead, OR has uncommitted changes) → record `{repo, branch, base}`

Store the results as a `REPO_STATE` list for use in Steps 3, 6.5, 7, and 8.

If no repos are touched (all on base branches with no changes), `REPO_STATE` is empty — omit the `## Repo State` section from the handoff file entirely.

## Step 3: Create handoff file

File path: `memory/handoffs/YYYY-MM/DD-[author]-[topic-slug].md`

Example: `memory/handoffs/2026-02/07-bob-defensibility-architecture.md`

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
**Project**: [project name from context]

## Briefing

[2-4 sentences — what happened, why it matters, how it connects]

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

## Repo State

| Repo | Branch | PR | Base |
|------|--------|----|------|
| [repo-name] | [branch] | — | [base-branch] |
HANDOFFEOF
```

Omit the **To** line if no recipient. Omit **Key Decisions** if none. Omit **Session Artifacts** section if the artifact query (Step 5) returns empty. The Session Artifacts section is populated after the Neo4j query in Step 5 — leave a placeholder during file creation, then update the file after the query.

**Repo State section**: Only include `## Repo State` if `REPO_STATE` from Step 2.5 is non-empty. Write one row per touched repo. The PR column starts as `—` (em dash) — it gets backfilled with actual PR numbers in Step 6.5 after auto-save.

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

## Step 5: Index to Neo4j + query artifacts — CONNECTED MODE ONLY

**Skip this entire step in local mode.** Do not run `bin/index-handoff.sh` or the artifact query. Omit the Session Artifacts section from the handoff file. Do not show any graph-related progress.

### Session indexing

```bash
RESULT=$(bash bin/index-handoff.sh "memory/handoffs/YYYY-MM/DD-author-topic-slug.md" 2>/dev/null)
```

The script handles all graph writes: Session node (MERGE for idempotency), BY/HANDED_TO/ABOUT relationships, and auto-resolve of old `read` handoffs from this author.

Returns: `{"sessionId":"...","resolved":N}` or `{"error":"..."}`.

If it fails: show "Graph offline — file saved, will sync on next /save". Continue to Step 6.

If resolved > 0, include in progress output: `[3/5] ✓ Session -> knowledge graph (resolved N prior handoffs)`

### Artifact query

Query for artifacts created today by the author, excluding tutorial-generated artifacts:

```cypher
MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person {name: $author})
WHERE a.created >= datetime({year: $year, month: $month, day: $day})
  AND NOT 'tutorial-generated' IN coalesce(a.topics, [])
RETURN a.title AS title, a.type AS type, a.filePath AS path, a.topics AS topics
ORDER BY a.created DESC
```

Run this in parallel with the Session creation query.

**Relevance filter:** After fetching, only include artifacts in the TUI whose topics overlap with the session topic. Compare each artifact's `topics` array against keywords extracted from the handoff topic. If no artifacts pass the relevance filter, omit the artifacts section entirely. This prevents unrelated same-day artifacts from leaking into handoffs.

If relevant artifacts are found, update the handoff file's Session Artifacts section with the results. Format each artifact as:
```
- [Type capitalized]: [Title] -> [shortened file path]
```

Show progress:
```
[3/5] ✓ Session -> knowledge graph
```

## Step 6: Auto-save

Run the full `/save` flow:

1. Commit changes in memory repo and push directly to main (pull-rebase-push with retry)
2. Commit any egregore changes and push working branch + PR to develop

This is the same flow as `/save`. Follow its logic exactly.

Show progress:
```
[4/5] ✓ Pushed + PR created
```

## Step 6.5: Backfill PR numbers into Repo State — CONNECTED MODE ONLY

**Skip this step in local mode.** Leave PR column as `—`.

After auto-save completes (which creates branches and PRs), query each touched repo for its open PR number:

```bash
GITHUB_ORG=$(jq -r '.github_org // empty' egregore.json 2>/dev/null)
for each touched repo in REPO_STATE:
  PR_NUM=$(gh pr list --repo "$GITHUB_ORG/$REPO_NAME" --head "$BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")
```

Then update the handoff file's `## Repo State` table: replace the `—` in the PR column with `#N` for each repo that now has a PR.

If a PR was already merged (branch no longer has an open PR), leave `—`. The branch name in the table is the primary coordination mechanism; the PR number is supplementary.

## Step 7: Publish artifact + Notify recipient

### 7a: Publish artifact (synchronous, before notification)

Generate and publish the handoff as a branded HTML artifact **before** sending the notification, so the Telegram message includes the artifact URL with OG link preview.

```bash
ARTIFACT_URL=$(bash bin/publish-artifact.sh handoff "$HANDOFF_FILE_PATH" \
  --title "$HANDOFF_TOPIC" \
  --author "$AUTHOR" \
  --description "$BRIEFING_FIRST_TWO_SENTENCES" 2>/dev/null)
```

This takes ~2-3s (HTML generation + upload). The script outputs the URL on success, or nothing on failure.

- **Connected** (API key present): publishes to `egregore.xyz/view/{org}/{id}` (permanent)
- **OSS** (no API key): publishes to `egregore.xyz/view/_/{id}` (ephemeral, 7-day TTL)
- **If publish fails**: `ARTIFACT_URL` is empty — fall back to the GitHub entry point link in the notification.

### 7b: Notify recipient

**Only if a recipient was specified.**

**Connected mode:** Send via DM (falls back to group automatically):
```bash
bash bin/notify.sh send "$RECIPIENT" "$MESSAGE"
```

**Local mode:** Send to group (DMs not available without API):
```bash
bash bin/notify.sh group "$MESSAGE"
```

If `telegram_chat_id` is not set in `egregore.json`, skip silently — Telegram isn't configured.

**Telegram message format**:

```
Handoff from [Author]: [Topic]

"[2-3 sentence briefing from the session]"

[If repos touched (REPO_STATE non-empty):]
Repos:
  - [repo]: [branch] → PR #[N] to [base]
  - [repo]: [branch] → [base]

[If artifacts found:]
Session included N artifacts:
  - [Type]: [Title]
  - [Type]: [Title]

[If ARTIFACT_URL is set:]
View: [ARTIFACT_URL]
[else:]
Entry point: https://github.com/{org}/{memory-repo}/blob/main/[handoff file path]
```

**The artifact URL is preferred** — it renders a branded page with OG link preview in Telegram. Only fall back to the GitHub entry point link if artifact publishing failed.

Derive the GitHub fallback URL from `egregore.json`: read `memory_repo` (strip `.git` suffix and extract `{org}/{repo}` from the URL), then append `/blob/main/` + the file path relative to the memory root.

Example (with artifact URL):
```
Handoff from Bob: Defensibility architecture

"Analyzed five-layer moat framework. Server-side intelligence is the biggest gap. Full artifact in knowledge/decisions/."

Session included 2 artifacts:
  - Decision: Defensibility architecture framework
  - Finding: Harvest flywheel as training surface

View: https://egregore.xyz/view/curvelabs/a7xK3mP9qw0
```

Show progress:
```
[5/5] ✓ [Recipient] notified
```

**If no recipient**: step 5 becomes "✓ Team sees this on /activity" and no notification is sent (show only 4 progress steps total, renumbered). The artifact is still published (available via `/view` and the listing page).

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

The briefing is the primary content — what was actually handed off. The progress checklist is already shown incrementally during execution; repeating it wastes space. Collapse progress to a single status line.

### With recipient, artifacts, and repos:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF SENT                                     bob · Feb 07     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: Defensibility architecture                                   │
│  To: Alice                                                           │
│                                                                      │
│  Analyzed five-layer moat framework for Egregore. Server-side        │
│  intelligence is the biggest gap and biggest opportunity.             │
│  Defined pricing tiers and go-to-market sequence.                    │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  REPOS                                                               │
│  ◈ egregore: dev/bob/topic → PR #435 to develop               │
│  ◈ egregore-site: dev/bob/topic → PR #12 to main                    │
├──────────────────────────────────────────────────────────────────────┤
│  ◉ Decision: Defensibility architecture framework                    │
│  ◉ Finding: Harvest flywheel as training surface                     │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed · Alice notified                            │
│  Team sees this on /activity.                                        │
└──────────────────────────────────────────────────────────────────────┘
```

### Without recipient, no artifacts, with repos (local mode):

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF SENT                                      alice · Feb 07     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: MCP auth flow                                                │
│                                                                      │
│  Implemented OAuth device flow for MCP authentication.               │
│  Token refresh works end-to-end. Needs error handling                │
│  for expired sessions.                                               │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  REPOS                                                               │
│  ◈ egregore: dev/alice/mcp-auth → develop                            │
│  ◈ egregore-site: dev/alice/mcp-auth → main                         │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · pushed                                                    │
│  Team sees this on /activity.                                        │
└──────────────────────────────────────────────────────────────────────┘
```

### TUI rules

- Header row: `⇌ HANDOFF SENT` left, `author · Mon DD` right — both inside the 72-char frame
- `├───┤` separator between header and content
- Topic always shown
- "To:" line only if recipient specified
- **Briefing** — 2-4 sentences from Step 2, wrapped at ~60 chars. This is the primary content.
- **Repos section** (between `├───┤` dividers): `◈` for each touched repo. Format: `◈ {repo}: {branch} → PR #{N} to {base}` (connected mode) or `◈ {repo}: {branch} → {base}` (local mode, no PR numbers). Omit entirely if `REPO_STATE` is empty.
- Artifacts section (between `├───┤` dividers): `◉` for each artifact. Omit entirely if no artifacts.
- **Status line** — single line collapsing all progress: `✓ Saved · graphed · pushed` (add `· {Recipient} notified` if recipient)
- Footer: "Team sees this on /activity." + if artifacts package exists: "Open in browser? /view handoff {filename}"
- Truncate topic at 45 chars with `...` if needed
- **No sub-boxes** — only outer frame `│` borders and `├────┤` separators

## Receiver View (for /activity integration)

When a recipient reads a handoff directed at them (e.g., from an `/activity` action item), display this format.

Same boundary rules apply — 4 line patterns only, no sub-boxes, 72-char outer width.

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF FROM BOB                                     Feb 07       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: Defensibility architecture                                   │
│                                                                      │
│  Analyzed Egregore defensibility — five-layer moat from              │
│  convenience to network effects. Server-side intelligence            │
│  is the biggest gap and biggest opportunity.                         │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  REPOS                                                               │
│  ◈ egregore: dev/bob/topic → PR #435 to develop               │
│  ◈ egregore-site: dev/bob/topic → PR #12 to main                    │
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
│  → memory/handoffs/2026-02/07-bob-defensibility-...             │
└──────────────────────────────────────────────────────────────────────┘
```

### Receiver TUI rules

- Header: `⇌ HANDOFF FROM [AUTHOR uppercase]` left, `Mon DD` right
- Briefing: wrap at ~60 chars — the primary content
- **Repos section** (between `├───┤` dividers): `◈` for each repo in `## Repo State`. Format: `◈ {repo}: {branch} → PR #{N} to {base}` (if PR exists) or `◈ {repo}: {branch} → {base}` (no PR). Omit entirely if no `## Repo State` section in the handoff file.
- Open Threads section (between `├───┤` dividers): `○` for each thread. Omit entirely if none.
- Artifacts section: `◉` for each artifact. Omit entirely if none.
- Entry points: `→` for file paths, shortened to last 2-3 segments with `...` if needed
- Omit empty sections entirely
- **No sub-boxes** — only outer frame `│` borders and `├────┤` separators

### When /activity shows handoffs

In `/activity`, handoffs directed at the current user use the three-icon status system:
```
[1] ● alice → you: Infra fix after sync (yesterday)    ← pending (unread)
[2] ◐ carol → you: Slash command testing (2d ago)      ← read but open
    ○ alice → you: Setup flow (done)                   ← resolved (unnumbered)
```

When the user selects a numbered item, display the receiver view above by reading the handoff file from the path in the Session node's `filePath` property.

## Step 9: Reflection prompt — CONNECTED MODE ONLY

**Skip this entire step in local mode.** Do not run the artifact count query.

After displaying the TUI confirmation, check if today's sessions produced no non-tutorial artifacts. Query:

```cypher
MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person {name: $me})
WHERE a.created >= datetime({year: $year, month: $month, day: $day})
  AND NOT 'tutorial-generated' IN coalesce(a.topics, [])
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
| Neo4j unavailable (connected mode) | Still create handoff file and index. Show warning: "Graph offline — file saved, will sync on next /save". Skip artifact query. |
| Local mode | Skip all graph/notify calls silently — no warnings, no "graph offline" messaging. File creation + index update + auto-save work normally. TUI shows `✓ Saved · pushed`. No notification. |
| No artifacts today | Omit Session Artifacts sub-box from TUI and Telegram message |
| Notification fails | Show warning but don't fail the handoff: "Notification failed — [recipient] can see this on /activity" |
| Memory symlink missing | Error: "Run /setup first — memory not linked" |
| Recipient not a known Person | **Connected mode:** Warn: "[name] not found in graph — handoff saved but not directed. Create them with /invite?" **Local mode:** Warn: "[name] not found in memory/people/ — handoff saved but not directed. Add them with /invite?" |
| No topic in $ARGUMENTS | If open handoffs exist → triage mode (Step 0.5). Otherwise, summarize the session and generate a topic from conversation context |
| Empty session (nothing happened) | Ask: "Nothing to hand off yet. Want to leave a note instead?" |
| Scoped briefing is very short | Fine — focused handoffs are better than muddled ones |
| File already exists at path | Append timestamp to slug to avoid collision |
| No repos touched (all on base branch) | Omit `## Repo State` section from file, omit REPOS from TUI, omit repos from Telegram notification |
| Managed repo dir missing | Skip that repo silently — it may not be cloned locally |
| Recipient auto-checkout branch gone | Report: `◐ {repo}: PR #{N} merged — on {base}` |

## Full example: with recipient (connected mode, cross-repo)

```
> /handoff defensibility architecture to alice

Creating handoff...

Summarizing session...

  [1/5] ✓ Conversation file
        → memory/handoffs/2026-02/07-bob-defensibility-architecture.md

  [2/5] ✓ Index updated

  [3/5] ✓ Session -> knowledge graph

  [4/5] ✓ Pushed + PR created

  [5/5] ✓ Alice notified

┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF SENT                                     bob · Feb 07     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: Defensibility architecture                                   │
│  To: Alice                                                           │
│                                                                      │
│  Analyzed five-layer moat framework for Egregore. Server-side        │
│  intelligence is the biggest gap and biggest opportunity.             │
│  Defined pricing tiers and go-to-market sequence.                    │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  REPOS                                                               │
│  ◈ egregore: dev/bob/topic → PR #435 to develop               │
│  ◈ egregore-site: dev/bob/topic → PR #12 to main                    │
├──────────────────────────────────────────────────────────────────────┤
│  ◉ Decision: Defensibility architecture framework                    │
│  ◉ Finding: Harvest flywheel as training surface                     │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed · Alice notified                            │
│  Team sees this on /activity.                                        │
└──────────────────────────────────────────────────────────────────────┘
```

## Full example: no recipient (local mode, cross-repo)

```
> /handoff mcp auth flow

Creating handoff...

Summarizing session...

  [1/3] ✓ Conversation file
        → memory/handoffs/2026-02/07-alice-mcp-auth-flow.md

  [2/3] ✓ Index updated

  [3/3] ✓ Pushed + PR created

┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF SENT                                      alice · Feb 07     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: MCP auth flow                                                │
│                                                                      │
│  Implemented OAuth device flow for MCP authentication.               │
│  Token refresh works end-to-end. Needs error handling                │
│  for expired sessions.                                               │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  REPOS                                                               │
│  ◈ egregore: dev/alice/mcp-auth → develop                            │
│  ◈ egregore-site: dev/alice/mcp-auth → main                         │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · pushed                                                    │
│  Team sees this on /activity.                                        │
└──────────────────────────────────────────────────────────────────────┘
```
