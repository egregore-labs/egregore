See what's happening across the team — recent sessions, handoffs, and open work.

Display it immediately — no preamble, no narration, no reasoning text. Output the box and nothing else before AskUserQuestion.

## When to invoke

User says: "catch me up", "what's going on", "show dashboard", "where did I leave off", "what happened", "any updates", "what did I miss"
Not this: if user wants to *do* something specific, route to that command instead

Topic: $ARGUMENTS

## Step 1: Fetch data

Run ONE command to get all dashboard data:

```bash
bash bin/activity-data.sh
```

Returns JSON with these fields. Arrays are arrays of objects (NOT `{fields, values}` format).

**Arrays of objects:**
- `my_sessions` — `[{date, topic, id, filePath, handedTo}, ...]`
- `team_sessions` — `[{date, topic, by}, ...]`
- `quests` — `[{quest, title, artifacts, daysSince, score}, ...]`
- `pending_questions` — `[{setId, topic, created, from}, ...]`
- `answered_questions` — `[{setId, topic, answeredBy}, ...]`
- `handoffs_to_me` — `[{topic, date, author, filePath, sessionId, status, response}, ...]`
- `all_handoffs` — `[{topic, date, from, to, filePath}, ...]`
- `checkins` — `[{id, summary, date, by, total}, ...]`
- `focus_history` — `[{shown, selected, dismissed, date, topic}, ...]`

**Flat objects:**
- `todos_merged` — `{activeTodoCount, blockedCount, deferredCount, staleBlockedCount, lastCheckinDate}`
- `knowledge_gap` — `{gapCount}`
- `orphans` — `{orphanCount}`
- `trends.resolution` — `{avgDays, resolved}`
- `trends.throughput` — `{created, completed}`
- `trends.capture` — `{total, captured}`

**Other:**
- `trends.cadence` — `[{weeksAgo, sessions}, ...]`
- `me` — string (person name)
- `org`, `date` — strings (added client-side)
- `prs` — `[{number, title, author}, ...]` (from git, client-side)
- `disk` — `{handoffs, decisions}` (from filesystem, client-side)

The response includes `graph_status` (`"connected"` or `"offline"`) and `graph_reason` (one of: `missing_config`, `unreachable`, `auth_error`, `server_error`, `invalid_response`).

### Mode detection

Read `mode` from `egregore.json`:
```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

### Local mode (`mode === "local"`)

Do NOT show graph status, graph_reason, or any "/connect", "/setup", "/env" messaging. Read everything from filesystem:
- Recent sessions from `memory/handoffs/index.md` (last 5-10 entries)
- Active quests from `memory/quests/index.md`
- Recent decisions from `memory/knowledge/decisions/` (last 3 by date)
- PRs from `prs` field (git-based, always available)
- Footer: `"Local mode — showing activity from memory"`

### Connected mode — graph offline

Only applies when `mode === "connected"` (or mode not set):
- `graph_status: "connected"` → normal dashboard
- `graph_status: "offline"` → fall back to reading `memory/` files. Add `(offline)` after ✦ in header. Show the reason in footer:
  - `unreachable` → `Graph unreachable — check your network connection`
  - `auth_error` → `Graph auth failed — run /env to check API key`
  - `server_error` → `Graph server error — try again shortly`
  - `missing_config` → `Graph not configured — run /setup`
  - `invalid_response` → `Graph returned unexpected data — try again`

## Step 2: Render dashboard

Output the TUI box directly. 72 chars wide. Use these frame lines (copy exactly):

```
┌──────────────────────────────────────────────────────────────────────┐
├──────────────────────────────────────────────────────────────────────┤
└──────────────────────────────────────────────────────────────────────┘
```

Content rows: `│  {text padded with trailing spaces}  │`

**DO NOT count characters or show reasoning.** Approximate padding is fine — the frame is decorative, not pixel-perfect. Go straight from data to rendered output.

### Topic display rules (MANDATORY)

When displaying a session topic anywhere in the activity view:
- If `topic` is non-null: show it as-is
- If `topic` is null/empty: show the branch slug humanized (drop the `dev/author/` prefix, replace hyphens with spaces). E.g. `dev/oz/session-naming-bug` → `session naming bug`
- If branch is also null or is `develop`/`main`/`master`: show the session date as fallback (e.g. `Feb 24 session`)
- **NEVER show "untitled", "current session", "quick session", or any invented label**

### Sections (separated by `├────┤`)

**Header**: `{ORG} EGREGORE ✦ ACTIVITY DASHBOARD` left, `{me} · {date}` right

**Insight** (1-3 lines): Synthesize what's happening. Warm, concise, connective.
- Use `trends` data when available to enrich synthesis. Compare this week's cadence vs last week ("session cadence up 40%"), note capture ratio ("capture ratio at 75%"), mention throughput ("3 todos created, 5 completed this week"). Only mention trends that are notable — don't list all metrics.
- If `todos_merged.staleBlockedCount > 0`: `{N} todos blocked for 3+ days. /todo check to review.`
- If no check-in in 3+ days (check `todos_merged.lastCheckinDate`) AND `todos_merged.activeTodoCount >= 3`: `{N} active todos, no check-in in {days}d. /todo check to review.`

**Handoffs & Asks** (skip if all empty):
- Handoffs (status=pending) → `[N] ● {from} → you: {topic} ({when})`
- Handoffs (status=read) → `[N] ◐ {from} → you: {topic} ({when})`
- Handoffs (status=done) → `    ○ {from} → you: {topic} (done)`. If `response` field is non-null, append on next line: `      "{response truncated to 50 chars}..."`
- Pending questions → `[N] {from} asks about "{topic}" ({when})`
- Answered questions → `    ✓ {name} answered "{topic}"`
- Other handoffs → `    {from} → {to}: {topic} ({when})`
- Numbered items (● and ◐) first, blank line, then ○ + others.

**Sessions** — ALWAYS render. NEVER skip:
- `◦ YOUR SESSIONS` — iterate `my_sessions` array. Each object has `.date` and `.topic`. Show top 5: `{date}  {topic}`. If array is empty: `(none yet)`.
  - Interleave check-ins from `checkins` (where `.by` matches `me`) in chronological order: `{date}  Check-in: {summary}`
- `◦ TEAM` — iterate `team_sessions` array. Each object has `.date`, `.topic`, `.by`. Show top 5: `{date}  {by}: {topic}`. If array is empty: `(none yet)`.
  - Interleave check-ins from `checkins` (where `.by` differs from `me`) in chronological order: `{date}  {by}: Check-in: {summary}`
- `my_sessions` and `team_sessions` are independent arrays. One can be empty `[]` while the other has data.
- Blank line between sub-sections.

**Quests & PRs** (skip if both empty):
- `⚑ QUESTS (N active)` — top 5 by score. `{quest-id}` left, `{N} artifacts · {N}d ago` right.
- `→ OPEN PRs` — `#{number}  {title} ({author})`
- Blank line between sub-sections. Omit either if empty.

**Footer** (separated by `├────┤`):
- If orphans.orphanCount > 0: `{N} artifacts unlinked to quests — /quest suggest`
- If knowledge_gap.gapCount > 0: `{N} sessions without captured insights — /reflect to extract`
- Else: `/todo check to review · /ask a question · /quest to see more`
- If `packages/egregore-artifacts/` exists: `Open in browser? /view activity`
- Always end with: `What's your focus?`

### Date formatting

Today → `Today    ` (9 chars) · Yesterday → `Yesterday` · Older → `Mon DD   ` (9 chars). 2-space gap before topic.

Time ago: <1h `Nm ago` · 1-23h `Nh ago` · 1d `yesterday` · 2-6d `Nd ago` · 7d+ `Mon DD`

### Data freshness

Compare my_sessions for today vs disk.handoffs for today. If disk has more files than graph has sessions for today, show in footer: `{N} sessions on disk not in graph — /save to sync`

## Step 3: Session orientation

Fire AskUserQuestion immediately after the dashboard:

```
header: "Focus"
question: "What would you like to focus on?"
multiSelect: false
```

### Generating options — model-driven, not table-driven

Generate 2-4 options by reasoning over ALL available data. There is no fixed priority table. You have:

- `handoffs_to_me` — pending, read, and done handoffs with status
- `pending_questions` — unanswered questions from teammates
- `my_sessions` — recent work showing what the user has been doing
- `team_sessions` — what others are doing (collaboration opportunities)
- `quests` — active quests with scores and recency
- `prs` — open PRs that may need review
- `focus_history` — **what the user chose and dismissed in recent sessions**
- The full conversation context of this session (what they've already been working on)

**Use `focus_history` to adapt.** This is the key signal:

- If an option was **shown but not selected** across 2+ recent sessions → deprioritize it. The user has seen it and chosen not to engage. Don't keep pushing it to the top.
- If the user consistently selects **work stream continuation** over handoffs → lead with work streams, not handoffs.
- If the user typed **"Other" with custom text** → that tells you what they actually wanted. Use it to inform future option generation.
- If `focus_history` is empty (first session or new user) → fall back to surfacing pending handoffs and questions first, then work streams.

**Use current session context to adapt.** If the user has already been working on something in this session before running `/activity`, the options should reflect continuation of that work, not ignore it.

**Work stream detection:** Cluster recent sessions by theme. Name specifically — not "Continue recent work" but "Query optimization + batch endpoints" or "Pricing strategy refinement." Hint at what's next, not what's done.

**Constraints:**
- Minimum 2 options, maximum 4. "Other" is automatic (provided by AskUserQuestion).
- Every option must be grounded in actual data — no generic labels.
- Handoffs with status `done` are excluded from options entirely.
- Handoffs with status `read` are lower priority than `pending` but not excluded — the user may want to revisit.

### Recording the selection — CONNECTED MODE ONLY

**Skip this entire section in local mode.** Do not run `bin/graph-op.sh` or show "Remembering..." indicator. Proceed directly to the action.

After the user selects, record what happened for future sessions:

```
  ✦ Remembering...
```

Compute the dismissed options (shown minus selected) and record:
```bash
bash bin/graph-op.sh record-focus "$SESSION_ID" '$SHOWN_JSON' "$SELECTED" '$DISMISSED_JSON'
```

Where `$SESSION_ID` is the most recent session from `my_sessions`, `$SHOWN_JSON` is the array of option labels shown, `$SELECTED` is the chosen label, and `$DISMISSED_JSON` is the array of labels not chosen. If the user typed custom text via "Other", use their text as the selected value.

This runs silently — do not show output. Proceed immediately to the action.

### After selection

| Selection | Action |
|-----------|--------|
| Handoff | Read filePath from data. Display content + entry points. **Connected mode only:** mark as read: output `  ✦ Remembering...` then run `bash bin/graph-op.sh mark-read $sessionId`. **In local mode:** skip the mark-read call and the indicator — just display the content. Then proceed — no follow-up question. |
| Questions | Load QuestionSet, present via AskUserQuestion. |
| Work stream | Read most recent handoff from cluster. Show Open Threads / Next Steps. Mention relevant knowledge artifacts. |
| PR | `gh pr view #N --json title,body,additions,deletions,files`. Summarize. |
| New / Other | Ask: "What are you working on?" |

## Argument filtering

- `/activity quests` — expand quests, show all with full counts
- `/activity @name` — filter to that person's sessions
- `/activity done [N]` — resolve handoff N. Fetch activity data, map Nth ●/◐ handoff to sessionId. **Connected mode:** Output `  ✦ Resolving...` then run `bash bin/graph-op.sh mark-done $sessionId`. Output: `✓ Resolved: {topic} from {author}`. **Local mode:** Show `Handoff resolution requires connected mode — handoffs are tracked in memory/handoffs/`.
- `/activity analytics` — Run `bash bin/analytics-data.sh` instead of the normal data script. Render full org health using all 10 metrics (cadence, resolution, quest velocity, collaboration density, todo health, throughput, capture ratio, question response, check-in frequency, issue lifecycle). Same TUI box, 72-char frame. Model decides layout — no rigid template. Group metrics by theme (velocity, collaboration, health). Highlight notable patterns, comparisons between people, and week-over-week changes.

## Rules

- `bash bin/activity-data.sh` for ALL data — never call graph.sh directly for reads
- Use `bash bin/graph-op.sh <operation>` for all graph writes (mark-read, mark-done, etc.) — never raw Cypher — **connected mode only**
- Before any graph write, output a thinking indicator: `  ✦ Remembering...` or `  ✦ Resolving...` — **connected mode only**
- **In local mode:** do NOT run any `bin/graph-op.sh` calls or show thinking indicators. All graph write operations are skipped silently.
- No sub-boxes — only outer frame `│` and `├────┤` separators
- DO NOT output reasoning, character counting, or analysis — render directly
