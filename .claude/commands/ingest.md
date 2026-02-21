Unified content ingestion router. Dispatches to type-specific analysis pipelines.

Arguments: $ARGUMENTS (Optional: subcommand — "meeting", "user-interview", or search term)

## Usage

- `/ingest` — Auto-detect source type or ask
- `/ingest meeting` — Route to meeting pipeline (Granola meetings)
- `/ingest meeting sync` — Batch process all unprocessed meetings
- `/ingest meeting backfill` — Re-process historical meetings
- `/ingest meeting [search]` — Find and process a specific meeting
- `/ingest user-interview` — Route to user interview analysis pipeline

## When to invoke

**Trigger phrases:**
- "process the meeting", "ingest the call", "meeting notes" → `/ingest meeting`
- "process the interview", "analyze the interview", "user interview", "onboarding interview", "research session" → `/ingest user-interview`
- "ingest", "process this" → `/ingest` (auto-detect or ask)

**Disambiguation:**
- Team meeting / sync / standup → `/ingest meeting`
- User interview / research session / onboarding call → `/ingest user-interview`
- "process the call" → ambiguous — ask which type

## What to do

### Step 1: Parse subcommand

Read `$ARGUMENTS` and determine the route:

```
$ARGUMENTS parsing:
  "meeting"                → meeting pipeline
  "meeting sync"           → meeting pipeline (pass "sync")
  "meeting backfill"       → meeting pipeline (pass "backfill")
  "meeting <search>"       → meeting pipeline (pass search term)
  "user-interview"         → interview pipeline
  "user-interview <args>"  → interview pipeline (pass remaining args)
  "" (empty)               → auto-detect (Step 2)
  other                    → auto-detect with hint (Step 2)
```

### Step 2: Auto-detect (when no explicit subcommand)

If `$ARGUMENTS` is empty or doesn't match a known subcommand:

**Check for keyword hints in $ARGUMENTS:**
- Contains "meeting", "sync", "backfill", "standup", "weekly" → route to meeting
- Contains "interview", "user", "onboarding", "research session" → route to interview

**If still ambiguous**, ask:

```
AskUserQuestion:
  question: "What kind of content are you ingesting?"
  header: "Source"
  options:
    - label: "Meeting"
      description: "Team meeting from Granola — syncs, standups, reviews"
    - label: "User Interview"
      description: "Research session — onboarding interview, user feedback call"
```

### Step 3: Route to pipeline

**Meeting pipeline:**
Load and follow `.claude/commands/meeting.md`. Pass through any remaining arguments after "meeting" (e.g., "sync", "backfill", search term).

This is equivalent to running `/meeting` directly — the meeting pipeline is unchanged.

**Interview pipeline:**
Load and follow `.claude/commands/ingest-user-interview.md`. Pass through any remaining arguments after "user-interview".

## Architecture

```
/ingest                    → this router (auto-detect or ask)
/ingest meeting            → .claude/commands/meeting.md (existing, unchanged)
/ingest user-interview     → .claude/commands/ingest-user-interview.md (new)
/ingest [future type]      → extensible — add new pipelines as needed
```

The meeting pipeline (`/meeting`) continues to work as a standalone command. `/ingest meeting` simply routes to it. No migration, no breaking changes.

## Extensibility

To add a new ingest type:
1. Create `.claude/commands/ingest-{type}.md` with the pipeline spec
2. Add the type to Step 1 parsing and Step 2 keyword hints above
3. Add an option to the AskUserQuestion in Step 2
