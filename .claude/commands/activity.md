Activity dashboard. Display it immediately — no preamble, no narration, no reasoning text. Output the box and nothing else before AskUserQuestion.

Topic: $ARGUMENTS

## Step 1: Fetch data

Run ONE command to get all dashboard data:

```bash
bash bin/activity-data.sh
```

Returns JSON: `me`, `org`, `date`, `my_sessions`, `team_sessions`, `quests`, `pending_questions`, `answered_questions`, `handoffs_to_me`, `all_handoffs`, `knowledge_gap`, `orphans`, `prs`, `disk`.

If the command fails, fall back to reading `memory/` files. Add `(offline)` after ✦ in header.

## Step 2: Render dashboard

Output the TUI box directly. 72 chars wide. Use these frame lines (copy exactly):

```
┌──────────────────────────────────────────────────────────────────────┐
├──────────────────────────────────────────────────────────────────────┤
└──────────────────────────────────────────────────────────────────────┘
```

Content rows: `│  {text padded with trailing spaces}  │`

**DO NOT count characters or show reasoning.** Approximate padding is fine — the frame is decorative, not pixel-perfect. Go straight from data to rendered output.

### Sections (separated by `├────┤`)

**Header**: `{ORG} EGREGORE ✦ ACTIVITY DASHBOARD` left, `{me} · {date}` right

**Insight** (1-2 lines): Synthesize what's happening. Warm, concise, connective.

**Handoffs & Asks** (skip if all empty):
- Handoffs to me (status=pending or null) → `[N] {from} → you: {topic} ({when})`
- Handoffs to me (status=read) → unnumbered `    ○ {from} → you: {topic} (read)`
- Pending questions → `[N] {from} asks about "{topic}" ({when})`
- Answered questions → `[N] ✓ {name} answered "{topic}"`
- Other handoffs → unnumbered `{from} → {to}: {topic} ({when})`
- Numbered items first, blank line, then read handoffs + others.

**Sessions**:
- `◦ YOUR SESSIONS` — top 5. Format: `{date}  {topic}`
- `◦ TEAM` — top 5. Format: `{date}  {name}: {topic}`
- Blank line between sub-sections.

**Quests & PRs** (skip if both empty):
- `⚑ QUESTS (N active)` — top 5 by score. `{quest-id}` left, `{N} artifacts · {N}d ago` right.
- `→ OPEN PRs` — `#{number}  {title} ({author})`
- Blank line between sub-sections. Omit either if empty.

**Footer** (separated by `├────┤`):
- If orphans.orphanCount > 0: `{N} artifacts unlinked to quests — /quest suggest`
- If knowledge_gap.gapCount > 0: `{N} sessions without captured insights — /reflect to extract`
- Else: `/ask a question · /quest to see more · /reflect for insights`
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

Generate 2-4 options, prioritized (take first 2-4 that apply):

| Priority | Source | Label | Description |
|----------|--------|-------|-------------|
| 1 | handoffs_to_me | `Read {author}'s handoff` | `{topic} — {when}` |
| 2 | pending_questions | `Answer {asker}'s questions` | `About "{topic}" — {when}` |
| 3-4 | my_sessions (last 3 days) | Work stream name | Cluster recent sessions by theme. Name specifically. Max 2 clusters. Hint at what's next, not what's done. |
| 5 | prs (not by me) | `Review PR #{N}` | `{title} by {author}` |
| 6 | fallback | `Start something new` | `Begin a fresh work stream` |

Minimum 2 options. "Other" is automatic.

### After selection

| Selection | Action |
|-----------|--------|
| Handoff | Read filePath from data. Display content + entry points. **Immediately** mark as read: `bash bin/graph.sh query "MATCH (s:Session {id: '$sessionId'}) SET s.handoffStatus = 'read' RETURN s.id"`. After displaying content, ask via AskUserQuestion: header "Handoff", question "What next?", options: "Start working on this" (marks `handoffStatus = 'done'` via `bash bin/graph.sh query "MATCH (s:Session {id: '$sessionId'}) SET s.handoffStatus = 'done' RETURN s.id"`), "Keep it open" (stays `read`, no action needed). |
| Questions | Load QuestionSet, present via AskUserQuestion. |
| Work stream | Read most recent handoff from cluster. Show Open Threads / Next Steps. Mention relevant knowledge artifacts. |
| PR | `gh pr view #N --json title,body,additions,deletions,files`. Summarize. |
| New / Other | Ask: "What are you working on?" |

## Argument filtering

- `/activity quests` — expand quests, show all with full counts
- `/activity @name` — filter to that person's sessions

## Rules

- `bash bin/activity-data.sh` for ALL data — never call graph.sh directly
- No sub-boxes — only outer frame `│` and `├────┤` separators
- DO NOT output reasoning, character counting, or analysis — render directly
