End a session with a summary for the next person (or future you). With no arguments, triages open handoffs first.

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## When to invoke

User says: "I'm done", "wrapping up", "leave a handoff", "pass this to [name]", "hand off", "done for now", "signing off"
Not this: user wants to push but keep working → `/save`

## Mode detection

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

**Local mode** (`mode === "local"`): graph queries and DM-style notifications are unavailable. The group-relay notification still works when `telegram_chat_id` is set. Artifact publishing routes through the public OSS relay (ephemeral 7-day TTL) — an acceptable fallback, but note that the handoff body is uploaded there.

**Connected mode**: full feature set — Neo4j indexing, today's artifacts query, DM notifications, branded permanent artifact URLs, PR-number backfill.

## Execution model

Mechanical work delegates to `bin/handoff-run.sh` in a single Bash call. The main session drafts the briefing markdown and pipes it via heredoc; the script writes the file, updates the index, indexes to Neo4j, pushes memory, publishes the artifact, and notifies the recipient — all in parallel where possible.

**No per-step progress chatter.** The Bash tool block IS the progress indicator. No `[1/5] ✓ Conversation file` lines.

**No raw JSON.** Parse `handoff-run.sh`'s result file (written to `$TMPDIR/handoff-run-result.json`); only render the rich TUI card as text. Never echo raw JSON back to the user.

**Suppress raw output.** All `bin/graph.sh` and `bin/notify.sh` calls from this skill (triage, artifact query, reflection query) MUST redirect stdout to `/dev/null` or capture in a variable. Only show formatted progress lines or the final card.

## Step 0: Identity + team directory

```bash
git config user.name
```

Derive author handle: **lowercase first word** of git user.name (e.g. "Alice Smith" → "alice", "Oguzhan" → "oguzhan"). Do NOT pass a mixed-case handle — the script uses it verbatim in filenames and commit messages.

**Team members — always from the filesystem**, regardless of mode. `memory/people/*.md` is the source of truth for both the GitHub handle and the display name:

```bash
for f in memory/people/*.md; do
  [ -f "$f" ] || continue
  github=$(basename "$f" .md)
  display=$(head -1 "$f" | sed 's/^# //')
  echo "$github|$display"
done
```

- **Filename** (minus `.md`) = GitHub handle.
- **First line** (`# Display Name`) = the name the person chose, including anything they set via `/me "call me oz"`. `/me` writes this line directly to the file and re-syncs the graph's `Person.name` to match — the file is canonical. In local mode the file is the only place it lives; in connected mode the graph mirrors it.

Match recipient case-insensitively against either. Display name wins on conflict (`/handoff to oz` should resolve even if the filename is `oguzhan.md`).

The graph has a couple more fields (`fullName`, `telegramUsername`) that /handoff doesn't use for recipient matching, so a graph round-trip here would just be ~1s of network for the same handle + display name we already have on disk. Skip it.

## Step 0.5: Triage mode (bare `/handoff` + open handoffs exist)

**Trigger:** `$ARGUMENTS` is empty AND there are open handoffs directed at the current user.

**Connected mode:** query the graph for open handoffs to me in the last 14 days:

```cypher
MATCH (s:Session)-[:HANDED_TO]->(p:Person {name: $me})
WHERE coalesce(s.handoffStatus, 'pending') IN ['pending', 'read']
  AND date(left(toString(s.date), 10)) >= date() - duration('P14D')
MATCH (s)-[:BY]->(author:Person)
RETURN s.topic AS topic, s.date AS date, author.name AS author,
       s.filePath AS filePath, s.id AS sessionId,
       coalesce(s.handoffStatus, 'pending') AS status
ORDER BY CASE coalesce(s.handoffStatus, 'pending') WHEN 'pending' THEN 0 ELSE 1 END, s.date DESC
LIMIT 8
```

**Local mode:** read `memory/handoffs/index.md`, scan last 14 days, find entries with `to: {me}` (or `handoff to {me}`), read each file for topic and author. All treated as `pending` — no status tracking in local mode.

**If no open handoffs** → fall through to Step 1 (normal create flow; summarize the session to synthesize a topic).

**If open handoffs exist** → enter triage mode.

### Route A: Guided walk-through (1 – 3 handoffs)

For each handoff, in order:

**1. Display the receiver view** (see "Receiver View" section below). Read the file at `filePath` (prepend `memory/` if the path is relative) to populate content.

**2. Ask via AskUserQuestion:**

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

- **"Done" / "Not relevant"** (or any freeform text that implies done):
  - **Connected mode:** `bash bin/graph.sh query "MATCH (s:Session {id: '$sessionId'}) SET s.handoffStatus = 'done'${RESP:+, s.handoffResponse = '$RESP'} RETURN s.id" >/dev/null 2>&1` where `$RESP` is a SQL-escaped freeform response if user typed one.
  - **Local mode:** skip the graph call — status is informational only.
  - Output: `✓ Resolved: {topic} from {author}` (and `  Captured: "{first 60 chars}…"` if freeform).

- **"Still open"**:
  - **Connected mode:** if currently `pending`, mark as `read`: `bash bin/graph.sh query "MATCH (s:Session {id: '$sessionId'}) WHERE s.handoffStatus = 'pending' OR s.handoffStatus IS NULL SET s.handoffStatus = 'read', s.handoffReadDate = date() RETURN s.id" >/dev/null 2>&1`
  - **Local mode:** skip the graph call.
  - Output: `◐ Kept open: {topic} from {author}`
  - **Auto-checkout repos**: if the handoff file has a `## Repo State` section, parse its table (skip the header rows) and for each row, fetch + checkout the branch in the sibling repo directory:
    ```bash
    PARENT_DIR="$(cd .. && pwd)"
    REPO_DIR="$PARENT_DIR/$REPO_NAME"
    if [ -d "$REPO_DIR/.git" ] || [ -f "$REPO_DIR/.git" ]; then
      git -C "$REPO_DIR" fetch origin "$BRANCH" --quiet 2>/dev/null
      git -C "$REPO_DIR" checkout "$BRANCH" 2>/dev/null || \
        git -C "$REPO_DIR" checkout -b "$BRANCH" "origin/$BRANCH" 2>/dev/null
    fi
    ```
    Report: `✓ Checked out {branch} in {repo1}, {repo2}`. If the remote branch is gone (PR merged): `◐ {repo}: PR #{N} merged — on {base}`. Managed repo dir missing → skip silently.

**4. After all handoffs:**

```
All caught up.

Handing off this session? (topic, or enter to skip)
```

If user provides a topic → fall through to Step 1. If empty/enter → exit.

### Route B: Batch triage (4+ handoffs)

```
header: "Triage"
question: "Which handoffs have you addressed?"
multiSelect: true
options: (max 4; pending first, then oldest read)
  - label: "{author}: {topic}"
    description: "{status_icon} {when}"
```

Where `status_icon` is `●` for pending, `◐` for read. If more than 4, show top 4 and note: `Showing 4 of N — run /handoff again to triage the rest.`

**After selection:**
- Each selected handoff → mark `done` (connected) / skip (local).
- Unselected `pending` handoffs → mark `read` (connected) / skip (local).
- Output: `✓ Resolved N handoffs` (and `◐ Kept N open` if any unselected).

Then the same "Handing off this session?" fall-through as Route A.

## Step 1: Parse arguments (create flow)

**Only reached if `$ARGUMENTS` is non-empty OR user provided a topic after triage.**

Extract from `$ARGUMENTS`:
- **Topic** — the thing being handed off (may include "to <person>" which you strip from the topic).
- **Recipient** — optional, derived from "to <name>" or "for <name>". Leave empty if not specified or if the user wrote "to self".

Examples:
- `auth flow to alice` → topic: `auth flow`, recipient: `alice`
- `mcp debugging for cem to pick up` → topic: `mcp debugging`, recipient: `cem`
- `research pipeline writeup` → topic: `research pipeline writeup`, recipient: (none)
- `tui cleanup to self` → topic: `tui cleanup`, recipient: (none — "self" is implicit)

**Recipient matching:** case-insensitive against the team directory from Step 0. Match display name OR GitHub handle. Display name wins on conflict.

**Empty arguments AND no open handoffs to triage** → summarize the session and synthesize a topic from conversation context.

**Recipient not in the team directory** → don't burn an AskUserQuestion. Proceed without `--recipient` and note it in the final card footer: `◐ {name} not in team directory — handoff saved without direct address.`

## Step 2: Draft the briefing (no tool call)

Synthesize the session into a briefing. Actively interpret — this is not a transcript. Situate the work in team context (active quests, recent handoffs, known priorities). Tell the reader what matters and why.

Produce (omit any section that is genuinely empty — don't ship placeholder bullets):

1. **Briefing** — 2–4 sentences. What happened, why it matters, how it connects.
2. **Key Decisions** — decisions with rationale and implications.
3. **Current State** — working / in progress / blocked.
4. **Open Threads** — unfinished items with enough context to pick up.
5. **Next Steps** — clear actions with entry points.
6. **Entry Points** — specific files/commands for the next session.

If `$ARGUMENTS` narrows scope, constrain the briefing to that scope; don't include unrelated threads from the session.

**This is drafted in your head**, not via a tool call. The resulting markdown is the heredoc payload to `handoff-run.sh` in Step 4.

## Step 3: Session Artifacts — automatic

You don't do anything here. `handoff-run.sh` queries the graph for today's artifacts by this author in parallel with everything else (Branch D), filters out tutorial-tagged ones, and appends a `## Session Artifacts` section to the handoff file BEFORE Branch B commits — so the committed file always has them. The results also come back in the result JSON's `artifacts` array for the card render.

The graph is the right tool here: indexed by date + author + tag, returns a structured list. A filesystem walk would have to read every file under `memory/knowledge/` and filter by frontmatter — slow and ugly. This is exactly the navigation-layer role the graph is built for.

Local mode: skipped silently (no graph). `artifacts` in the JSON will be an empty array.

## Step 4: Call handoff-run.sh

One bash call. Briefing content on stdin via heredoc.

```bash
bash bin/handoff-run.sh \
  --author <lowercase-handle> \
  --topic "<topic>" \
  [--recipient <name>] \
  [--project <name>] \
  <<'HANDOFFEOF'
# Handoff: <topic>

**Date**: YYYY-MM-DD
**Author**: <Display Name>
**To**: <recipient, if any>
**Project**: <project, if identifiable>

## Briefing

<2-4 sentences>

## Key Decisions

- **<Decision>**: <rationale>

## Current State

<what's working / in progress / blocked>

## Open Threads

- [ ] <unfinished item with context>

## Next Steps

1. <clear action with entry point>

## Entry Points

For the next session, start by:
- Reading: <specific file>
- Running: <specific command>

## Session Artifacts

- <Type>: <Title> -> <path>
HANDOFFEOF
```

**`--author`**: lowercase handle only (see Step 0). **`**Author**:`** in the file body: display name (e.g. `Oz`).

**`--project`**: derive from conversation context. Omit the flag if unclear.

**Omit optional body sections** (Key Decisions, Open Threads, Session Artifacts, etc.) entirely if empty.

`handoff-run.sh` handles, in one process:
1. File write to `memory/handoffs/YYYY-MM/DD-author-slug.md`
2. Append `## Repo State` section from `bin/repo-state.sh` if any repos are on non-base branches or have uncommitted changes
3. Prepend `memory/handoffs/index.md`
4. Index to Neo4j via `bin/index-handoff.sh` (connected mode only — Session node, BY/HANDED_TO/ABOUT edges, auto-resolve of old `read` handoffs from this author)
5. Memory commit + pull-rebase-push to main (in parallel with 4)
6. Publish branded HTML artifact via `bin/publish-artifact.sh` (which also detaches a depth-1 publish of backtick-referenced `memory/**/*.md` paths)
7. Send Telegram notification via `bin/notify.sh` — **always**, even for self-handoffs. With `--recipient` in connected mode → DM; otherwise → group (includes self-handoffs and local mode). A handoff without a Telegram beat is invisible.
8. Emit one status line to stdout, write full result to `$TMPDIR/handoff-run-result.json`

## Step 5: Render the rich card

Read `$TMPDIR/handoff-run-result.json`:

```json
{
  "mode": "connected|local",
  "file": "handoffs/YYYY-MM/DD-author-slug.md",
  "absFile": "/absolute/path/...",
  "sessionId": "...",
  "resolved": 0,
  "graphStatus": "ok|offline|skipped",
  "memoryStatus": "ok|failed|skipped (--no-push)",
  "notifyStatus": "sent|failed|skipped|unknown",
  "artifactUrl": "https://...",
  "recipient": "...",
  "topic": "...",
  "author": "...",
  "subgraph": { ... },
  "artifacts": [ {"title": "...", "type": "Decision|Finding|...", "path": "memory/..."} ]
}
```

### The box

Wrap in a ` ``` ` code fence so the chat renderer preserves monospace alignment. Outer width 72 chars. Only four line patterns:

1. **Top**: `┌` + 70×`─` + `┐`
2. **Separator**: `├` + 70×`─` + `┤`
3. **Content**: `│` + 2 spaces + text + trailing spaces padding to 68 chars + `│` (70 chars between borders)
4. **Bottom**: `└` + 70×`─` + `┘`

Copy the top/separator/bottom lines verbatim — don't recount dashes each time.

**Never use `&nbsp;` or other HTML entities** — this renderer doesn't convert them. Use real space characters inside the box (monospace, reliable), and plain markdown below.

**Em-dashes (`—`), arrows (`→`), and other multi-byte UTF-8 characters each count as one display column** — don't double-count them.

Shape (no recipient, no artifacts):

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF SENT                                      {Author} · {MMM DD}  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: {topic}                                                      │
│                                                                      │
│  {briefing line 1, wrapped at ~64 chars}                             │
│  {briefing line 2}                                                   │
│  {briefing line 3}                                                   │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ {status bits joined with " · "}                                   │
└──────────────────────────────────────────────────────────────────────┘
```

Shape (with recipient, repos, and artifacts):

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF SENT                                      {Author} · {MMM DD}  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: {topic}                                                      │
│  To:    {Recipient}                                                  │
│                                                                      │
│  {briefing line 1}                                                   │
│  {briefing line 2}                                                   │
│  {briefing line 3}                                                   │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  REPOS                                                               │
│  ◈ {repo}: {branch} → PR #{N} to {base}                              │
│  ◈ {repo}: {branch} → {base}                                         │
├──────────────────────────────────────────────────────────────────────┤
│  ◉ {Type}: {Title}                                                   │
│  ◉ {Type}: {Title}                                                   │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ {status bits}                                                     │
└──────────────────────────────────────────────────────────────────────┘
```

**Repos section** — populate by re-reading the written handoff file's `## Repo State` table (its path is `absFile` from the JSON). Omit the section entirely if no table. PR number `—` means no open PR yet (backfill may populate later).

**Artifacts section** — populate from the `artifacts` array in the result JSON (filled by Branch D of `handoff-run.sh`). Each entry: `◉ {type}: {title}`. Omit the section entirely if the array is empty.

### Filling in the fields

- **`{Author}`** — from `author` in JSON. Prefer the display name (from `memory/people/{handle}.md`'s `# <name>` header) if you have it; otherwise capitalize the handle (`oguzhan` → `Oguzhan`).
- **`{MMM DD}`** — today formatted like `Apr 24`.
- **`{topic}`** — from JSON. Truncate at 58 chars with `…` if longer.
- **`{Recipient}`** — only if `recipient` in JSON is non-empty. Title-case.
- **`{briefing}`** — the 2–4 sentences from Step 2, wrapped hard at ~64 chars. Use what you drafted — no need to re-read the file.
- **Status bits** — build from JSON flags, join with ` · `:
  - Always: `saved`
  - If `graphStatus == "ok"`: `graphed`
  - If `memoryStatus == "ok"`: `pushed`
  - If `notifyStatus == "sent"` AND `recipient` non-empty: `{recipient} notified` (lowercase recipient)
  - If `notifyStatus == "sent"` AND `recipient` empty: `group notified` (self-handoff posted to Telegram group)
  - If `notifyStatus == "unknown"`: `{recipient} relayed to group` (DM-to-group fallback)
  - If `artifactUrl` non-empty: `published`

### Links below the box

After the closing ` ``` `, render two links on one line — the hosted artifact and the local /view command:

```markdown
[view this handoff →]({artifactUrl})  ·  `/view handoff {slug}` (open locally)
```

- **Hosted link** (`[view this handoff →]({artifactUrl})`) — only include if `artifactUrl` in the JSON is non-empty. This is the branded egregore.xyz URL with OG preview.
- **Local /view hint** (`` `/view handoff {slug}` ``) — ALWAYS include. The slug is the filename stem after `DD-{author}-`, e.g. for `memory/handoffs/2026-04/24-oguzhan-auth-refactor.md` the slug is `auth-refactor`. Extract it from the `file` field in the result JSON: strip the directory and `.md` suffix, then drop the `DD-{author}-` prefix. This lets the user open the handoff locally in the browser without copy-pasting a URL.

If `artifactUrl` is empty, collapse to just the local hint:

```markdown
`/view handoff {slug}` (open locally)
```

Then, if natural, add ONE short sentence of sign-off — a human beat telling the recipient what the state is for them. Examples:
- `Renc has the link, the WIP note, and everything else. Ready when you want to move on.`
- `Ping me if the rebase conflicts.`
- `Nothing needed from you — just capturing state.`

Keep it to one sentence. Skip if there's nothing meaningful to add.

### Padding content lines — critical

Every content line is exactly 72 chars wide including borders: `│  {text}{pad to 68}│`. If a line looks visually short, it wasn't padded — fix it.

### Degraded states (warnings ABOVE the box)

| Flag | Render (markdown line, above the code fence) |
|---|---|
| `graphStatus == "offline"` in connected mode | `⚠ graph indexing failed — will sync on next /save` |
| `memoryStatus == "failed"` | `⚠ memory push failed — commits are local` |
| `notifyStatus == "failed"` | `⚠ notification to {recipient} failed — they can see this on /activity` |

`memoryStatus == "skipped (--no-push)"` is NOT a failure — no warning. `notifyStatus == "unknown"` reflects a DM-to-group fallback — no warning; the status bit conveys it.

### What NOT to render

- **No `&nbsp;`** or other HTML entities.
- **No raw JSON** — ever.
- **No `[N/5]` progress lines** — the Bash tool block is the progress indicator.
- **No "Team sees this on /activity."** footer boilerplate — status bits say everything.
- **No preamble** like "Handoff created successfully" — the box IS the acknowledgment.

## Step 6: Auto-save egregore-side — DETACHED, NON-BLOCKING

**Fire once, forget.** Handoffs happen at natural exit points; people walk away. Don't make them wait on git — but don't let their session work sit uncommitted either.

Immediately after rendering the card, fire `bin/handoff-save-egregore.sh` detached. It reparents to init, so it survives session exit:

```bash
( bash bin/handoff-save-egregore.sh "$AUTHOR" "$TOPIC" >/dev/null 2>&1 & ) >/dev/null 2>&1
```

Then, in the markdown below the box, add one line so the user knows it's happening:

```markdown
Saving core-repo changes in the background — markdown-only will auto-merge to develop.
```

Omit that line if you already know there's nothing to save (quick check: `git status --porcelain` empty AND `git rev-list --count origin/develop..HEAD` is 0). The helper does the same check itself — it's just cheaper to skip the line than to say "nothing to save".

**The helper does:**
1. Early-exits if the working tree is clean and no commits are ahead of `origin/develop`.
2. If on `develop`/`main`/`master`, creates `dev/{author}/handoff-YYYY-MM-DD` from `origin/develop`.
3. Commits uncommitted work with message `Handoff: {topic}`.
4. Rebases onto `origin/develop` (falls back to merge if rebase conflicts).
5. Pushes the working branch.
6. Creates (or reuses) a PR to `develop`.
7. **Markdown-only diff → `gh pr merge --auto --merge`** — PR auto-merges as soon as checks pass. This is the common case for handoffs.
8. **Any non-markdown changes present → leave PR open for review.** No auto-merge for code/config. The user sees the PR next session.

Unresolvable conflicts or auth failures leave the branch as-is locally. The user will discover and resolve next session — no data loss, just a delayed merge.

Do NOT run `/save` inline here. `/save` is correct but slow (preflight, cypher checks, graph ops, managed-repo loop). For a handoff, the user is walking away — speed wins over completeness.

## Step 7: PR-number backfill — automatic

`handoff-run.sh` calls `bin/repo-state.sh --no-pr` to avoid the `gh pr list` round-trip per managed repo (~400–600ms each) on the hot path, then fires `bin/handoff-pr-backfill.sh` detached. The backfill rewrites `—` → `#N` for each row's open PR and re-commits the memory repo.

You don't do anything here. The orchestrator handles it. If the backfill fails (no `gh`, no open PR, network drop), the `—` stays — cosmetic only, branch names are the primary coordination mechanism.

## Step 8: Reflection prompt — CONNECTED MODE ONLY

After the card and auto-save, check if today's sessions produced no non-tutorial artifacts:

```bash
ARTIFACT_COUNT=$(bash bin/graph.sh query "
  MATCH (a:Artifact)-[:CONTRIBUTED_BY]->(p:Person {name: \$me})
  WHERE a.created >= datetime({year: $(date +%Y), month: $(date +%-m), day: $(date +%-d)})
    AND NOT 'tutorial-generated' IN coalesce(a.topics, [])
  RETURN count(a) AS artifactCount" 2>/dev/null | jq -r '.values[0][0] // 0' 2>/dev/null)
```

If `ARTIFACT_COUNT == 0`, show one line (NOT an AskUserQuestion — a soft nudge):

```
This session had insights worth capturing. Quick /reflect?
```

If artifacts exist, skip silently.

## Receiver View (for triage + /activity integration)

When a recipient reads a handoff directed at them — during Step 0.5 Route A, or when `/activity` shows a handoff — display this format.

Same boundary rules as Step 5 (72-char outer width, four line patterns, no sub-boxes).

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⇌ HANDOFF FROM {AUTHOR uppercase}                      {Mon DD}     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Topic: {topic}                                                      │
│                                                                      │
│  {briefing wrapped at ~64 chars}                                     │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  REPOS                                                               │
│  ◈ {repo}: {branch} → PR #{N} to {base}                              │
├──────────────────────────────────────────────────────────────────────┤
│  OPEN THREADS                                                        │
│  ○ {thread 1}                                                        │
│  ○ {thread 2}                                                        │
├──────────────────────────────────────────────────────────────────────┤
│  ◉ {Type}: {Title}                                                   │
├──────────────────────────────────────────────────────────────────────┤
│  → {shortened entry-point path}                                      │
│  → {shortened entry-point path}                                      │
└──────────────────────────────────────────────────────────────────────┘
```

**Rules:**
- Header left: `⇌ HANDOFF FROM {AUTHOR uppercase}`. Header right: `Mon DD`.
- Briefing: wrap at ~64 chars.
- **REPOS** section (between `├───┤`): `◈` for each row in the handoff file's `## Repo State` table. Omit section entirely if no table.
- **OPEN THREADS** section: `○` for each item in `## Open Threads`. Omit if none.
- **Artifacts** section: `◉` for each item in `## Session Artifacts`. Omit if none.
- **Entry points**: `→` for file paths from `## Entry Points`, shortened to last 2–3 segments with `…` if needed.
- Omit empty sections entirely. No sub-boxes.

### Where /activity uses this

`/activity` shows handoffs directed at the current user with three-icon status (`●` pending, `◐` read, `○` done). When the user selects a numbered handoff, `/activity` reads the file from the Session's `filePath` and renders the receiver view above.

## Edge cases

| Scenario | Handling |
|---|---|
| `handoff-run.sh` exits non-zero | Show last ~10 lines of its stderr plus "Run with `GRAPH_OP_VERBOSE=1` to debug." Do not retry automatically. |
| `graphStatus == "offline"` in connected mode | Warning line above box: `⚠ graph indexing failed — will sync on next /save`. Skip the reflection prompt (Step 8). |
| `memoryStatus == "failed"` | Warning line above box. Do not silently swallow. |
| `notifyStatus == "failed"` | Warning line above box. Do not block the card. |
| `notifyStatus == "unknown"` | Status bit reads `{recipient} relayed to group` (DM fell back to group chat). No warning. |
| Local mode + recipient specified | Notify goes to the Telegram group via relay (DMs not available without API). Card's status bit reads `{recipient} notified` if `sent`. If `telegram_chat_id` is unset, notify is skipped silently. |
| Self-handoff (no recipient) | Notify ALWAYS fires — posts to the Telegram group so the handoff is visible. Card's status bit reads `group notified`. A handoff without a Telegram beat is invisible, which defeats the point. |
| Local mode + artifact publish | Falls through to the public OSS relay with 7-day TTL. Handoff body is uploaded there. Acceptable fallback but surfaced via `published` bit. |
| Empty session (nothing happened) | Ask "Nothing to hand off yet. Want to leave a note instead?" — don't create an empty file. |
| File already exists at path | `handoff-run.sh` appends `-N` to the slug to avoid collision. |
| No repos touched (all on base branch) | `bin/repo-state.sh` returns empty → `## Repo State` section omitted → REPOS omitted from TUI. |
| Recipient auto-checkout branch gone (triage Route A, "still open") | Report `◐ {repo}: PR #{N} merged — on {base}`. |
| Managed repo dir missing | Skip silently in both triage auto-checkout and `bin/repo-state.sh` output. |
| Mid-session `/handoff` (not end-of-session) | Same flow. Briefing is whatever was in scope. Auto-save (Step 6) still fires. |
| Scoped briefing is very short | Fine — focused handoffs are better than muddled ones. |

## Status-line bits

| Bit | Present when |
|---|---|
| `saved` | Always — file is on disk. |
| `graphed` | `graphStatus == "ok"` — Session node created in Neo4j (connected mode only). |
| `pushed` | `memoryStatus == "ok"` — memory repo committed and pushed to main. |
| `{name} notified` | `notifyStatus == "sent"` AND recipient set — Telegram DM delivered. |
| `group notified` | `notifyStatus == "sent"` AND recipient empty — posted to Telegram group (self-handoff or local mode). |
| `{name} relayed to group` | `notifyStatus == "unknown"` — DM fell back to group chat. |
| `published` | `artifactUrl` non-empty — branded HTML artifact published. |

Missing bits are informative, not errors. `graphed` missing in local mode is normal. `pushed` missing under `--no-push` is normal. A notify bit is ALWAYS present — every handoff posts somewhere; a handoff with no Telegram beat is invisible.
