See your recent sessions, open handoffs, and current work at a glance.

Display it immediately — no preamble, no narration, no reasoning text. Output the box and nothing else before AskUserQuestion.

## When to invoke

User says: "what did I work on", "my dashboard", "show me my work", "what's my status", "what have I done", "my sessions", "my progress", "what's open", "where was I"
Not this: team-wide view → `/activity` · ending session → `/wrap` · pushing work → `/save`

Topic: $ARGUMENTS

## Execution rules

**CRITICAL: Suppress raw output.** Never show raw JSON. Capture all script output in variables, only show formatted TUI.
**One data call.** `bash bin/dashboard-data.sh` returns everything as JSON. Do NOT call `bin/graph.sh` directly.
**Render immediately.** No "Let me check..." or "Here's your dashboard...". Straight to the TUI box.

## Step 1: Fetch data

Map `$ARGUMENTS` to time range:
- (empty) → `P7D`
- `today` → `P1D`
- `week` → `P7D`
- `month` → `P30D`
- `all` → `P365D`

```bash
DATA=$(bash bin/dashboard-data.sh "" "$TIME_RANGE" 2>/dev/null)
```

The script auto-detects the user from `.egregore-state.json`. Returns JSON with:
- `me`, `org`, `date`, `range_label`, `graph_status`, `graph_reason`
- `sessions[]`, `todos[]`, `quests[]`, `handoffs[]`, `open_threads[]`
- `stats{totalSessions, wrappedSessions, openTodos, oldestTodoDays}`
- `current_session{id, status, topic, branch}`
- `identity_hint` (non-null if identity mismatch detected)
- `git{branch, dirty}`

### Graph offline handling

If `graph_status` is not `"connected"`:
- Show `(offline)` after sigil in header
- Show the current session from `current_session` (client-side fallback always works)
- Skip todos, quests, handoffs, open_threads sections
- Footer: reason message based on `graph_reason`:
  - `missing_config` → "API not configured. Run /env to set up."
  - `unreachable` → "API unreachable. Check your network."
  - `auth_error` → "Authentication failed. Run /env to check your API key."
  - `server_error` → "Server error. Try again later."

### Identity mismatch handling

If `identity_hint` is non-null (stats show 0 sessions but current_session exists):
- Show the hint in the footer: "⚠ [identity_hint] Run /env to check."
- Still render the current session from client-side fallback

## Step 2: Render TUI

72-char outer width. 4 line patterns only (top `┌─┐`, separator `├─┤`, content `│ │`, bottom `└─┘`). **No sub-boxes.**

Sigil: `◉ DASHBOARD`

### Section ordering rationale

Action first, context second. The primary use case is resumption ("where was I, what should I do?"):

1. **Current session** (you are here)
2. **Open threads from wraps** (what's unfinished — strongest resumption signal)
3. **Open todos** (what to do next)
4. **Pending handoffs** (social obligation = urgency)
5. **Recent sessions** (orientation — what have I been doing)
6. **Quests** (strategic context)

Stats move to the footer. Artifacts omitted from daily view (use `/dashboard month` or `/reflect` for knowledge record).

### Layout

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◉ DASHBOARD                                       cem · Feb 19     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ● v1-data-quality                                       active      │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  PICK UP WHERE YOU LEFT OFF                                          │
│                                                                      │
│  Yesterday · dashboard command design                                │
│    ○ finish retry logic in graph.sh                                  │
│    ○ review pricing page copy                                        │
│  Feb 17 · pricing strategy revisions                                 │
│    ○ revisit unit economics with new tier                            │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  OPEN TODOS (5)                                                      │
│                                                                      │
│  [1] ★ fix retry logic in graph.sh                                   │
│      → egregore-reliability                                          │
│  [2]   revisit pricing page copy                                     │
│  [3] ✗ blocked: waiting on design review                             │
│                                                                      │
│  + 2 more · /todo to see all                                         │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  HANDOFFS (1 pending)                                                │
│                                                                      │
│  ● bob: MCP auth review (yesterday)                                  │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  SESSIONS (last 7 days)                                              │
│                                                                      │
│  ● Today      v1-data-quality                            active      │
│  ◎ Yesterday  dashboard command design                   wrapped     │
│  ◎ Feb 17     pricing strategy revisions                 wrapped     │
│  → Feb 16     onboarding flow to oskar                   handed off  │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  QUESTS (2 active)                                                   │
│                                                                      │
│  egregore-reliability       3 sessions · 5 artifacts · 2d ago       │
│  pricing-strategy           2 sessions · 3 artifacts · 4d ago       │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  8 sessions · 5/8 wrapped · 5 open todos (oldest: 12d)              │
│  What's next?                                                        │
└──────────────────────────────────────────────────────────────────────┘
```

### Section rules

**Header**: `◉ DASHBOARD` left, `{me} · {date}` right.

**Current session** (always shown, right after header):
- Format: `● {topic|branch}` left, `active` right
- Topic fallback: `topic` → `branch` → `id`
- If no current session data at all: show `● (starting...)  active`

**PICK UP WHERE YOU LEFT OFF** (skip if no open threads):
- Sources from `open_threads[]` — wrapped sessions with unfinished items
- Grouped by session: `{date} · {topic}` as header, then `○ {thread}` items indented
- Max 3 sessions, max 3 threads per session
- This is the highest-value section for the resumption use case

**OPEN TODOS** (skip if empty):
- Header: `OPEN TODOS ({total count})`
- Show top 3 with numbering `[1]`-`[3]`
- `★` prefix for priority >= 2
- `✗ blocked:` prefix for blocked, show blockedBy text
- `↓ deferred` for deferred status
- Quest link on next line: `    → {quest-id}`
- If more: `+ N more · /todo to see all`

**HANDOFFS** (skip if empty):
- Header: `HANDOFFS ({count} pending)`
- `●` for pending, `◐` for read
- Format: `{icon} {author}: {topic} ({when})`
- Max 3

**SESSIONS** (always shown):
- Header: `SESSIONS ({range_label})`
- Status icons: `●` active, `◎` wrapped, `→` handed_off
- Display: `{icon} {date}  {topic|branch}  {status}`
- Topic fallback: `topic` → `branch` → `id`
- Show top 5. If more: `+ N more`
- Date: `Today`, `Yesterday`, `Mon DD` (9 chars padded)

**QUESTS** (skip if empty):
- Header: `QUESTS ({count} active)`
- Format: `{quest-id}` left, `{N} sessions · {N} artifacts · {N}d ago` right
- Max 3

**Footer** (always shown):
- Stats line that answers questions:
  - `{N} sessions · {wrapped}/{total} wrapped · {N} open todos`
  - If `oldestTodoDays` > 7: append `(oldest: {N}d)` — staleness signal
  - If all zeros: `No activity recorded yet`
  - If identity hint: `⚠ {hint} Run /env to check.`
- Always end with: `What's next?`

### Empty state

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◉ DASHBOARD                                       cem · Feb 19     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ● (this session)                                        active      │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  Your dashboard fills up as you work. Sessions are auto-captured.    │
│  /wrap when done · /todo to add tasks · /reflect to capture insights │
│  What's next?                                                        │
└──────────────────────────────────────────────────────────────────────┘
```

## Step 3: Follow-up (AskUserQuestion)

```
header: "Action"
question: "What's next?"
options: [dynamically built from data, 2-4 options]
multiSelect: false
```

### Option generation (model-driven from data):

Build 2-4 options based on what the dashboard shows. Prefer the most actionable:
- If open threads exist: `"Pick up: {most recent thread text}"` → load session context
- If handoffs pending: `"Triage handoffs from {author}"` → route to /handoff
- If todos with priority >= 2: `"Work on: {todo text}"` → show todo context
- If current session active and has commits: `"Wrap this session"` → route to /wrap
- If quest idle > 5 days: `"Continue {quest-id}"` → load quest context
- Always available as fallback (Other is automatic via AskUserQuestion)

### After selection:

| Selection | Action |
|-----------|--------|
| Pick up thread | Load the wrapped session's context (read wrap file, show summary + threads) |
| Triage handoffs | Route to `/handoff` |
| Work on todo | Show full todo context, ask what they want to do |
| Wrap this session | Route to `/wrap` |
| Continue quest | Load quest file from memory, show recent artifacts + sessions |

## Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"dashboard"}' 2>/dev/null &
```
