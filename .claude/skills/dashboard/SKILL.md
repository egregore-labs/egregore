See your recent sessions, open handoffs, and current work at a glance.

Display it immediately — no preamble, no narration, no reasoning text. The rendered box must be the FINAL text of the turn — never follow it with AskUserQuestion in the same turn. The harness hides text that precedes a tool call, so a box rendered before AskUserQuestion is never seen by the user.

## When to invoke

User says: "what did I work on", "my dashboard", "show me my work", "what's my status", "what have I done", "my sessions", "my progress", "what's open", "where was I"
Not this: team-wide view → `/activity` · ending session → `/wrap` · pushing work → `/save`

Topic: $ARGUMENTS

## Execution rules

**CRITICAL: Suppress raw output.** Never show raw JSON. Shell variables do NOT persist between tool calls, so `DATA=$(...)` alone cannot hide it — use the temp-file + compact-slice pattern in Step 1.
**One data call.** `bash bin/dashboard-data.sh` returns everything as JSON. Do NOT call `bin/graph.sh` directly.
**Render immediately.** No "Let me check..." or "Here's your dashboard...". Straight to the TUI box.

## Step 1: Fetch data

Map `$ARGUMENTS` to time range:
- (empty) → `P7D`
- `today` → `P1D`
- `week` → `P7D`
- `month` → `P30D`
- `all` → `P365D`

**Quiet fetch — never print the raw JSON.** This command renders inline (terminal-render, undelegatable), so a bare data-script call dumps hundreds of JSON lines into the terminal before the box. Write to a temp file and read compact slices, in ONE command:

```bash
DATA="${TMPDIR:-/tmp}/egregore-dashboard-$$.json"
bash bin/dashboard-data.sh "" "$TIME_RANGE" > "$DATA" 2>/dev/null
jq -c '{me, org, date, range_label, graph_status, graph_reason, stats, current_session, identity_hint, git}' "$DATA"
jq -c '.sessions[:8][] | {id, date, topic, branch, status, handedTo}' "$DATA"
jq -c '(.todos[:8][] | {id, text: (.text | tostring | .[0:120]), status, priority, quest}), (.quests[:5][]), (.handoffs[:5][]), (.open_threads[:5][])' "$DATA"
rm -f "$DATA"
```

If a later step needs a field not sliced above (e.g. a session's `summary`), re-fetch and run another targeted `jq` — never `cat` the file, never run the data script bare.

The script auto-detects the user from `.egregore-state.json`. Returns JSON with:
- `me`, `org`, `date`, `range_label`, `graph_status`, `graph_reason`
- `sessions[]`, `todos[]`, `quests[]`, `handoffs[]`, `open_threads[]`
- `stats{totalSessions, wrappedSessions, openTodos, oldestTodoDays}`
- `current_session{id, status, topic, branch}`
- `identity_hint` (non-null if identity mismatch detected)
- `git{branch, dirty}`

### Mode detection

Read `mode` from `egregore.json`:
```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

### Local mode (`mode === "local"`)

Do NOT show graph status, graph_reason, or any "/connect", "/env", "/setup" messaging. Instead:
- Show current session from `current_session`
- Read recent handoffs from `memory/handoffs/index.md` (last 3-5 entries)
- Read active quests from `memory/quests/index.md`
- Show git branch + dirty status from `git` field
- Footer: `"Local mode — memory is your source of truth"`
- Skip: todos, open_threads (graph-dependent)

### Connected mode — graph offline handling

Only applies when `mode === "connected"` (or mode not set). If `graph_status` is not `"connected"`:
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

### Topic display rules (MANDATORY)

When displaying a session topic anywhere in the dashboard:
- If `topic` is non-null: show it as-is
- If `topic` is null/empty: show the branch slug humanized (drop the `dev/author/` prefix, replace hyphens with spaces). E.g. `dev/oz/session-naming-bug` → `session naming bug`
- If branch is also null or is `develop`/`main`/`master`: show the session date as fallback (e.g. `Feb 24 session`)
- **NEVER show "untitled", "current session", "quick session", or any invented label**

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
- If `packages/egregore-artifacts/` exists: `Open in browser? /view activity`
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

## Step 3: Follow-up

**Sequencing (MANDATORY):** end the turn with the rendered box as your final text — do NOT call AskUserQuestion (or any tool) after it in the same turn; the harness hides text that precedes a tool call, which swallows the box. Close the box with `What's next?` and wait.

When the user replies, act on it directly. Only if their reply is ambiguous between concrete next steps, present options via AskUserQuestion in that NEXT turn:

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
