End a session with a summary for the next person (or future you). With no arguments, triages open handoffs first.

Topic: $ARGUMENTS

**Auto-saves.** No need to run `/save` after.

## When to invoke

User says: "I'm done", "wrapping up", "leave a handoff", "pass this to [name]", "hand off", "done for now", "signing off"
Not this: user wants to push but keep working → `/save`

**Scope:** `/handoff` is the **team session-handoff** — internal recap addressed to a teammate or future-you, indexed in Neo4j, posted to Telegram, written to `memory/handoffs/`, auto-PR'd to develop. It is NOT a portable capsule.

**Portable, executable capsules** — the kind you share with someone outside the team via an `egregore.xyz/emissary/e/<id>` link — live in `/emissary`. If the user pastes such a link, asks to "make/send/run an emissary", or wants capsule lifecycle (receive, reply, run), route to `/emissary` and stop. Do not handle capsules here.

## Disambiguation

- "Show me my handoffs" → team handoffs (`/activity`). For capsules sent externally, that's `/emissary` territory.
- "I'm done", "wrap this up", "hand off to alice", `/handoff <topic>` → AUTHOR flow below.
- "Let's make an emissary", "send an emissary to alice", pasted `egregore.xyz/emissary/e/<id>` → `/emissary`.

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
- **Recipient** — optional, derived from "to <name>" or "for <name>". Leave empty only if no "to" clause at all.

**"to self" / "to me" / "to myself" → recipient = author handle.** These phrases mean "DM future-me the link", not "broadcast to the group". Set `--recipient` to the author handle (lowercase first word of `git config user.name`) so notify routes as a personal DM. Strip the self-phrase from the topic.

Examples:
- `auth flow to alice` → topic: `auth flow`, recipient: `alice`
- `mcp debugging for cem to pick up` → topic: `mcp debugging`, recipient: `cem`
- `research pipeline writeup` → topic: `research pipeline writeup`, recipient: (none)
- `tui cleanup to self` → topic: `tui cleanup`, recipient: `{author handle}` (DM to author)
- `tui cleanup to myself` → topic: `tui cleanup`, recipient: `{author handle}` (DM to author)

**Recipient matching:** case-insensitive against the team directory from Step 0. Match display name OR GitHub handle. Display name wins on conflict.

**Empty arguments AND no open handoffs to triage** → summarize the session and synthesize a topic from conversation context.

**Recipient not in the team directory** → don't burn an AskUserQuestion. Proceed without `--recipient` and note it in the final card footer: `◐ {name} not in team directory — handoff saved without direct address.`

## Step 2: COMPOSE the handoff into the house-kit — then confirm

A handoff renders through the **shared composer** (the same one emissaries use), so it comes out looking like a flagship artifact — the way cem's Decision Surface does — **not a wall of prose**. The beauty comes from *composing*: you read the session and **choose a component per section**. A dumb markdown→render converter can't invent structure; you can. This is the whole difference between "themed" and "beautiful."

You produce **two things**, both in your head:

**1. The house-kit render spec — a JSON (this is the beautiful artifact).**
```json
{
  "kind":"handoff", "kicker":"Handoff", "topic":"<topic>",
  "claim":"<one line — what this handoff is>",
  "chips":[{"text":"From <author>"},{"text":"For <recipient>"},{"text":"<date>"},{"text":"<status>","tone":"brass"}],
  "highlights":[{"v":"<stat>","l":"<label>","tone":"teal"}],
  "agent":{"ask":"<what the receiving agent should do>","receiverInstructions":"<optional directive>","core":[{"k":"topic","v":"..."},{"k":"ask","v":"..."},{"k":"for","v":"..."}]},
  "repoState":[{"repo":"...","branch":"...","pr_number":0,"base":"develop"}],
  "sections":[ { "label":"<short>", "title":"<statement>", "component":"<pick>", "...": "..." } ],
  "tags":["<author>","<date>"]
}
```

**Pick the component that fits each section's SHAPE** — do NOT default to prose:
- `claims` — a stat/outcome band → `items:[{v,l,tone}]`. Pull 2–3 key numbers/results into `highlights` (a top band) or a section.
- `steps` — a sequence / "here's what landed" → `items:[{title,body}]` (body is markdown); `after:"<wrap-up line>"` for a trailing summary.
- `tagcards` — decisions / disclosures / findings → `items:[{tag,tone,title,body,verdict}]` (tone: teal/brass/rose).
- `panels` — 2–3 options/comparison → `items:[{head,tone,body,points:[...]}]`.
- `compare` — before/after → `items:[{k:"// before",title,body,tone}]`.
- `ledger` — Q&A → `items:[{q,a}]`.
- `flow` — a staged loop → `items:[{tag,tone,title,body,conn}]`.
- `pullquote` — one sharp line → `{body}`.  `note` — a caveat/aside → `{body}`.
- `prose` — genuine narrative only → `{body}` (markdown). Use it sparingly.

**2. The markdown record — the memory/grep copy** (frontmatter + the material as plain markdown). This becomes the memory file + graph index and stays greppable; the JSON is what renders.

If `$ARGUMENTS` narrows scope, constrain to that scope.

**Then CONFIRM before sending (the gate).** `handoff-run.sh` publishes + notifies. Show the user the composed shape — each section's label + the component you chose, plus `claim`/`ask` — and get a quick OK. If they edit, apply and re-show. (Skip only if they said "just send it".)

## Step 3: Session Artifacts — automatic

You don't do anything here. `handoff-run.sh` queries the graph for today's artifacts by this author in parallel with everything else (Branch D), filters out tutorial-tagged ones, and appends a `## Session Artifacts` section to the handoff file BEFORE Branch B commits — so the committed file always has them. The results also come back in the result JSON's `artifacts` array for the card render.

The graph is the right tool here: indexed by date + author + tag, returns a structured list. A filesystem walk would have to read every file under `memory/knowledge/` and filter by frontmatter — slow and ugly. This is exactly the navigation-layer role the graph is built for.

Local mode: skipped silently (no graph). `artifacts` in the JSON will be an empty array.

## Step 4: Call handoff-run.sh

Write the house-kit JSON to a temp file, then one bash call — the markdown record on stdin, the JSON via `--composed`:

```bash
cat > "${TMPDIR:-/tmp}/handoff-composed.json" <<'JSONEOF'
{ ...the Step 2 house-kit render spec... }
JSONEOF

bash bin/handoff-run.sh \
  --author <lowercase-handle> \
  --topic "<topic>" \
  [--recipient <name>] \
  [--project <name>] \
  --composed "${TMPDIR:-/tmp}/handoff-composed.json" \
  <<'HANDOFFEOF'
---
from: <lowercase-handle>
addressed_to: <recipient, if any>
date: YYYY-MM-DD
topic: <topic>
claim: <one line — what this handoff is>
ask: <what the receiving agent should do>
receiver_instructions: <optional — a directive to the receiving agent>
---

<THE MATERIAL — plain markdown, the memory/grep record. Its own `## sections`,
its own prose. This is the record; the JSON is what renders.>
HANDOFFEOF
```

`--composed` makes the pipeline render the **house-kit JSON** (rich components, `render_mode:custom`, never falls back to letterhead). The markdown stays the memory record + graph index. **Omit `--composed`** only for a bare recap with nothing worth composing — the markdown floor renders instead.

**Fallback body (only when nothing was prepared)** — replace the material with synthesized recipe sections:

```markdown
## Briefing

<2–4 sentences>

## Current State

<working / in progress / blocked>

## Next Steps

1. <clear action with entry point>
```

**`--author`**: lowercase handle only (see Step 0) — must match `from:`.

**`--project`**: derive from conversation context. Omit the flag if unclear.

**Frontmatter, not `**Key**:` lines.** The constrained core (`claim`/`ask`/`receiver_instructions`) drives the agent face and MUST be frontmatter — inline `**Key**:` lines leak into the reader body. Omit `receiver_instructions` if there's no specific directive. **Do NOT hand-write `## Repo State` or `## Session Artifacts`** — `handoff-run.sh` appends both, and the renderer routes Repo State into the agent face.

`handoff-run.sh` handles, in one process:
1. File write to `memory/handoffs/YYYY-MM/DD-author-slug.md`
2. Append `## Repo State` section from `bin/repo-state.sh` if any repos are on non-base branches or have uncommitted changes
3. Prepend `memory/handoffs/index.md`
4. Index to Neo4j via `bin/index-handoff.sh` (connected mode only — Session node, BY/HANDED_TO/ABOUT edges, auto-resolve of old `read` handoffs from this author)
5. Memory commit + pull-rebase-push to main (in parallel with 4)
6. Publish branded HTML artifact via `bin/publish-artifact.sh` (which also detaches a depth-1 publish of backtick-referenced `memory/**/*.md` paths)
7. Send Telegram notification via `bin/notify.sh` — **always**. Routing: `--recipient` set (incl. self via "to self/me/myself" → author handle) and connected mode → DM. No recipient (bare `/handoff` with no "to" clause) → group. Local mode → group regardless. A handoff without a Telegram beat is invisible.
8. Emit one status line to stdout, write full result to `$TMPDIR/handoff-run-result.json`

## Step 5: Render the rich card

Call the deterministic renderer directly:

```bash
bash bin/render-card.sh --result "${TMPDIR:-/tmp}/handoff-run-result.json"
```

The renderer reads the briefing from the written handoff file's `## Briefing` section via `absFile` in the result JSON. `--briefing-file` and stdin remain supported as explicit overrides.

Output the renderer stdout VERBATIM — no reformatting, no re-drawing, no preamble, no sign-off sentence. The renderer owns degraded warnings, the fenced 72-column card, repo/artifact sections, status bits, and the link line below the fence.

### What NOT to output

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
| `group notified` | `notifyStatus == "sent"` AND recipient empty — posted to Telegram group (no "to" clause, or local mode). |
| `{author} notified` | Self-handoff ("to self/me/myself") — recipient = author handle, DM to the author in connected mode. |
| `{name} relayed to group` | `notifyStatus == "unknown"` — DM fell back to group chat. |
| `published` | `artifactUrl` non-empty — branded HTML artifact published. |

Missing bits are informative, not errors. `graphed` missing in local mode is normal. `pushed` missing under `--no-push` is normal. A notify bit is ALWAYS present — every handoff posts somewhere; a handoff with no Telegram beat is invisible.
